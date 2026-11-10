extends SceneTree
## Renders named GameCove screens with a fake library to PNGs.
## Needs a display (use shoot.sh, which wraps xvfb-run).
##
##   godot --path app --resolution 1280x800 -s ../tools/screenshots/shoot.gd -- \
##       --out /tmp/shots [--only home,library] [--suffix _1920] [--theme cove]
##
## Art is painted here procedurally (gradients, shapes, the title in Inter),
## never downloaded, so the shots look real without using anyone's game art.


var out := "/tmp/gamecove-shots/"
var only: Array = []
var suffix := ""
var art_dir := "/tmp/gamecove-shots/art/"
var main: Control
var games: Array = []
var T: GDScript
var F: GDScript
var S: GDScript
var _home_ach: Node


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		match args[i]:
			"--out": out = args[i + 1].trim_suffix("/") + "/"
			"--only": only = Array(args[i + 1].split(","))
			"--suffix": suffix = args[i + 1]
	_run.call_deferred()


func frames(n: int) -> void:
	for i in n:
		await process_frame


func settle() -> void:
	# Wait for art loads and tweens to finish.
	for i in 90:
		await process_frame
		var AC = load("res://scripts/ui/art_cache.gd")
		if AC.pending_count() == 0 and i > 20:
			break
	await frames(30)


func shot(name: String) -> void:
	if not only.is_empty() and name not in only:
		return
	await settle()
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(out)
	root.get_texture().get_image().save_png(out + name + suffix + ".png")
	print("saved ", out + name + suffix + ".png")


func want(names: Array) -> bool:
	if only.is_empty():
		return true
	for n in names:
		if n in only:
			return true
	return false


func press(action: String) -> void:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	Input.parse_input_event(e)
	await frames(2)
	e = InputEventAction.new()
	e.action = action
	e.pressed = false
	Input.parse_input_event(e)
	await frames(4)


