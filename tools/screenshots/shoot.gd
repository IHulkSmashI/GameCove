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
	if want(["home_empty"]):
		await shot("home_empty")
	var lib := root.get_node("Library")
	lib.games.assign(games)
	lib.changed.emit()
	_status()
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
			main.page.form.focusables()[1].grab_focus()
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
		main._open_menu()
		await shot("quick_game")
		qm.show_section(1)
		await frames(2)
		await press("ui_down")
		await shot("quick_power")
		qm.show_section(2)
		await shot("quick_screen")
		qm.show_section(4)
		await frames(20)
		qm.show_section(4)
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
	quit()


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
		"perf": S.FakePerf.new(), "achievements": S.FakeAchievements.new(), "device": S.FakeDevicePic.new()}
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
				st.pages["performance"].rows["overlay"].button.grab_focus()
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
			qm.device.profile["support"] = "partial"
			qm.device.profile["name"] = "Lenovo Legion Go 2"
			qm.device.profile["unverified"] = ["tdp", "charge_limit", "panel.vrr"]
			qm.show_section(4)
			await shot("quick_device_partial")
		qm.close()
		main.playing = {}


func _noop(_g = null) -> void:
	pass


func _status() -> void:
	main.top_bar.set_status("MSI Claw 8 EX AI+", {"percent": 72, "status": "Discharging", "watts": 9.4}, "2:05 PM", {"connected": true, "strength": 0.8})
	main.status_panel.set_battery("MSI Claw 8 EX AI+", {"percent": 72, "status": "Discharging", "watts": 9.4, "time_left_min": 214})
