extends "shoot.gd"
## The Controls UI shots: quick menu tabs, the generated settings pages,
## Profiles, Device > Fixes, the Keep-this check and the game page's Game
## settings card. Fake Controls from snapshots of the real providers on the
## device matrix (app/tests/fixtures/ui_controls/<device>.json, made by
## dump_controls.gd), patched with what a fully set-up MSI Claw 8 EX and
## Legion Go S report (Power service, InputPlumber / hhd and MangoHud
## running), and the real Profiles on a temporary file.
##
##   SHOOT_SCRIPT=shoot_controls.gd tools/screenshots/shoot.sh /tmp/shots [WxH] [only,these]
##   SHOOT_THEME=midnight|sunset|light renders the whole set in that theme
##   (the per-theme extras are skipped then).

const FakeControls := preload("res://tests/fixtures/ui_controls/fake_controls.gd")
const ProfilesScript := preload("res://scripts/controls/profiles.gd")
const SNAP := "res://tests/fixtures/ui_controls/%s.json"
const SHOTS := ["controls_quick_game", "controls_quick_game_everyday", "controls_quick_power", "controls_quick_display",
	"controls_quick_audio", "controls_quick_controller", "controls_quick_device", "controls_settings_power",
	"controls_settings_fan_curve", "controls_settings_display", "controls_settings_controller", "controls_settings_lights",
	"controls_settings_performance", "controls_settings_system", "controls_settings_profiles", "controls_settings_fixes",
	"controls_settings_more", "controls_keep", "controls_game_page", "controls_quick_midnight", "controls_settings_light",
	"controls_quick_sunset", "controls_quick_legion", "controls_settings_about", "controls_settings_stores"]

var fake: Node
var profiles: Node
var qm_power: Object
var dev: Object


static func claw_patch() -> Dictionary:
	var tdp := {"value": 17, "min": 8.0, "max": 35.0, "step": 1.0, "unit": "W"}
	return {
		"power.tdp": tdp,
		"power.profile": {"value": "balanced"},
		"power.boost": {"value": 6, "min": 0.0, "max": 10.0, "step": 1.0, "unit": "W"},
		"power.fan_mode": {"value": "auto", "options": [{"value": "quiet", "label": "Quiet"}, {"value": "auto", "label": "Auto"}, {"value": "max", "label": "Max"}]},
		"power.fan_curve": {"value": [0.0, 40.0, 45.0, 55.0, 70.0, 85.0], "points": 6},
		"power.charge_limit": {"value": 80, "min": 50.0, "max": 100.0, "step": 5.0, "unit": "%"},
		"power.autotune_target": {"value": 60},
		"power.autotune_auto_fps": {"value": true},
		"power.autotune_keep": {"value": 5, "min": 2.0, "max": 15.0, "unit": "%"},
		"power.autotune_floor": {"value": 8, "min": 8.0, "max": 35.0, "unit": "W"},
		"power.autotune_plugged": {"value": false},
		"power.thermal_limit": {"reason": "PowerStation can't set a temperature limit here (AMD with ryzenadj only)"},
		"perf.overlay": {"value": "fps"},
		"perf.overlay_position": {"value": "top-left"},
		"perf.overlay_opacity": {"value": 40, "min": 0.0, "max": 100.0, "step": 5.0, "unit": "%"},
		"perf.overlay_scale": {"value": 100, "min": 50.0, "max": 200.0, "step": 10.0, "unit": "%"},
		"perf.upscaler": {"value": "xess"},
		"perf.frame_gen": {"value": 0},
		"perf.upscale_recommended": {"value": null},
		"perf.upscale_undo": {"value": null},
		"perf.low_latency": {"value": true},
		"perf.proton": {"value": "proton_cachyos", "options": [{"value": "", "label": "Steam's default"},
			{"value": "proton_cachyos", "label": "Proton-CachyOS 11"}, {"value": "GE-Proton10-25", "label": "GE-Proton 10-25"},
			{"value": "proton_experimental", "label": "Proton Experimental"}]},
		"perf.launch_wrapper": {"value": true},
		"perf.clear_shader_cache": {"value": null},
		"controller.gyro": {"value": true},
		"controller.gyro_source": {"reason": "This handheld has one gyro"},
		"controller.gyro_accel": {"value": false},
		"controller.emulation": {"value": "deck"},
		"controller.paddle.LeftPaddle1": {"value": "", "options": [{"value": "", "label": "As itself"}, {"value": "off", "label": "Off"},
			{"value": "South", "label": "A"}, {"value": "Screenshot", "label": "Screenshot"}]},
		"controller.paddle.RightPaddle1": {"value": "South", "options": [{"value": "", "label": "As itself"}, {"value": "off", "label": "Off"},
			{"value": "South", "label": "A"}, {"value": "Screenshot", "label": "Screenshot"}]},
		"controller.nintendo_layout": {"value": false},
		"controller.desktop_mode": {"value": false},
		"controller.desktop_speed": {"value": 1000, "min": 200.0, "max": 3000.0, "step": 100.0, "unit": "px/s"},
		"controller.rumble": {"value": true},
		"controller.rumble_strength": {"value": 60, "options": [{"value": 20, "label": "20%"}, {"value": 40, "label": "40%"},
			{"value": 60, "label": "60%"}, {"value": 80, "label": "80%"}, {"value": 100, "label": "100%"}]},
		"controller.rumble_test": {"value": null},
		"controller.led_effect": {"value": "solid", "options": [{"value": "off", "label": "Off"}, {"value": "solid", "label": "Solid"},
			{"value": "pulse", "label": "Pulse"}, {"value": "rainbow", "label": "Rainbow"}, {"value": "spiral", "label": "Spiral"}]},
		"controller.led_color": {"value": "#00F0FF"},
		"controller.led_brightness": {"value": 70, "min": 0.0, "max": 100.0, "step": 5.0, "unit": "%"},
		"controller.led_speed": {"value": 50, "min": 0.0, "max": 100.0, "step": 5.0, "unit": "%"},
		"controller.reset_layout": {"value": null},
		"display.brightness": {"value": 64},
		"display.vrr": {"value": true},
		"display.fps_limit": {"value": 60},
		"display.night_light_schedule": {"value": "manual", "options": [{"value": "manual", "label": "Off"},
			{"value": "20-7", "label": "8 PM to 7 AM"}, {"value": "22-6", "label": "10 PM to 6 AM"}]},
		"display.effect": {"value": "", "options": [{"value": "", "label": "Off"}, {"value": "crt", "label": "CRT (Lottes)"}, {"value": "scan", "label": "Scanlines"}]},
		"display.sharpness": {"value": 14},
		"display.vibrance": {"value": 25},
		"audio.volume": {"value": 62},
		"audio.output": {"value": "Speaker"},
	}