func _run() -> void:
	OS.low_processor_usage_mode = false
	T = load("res://tests/test_ui_screens.gd")
	F = load("res://tests/test_ui_device_fixes.gd")
	var painter: GDScript = load(get_script().resource_path.get_base_dir().path_join("painter.gd"))
	DirAccess.make_dir_recursive_absolute(art_dir)
	games = await painter.make_library(self, art_dir)
	# Fresh prefs: Cove theme, art colours on.
	var prefs = load("res://scripts/ui/ui_prefs.gd")
	prefs.path = "/tmp/gamecove-shots/ui.cfg"
	DirAccess.remove_absolute(prefs.path)

	load("res://scripts/main.gd").boot_splash = false
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await frames(3)
	main._live_timer.stop()   # keep the fake status numbers on screen
	main._live_timer.wait_time = 9999
	# First-run setup would open over every shot; it has its own shots below.
	var flow_script = load("res://scripts/ui/setup/setup_flow.gd")
	if flow_script.instance != null:
		flow_script.instance.finish()
	S = load("res://tests/test_ui_settings.gd")
	if get_script().resource_path.get_file() == "shoot.gd":
		_fake_controls()
	if want(["home_empty"]):
		_status()
		await frames(2)
		await shot("home_empty")
	var lib := root.get_node("Library")
	lib.games.assign(games)
	lib.changed.emit()
	_status()
	# SHOOT_THEME=midnight|sunset|light: the default shot list in that theme
	# (pair with --only; the theme_* shots switch themes themselves).
	var th := OS.get_environment("SHOOT_THEME")
	if th != "" and get_script().resource_path.get_file() == "shoot.gd":
		prefs.theme = th
		prefs.match_art = th != "light"
		main.apply_theme()
	await frames(4)
	main.home.play_button.grab_focus()
	await shot("home")

	if want(["home_focus", "home_focus2"]):
		await press("ui_down")
		await press("ui_right")
		await press("ui_right")
		await shot("home_focus")
		await press("ui_down")
		await press("ui_right")
		await shot("home_focus2")
		main.home.play_button.grab_focus()

	if want(["library", "library_search"]):
		main.show_screen("library")
		await frames(4)
		var t: Array = main.library_screen.tiles()
		if t.size() > 9:
			t[9].grab_focus()
		await shot("library")
		if want(["library_search"]):
			main.library_screen.open_search()
			for ch in "dr":
				main.library_screen.keyboard.type(ch)
			await shot("library_search")
			main.library_screen.keyboard.close()
		main.show_screen("home")

	if want(["discover"]):
		main.show_screen("discover")
		await shot("discover")
		main.show_screen("home")

	var dshots := ["discover_home", "discover_home_focus", "discover_deals", "discover_deals_store", "discover_calendar",
		"discover_calendar_month", "discover_wishlist", "discover_import", "discover_page", "discover_page_prices",
		"discover_page_upcoming", "discover_toast", "discover_offline", "discover_calendar_empty", "discover_wishlist_empty",
		"discover_light", "discover_midnight_page"]
	if want(dshots):
		await _discover_shots(lib)

	if want(["settings"]):
		main.show_screen("settings")
		await frames(4)
		await shot("settings")
		main.show_screen("home")

	await _settings_shots()

	if want(["game_page", "game_page_settings"]):
		main._open_page(games[0])
		await shot("game_page")
		if want(["game_page_settings"]):
			# The Game settings card's switch (launch settings show once it's on).
			var gs: Node = main.page.game_settings
			if gs != null and gs.toggle != null:
				gs.toggle.button.grab_focus()
			else:
				main.page.form.focusables()[1].grab_focus()
			await frames(6)
			await shot("game_page_settings")
		main._close_page()

	if want(["game_no_art"]):
		var bare: Dictionary = {}
		for g in games:
			if g["art"]["cover"] == "" and g["art"]["hero"] == "":
				bare = g
				break
		main._open_page(bare)
		await shot("game_no_art")
		main._close_page()

	if want(["quick_game", "quick_power", "quick_screen", "quick_device"]):
		var qm = main.quick_menu
		var fp = T.FakePower.new()
		fp.supported = {"tdp": true, "profiles": true, "charge_limit": true, "fan": true}
		var gs = T.FakeGamescope.new()
		gs.running = true
		var dev = T.FakeDevice.new()
		dev.profile["fixes"] = ["claw8ex-buttons", "claw8ex-vrr", "claw8ex-gyro", "fan", "charge-limit"]
		var r = F.FakeRunner.new()
		r.states = {"claw8ex-buttons": "on", "claw8ex-vrr": "off", "claw8ex-gyro": "restart"}
		qm.power = fp
		qm.gamescope = gs
		qm.device = dev
		qm.commands.runner = r
		qm.fixes = F.FakeFixes.new()
		qm.fixes.list = [{"id": "a", "status": "applied"}, {"id": "b", "status": "applied"}, {"id": "c", "status": "available"}]
		main._open_menu()
		await shot("quick_game")
		qm.show_section(1)
		await frames(2)
		await press("ui_down")
		await shot("quick_power")
		qm.show_section(2)
		await shot("quick_screen")
		qm.show_section(5)
		await frames(20)
		qm.show_section(5)
		await shot("quick_device")
		qm.close()

	if want(["launch"]):
		main.launch_overlay.show_for(games[1], main.backdrop.current_accent())
		await shot("launch")
		main.launch_overlay.finish()

	if want(["toast", "status"]):
		main.toast("Gyro aiming installed", "check", "good", "Shut down fully, then turn it back on.")
		main.toast("Paper Lanterns is 60% off", "tag", "sale", "Wishlist price drop, today only.")
		await shot("toast")
		for c in main.toasts.get_children():
			c.free()
		main._open_status()
		await shot("status")
		main.status_panel.close()

	await _games_shots()

	for id in ["midnight", "sunset", "light", "cove"]:
		if not want(["theme_" + id, "theme_%s_page" % id, "theme_%s_quick" % id]):
			continue
		prefs.theme = id
		# Show each theme's own accent; Cove keeps colours from the art.
		prefs.match_art = id == "cove"
		main.apply_theme()
		main.show_screen("home")
		await frames(4)
		var tl: Array = main.home.tiles("recent")
		if tl.size() > 1:
			tl[1].grab_focus()
		await shot("theme_" + id)
		if want(["theme_%s_page" % id]):
			main._open_page(games[1])
			await shot("theme_%s_page" % id)
			main._close_page()
		if want(["theme_%s_quick" % id]):
			main._open_menu()
			main.quick_menu.show_section(1)
			await shot("theme_%s_quick" % id)
			main.quick_menu.close()
	if want(["boot"]):
		# The splash at its hold point (not started, so it stays put).
		var sp: Control = load("res://scripts/ui/boot_splash.gd").new()
		main.add_child(sp)
		await shot("boot")
		sp.queue_free()
	await finish()


