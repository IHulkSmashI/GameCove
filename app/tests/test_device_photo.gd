extends "res://tests/test_case.gd"
## DevicePhoto (scripts/device/photo.gd) and its view, with fake_http: no network.

const PhotoSvc := preload("res://scripts/device/photo.gd")
const PhotoView := preload("res://scripts/ui/device/device_photo_view.gd")
const FakeHttp := preload("res://scripts/discover/fake_http.gd")

const CREDIT := {"author": "Jane Doe", "license": "CC BY-SA 4.0",
	"license_url": "https://creativecommons.org/licenses/by-sa/4.0/",
	"page_url": "https://commons.wikimedia.org/wiki/File:Deck.jpg", "file": "Deck.jpg"}

var _dir := "user://test_device_photos"
var _prefs := "user://test_device_photo_prefs.cfg"


func _clean() -> void:
	var abs := ProjectSettings.globalize_path(_dir)
	if DirAccess.dir_exists_absolute(abs):
		for f in DirAccess.get_files_at(abs):
			DirAccess.remove_absolute(abs.path_join(f))
	DirAccess.make_dir_recursive_absolute(abs)
	if FileAccess.file_exists(_prefs):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_prefs))


## A small real WebP, as the release would serve it.
func _photo_bytes() -> PackedByteArray:
	var img := Image.create(64, 40, false, Image.FORMAT_RGB8)
	img.fill(Color(0.2, 0.4, 0.8))
	return img.save_webp_to_buffer(false, 0.8)


func _manifest(body: PackedByteArray, sha := "") -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(body)
	var h := ctx.finish().hex_encode() if sha == "" else sha
	return JSON.stringify({"version": 1, "devices": {
		"steam-deck-lcd": {"asset": "steam-deck-lcd.webp", "sha256": h, "size": body.size(), "credit": CREDIT}}})


func _svc(http: Variant) -> Node:
	_clean()
	var s: Node = PhotoSvc.new()
	s.cache_dir = _dir
	s.prefs_path = _prefs
	s.http = http
	s.maker_sources = {}   # free-photo tests: no maker links (maker tests set their own)
	return s


func _routes(http: FakeHttp, body: PackedByteArray, manifest: String) -> void:
	http.route(PhotoSvc.RELEASE + "manifest.json", {"text": manifest})
	http.route(PhotoSvc.RELEASE + "steam-deck-lcd.webp", {"bytes": body})


# ---- licenses and manifest ------------------------------------------------------

func test_license_allowlist() -> void:
	for good in ["CC0", "CC BY 4.0", "CC BY-SA 4.0", "CC BY-SA 3.0 de", "CC BY 2.0", "Public domain", "PD"]:
		ok(PhotoSvc.license_allowed(good), good)
	for bad in ["CC BY-NC 4.0", "CC BY-ND 4.0", "CC BY-NC-SA 4.0", "GFDL", "Fair use", "", "All rights reserved"]:
		ok(not PhotoSvc.license_allowed(bad), bad)


func test_manifest_parsing_drops_bad_entries() -> void:
	var sha := "a".repeat(64)
	var good := {"asset": "deck.webp", "sha256": sha, "size": 100, "credit": CREDIT}
	var nc := good.duplicate(true)
	nc["credit"]["license"] = "CC BY-NC 4.0"
	var traversal := good.duplicate(true)
	traversal["asset"] = "../evil.webp"
	var offsite := good.duplicate(true)
	offsite["credit"]["page_url"] = "https://example.com/deck"
	var flickr := good.duplicate(true)
	flickr["credit"]["page_url"] = "https://www.flickr.com/photos/someone/123"
	var no_author := good.duplicate(true)
	no_author["credit"]["author"] = " "
	var bad_sha := good.duplicate(true)
	bad_sha["sha256"] = "xyz"
	var m := PhotoSvc.parse_manifest(JSON.stringify({"devices": {"a": good, "b": nc, "c": traversal,
		"d": offsite, "e": no_author, "f": bad_sha, "g": "junk", "h": flickr}}))
	eq(m.keys(), ["a", "h"], "only the valid entries survive (Commons and Flickr pages)")
	eq(m["a"]["credit"]["author"], "Jane Doe", "credit kept")
	eq(PhotoSvc.parse_manifest("not json"), {}, "garbage -> empty")
	eq(PhotoSvc.parse_manifest("[]"), {}, "wrong shape -> empty")


