extends "res://tests/test_case.gd"
## The rebuilt quick menu over fake Controls and the real Profiles: tabs,
## "Use settings for this game", the quick controls per tab (only what this
## handheld can use), Auto TDP, Reset this game, gyro and Steam Input, live
## numbers, session time and Exit game, LB / RB / Y / B, the focus chain.

const QuickMenu := preload("res://scripts/ui/quick_menu.gd")
const Screens := preload("res://tests/test_ui_screens.gd")
const Settings := preload("res://tests/test_ui_settings.gd")
const UIC := preload("res://tests/test_ui_controls.gd")
const ProfilesScript := preload("res://scripts/controls/profiles.gd")
const TC := preload("res://scripts/ui/texts_controls.gd")
const TS := preload("res://scripts/ui/texts_settings.gd")
const PROFILE_FILE := "user://test_ui_quick_menu_profiles.json"


class FakeLauncher extends "res://tests/test_ui_screens.gd".FakeLauncher:
	func auto_tdp_for(key: String) -> bool:
		return settings_for(key)["goal"] in ["battery", "balanced"]
	func save_settings(key: String, s: Dictionary) -> void:
		var cur := settings_for(key)
		cur.merge(s, true)
		saved[key] = cur


class FakePower extends "res://tests/test_ui_settings.gd".FakeAutoPower:
	var requests := []
	func request_autotune(on: bool, key := "") -> void:
		requests.append([on, key])


func _menu(extra := {}) -> Dictionary:
	var c: Node = UIC.fake()
	c.add({"id": "perf.overlay", "title": "Performance overlay", "kind": "choice", "value": "off",
		"options": [{"value": "off", "label": "Off"}, {"value": "fps", "label": "FPS"}, {"value": "full", "label": "Full"}]})
	c.add({"id": "perf.upscaler", "title": "Upscaler", "kind": "choice", "reason": "Needs GameCove's upscaling helper"})
	c.add({"id": "controller.gyro", "title": "Gyro", "kind": "toggle", "value": true})
	c.add({"id": "controller.emulation", "title": "Controller type", "kind": "choice", "value": "deck",
		"options": [{"value": "default", "label": "Handheld default"}, {"value": "deck", "label": "Steam Deck"}]})
	c.add({"id": "audio.volume", "title": "Volume", "kind": "slider", "min_value": 0.0, "max_value": 100.0, "unit": "%", "value": 60, "per_game": false})
	c.add({"id": "network.wifi", "title": "Wi-Fi", "kind": "toggle", "value": true, "per_game": false})
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILE_FILE))
	var p: Node = ProfilesScript.new()
	p.setup(c, "msi-claw-8-ex", PROFILE_FILE)
	p._first_detect_done = true
	var power := FakePower.new()
	var launcher := FakeLauncher.new()
	var sess: Node = Settings.FakeSession.new()
	var svc := {"device": Screens.FakeDevice.new(), "power": power, "launcher": launcher, "gamescope": Screens.FakeGamescope.new(),
		"controls": c, "profiles": p, "session": sess}
	svc.merge(extra, true)
	var m: Control = QuickMenu.new()
	m.setup(svc)
	return {"m": m, "c": c, "p": p, "power": power, "launcher": launcher, "session": sess}


func _done(x: Dictionary) -> void:
	for k in ["m", "c", "p", "session"]:
		if is_instance_valid(x[k]):
			x[k].free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILE_FILE))


func _ids(m: Control) -> Array:
	var out := []
	for f in m.focusables():
		var n: Node = f
		while n != null and n != m.body:
			if n.has_method("explanation"):
				out.append(n.key)
				break
			n = n.get_parent()
	return out


const HADES := {"key": "steam:1", "title": "Hades", "store": "steam", "id": "1"}