## Free main and every static cache before quitting, or the engine aborts at
## exit (textures and fonts held in static vars outlive the renderer).
func finish() -> void:
	if main != null and is_instance_valid(main):
		main.get_parent().remove_child(main)
		main.free()   # _exit_tree -> release_caches(), waits for art workers
	load("res://scripts/main.gd").release_caches()
	load("res://scripts/ui/ui_kit.gd")._art_cache.clear()
	# Background work (library scans, art decodes) must end before the engine does.
	for n in root.get_children():
		var t: Variant = n.get("_task")
		if t is int and t >= 0:
			WorkerThreadPool.wait_for_task_completion(t)
			n.set("_task", -1)
	await frames(4)
	quit(0)


## Settings pages, sign-in, credits, first-run setup and the quick menu
## additions, on fake services with realistic values.
func _settings_shots() -> void:
	var names := ["settings_appearance", "settings_stores", "settings_signin", "settings_discover", "settings_performance",
		"settings_device", "settings_about", "settings_credits", "setup_welcome", "setup_theme", "setup_stores",
		"setup_signin", "setup_keys", "setup_fixes", "setup_done", "quick_perf", "quick_session", "quick_device_partial",
		"settings_light", "setup_light"]
	if not want(names):
		return
	var svc := {"setup": S.FakeSetup.new(), "library": S.FakeLibrary.new(), "discover": S.FakeDiscover.new(),
		"perf": S.FakePerf.new(), "achievements": S.FakeAchievements.new(), "device": _claw_device()}
	svc["controls"] = root.get_node_or_null("Controls")
	svc["library"].s["steam_cef"] = true
	svc["library"].s["steam_cef_status"] = "ready"
	svc["library"].s["steam_pending_count"] = 1
	svc["discover"].s["ggdeals_key"] = "a1B2c3D4e5F6g7H8"
	svc["setup"].done = {"welcome": true, "theme": true}
	svc["setup"].skipped = {"steamgriddb": true}
	svc["perf"].level = 1
	svc["perf"].needs_overlay = true
	var st = main.settings
	st.set_services(svc)
	main.show_screen("settings")
	await frames(4)
	var pages := {"settings_appearance": "appearance", "settings_stores": "stores", "settings_discover": "discover",
		"settings_performance": "performance", "settings_device": "device", "settings_about": "about"}
	for n in pages:
		if not want([n]) and not (n == "settings_stores" and want(["settings_signin"])) and not (n == "settings_about" and want(["settings_credits"])):
			continue
		st.cat_buttons[pages[n]].grab_focus()
		await frames(2)
		if pages[n] != "device":
			st.enter_page()
			if pages[n] == "stores":
				st.pages["stores"].rows["store_epic"].button.grab_focus()
			elif pages[n] == "discover":
				st.pages["discover"].rows["country"].button.grab_focus()
			elif pages[n] == "performance":
				# The Controls-built page has no "overlay" row of its own:
				# its first row (the overlay control) then.
				var pp = st.pages["performance"]
				if "rows" in pp and pp.rows.has("overlay"):
					pp.rows["overlay"].button.grab_focus()
				elif not pp.focusables().is_empty():
					pp.focusables()[0].grab_focus()
			elif pages[n] == "about":
				st.pages["about"].rows["setup_keys"].button.grab_focus()
		await shot(n)
		if pages[n] == "stores" and want(["settings_signin"]):
			st.open_sign_in("epic")
			await shot("settings_signin")
			st.close_sheet()
		if pages[n] == "about" and want(["settings_credits"]):
			st.open_credits()
			await shot("settings_credits")
			st.close_sheet()
	if want(["settings_light", "setup_light"]):
		var prefs = load("res://scripts/ui/ui_prefs.gd")
		prefs.theme = "light"
		prefs.match_art = false
		main.apply_theme()
		await frames(2)
		if want(["settings_light"]):
			st.cat_buttons["stores"].grab_focus()
			await frames(2)
			st.enter_page()
			await shot("settings_light")
		if want(["setup_light"]):
			var fl = load("res://scripts/ui/setup/setup_flow.gd").open(main, svc, "fixes")
			await shot("setup_light")
			fl.finish()
		prefs.theme = "cove"
		prefs.match_art = true
		main.apply_theme()
		await frames(2)
	main.show_screen("home")

	var flow_script = load("res://scripts/ui/setup/setup_flow.gd")
	var setup_shots := {"setup_welcome": "welcome", "setup_theme": "theme", "setup_stores": "stores", "setup_keys": "keys", "setup_fixes": "fixes", "setup_done": "done"}
	for n in setup_shots:
		if not want([n]) and not (n == "setup_stores" and want(["setup_signin"])):
			continue
		var f = flow_script.open(main, svc, setup_shots[n])
		f.go(setup_shots[n])
		await frames(4)
		if setup_shots[n] == "theme":
			f.focusables()[0].grab_focus()
		await shot(n)
		if setup_shots[n] == "stores" and want(["setup_signin"]):
			f.open_sign_in("epic")
			await shot("setup_signin")
		f.finish()
		await frames(2)

	if want(["quick_perf", "quick_session", "quick_device_partial"]):
		var qm = main.quick_menu
		var fp = S.FakeAutoPower.new()
		fp.supported = {"tdp": true, "profiles": true, "charge_limit": true, "fan": true}
		var gs = T.FakeGamescope.new()
		gs.running = true
		qm.power = fp
		qm.gamescope = gs
		qm.perf = svc["perf"]
		qm.device = T.FakeDevice.new()
		var sess = S.FakeSession.new()
		qm.attach_session(sess)
		if not qm.exit_game_requested.is_connected(_noop):
			qm.exit_game_requested.connect(_noop)
		main.playing = games[0]
		sess.started.emit(games[0])
		qm._session_start_ms = Time.get_ticks_msec() - 47 * 60 * 1000
		main._open_menu()
		if want(["quick_session"]):
			qm.show_section(0)
			await frames(2)
			qm.focusables()[-1].grab_focus()
			await shot("quick_session")
		if want(["quick_perf"]):
			qm.show_section(1)
			qm._on_autotune_limit(true, {"cant_reach": true, "target_fps": 60, "ceiling_w": 15.0, "tdp_max": 30.0})
			await frames(2)
			qm.focusables()[-1].grab_focus()
			await shot("quick_perf")
		if want(["quick_device_partial"]):
			qm.device.profile = {"id": "lenovo-legion-go-2", "name": "Lenovo Legion Go 2", "maker": "Lenovo",
				"chip": "AMD Ryzen Z2 Extreme", "gpu": "Radeon 890M-class (RDNA 3.5)", "panel_hz": [30, 144],
				"support": "partial", "unverified": ["tdp", "charge_limit", "panel.vrr"]}
			# The fake Controls are a Claw's: What works comes from the Legion's row.
			var claw_controls = qm.controls
			qm.controls = null
			qm.show_section(5)
			await shot("quick_device_partial")
			qm.controls = claw_controls
		qm.close()
		main.playing = {}


