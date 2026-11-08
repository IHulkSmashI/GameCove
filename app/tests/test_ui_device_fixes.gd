extends "res://tests/test_case.gd"
## The quick menu's Device section: device fixes with their status, Install /
## Remove, the gyro's accelerometer toggle and the switch to Steam. Every
## command goes to a fake runner; nothing real ever runs.

const QuickMenu := preload("res://scripts/ui/quick_menu.gd")
const BgCommand := preload("res://scripts/ui/bg_command.gd")
const FixRow := preload("res://scripts/ui/fix_row.gd")
const Texts := preload("res://scripts/ui/texts.gd")
const Screens := preload("res://tests/test_ui_screens.gd")

const HELPER := "/usr/libexec/gamecove/gamecove-fix"


## Pretends to be gamecove-fix: keeps a state per fix and answers like it.
class FakeRunner extends RefCounted:
	var calls: Array[String] = []
	var spawned: Array[String] = []
	var spawn_pid := 4242
	var states := {"claw8ex-buttons": "off", "claw8ex-vrr": "on", "claw8ex-gyro": "on"}
	var accel := false
	var pkexec_code := 0   # 126 = password dialog dismissed

	func run(program: String, args: PackedStringArray) -> Dictionary:
		var a := Array(args)
		calls.append(" ".join([program] + a))
		if program == HELPER_PATH and a.size() == 2 and a[1] == "status":
			if not states.has(a[0]):
				return {"code": 65, "out": "gamecove-fix: unknown fix: %s\n" % a[0]}
			var out := "applies=yes\ninstalled=%s\n" % ("no" if states[a[0]] == "off" else "yes")
			if a[0] == "claw8ex-gyro":
				out += "accelerometer=%s\n" % ("yes" if accel else "no")
			return {"code": 0, "out": out + "state=%s\n" % states[a[0]]}
		if program == "pkexec" and a.size() >= 3 and a[0] == HELPER_PATH:
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


func _menu(runner: FakeRunner, fixes := ["claw8ex-buttons", "claw8ex-vrr", "claw8ex-gyro", "fan", "charge-limit"]) -> Control:
	var dev := Screens.FakeDevice.new()
	dev.profile["fixes"] = fixes
	var m: Control = QuickMenu.new()
	m.setup({"device": dev, "power": Screens.FakePower.new(), "launcher": Screens.FakeLauncher.new(),
		"gamescope": Screens.FakeGamescope.new(), "command_runner": runner})
	m.open({})
	m.show_section(4)
	return m


func _row(m: Control, fix: String) -> VBoxContainer:
	return m.body.get_node_or_null(fix)


func _texts(n: Node, out: Array = []) -> Array:
	if n is Label or n is Button:
		out.append(n.text)
	for c in n.get_children():
		_texts(c, out)
	return out


func test_lists_fixes_with_status() -> void:
	var r := FakeRunner.new()
	var m := _menu(r)
	eq(m.device_fixes(), ["claw8ex-buttons", "claw8ex-vrr", "claw8ex-gyro"], "fan and charge limit stay in Power")
	ok(_row(m, "fan") == null and _row(m, "charge-limit") == null, "no rows for Power's fixes")
	eq(r.calls, [HELPER + " claw8ex-buttons status", HELPER + " claw8ex-vrr status", HELPER + " claw8ex-gyro status"],
		"status checked once each, without pkexec")
	eq(_row(m, "claw8ex-buttons").state_label.text, "Off", "buttons off")
	eq(_row(m, "claw8ex-buttons").button.text, "Install", "off offers Install")
	eq(_row(m, "claw8ex-vrr").button.text, "Remove", "on offers Remove")
	ok(m.body.get_node_or_null("claw8ex-gyro-accel") != null, "installed gyro shows the accelerometer toggle")
	eq(m.body.get_node("claw8ex-gyro-accel").value(), false, "accelerometer read from status")
	eq(m.focusables().size(), 5, "three fix buttons, accelerometer, Steam")
	var t := _texts(m.body)
	ok(Texts.FIXES_INTRO in t, "explains the admin password")
	for f in Texts.DEVICE_FIXES:
		ok(Texts.fix_explain(f) in t, "explanation for " + f)
	ok("Needs a restart" in Texts.fix_explain("claw8ex-vrr"), "VRR says it needs a restart")
	ok("cold boot" in Texts.fix_explain("claw8ex-gyro"), "gyro says it needs a cold boot")
	ok(Texts.explain("claw8ex-gyro-accel").begins_with("Off gives steadier aiming."), "accelerometer explained")
	m.show_section(4)
	eq(r.calls.size(), 3, "switching back to the section doesn't check again")
	m.close()
	m.open({})
	m.show_section(4)
	eq(r.calls.size(), 6, "reopening the menu checks again")
	m.free()


