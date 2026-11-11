extends Node
## Achievements: Steam achievements read offline from the Steam client's own
## cache (steam_achievements.gd), with global rarity from Steam's public
## GetGlobalAchievementPercentagesForApp endpoint (no key, no account).
##
## achievements_for(appid) returns at once from a cache that's checked against
## the files' modification times (two stat calls). The first read of a big
## schema can take a few ms; request(appid) does it on the thread pool and
## answers with `loaded`. Missing files give an empty result, never an error.
##
## Rarity: at most one request per game per day (also after a failure),
## through an HTTPRequest with use_threads, so nothing waits on the network.
## The result is kept in user://achievements/rarity/<appid>.json and `changed`
## fires so the screen can ask again. fetch_rarity = false turns it off.
## Steam Web API Terms of Use (steamcommunity.com/dev/apiterms): data for the
## player's personal use, no implied endorsement by Valve, <= 100,000 calls a
## day per application; this endpoint needs no API key.

## A request() finished. result has the shape of achievements_for().
signal loaded(appid: String, result: Dictionary)
## Something new arrived for this game (rarity); call achievements_for again.
signal changed(appid: String)

const Steam := preload("res://scripts/achievements/steam_achievements.gd")
const RARITY_URL := "https://api.steampowered.com/ISteamUserStats/GetGlobalAchievementPercentagesForApp/v0002/?gameid=%s&format=json"
const RARITY_DIR := "user://achievements/rarity"
const DAY_S := 86400
## The rarity answer is a few hundred KB at most for the biggest games.
const RARITY_MAX_BYTES := 2 * 1024 * 1024
const RARITY_HOSTS := ["api.steampowered.com"]

## Steam root; "" = the first of steam.gd's roots with an appcache/stats folder.
var steam_root := ""
## Steam account id (userdata folder name); "" = the most recent login.
var account := ""
## Steam language name for names and descriptions ("english", "german", ...).
var language := "english"
var fetch_rarity := true
var rarity_dir := RARITY_DIR
## func(url: String, appid: String) -> void that must call rarity_arrived()
## later; tests swap it. Default: an HTTPRequest child.
var fetcher: Callable

var _cache := {}   # appid -> {"key": [mtimes], "result": Dictionary}
var _mutex := Mutex.new()
var _in_flight := {}
var _http: Variant = null   # discover/http.gd (a fake in tests), made on the first fetch
var _tasks: Array[int] = []   # thread-pool ids; every task must be waited on before exit


func _ready() -> void:
	if not fetcher.is_valid():
		fetcher = _http_fetch


## {unlocked, total, items: [{id, name, description, hidden, icon, icon_gray,
## icon_url, icon_gray_url, unlocked, unlock_time, rarity}], source, appid}.
## rarity is a percent, -1 until known. Empty (total 0) when nothing is cached.
func achievements_for(appid: Variant) -> Dictionary:
	var id := str(appid)
	var result := _read(id)
	_maybe_fetch_rarity(id, result)
	return result


## achievements_for() on the thread pool; the answer comes as `loaded`.
func request(appid: Variant) -> void:
	var id := str(appid)
	if not is_inside_tree():
		loaded.emit(id, achievements_for(id))
		return
	for t in _tasks.filter(func(t): return WorkerThreadPool.is_task_completed(t)):
		WorkerThreadPool.wait_for_task_completion(t)   # frees it; returns at once
		_tasks.erase(t)
	_tasks.append(WorkerThreadPool.add_task(func():
		var r := _read(id)
		_finish_request.call_deferred(id, r)))


## Unwaited pool tasks crash the engine at exit; wait for ours.
func _exit_tree() -> void:
	for t in _tasks:
		WorkerThreadPool.wait_for_task_completion(t)
	_tasks.clear()


func _finish_request(id: String, r: Dictionary) -> void:
	_maybe_fetch_rarity(id, r)
	loaded.emit(id, r)