## The Device service with a fully resolved Claw 8 EX info() (About this device).
func _claw_device() -> Node:
	var here: String = get_script().resource_path.get_base_dir()
	var d: Node = load(here.path_join("shoot_controls.gd")).ClawDevice.new()
	d.name = "ShotDevice"
	d.data = load("res://tests/fixtures/device_ui/fakes.gd").claw_info()
	root.add_child(d)
	return d


## A set-up Claw 8 EX's Controls (shoot_controls.gd's snapshot and patch) in
## place of the real registry, which finds nothing on the build machine and
## would leave the quick menu and the Handheld settings pages empty.
func _fake_controls() -> void:
	var old := root.get_node_or_null("Controls")
	if old != null:
		old.name = "ControlsReal"
	var fc: Node = load("res://tests/fixtures/ui_controls/fake_controls.gd").new()
	fc.name = "Controls"
	var here: String = get_script().resource_path.get_base_dir()
	fc.load_snapshot("res://tests/fixtures/ui_controls/msi-claw-8-ex.json", load(here.path_join("shoot_controls.gd")).claw_patch())
	root.add_child(fc)
	main.quick_menu.use_controls(fc, null)
	var svc: Dictionary = main.settings.services.duplicate()
	svc["controls"] = fc
	main.settings.set_services(svc)


