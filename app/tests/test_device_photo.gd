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
		if e.has("representative"):
			ok(PhotoSvc.parse_representatives(doc).has(id), "%s: representative has a picture" % id)
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
	ok(not shipped.has("msi-claw-family"), "family rows have no link of their own (they borrow a model's)")


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


# ---- families: the maker's representative model, captioned ----------------------

const REP_URL := "https://asset-us-store.msi.com/claw8.png"


func _family_svc(http: Variant) -> Node:
	var s := _svc(http)
	s.maker_sources = {"msi-claw-8-ai-plus": {"url": REP_URL, "page_url": "https://us-store.msi.com/claw8", "maker": "MSI"}}
	s._reps = {"msi-claw-family": "msi-claw-8-ai-plus"}
	return s


func test_family_caption_text() -> void:
	eq(PhotoSvc.family_caption("MSI Claw (unknown model)"), "MSI Claw (model not identified)", "claw")
	eq(PhotoSvc.family_caption("GPD (unknown model)"), "GPD (model not identified)", "gpd")
	eq(PhotoSvc.family_caption("AYANEO"), "AYANEO (model not identified)", "no suffix")


func test_representative_pick_rules() -> void:
	var doc := {"a-family": {"representative": "a1"}, "a1": {"maker_image": {}},
		"b-family": {"representative": "nope"}, "c-family": {"representative": "c-family"},
		"d-family": {"representative": "a-family"}, "e-family": {"representative": "e1"}, "e1": {"note": "no picture"},
		"f-family": {"representative": "f1"}, "f1": {"file": "F1.jpg"}}
	eq(PhotoSvc.parse_representatives(doc), {"a-family": "a1", "f-family": "f1"},
		"only real rows with a picture of their own; no self, chains or missing rows")
	var shipped: Dictionary = PhotoSvc.parse_representatives(JSON.parse_string(FileAccess.get_file_as_string("res://data/device_photos.json")))
	var rows := {}
	for r in load("res://scripts/device/device.gd").load_table():
		rows[r["id"]] = r
	for id in rows:
		if str(id).ends_with("-family"):
			ok(shipped.has(id), "%s has a representative" % id)
			if shipped.has(id):
				eq(rows[shipped[id]]["maker"], rows[id]["maker"], "%s: same maker" % id)
	eq(shipped.get("msi-claw-family"), "msi-claw-8-ai-plus", "MSI Claw family shows the Claw 8 AI+")
	eq(shipped.get("gpd-family"), "gpd-win-4", "GPD family shows the WIN 4")


func test_family_shows_representative_with_caption() -> void:
	var http := FakeHttp.new()
	var body := _png_bytes()
	http.route(REP_URL, {"bytes": body})
	var s := _family_svc(http)
	var ready := []
	s.photo_ready.connect(func(id, _p): ready.append(id))
	eq(s.representative_of("msi-claw-family"), "msi-claw-8-ai-plus", "representative")
	eq(s.representative_of("msi-claw-8-ex"), "msi-claw-8-ex", "exact models stand for themselves")
	eq(s.photo_for("msi-claw-family"), {}, "first ask is a miss")
	ok("msi-claw-family" in ready, "photo_ready for the family id")
	ok("msi-claw-8-ai-plus" in ready, "and for the model fetched")
	var got: Dictionary = s.photo_for("msi-claw-family")
	eq(FileAccess.get_file_as_bytes(got["path"]), body, "the representative's picture")
	eq(got["caption"], "MSI Claw (model not identified)", "caption says the model wasn't recognised")
	eq(got["pictured"], "Pictured: MSI Claw 8 AI+", "and which model is pictured")
	eq(got["family"], {"device_id": "msi-claw-family", "representative": "msi-claw-8-ai-plus"}, "family info")
	eq(PhotoSvc.credit_line(got["credit"]), "Image: MSI", "credit unchanged")
	ok(not s.photo_for("msi-claw-8-ai-plus").has("caption"), "the model itself has no family caption")
	eq(http.count(REP_URL), 1, "one request serves both")
	var v = PhotoView.make(got, 200, Callable())
	ok(v != null and v.caption != null, "view shows the caption")
	ok(v.caption.text.begins_with("MSI Claw (model not identified)"), "caption text")
	ok(v.caption.get_index() < v.credit.get_index(), "caption above the credit")
	v.free()
	s.free()


