extends Node
## Fills in missing game details for every library game, in the background.
## A child of Library ("Metadata"); the Library hands it every game after a
## scan (queue_games) and the game page asks for its game first (request).
##
## What it fetches (Metadata explains the merge order):
## - Steam store appdetails for a Steam game, or for a GOG / Epic / Amazon
##   game's Steam twin, when the merged details still miss something a Steam
##   fetch can fill. One request every STEAM_GAP seconds (Steam allows about
##   200 per 5 minutes); answers (and "Steam has no such app") are cached for
##   CACHE_DAYS in user://metadata/steam/<appid>.json.
## - OpenCritic, only when the user added their own key (opencritic.gd), by
##   title, within the free plan's daily quota; cached CACHE_DAYS.
##
## Privacy (docs/PRIVACY.md): nothing at all with "Look up game details" off;
## the background queue only with "Background lookups" on as well. Opening a
## game page asks for that game right then, like opening a store page does.
## Results go to disk and `resolved(key)` fires on the main thread.

signal resolved(key: String)

const Metadata := preload("res://scripts/library/meta/metadata.gd")
const OpenCritic := preload("res://scripts/library/meta/opencritic.gd")
const Privacy := preload("res://scripts/system/privacy.gd")
const STEAM_URL := "https://store.steampowered.com/api/appdetails?l=english&cc=us&appids="
const CACHE_DIR := "user://metadata"
const CACHE_DAYS := 7
const STEAM_GAP := 1.6
const OC_GAP := 3.0
const MAX_QUEUE := 2000
const MAX_BODY := 2 * 1024 * 1024
const SettingsFile := preload("res://scripts/system/settings_file.gd")

## http.gd node or fake_http.gd object (made in _ready unless set).
var http: Variant = null
var cache_dir := CACHE_DIR
var prefs_path := Privacy.PREFS_PATH
var clock: Callable = func() -> int: return int(Time.get_unix_time_from_system())
## Tests: run every job at once instead of on the timer.
var sync_mode := false

var _queue: Array = []          # jobs, front = next
var _queued := {}               # job id -> true
var _timer: Timer
var _busy := false


func _ready() -> void:
	if http == null:
		var d := get_node_or_null("/root/Discover")
		if d != null and d.get("http") != null:
			http = d.http
		else:
			var node: Node = preload("res://scripts/discover/http.gd").new()
			node.name = "Http"
			add_child(node)
			http = node
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.timeout.connect(_next)
	add_child(_timer)


func _now() -> int:
	return int(clock.call())


func abs_dir() -> String:
	return ProjectSettings.globalize_path(cache_dir)


# ------------------------------------------------------------ cache (static: the Library scan reads it on a worker)

static func steam_cache_path(dir: String, appid: String) -> String:
	return dir.path_join("steam").path_join(appid + ".json")


static func oc_cache_path(dir: String, title: String) -> String:
	return dir.path_join("opencritic").path_join(title.to_lower().sha1_text().substr(0, 24) + ".json")


static func _read(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var j := JSON.new()
	if j.parse(FileAccess.get_file_as_string(path)) != OK or not j.data is Dictionary:
		return {}
	return j.data


static func _write(path: String, data: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data))
		f.close()


## The cached live Steam layer for `appid` ({} if none), whatever its age.
static func steam_cached(dir: String, appid: String) -> Dictionary:
	var c := _read(steam_cache_path(dir, appid)) if appid != "" else {}
	var l = c.get("layer", {})
	if not l is Dictionary or l.is_empty():
		return {}
	# cleaned again on the way in: JSON brings numbers back as floats
	return Metadata.layer("steam", l.get("meta", {}), l.get("critics", {}))


static func oc_cached(dir: String, title: String) -> Dictionary:
	var c := _read(oc_cache_path(dir, title)) if title != "" else {}
	return Metadata.layer("opencritic", {}, {"opencritic": c.get("critics")}) if c.get("critics") is Dictionary else {}


static func _fresh(c: Dictionary, now: int) -> bool:
	return not c.is_empty() and now - int(c.get("at", 0)) < CACHE_DAYS * 86400


## The Steam app id whose store data describes this game: its own for Steam,
## else the twin the game database names ("" when there's none).
static func steam_id_of(game: Dictionary) -> String:
	if str(game.get("store", "")) == "steam":
		return str(game.get("id", ""))
	var info = game.get("info", {})
	var m = info.get("meta", {}) if info is Dictionary else {}
	return str(m.get("steam_twin", "")) if m is Dictionary else ""