func test_tabs_and_no_game() -> void:
	var x := _menu()
	var m: Control = x["m"]
	m.open({})
	eq(m.tabs.size(), 6, "six tabs")
	eq(m.section, 0, "opens on This game")
	eq(m.tabs[0].text, "This game", "the open tab names itself")
	eq(m.tabs[1].text, "", "the others are icons")
	ok(m.body.get_node_or_null("NoGame") != null, "no game: says how to get one")
	m.show_section(1)
	eq(m.tabs[1].text, "Power", "label follows the open tab")
	_done(x)


func test_this_game_rows_and_profile() -> void:
	var x := _menu()
	var m: Control = x["m"]
	var p: Node = x["p"]
	var c: Node = x["c"]
	m.open(HADES)
	var ids := _ids(m)
	eq(ids.slice(0, 3), ["perf.overlay", "display.fps_limit", "power.tdp"], "most used first")
	ok("power.autotune" in ids, "Auto TDP for this game")
	ok(not "perf.upscaler" in ids, "what this handheld can't use is left out")
	var use: Node = m.body.get_node("UseGame")
	eq(use.value(), false, "no profile yet")
	eq(use.hint_text(), TC.USE_GAME_OFF, "says it uses the everyday settings")
	use.step(1)
	ok(p.has_profile("steam:1"), "own settings saved")
	use = m.body.get_node("UseGame")
	eq(use.hint_text(), TC.USE_GAME_ON % "Hades", "says changes save for this game")
	ok(m.body.get_node_or_null("EditNote") != null, "not running: says nothing changes until it starts")
	ok(m.body.get_node_or_null("ResetGame") != null, "reset shows once it has a profile")
	var before: Variant = c.value("power.tdp")
	m.model.set_value("power.tdp", 7)
	eq(c.value("power.tdp"), before, "editing the profile leaves the handheld alone")
	eq(int(p.layer("steam:1", "")["power.tdp"]), 7, "saved for Hades")
	var reset: Node = m.body.get_node("ResetGame")
	reset.pressed.emit()
	ok(p.has_profile("steam:1"), "first press only asks")
	eq(reset.title_label.text, TC.RESET_CONFIRM, "asks for a second press")
	reset.pressed.emit()
	ok(not p.has_profile("steam:1"), "second press resets")
	eq(m.status_label.text, TC.RESET_DONE % "Hades", "says so")
	_done(x)


func test_auto_tdp_follows_launcher_and_session() -> void:
	var x := _menu()
	var m: Control = x["m"]
	var launcher: Object = x["launcher"]
	var power: Object = x["power"]
	m.open(HADES)
	eq(m.model.value("power.autotune"), true, "balanced goal: Auto TDP on")
	m.model.set_value("power.autotune", false)
	eq(launcher.saved["steam:1"]["goal"], "smooth", "off keeps the full TDP (Smoothest)")
	eq(power.requests, [], "not running: nothing starts or stops now")
	x["session"].started.emit(HADES)
	m.model.set_value("power.autotune", true)
	eq(launcher.saved["steam:1"]["goal"], "balanced", "on again")
	eq(power.requests, [[true, "steam:1"]], "running: Power starts it at once")
	c_unavailable_hides_autotune(x)
	_done(x)


func c_unavailable_hides_autotune(x: Dictionary) -> void:
	var m: Control = x["m"]
	x["c"].set_available("power.tdp", false)
	x["c"].detect_all()
	m.model.control("power.autotune").detect()
	eq(m.model.describe("power.autotune")["reason"], "Needs a TDP control", "no TDP: no Auto TDP")