func test_install_and_remove() -> void:
	var r := FakeRunner.new()
	var m := _menu(r)
	r.calls.clear()
	_row(m, "claw8ex-buttons").button.pressed.emit()
	eq(r.calls, ["pkexec %s claw8ex-buttons install" % HELPER, HELPER + " claw8ex-buttons status"], "install through pkexec, then check")
	eq(_row(m, "claw8ex-buttons").state_label.text, "On", "now on")
	ok(m.status_label.text.begins_with("MSI buttons installed."), "result shown: " + m.status_label.text)
	eq(m.focus_target("claw8ex-buttons"), _row(m, "claw8ex-buttons").button, "focus can stay on the row after the rebuild")

	r.calls.clear()
	_row(m, "claw8ex-vrr").button.pressed.emit()
	eq(r.calls[0], "pkexec %s claw8ex-vrr remove" % HELPER, "remove through pkexec")
	ok(m.status_label.text.contains("Restart"), "remove says to restart")
	eq(_row(m, "claw8ex-vrr").button.text, "Install", "removed fix offers Install again")

	r.pkexec_code = 126
	_row(m, "claw8ex-vrr").button.pressed.emit()
	eq(m.status_label.text, Texts.NO_PASSWORD, "cancelled password prompt explained")
	eq(r.states["claw8ex-vrr"], "off", "nothing changed")
	m.free()


func test_states_without_an_action() -> void:
	var r := FakeRunner.new()
	r.states = {"claw8ex-buttons": "not-needed", "claw8ex-vrr": "n/a"}
	var m := _menu(r)
	ok(_row(m, "claw8ex-buttons").button == null, "not needed: no button")
	ok(_row(m, "claw8ex-buttons").get_node_or_null("Note") != null, "not needed: a note says why")
	ok(_row(m, "claw8ex-vrr").button == null, "doesn't apply: no button")
	var gyro := _row(m, "claw8ex-gyro")
	eq(gyro.state, "unknown", "helper said unknown fix")
	eq(gyro.button.text, "Check again", "unknown offers Check again")
	ok(m.body.get_node_or_null("claw8ex-gyro-accel") == null, "no accelerometer toggle without the gyro fix")
	eq(m.focusables().size(), 2, "Check again and Steam")
	r.states["claw8ex-gyro"] = "off"
	gyro.button.pressed.emit()
	eq(_row(m, "claw8ex-gyro").button.text, "Install", "checked again")
	m.free()


func test_accelerometer_toggle() -> void:
	var r := FakeRunner.new()
	var m := _menu(r)
	r.calls.clear()
	m.body.get_node("claw8ex-gyro-accel").step(1)
	eq(r.calls[0], "pkexec %s claw8ex-gyro set accel-on" % HELPER, "single-token value")
	ok(r.accel, "accelerometer on")
	eq(m.body.get_node("claw8ex-gyro-accel").value(), true, "toggle shows the new value")
	ok(m.status_label.text.begins_with("Accelerometer on."), "result shown")
	r.pkexec_code = 126
	m.body.get_node("claw8ex-gyro-accel").step(1)
	eq(m.body.get_node("claw8ex-gyro-accel").value(), true, "refused change rolls back")
	eq(m.status_label.text, Texts.NO_PASSWORD, "refusal explained")
	m.free()


func test_switch_to_steam_needs_a_second_press() -> void:
	var r := FakeRunner.new()
	var m := _menu(r, [])
	eq(m.focusables().size(), 1, "no fixes: just the Steam button")
	ok(m.body.get_node_or_null("FixesHeader") == null, "no fixes header")
	var b: Button = m.focusables()[0]
	b.pressed.emit()
	eq(r.spawned, [], "first press only asks")
	eq(b.text, Texts.STEAM_CONFIRM, "button asks to press again")
	b.focus_exited.emit()
	eq(b.text, Texts.STEAM_TITLE, "moving away cancels")
	b.pressed.emit()
	b.pressed.emit()
	eq(r.spawned, ["/usr/bin/gamecove-session-select steam"], "second press switches")
	r.spawn_pid = -1
	b.pressed.emit()
	b.pressed.emit()
	eq(m.status_label.text, Texts.STEAM_FAILED, "failure explained")
	eq(r.calls, [], "nothing else ran")
	m.free()


func test_focus_chain() -> void:
	var m := _menu(FakeRunner.new())
	var f: Array = m.focusables()
	eq(f[0].get_node(f[0].focus_neighbor_top), m.tabs[4], "up from the first fix reaches the tab")
	eq(f[0].get_node(f[0].focus_neighbor_bottom), f[1], "down goes to the next fix")
	eq(f[-1].get_node(f[-1].focus_neighbor_bottom), f[-1], "down from Steam stays put")
	eq(m.tabs[4].get_node(m.tabs[4].focus_neighbor_bottom), f[0], "down from the tab enters the section")
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
