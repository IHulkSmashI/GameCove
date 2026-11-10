extends "showcase.gd"
## The extras: Record in the quick menu (with the REC chip and a controller's
## battery in the top bar), Settings > Media (recorder ready, clips with
## pictures), a clip's sheet and its Send to phone QR page, Home's Apps shelf,
## the Apps view, the Library header's Apps button and Discover's Free to keep
## shelf. Same lived-in profile as showcase.gd; the clips, apps and recorder
## are a fake system in a temp folder (nothing real is installed or run).
##   godot --path app --resolution 1920x1200 -s ../tools/showcase/showcase_extras.gd -- --out DIR [--only a,b]

const SHOTS_EXTRAS := ["quick_record", "settings_media", "media_clip_sheet", "media_share", "home_apps", "apps_view",
	"library_apps", "discover_free"]
const Recorder := preload("res://scripts/system/recorder.gd")
const Clips := preload("res://scripts/system/clips.gd")
const Apps := preload("res://scripts/library/apps.gd")
const FakeRunner := preload("res://tests/fixtures/system/fake_runner.gd")

var fake_home := ""


func _run() -> void:
	OS.low_processor_usage_mode = false
	here = get_script().resource_path.get_base_dir()
	T = load("res://tests/test_ui_screens.gd")
	S = load("res://tests/test_ui_settings.gd")
	now = int(Time.get_unix_time_from_system())
	lib_doc = JSON.parse_string(FileAccess.get_file_as_string(here.path_join("library.json")))
	games = _library()
	ach_svc = ShowcaseAchievements.new()
	ach_svc.name = "ShowcaseAchievements"
	ach_svc.by_appid = _achievements()
	root.add_child(ach_svc)
	fake_home = OS.get_cache_dir().path_join("gamecove-showcase-extras")
	_wipe(fake_home)
	_fake_system()
	var prefs = load("res://scripts/ui/ui_prefs.gd")
	prefs.path = OS.get_cache_dir().path_join("gamecove-showcase-ui.cfg")
	DirAccess.remove_absolute(prefs.path)
	prefs.theme = theme_id()
	prefs.match_art = theme_id() == "cove"
	load("res://scripts/main.gd").boot_splash = false
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await frames(3)
	main._live_timer.stop()
	main._live_timer.wait_time = 9999
	var flow_script = load("res://scripts/ui/setup/setup_flow.gd")
	if flow_script.instance != null:
		flow_script.instance.finish()
	prefs.theme = theme_id()
	prefs.match_art = theme_id() == "cove"
	main.apply_theme()
	var lib := root.get_node("Library")
	for i in 600:
		if int(lib.get("_task")) == -1:
			break
		await process_frame
	var db: Node = lib.get("_db")
	if db != null and db.updated.is_connected(lib.refresh):
		db.updated.disconnect(lib.refresh)
	lib.games.assign(games)
	lib.changed.emit()
	_seed_shots(lib)
	_status()
	await frames(4)
	await _use_device("msi-claw-8-ex", claw_patch())
	_photo()
	_fake_apps()
	await _quick_record()
	await _media()
	await _apps()
	await _discover_free()
	_wipe(fake_home)
	quit()


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(d))
	DirAccess.remove_absolute(dir)


static func _u32(n: int) -> PackedByteArray:
	var b := PackedByteArray([0, 0, 0, 0])
	b.encode_u32(0, n)
	b.reverse()
	return b


static func _box(kind: String, body: PackedByteArray) -> PackedByteArray:
	var out := _u32(body.size() + 8)
	out.append_array(kind.to_ascii_buffer())
	out.append_array(body)
	return out


