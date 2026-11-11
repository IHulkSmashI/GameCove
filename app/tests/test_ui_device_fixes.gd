extends "res://tests/test_case.gd"
## The quick menu's Device tab: the fixes summary that links to Settings >
## Device > Fixes (the fixes themselves are on that page, test_fixes.gd and
## test_ui_device_pages.gd) and the switch to Steam. Every command goes to a
## fake runner; nothing real ever runs.

const QuickMenu := preload("res://scripts/ui/quick_menu.gd")
const BgCommand := preload("res://scripts/ui/bg_command.gd")
const FixRow := preload("res://scripts/ui/fix_row.gd")
const Texts := preload("res://scripts/ui/texts.gd")
const Screens := preload("res://tests/test_ui_screens.gd")
const TC := preload("res://scripts/ui/texts_controls.gd")

const HELPER := "/usr/libexec/gamecove/gamecove-fix"
const SET_HELPER := "/usr/libexec/gamecove/gamecove-fix-set"


## Pretends to be gamecove-fix: keeps a state per fix and answers like it.
class FakeRunner extends RefCounted:
	var calls: Array[String] = []
	var spawned: Array[String] = []
	var spawn_pid := 4242
	var states := {"claw8ex-buttons": "off", "claw8ex-vrr": "on", "claw8ex-gyro": "on"}
	var accel := false
	var pkexec_code := 0   # 126 = password dialog dismissed
	var switch_code := 0   # gamecove-session-select's exit code
	var switch_out := ""

	func run(program: String, args: PackedStringArray) -> Dictionary:
		var a := Array(args)
		if program == "/usr/bin/gamecove-session-select":
			spawned.append(" ".join([program] + a))   # the session switch (run, so its result is read)
			return {"code": switch_code, "out": switch_out}
		calls.append(" ".join([program] + a))
		if program == HELPER_PATH and a.size() == 2 and a[1] == "status":
			if not states.has(a[0]):
				return {"code": 65, "out": "gamecove-fix: unknown fix: %s\n" % a[0]}
			var out := "applies=yes\ninstalled=%s\n" % ("no" if states[a[0]] == "off" else "yes")
			if a[0] == "claw8ex-gyro":
				out += "accelerometer=%s\n" % ("yes" if accel else "no")
			return {"code": 0, "out": out + "state=%s\n" % states[a[0]]}
		if program == "pkexec" and a.size() >= 3 and (a[0] == HELPER_PATH or (a[0] == SET_PATH and a[2] == "set")):
			if pkexec_code != 0:
				return {"code": pkexec_code, "out": ""}
			match a[2]:
				"install": states[a[1]] = "restart" if a[1] != "claw8ex-buttons" else "on"
				"remove": states[a[1]] = "off"
				"set": accel = a[3] == "accel-on"
			return {"code": 0, "out": "done\n"}
		return {"code": 127, "out": ""}

	func spawn(program: String, args: PackedStringArray) -> int:
		spawned.append(" ".join([program] + Array(args)))
		return spawn_pid

	const HELPER_PATH := "/usr/libexec/gamecove/gamecove-fix"
	const SET_PATH := "/usr/libexec/gamecove/gamecove-fix-set"


const DEVICE_TAB := 5


func _menu(runner: FakeRunner, fixes := ["claw8ex-buttons", "claw8ex-vrr", "claw8ex-gyro", "fan", "charge-limit"], extra := {}) -> Control:
	var dev := Screens.FakeDevice.new()
	dev.profile["fixes"] = fixes
	var m: Control = QuickMenu.new()
	var svc := {"device": dev, "power": Screens.FakePower.new(), "launcher": Screens.FakeLauncher.new(),
		"gamescope": Screens.FakeGamescope.new(), "command_runner": runner}
	svc.merge(extra, true)
	m.setup(svc)
	m.open({})
	m.show_section(DEVICE_TAB)
	return m


func _texts(n: Node, out: Array = []) -> Array:
	if n is Label or n is Button:
		out.append(n.text)
	for c in n.get_children():
		_texts(c, out)
	return out


class FakeFixes extends RefCounted:
	signal changed(rows: Array)
	var list := [{"id": "a", "status": "applied"}, {"id": "b", "status": "applied"}, {"id": "c", "status": "available"}]
	func rows() -> Array: return list
	func counts() -> Dictionary:
		var c := {"applied": 0, "available": 0, "os-fixed": 0, "not-needed": 0}
		for r in list:
			c["applied" if r["status"] == "applied" else "available"] += 1
		return c