static func legion_patch() -> Dictionary:
	var p := claw_patch()
	p["power.tdp"] = {"value": 15, "min": 5.0, "max": 30.0, "step": 1.0, "unit": "W"}
	p["power.boost"] = {"reason": "Not available on this handheld"}
	p["power.fan_curve"] = {"reason": "No fan curve on this handheld; the fan modes still work"}
	p["power.charge_limit"] = {"reason": "This battery has no charge limit"}
	p["power.battery_long_life"] = {"value": true}
	p["power.autotune_floor"] = {"value": 5, "min": 5.0, "max": 30.0, "unit": "W"}
	p["perf.upscaler"] = {"value": "own", "options": [{"value": "own", "label": "Game's own"}, {"value": "fsr31", "label": "FSR 3.1 (OptiScaler)"}]}
	p["perf.frame_gen"] = {"value": 0, "options": [{"value": 0, "label": "Off"}, {"value": 2, "label": "2x"}]}
	p["perf.low_latency"] = {"value": false}
	p["perf.lsfg"] = {"value": false}
	p["perf.lsfg_multiplier"] = {"value": 2}
	p["perf.lsfg_flow_scale"] = {"value": 0.8}
	p["controller.gyro_accel"] = {"reason": "Only on the MSI Claw 8 EX"}
	p["controller.trackpad"] = {"value": "as-is", "options": [{"value": "as-is", "label": "As sent"}, {"value": "right", "label": "Steam right pad"},
		{"value": "left", "label": "Steam left pad"}, {"value": "off", "label": "Off"}]}
	p["controller.rumble_strength"] = {"reason": "InputPlumber can only turn rumble on or off"}
	p["controller.led_color"] = {"value": "#FF2E88"}
	p["display.refresh_rate"] = {"value": 120, "min": 48.0, "max": 120.0, "step": 1.0, "unit": "Hz"}
	p["display.vibrance"] = {"value": 0}
	return p