func test_power_tab_live_and_autotune_line() -> void:
	var x := _menu()
	var m: Control = x["m"]
	var power: Object = x["power"]
	m.open({})
	m.show_section(1)
	var strip: Node = m.body.get_node("PowerLive")
	eq(strip.get_node("Stat_battery/Col/Value").text, "72%", "battery")
	eq(strip.get_node("Stat_draw/Col/Value").text, "9.4 W", "drawing")
	eq(strip.get_node("Stat_tdp/Col/Value").text, "15 W", "TDP")
	m.model.set_value("power.tdp", 18)
	m.refresh_live()
	eq(strip.get_node("Stat_tdp/Col/Value").text, "18 W", "refreshes")
	ok("power.tdp" in _ids(m) and "power.profile" in _ids(m), "power quick controls")
	power.autotune_limit.emit(true, {"cant_reach": true, "target_fps": 60, "ceiling_w": 15.0, "tdp_max": 30.0})
	var l: Label = m.body.get_node("AutoTdpLimit")
	eq(l.text, TS.QM_RAISE_TDP % [60, 15, 30], "raise TDP message")
	power.autotune_limit.emit(true, {"cant_reach": true, "target_fps": 60, "ceiling_w": 30.0, "tdp_max": 30.0})
	eq(l.text, TS.QM_CANT_HOLD % 60, "can't hold message at the ceiling")
	power.autotune_limit.emit(false, {})
	ok(not l.visible, "clears")
	ok(m.body.get_node_or_null("AllSettings") != null, "All power settings at the end")
	_done(x)


func test_controller_tab_gyro_and_steam_input() -> void:
	var x := _menu()
	var m: Control = x["m"]
	var opened := []
	m.open_uri = func(u): opened.append(u); return true
	m.open(HADES)
	m.show_section(4)
	ok(m.body.get_node_or_null("GyroSteam") != null, "explains gyro aiming lives in Steam")
	var b: Button = m.body.find_child("OpenSteamInput", true, false)
	ok(b != null and b in m.focusables(), "button for a Steam game")
	b.pressed.emit()
	eq(opened, ["steam://controllerconfig/1"], "opens Steam's controller settings for the game")
	ok(not m.visible, "menu closes for Steam")
	m.open({"key": "epic:2", "title": "Fortnite", "store": "epic", "id": "2"})
	m.show_section(4)
	ok(m.body.find_child("OpenSteamInput", true, false) == null, "no button for other stores")
	ok(_ids(m).has("controller.gyro") and _ids(m).has("controller.emulation"), "gyro on/off and controller type")
	_done(x)


func test_input_tabs_settings_and_close() -> void:
	var x := _menu()
	var m: Control = x["m"]
	m.open(HADES)
	var rb := InputEventJoypadButton.new()
	rb.button_index = JOY_BUTTON_RIGHT_SHOULDER
	rb.pressed = true
	m._unhandled_input(rb)
	eq(m.section, 1, "RB goes to Power")
	var lb := InputEventJoypadButton.new()
	lb.button_index = JOY_BUTTON_LEFT_SHOULDER
	lb.pressed = true
	m._unhandled_input(lb)
	m._unhandled_input(lb)
	eq(m.section, 5, "LB wraps to Device")
	var asked := []
	m.settings_requested.connect(func(cat, part): asked.append([cat, part]))
	m.show_section(2)
	var y := InputEventJoypadButton.new()
	y.button_index = JOY_BUTTON_Y
	y.pressed = true
	m._unhandled_input(y)
	eq(asked, [["display", ""]], "Y opens Settings on the tab's category")
	ok(not m.visible, "and closes the menu")
	m.open(HADES)
	eq(m.section, 0, "always reopens on This game")
	var esc := InputEventAction.new()
	esc.action = "ui_cancel"
	esc.pressed = true
	m._unhandled_input(esc)
	ok(not m.visible, "B closes")
	_done(x)


class FakeHost extends Control:
	var shown := ""
	var settings: Object
	func show_screen(s: String) -> void: shown = s


class FakeSettings extends RefCounted:
	var opened := []
	func open_category(c: String, part := "") -> void: opened.append([c, part])


func test_all_settings_falls_back_to_the_host() -> void:
	var x := _menu()
	var m: Control = x["m"]
	var host := FakeHost.new()
	host.settings = FakeSettings.new()
	host.add_child(m)
	m.open({})
	m.show_section(3)
	m.open_all_settings()
	eq(host.shown, "settings", "host shows Settings")
	eq(host.settings.opened, [["audio", ""]], "on the Sound page")
	host.remove_child(m)
	host.free()
	_done(x)


