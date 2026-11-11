extends Node
## A real photo of the detected handheld, for About this device and the
## first-run welcome. Only freely licensed Commons or Flickr photos (CC0,
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
##   credit_line(credit) -> "Photo: <author>, <license>" | "Image: <Maker>"
##
## Maker images (by link only). A handheld with no free photo may have a
## "maker_image" in res://data/device_photos.json: the maker's own official
## product image on the maker's own site. GameCove never copies it; this
## service downloads that one image from the maker on this device, only when
## asked for the detected handheld, and keeps the bytes unchanged in
## user://device_photos/maker-<url hash>.<png|jpg|webp>. One request per
## session at most (none while the cached copy is under a week old), 10 s
## timeout, 3 MB cap, PNG/JPEG/WebP only (checked from the bytes), no retry
## after a failure until the next start. Credit: "Image: <Maker>", linking to
## the maker's product page.
##
## Bundled images. A row may instead name a picture shipped inside the app:
##   "bundled": "res://assets/device_photos/<id>.webp", "view": "front"
## (WebP, PNG or JPEG under res://assets/device_photos/, force-included by
## export_presets.cfg). It shows offline, needs no request and isn't affected
## by "Show maker photos" (only by "Show a real photo of my device"); no credit
## line (credit {}). To swap the picture, replace the file at that path.
##
## Order: bundled image, then free photo, then maker image, then the drawing.
##   maker_enabled / set_maker_enabled(on)  "Show maker photos" (default on;
##       ConfigFile user://settings.cfg [device] maker_photo). Off: no request
##       to any maker's site; free photo or drawing only.
##
## Families. A "<maker> (unknown model)" row (GameCove knows the maker, not the
## model) has "representative" in device_photos.json: that maker's most common
## current model. photo_for(family) returns the representative's picture plus
##   "family": {"device_id", "representative"}, "caption": "MSI Claw (model not
##   identified)", "pictured": "Pictured: MSI Claw 8 AI+"
## so the UI can say plainly the exact model wasn't recognised. photo_ready is
## emitted for the family id too.
##
## First launch. prefetch(device_id) (and prefetch_detected() for this
## handheld) fetches the picture into the cache ahead of time: the app calls it
## in the background at start, the installer wizard while it is online anyway,
## and `gamecove -- --prefetch-photo` (get-gamecove.sh --no-launch) headless,
## so the photo is there the first time Game Mode opens, even offline. Same
## limits as an ordinary miss (one image, size cap, type sniffed, the maker's
## own URL), and nothing at all when either photo setting is off.

signal photo_ready(device_id: String, path: String)

const SettingsFile := preload("res://scripts/system/settings_file.gd")
const DataRepo := preload("res://scripts/system/data_repo.gd")
const RELEASE := DataRepo.PHOTOS
const PREFS_PATH := "user://settings.cfg"
const MANIFEST_MAX_AGE := 7 * 24 * 3600
const MAX_PHOTO_BYTES := 4 * 1024 * 1024
const MAX_MANIFEST_BYTES := 512 * 1024
## A GitHub release download: GitHub and its file hosts, the address and every redirect hop.
const RELEASE_HOSTS := ["github.com", "githubusercontent.com"]
const SOURCES_PATH := "res://data/device_photos.json"
const MAKER_MAX_BYTES := 3 * 1024 * 1024
const MAKER_MAX_AGE := 7 * 24 * 3600
const MAKER_TIMEOUT := 10.0
const MAKER_EXTS := ["png", "jpg", "webp"]
const BUNDLED_DIR := "res://assets/device_photos/"
const COMMONS_PAGE := "https://commons.wikimedia.org/wiki/File:"
const TPhoto := preload("res://scripts/ui/texts_photo.gd")
## Credit pages we accept: Commons files and Flickr photos (taken through
## Openverse by the build). Same list as tools/device_photos/build.py.
const PAGE_PREFIXES := [COMMONS_PAGE, "https://www.flickr.com/photos/"]