func test_shipped_list_is_all_allowed() -> void:
	var doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/device_photos.json"))
	var ids := {}
	for d in JSON.parse_string(FileAccess.get_file_as_string("res://data/devices.json"))["devices"]:
		ids[d["id"]] = true
	for id in doc:
		if str(id).begins_with("_"):
			continue
		var e: Dictionary = doc[id]
		ok(ids.has(id), "%s is a known device" % id)
		if e.has("maker_image"):
			ok(not e.has("file") and not e.has("openverse_id"), "%s: maker link only where no free photo" % id)
			ok(PhotoSvc.parse_maker_sources(doc).has(id), "%s: maker link follows the _makers rules" % id)
			continue
		ok(PhotoSvc.license_allowed(e["license"]), "%s license" % id)
		ok(PhotoSvc.page_allowed(str(e["page_url"])), "%s page" % id)
		ok(str(e["author"]) != "", "%s author" % id)


# ---- cache ----------------------------------------------------------------------

func test_miss_downloads_once_then_hits_cache() -> void:
	var http := FakeHttp.new()
	var body := _photo_bytes()
	_routes(http, body, _manifest(body))
	var s := _svc(http)
	var ready := []
	s.photo_ready.connect(func(id, path): ready.append([id, path]))
	eq(s.photo_for("steam-deck-lcd"), {}, "first ask is a miss (download starts)")
	eq(ready.size(), 1, "photo_ready once")
	var got: Dictionary = s.photo_for("steam-deck-lcd")
	ok(FileAccess.file_exists(got.get("path", "")), "cached file")
	eq(got.get("credit", {}).get("author"), "Jane Doe", "credit")
	eq(http.count(PhotoSvc.RELEASE + "steam-deck-lcd.webp"), 1, "downloaded once")
	s.photo_for("steam-deck-lcd")
	eq(http.count(PhotoSvc.RELEASE), 2, "no more requests on hits")
	# A new session reads the cache from disk without touching the network.
	var s2: Node = PhotoSvc.new()
	s2.cache_dir = _dir
	s2.prefs_path = _prefs
	var http2 := FakeHttp.new()
	s2.http = http2
	ok(not s2.photo_for("steam-deck-lcd").is_empty(), "hit in a new session")
	eq(http2.requests.size(), 0, "fresh manifest: no request")
	s.free()
	s2.free()


func test_other_device_downloads_nothing() -> void:
	var http := FakeHttp.new()
	var body := _photo_bytes()
	_routes(http, body, _manifest(body))
	var s := _svc(http)
	eq(s.photo_for("msi-claw-8-ex"), {}, "no photo for this device")
	eq(http.count(PhotoSvc.RELEASE + "steam-deck-lcd.webp"), 0, "only this device's file is ever fetched")
	s.free()


func test_sha_mismatch_rejected() -> void:
	var http := FakeHttp.new()
	var body := _photo_bytes()
	_routes(http, body, _manifest(body, "b".repeat(64)))
	var s := _svc(http)
	var ready := []
	s.photo_ready.connect(func(id, path): ready.append(id))
	eq(s.photo_for("steam-deck-lcd"), {}, "miss")
	eq(ready.size(), 0, "no photo_ready")
	eq(s.photo_for("steam-deck-lcd"), {}, "still nothing")
	var left := Array(DirAccess.get_files_at(ProjectSettings.globalize_path(_dir))).filter(func(f): return f.ends_with(".webp") or f.ends_with(".part"))
	eq(left, [], "bad download removed")
	s.free()


func test_tampered_cache_file_rejected() -> void:
	var http := FakeHttp.new()
	var body := _photo_bytes()
	_routes(http, body, _manifest(body))
	var s := _svc(http)
	s.photo_for("steam-deck-lcd")
	var path: String = s.photo_for("steam-deck-lcd")["path"]
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("not the photo")
	f.close()
	var s2: Node = PhotoSvc.new()
	s2.cache_dir = _dir
	s2.prefs_path = _prefs
	eq(s2.cached("steam-deck-lcd"), {}, "hash checked on first use")
	ok(not FileAccess.file_exists(path), "tampered file deleted")
	s.free()
	s2.free()