## A small MP4 whose header says `seconds` (what the Clips list reads) and
## whose size is `mb` (sparse padding).
static func _mp4(path: String, seconds: int, mb: int) -> void:
	var mvhd := PackedByteArray([0, 0, 0, 0])
	for v in [0, 0, 1000, seconds * 1000]:
		mvhd.append_array(_u32(v))
	var pad := PackedByteArray()
	pad.resize(80)
	mvhd.append_array(pad)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(_box("ftyp", "isom\u0000\u0000\u0002\u0000".to_ascii_buffer()))
	var size := mb * 1_000_000
	f.store_buffer(_u32(size + 8))
	f.store_buffer("mdat".to_ascii_buffer())
	f.seek(f.get_position() + size)
	f.store_buffer(_box("moov", _box("mvhd", mvhd)))
	f.close()


## Clips from the showcase library's games, each with its hero art as the picture.
func _fake_system() -> void:
	var root_dir := fake_home.path_join("root")
	DirAccess.make_dir_recursive_absolute(root_dir + Recorder.SYSTEM_APP_DIR)
	DirAccess.make_dir_recursive_absolute(root_dir + "/usr/bin")
	FileAccess.open(root_dir + "/usr/bin/flatpak", FileAccess.WRITE).close()
	var clips := [["1245620", "ELDEN RING", 94, 71, 0], ["1145350", "Hades II", 42, 33, 1], ["1086940", "Baldur's Gate 3", 185, 140, 26],
		["1091500", "Cyberpunk 2077", 61, 47, 50], ["1174180", "Red Dead Redemption 2", 128, 96, 98]]
	for c in clips:
		var when := Time.get_datetime_dict_from_unix_time(now - int(c[4]) * 3600 - 1800)
		var p := Recorder.clip_path(fake_home, str(c[1]), when)
		_mp4(p, int(c[2]), int(c[3]))
		OS.execute("touch", ["-d", "@%d" % (now - int(c[4]) * 3600 - 1800), p])
		var hero := here.path_join("cache").path_join(str(c[0])).path_join("hero.jpg")
		if FileAccess.file_exists(hero):
			Clips.save_thumb(p, Image.load_from_file(hero))


func _media_services() -> void:
	var f: RefCounted = FakeRunner.new()
	f.responses[Recorder.KMS_PROXY + " is-setup " + fake_home] = {"code": 0, "out": ""}
	f.responses["/usr/bin/flatpak list --app --columns=application"] = {"code": 0, "out": Clips.MPV_FLATPAK + "\n"}
	var svc: Dictionary = main.settings.services
	svc["media_runner"] = f
	svc["media_env"] = {"home": fake_home, "path_env": "/usr/bin", "sys_root": fake_home.path_join("root")}
	svc["drop_bind"] = "127.0.0.1"


