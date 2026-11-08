extends Node
## Client for GameCove's open game database (built nightly by gamedb/gamedb/build.py,
## published as a GitHub release). Downloads it at most once a day, keeps it in
## user://, and works offline from that copy. The static functions do the
## parsing and matching so they can run on a worker thread and in tests.

signal updated

const URL := "https://github.com/IHulkSmashI/GameCove/releases/download/gamedb/gamedb.json.gz"
const CACHE_PATH := "user://gamedb.json.gz"
const MAX_AGE_S := 24 * 60 * 60
## Upper bound for the unpacked file, so a bad download can't eat all memory.
const MAX_UNPACKED := 512 * 1024 * 1024
const STORES := ["steam", "gog", "epic"]

var _http: HTTPRequest


## True when the cached copy is missing or older than a day.
static func is_stale(cache_modified_unix: int, now_unix: int) -> bool:
	return cache_modified_unix <= 0 or now_unix - cache_modified_unix >= MAX_AGE_S


## Starts a background download if the cached copy is stale. Emits `updated`
## after a good download; a failed one keeps the old copy and stays quiet.
func update_if_stale() -> void:
	var path := ProjectSettings.globalize_path(CACHE_PATH)
	var modified := int(FileAccess.get_modified_time(path)) if FileAccess.file_exists(path) else 0
	if not is_stale(modified, int(Time.get_unix_time_from_system())) or _http != null:
		return
	_http = HTTPRequest.new()
	_http.use_threads = true
	_http.accept_gzip = false
	_http.timeout = 120.0
	_http.download_file = path + ".part"
	add_child(_http)
	_http.request_completed.connect(_on_downloaded)
	if _http.request(URL) != OK:
		_finish_http()


func _on_downloaded(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	var path := ProjectSettings.globalize_path(CACHE_PATH)
	var part := path + ".part"
	var good := result == HTTPRequest.RESULT_SUCCESS and code == 200 \
		and not parse_gz(FileAccess.get_file_as_bytes(part)).is_empty()
	if good:
		DirAccess.rename_absolute(part, path)
	else:
		if FileAccess.file_exists(part):
			DirAccess.remove_absolute(part)
		print_verbose("gamedb: download skipped (result %d, HTTP %d); using cached copy" % [result, code])
	_finish_http()
	if good:
		updated.emit()


func _finish_http() -> void:
	if _http:
		_http.queue_free()
		_http = null


## The database document from gzip bytes, or {} if they aren't a valid one.
static func parse_gz(bytes: PackedByteArray) -> Dictionary:
	# gzip magic number; checking it first keeps Godot from logging errors for
	# an HTML error page or other junk.
	if bytes.size() < 18 or bytes[0] != 0x1f or bytes[1] != 0x8b:
		return {}
	var raw := bytes.decompress_dynamic(MAX_UNPACKED, FileAccess.COMPRESSION_GZIP)
	if raw.is_empty():
		return {}
	var json := JSON.new()
	if json.parse(raw.get_string_from_utf8()) != OK or not json.data is Dictionary:
		return {}
	var doc: Dictionary = json.data
	return doc if doc.get("games") is Array else {}


static func load_file(path: String) -> Dictionary:
	return parse_gz(FileAccess.get_file_as_bytes(path)) if FileAccess.file_exists(path) else {}


## Title key for matching: lowercase letters and digits only, so ™ ® ©, case,
## spacing and punctuation don't matter ("DOOM™ Eternal" == "Doom Eternal").
static func normalise(title: String) -> String:
	var re := RegEx.create_from_string("[^\\p{L}\\p{N}]+")
	return re.sub(title.to_lower(), "", true)


## Lookup tables: one per store id plus normalised title. On duplicate titles
## the first record (the database is sorted by title) wins.
static func build_index(doc: Dictionary) -> Dictionary:
	var index := {"title": {}}
	for s in STORES:
		index[s] = {}
	for g in doc.get("games", []):
		if not g is Dictionary:
			continue
		var ids = g.get("ids", {})
		if ids is Dictionary:
			for s in STORES:
				if ids.has(s):
					index[s][str(ids[s]).to_lower()] = g
		var t := normalise(str(g.get("title", "")))
		if t != "" and not index["title"].has(t):
			index["title"][t] = g
	return index


## The database record for a game: any store id first, title only as fallback.
## `ids` maps store -> id or list of ids, e.g. {"epic": ["Fortnite", "fortnite"]}.
static func find(index: Dictionary, ids: Dictionary, title: String) -> Dictionary:
	if index.is_empty():
		return {}
	for s in ids:
		if not index.has(s) or s == "title":
			continue
		var list = ids[s] if ids[s] is Array else [ids[s]]
		for id in list:
			var key := str(id).to_lower()
			if key != "" and index[s].has(key):
				return index[s][key]
	return index["title"].get(normalise(title), {})


static func _hours(v: Variant) -> Variant:
	return float(v) if v is float or v is int else null


## The contract's `info` block from a database record ({} gives all nulls).
## The builder omits null fields (and empty lists) everywhere, so a missing key
## means null here; every key of the contract is always filled in.
static func info_for(rec: Dictionary) -> Dictionary:
	var released = rec.get("released", null)
	var ttb = rec.get("time_to_beat", null)
	if ttb is Dictionary:
		ttb = {
			"main_h": _hours(ttb.get("main_h")), "extra_h": _hours(ttb.get("extra_h")),
			"complete_h": _hours(ttb.get("complete_h")), "count": int(ttb.get("count", 0)),
			"source": str(ttb.get("source", "")),
		}
	else:
		ttb = null
	var ac = rec.get("anticheat", null)
	if ac is Dictionary:
		ac = {"status": str(ac.get("status", "unknown")),
			"anticheats": ac.get("anticheats", []) if ac.get("anticheats") is Array else []}
	else:
		ac = null
	var proton = rec.get("protondb", null)
	return {
		"released": int(released) if released is float or released is int else null,
		"time_to_beat": ttb,
		"anticheat": ac,
		"protondb": proton if proton in ["platinum", "gold", "silver", "bronze", "borked"] else null,
	}