func test_offline_falls_back_to_drawing() -> void:
	var http := FakeHttp.new()
	http.offline = true
	var s := _svc(http)
	eq(s.photo_for("steam-deck-lcd"), {}, "offline -> empty")
	eq(s.photo_for("steam-deck-lcd"), {}, "one try per session, still empty")
	eq(http.count(PhotoSvc.RELEASE + "manifest.json"), 1, "manifest tried once")
	var s2 := _svc(null)
	eq(s2.photo_for("steam-deck-lcd"), {}, "no http at all -> empty")
	s.free()
	s2.free()


func test_setting_off() -> void:
	var http := FakeHttp.new()
	var body := _photo_bytes()
	_routes(http, body, _manifest(body))
	var s := _svc(http)
	ok(PhotoSvc.load_enabled(_prefs), "default on")
	s.photo_for("steam-deck-lcd")
	s.set_enabled(false)
	ok(not PhotoSvc.load_enabled(_prefs), "saved off")
	eq(s.photo_for("steam-deck-lcd"), {}, "off -> empty even when cached")
	var before := http.requests.size()
	s.photo_for("msi-claw-a1m")
	eq(http.requests.size(), before, "off -> nothing downloaded")
	s.set_enabled(true)
	ok(not s.photo_for("steam-deck-lcd").is_empty(), "back on")
	s.free()


# ---- maker images (by link only) ----------------------------------------------

const MAKER_URL := "https://asset-us-store.msi.com/claw.png"
const MAKER_SRC := {"msi-claw-8-ex": {"url": MAKER_URL, "page_url": "https://us-store.msi.com/claw", "maker": "MSI"}}


func _png_bytes() -> PackedByteArray:
	var img := Image.create(32, 20, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.5, 0.2, 0.7))
	return img.save_png_to_buffer()


func _maker_svc(http: Variant) -> Node:
	var s := _svc(http)
	s.maker_sources = MAKER_SRC.duplicate(true)
	return s


func test_maker_sources_follow_the_rules() -> void:
	var rules := {"MSI": {"image_prefixes": ["https://asset-us-store.msi.com/"], "page_domains": ["msi.com"]}}
	var good := {"url": MAKER_URL, "page_url": "https://us-store.msi.com/claw", "maker": "MSI", "checked": "2026-11-09"}
	var doc := {"_makers": rules, "a": {"maker_image": good}}
	for pair in [["url", "https://retailer.example/claw.png"], ["url", "http://asset-us-store.msi.com/claw.png"],
			["page_url", "https://evilmsi.com/x"], ["page_url", "https://review.example/msi"], ["maker", "Nobody"]]:
		var bad := good.duplicate()
		bad[pair[0]] = pair[1]
		doc[str(pair)] = {"maker_image": bad}
	eq(PhotoSvc.parse_maker_sources(doc).keys(), ["a"], "only the entry on the maker's own site survives")
	eq(PhotoSvc.parse_maker_sources({"a": {"maker_image": good}}), {}, "no _makers rules -> nothing")
	var shipped: Dictionary = PhotoSvc.parse_maker_sources(JSON.parse_string(FileAccess.get_file_as_string("res://data/device_photos.json")))
	ok(shipped.size() >= 25, "shipped maker links parse (%d)" % shipped.size())
	ok(not shipped.has("msi-claw-family"), "unknown-model rows keep the drawing")


func test_sniff_image() -> void:
	eq(PhotoSvc.sniff_image(_png_bytes()), "png", "png")
	eq(PhotoSvc.sniff_image(_photo_bytes()), "webp", "webp")
	var img := Image.create(8, 8, false, Image.FORMAT_RGB8)
	eq(PhotoSvc.sniff_image(img.save_jpg_to_buffer()), "jpg", "jpg")
	eq(PhotoSvc.sniff_image("<!doctype html>".to_utf8_buffer()), "", "html refused")