func _run() -> void:
	OS.low_processor_usage_mode = false
	T = load("res://tests/test_ui_screens.gd")
	S = load("res://tests/test_ui_settings.gd")
	var painter: GDScript = load(get_script().resource_path.get_base_dir().path_join("painter.gd"))
	DirAccess.make_dir_recursive_absolute(art_dir)
	games = await painter.make_library(self, art_dir)
	var prefs = load("res://scripts/ui/ui_prefs.gd")
	prefs.path = "/tmp/gamecove-shots/ui-controls.cfg"
	DirAccess.remove_absolute(prefs.path)
	if theme_override() != "":
		prefs.theme = theme_override()
		prefs.match_art = theme_override() != "light"
	load("res://scripts/main.gd").boot_splash = false
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await frames(3)
	main._live_timer.stop()
	main._live_timer.wait_time = 9999
	var flow_script = load("res://scripts/ui/setup/setup_flow.gd")
	if flow_script.instance != null:
		flow_script.instance.finish()
	var lib := root.get_node("Library")
	lib.games.assign(games)
	lib.changed.emit()
	_status()
	if theme_override() != "":
		prefs.theme = theme_override()
		prefs.match_art = theme_override() != "light"
		main.apply_theme()
	await frames(4)

	await _use_device("msi-claw-8-ex", claw_patch())
	await _quick_shots()
	await _settings_shots_controls()
	await _game_page_shot()
	await _theme_shots()
	if want(["controls_quick_legion", "controls_quick_display", "controls_settings_display", "controls_settings_more"]):
		await _use_device("lenovo-legion-go-s-z2go", legion_patch())
		await _legion_shots()
	quit()


## Swaps the Controls / Profiles autoloads for fakes of one handheld.
func _use_device(id: String, patch: Dictionary) -> void:
	for n in ["Controls", "Profiles"]:
		var old := root.get_node_or_null(n)
		if old != null and old != fake and old != profiles:
			old.name = n + "Real"
	if fake != null:
		fake.name = "ControlsOld"
		fake.queue_free()
	if profiles != null:
		profiles.name = "ProfilesOld"
		profiles.queue_free()
	await frames(1)
	fake = FakeControls.new()
	fake.name = "Controls"
	fake.load_snapshot(SNAP % id, patch)
	root.add_child(fake)
	var path := "/tmp/gamecove-shots/profiles-%s.json" % id
	DirAccess.remove_absolute(path)
	profiles = ProfilesScript.new()
	profiles.name = "Profiles"
	profiles.setup(fake, id, path)
	profiles._first_detect_done = true
	root.add_child(profiles)
	# a couple of saved layers so badges and the Profiles page have something real
	profiles.set_value("", "battery", "display.fps_limit", 60)
	profiles.set_value("", "", "power.tdp", 17)
	var other := {"key": "steam:892970", "title": "Valheim"}
	profiles.set_layer("steam:892970", "", {"power.tdp": 12, "display.fps_limit": 40, "perf.overlay": "fps"})
	profiles._remember_title("steam:892970", other["title"])
	profiles.set_layer("epic:fn", "battery", {"power.tdp": 10, "display.fps_limit": 30})
	profiles._remember_title("epic:fn", "Fortnite")
	profiles.save_file()

	dev = T.FakeDevice.new()
	if id.begins_with("lenovo"):
		dev.profile = {"name": "Lenovo Legion Go S", "chip": "AMD Ryzen Z2 Go", "gpu": "Radeon 680M-class (RDNA 2)",
			"panel_hz": [48, 120], "support": "partial", "fixes": [], "unverified": ["tdp"]}
		dev.bat = {"percent": 58, "status": "Discharging", "watts": 11.2}
	else:
		dev.profile["fixes"] = ["claw8ex-buttons", "claw8ex-vrr", "claw8ex-gyro", "claw-kbd-wakeup"]
	var qm = main.quick_menu
	qm.device = dev
	qm_power = S.FakeAutoPower.new()
	qm.power = qm_power
	qm.launcher = load("res://tests/test_ui_quick_menu.gd").FakeLauncher.new()
	qm.fixes = load("res://tests/test_ui_device_fixes.gd").FakeFixes.new()
	qm.fixes.list = [{"id": "a", "status": "applied"}, {"id": "b", "status": "applied"}, {"id": "c", "status": "applied"}, {"id": "d", "status": "available"}]
	qm.use_controls(fake, profiles)
	var gs = T.FakeGamescope.new()
	gs.running = true
	qm.gamescope = gs
	var svc: Dictionary = main.settings.services.duplicate()
	svc["controls"] = fake
	svc["profiles"] = profiles
	svc["device"] = S.FakeDevicePic.new() if not id.begins_with("lenovo") else svc.get("device")
	svc["fixes"] = _fake_fixes(id)
	svc["profiles_dir"] = "/tmp/gamecove-shots/profiles-export"
	main.settings.set_services(svc)
	await frames(2)


