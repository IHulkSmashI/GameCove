extends "res://tests/test_case.gd"
## The InputPlumber intercept: gdbus monitor lines, activation per device,
## D-Bus events turned into actions and joypad events, and the modes the
## Controller sends. Fake runner only; no process, no D-Bus.

const Intercept := preload("res://scripts/input/intercept.gd")
const ControllerScript := preload("res://scripts/input/controller.gd")
const Fake := preload("res://tests/fixtures/system/fake_runner.gd")
const IPTest := preload("res://tests/test_input_controller.gd")

const DEV0 := "/org/shadowblip/InputPlumber/CompositeDevice0"
const SETP := "busctl --system set-property org.shadowblip.InputPlumber "


func test_parse_real_gdbus_lines() -> void:
	eq(Intercept.parse_line("Monitoring signals from all objects owned by org.shadowblip.InputPlumber"), {"kind": "started"})
	eq(Intercept.parse_line("The name org.shadowblip.InputPlumber is owned by :1.42"), {"kind": "owner", "owner": ":1.42"})
	eq(Intercept.parse_line("The name org.shadowblip.InputPlumber does not have an owner"), {"kind": "owner", "owner": ""})
	var e := Intercept.parse_line("/org/shadowblip/InputPlumber/devices/target/dbus0: org.shadowblip.Input.DBusDevice.InputEvent ('ui_guide', 1.0)")
	eq(e, {"kind": "event", "path": "/org/shadowblip/InputPlumber/devices/target/dbus0", "event": "ui_guide", "value": 1.0})
	var a := Intercept.parse_line("/org/shadowblip/InputPlumber/devices/target/dbus0: org.shadowblip.Input.DBusDevice.InputEvent ('ui_left', 0.72999999999999998)")
	ok(absf(float(a["value"]) - 0.73) < 0.001, "full-precision doubles")
	var add := Intercept.parse_line("/org/shadowblip/InputPlumber: org.freedesktop.DBus.ObjectManager.InterfacesAdded (objectpath '/org/shadowblip/InputPlumber/CompositeDevice1', {'org.shadowblip.Input.CompositeDevice': {'Name': <'x'>}})")
	eq(add, {"kind": "added", "path": "/org/shadowblip/InputPlumber/CompositeDevice1"})
	eq(Intercept.parse_line("/org/shadowblip/InputPlumber/devices/target/dbus0: org.shadowblip.Input.DBusDevice.TouchEvent ('ui_touch', 0, true, 1.0, 0.5, 0.5)"), {}, "other signals ignored")
	eq(Intercept.parse_line("/x: org.freedesktop.DBus.Properties.PropertiesChanged ('a', {}, [])"), {})
	eq(Intercept.parse_line(""), {})
	eq(Intercept.parse_line("garbage"), {})


func test_activation_per_device() -> void:
	eq(Intercept.activation_for("msi-claw-8-ex"), {"events": ["Gamepad:Button:Guide"], "target": "Gamepad:Button:Guide"}, "Claw: Guide")
	eq(Intercept.activation_for("gpd-win-4"), {"events": ["Gamepad:Button:QuickAccess"], "target": "Gamepad:Button:QuickAccess"}, "WIN 4: no Guide, Quick Access")
	eq(Intercept.activation_for("gpd-win-max-2"), {"events": ["Gamepad:Button:Select", "Gamepad:Button:Start"], "target": "Gamepad:Button:Guide"}, "WIN Max 2: View + Menu")
	eq(Intercept.chords_for("msi-claw-8-ex").keys().has("home"), false, "a device with a home button gets no home chord")
	eq(Intercept.chords_for("gpd-win-4").get("home"), ["QuickAccess", "South"], "WIN 4: Quick Access + A for home")
	eq(Intercept.chords_for("gpd-win-max-2"), {}, "no modifier, no chords")


func _rec(device := "msi-claw-8-ex") -> Array:
	var i: RefCounted = Intercept.new()
	var log := {"inject": [], "actions": [], "buttons": []}
	i.device = device
	i.inject = func(e: InputEvent): log["inject"].append(e)
	i.on_action = func(a: String): log["actions"].append(a)
	i.on_button = func(c: String, p: bool): log["buttons"].append([c, p])
	return [i, log]