func test_fixes_summary_links_to_the_fixes_page() -> void:
	var m := _menu(FakeRunner.new(), ["claw8ex-buttons", "fan"])
	var row: Node = m.body.get_node("Fixes")
	eq(row.value_label.text, TC.FIXES_COUNT_ONLY % 2, "without the service: how many fixes the device row lists")
	var asked := []
	m.settings_requested.connect(func(cat, part): asked.append([cat, part]))
	m.visible = true
	row.pressed.emit()
	eq(asked, [["device", "fixes"]], "opens Settings > Device > Fixes")
	ok(not m.visible, "menu closes")
	m.free()
	var m2 := _menu(FakeRunner.new(), [], {"fixes": FakeFixes.new()})
	eq(m2.body.get_node("Fixes").value_label.text, TC.fixes_line({"applied": 2, "available": 1}), "counts from the Fixes service")
	ok(TC.fixes_line({"applied": 2, "available": 1}).contains("1"), "names what's left")
	m2.free()
	var m3 := _menu(FakeRunner.new(), [])
	eq(m3.body.get_node("Fixes").value_label.text, TC.FIXES_NONE, "no fixes")
	m3.free()


func test_device_lines() -> void:
	var m := _menu(FakeRunner.new())
	var t := _texts(m.body)
	ok("MSI Claw 8 EX AI+" in t, "device name")
	ok(m.body.find_child("BrandLogo", true, false) != null, "maker logo beside the name")
	eq(m.maker_name({}, "MSI Claw 8 EX"), "MSI", "maker from the name when the row has none")
	eq(m.maker_name({"maker": "Lenovo"}, "Legion Go S"), "Lenovo", "row's maker first")
	ok(t.any(func(x): return str(x).contains("Intel Panther Lake")), "chip")
	ok("Tested on hardware" in t or "TESTED ON HARDWARE" in t, "support chip")
	m.free()


func _steam(m: Control) -> Button:
	return m.body.get_node("SteamMode/Button")


func test_switch_to_steam_needs_a_second_press() -> void:
	var r := FakeRunner.new()
	var m := _menu(r, [])
	var b := _steam(m)
	ok(b in m.focusables(), "Steam button in the focus chain")
	b.pressed.emit()
	eq(r.spawned, [], "first press only asks")
	eq(b.text, Texts.STEAM_CONFIRM, "button asks to press again")
	b.focus_exited.emit()
	eq(b.text, Texts.STEAM_TITLE, "moving away cancels")
	b.pressed.emit()
	b.pressed.emit()
	eq(r.spawned, ["/usr/bin/gamecove-session-select steam"], "second press switches")
	eq(m.status_label.text, Texts.STEAM_SWITCHING, "switching (the logout takes GameCove away)")
	r.switch_code = 2
	r.switch_out = "gamecove-session-select: steamosctl (steamos-manager) not found; switch sessions from the login screen instead\n"
	b.pressed.emit()
	b.pressed.emit()
	eq(m.status_label.text, Texts.SWITCH_FAILED % "steamosctl (steamos-manager) not found; switch sessions from the login screen instead",
		"review M8: the switch's own reason shown")
	eq(r.calls, [], "nothing else ran")
	m.free()


func test_switch_to_desktop_reaches_the_real_desktop() -> void:
	# review S1-1: GameCove itself must always offer a way to Desktop Mode
	var r := FakeRunner.new()
	var m := _menu(r, [])
	var b: Button = m.body.get_node("DesktopMode/Button")
	ok(b in m.focusables(), "Desktop button in the focus chain")
	b.pressed.emit()
	eq(r.spawned, [], "first press only asks")
	b.focus_exited.emit()
	eq(b.text, Texts.DESKTOP_TITLE, "moving away cancels")
	b.pressed.emit()
	b.pressed.emit()
	eq(r.spawned, ["/usr/bin/gamecove-session-select desktop"], "second press switches to the desktop")
	m.free()


func test_focus_chain() -> void:
	var m := _menu(FakeRunner.new())
	var f: Array = m.focusables()
	eq(f[0].get_node(f[0].focus_neighbor_top), m.tabs[DEVICE_TAB], "up from the first row reaches the tab")
	eq(f[-1].get_node(f[-1].focus_neighbor_bottom), f[-1], "down from Desktop stays put")
	eq(f[-2], _steam(m), "Steam, then")
	eq(f[-1], m.body.get_node("DesktopMode/Button"), "Desktop last")
	eq(m.tabs[DEVICE_TAB].get_node(m.tabs[DEVICE_TAB].focus_neighbor_bottom), f[0], "down from the tab enters the section")
	m.free()


func test_bg_command_helpers() -> void:
	eq(BgCommand.key_values("applies=yes\nnoise line\nrange=30-120\nstate=on\nnext=a=b\n"),
		{"applies": "yes", "range": "30-120", "state": "on", "next": "a=b"}, "key=value lines")
	eq(BgCommand.error_line("installing\nerror: wrong sha256\n"), "wrong sha256", "fix.sh error line")
	eq(BgCommand.error_line("ok\n"), "", "no error line")
	var bg: Node = BgCommand.new()
	var r := FakeRunner.new()
	bg.runner = r
	var got := []
	bg.finished.connect(func(id, code, out): got.append([id, code, out]))
	ok(bg.run("x", "/bin/nothing", PackedStringArray()), "runs")
	eq(got, [["x", 127, ""]], "finished with the runner's result")
	ok(not bg.busy("x"), "not busy afterwards")
	ok(bg.spawn("prog", PackedStringArray(["a"])), "spawn reports a pid")
	eq(FixRow.verb_for("restart"), "remove", "restart pending can be undone")
	eq(FixRow.verb_for("other-override"), "", "someone else's override: hands off")
	bg.free()