# ---- prefetch (instant first launch) --------------------------------------------

func test_prefetch_fills_cache_for_offline_start() -> void:
	var http := FakeHttp.new()
	http.route(REP_URL, {"bytes": _png_bytes()})
	var s := _family_svc(http)
	ok(not s.has_cached("msi-claw-family"), "nothing cached yet")
	ok(s.prefetch("msi-claw-family"), "prefetch fetched it")
	ok(s.has_cached("msi-claw-family"), "cached for the family")
	ok(s.has_cached("msi-claw-8-ai-plus"), "and the model")
	eq(http.count(REP_URL), 1, "one image")
	var o: Dictionary = http.options[0]
	eq(int(o.get("max_bytes", 0)), PhotoSvc.MAKER_MAX_BYTES, "same size cap")
	# Next start, offline: the cached photo shows without any request.
	var off := FakeHttp.new()
	off.offline = true
	var s2 := PhotoSvc.new()
	s2.cache_dir = _dir
	s2.prefs_path = _prefs
	s2.http = off
	s2.maker_sources = s.maker_sources.duplicate(true)
	s2._reps = s._reps.duplicate()
	ok(not s2.photo_for("msi-claw-family").is_empty(), "offline start shows the prefetched photo")
	eq(off.requests.size(), 0, "no request while the copy is fresh")
	ok(s2.prefetch("msi-claw-family"), "prefetch with a cached copy: true, nothing to do")
	eq(off.requests.size(), 0, "still no request")
	s.free()
	s2.free()


func test_prefetch_respects_settings_and_failures() -> void:
	var http := FakeHttp.new()
	http.route(REP_URL, {"bytes": _png_bytes()})
	var s := _family_svc(http)
	s.set_maker_enabled(false)
	ok(not s.prefetch("msi-claw-family"), "Show maker photos off: no prefetch")
	eq(http.requests.size(), 0, "and no request")
	s.set_maker_enabled(true)
	s.set_enabled(false)
	ok(not s.prefetch("msi-claw-family"), "real photos off: no prefetch")
	eq(http.requests.size(), 0, "and no request")
	s.set_enabled(true)
	ok(not s.prefetch(""), "no device")
	ok(not s.prefetch("unknown"), "unknown device")
	ok(not s.prefetch("steam-deck-lcd"), "no picture source here: nothing cached")
	var http2 := FakeHttp.new()
	http2.route(REP_URL, {"text": "<html>moved</html>"})
	var s2 := _family_svc(http2)
	ok(not s2.prefetch("msi-claw-family"), "not an image: false, nothing cached")
	ok(not s2.has_cached("msi-claw-family"), "nothing cached")
	var s3 := _family_svc(null)
	ok(not s3.prefetch("msi-claw-family"), "no network object: false")
	s.free()
	s2.free()
	s3.free()


func test_prefetch_detected_without_device_is_harmless() -> void:
	var s := _family_svc(FakeHttp.new())
	ok(not s.prefetch_detected(), "outside the tree / no Device: false")
	s.free()


class FakePrefetch extends RefCounted:
	var asked: Array = []
	func prefetch(id: String) -> bool:
		asked.append(id)
		return true