func test_navigation_becomes_joypad_events() -> void:
	var t := _rec()
	var i: RefCounted = t[0]
	var log: Dictionary = t[1]
	i.handle("ui_accept", 1.0)
	i.handle("ui_accept", 0.0)
	eq(log["inject"].size(), 2, "press and release")
	var e: InputEventJoypadButton = log["inject"][0]
	eq(e.button_index, JOY_BUTTON_A)
	ok(e.pressed and not log["inject"][1].pressed, "pressed then released")
	eq(log["buttons"], [["South", true], ["South", false]], "button test sees South")
	log["inject"].clear()
	i.handle("ui_left", 0.73)
	i.handle("ui_left", 0.4)   # still held (hysteresis)
	i.handle("ui_left", 0.2)
	eq(log["inject"].size(), 2, "stick: one press, one release")
	eq(log["inject"][0].button_index, JOY_BUTTON_DPAD_LEFT)
	log["inject"].clear()
	i.handle("ui_r2", 0.8)
	ok(log["inject"][0] is InputEventJoypadMotion and log["inject"][0].axis == JOY_AXIS_TRIGGER_RIGHT, "triggers stay analog")
	eq(log["actions"], [], "no actions from navigation")


func test_guide_and_quick_become_actions() -> void:
	var t := _rec()
	var i: RefCounted = t[0]
	var log: Dictionary = t[1]
	i.handle("ui_guide", 1.0)
	i.handle("ui_guide", 0.0)
	i.handle("ui_quick", 1.0)
	i.handle("ui_quick", 0.0)
	eq(log["actions"], ["home", "quick_menu"], "Guide -> home, Quick Access -> quick menu, on press")
	eq(log["inject"], [], "special buttons never reach the UI as joypad buttons")
	var z := _rec("zotac-zone")
	z[0].handle("ui_quick2", 1.0)
	eq(z[1]["actions"], ["home"], "Zotac's Home button (QuickAccess2) opens home")
	var o := _rec("onexplayer-3")
	o[0].handle("ui_quick2", 1.0)
	eq(o[1]["actions"], ["osk"], "OneXPlayer 3's keyboard button (QuickAccess2) opens the keyboard")


func test_fallback_chord_on_a_device_without_home() -> void:
	var t := _rec("gpd-win-4")
	var i: RefCounted = t[0]
	var log: Dictionary = t[1]
	i.handle("ui_quick", 1.0)
	i.handle("ui_accept", 1.0)
	i.handle("ui_accept", 0.0)
	i.handle("ui_quick", 0.0)
	eq(log["actions"], ["home"], "Quick Access + A = home")
	eq(log["inject"], [], "the chord's A never reaches the UI")
	i.handle("ui_quick", 1.0)
	i.handle("ui_quick", 0.0)
	eq(log["actions"], ["home", "quick_menu"], "Quick Access alone opens the quick menu on release")


func _ctl(test_name: String) -> Array:
	var f: RefCounted = Fake.new()
	var _ip = IPTest.FakeIP.new(f, fixture("system/inputplumber"))
	var c: Node = ControllerScript.new()
	var home := ProjectSettings.globalize_path("user://test_intercept/" + test_name)
	DirAccess.make_dir_recursive_absolute(home)
	c.setup(f, home)
	c.device_id = "msi-claw-8-ex"
	return [c, f]


func _modes(f: RefCounted) -> Array:
	var out := []
	for cmd in f.calls:
		if cmd.begins_with(SETP + DEV0 + " org.shadowblip.Input.CompositeDevice InterceptMode u "):
			out.append(int(cmd.get_slice(" u ", 1)))
	return out