## Drops the cached result (e.g. a game just closed and Steam wrote new stats).
func invalidate(appid: Variant) -> void:
	_mutex.lock()
	_cache.erase(str(appid))
	_mutex.unlock()


func root() -> String:
	return steam_root if steam_root != "" else Steam.find_root(OS.get_environment("HOME"))


func _read(id: String) -> Dictionary:
	var r := root()
	if r == "" or not id.is_valid_int():
		return {"appid": id, "unlocked": 0, "total": 0, "items": [], "source": ""}
	var acct := account if account != "" else Steam.recent_account(r)
	var schema := Steam.schema_path(r, id)
	var user := Steam.user_stats_path(r, id, acct)
	var key := [FileAccess.get_modified_time(schema) if FileAccess.file_exists(schema) else 0,
		user, FileAccess.get_modified_time(user) if user != "" else 0,
		_rarity_mtime(id), language]
	_mutex.lock()
	var hit: Variant = _cache.get(id, null)
	_mutex.unlock()
	if hit != null and hit["key"] == key:
		return hit["result"]
	var result := Steam.read_game(r, id, acct, language, load_rarity(id).get("percent", {}))
	_mutex.lock()
	_cache[id] = {"key": key, "result": result}
	_mutex.unlock()
	return result


# ---- rarity ---------------------------------------------------------------------

## The stored rarity for a game: {"fetched": unix, "tried": unix, "percent": {}}.
func load_rarity(appid: String) -> Dictionary:
	var path := rarity_dir + "/" + appid + ".json"
	if not FileAccess.file_exists(path):
		return {}
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK:
		return {}
	return json.data if json.data is Dictionary else {}


func _rarity_mtime(appid: String) -> int:
	var path := rarity_dir + "/" + appid + ".json"
	return FileAccess.get_modified_time(path) if FileAccess.file_exists(path) else 0


## True when this game's rarity may be fetched now: it has achievements and
## the last try (success or not) is a day old.
func should_fetch(appid: String, total: int, now: int) -> bool:
	if not fetch_rarity or total <= 0 or _in_flight.has(appid):
		return false
	var r := load_rarity(appid)
	return now - int(r.get("tried", 0)) >= DAY_S


func _maybe_fetch_rarity(id: String, result: Dictionary) -> void:
	var now := int(Time.get_unix_time_from_system())
	if not should_fetch(id, int(result.get("total", 0)), now):
		return
	if not fetcher.is_valid():
		return
	_in_flight[id] = true
	_save_rarity(id, {"tried": now, "fetched": int(load_rarity(id).get("fetched", 0)),
		"percent": load_rarity(id).get("percent", {})})
	fetcher.call(RARITY_URL % id, id)


## The fetcher calls this with the response body ("" on failure).
func rarity_arrived(appid: String, body: String) -> void:
	_in_flight.erase(appid)
	var pct := Steam.parse_rarity(body)
	if pct.is_empty():
		return
	var now := int(Time.get_unix_time_from_system())
	_save_rarity(appid, {"tried": now, "fetched": now, "percent": pct})
	invalidate(appid)
	changed.emit(appid)


func _save_rarity(appid: String, data: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(rarity_dir)
	var f := FileAccess.open(rarity_dir + "/" + appid + ".json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data))
		f.close()


func _http_fetch(url: String, appid: String) -> void:
	if _http == null:
		if not is_inside_tree():
			rarity_arrived(appid, "")
			return
		_http = preload("res://scripts/discover/http.gd").new()
		add_child(_http)
	# through the one network gateway: a size cap, backoff, and Steam's own host only (also for redirects)
	_http.request(url, {"timeout": 15.0, "max_bytes": RARITY_MAX_BYTES, "hosts": RARITY_HOSTS},
		func(res: Dictionary):
			var body: PackedByteArray = res.get("body", PackedByteArray())
			rarity_arrived(appid, body.get_string_from_utf8() if res.get("ok", false) else ""))
