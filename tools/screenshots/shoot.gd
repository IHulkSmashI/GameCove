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
	quit()


func _status() -> void:
	main.top_bar.set_status("MSI Claw 8 EX AI+", {"percent": 72, "status": "Discharging", "watts": 9.4}, "2:05 PM", {"connected": true, "strength": 0.8})
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