func _noop(_g = null) -> void:
	pass


func _status() -> void:
	main.top_bar.set_status("MSI Claw 8 EX AI+", {"percent": 72, "status": "Discharging", "watts": 9.4}, "2:05 PM", {"connected": true, "strength": 0.8})
	main.top_bar.set_telemetry({"tdp_w": 17.0, "profile": "balanced", "temp_c": 58.0})
	main.home.set_battery_left("~2 h 45 min")
	main.hint_status.text = "● GameCove 0.4   MSI Claw 8 EX AI+"
	if _home_ach == null:
		_home_ach = load("res://tests/test_ui_games.gd").FakeAchievements.new()
		_home_ach.data = _ach_data()
		root.add_child(_home_ach)
		# One service for Home and the game page (main.set_achievements), as in the app.
		main.set_achievements(_home_ach)
	main.status_panel.set_battery("MSI Claw 8 EX AI+", {"percent": 72, "status": "Discharging", "watts": 9.4, "time_left_min": 214})


# ------------------------------------------------------------ games (s-games)

const GAME_SHOTS := ["games_library", "games_home", "games_page", "games_page_achievements", "games_page_downloading",
	"games_manage", "games_install", "games_launch_options", "games_compat", "games_downloads", "games_downloads_empty",
	"games_steam", "games_toasts", "games_page_light", "games_downloads_midnight"]


## A small round achievement icon painted here (no game art is used).
func _ach_icon(path: String, a: Color, b: Color) -> String:
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var d := Vector2(x - 31.5, y - 31.5).length() / 32.0
			var c := a.lerp(b, clampf(float(y) / 64.0 + d * 0.3, 0.0, 1.0))
			if d > 0.62 and d < 0.72:
				c = c.lightened(0.35)
			img.set_pixel(x, y, c)
	img.save_png(path)
	return path