func test_focus_chain_never_escapes() -> void:
	var x := _menu()
	var m: Control = x["m"]
	m.open(HADES)
	for t in 6:
		m.show_section(t)
		var f: Array = m.focusables()
		if f.is_empty():
			continue
		eq(f[0].get_node(f[0].focus_neighbor_top), m.tabs[t], "tab %d: up from the first control reaches the tab" % t)
		eq(f[-1].get_node(f[-1].focus_neighbor_bottom), f[-1], "tab %d: down from the last stays put" % t)
		eq(m.tabs[t].get_node(m.tabs[t].focus_neighbor_bottom), f[0], "tab %d: down from the tab enters" % t)
	eq(m.tabs[0].get_node(m.tabs[0].focus_neighbor_left), m.tabs[0], "left from the first tab stays put")
	m.show_section(0)
	var tdp: Node = m.body.find_child("power_tdp", true, false)
	eq(m.focus_target("power.tdp"), tdp.button, "focus kept on a setting by id")
	_done(x)


func test_session_time_and_exit() -> void:
	var x := _menu()
	var m: Control = x["m"]
	var sess: Node = x["session"]
	var g: Dictionary = {"key": "epic:2", "title": "Fortnite", "store": "epic"}
	m.open(g)
	ok(m.body.get_node_or_null("SessionTime") == null, "no time before the game starts")
	sess.started.emit(g)
	m.show_section(0)
	ok(m.body.get_node_or_null("SessionTime") != null, "session time shown")
	ok(m.body.get_node_or_null("ExitGame") == null, "no exit button without a host listening")
	var exits: Array = []
	m.exit_game_requested.connect(func(e): exits.append(e["key"]))
	m.show_section(0)
	var b: Button = m.body.get_node("ExitGame/Button")
	ok(b in m.focusables(), "exit in focus chain")
	b.pressed.emit()
	eq(exits, [], "first press only arms")
	eq(b.text, TS.QM_EXIT_CONFIRM, "asks to press again")
	b.pressed.emit()
	eq(exits, ["epic:2"], "second press exits")
	ok(not m.visible, "menu closes")
	sess.ended.emit(g)
	m.open(g)
	ok(m.body.get_node_or_null("SessionTime") == null, "time gone after the game ends")
	_done(x)


func test_partial_support_and_no_controls() -> void:
	var dev = Screens.FakeDevice.new()
	dev.profile["support"] = "partial"
	dev.profile["unverified"] = ["tdp", "panel.vrr"]
	var m: Control = QuickMenu.new()
	m.setup({"device": dev, "power": Screens.FakePower.new(), "launcher": Screens.FakeLauncher.new(), "gamescope": Screens.FakeGamescope.new()})
	m.open({})
	ok(m.body.get_node_or_null("NoGame") != null, "no game")
	m.show_section(1)
	ok(m.body.get_node_or_null("NoControls") != null, "without Controls: says settings aren't ready")
	m.show_section(5)
	eq(m.body.get_node("Support").text, TS.QM_SUPPORT_PARTIAL, "partial support explained")
	eq(m.body.get_node("Unverified").text, "Not confirmed yet: power limits, VRR range.", "unverified fields named")
	m.free()


func test_this_game_favourite() -> void:
	load("res://scripts/system/settings_file.gd").reset_for_tests()
	var file := ProjectSettings.globalize_path("user://test_qm_collections.json")
	DirAccess.remove_absolute(file)
	var cols: RefCounted = load("res://scripts/library/collections.gd").new(file)
	var x := _menu({"collections": cols})
	var m: Control = x["m"]
	var emu := {"key": "emu:3000000001", "title": "Super Game", "store": "emu", "id": "3000000001"}
	m.open(emu)
	var fav: Node = m.body.get_node_or_null("Favourite")
	ok(fav != null, "Favourite on This game, emulated games too")
	eq(fav.value(), false, "not yet")
	fav.step(1)
	ok(cols.is_favourite("emu:3000000001"), "saved")
	m.close()
	m.open(emu)
	eq(m.body.get_node("Favourite").value(), true, "shows it next time")
	_done(x)
	var y := _menu()
	y["m"].open(HADES)
	ok(y["m"].body.get_node_or_null("Favourite") == null, "no collections service: no row")
	_done(y)
	DirAccess.remove_absolute(file)


