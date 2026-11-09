extends Node
## A real photo of the detected handheld, for About this device and the
## first-run welcome. Only freely licensed Wikimedia Commons photos (CC0,
## CC BY, CC BY-SA, public domain) are used; the weekly device-photos workflow
## checks each license through the Commons API and publishes the converted
## photos plus manifest.json (sha256, size, credit) to the rolling
## "device-photos" GitHub release.
##
## This service fetches the manifest (at most once a week) and then only this
## device's own photo, once, in the background through http.gd, checks it
## against the manifest's sha256 and keeps it in user://device_photos/.
## Offline, switched off or no photo for this device: photo_for() returns {}
## and the UI keeps the original drawing (Device.picture_for).
##
##   photo_for(device_id) -> {} | {"path": abs path, "credit": {"author",
##       "license", "license_url", "page_url", "file"}}
##       Never blocks. A miss starts the download; photo_ready follows.
##   signal photo_ready(device_id, path)
##   enabled: bool / set_enabled(on)   "Show a real photo of my device" (default on)
##   credit_line(credit) -> "Photo: <author>, <license>"

signal photo_ready(device_id: String, path: String)

const RELEASE := "https://github.com/IHulkSmashI/GameCove/releases/download/device-photos/"
const PREFS_PATH := "user://settings.cfg"
const MANIFEST_MAX_AGE := 7 * 24 * 3600
const MAX_PHOTO_BYTES := 4 * 1024 * 1024
const MAX_MANIFEST_BYTES := 512 * 1024
const COMMONS_PAGE := "https://commons.wikimedia.org/wiki/File:"

## http.gd node or fake_http.gd object (made in _ready unless tests set one).
var http: Variant = null
var cache_dir := "user://device_photos"
var prefs_path := PREFS_PATH
var enabled := true
## Seconds since the epoch; tests replace it.
var clock: Callable = func() -> int: return int(Time.get_unix_time_from_system())

var _manifest := {}          # device_id -> entry (parse_manifest)
var _manifest_loaded := false
var _manifest_fetching := false
var _manifest_tried := false # one network try per session
var _waiting: Array = []     # device ids asked for while the manifest loads
var _inflight := {}          # device_id -> true
var _failed := {}            # device_id -> true: download failed, no retry this session
var _checked := {}           # abs path -> sha256 already verified this session


func _ready() -> void:
	enabled = load_enabled(prefs_path)
	var main_script = get_tree().get_script()
	if main_script != null and str(main_script.resource_path).begins_with("res://tests/"):
		return
	var d := get_node_or_null("/root/Discover")
	if d != null and d.get("http") != null:
		http = d.http
		return
	var node: Node = preload("res://scripts/discover/http.gd").new()
	node.name = "Http"
	add_child(node)
	http = node


# ---- the setting ----------------------------------------------------------------

static func load_enabled(path := PREFS_PATH) -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return true
	return bool(cfg.get_value("device", "real_photo", true))


func set_enabled(on: bool) -> void:
	enabled = on
	var cfg := ConfigFile.new()
	cfg.load(prefs_path)
	cfg.set_value("device", "real_photo", on)
	cfg.save(prefs_path)


# ---- licenses -------------------------------------------------------------------

## True for the licenses we accept: CC0, public domain, CC BY and CC BY-SA (any
## version). Anything NonCommercial, NoDerivatives, GFDL-only, "fair use" or
## unknown is refused. Same rule as tools/device_photos/build.py.
static func license_allowed(short_name: String) -> bool:
	var s := short_name.strip_edges().to_lower().replace("-", " ").replace("_", " ")
	while s.contains("  "):
		s = s.replace("  ", " ")
	if s == "":
		return false
	for bad in [" nc", " nd", "noncommercial", "non commercial", "noderiv", "no deriv", "fair use", "non free", "copyrighted"]:
		if (" " + s).contains(bad):
			return false
	if s in ["cc0", "cc0 1.0", "cc zero", "public domain", "pd", "no restrictions"]:
		return true
	if s.begins_with("public domain") or s.begins_with("pd "):
		return true
	var re := RegEx.create_from_string("^cc by( sa)? \\d\\.\\d( [a-z]+)?$")
	return re.search(s) != null


# ---- manifest -------------------------------------------------------------------

## manifest.json -> {device_id: {"asset", "sha256", "size", "credit": {...}}}.
## Entries with an unsafe asset name, a bad hash or size, a non-Commons page
## or a license we don't accept are dropped (the app double-checks the build).
static func parse_manifest(text: String) -> Dictionary:
	var out := {}
	var doc: Variant = _json(text)
	if not doc is Dictionary or not doc.get("devices") is Dictionary:
		return out
	var asset_re := RegEx.create_from_string("^[a-z0-9][a-z0-9._-]{0,80}\\.(webp|jpg)$")
	var sha_re := RegEx.create_from_string("^[0-9a-f]{64}$")
	for id in doc["devices"]:
		var e: Variant = doc["devices"][id]
		if not e is Dictionary or not e.get("credit") is Dictionary:
			continue
		var c: Dictionary = e["credit"]
		var entry := {
			"asset": str(e.get("asset", "")),
			"sha256": str(e.get("sha256", "")).to_lower(),
			"size": int(e.get("size", 0)),
			"credit": {
				"author": str(c.get("author", "")).strip_edges(),
				"license": str(c.get("license", "")).strip_edges(),
				"license_url": str(c.get("license_url", "")),
				"page_url": str(c.get("page_url", "")),
				"file": str(c.get("file", "")),
			},
		}
		if asset_re.search(entry["asset"]) == null or sha_re.search(entry["sha256"]) == null:
			continue
		if entry["size"] <= 0 or entry["size"] > MAX_PHOTO_BYTES:
			continue
		if not license_allowed(entry["credit"]["license"]) or entry["credit"]["author"] == "":
			continue
		if not str(entry["credit"]["page_url"]).begins_with(COMMONS_PAGE):
			continue
		var lu := str(entry["credit"]["license_url"])
		if lu != "" and not lu.begins_with("https://"):
			entry["credit"]["license_url"] = ""
		out[str(id)] = entry
	return out


