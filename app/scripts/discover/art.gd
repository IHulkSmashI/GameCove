extends Node
## Art: cover / hero / logo / header images for any game (Discover entries
## and Library games missing art), downloaded in the background and cached in
## user://art/ with a size cap and least-recently-used clean-up.
##
##   var p := Art.request("steam:1145360", "cover")        # "" until it's cached
##   Art.art_ready.connect(func(key, kind, path): ...)     # path "" = none found
##
## Where images come from, in order:
## 1. a URL the caller passes (hints.url) or one remembered from Steam store
##    data / the calendar (remember()); newer Steam apps keep art under hashed
##    paths that only the store data knows;
## 2. Steam's public CDN by appid (store_item_assets/steam/apps/<id>/...);
## 3. SteamGridDB, with the user's own API key, else GameCove's project key
##    when the build has one (scripts/library/art/sgdb.gd), and only while
##    "Look up game details" is on (scripts/system/privacy.gd).
## A game with nothing found isn't asked about again for a day.

signal art_ready(key: String, kind: String, path: String)

const SteamApi := preload("res://scripts/discover/steam_api.gd")
const KINDS := ["cover", "hero", "logo", "header"]
const SGDB := "https://www.steamgriddb.com/api/v2/"
const RETRY_FAILED_S := 86400
const DEFAULT_MAX_BYTES := 256 * 1024 * 1024
const MAX_FILE_BYTES := 8 * 1024 * 1024

## http.gd node or fake_http.gd object (made in _ready unless tests set one).
var http: Variant = null
var cache_dir := "user://art"
var max_bytes := DEFAULT_MAX_BYTES
## The user's SteamGridDB key; "" = read it from Discover's settings.
var api_key := ""
var clock: Callable = func() -> int: return int(Time.get_unix_time_from_system())

var _known := {}      # key -> {kind: url}
var _index := {}      # file name -> {"size": int, "used": int}
var _failed := {}     # "key|kind" -> unix
var _inflight := {}   # "key|kind" -> true
var _index_loaded := false


func _ready() -> void:
	var main_script = get_tree().get_script()
	if main_script != null and str(main_script.resource_path).begins_with("res://tests/"):
		return
	# Share Discover's http node (one backoff state per host) when it's there.
	var d := get_node_or_null("/root/Discover")
	if d != null and d.get("http") != null:
		http = d.http
		return
	var Http := preload("res://scripts/discover/http.gd")
	var node := Http.new()
	node.name = "Http"
	add_child(node)
	http = node


func _exit_tree() -> void:
	if _index_loaded:
		_save_index()


func _now() -> int:
	return int(clock.call())


## Remembers image URLs for a key ({"cover": url, "hero": url, ...}) so a later
## request() uses them first. Unknown kinds are ignored.
func remember(key: String, art: Dictionary) -> void:
	var k: Dictionary = _known.get(key, {})
	for kind in art:
		if kind in KINDS and str(art[kind]) != "":
			k[kind] = str(art[kind])
	_known[key] = k


static func file_base(key: String, kind: String) -> String:
	return "%s_%s" % [key.sha1_text().substr(0, 20), kind]


## The cached file for key/kind, or "".
func path_for(key: String, kind: String) -> String:
	_ensure_index()
	var base := file_base(key, kind)
	for ext in ["jpg", "png", "webp"]:
		var name: String = base + "." + ext
		if _index.has(name) and FileAccess.file_exists(_abs(name)):
			return _abs(name)
	return ""


## Returns the cached path at once (and marks it used), or "" and starts a
## background download that ends in art_ready(key, kind, path). `hints`:
## {"appid": "123", "url": "https://...", "title": "..."}; a key of the form
## "steam:<appid>" supplies the appid itself.
func request(key: String, kind: String, hints := {}) -> String:
	if not kind in KINDS:
		return ""
	var p := path_for(key, kind)
	if p != "":
		_index[p.get_file()]["used"] = _now()
		return p
	var id := key + "|" + kind
	if _inflight.has(id) or http == null:
		return ""
	if _failed.has(id) and _now() - int(_failed[id]) < RETRY_FAILED_S:
		return ""
	_inflight[id] = true
	_try(key, kind, candidates(key, kind, hints))
	return ""


## The URLs to try, in order; the marker "sgdb" stands for a SteamGridDB lookup.
func candidates(key: String, kind: String, hints: Dictionary) -> Array:
	var out := []
	if str(hints.get("url", "")) != "":
		out.append(str(hints["url"]))
	var known: String = _known.get(key, {}).get(kind, "")
	if known != "" and not known in out:
		out.append(known)
	var appid := str(hints.get("appid", ""))
	if appid == "" and key.begins_with("steam:"):
		appid = key.substr(6)
	if appid != "" and appid.is_valid_int():
		var fb: String = SteamApi.fallback_art(appid).get(kind, "")
		if fb != "" and not fb in out:
			out.append(fb)
	if _key() != "" and (appid != "" or str(hints.get("title", "")) != ""):
		out.append({"sgdb": true, "appid": appid, "title": str(hints.get("title", ""))})
	return out


func _key() -> String:
	if api_key != "":
		return api_key
	var user := ""
	var d := get_node_or_null("/root/Discover") if is_inside_tree() else null
	if d != null and d.has_method("get_settings"):
		user = str(d.get_settings().get("steamgriddb_key", ""))
	if not is_inside_tree() or not preload("res://scripts/system/privacy.gd").metadata_allowed():
		return user
	return preload("res://scripts/library/art/sgdb.gd").key(user)