func _ach_data() -> Dictionary:
	var specs := [["First Light", "Finish the prologue.", true, 1762000000, 81.2], ["Tide Turner", "Win a storm fight without taking damage.", true, 1762400000, 23.5],
		["Deep Diver", "Reach the trench floor.", true, 1762500000, 8.4], ["Shell Collector", "Find 50 shells.", false, 0, 31.0],
		["Lighthouse Keeper", "Relight every lighthouse.", true, 1762550000, 3.1], ["Night Swim", "Swim across the bay at night.", false, 0, 12.7],
		["Old Friends", "Meet the ferryman again.", true, 1762580000, 44.0], ["Master Angler", "Catch every fish.", false, 0, 2.2],
		["Silent Running", "Cross the reef unseen.", false, 0, 17.9], ["Storm Chaser", "Survive five storms.", true, 1762590000, 15.0],
		["", "", false, 0, 0.9], ["", "", false, 0, 1.4], ["Cartographer", "Map the whole coast.", false, 0, 9.3], ["Homecoming", "See the ending.", false, 0, 38.6]]
	var cols := [["#2B8C9E", "#0B2B4A"], ["#F7D58B", "#C46A2B"], ["#B8A6FF", "#3B2A7A"], ["#7FB069", "#1F3A24"], ["#FF9E40", "#C2185B"]]
	var items: Array = []
	var unlocked := 0
	for i in specs.size():
		var sp: Array = specs[i]
		var c: Array = cols[i % cols.size()]
		var icon := _ach_icon(art_dir + "ach_%d.png" % i, Color(c[0]), Color(c[1]))
		var hidden: bool = sp[0] == ""
		items.append({"id": "a%d" % i, "name": sp[0] if not hidden else "Secret %d" % i, "description": sp[1], "hidden": hidden,
			"icon": icon, "icon_gray": icon, "unlocked": sp[2], "unlock_time": sp[3], "rarity": sp[4]})
		if sp[2]:
			unlocked += 1
	return {"appid": "1077", "unlocked": unlocked, "total": items.size(), "source": "steam-local", "items": items}


func _find(title: String) -> Dictionary:
	for g in games:
		if g["title"] == title:
			return g
	return {}