## JSON without the engine's error print on garbage (a bad download is normal).
static func _json(text: String) -> Variant:
	var j := JSON.new()
	return j.data if j.parse(text) == OK else null


func _abs(name: String) -> String:
	return ProjectSettings.globalize_path(cache_dir.path_join(name))


func _manifest_path() -> String:
	return _abs("manifest.json")


func _load_manifest() -> void:
	if _manifest_loaded:
		return
	_manifest_loaded = true
	var p := _manifest_path()
	if FileAccess.file_exists(p):
		_manifest = parse_manifest(FileAccess.get_file_as_string(p))


func _manifest_stale() -> bool:
	var p := _manifest_path()
	if not FileAccess.file_exists(p):
		return true
	return clock.call() - int(FileAccess.get_modified_time(p)) > MANIFEST_MAX_AGE


# ---- the photo ------------------------------------------------------------------

## The cached, checked photo for this device, or {} (and a background download
## starts when there's one to get).
func photo_for(device_id: String) -> Dictionary:
	if not enabled or device_id == "":
		return {}
	_load_manifest()
	var got := cached(device_id)
	if not got.is_empty():
		# A weekly look at the manifest still happens, so a photo whose license
		# was withdrawn upstream drops out here too.
		if http != null and _manifest_stale() and not _manifest_tried:
			_fetch_manifest()
		return got
	_fetch(device_id)
	return {}


## The cached photo only; never touches the network.
func cached(device_id: String) -> Dictionary:
	if not enabled:
		return {}
	_load_manifest()
	var e: Dictionary = _manifest.get(device_id, {})
	if e.is_empty():
		return {}
	var path := _abs(e["asset"])
	if not FileAccess.file_exists(path):
		return {}
	if _checked.get(path, "") != e["sha256"]:
		if FileAccess.get_sha256(path) != e["sha256"]:
			DirAccess.remove_absolute(path)
			return {}
		_checked[path] = e["sha256"]
	return {"path": path, "credit": e["credit"].duplicate()}


func _fetch(device_id: String) -> void:
	if http == null or _inflight.has(device_id):
		return
	if _manifest_stale() and not _manifest_tried:
		if not device_id in _waiting:
			_waiting.append(device_id)
		_fetch_manifest()
		return
	_download(device_id)


func _fetch_manifest() -> void:
	if _manifest_fetching:
		return
	_manifest_fetching = true
	_manifest_tried = true
	http.request(RELEASE + "manifest.json", {"timeout": 20.0}, _on_manifest)


func _on_manifest(res: Dictionary) -> void:
	_manifest_fetching = false
	var body: PackedByteArray = res.get("body", PackedByteArray())
	if res.get("ok", false) and body.size() > 0 and body.size() <= MAX_MANIFEST_BYTES:
		var text := body.get_string_from_utf8()
		var parsed := parse_manifest(text)
		if not parsed.is_empty() or _json(text) is Dictionary:
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(cache_dir))
			var f := FileAccess.open(_manifest_path(), FileAccess.WRITE)
			if f != null:
				f.store_string(text)
				f.close()
			_manifest = parsed
			_manifest_loaded = true
	var ids := _waiting.duplicate()
	_waiting.clear()
	for id in ids:
		if cached(id).is_empty():
			_download(id)
		else:
			photo_ready.emit(id, cached(id)["path"])


func _download(device_id: String) -> void:
	var e: Dictionary = _manifest.get(device_id, {})
	if e.is_empty() or _inflight.has(device_id) or _failed.has(device_id):
		return
	_inflight[device_id] = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(cache_dir))
	var part := _abs(e["asset"] + ".part")
	http.request(RELEASE + e["asset"], {"download_file": part, "timeout": 30.0}, func(res: Dictionary):
		_inflight.erase(device_id)
		var path := store_part(part, e) if res.get("ok", false) else _drop(part)
		if path != "":
			photo_ready.emit(device_id, path)
		else:
			_failed[device_id] = true)


func _drop(part: String) -> String:
	if FileAccess.file_exists(part):
		DirAccess.remove_absolute(part)
	return ""


## Moves a finished download into place when its size and sha256 match.
func store_part(part: String, e: Dictionary) -> String:
	if not FileAccess.file_exists(part):
		return ""
	var f := FileAccess.open(part, FileAccess.READ)
	if f == null:
		return _drop(part)
	var size := f.get_length()
	f.close()
	if size != int(e["size"]) or FileAccess.get_sha256(part) != str(e["sha256"]):
		return _drop(part)
	var dest := _abs(e["asset"])
	if FileAccess.file_exists(dest):
		DirAccess.remove_absolute(dest)
	if DirAccess.rename_absolute(part, dest) != OK:
		return _drop(part)
	_checked[dest] = e["sha256"]
	return dest


# ---- for the UI -----------------------------------------------------------------

## "Photo: Jane Doe, CC BY-SA 4.0"
static func credit_line(credit: Dictionary) -> String:
	var who := str(credit.get("author", "")).strip_edges()
	var lic := str(credit.get("license", "")).strip_edges()
	if who.length() > 60:
		who = who.substr(0, 57).strip_edges() + "…"
	return "Photo: %s, %s" % [who, lic] if lic != "" else "Photo: %s" % who