## Opening over a game must feel instant (docs/PERFORMANCE.md): This game isn't built again
## on every press. Its rows come back as they were (hidden in between) unless what they're
## built from changed; main.gd builds it once when the game starts (prepare). That hidden
## rows do no work is checked in the tree, in e2e suite_perf.
func test_this_game_kept_between_opens() -> void:
	load("res://scripts/system/settings_file.gd").reset_for_tests()
	var file := ProjectSettings.globalize_path("user://test_qm_kept_collections.json")
	DirAccess.remove_absolute(file)
	var cols: RefCounted = load("res://scripts/library/collections.gd").new(file)
	var x := _menu({"collections": cols})
	var m: Control = x["m"]
	var c: Node = x["c"]
	var sess: Node = x["session"]
	m.prepare(HADES)
	ok(not m.visible, "built out of sight")
	var use: Node = m.body.get_node_or_null("UseGame")
	ok(use != null, "This game is ready before the first press")
	m.open(HADES)
	ok(m.body.get_node("UseGame") == use, "the first press shows what was built")
	var tdp: Control = m.body.get_node("List").views["power.tdp"]
	m.close()
	c.set_value("power.tdp", 9)
	m.open(HADES)
	ok(m.body.get_node("UseGame") == use, "opened again: the same rows")
	eq(int(tdp.desc["value"]), 9, "showing what changed")
	eq(_ids(m).slice(0, 3), ["perf.overlay", "display.fps_limit", "power.tdp"], "focus chain as built")
	# LB / RB away and back: kept too, and nothing armed carries over
	m.switch_tab(1)
	ok(m.body.get_node_or_null("PowerLive") != null and m.body.get_node_or_null("UseGame") == null, "Power shows alone")
	m.switch_tab(-1)
	ok(m.body.get_node("UseGame") == use, "back on This game: the same rows")
	# what the rows are built from changes: built again
	m.close()
	cols.set_favourite("steam:1", true)
	m.open(HADES)
	ok(m.body.get_node("UseGame") != use, "favourited elsewhere: built again")
	eq(m.body.get_node("Favourite").value(), true, "and shows it")
	use = m.body.get_node("UseGame")
	m.close()
	m.model.set_per_game(true)
	m.open(HADES)
	ok(m.body.get_node("UseGame") != use, "own settings turned on: built again")
	eq(m.body.get_node("UseGame").value(), true, "and shows it")
	use = m.body.get_node("UseGame")
	var reset: Node = m.body.get_node("ResetGame")
	reset.pressed.emit()
	eq(reset.title_label.text, TC.RESET_CONFIRM, "Reset armed")
	m.close()
	m.open(HADES)
	ok(m.body.get_node("UseGame") == use, "kept")
	eq(reset.title_label.text, TC.RESET_GAME, "an armed Reset doesn't carry over to the next open")
	reset.pressed.emit()
	ok(m.model.per_game(), "the first press after reopening only asks again")
	m.close()
	sess.started.emit(HADES)
	m.open(HADES)
	ok(m.body.get_node("UseGame") != use, "the game started: built again (session time)")
	ok(m.body.get_node_or_null("SessionTime") != null, "session time shown")
	use = m.body.get_node("UseGame")
	m.close()
	m.open({"key": "steam:2", "title": "Celeste", "store": "steam", "id": "2"})
	ok(m.body.get_node("UseGame") != use, "another game: built again")
	m.close()
	m.prepare(HADES)
	ok(m.body.get_node_or_null("UseGame") != null and str(m.game.get("key")) == "steam:1", "prepare builds for the game it's given")
	_done(x)
	DirAccess.remove_absolute(file)