func test_maker_image_downloads_once_and_credits_maker() -> void:
	var http := FakeHttp.new()
	var body := _png_bytes()
	http.route(MAKER_URL, {"bytes": body})
	var s := _maker_svc(http)
	var ready := []
	s.photo_ready.connect(func(id, path): ready.append([id, path]))
	eq(s.photo_for("msi-claw-8-ex"), {}, "first ask is a miss")
	eq(ready.size(), 1, "photo_ready once")
	var got: Dictionary = s.photo_for("msi-claw-8-ex")
	ok(str(got.get("path", "")).ends_with(".png"), "cached with the sniffed type")
	eq(FileAccess.get_file_as_bytes(got["path"]), body, "bytes kept exactly as the maker served them")
	eq(PhotoSvc.credit_line(got["credit"]), "Image: MSI", "credit line")
	eq(got["credit"]["page_url"], "https://us-store.msi.com/claw", "credit links the maker's page")
	eq(http.count(MAKER_URL), 1, "one request")
	eq(http.count(PhotoSvc.RELEASE), 0, "maker rows never ask the photo release")
	var o: Dictionary = http.options[0]
	eq(int(o.get("max_bytes", 0)), PhotoSvc.MAKER_MAX_BYTES, "size cap")
	ok(float(o.get("timeout", 99)) <= 10.0, "short timeout")
	ok(PhotoView.make(got, 200, Callable()) != null, "view builds from the cached file")
	s.free()


func test_maker_refetch_at_most_weekly() -> void:
	var http := FakeHttp.new()
	http.route(MAKER_URL, {"bytes": _png_bytes()})
	var s := _maker_svc(http)
	s.photo_for("msi-claw-8-ex")
	var now := int(Time.get_unix_time_from_system())
	var s2 := PhotoSvc.new()
	s2.cache_dir = _dir
	s2.prefs_path = _prefs
	s2.http = http
	s2.maker_sources = MAKER_SRC.duplicate(true)
	s2.clock = func() -> int: return now + 3 * 24 * 3600
	ok(not s2.photo_for("msi-claw-8-ex").is_empty(), "new session: cached copy shown")
	eq(http.count(MAKER_URL), 1, "under a week old: no request")
	var s3 := PhotoSvc.new()
	s3.cache_dir = _dir
	s3.prefs_path = _prefs
	s3.http = http
	s3.maker_sources = MAKER_SRC.duplicate(true)
	s3.clock = func() -> int: return now + 8 * 24 * 3600
	ok(not s3.photo_for("msi-claw-8-ex").is_empty(), "stale copy still shown")
	eq(http.count(MAKER_URL), 2, "over a week: one background refresh")
	s3.photo_for("msi-claw-8-ex")
	eq(http.count(MAKER_URL), 2, "refresh once per session")
	s.free()
	s2.free()
	s3.free()


func test_maker_refuses_non_images_big_bodies_and_does_not_retry() -> void:
	var http := FakeHttp.new()
	http.route(MAKER_URL, {"text": "<!doctype html><title>moved</title>"})
	var s := _maker_svc(http)
	eq(s.photo_for("msi-claw-8-ex"), {}, "html -> drawing")
	eq(s.photo_for("msi-claw-8-ex"), {}, "still drawing")
	eq(http.count(MAKER_URL), 1, "no retry until next start")
	var left := Array(DirAccess.get_files_at(ProjectSettings.globalize_path(_dir))).filter(func(f): return f.begins_with("maker-"))
	eq(left, [], "nothing cached")
	var big := PackedByteArray(_png_bytes())
	big.resize(PhotoSvc.MAKER_MAX_BYTES + 10)
	var http2 := FakeHttp.new()
	http2.route(MAKER_URL, {"bytes": big})
	var s2 := _maker_svc(http2)
	eq(s2.photo_for("msi-claw-8-ex"), {}, "over 3 MB -> drawing")
	var http3 := FakeHttp.new()
	http3.offline = true
	var s3 := _maker_svc(http3)
	eq(s3.photo_for("msi-claw-8-ex"), {}, "offline -> drawing")
	s3.photo_for("msi-claw-8-ex")
	eq(http3.requests.size(), 1, "offline: one try per session")
	s.free()
	s2.free()
	s3.free()