## Simple original icons (no brand marks) for a handful of everyday apps.
func _fake_apps() -> void:
	var specs := [
		["org.mozilla.firefox", "Firefox", "#FF7139", "<circle cx='32' cy='32' r='20' fill='none' stroke='white' stroke-width='5'/><path d='M12 32h40M32 12c-8 8-8 32 0 40M32 12c8 8 8 32 0 40' stroke='white' stroke-width='4' fill='none'/>"],
		["com.discordapp.Discord", "Discord", "#5865F2", "<path d='M14 20h36v20H30l-10 8v-8h-6z' fill='white'/>"],
		["io.mpv.Mpv", "mpv", "#6A1B9A", "<path d='M24 18v28l22-14z' fill='white'/>"],
		["com.spotify.Client", "Spotify", "#1DB954", "<path d='M18 26c10-4 20-3 28 2M20 33c8-3 16-2 22 2M22 40c6-2 12-1 16 2' stroke='white' stroke-width='4' fill='none' stroke-linecap='round'/>"],
		["org.libretro.RetroArch", "RetroArch", "#4A4A4A", "<rect x='14' y='22' width='36' height='20' rx='10' fill='white'/><circle cx='24' cy='32' r='3' fill='#4A4A4A'/><circle cx='40' cy='32' r='3' fill='#4A4A4A'/>"],
		["org.videolan.VLC", "VLC media player", "#FF8800", "<path d='M32 12l14 36H18z' fill='white'/>"],
		["com.obsproject.Studio", "OBS Studio", "#302E31", "<circle cx='32' cy='32' r='18' fill='white'/><circle cx='32' cy='32' r='7' fill='#302E31'/>"],
		["net.davidotek.pupgui2", "ProtonUp-Qt", "#C2185B", "<path d='M32 14v26M22 30l10 10 10-10M18 48h28' stroke='white' stroke-width='5' fill='none'/>"],
		["org.kde.dolphin", "Dolphin", "#1D99F3", "<path d='M14 22h14l4 4h18v20H14z' fill='white'/>"],
		["com.heroicgameslauncher.hgl", "Heroic Games Launcher", "#0E1A2B", "<path d='M32 12l18 8v12c0 10-8 18-18 20-10-2-18-10-18-20V20z' fill='white'/>"],
		["org.chromium.Chromium", "Chromium", "#4285F4", "<circle cx='32' cy='32' r='20' fill='white'/><circle cx='32' cy='32' r='8' fill='#4285F4'/>"],
		["md.obsidian.Obsidian", "Obsidian", "#7C3AED", "<path d='M32 12l16 14-6 26H22l-6-26z' fill='white'/>"],
	]
	var list: Array = []
	var dir := fake_home.path_join("icons")
	DirAccess.make_dir_recursive_absolute(dir)
	for s in specs:
		var svg := "<svg xmlns='http://www.w3.org/2000/svg' width='64' height='64'><rect width='64' height='64' rx='14' fill='%s'/>%s</svg>" % [s[2], s[3]]
		var img := Image.new()
		img.load_svg_from_buffer(svg.to_utf8_buffer(), 4.0)
		var p := dir.path_join(str(s[0]) + ".png")
		img.save_png(p)
		list.append({"key": "app:" + str(s[0]), "id": s[0], "store": "app", "title": s[1], "exec": ["/usr/bin/flatpak", "run", s[0]],
			"icon": p, "flatpak": s[0], "installed": true, "art": {"icon": p}})
	var pins := fake_home.path_join("apps.json")
	for i in [1, 3, 0, 2]:
		Apps.set_pinned(list[i], true, pins)
	main.home.set_apps(Apps.pinned(pins))
	main.set_meta("fake_apps", list)
	main.set_meta("fake_pins", pins)


## The render machine has no UPower: show a DualSense at 62 % (after main's own read).
func _pads() -> void:
	main.top_bar.set_pads([{"name": "DualSense Wireless Controller", "percent": 62, "charging": false}])


func _quick_record() -> void:
	if not want(["quick_record"]):
		return
	var qm = main.quick_menu
	var g := _find_key("steam:1245620")
	var sess = S.FakeSession.new()
	root.add_child(sess)
	qm.attach_session(sess)
	main.show_screen("home")
	await frames(3)
	main.playing = g
	sess.started.emit(g)
	qm._session_start_ms = Time.get_ticks_msec() - 47 * 60 * 1000
	var rec = main.recording
	rec.env = {"home": fake_home, "path_env": "/usr/bin", "sys_root": fake_home.path_join("root"), "proc_root": fake_home}
	rec.state = "recording"
	rec._started_ms = Time.get_ticks_msec() - 83 * 1000
	main.top_bar.set_recording(true)
	main._open_menu()
	qm.game = g
	await _open_quick(g, 0)
	var row: Node = qm.body.find_child("Record", true, false)
	if row != null:
		row.button.grab_focus()
	await frames(6)
	_pads()
	await shot("quick_record")
	qm.close()
	rec.state = "idle"
	main.top_bar.set_recording(false)
	main.playing = {}
	await frames(3)