## The real Fixes service for the handheld, on a fake runner (test_fixes.gd's).
func _fake_fixes(id: String) -> Node:
	var tf = load("res://tests/test_fixes.gd").new()
	var states := {"claw8ex-buttons": "on", "claw8ex-vrr": "on", "claw8ex-gyro": "on", "claw-kbd-wakeup": "off", "ax210-d3cold": "not-needed"} \
		if id == "msi-claw-8-ex" else {}
	var s: Node = tf._svc(id, states)
	s.refresh()
	return s


func _game(i := 0) -> Dictionary:
	var g: Dictionary = games[i].duplicate()
	return g


func _open_quick(g: Dictionary, tab: int, focus_id := "") -> void:
	var qm = main.quick_menu
	if not qm.visible:
		main._open_menu()
	qm.game = g
	qm.model.set_game(g)
	qm._set_header(g)
	qm.show_section(tab, focus_id)
	await frames(3)


func _quick_shots() -> void:
	if not want(["controls_quick_game", "controls_quick_game_everyday", "controls_quick_power", "controls_quick_audio",
			"controls_quick_controller", "controls_quick_device", "controls_quick_midnight", "controls_quick_sunset"]):
		return
	var qm = main.quick_menu
	var g := _game(0)
	var sess = S.FakeSession.new()
	root.add_child(sess)
	qm.attach_session(sess)
	if not qm.exit_game_requested.is_connected(_noop):
		qm.exit_game_requested.connect(_noop)
	main.playing = g
	sess.started.emit(g)
	profiles.game_started(g)
	qm._session_start_ms = Time.get_ticks_msec() - 42 * 60 * 1000
	main._open_menu()
	qm.game = g
	if want(["controls_quick_game_everyday"]):
		await _open_quick(g, 0, "display.fps_limit")
		await shot("controls_quick_game_everyday")
	qm.model.set_per_game(true)
	qm.model.set_value("power.tdp", 14)
	await _open_quick(g, 0, "power.tdp")
	await shot("controls_quick_game")
	qm._on_autotune_limit(true, {"cant_reach": true, "target_fps": 60, "ceiling_w": 15.0, "tdp_max": 35.0})
	await _open_quick(g, 1, "power.fan_mode")
	await shot("controls_quick_power")
	await _open_quick(g, 3, "audio.volume")
	await shot("controls_quick_audio")
	await _open_quick(g, 4, "controller.led_color")
	var led: Node = qm.body.find_child("controller_led_color", true, false)
	if led != null:
		led.button.grab_focus()
	await shot("controls_quick_controller")
	await _open_quick(g, 5)
	await shot("controls_quick_device")
	qm.close()
	_qm_session = sess


var _qm_session: Node


func _settings_page(cat: String, focus_id := "") -> void:
	var st = main.settings
	main.show_screen("settings")
	await frames(4)
	st.open_category(cat)
	await frames(4)
	if focus_id != "":
		var n: Node = st.pages[cat].find_child(focus_id.validate_node_name(), true, false)
		if n != null and n.has_method("focusables"):
			n.focusables()[0].grab_focus()
	await frames(4)