func test_controller_modes_follow_focus() -> void:
	var t := _ctl("modes")
	var c: Node = t[0]
	var f: RefCounted = t[1]
	f.handler = func(cmd: String):
		if cmd.begins_with(SETP) or cmd.contains(" SetInterceptActivation "):
			return {"code": 0, "out": ""}
		return null
	c.setup_intercept_for_tests()
	eq(_modes(f), [], "nothing before the monitor runs")
	c.monitor_line({"kind": "started"})
	ok(f.calls.has("busctl --system call org.shadowblip.InputPlumber " + DEV0 + " org.shadowblip.Input.CompositeDevice SetInterceptActivation ass 1 Gamepad:Button:Guide Gamepad:Button:Guide"), "activation = Guide")
	eq(_modes(f).back(), 2, "our UI has focus: Always")
	c.start_game("steam:1")
	eq(_modes(f).back(), 1, "a game has focus: Pass")
	var got := []
	c.ui_action.connect(func(a): got.append(a))
	c.monitor_line(Intercept.parse_line("/org/shadowblip/InputPlumber/devices/target/dbus0: org.shadowblip.Input.DBusDevice.InputEvent ('ui_guide', 1.0)"))
	eq(got, ["home"], "Guide in a game -> ui_action(home)")
	c.set_game_focused(false)
	eq(_modes(f).back(), 2, "home over the game: Always")
	c.set_game_focused(true)
	eq(_modes(f).back(), 1, "back to the game: Pass")
	c.end_game()
	eq(_modes(f).back(), 2, "game over: Always")
	c.set_button_test(true)
	eq(_modes(f).back(), 0, "button test with no game: None, so paddles reach Godot")
	c.set_button_test(false)
	eq(_modes(f).back(), 2, "button test over")
	c.monitor_line({"kind": "exited"})
	eq(_modes(f).back(), 0, "monitor gone: None, never stuck in Always")
	eq(c.intercept_state()["listening"], false)
	c.free()


func test_new_device_and_restart_reapply() -> void:
	var t := _ctl("readd")
	var c: Node = t[0]
	var f: RefCounted = t[1]
	f.handler = func(cmd: String):
		if cmd.begins_with(SETP) or cmd.contains(" SetInterceptActivation "):
			return {"code": 0, "out": ""}
		return null
	c.setup_intercept_for_tests()
	c.monitor_line({"kind": "started"})
	var n := _modes(f).size()
	c.monitor_line({"kind": "added", "path": "/org/shadowblip/InputPlumber/CompositeDevice3"})
	ok(_modes(f).size() > n, "new composite device gets the intercept")
	n = _modes(f).size()
	c.monitor_line({"kind": "added", "path": "/org/shadowblip/InputPlumber/devices/target/dbus3"})
	eq(_modes(f).size(), n, "target devices don't")
	c.monitor_line({"kind": "owner", "owner": ":1.77"})
	ok(_modes(f).size() > n, "InputPlumber restarted: applied again")
	c.free()


func test_only_in_our_own_session() -> void:
	ok(ControllerScript.intercept_wanted("silent", "", true), "GameCove session in gamescope")
	ok(not ControllerScript.intercept_wanted("", "", true), "Steam's session (no GAMECOVE_STEAM_MODE): leave InputPlumber alone")
	ok(not ControllerScript.intercept_wanted("silent", "", false), "not in gamescope (desktop window)")
	ok(not ControllerScript.intercept_wanted("silent", "0", true), "GAMECOVE_INTERCEPT=0 turns it off")
	var t := _ctl("off")
	var c: Node = t[0]
	c.set_game_focused(true)
	c.set_button_test(true)
	eq(_modes(t[1]), [], "never touches InputPlumber when not intercepting")
	c.free()