## http.gd node or fake_http.gd object (made in _ready unless tests set one).
var http: Variant = null
var cache_dir := "user://device_photos"
var prefs_path := PREFS_PATH
var enabled := true
var maker_enabled := true
var sources_path := SOURCES_PATH
## device_id -> {"url", "page_url", "maker"} (parse_maker_sources); tests may set it.
var maker_sources: Variant = null
## device ids whose bundled entry names a free photo (Commons/Openverse).
var _free := {}
## device_id -> res:// path of a picture shipped in the app (parse_bundled); tests may set it.
var bundled_sources: Variant = null
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
var _maker_tried := {}       # url -> true: one request per session at most
var _maker_inflight := {}    # url -> [device ids]
var _reps := {}              # family id -> representative id (bundled list)
var _aliases := {}           # representative id -> [family ids asked for]
var _names := {}             # device id -> name (devices.json), for family captions


func _ready() -> void:
	enabled = load_enabled(prefs_path)
	maker_enabled = load_maker_enabled(prefs_path)
	if preload("res://scripts/system/run_mode.gd").helper():
		return   # --restore-baseline: no services (review 2, problem 5)
	var main_script = get_tree().get_script()
	if main_script != null and str(main_script.resource_path).begins_with("res://tests/"):
		return
	var d := get_node_or_null("/root/Discover")
	if d != null and d.get("http") != null:
		http = d.http
	else:
		var node: Node = preload("res://scripts/discover/http.gd").new()
		node.name = "Http"
		add_child(node)
		http = node
	# Background prefetch at start, so the picture is cached before anyone opens
	# About (and before the next offline start); not with "Background lookups" off (review M22).
	if preload("res://scripts/system/privacy.gd").background_allowed(prefs_path):
		prefetch_detected.call_deferred()


# ---- the setting ----------------------------------------------------------------

static func load_enabled(path := PREFS_PATH) -> bool:
	return preload("res://scripts/system/privacy.gd").switch_value(path, "device", "real_photo")


static func load_maker_enabled(path := PREFS_PATH) -> bool:
	return preload("res://scripts/system/privacy.gd").switch_value(path, "device", "maker_photo")


func set_maker_enabled(on: bool) -> void:
	maker_enabled = on
	SettingsFile.update_cfg(prefs_path, func(cfg: ConfigFile): cfg.set_value("device", "maker_photo", on))


func set_enabled(on: bool) -> void:
	enabled = on
	SettingsFile.update_cfg(prefs_path, func(cfg: ConfigFile): cfg.set_value("device", "real_photo", on))


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


## True when a credit link points at a source we accept (PAGE_PREFIXES).
static func page_allowed(url: String) -> bool:
	for prefix in PAGE_PREFIXES:
		if url.begins_with(prefix):
			return true
	return false


# ---- manifest -------------------------------------------------------------------

## manifest.json -> {device_id: {"asset", "sha256", "size", "credit": {...}}}.
## Entries with an unsafe asset name, a bad hash or size, a page not on Commons or Flickr
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
		if not page_allowed(str(entry["credit"]["page_url"])):
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
	var rid := representative_of(device_id)
	if rid != device_id:
		if not device_id in _aliases.get(rid, []):
			_aliases[rid] = _aliases.get(rid, []) + [device_id]
		return _family_photo(device_id, rid, photo_for(rid))
	var b := bundled(device_id)
	if not b.is_empty():
		return b
	_load_manifest()
	var got := cached(device_id)
	if got.is_empty() and _use_maker(device_id):
		return _maker_photo(device_id)
	if not got.is_empty():
		# A weekly look at the manifest still happens, so a photo whose license
		# was withdrawn upstream drops out here too.
		if http != null and _manifest_stale() and not _manifest_tried and _net_allowed():
			_fetch_manifest()
		return got
	_fetch(device_id)
	return {}


## The cached photo only; never touches the network.
func cached(device_id: String) -> Dictionary:
	if not enabled:
		return {}
	var rid := representative_of(device_id)
	if rid != device_id:
		return _family_photo(device_id, rid, cached(rid))
	var b := bundled(device_id)
	if not b.is_empty():
		return b
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


