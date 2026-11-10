extends Node
## Client for GameCove's open game database (built nightly by gamedb/gamedb/build.py,
## published as a GitHub release). Downloads it at most once a day, keeps it in
## user://, and works offline from that copy. The static functions do the
## parsing and matching so they can run on a worker thread and in tests.
##
## A finished download is unpacked and checked on a WorkerThreadPool thread,
## never on the main thread. The checked document is handed to the next
## load_file() of the same file (Library's scan, which `updated` starts), so a
## new download is parsed once, not twice.

signal updated

const URL := "https://github.com/IHulkSmashI/GameCove/releases/download/gamedb/gamedb.json.gz"
const CACHE_PATH := "user://gamedb.json.gz"
const MAX_AGE_S := 24 * 60 * 60
## Upper bound for the unpacked file, so a bad download can't eat all memory.
## With game details and critic scores the published file unpacks to about
## 73 MB (November 2026), past the old 64 MB cap: the whole database was
## refused at start ("Decompression failed"). 128 MB leaves room to grow.
const MAX_UNPACKED := 128 * 1024 * 1024
const STORES := ["steam", "gog", "epic"]
## Beside the copy: the unix time of the last failed download. A download that
## failed (refused, HTTP error, cut off) is retried at most once a day, so a bad
## published file isn't fetched and thrown away at every start (review 2, problem 1).
const FAILED_SUFFIX := ".failed"

const SettingsFile := preload("res://scripts/system/settings_file.gd")

## Where the copy lives; tests point it at a temp file.
var cache_path := CACHE_PATH

var _http: HTTPRequest
var _task := -1

## The last download's parsed document, waiting for load_file() of that path:
## {"path": absolute path, "modified": unix mtime, "doc": Dictionary}.
static var _handoff := {}
static var _handoff_mutex := Mutex.new()


## True when the cached copy is missing or older than a day.
static func is_stale(cache_modified_unix: int, now_unix: int) -> bool:
	return cache_modified_unix <= 0 or now_unix - cache_modified_unix >= MAX_AGE_S


## Starts a background download if the cached copy is stale. Emits `updated`
## after a good download; a failed one keeps the old copy and stays quiet.
func update_if_stale() -> void:
	var path := ProjectSettings.globalize_path(cache_path)
	if not should_download(path, int(Time.get_unix_time_from_system())) or _http != null or _task != -1:
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
	var path := ProjectSettings.globalize_path(cache_path)
	var part := path + ".part"
	_finish_http()
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		# offline, 404 (no release yet) and so on: keep the old copy
		if FileAccess.file_exists(part):
			DirAccess.remove_absolute(part)
		# no network at all costs nothing: try again next start. Anything that
		# reached the server (an HTTP error, a cut-off transfer) waits a day.
		if not result in [HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CANT_RESOLVE]:
			record_failure(path)
		print_verbose("gamedb: download skipped (result %d, HTTP %d); using cached copy" % [result, code])
		return
	if not is_inside_tree():
		# tests: no frames run, so do it right here
		_validated(accept_download(part, path))
		return
	_task = WorkerThreadPool.add_task(func(): _validated.call_deferred(accept_download(part, path)),
		false, "GameDB check")


## Worker thread: unpacks and checks the downloaded `part`. A good one replaces
## the copy at `path` and waits for the next load_file(path); a bad one is
## deleted. Returns whether it was good.
static func accept_download(part: String, path: String) -> bool:
	var doc := parse_gz(FileAccess.get_file_as_bytes(part)) if FileAccess.file_exists(part) else {}
	if doc.is_empty():
		if FileAccess.file_exists(part):
			DirAccess.remove_absolute(part)
		print_verbose("gamedb: downloaded file isn't a valid database; using cached copy")
		record_failure(path)
		return false
	if DirAccess.rename_absolute(part, path) != OK:
		DirAccess.remove_absolute(part)
		return false
	if FileAccess.file_exists(path + FAILED_SUFFIX):
		DirAccess.remove_absolute(path + FAILED_SUFFIX)
	_handoff_mutex.lock()
	_handoff = {"path": path, "modified": int(FileAccess.get_modified_time(path)), "doc": doc}
	_handoff_mutex.unlock()
	return true


## True when the copy at `path` is stale and no download failed in the last day.
static func should_download(path: String, now_unix: int) -> bool:
	var modified := int(FileAccess.get_modified_time(path)) if FileAccess.file_exists(path) else 0
	return is_stale(modified, now_unix) and is_stale(last_failure(path), now_unix)


## Unix time of the last failed download of `path` (0 when none).
static func last_failure(path: String) -> int:
	var f := path + FAILED_SUFFIX
	return int(FileAccess.get_file_as_string(f).strip_edges()) if FileAccess.file_exists(f) else 0


static func record_failure(path: String) -> void:
	SettingsFile.save_text(path + FAILED_SUFFIX, "%d\n" % int(Time.get_unix_time_from_system()))


## Main thread, after accept_download().
func _validated(good: bool) -> void:
	if _task != -1:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	if good:
		updated.emit()


func _exit_tree() -> void:
	if _task != -1:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_finish_http()


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


## The database at `path`, or {} if it's missing or broken. If that file is
## the one a download just checked, the document parsed then is reused (once).
## Safe to call from any thread.
static func load_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var doc := take_handoff(path)
	return doc if not doc.is_empty() else parse_gz(FileAccess.get_file_as_bytes(path))


## The document accept_download() left for `path`, or {} if there's none or the
## file changed since. A hand-off for `path` is used up either way.
static func take_handoff(path: String) -> Dictionary:
	_handoff_mutex.lock()
	var h := _handoff
	if not h.is_empty() and h["path"] == path:
		_handoff = {}
	_handoff_mutex.unlock()
	if h.is_empty() or h["path"] != path or h["modified"] != int(FileAccess.get_modified_time(path)):
		return {}
	return h["doc"]


## Title key for matching: lowercase letters and digits only, so ™ ® ©, case,
## spacing and punctuation don't matter ("DOOM™ Eternal" == "Doom Eternal").
static func normalise(title: String) -> String:
	var re := RegEx.create_from_string("[^\\p{L}\\p{N}]+")
	return re.sub(title.to_lower(), "", true)


## Lookup tables: one per store id plus normalised title. On duplicate titles
## the first record wins (the database is sorted by title, the more popular
## game first, so "Resident Evil 4" finds the 2023 remake).
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
			# extra Steam apps of the same game (the builder keeps the lowest id in "steam")
			var more = ids.get("steam_more", [])
			if more is Array:
				for m in more:
					var k := str(m).to_lower()
					if k != "" and not index["steam"].has(k):
						index["steam"][k] = g
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
		# game details: the Library fills these in (scripts/library/meta/metadata.gd)
		"summary": "",
		"meta": preload("res://scripts/library/meta/metadata.gd").empty(),
	}