class FakeController extends RefCounted:
	var released := 0
	var started := 0
	var active := true
	var done := Callable()
	func release_intercept(cb := Callable()) -> void:
		released += 1
		active = false
		done = cb
	func start_intercept() -> bool:
		started += 1
		active = true
		return true
	func intercept_state() -> Dictionary:
		return {"active": active}


## Review M8: a failed switch gives GameCove the controller back (Guide was dead until a restart).
func test_failed_switch_takes_the_controller_back() -> void:
	var r := FakeRunner.new()
	var ctl := FakeController.new()
	var m := _menu(r, [], {"controller": ctl})
	r.switch_code = 1
	r.switch_out = "gamecove-session-select: steamosctl set-default-login-mode game didn't take (reads back 'desktop')\n"
	var b: Button = m.body.get_node("DesktopMode/Button")
	b.pressed.emit()
	b.pressed.emit()
	ctl.done.call()
	eq(r.spawned, ["/usr/bin/gamecove-session-select desktop"], "switch ran")
	eq(ctl.started, 1, "intercept on again")
	ok(m.status_label.text.contains("didn't take"), "reason shown: " + m.status_label.text)
	r.switch_code = 0
	ctl.started = 0
	_steam(m).pressed.emit()
	_steam(m).pressed.emit()
	ctl.done.call()
	eq(ctl.started, 0, "a switch that worked leaves the controller to the next session")
	m.switch_timed_out(m._switch_gen)
	eq(ctl.started, 1, "still here after the wait: the controller comes back")
	eq(m.status_label.text, Texts.SWITCH_STUCK, "and says so")
	m.switch_timed_out(m._switch_gen - 1)
	eq(ctl.started, 1, "a stale timer does nothing")
	m.free()


## Review at ff76ca4, session Low 6: a switch that didn't happen leaves no "just left" mark behind for `leave`.
func test_a_switch_that_never_came_forgets_its_left_mark() -> void:
	var dir := OS.get_user_data_dir().path_join("left_mark_test")
	DirAccess.make_dir_recursive_absolute(dir)
	var was := OS.get_environment("XDG_RUNTIME_DIR")
	OS.set_environment("XDG_RUNTIME_DIR", dir)
	FileAccess.open(dir.path_join("gamecove-left"), FileAccess.WRITE).store_string("1\n")
	var m := _menu(FakeRunner.new(), [], {})
	m.switch_timed_out(m._switch_gen)
	ok(not FileAccess.file_exists(dir.path_join("gamecove-left")), "the mark is gone once GameCove is back in charge")
	OS.set_environment("XDG_RUNTIME_DIR", was)
	m.free()


## Final review, session: Power stops writing before the switch runs (Auto TDP, charge hold, thermald
## hold, the 15 s check), and writes again when the switch didn't happen.
class LeavingPower extends "res://tests/test_ui_screens.gd".FakePower:
	var log: Array = []
	var done := Callable()
	func request_leave(cb := Callable()) -> void:
		log.append("leave")
		done = cb
	func request_cancel_leave() -> void:
		log.append("cancel")


func test_switch_quiets_power_first_and_wakes_it_when_it_fails() -> void:
	var r := FakeRunner.new()
	var pw := LeavingPower.new()
	var m := _menu(r, [], {"power": pw})
	r.switch_code = 0
	_steam(m).pressed.emit()
	_steam(m).pressed.emit()
	eq(pw.log, ["leave"], "Power is told first")
	eq(r.spawned, [], "the switch waits until Power has stopped writing")
	pw.done.call()
	eq(r.spawned, ["/usr/bin/gamecove-session-select steam"], "then the switch runs")
	eq(pw.log, ["leave"], "a switch that worked leaves Power quiet")
	m.switch_timed_out(m._switch_gen)
	eq(pw.log, ["leave", "cancel"], "GameCove is still here: Power writes again")
	r.switch_code = 1
	r.switch_out = "gamecove-session-select: no\n"
	r.spawned.clear()
	_steam(m).pressed.emit()
	_steam(m).pressed.emit()
	pw.done.call()
	eq(pw.log, ["leave", "cancel", "leave", "cancel"], "a failed switch wakes Power at once")
	ok(QuickMenu.SWITCH_LIMIT_S >= 40.0 + 10.0 + 10.0, "the overall wait covers a slow switch (baseline 40 s, root 10 s, Steam 10 s)")
	m.free()


func test_switch_to_steam_hands_the_controller_back_first() -> void:
	var r := FakeRunner.new()
	var ctl := FakeController.new()
	var m := _menu(r, [], {"controller": ctl})
	var b := _steam(m)
	b.pressed.emit()
	b.pressed.emit()
	eq(ctl.released, 1, "InterceptMode reset asked for")
	eq(r.spawned, [], "the session switch waits until it's written")
	ctl.done.call()
	eq(r.spawned, ["/usr/bin/gamecove-session-select steam"], "then switches")
	m.free()