## The merged details for a store entry: its layers (set by the Library scan:
## {"local": layer, "db": [layers]}) plus whatever is cached on disk.
static func assemble(layers: Dictionary, steam_twin: String, title: String, dir: String) -> Dictionary:
	var live := steam_cached(dir, steam_twin)
	var oc := oc_cached(dir, title)
	return Metadata.merge(Metadata.ordered(layers.get("local", {}), layers.get("db", []), live, oc), steam_twin)


# ------------------------------------------------------------ settings

static func opencritic_key(path := Privacy.PREFS_PATH) -> String:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return ""
	return str(cfg.get_value("metadata", "opencritic_key", ""))


static func set_opencritic_key(key: String, path := Privacy.PREFS_PATH) -> bool:
	var k := key.strip_edges()
	if not OpenCritic.valid_key(k):
		return false
	return SettingsFile.update_cfg(path, func(cfg: ConfigFile):
		if k == "":
			if cfg.has_section_key("metadata", "opencritic_key"):
				cfg.erase_section_key("metadata", "opencritic_key")
		else:
			cfg.set_value("metadata", "opencritic_key", k)) == OK


# ------------------------------------------------------------ queue

## What this game still needs fetched: [] when nothing (or it isn't allowed).
func jobs_for(game: Dictionary) -> Array:
	var out := []
	if not Privacy.metadata_allowed(prefs_path):
		return out
	var key := str(game.get("key", ""))
	var info = game.get("info", {})
	var meta: Dictionary = info.get("meta", {}) if info is Dictionary and info.get("meta") is Dictionary else Metadata.empty()
	var dir := abs_dir()
	var appid := steam_id_of(game)
	if appid.is_valid_int() and Metadata.wants_steam(meta) and not _fresh(_read(steam_cache_path(dir, appid)), _now()):
		out.append({"kind": "steam", "key": key, "appid": appid})
	var ock := opencritic_key(prefs_path)
	var title := str(game.get("title", ""))
	if ock != "" and title != "" and meta.get("critics", {}).get("opencritic") == null \
			and not _fresh(_read(oc_cache_path(dir, title)), _now()):
		out.append({"kind": "oc", "key": key, "title": title})
	return out


static func _job_id(j: Dictionary) -> String:
	return "%s|%s" % [j["kind"], j.get("appid", j.get("title", ""))]


## True while a game runs (Library.set_background_paused): the background fill waits; a
## game page's own request() still runs (the user asked).
var paused := false
var _asked := {}   # job ids from request(): run even while paused


func set_paused(on: bool) -> void:
	paused = on
	if not on:
		_kick()


## Background fill for a list of games (after a Library scan). Needs both
## "Look up game details" and "Background lookups".
func queue_games(games: Array) -> int:
	if not Privacy.background_allowed(prefs_path):
		return 0
	var n := 0
	for g in games:
		for j in jobs_for(g):
			if _queue.size() >= MAX_QUEUE:
				break
			if not _queued.has(_job_id(j)):
				_queued[_job_id(j)] = true
				_queue.append(j)
				n += 1
	_kick()
	return n


## This game first (its page just opened). Works with Background lookups off.
func request(game: Dictionary) -> int:
	var js := jobs_for(game)
	js.reverse()
	for j in js:
		var id := _job_id(j)
		if _queued.has(id):
			for i in _queue.size():
				if _job_id(_queue[i]) == id:
					_queue.remove_at(i)
					break
		_queued[id] = true
		_asked[id] = true
		_queue.push_front(j)
	_kick()
	return js.size()


func pending() -> int:
	return _queue.size()


## The next job may run now: not paused, or the user asked for it.
func _may_run() -> bool:
	return not _queue.is_empty() and (not paused or _asked.has(_job_id(_queue[0])))


func _kick() -> void:
	if sync_mode:
		while _may_run():
			_run(_queue.pop_front())
		return
	if not _busy and _may_run() and _timer != null and _timer.is_stopped():
		_next()


func _next() -> void:
	if not _may_run():
		return
	_busy = true
	_run(_queue.pop_front())


func _done(gap: float) -> void:
	_busy = false
	if sync_mode or _timer == null or not is_inside_tree():
		return
	if _may_run():
		_timer.start(gap)


func _run(j: Dictionary) -> void:
	_queued.erase(_job_id(j))
	_asked.erase(_job_id(j))
	if http == null or not Privacy.metadata_allowed(prefs_path):
		_done(0.1)
		return
	match j["kind"]:
		"steam":
			_steam(j)
		"oc":
			_oc(j)
		_:
			_done(0.1)