func _try(key: String, kind: String, list: Array) -> void:
	var id := key + "|" + kind
	if list.is_empty():
		_inflight.erase(id)
		_failed[id] = _now()
		art_ready.emit(key, kind, "")
		return
	var c = list.pop_front()
	if c is Dictionary:
		_sgdb(key, kind, c, func(url: String):
			if url != "":
				list.push_front(url)
			_try(key, kind, list))
		return
	_download(key, kind, str(c), func(path: String):
		if path == "":
			_try(key, kind, list)
			return
		_inflight.erase(id)
		_failed.erase(id)
		art_ready.emit(key, kind, path))


static func sgdb_url(kind: String, game: String, by_steam: bool) -> String:
	var where := ("steam/" if by_steam else "game/") + game.uri_encode()
	match kind:
		"cover":
			return SGDB + "grids/" + where + "?dimensions=600x900&types=static"
		"header":
			return SGDB + "grids/" + where + "?dimensions=460x215,920x430&types=static"
		"hero":
			return SGDB + "heroes/" + where + "?types=static"
	return SGDB + "logos/" + where + "?types=static"


## First image URL (or game id for autocomplete) in a SteamGridDB answer, or "".
static func parse_sgdb(body: PackedByteArray, field := "url") -> String:
	var j := JSON.new()
	if j.parse(body.get_string_from_utf8()) != OK or not j.data is Dictionary or not j.data.get("success", false):
		return ""
	var data = j.data.get("data", [])
	if data is Array and not data.is_empty() and data[0] is Dictionary and data[0].has(field):
		return str(int(data[0][field])) if field == "id" else str(data[0][field])
	return ""


func _sgdb(key: String, kind: String, c: Dictionary, done: Callable) -> void:
	var headers := ["Authorization: Bearer " + _key()]
	var fetch := func(game: String, by_steam: bool):
		http.request(sgdb_url(kind, game, by_steam), {"headers": headers}, func(res: Dictionary):
			done.call(parse_sgdb(res["body"]) if res["ok"] else ""))
	if c["appid"] != "":
		fetch.call(c["appid"], true)
		return
	http.request(SGDB + "search/autocomplete/" + str(c["title"]).uri_encode(), {"headers": headers}, func(res: Dictionary):
		var gid := parse_sgdb(res["body"], "id") if res["ok"] else ""
		if gid == "":
			done.call("")
		else:
			fetch.call(gid, false))


## Image type from the first bytes: "jpg", "png", "webp" or "".
static func sniff(head: PackedByteArray) -> String:
	if head.size() >= 3 and head[0] == 0xFF and head[1] == 0xD8 and head[2] == 0xFF:
		return "jpg"
	if head.size() >= 8 and head.slice(0, 8) == PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]):
		return "png"
	if head.size() >= 12 and head.slice(0, 4).get_string_from_ascii() == "RIFF" and head.slice(8, 12).get_string_from_ascii() == "WEBP":
		return "webp"
	return ""


func _abs(name: String) -> String:
	return ProjectSettings.globalize_path(cache_dir.path_join(name))


func _download(key: String, kind: String, url: String, done: Callable) -> void:
	if not url.begins_with("https://"):
		done.call("")
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(cache_dir))
	var part := _abs(file_base(key, kind) + ".part")
	http.request(url, {"download_file": part, "timeout": 30.0}, func(res: Dictionary):
		done.call(store_part(part, key, kind) if res["ok"] else _drop(part)))


func _drop(part: String) -> String:
	if FileAccess.file_exists(part):
		DirAccess.remove_absolute(part)
	return ""


## Checks a downloaded file and moves it into the cache; returns its path or "".
func store_part(part: String, key: String, kind: String) -> String:
	if not FileAccess.file_exists(part):
		return ""
	var f := FileAccess.open(part, FileAccess.READ)
	var size := f.get_length()
	var ext := sniff(f.get_buffer(12))
	f.close()
	if ext == "" or size <= 0 or size > MAX_FILE_BYTES:
		return _drop(part)
	_ensure_index()
	var name := file_base(key, kind) + "." + ext
	var dest := _abs(name)
	if DirAccess.rename_absolute(part, dest) != OK:
		return _drop(part)
	_index[name] = {"size": size, "used": _now()}
	cleanup()
	_save_index()
	return dest


func total_bytes() -> int:
	_ensure_index()
	var t := 0
	for n in _index:
		t += int(_index[n]["size"])
	return t


## Deletes least recently used files until the cache is under 80% of max_bytes
## (only when it's over max_bytes). Returns how many files went.
func cleanup() -> int:
	_ensure_index()
	if total_bytes() <= max_bytes:
		return 0
	var names := _index.keys()
	names.sort_custom(func(a, b): return int(_index[a]["used"]) < int(_index[b]["used"]))
	var total := total_bytes()
	var removed := 0
	for n in names:
		if total <= max_bytes * 0.8:
			break
		total -= int(_index[n]["size"])
		if FileAccess.file_exists(_abs(n)):
			DirAccess.remove_absolute(_abs(n))
		_index.erase(n)
		removed += 1
	return removed


func _ensure_index() -> void:
	if _index_loaded:
		return
	_index_loaded = true
	var p := _abs("index.json")
	if FileAccess.file_exists(p):
		var j := JSON.new()
		if j.parse(FileAccess.get_file_as_string(p)) == OK and j.data is Dictionary:
			for n in j.data:
				if j.data[n] is Dictionary and FileAccess.file_exists(_abs(n)):
					_index[n] = {"size": int(j.data[n].get("size", 0)), "used": int(j.data[n].get("used", 0))}


func _save_index() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(cache_dir))
	var f := FileAccess.open(_abs("index.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_index))
		f.close()