## Every request here is on GameCove's own initiative (a page showing the picture, the start-up prefetch), so
## none is made with "Background lookups" off; what's cached still shows (review M22, problem 4).
func _net_allowed() -> bool:
	return preload("res://scripts/system/privacy.gd").background_allowed(prefs_path)


func _fetch(device_id: String) -> void:
	if http == null or _inflight.has(device_id) or not _net_allowed():
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
	http.request(RELEASE + "manifest.json", {"timeout": 20.0, "max_bytes": MAX_MANIFEST_BYTES, "hosts": RELEASE_HOSTS}, _on_manifest)


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
			_ready_for(id, cached(id)["path"])


func _download(device_id: String) -> void:
	var e: Dictionary = _manifest.get(device_id, {})
	if e.is_empty() or _inflight.has(device_id) or _failed.has(device_id):
		return
	_inflight[device_id] = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(cache_dir))
	var part := _abs(e["asset"] + ".part")
	http.request(RELEASE + e["asset"], {"download_file": part, "timeout": 30.0, "max_bytes": MAX_PHOTO_BYTES, "hosts": RELEASE_HOSTS}, func(res: Dictionary):
		_inflight.erase(device_id)
		var path := store_part(part, e) if res.get("ok", false) else _drop(part)
		if path != "":
			_ready_for(device_id, path)
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


# ---- maker images (by link only) ------------------------------------------------

## device_photos.json -> {device_id: {"url", "page_url", "maker"}} for the
## maker_image entries that follow the "_makers" rules: image URL on that
## maker's own site or CDN (listed prefixes), product page on the maker's
## domain, https only. Same rules as tools/device_photos/makers.py.
static func parse_maker_sources(doc: Variant) -> Dictionary:
	var out := {}
	if not doc is Dictionary or not doc.get("_makers") is Dictionary:
		return out
	var rules: Dictionary = doc["_makers"]
	for id in doc:
		if str(id).begins_with("_") or not doc[id] is Dictionary:
			continue
		var m: Variant = doc[id].get("maker_image")
		if not m is Dictionary:
			continue
		var maker := str(m.get("maker", "")).strip_edges()
		var r: Variant = rules.get(maker)
		if maker == "" or maker.length() > 40 or not r is Dictionary:
			continue
		var url := str(m.get("url", ""))
		var page := str(m.get("page_url", ""))
		var url_ok := false
		for prefix in r.get("image_prefixes", []):
			if str(prefix).begins_with("https://") and url.begins_with(str(prefix)):
				url_ok = true
		if not url_ok or not _page_on(page, r.get("page_domains", [])):
			continue
		out[str(id)] = {"url": url, "page_url": page, "maker": maker}
	return out


static func _page_on(url: String, domains: Variant) -> bool:
	if not url.begins_with("https://") or not domains is Array:
		return false
	var host := url.substr(8).split("/", true, 1)[0].split("?", true, 1)[0].to_lower()
	for d in domains:
		var dd := str(d).to_lower()
		if dd != "" and (host == dd or host.ends_with("." + dd)):
			return true
	return false


## The largest picture decoded (review problem 9): a few hundred KB of PNG or WebP can claim a 50000 x 50000
## canvas, and the view decodes on the main thread. Real photos and maker images are under 4000 px.
const MAX_SIDE := 6000
const MAX_PIXELS := 24 * 1000 * 1000


## Width and height from a PNG, JPEG or WebP header, without decoding; Vector2i.ZERO when unreadable.
static func image_size(b: PackedByteArray) -> Vector2i:
	var n := b.size()
	match sniff_image(b):
		"png":
			if n >= 24:
				return Vector2i((b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19],
					(b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23])
		"jpg":
			var i := 2
			while i + 9 < n:
				if b[i] != 0xFF:
					i += 1
					continue
				var m := b[i + 1]
				if m == 0xFF or m == 0x01 or (m >= 0xD0 and m <= 0xD8):
					i += 1 if m == 0xFF else 2
					continue
				if m >= 0xC0 and m <= 0xCF and m != 0xC4 and m != 0xC8 and m != 0xCC:
					return Vector2i((b[i + 7] << 8) | b[i + 8], (b[i + 5] << 8) | b[i + 6])
				i += 2 + ((b[i + 2] << 8) | b[i + 3])
		"webp":
			if n >= 30:
				var kind := b.slice(12, 16).get_string_from_ascii()
				if kind == "VP8 " and b[23] == 0x9D and b[24] == 0x01 and b[25] == 0x2A:
					return Vector2i((b[26] | (b[27] << 8)) & 0x3FFF, (b[28] | (b[29] << 8)) & 0x3FFF)
				if kind == "VP8L" and b[20] == 0x2F:
					return Vector2i(1 + (((b[22] & 0x3F) << 8) | b[21]), 1 + (((b[24] & 0x0F) << 10) | (b[23] << 2) | ((b[22] & 0xC0) >> 6)))
				if kind == "VP8X":
					return Vector2i(1 + (b[24] | (b[25] << 8) | (b[26] << 16)), 1 + (b[27] | (b[28] << 8) | (b[29] << 16)))
	return Vector2i.ZERO


## True when the header names a size that may be decoded (MAX_SIDE, MAX_PIXELS).
static func size_ok(b: PackedByteArray) -> bool:
	var sz := image_size(b)
	return sz.x > 0 and sz.y > 0 and sz.x <= MAX_SIDE and sz.y <= MAX_SIDE and sz.x * sz.y <= MAX_PIXELS


## "png" | "jpg" | "webp" | "" from the first bytes (never trusts headers).
static func sniff_image(b: PackedByteArray) -> String:
	if b.size() >= 8 and b.slice(0, 8) == PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]):
		return "png"
	if b.size() >= 3 and b[0] == 0xFF and b[1] == 0xD8 and b[2] == 0xFF:
		return "jpg"
	if b.size() >= 12 and b.slice(0, 4).get_string_from_ascii() == "RIFF" and b.slice(8, 12).get_string_from_ascii() == "WEBP":
		return "webp"
	return ""