func _steam(j: Dictionary) -> void:
	var appid: String = j["appid"]
	http.request(STEAM_URL + appid.uri_encode(), {"timeout": 20.0, "max_bytes": MAX_BODY}, func(res: Dictionary):
		if res["ok"]:
			var l := Metadata.steam_layer(appid, res["body"])
			# "No such app" is cached too, so it isn't asked again for a week.
			_write(steam_cache_path(abs_dir(), appid), {"at": _now(), "appid": appid, "layer": l})
			resolved.emit(j["key"])
		_done(STEAM_GAP if res.get("error", "") != "backoff" else 30.0))


# ------------------------------------------------------------ OpenCritic (user's own key)

func _quota_path() -> String:
	return abs_dir().path_join("opencritic_quota.json")


func _today() -> String:
	return Time.get_date_string_from_unix_time(_now())


func _use(kind: String, blocked := false) -> void:
	var q := _read(_quota_path())
	if str(q.get("day", "")) != _today():
		q = {"day": _today(), "searches": 0, "requests": 0, "blocked": false}
	q[kind] = int(q.get(kind, 0)) + 1
	if blocked:
		q["blocked"] = true
	_write(_quota_path(), q)


func quota() -> Dictionary:
	return OpenCritic.quota_left(_read(_quota_path()), _today())


func _oc(j: Dictionary) -> void:
	var key := opencritic_key(prefs_path)
	var left := quota()
	var title: String = j["title"]
	var path := oc_cache_path(abs_dir(), title)
	var cached := _read(path)
	if key == "" or left["blocked"] or left["requests"] <= 0:
		_done(0.1)
		return
	var hdr := OpenCritic.headers(key)
	var fetch_game := func(id: int):
		_use("requests")
		http.request(OpenCritic.game_url(id), {"headers": hdr, "timeout": 20.0, "max_bytes": MAX_BODY}, func(res: Dictionary):
			if res["ok"]:
				_write(path, {"at": _now(), "id": id, "title": title, "critics": OpenCritic.parse_game(res["body"])})
				resolved.emit(j["key"])
			elif int(res.get("code", 0)) == 429:
				_use("requests", true)
			_done(OC_GAP))
	if int(cached.get("id", 0)) > 0:
		fetch_game.call(int(cached["id"]))
		return
	if left["searches"] <= 0:
		_done(0.1)
		return
	_use("searches")
	http.request(OpenCritic.search_url(title), {"headers": hdr, "timeout": 20.0, "max_bytes": MAX_BODY}, func(res: Dictionary):
		if not res["ok"]:
			if int(res.get("code", 0)) == 429:
				_use("searches", true)
			_done(OC_GAP)
			return
		var id := OpenCritic.pick(res["body"], title)
		if id <= 0:
			# no exact match: remembered (no score) so it isn't searched again for a week
			_write(path, {"at": _now(), "id": 0, "title": title, "critics": null})
			_done(OC_GAP)
			return
		if quota()["requests"] <= 0:
			_write(path, {"at": 0, "id": id, "title": title, "critics": null})
			_done(OC_GAP)
			return
		fetch_game.call(id))


# ------------------------------------------------------------ screenshots

## A screenshot (or any detail image) on disk: done(path), "" on failure. Only
## the image hosts Metadata allows; cached in user://metadata/shots/. Asked by
## the game page that shows it (needs "Look up game details").
func image(url: String, done: Callable) -> void:
	if http == null or Metadata.https_on(url, Metadata.IMAGE_HOSTS) == "" or not Privacy.metadata_allowed(prefs_path):
		done.call("")
		return
	var dir := abs_dir().path_join("shots")
	DirAccess.make_dir_recursive_absolute(dir)
	var base := dir.path_join(url.sha1_text().substr(0, 24))
	for e in ["jpg", "png", "webp"]:
		if FileAccess.file_exists(base + "." + e):
			done.call(base + "." + e)
			return
	var part := base + ".part"
	http.request(url, {"download_file": part, "timeout": 30.0, "max_bytes": 6 * 1024 * 1024}, func(res: Dictionary):
		var ext := ""
		if res["ok"] and FileAccess.file_exists(part):
			var f := FileAccess.open(part, FileAccess.READ)
			ext = preload("res://scripts/discover/art.gd").sniff(f.get_buffer(12))
			f.close()
		if ext == "" or DirAccess.rename_absolute(part, base + "." + ext) != OK:
			if FileAccess.file_exists(part):
				DirAccess.remove_absolute(part)
			done.call("")
			return
		done.call(base + "." + ext))
