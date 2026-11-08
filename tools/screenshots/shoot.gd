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
		if not want(["theme_" + id]):
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
	quit()


func _status() -> void:
	main.top_bar.set_status("MSI Claw 8 EX AI+", {"percent": 72, "status": "Discharging", "watts": 9.4}, "2:05 PM", {"connected": true, "strength": 0.8})
	main.status_panel.set_battery("MSI Claw 8 EX AI+", {"percent": 72, "status": "Discharging", "watts": 9.4, "time_left_min": 214})