func _games_shots() -> void:
	if not want(GAME_SHOTS):
		return
	var GT = load("res://tests/test_ui_games.gd")
	var lib = GT.FakeLibrary.new()
	root.add_child(lib)
	var ach = GT.FakeAchievements.new()
	ach.data = _ach_data()
	root.add_child(ach)
	lib.locations.assign([{"path": "/home/deck/Games", "label": "Internal", "free": 189 * 1073741824, "removable": false},
		{"path": "/run/media/deck/Sandisk512/Games", "label": "Sandisk512", "free": 412 * 1073741824, "removable": true}])
	lib.pending = 1
	lib.opts = "PROTON_LOG=1 %command%"
	main.use_store_api(lib, ach)
	var kingdom := _find("Kingdom of Ash")
	var iron := _find("Iron Meridian")
	var sky := _find("Sky Harbor")
	var hollow := _find("Hollow Tide")
	var glacier := _find("Glacier Protocol")
	var now := int(Time.get_unix_time_from_system())
	lib.queue.assign([
		{"key": kingdom["key"], "action": "install", "title": kingdom["title"], "state": "running", "progress": {}, "error": "", "size": 13314398617},
		{"key": iron["key"], "action": "install", "title": iron["title"], "state": "queued", "progress": {}, "error": "", "size": 41875931136},
	])
	lib.queue_changed.emit()
	lib.download_progress.emit(kingdom["key"], 6012954214, 13314398617, 24221286.0, 301)
	lib.install_state_changed.emit(glacier["key"], "update_required")
	main.install_state.clock = func() -> int: return now
	main.install_state.done = [{"key": hollow["key"], "title": hollow["title"], "action": "update", "ok": true, "message": "", "at": now - 240},
		{"key": _find("Northbound")["key"], "title": "Northbound", "action": "verify", "ok": true, "message": "", "at": now - 1900}]
	main.install_state.changed.emit()
	await frames(4)

	if want(["games_library"]):
		main.show_screen("library")
		await frames(4)
		for t in main.library_screen.tiles():
			if t.game["key"] == kingdom["key"]:
				t.grab_focus()
		await shot("games_library")
		main.show_screen("home")

	if want(["games_home"]):
		main.show_screen("home")
		await frames(4)
		var t = main.home.tile_for(kingdom["key"])
		if t != null:
			t.grab_focus()
		await shot("games_home")
		main.home.play_button.grab_focus()

	if want(["games_page", "games_page_achievements", "games_manage", "games_launch_options", "games_compat"]):
		main._open_page(hollow)
		await frames(4)
		await shot("games_page")
		if want(["games_page_achievements"]):
			main.page.ach_card.cells[2].grab_focus()
			await frames(10)
			await shot("games_page_achievements")
			main.page.play_button.grab_focus()
		if want(["games_manage"]):
			main.page.manage_button.grab_focus()
			main.game_actions.manage(main.page.game)
			await frames(2)
			main.game_actions.sheet.rows[1].grab_focus()
			await shot("games_manage")
			main.game_actions.sheet.close()
		if want(["games_launch_options"]):
			main.game_actions.launch_options(main.page.game)
			await shot("games_launch_options")
			main.game_actions.keyboard.close()
			lib.opts = "PROTON_LOG=1 %command%"
		if want(["games_compat"]):
			lib.tool = "proton_9"
			main.game_actions.compat_tool(main.page.game)
			await shot("games_compat")
			main.game_actions.sheet.close()
		main._close_page()

	if want(["games_page_downloading"]):
		main._open_page(kingdom)
		await shot("games_page_downloading")
		main._close_page()

	if want(["games_install"]):
		main._open_page(sky)
		await frames(2)
		main.game_actions.install(main.page.game)
		await shot("games_install")
		main.game_actions.sheet.close()
		main._close_page()

	if want(["games_downloads", "games_downloads_midnight"]):
		main.open_downloads()
		await frames(4)
		await shot("games_downloads")
		if want(["games_downloads_midnight"]):
			var prefs = load("res://scripts/ui/ui_prefs.gd")
			prefs.theme = "midnight"
			prefs.match_art = false
			main.apply_theme()
			main.downloads_view.refresh()
			await shot("games_downloads_midnight")
			prefs.theme = "cove"
			prefs.match_art = true
			main.apply_theme()
		main.close_downloads()

	if want(["games_steam"]):
		main._on_external_window(iron["key"], "steam", "install")
		await shot("games_steam")
		main.steam_overlay.close()

	if want(["games_toasts"]):
		for c in main.toasts.get_children():
			c.free()
		main._on_autotune_limit(true, {"target_fps": 60, "ceiling_w": 15.0, "tdp_max": 30.0})
		lib.action_failed.emit(iron["key"], "install", "Not enough free space on the SD card.")
		await shot("games_toasts")
		for c in main.toasts.get_children():
			c.free()

	if want(["games_page_light"]):
		var prefs = load("res://scripts/ui/ui_prefs.gd")
		prefs.theme = "light"
		prefs.match_art = false
		main.apply_theme()
		main._open_page(hollow)
		await shot("games_page_light")
		main._close_page()
		prefs.theme = "cove"
		prefs.match_art = true
		main.apply_theme()

	if want(["games_downloads_empty"]):
		lib.queue.clear()
		main.install_state.done = []
		lib.queue_changed.emit()
		main.open_downloads()
		await shot("games_downloads_empty")
		main.close_downloads()


