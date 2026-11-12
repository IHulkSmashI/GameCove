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
	Layout.begin()   # tools/layout: measure every shot on one screen of the matrix
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
	if Layout.measuring():
		Layout.check(root, name)
		return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(out)
	root.get_texture().get_image().save_png(out + name + suffix + ".png")
	print("saved ", out + name + suffix + ".png")
	Layout.check(root, name)


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
	await _library2_shots(lib)
	await _saves_shots()

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
		sp.build("code")
		main.add_child(sp)
		await shot("boot")
		sp.queue_free()
	await finish()


## Favourites, hidden games, collections and the Emulation page.
func _library2_shots(lib: Node) -> void:
	if not want(["library_options", "library_filter", "library_favourites", "home_favourites", "game_favourite",
			"emulation_empty", "emulation", "library_emulation", "home_emulation", "settings_collections"]):
		return
	var cols: RefCounted = lib.collections
	cols.path = "/tmp/gamecove-shots/collections.json"
	DirAccess.remove_absolute(cols.path)
	cols.reload()
	for t in ["Hollow Tide", "Northbound", "Paper Lanterns", "Quiet Orchard"]:
		cols.set_favourite(_find(t)["key"], true)
	var party: String = cols.create("Couch co-op")
	for t in ["Ember Circuit", "Velvet Arcade", "Dune Runners"]:
		cols.add(party, _find(t)["key"])
	var backlog: String = cols.create("Backlog")
	for t in ["Kingdom of Ash", "Crimson Vale"]:
		cols.add(backlog, _find(t)["key"])
	cols.set_hidden(_find("Sky Harbor")["key"], true)
	# Two pinned desktop apps, so Home shows its Apps shelf where it goes.
	main.home.set_apps([{"key": "app:org.videolan.VLC", "store": "app", "id": "org.videolan.VLC", "title": "VLC", "installed": true,
		"exec": ["vlc"], "art": {"cover": "", "hero": "", "logo": "", "icon": ""}, "info": {}, "last_played": 0, "playtime_min": 0},
		{"key": "app:org.mozilla.firefox", "store": "app", "id": "org.mozilla.firefox", "title": "Firefox", "installed": true,
		"exec": ["firefox"], "art": {"cover": "", "hero": "", "logo": "", "icon": ""}, "info": {}, "last_played": 0, "playtime_min": 0}])
	await frames(4)
	main.show_screen("library")
	await frames(4)
	var tiles: Array = main.library_screen.tiles()
	var third: int = mini(2, tiles.size() - 1)   # a narrow layout may show fewer than three tiles
	if third >= 0:
		tiles[third].grab_focus()
	if third >= 0 and want(["library_options"]):
		main.collection_actions.options(tiles[third].game)
		await shot("library_options")
		main.game_actions.sheet.close()
	if want(["library_filter"]):
		main.open_library_filter()
		await shot("library_filter")
		main.game_actions.sheet.close()
	if want(["library_favourites"]):
		main.library_screen.set_view("favourites")
		await frames(4)
		await shot("library_favourites")
		main.library_screen.set_view("")
	if want(["home_favourites"]):
		main.show_screen("home")
		await frames(4)
		var fav: Array = main.home.tiles("favourites")
		if not fav.is_empty():
			fav[0].grab_focus()
		await shot("home_favourites")
	if want(["game_favourite"]):
		main._open_page(_find("Hollow Tide"))
		await frames(4)
		if main.page.favourite_button != null:
			main.page.favourite_button.grab_focus()
		await shot("game_favourite")
		main._close_page()
	if want(["settings_collections"]):
		main.show_screen("settings")
		await frames(4)
		main.settings.open_category("stores", "")
		await frames(30)
		var rows: Dictionary = main.settings.pages["stores"].rows
		if rows.has("steam_collections"):
			var row: Control = rows["steam_collections"]
			row.button.grab_focus()
			var n: Node = row
			while n != null and not n is ScrollContainer:
				n = n.get_parent()
			if n != null:
				await frames(2)
				(n as ScrollContainer).ensure_control_visible(row)
			await frames(20)
		await shot("settings_collections")
	if want(["emulation_empty"]):
		main.show_screen("library")
		await frames(2)
		main.open_emulation()
		await shot("emulation_empty")
		main._close_page()
	if want(["emulation", "library_emulation", "home_emulation"]):
		await _emulation_shots(lib)
	main.show_screen("home")
	await frames(2)