func _load_sources() -> void:
	if maker_sources != null:
		return
	var doc: Variant = _json(FileAccess.get_file_as_string(sources_path)) if FileAccess.file_exists(sources_path) else null
	maker_sources = parse_maker_sources(doc)
	if doc is Dictionary:
		for id in doc:
			var e: Variant = doc[id]
			if not str(id).begins_with("_") and e is Dictionary and (e.has("file") or e.has("openverse_id")):
				_free[str(id)] = true
		_reps = parse_representatives(doc)


## The maker entry for a device, or {} (also when the setting is off).
func maker_entry(device_id: String) -> Dictionary:
	_load_sources()
	return maker_sources.get(device_id, {}) if maker_sources is Dictionary else {}


## Maker image instead of the free-photo route: only for a device with a
## maker entry and no free photo of its own (a free photo always wins).
func _use_maker(device_id: String) -> bool:
	# The bundled list decides: a row that moved from a free photo to a maker
	# image switches at once, not when the weekly manifest catches up.
	return not maker_entry(device_id).is_empty() and not _free.has(device_id) and bundled_path(device_id) == ""


func _maker_base(url: String) -> String:
	return _abs("maker-" + url.sha256_text().substr(0, 24))


## The cached maker image only; never touches the network.
func maker_cached(device_id: String) -> Dictionary:
	if not enabled or not maker_enabled:
		return {}
	var m := maker_entry(device_id)
	if m.is_empty():
		return {}
	var base := _maker_base(m["url"])
	for ext in MAKER_EXTS:
		var path: String = base + "." + ext
		if FileAccess.file_exists(path):
			return {"path": path, "credit": {"kind": "maker", "maker": m["maker"], "page_url": m["page_url"], "url": m["url"]}}
	return {}