## Discover with fake services (tools/screenshots/discover_fake.gd).
func _discover_shots(lib: Node) -> void:
	var DF: GDScript = load(get_script().resource_path.get_base_dir().path_join("discover_fake.gd"))
	var fk: Dictionary = await DF.make(self, art_dir)
	var d = fk["discover"]
	root.add_child(d)
	var svc := {"library": lib, "open_game": main._open_page, "toast": main.toast, "discover": d, "art": fk["art"], "prefs_path": "", "clock": DF.now}
	main.discover.setup(svc)
	main.show_screen("discover")
	var r = main.discover.content
	await frames(4)
	await shot("discover_home")
	if want(["discover_home_focus"]):
		var h = r.sections["home"]
		h.shelves[0].tiles[1].grab_focus()
		await shot("discover_home_focus")
		h.primary.grab_focus()
	if want(["discover_deals", "discover_deals_store"]):
		r.show_section("deals")
		await frames(4)
		r.sections["deals"].rows[0].grab_focus()
		await shot("discover_deals")
		if want(["discover_deals_store"]):
			r.sections["deals"].sort_row.button.grab_focus()
			r.sections["deals"].sort_row.step(1)
			await frames(4)
			await shot("discover_deals_store")
	if want(["discover_calendar", "discover_calendar_month"]):
		r.show_section("calendar")
		var cal = r.sections["calendar"]
		cal.set_layout("list")
		await frames(4)
		cal.rows[1][0].grab_focus()
		await shot("discover_calendar")
		if want(["discover_calendar_month"]):
			cal.set_layout("month")
			await frames(4)
			cal.day_buttons[13].grab_focus()
			await shot("discover_calendar_month")
			cal.set_layout("list")
	if want(["discover_wishlist", "discover_import"]):
		r.show_section("wishlist")
		await frames(4)
		r.sections["wishlist"].rows[0].grab_focus()
		await shot("discover_wishlist")
		if want(["discover_import"]):
			var w = r.sections["wishlist"]
			w.open_import()
			w._open_keyboard()
			for ch in "robin_walker":
				w.keyboard.type(ch)
			await shot("discover_import")
			w.keyboard.close()
			w.close_import()
	if want(["discover_page", "discover_page_prices"]):
		r.show_section("home")
		await frames(2)
		r.open_page(r.sections["home"].shelves[0].tiles[0].game)
		await shot("discover_page")
		if want(["discover_page_prices"]):
			r.page.price_rows[0].grab_focus()
			await frames(20)
			await shot("discover_page_prices")
		r.close_page()
	if want(["discover_page_upcoming"]):
		var rel = d.calendar[2]
		r.open_page(r.sections["calendar"]._view_for(rel))
		await shot("discover_page_upcoming")
		r.close_page()
	if want(["discover_toast"]):
		r.show_section("home")
		d.price_alert.emit(d.wishlist[0], d.deals[3])
		d.release_alert.emit({"title": "Kite Season"})
		for t in main.toasts.find_children("*", "Timer", true, false):
			t.start(120.0)   # slow software rendering: keep them up for the shot
		await shot("discover_toast")
		for c in main.toasts.get_children():
			c.free()
	if want(["discover_light"]):
		var prefs = load("res://scripts/ui/ui_prefs.gd")
		prefs.theme = "light"
		prefs.match_art = false
		main.apply_theme()
		r.show_section("deals")
		await frames(4)
		r.sections["deals"].rows[1].grab_focus()
		await shot("discover_light")
		prefs.theme = "cove"
		prefs.match_art = true
		main.apply_theme()
	if want(["discover_midnight_page"]):
		var prefs = load("res://scripts/ui/ui_prefs.gd")
		prefs.theme = "midnight"
		prefs.match_art = false
		main.apply_theme()
		r.show_section("wishlist")
		await frames(4)
		r.sections["wishlist"].rows[1].grab_focus()
		await shot("discover_midnight_page")
		prefs.theme = "cove"
		prefs.match_art = true
		main.apply_theme()
	if want(["discover_offline", "discover_calendar_empty", "discover_wishlist_empty"]):
		var e = DF.FakeDiscover.new()
		e.status = {"cheapshark": "offline", "steam": "offline", "calendar": "missing"}
		e.clock = DF.now
		root.add_child(e)
		svc["discover"] = e
		main.discover.setup(svc)
		r = main.discover.content
		main.show_screen("home")
		main.show_screen("discover")
		await frames(4)
		await shot("discover_offline")
		r.show_section("calendar")
		await shot("discover_calendar_empty")
		r.show_section("wishlist")
		await shot("discover_wishlist_empty")
	main.show_screen("home")