## End to end: main.gd's calls into SessionWiring (game start, window focus,
## quick menu) reach a real Controller and come out as InterceptMode writes.
func test_session_wiring_drives_intercept_mode() -> void:
	var SW = load("res://scripts/ui/games/session_wiring.gd")
	var t := _ctl("wiring")
	var c: Node = t[0]
	var f: RefCounted = t[1]
	f.handler = func(cmd: String):
		if cmd.begins_with(SETP) or cmd.contains(" SetInterceptActivation "):
			return {"code": 0, "out": ""}
		return null
	c.setup_intercept_for_tests()
	c.monitor_line({"kind": "started"})
	var w = SW.new()
	w.setup({"controller": c})
	w.home_in_front(true)
	eq(_modes(f).back(), 2, "no game: our UI keeps Always")
	w.game_started({"key": "steam:42", "store": "steam", "id": "42"}, 42)
	eq(_modes(f).back(), 1, "game starts: Pass")
	w.home_in_front(false)
	eq(_modes(f).back(), 1, "game window in front: Pass")
	eq(c.intercept_state()["game_focused"], true)
	w.home_in_front(true)
	eq(_modes(f).back(), 2, "home in front of the game: Always")
	w.home_in_front(false)
	w.menu_over_game(true)
	eq(_modes(f).back(), 2, "quick menu over the game: Always")
	w.menu_over_game(false)
	eq(_modes(f).back(), 1, "quick menu closed: Pass again")
	# InputPlumber moved itself to Always on Guide; nothing changed on our
	# side, but the mode is written again instead of trusting the last one.
	var n := _modes(f).size()
	w.sync_focus()
	eq(_modes(f).size(), n + 1, "focus sync re-sends the mode")
	eq(_modes(f).back(), 1, "still Pass while the game is in front")
	w.game_ended({"key": "steam:42", "store": "steam", "id": "42"})
	eq(_modes(f).back(), 2, "game over: Always")
	w.home_in_front(true)   # GameCove comes back in front
	n = _modes(f).size()
	w.menu_over_game(true)
	w.menu_over_game(false)
	eq(_modes(f).size(), n, "quick menu with no game leaves the mode alone")
	# review M15: no game, and Steam's install dialog takes focus: it gets the controller
	w.home_in_front(false)
	eq(_modes(f).back(), 1, "another window in front with no game: Pass")
	n = _modes(f).size()
	w.home_in_front(false)
	eq(_modes(f).size(), n, "nothing changed: nothing sent")
	w.home_in_front(true)
	eq(_modes(f).back(), 2, "GameCove in front again: Always")
	c.free()


func test_release_intercept_resets_every_device() -> void:
	var t := _ctl("release")
	var c: Node = t[0]
	var f: RefCounted = t[1]
	f.handler = func(cmd: String):
		if cmd.begins_with(SETP) or cmd.contains(" SetInterceptActivation "):
			return {"code": 0, "out": ""}
		return null
	c.setup_intercept_for_tests()
	c.monitor_line({"kind": "started"})
	eq(_modes(f).back(), 2, "intercepting: Always")
	var done := [false]
	c.release_intercept(func(): done[0] = true)
	eq(_modes(f).back(), 0, "released: InterceptMode 0")
	var zeroed: Array = f.calls.filter(func(cmd): return cmd.begins_with(SETP) and cmd.ends_with("InterceptMode u 0"))
	ok(zeroed.size() >= 1, "every composite device gets 0")
	ok(done[0], "callback after the write")
	eq(c.intercept_state()["active"], false, "no longer intercepting")
	var n: int = f.calls.size()
	c.set_game_focused(false)
	c.set_game_focused(true)
	eq(f.calls.size(), n, "focus changes after release write nothing")
	c.free()


## Review M11: a monitor that exits by itself is no longer "running", so Controller's restart
## timer (`not intercept.running()`) starts a new one.
func test_monitor_that_died_is_not_running() -> void:
	var ic := Intercept.new()
	ok(ic.start_monitor("sh", ["-c", "echo 'Monitoring signals from all objects owned by org.shadowblip.InputPlumber'; exit 1"]), "started")
	var pid: int = ic._pid
	var waited := 0
	while OS.is_process_running(pid) and waited < 3000:
		OS.delay_msec(20)
		waited += 20
	ok(not OS.is_process_running(pid), "the child exited")
	ok(not ic.running(), "running() says so")
	ok(ic.start_monitor("sh", ["-c", "sleep 5"]), "a new monitor starts in its place")
	ok(ic.running(), "and runs")
	ok(ic._pid != pid, "a new process")
	ic.stop_monitor()
	ok(not ic.running(), "stopped")