func _maker_photo(device_id: String) -> Dictionary:
	if not maker_enabled:
		return {}
	var got := maker_cached(device_id)
	if got.is_empty():
		_fetch_maker(device_id)
	elif clock.call() - int(FileAccess.get_modified_time(got["path"])) > MAKER_MAX_AGE:
		_fetch_maker(device_id)   # weekly refresh in the background; the old copy shows meanwhile
	return got


func _fetch_maker(device_id: String) -> void:
	var m := maker_entry(device_id)
	if http == null or m.is_empty() or not _net_allowed():
		return
	var url: String = m["url"]
	if _maker_inflight.has(url):
		if not device_id in _maker_inflight[url]:
			_maker_inflight[url].append(device_id)
		return
	if _maker_tried.has(url):
		return
	_maker_tried[url] = true
	_maker_inflight[url] = [device_id]
	# the maker's own host only: a redirect to anywhere else fails (http.gd checks every hop)
	http.request(url, {"timeout": MAKER_TIMEOUT, "max_bytes": MAKER_MAX_BYTES,
		"hosts": [preload("res://scripts/discover/http.gd").host_of(url)],
		"headers": ["Accept: image/png, image/jpeg, image/webp"]}, _on_maker.bind(url))


func _on_maker(res: Dictionary, url: String) -> void:
	var ids: Array = _maker_inflight.get(url, [])
	_maker_inflight.erase(url)
	var body: PackedByteArray = res.get("body", PackedByteArray())
	if not res.get("ok", false) or body.is_empty() or body.size() > MAKER_MAX_BYTES:
		return
	var ext := sniff_image(body)
	if ext == "" or not size_ok(body):
		return
	var path := store_maker(url, body, ext)
	if path == "":
		return
	for id in ids:
		_ready_for(id, path)