func _media() -> void:
	if not (want(["settings_media"]) or want(["media_clip_sheet"]) or want(["media_share"])):
		return
	_media_services()
	main.show_screen("settings")
	await frames(4)
	var st = main.settings
	st.open_category("media")
	await frames(4)
	var page = st.pages["media"]
	for i in 200:
		if page.busy == "":
			break
		await process_frame
	await frames(6)
	if not page.clip_rows.is_empty():
		page.clip_rows[0].button.grab_focus()
	await frames(8)
	_pads()
	await shot("settings_media")
	if not page.clip_rows.is_empty() and want(["media_clip_sheet"]):
		page.open_clip(page.clip_rows[0].clip)
		await frames(12)
		await shot("media_clip_sheet")
		page.sheet.close()
		await frames(4)
	if not page.clip_rows.is_empty() and want(["media_share"]):
		page.share_clip(page.clip_rows[0].clip)
		await frames(2)
		if page.share != null and page.share.drop.is_running():
			page.share.qr_rect.texture = load("res://scripts/ui/settings/qr.gd").texture(page.share.drop.url.replace("127.0.0.1", LAN_IP), 6)
		await frames(12)
		await shot("media_share")
		page.share.close()
	main.show_screen("home")
	await frames(4)


func _apps() -> void:
	if want(["home_apps"]):
		main.show_screen("home")
		await frames(4)
		var row: Node = main.home.find_child("Row_apps", true, false)
		if row != null and not row.tiles.is_empty():
			row.tiles[0].grab_focus()
		await frames(10)
		_pads()
		await shot("home_apps")
	if want(["apps_view"]):
		main.open_apps()
		main.apps_view.pins_path = main.get_meta("fake_pins")
		var list: Array = main.get_meta("fake_apps")
		main.apps_view.scan_fn = func() -> Array: return list
		main.apps_view.loading = false
		main.apps_view.open()
		for i in 120:
			if not main.apps_view.loading:
				break
			await process_frame
		await frames(6)
		if main.apps_view.tiles.size() > 5:
			main.apps_view.tiles[5].grab_focus()
		await frames(8)
		main._update_hints()
		await frames(2)
		await shot("apps_view")
		main.close_apps()
		await frames(4)
	if want(["library_apps"]):
		main.show_screen("library")
		await frames(6)
		main.library_screen.apps_button.grab_focus()
		await frames(6)
		await shot("library_apps")
		main.show_screen("home")
		await frames(3)


func _discover_free() -> void:
	if not want(["discover_free"]):
		return
	var d: Node = root.get_node("Discover")
	var stores: Dictionary = d.get("_cache").get("stores", {})
	var free := [
		{"deal_id": "showcase-free-1", "store_id": "25", "game_id": "1", "appid": "821250", "title": "Flotsam", "price": 0.0, "regular_price": 24.99, "savings_pct": 100, "rating": null, "thumb": "", "released": 0},
		{"deal_id": "showcase-free-2", "store_id": "7", "game_id": "2", "appid": "", "title": "Ghost of a Tale", "price": 0.0, "regular_price": 19.99, "savings_pct": 100, "rating": null, "thumb": "", "released": 0},
		{"deal_id": "showcase-free-3", "store_id": "25", "game_id": "3", "appid": "1145360", "title": "Hades", "price": 0.0, "regular_price": 24.99, "savings_pct": 100, "rating": null, "thumb": "", "released": 0},
	]
	d.get("_cache")["free"] = free
	if stores.is_empty():
		d.get("_cache")["stores"] = {"25": {"name": "Epic Games Store", "active": true, "icon": ""}, "7": {"name": "GOG", "active": true, "icon": ""}}
	d._rebuild_deals()
	d.deals_changed.emit()
	main.show_screen("discover")
	await frames(10)
	var home_view: Node = main.discover.find_child("Home", true, false)
	if home_view != null:
		for s in home_view.shelves:
			if s.id == "free" and not s.tiles.is_empty():
				s.tiles[0].grab_focus()
	await frames(14)
	await shot("discover_free")
	main.show_screen("home")