func test_maker_setting_off_and_free_photo_wins() -> void:
	var http := FakeHttp.new()
	http.route(MAKER_URL, {"bytes": _png_bytes()})
	var s := _maker_svc(http)
	ok(PhotoSvc.load_maker_enabled(_prefs), "default on")
	s.set_maker_enabled(false)
	ok(not PhotoSvc.load_maker_enabled(_prefs), "saved off")
	eq(s.photo_for("msi-claw-8-ex"), {}, "off -> drawing")
	eq(http.requests.size(), 0, "off -> no request to the maker (nor the release)")
	s.set_maker_enabled(true)
	s.set_enabled(false)
	eq(s.photo_for("msi-claw-8-ex"), {}, "real photos off -> drawing")
	eq(http.requests.size(), 0, "real photos off -> no request at all")
	s.set_enabled(true)
	# A device with a free photo never asks the maker, even with a maker entry.
	var body := _photo_bytes()
	_routes(http, body, _manifest(body))
	s.maker_sources = {"steam-deck-lcd": MAKER_SRC["msi-claw-8-ex"]}
	s._free["steam-deck-lcd"] = true
	s.photo_for("steam-deck-lcd")
	ok(not s.photo_for("steam-deck-lcd").is_empty(), "free photo shown")
	eq(http.count(MAKER_URL), 0, "maker not asked when a free photo exists")
	s.free()


# ---- view -----------------------------------------------------------------------

func test_view_shows_credit_or_nothing() -> void:
	eq(PhotoView.make({}, 200, Callable()), null, "no photo -> null, caller keeps the drawing")
	eq(PhotoView.make({"path": "/nonexistent.webp", "credit": CREDIT}, 200, Callable()), null, "missing file -> null")
	var http := FakeHttp.new()
	var body := _photo_bytes()
	_routes(http, body, _manifest(body))
	var s := _svc(http)
	s.photo_for("steam-deck-lcd")
	var opened := []
	var v = PhotoView.make(s.photo_for("steam-deck-lcd"), 200, func(u): opened.append(u))
	ok(v != null, "view built")
	eq(v.credit.text, "Photo: Jane Doe, CC BY-SA 4.0", "credit line")
	v.credit.pressed.emit()
	eq(opened, [CREDIT["page_url"]], "credit opens the Commons page")
	v.free()
	s.free()
	_clean()


# ---- UI hooks (About this device, first-run welcome) ----------------------------

class FakePhoto extends RefCounted:
	signal photo_ready(device_id: String, path: String)
	var enabled := true
	var path := ""
	var asked: Array = []
	func photo_for(id: String) -> Dictionary:
		asked.append(id)
		return {} if path == "" else {"path": path, "credit": CREDIT}
	func set_enabled(on: bool) -> void:
		enabled = on


func _photo_file() -> String:
	_clean()
	var p := ProjectSettings.globalize_path(_dir.path_join("ui.webp"))
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_buffer(_photo_bytes())
	f.close()
	return p


func test_setup_welcome_photo_or_drawing() -> void:
	var SetupFlow: GDScript = load("res://scripts/ui/setup/setup_flow.gd")
	var svc: Dictionary = load("res://tests/test_ui_settings.gd").new()._svc()
	svc["device"].profile["id"] = "msi-claw-8-ex"
	var ph := FakePhoto.new()
	svc["photo"] = ph
	var host := Control.new()
	var f: Control = SetupFlow.open(host, svc, "")
	ok(f.find_child("DevicePhoto", true, false) == null, "no photo -> drawing")
	eq(ph.asked, ["msi-claw-8-ex"], "asked for this device")
	f.finish()
	ph.path = _photo_file()
	f = SetupFlow.open(host, svc, "")
	var v = f.find_child("DevicePhoto", true, false)
	ok(v != null, "photo shown on welcome")
	ok(v != null and v.credit in f.focusables(), "credit reachable with the controller")
	f.finish()
	host.free()
	_clean()


func test_about_panel_photo_or_drawing() -> void:
	var About: GDScript = load("res://scripts/ui/device/about_panel.gd")
	var s: Dictionary = load("res://tests/fixtures/device_ui/fakes.gd").services()
	var ph := FakePhoto.new()
	s["photo"] = ph
	var p: Control = About.build(s)
	ok(p.photo_view == null, "no photo -> drawing")
	ok(p.picture.visible, "drawing visible")
	p.free()
	ph.path = _photo_file()
	p = About.build(s)
	ok(p.photo_view != null, "photo shown")
	ok(not p.picture.visible, "drawing hidden behind the photo")
	ok(p.photo_view.credit in p.focus_chain(), "credit in the focus chain")
	eq(p.hints_for(p.photo_view.credit)[0][0], "A", "A opens the source")
	p.free()
	_clean()