## Writes the image bytes as they came (no re-encoding) and drops older copies
## of the same link in other formats. Returns the path or "".
func store_maker(url: String, body: PackedByteArray, ext: String) -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(cache_dir))
	var base := _maker_base(url)
	var part := base + ".part"
	var f := FileAccess.open(part, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_buffer(body)
	f.close()
	for e in MAKER_EXTS:
		if FileAccess.file_exists(base + "." + e):
			DirAccess.remove_absolute(base + "." + e)
	var dest := base + "." + ext
	if DirAccess.rename_absolute(part, dest) != OK:
		return _drop(part)
	return dest


# ---- bundled images (shipped in the app) -----------------------------------------

## device_photos.json -> {device_id: res:// path} for the "bundled" entries
## whose path is a WebP, PNG or JPEG directly under BUNDLED_DIR (no "..").
## Same rule as tools/device_photos/makers.py bundled_problems.
static func parse_bundled(doc: Variant) -> Dictionary:
	var out := {}
	if not doc is Dictionary:
		return out
	var re := RegEx.create_from_string("^res://assets/device_photos/[a-z0-9][a-z0-9._-]{0,80}\\.(webp|png|jpg)$")
	for id in doc:
		var e: Variant = doc[id]
		if str(id).begins_with("_") or not e is Dictionary or not e.has("bundled"):
			continue
		var path := str(e["bundled"])
		if re.search(path) != null and not path.contains(".."):
			out[str(id)] = path
	return out


## The res:// path of this device's bundled picture when the file is there, or "".
func bundled_path(device_id: String) -> String:
	if bundled_sources == null:
		var doc: Variant = _json(FileAccess.get_file_as_string(sources_path)) if FileAccess.file_exists(sources_path) else null
		bundled_sources = parse_bundled(doc)
	var p := str(bundled_sources.get(device_id, "")) if bundled_sources is Dictionary else ""
	return p if p != "" and FileAccess.file_exists(p) else ""


## {"path": res:// path, "credit": {}} for a bundled picture, or {} (also when
## "Show a real photo" is off). Never touches the network; ignores maker_enabled.
func bundled(device_id: String) -> Dictionary:
	if not enabled:
		return {}
	var p := bundled_path(device_id)
	return {} if p == "" else {"path": p, "credit": {}}


# ---- families ---------------------------------------------------------------------

## {family id: representative id} for the rows with "representative" whose
## representative is a real row with a picture source of its own (no chains).
static func parse_representatives(doc: Variant) -> Dictionary:
	var out := {}
	if not doc is Dictionary:
		return out
	for id in doc:
		var e: Variant = doc[id]
		if str(id).begins_with("_") or not e is Dictionary or not e.has("representative"):
			continue
		var rid := str(e["representative"])
		var r: Variant = doc.get(rid)
		if rid == str(id) or not r is Dictionary or r.has("representative"):
			continue
		if r.has("file") or r.has("openverse_id") or r.has("maker_image") or r.has("bundled"):
			out[str(id)] = rid
	return out


## The model whose picture stands in for `device_id` (itself for exact models).
func representative_of(device_id: String) -> String:
	_load_sources()
	return str(_reps.get(device_id, device_id))


## "MSI Claw (unknown model)" -> "MSI Claw (model not identified)".
static func family_caption(family_name: String) -> String:
	var base := family_name.replace(TPhoto.UNKNOWN_MODEL_SUFFIX, "").strip_edges()
	return TPhoto.FAMILY_CAPTION % base


func _name_of(device_id: String) -> String:
	if _names.is_empty():
		for row in preload("res://scripts/device/device.gd").load_table():
			if row is Dictionary:
				_names[str(row.get("id", ""))] = str(row.get("name", ""))
	return str(_names.get(device_id, device_id))


func _family_photo(family_id: String, rid: String, got: Dictionary) -> Dictionary:
	if got.is_empty():
		return {}
	var out := got.duplicate(true)
	out["family"] = {"device_id": family_id, "representative": rid}
	out["caption"] = family_caption(_name_of(family_id))
	out["pictured"] = TPhoto.FAMILY_PICTURED % _name_of(rid)
	return out


func _ready_for(device_id: String, path: String) -> void:
	photo_ready.emit(device_id, path)
	for fam in _aliases.get(device_id, []):
		photo_ready.emit(fam, path)


# ---- prefetch (instant first launch) ---------------------------------------------

## Puts this device's picture into the cache ahead of time (the representative's
## for a family row). True when it's already cached or a download started;
## false when switched off, unknown, no source or no network object.
func prefetch(device_id: String) -> bool:
	if not enabled or device_id == "" or device_id == "unknown":
		return false
	if bundled_path(representative_of(device_id)) != "":
		return true   # shipped in the app: nothing to fetch
	if http == null:
		return false
	photo_for(device_id)
	return has_cached(device_id) or _busy(representative_of(device_id))


## True when this device's picture (bundled, free photo or maker image, the
## representative's for a family) is available locally. Never touches the network.
func has_cached(device_id: String) -> bool:
	var rid := representative_of(device_id)
	if not cached(rid).is_empty():
		return true
	return _use_maker(rid) and not maker_cached(rid).is_empty()


## prefetch() for the handheld Device detected ("" / unknown: nothing).
func prefetch_detected() -> bool:
	var dev := get_node_or_null("/root/Device") if is_inside_tree() else null
	if dev == null or not dev.has_method("id"):
		return false
	return prefetch(str(dev.id()))


func _busy(rid: String) -> bool:
	if _inflight.has(rid) or rid in _waiting or _manifest_fetching:
		return true
	var m := maker_entry(rid)
	return not m.is_empty() and _maker_inflight.has(m["url"])


# ---- for the UI -----------------------------------------------------------------

## "Photo: Jane Doe, CC BY-SA 4.0"; "" for no credit (bundled pictures: {}).
static func credit_line(credit: Dictionary) -> String:
	if credit.is_empty():
		return ""
	if str(credit.get("kind", "")) == "maker":
		return "Image: %s" % str(credit.get("maker", "")).strip_edges()
	var who := str(credit.get("author", "")).strip_edges()
	var lic := str(credit.get("license", "")).strip_edges()
	if who.length() > 60:
		who = who.substr(0, 57).strip_edges() + "…"
	return "Photo: %s, %s" % [who, lic] if lic != "" else "Photo: %s" % who