func test_installer_prefetches_the_photo() -> void:
	var F: GDScript = load("res://tests/fixtures/installer/fakes.gd")
	var Plan: GDScript = load("res://scripts/installer/plan.gd")
	var Screen: GDScript = load("res://scripts/ui/installer/installer_screen.gd")
	var Service: GDScript = load("res://scripts/installer/installer_service.gd")
	var Paths: GDScript = load("res://scripts/installer/paths.gd")
	var Fake: GDScript = load("res://tests/fixtures/system/fake_runner.gd")
	var d := ProjectSettings.globalize_path("user://test_installer_photo")
	DirAccess.make_dir_recursive_absolute(d)
	var dev = F.claw()
	var ph := FakePrefetch.new()
	var svc: Dictionary = F.services(dev, F.FakeSetup.new(), F.Recorder.new(), d + "/power.cfg")
	svc["photo"] = ph
	var tgt: Dictionary = F.target("bazzite")
	var make := func() -> Control:
		var r = Fake.new()
		r.handler = func(cmd: String): return {"code": 1, "out": ""} if cmd.begins_with("pgrep") else {"code": 0, "out": ""}
		var inst: Node = Service.new()
		inst.setup(r, Paths.for_home(d + "/home", d + "/root"), tgt, "/opt/gc/gamecove.x86_64")
		return Screen.create(svc, tgt, Plan.start(tgt, dev.profile, {"theme": "cove"}), inst)
	var scr: Control = make.call()
	eq(ph.asked, [str(dev.profile["id"])], "the installer fetches this handheld's photo while online")
	ok(scr.prefetch_photo(), "prefetch_photo() reports the service's answer")
	scr.free()
	svc.erase("photo")
	var scr2: Control = make.call()
	ok(not scr2.prefetch_photo(), "no photo service (tests, previews): nothing")
	scr2.free()


func test_boot_prefetch_argument() -> void:
	var Boot: GDScript = load("res://scripts/installer/boot.gd")
	ok(Boot.wants_photo_prefetch(PackedStringArray(["--prefetch-photo"])), "--prefetch-photo")
	ok(not Boot.wants_photo_prefetch(PackedStringArray(["--installer"])), "installer is not prefetch")
	eq(Boot.scene_for(PackedStringArray(["--prefetch-photo"])), Boot.MAIN, "scene_for unchanged (prefetch quits before)")


# ---- view: the plain margin is cropped at display time --------------------------

func test_view_crops_plain_margin() -> void:
	var img := Image.create(400, 400, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	img.fill_rect(Rect2i(100, 170, 200, 60), Color(0.1, 0.1, 0.1))
	var r: Rect2i = PhotoView.subject_rect(img)
	ok(r.size.x < 260 and r.size.y < 110, "white margin cropped (%s)" % r)
	ok(r.encloses(Rect2i(100, 170, 200, 60)), "the subject is kept whole")
	var clear := Image.create(300, 300, false, Image.FORMAT_RGBA8)
	clear.fill(Color(0, 0, 0, 0))
	clear.fill_rect(Rect2i(50, 120, 200, 60), Color(0.3, 0.3, 0.3))
	ok(PhotoView.subject_rect(clear).size.y < 100, "transparent margin cropped")
	var photo := Image.create(200, 100, false, Image.FORMAT_RGB8)
	for y in 100:
		for x in 200:
			photo.set_pixel(x, y, Color(float(x) / 200.0, float(y) / 100.0, 0.5))
	eq(PhotoView.subject_rect(photo), Rect2i(0, 0, 200, 100), "a real photo (corners differ) is left alone")
	var p := ProjectSettings.globalize_path(_dir.path_join("margin.png"))
	_clean()
	img.save_png(p)
	var tex := PhotoView.load_trimmed(p)
	ok(tex != null and tex.get_width() < 260, "the view's texture is the cropped one")
	eq(FileAccess.get_file_as_bytes(p).size() > 0, true, "the cached file itself is untouched")
	_clean()


func test_about_panel_family_caption() -> void:
	var About: GDScript = load("res://scripts/ui/device/about_panel.gd")
	var s: Dictionary = load("res://tests/fixtures/device_ui/fakes.gd").services()
	var ph := FakeFamilyPhoto.new()
	ph.path = _photo_file()
	s["photo"] = ph
	var p: Control = About.build(s)
	ok(p.photo_view != null, "photo shown")
	var cap: Label = p.photo_view.find_child("FamilyCaption", true, false)
	ok(cap != null and cap.text.contains("(model not identified)"), "family caption on About")
	p.free()
	_clean()


class FakeFamilyPhoto extends RefCounted:
	signal photo_ready(device_id: String, path: String)
	var enabled := true
	var path := ""
	func photo_for(_id: String) -> Dictionary:
		return {"path": path, "credit": {"kind": "maker", "maker": "MSI", "page_url": "https://www.msi.com/x"},
			"caption": "MSI Claw (model not identified)", "pictured": "Pictured: MSI Claw 8 AI+"}
	func set_enabled(on: bool) -> void:
		enabled = on