## A believable EmuDeck setup: ES-DE, four systems' worth of ROMs, recently
## played games, and three Steam ROM Manager shortcuts with painted covers.
func _emulation_shots(lib: Node) -> void:
	var now := int(Time.get_unix_time_from_system())
	var home := OS.get_environment("HOME")
	lib.emulation = {"kind": "emudeck", "name": "EmuDeck",
		"frontend": {"name": "ES-DE", "command": ["/home/deck/Applications/ES-DE.AppImage"]},
		"app": {"name": "EmuDeck", "command": ["/home/deck/Applications/EmuDeck.AppImage"]},
		"srm": {"command": ["/home/deck/Applications/srm/Steam-ROM-Manager.AppImage"]},
		"roms_dir": home.path_join("Emulation/roms"), "esde_dir": home.path_join("ES-DE"), "rom_total": 214,
		"systems": [{"id": "snes", "name": "Nintendo SNES (Super Nintendo)", "short": "SNES", "count": 64},
			{"id": "gba", "name": "Nintendo Game Boy Advance", "short": "GBA", "count": 48},
			{"id": "psx", "name": "Sony PlayStation", "short": "PS1", "count": 37},
			{"id": "genesis", "name": "Sega Genesis", "short": "Genesis", "count": 29},
			{"id": "n64", "name": "Nintendo 64", "short": "N64", "count": 18},
			{"id": "ps2", "name": "Sony PlayStation 2", "short": "PS2", "count": 11},
			{"id": "gc", "name": "Nintendo GameCube", "short": "GameCube", "count": 7}],
		"recent": [{"title": "Star Courier", "system": "SNES", "last_played": now - 3600 * 5},
			{"title": "Pixel Knights II", "system": "GBA", "last_played": now - 86400},
			{"title": "Neon Highway", "system": "PS1", "last_played": now - 86400 * 3},
			{"title": "Harbor Racer", "system": "Genesis", "last_played": now - 86400 * 9}]}
	var emu_games: Array = []
	var art := func(t: String) -> Dictionary: return _find(t)["art"].duplicate()
	var fe := {"key": "emu:frontend", "store": "emu", "id": "frontend", "title": "ES-DE", "installed": true,
		"art": {"cover": "", "hero": "", "logo": "", "icon": ""}, "info": {"released": null, "time_to_beat": null, "anticheat": null, "protondb": null},
		"last_played": now - 3600 * 5, "playtime_min": 640, "command": lib.emulation["frontend"]["command"], "frontend": true,
		"emulated": {"system": "", "system_name": "", "system_short": "", "emulator": "", "via": "emudeck"}}
	emu_games.append(fe)
	var specs := [["Star Courier", "snes", "Nintendo SNES (Super Nintendo)", "SNES", "Velvet Arcade"],
		["Pixel Knights II", "gba", "Nintendo Game Boy Advance", "GBA", "Quiet Orchard"],
		["Neon Highway", "psx", "Sony PlayStation", "PS1", "Neon Ronin"]]
	var i := 0
	for s in specs:
		i += 1
		emu_games.append({"key": "emu:30000000%02d" % i, "store": "emu", "id": "30000000%02d" % i, "title": s[0], "installed": true,
			"art": art.call(s[4]), "info": {"released": null, "time_to_beat": null, "anticheat": null, "protondb": null,
			"summary": "A %s game from your ROM folder, added to Steam by Steam ROM Manager through EmuDeck. It runs in RetroArch." % s[2]},
			"last_played": now - 86400 * i, "playtime_min": 90 * i, "shortcut": true,
			"emulated": {"system": s[1], "system_name": s[2], "system_short": s[3], "emulator": "RetroArch", "via": "emudeck"}})
	var all: Array = games.duplicate()
	all.append_array(emu_games)
	lib.games.assign(all)
	lib.changed.emit()
	await frames(4)
	if want(["emulation"]):
		main.show_screen("library")
		await frames(2)
		main.open_emulation()
		await shot("emulation")
		main._close_page()
	if want(["library_emulation"]):
		main.show_screen("library")
		main.library_screen.set_view("emulation")
		await frames(4)
		var t: Array = main.library_screen.tiles()
		for x in t:
			if x.game["key"] == "emu:3000000001":
				x.grab_focus()
		await shot("library_emulation")
		main.library_screen.set_view("")
	if want(["home_emulation"]):
		main.show_screen("home")
		await frames(4)
		var em: Array = main.home.tiles("emulation")
		if not em.is_empty():
			em[0].grab_focus()
		await frames(10)
		await shot("home_emulation")
	lib.games.assign(games)
	lib.emulation = load("res://scripts/library/stores/emu.gd").empty_setup()
	lib.changed.emit()
	await frames(2)


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
## Cloud saves (game page card, the conflict choice, Settings > Saves), battery drain and
## history (game page line, About this device) and the Sleep at low battery warning.
func _saves_shots() -> void:
	var names := ["game_saves", "game_saves_conflict", "game_saves_restored", "settings_saves", "about_battery", "battery_card", "low_battery"]
	if not want(names):
		return
	var tmp := "/tmp/gamecove-shots/saves"
	DirAccess.make_dir_recursive_absolute(tmp)
	var now := int(Time.get_unix_time_from_system())
	# a battery the log can read (49.3 Wh full, like a Claw 8 EX)
	var bat := tmp + "/sys/class/power_supply/BAT0/"
	DirAccess.make_dir_recursive_absolute(bat)
	for f in [["type", "Battery"], ["capacity", "64"], ["energy_now", "31500000"], ["energy_full", "49300000"]]:
		var fa := FileAccess.open(bat + f[0], FileAccess.WRITE)
		fa.store_string(f[1] + "\n")
		fa.close()
	var epic: Dictionary = {}
	for g in games:
		if str(g.get("store", "")) == "epic" and bool(g.get("installed", false)):
			epic = g
			break
	if epic.is_empty():
		epic = games[1].duplicate(true)
		epic["store"] = "epic"
		epic["key"] = "epic:" + str(epic["id"])
		epic["installed"] = true
	var key := str(epic["key"])
	var sv: Node = main.saves
	sv.cfg_path = tmp + "/saves.cfg"
	sv.backup_dir = tmp + "/backups"
	sv.backups.base_dir = sv.backup_dir
	var cfg := ConfigFile.new()
	cfg.set_value("game:" + key, "state", "synced")
	cfg.set_value("game:" + key, "at", now - 120)
	cfg.set_value("game:" + key, "last_sync", now - 120)
	cfg.save(sv.cfg_path)
	var bl: Node = main.battery_log
	bl.path = tmp + "/battery.json"
	bl.sys_root = tmp
	bl.data = {"v": 1, "open": {}, "samples": [], "games": {
		key: {"title": str(epic["title"]), "wh": 21.6, "s": 9000, "n": 3},
		str(games[0]["key"]): {"title": str(games[0]["title"]), "wh": 30.0, "s": 7200, "n": 2},
		str(games[2]["key"]): {"title": str(games[2]["title"]), "wh": 9.5, "s": 5400, "n": 2}}}
	# seven days of game starts and ends, sleep and the charger
	var pct := 100
	var t := now - 7 * 86400 + 3600
	var day := 0
	while t < now - 1800:
		bl.data["samples"].append([t, pct, pct * 0.493, "unplug", ""])
		bl.data["samples"].append([t + 600, pct - 2, (pct - 2) * 0.493, "start", key])
		pct = maxi(18, pct - 34 - (day % 3) * 9)
		bl.data["samples"].append([t + 6000, pct, pct * 0.493, "end", key])
		bl.data["samples"].append([t + 9000, pct - 3, (pct - 3) * 0.493, "suspend", ""])
		bl.data["samples"].append([t + 30000, pct - 5, (pct - 5) * 0.493, "resume", ""])
		bl.data["samples"].append([t + 31000, pct - 6, (pct - 6) * 0.493, "plug", ""])
		pct = 100
		bl.data["samples"].append([t + 40000, pct, pct * 0.493, "suspend", ""])
		t += 86400
		day += 1
	if want(["game_saves", "game_saves_conflict"]):
		main._open_page(epic)
		var card: Control = main.page.saves_card
		await frames(20)
		if card != null:
			card.toggle_button.grab_focus()
		await shot("game_saves")
		if want(["game_saves_conflict"]) and card != null:
			cfg.set_value("game:" + key, "state", "conflict")
			cfg.set_value("game:" + key, "local", now - 3 * 3600)
			cfg.set_value("game:" + key, "remote", now - 25 * 60)
			cfg.save(sv.cfg_path)
			card.refresh()
			card.open_conflict()
			await shot("game_saves_conflict")
			main.game_actions.sheet.close()
			if want(["game_saves_restored"]):
				# after a restore: the restored save is offered first, whatever its age
				cfg.set_value("game:" + key, "prefer", "local")
				cfg.save(sv.cfg_path)
				card.open_conflict()
				await shot("game_saves_restored")
				main.game_actions.sheet.close()
				cfg.set_value("game:" + key, "prefer", "")
			cfg.set_value("game:" + key, "state", "synced")
			cfg.save(sv.cfg_path)
		main._close_page()
	if want(["settings_saves", "about_battery"]):
		var lib = S.FakeLibrary.new()
		lib.games = games
		var svc: Dictionary = main.settings.services.duplicate()
		svc["saves"] = sv
		svc["battery"] = bl
		svc["library"] = lib
		svc["device"] = _claw_device()
		main.settings.set_services(svc)
		main.show_screen("settings")
		await frames(4)
		var st = main.settings
		if want(["settings_saves"]):
			st.cat_buttons["saves"].grab_focus()
			await frames(2)
			st.enter_page()
			var sp = st.pages["saves"]
			var gk := "game_" + key.validate_node_name()
			if sp.rows.has(gk):
				sp.rows[gk].button.grab_focus()
			await shot("settings_saves")
		if want(["about_battery"]):
			st.cat_buttons["device"].grab_focus()
			await frames(2)
			st.enter_page()
			await frames(10)
			var hist: Node = st.find_child("Card_history", true, false)
			if hist != null:
				hist.grab_focus()
			await shot("about_battery")
		main.show_screen("home")
	if want(["battery_card"]):
		# the card on its own, at the About page's column width
		var DKit = load("res://scripts/ui/device/device_kit.gd")
		var TD = load("res://scripts/ui/texts_device.gd")
		var bg := ColorRect.new()
		bg.color = load("res://theme/gamecove_theme.gd").color("bg")
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg.z_index = 50
		bg.set_meta("ux_no_walk", "a picture of one card for the docs, drawn over the app")
		main.add_child(bg)   # main's theme (fonts, colours)
		var c: Array = DKit.card(TD.SECTIONS["history"], TD.SECTION_ICONS["history"], "good", false)
		c[0].position = Vector2(48, 48)
		c[0].custom_minimum_size = Vector2(root.size.x * 0.5, 0)
		var body = load("res://scripts/ui/device/battery_history.gd").new()
		body.setup(bl, now)
		c[1].add_child(body)
		bg.add_child(c[0])
		await shot("battery_card")
		bg.free()
	if want(["low_battery"]):
		main._on_low_battery(5)
		main.low_dialog.seconds_left = 23
		main.low_dialog._show()
		main.low_dialog._timer.stop()
		await shot("low_battery")
		main.low_dialog.dismiss()
		main._low_dialog_closed()


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
	main.hint_status.text = "● GameCove %s   MSI Claw 8 EX AI+" % ShotVersion.short()
	if _home_ach == null:
		_home_ach = load("res://tests/test_ui_games.gd").FakeAchievements.new()
		_home_ach.data = _ach_data()
		root.add_child(_home_ach)
		# One service for Home and the game page (main.set_achievements), as in the app.
		main.set_achievements(_home_ach)
	main.status_panel.set_battery("MSI Claw 8 EX AI+", {"percent": 72, "status": "Discharging", "watts": 9.4, "time_left_min": 214})


# ------------------------------------------------------------ games (s-games)

const ShotVersion := preload("shot_version.gd")
const Layout := preload("../layout/recorder.gd")
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
			await frames(2)   # the import card focuses its field a frame later; the keyboard opens after, as when A is pressed on it
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


func _finalize() -> void:
	Layout.save(get_script().resource_path.get_file().get_basename())