func _settings_shots_controls() -> void:
	var st = main.settings
	if want(["controls_settings_power"]):
		await _settings_page("power", "power.tdp")
		await shot("controls_settings_power")
	if want(["controls_settings_fan_curve"]):
		await _settings_page("power", "power.fan_curve")
		var fc: Node = st.pages["power"].find_child("power_fan_curve", true, false)
		if fc != null:
			fc.row.toggle_edit()
			fc.row.selected = 4
			fc.row.nudge(4, 10.0)
		await shot("controls_settings_fan_curve")
		if fc != null:
			fc.row.cancel()
	if want(["controls_settings_controller"]):
		await _settings_page("controller", "controller.gyro")
		await shot("controls_settings_controller")
	if want(["controls_settings_lights"]):
		await _settings_page("controller", "controller.led_color")
		await shot("controls_settings_lights")
	if want(["controls_settings_performance"]):
		await _settings_page("performance", "perf.upscaler")
		await shot("controls_settings_performance")
	if want(["controls_settings_system"]):
		await _settings_page("system", "network.wifi")
		await shot("controls_settings_system")
	if want(["controls_settings_profiles"]):
		await _settings_page("profiles")
		var f: Array = st.pages["profiles"].focusables()
		if f.size() > 3:
			f[3].grab_focus()
		await shot("controls_settings_profiles")
	if want(["controls_settings_fixes"]):
		main.show_screen("settings")
		await frames(4)
		st.open_category("device", "fixes")
		await frames(12)
		await shot("controls_settings_fixes")
	if want(["controls_settings_about"]):
		main.show_screen("settings")
		await frames(4)
		st.open_category("device", "about")
		await frames(12)
		await shot("controls_settings_about")
	if want(["controls_settings_stores"]):
		await _settings_page("stores")
		await shot("controls_settings_stores")
	if want(["controls_keep"]):
		await _settings_page("display", "display.hdr")
		var KeepDialog = load("res://scripts/ui/controls/keep_dialog.gd")
		var d = KeepDialog.open(main, "Refresh rate", "40 Hz", 15)
		d.seconds_left = 11
		d._show()
		await shot("controls_keep")
		d.finish(true)
	main.show_screen("home")


func _game_page_shot() -> void:
	if not want(["controls_game_page"]):
		return
	var g := _game(0)
	main._open_page(g)
	await frames(6)
	var gs: Node = main.page.game_settings if main.page != null else null
	if gs != null and gs.edit_button != null:
		gs.edit_button.grab_focus()
		await frames(4)
		main.page._reveal(gs.get_parent().get_parent())
	await shot("controls_game_page")
	main._close_page()


static func theme_override() -> String:
	return OS.get_environment("SHOOT_THEME")


func _theme_shots() -> void:
	if theme_override() != "":
		return
	var prefs = load("res://scripts/ui/ui_prefs.gd")
	var g := _game(0)
	for t in [["controls_quick_midnight", "midnight", 1, "power.tdp"], ["controls_quick_sunset", "sunset", 4, "controller.emulation"]]:
		if not want([t[0]]):
			continue
		prefs.theme = t[1]
		main.apply_theme()
		await frames(3)
		main._open_menu()
		await _open_quick(g, t[2], t[3])
		await shot(t[0])
		main.quick_menu.close()
	if want(["controls_settings_light"]):
		prefs.theme = "light"
		prefs.match_art = false
		main.apply_theme()
		await frames(3)
		await _settings_page("power", "power.profile")
		await shot("controls_settings_light")
		main.show_screen("home")
		prefs.match_art = true
	prefs.theme = "cove"
	main.apply_theme()
	await frames(3)


func _legion_shots() -> void:
	var g := _game(1)
	_status_legion()
	if want(["controls_quick_display", "controls_quick_legion"]):
		main._open_menu()
		await _open_quick(g, 2, "display.refresh_rate")
		await shot("controls_quick_display")
		await _open_quick(g, 0, "perf.overlay")
		await shot("controls_quick_legion")
		main.quick_menu.close()
	if want(["controls_settings_display"]):
		await _settings_page("display", "display.vrr")
		await shot("controls_settings_display")
	if want(["controls_settings_more"]):
		await _settings_page("power")
		var page = main.settings.pages["power"]
		var lists: Array = page.cards.lists if page.cards != null else []
		if not lists.is_empty():
			lists[0].toggle_more()
			await frames(4)
			var f: Array = lists[0].focusables()
			if f.size() > 4:
				f[4].grab_focus()
		await frames(6)
		await shot("controls_settings_more")
	main.show_screen("home")


func _status_legion() -> void:
	main.top_bar.set_status("Lenovo Legion Go S", {"percent": 58, "status": "Discharging", "watts": 11.2}, "8:40 PM", {"connected": true, "strength": 0.6})
	main.top_bar.set_telemetry({"tdp_w": 15.0, "profile": "balanced", "temp_c": 61.0})
	main.hint_status.text = "● GameCove 0.4   Lenovo Legion Go S"
