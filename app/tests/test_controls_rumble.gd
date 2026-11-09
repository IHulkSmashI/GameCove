extends "res://tests/test_case.gd"
## Rumble controls (input/rumble.gd through providers/controller.gd): the
## controller firmware's strength through the kernel (fixes/controller-rumble,
## run for real on a fixture tree), InputPlumber's ForceFeedback, Handheld
## Daemon's settings, and the reasons where nothing can set a strength.

const Provider := preload("res://scripts/controls/providers/controller.gd")
const Rumble := preload("res://scripts/controls/input/rumble.gd")
const ControlsScript := preload("res://scripts/controls/controls.gd")
const Fakes := preload("res://tests/fixtures/controller/rumble_fakes.gd")
const DeviceScript := preload("res://scripts/device/device.gd")

const PAD := ["Gamepad:Button:South", "Gamepad:Button:East", "Gamepad:Button:Guide", "Gamepad:Button:QuickAccess",
	"Gamepad:Axis:LeftStick", "Gamepad:Axis:RightStick"]


func _row(id: String) -> Dictionary:
	for r in DeviceScript.load_table():
		if r.get("id") == id:
			return r
	return {}


func _root(test_name: String) -> String:
	var d := ProjectSettings.globalize_path("user://test_ctl_rumble/" + test_name)
	_rmdir(d)
	DirAccess.make_dir_recursive_absolute(d + "/home")
	return d


func _rmdir(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.include_hidden = true
	for f in d.get_files():
		DirAccess.remove_absolute(path + "/" + f)
	for sub in d.get_directories():
		_rmdir(path + "/" + sub)
	DirAccess.remove_absolute(path)


func _setup(f: RefCounted, row: Dictionary) -> Node:
	var reg: Node = ControlsScript.new()
	reg.sync_mode = true
	var c: Dictionary = f.ctx(row)
	reg.setup(c)
	var p := Provider.new()
	p.setup(c)
	reg.register_provider(p)
	reg.detect_all()
	return reg


func _c(reg: Node, id: String) -> RefCounted:
	var c: RefCounted = reg.control(id)
	ok(c != null, "control %s exists" % id)
	return c


## Writes like a later user action: the snapshot cache doesn't hide the change.
func _w(reg: Node, id: String, v: Variant) -> bool:
	var c := _c(reg, id)
	return c != null and c.write(v)


func _value(reg: Node, id: String) -> Variant:
	var c := _c(reg, id)
	c.detect()
	return c.read()


func _reason(reg: Node, id: String) -> String:
	var c := _c(reg, id)
	c.detect()
	return c.reason


func _opts(reg: Node, id: String) -> Array:
	var c := _c(reg, id)
	c.detect()
	return c.options.map(func(o): return o["value"])


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path).strip_edges()


# ---- MSI Claw 8 EX as it runs today: InputPlumber + hid-msi ------------------------------------

func _claw(test_name: String, left := 100, right := 100, knob := true) -> Array:
	var f: RefCounted = Fakes.new(_root(test_name))
	f.with_ip("MSI Claw 8 EX AI+ CG3EM", PAD)
	var d: String = f.msi_knob(left, right) if knob else ""
	return [_setup(f, _row("msi-claw-8-ex")), f, d]


func test_claw_strength_through_the_firmware() -> void:
	var t := _claw("claw_strength")
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	var d: String = t[2]
	for id in ["controller.rumble", "controller.rumble_strength", "controller.rumble_test"]:
		ok(_c(reg, id).available, id + " available (" + _c(reg, id).reason + ")")
	eq(_opts(reg, "controller.rumble_strength"), [10, 20, 30, 40, 50, 60, 70, 80, 90, 100], "0-100 knob in 10 % steps")
	eq(_value(reg, "controller.rumble_strength"), 100, "read back from the controller")
	ok(_w(reg, "controller.rumble_strength", 40), "40 %")
	eq([_read(d + "/rumble_intensity_left"), _read(d + "/rumble_intensity_right")], ["40", "40"], "both motors")
	eq(f.rumble_sets, ["40"], "one root action")
	eq(_value(reg, "controller.rumble_strength"), 40)
	ok(_w(reg, "controller.rumble_strength", 40), "same value again")
	eq(f.rumble_sets, ["40"], "an unchanged value never reaches the controller's flash")
	ok(not _w(reg, "controller.rumble_strength", 140), "outside the range")
	ok(not _w(reg, "controller.rumble_strength", "high"), "a word on a percent knob")
	eq(f.rumble_sets, ["40"], "refused values never reach the root action")
	reg.free()


func test_claw_on_off_uses_inputplumber_not_the_flash() -> void:
	var t := _claw("claw_onoff", 70, 70)
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	var d: String = t[2]
	eq(_value(reg, "controller.rumble"), true)
	ok(_w(reg, "controller.rumble", false), "off")
	eq(f.rumble, false, "ForceFeedback.Enabled false")
	eq(_read(d + "/rumble_intensity_left"), "70", "the firmware strength stays")
	eq(f.rumble_sets, [], "no flash write for on/off")
	eq(_value(reg, "controller.rumble"), false)
	ok(_w(reg, "controller.rumble", true), "on")
	eq(f.rumble, true)
	eq(_value(reg, "controller.rumble_strength"), 70)
	reg.free()


func test_claw_firmware_set_to_off_counts_as_off() -> void:
	var t := _claw("claw_fw_off", 0, 0)
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	var d: String = t[2]
	eq(_value(reg, "controller.rumble"), false, "InputPlumber on, firmware at 0: nothing vibrates")
	eq(_value(reg, "controller.rumble_strength"), null, "0 isn't a strength")
	ok(_w(reg, "controller.rumble", true), "on")
	eq(_read(d + "/rumble_intensity_left"), "100", "firmware back to full")
	eq(_value(reg, "controller.rumble"), true)
	reg.free()


func test_claw_test_buzz_at_the_chosen_strength() -> void:
	var t := _claw("claw_test", 50, 50)
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	eq(_c(reg, "controller.rumble_test").requires, ["controller.rumble"], "greyed while rumble is off")
	ok(_w(reg, "controller.rumble_test", true), "buzz")
	eq(f.buzzes, 1)
	eq(f.buzz_values(), [1.0], "full scale: the firmware's 50 % makes it the chosen strength")
	reg.free()


func test_claw_without_the_kernel_knob() -> void:
	var t := _claw("claw_old_kernel", 100, 100, false)
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	eq(_reason(reg, "controller.rumble_strength"), "Needs a kernel whose hid-msi driver has rumble strength")
	ok(_c(reg, "controller.rumble").available, "on/off still works through InputPlumber")
	ok(_w(reg, "controller.rumble_test", true), "buzz")
	eq(f.buzz_values(), [0.6], "a gentler buzz where nothing scales it")
	reg.free()


func test_claw_root_action_refuses() -> void:
	var t := _claw("claw_refuse", 80, 80)
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	var d: String = t[2]
	f.refuse_rumble = true
	ok(not _w(reg, "controller.rumble_strength", 30), "fails")
	eq(_read(d + "/rumble_intensity_left"), "80", "unchanged")
	eq(_value(reg, "controller.rumble_strength"), 80, "still reads what the controller has")
	reg.free()


func test_claw_under_hhd_kernel_is_the_switch() -> void:
	# hhd has no vibration setting for the Claw (src/hhd/device/claw): the
	# firmware knob turns rumble off, and a strength chosen while off waits.
	var f: RefCounted = Fakes.new(_root("claw_hhd"))
	f.with_hhd({"controllers": {"claw": {"imu": true}}}, {"controllers": {"claw": {"type": "container", "children": {}}}})
	var d: String = f.msi_knob(60, 60)
	var reg := _setup(f, _row("msi-claw-8-ex"))
	ok(_c(reg, "controller.rumble").available, "on/off through the firmware (" + _c(reg, "controller.rumble").reason + ")")
	eq(_reason(reg, "controller.rumble_test"), Rumble.R_HHD_NO_BUZZ)
	ok(_w(reg, "controller.rumble", false), "off")
	eq(_read(d + "/rumble_intensity_left"), "0")
	ok(_w(reg, "controller.rumble_strength", 30), "chosen while off")
	eq(_read(d + "/rumble_intensity_left"), "0", "stays off")
	eq(_value(reg, "controller.rumble_strength"), 30, "shows the strength it goes back on at")
	ok(_w(reg, "controller.rumble", true), "on")
	eq(_read(d + "/rumble_intensity_left"), "30", "back on at the chosen strength")
	eq(f.rumble_sets, ["0", "30"])
	reg.free()


# ---- Legion Go / Go 2: hid-lenovo-go words ------------------------------------------------------

func test_legion_go_levels() -> void:
	var f: RefCounted = Fakes.new(_root("legion_go"))
	f.with_ip("Lenovo Legion Go 2", PAD)
	var d: String = f.go_knob("high")
	var reg := _setup(f, _row("lenovo-legion-go-2"))
	eq(_opts(reg, "controller.rumble_strength"), ["low", "medium", "high"])
	eq(_value(reg, "controller.rumble_strength"), "high")
	ok(_w(reg, "controller.rumble_strength", "low"), "low")
	eq(_read(d + "/rumble_intensity"), "low")
	ok(not _w(reg, "controller.rumble_strength", 50), "a number on a word knob")
	ok(not _w(reg, "controller.rumble_strength", "unknown"), "not offered")
	eq(f.rumble_sets, ["low"])
	reg.free()


# ---- handhelds without a strength knob -----------------------------------------------------------

func test_reasons_where_nothing_sets_a_strength() -> void:
	var cases := {
		"asus-rog-ally": Rumble.R_HHD_HERE,
		"steam-deck-oled": Rumble.R_STEAM,
		"lenovo-legion-go-s-z2go": Rumble.R_NO_KNOB,
		"onexplayer-x1-amd": Rumble.R_IP_ONOFF,
	}
	for id in cases:
		var f: RefCounted = Fakes.new(_root("reasons_" + id))
		f.with_ip(id, PAD)
		var reg := _setup(f, _row(id))
		eq(_reason(reg, "controller.rumble_strength"), cases[id], id)
		ok(_reason(reg, "controller.rumble_strength").length() <= 100, id + ": one short line")
		ok(_c(reg, "controller.rumble").available, id + ": on/off through InputPlumber")
		ok(_c(reg, "controller.rumble_test").available, id + ": test buzz")
		ok(_w(reg, "controller.rumble", false), id + ": off")
		eq(f.rumble, false, id + ": ForceFeedback off")
		eq(f.rumble_sets, [], id + ": no root action")
		reg.free()


func test_no_force_feedback_and_no_knob() -> void:
	var f: RefCounted = Fakes.new(_root("no_ff"))
	f.with_ip("Some pad", PAD, false)
	var reg := _setup(f, _row("asus-rog-ally"))
	eq(_reason(reg, "controller.rumble"), Rumble.R_IP_NO_FF)
	eq(_reason(reg, "controller.rumble_test"), Rumble.R_IP_NO_FF)
	reg.free()


# ---- Handheld Daemon: GPD WinControls and the Ally ---------------------------------------------

func test_gpd_wincontrols_vibration() -> void:
	var f: RefCounted = Fakes.new(_root("gpd_hhd"))
	f.with_hhd({"controllers": {"gpd_win": {"imu": true}}, "wincontrols": {"wincontrols": {"vibration": "high"}}},
		{"controllers": {"gpd_win": {"type": "container", "children": {}}},
		"wincontrols": {"wincontrols": {"type": "container", "children": {"vibration": {"type": "multiple",
			"options": {"off": "Off", "medium": "Medium", "high": "High"}}}}}})
	var reg := _setup(f, _row("gpd-win-4"))
	eq(_value(reg, "controller.rumble"), true)
	eq(_opts(reg, "controller.rumble_strength"), ["medium", "high"])
	ok(_w(reg, "controller.rumble_strength", "medium"), "medium")
	eq(f.hhd.state["wincontrols"]["wincontrols"]["vibration"], "medium")
	ok(_w(reg, "controller.rumble", false), "off")
	eq(f.hhd.state["wincontrols"]["wincontrols"]["vibration"], "off")
	eq(_value(reg, "controller.rumble_strength"), null, "off isn't a strength")
	ok(_w(reg, "controller.rumble", true), "on")
	eq(f.hhd.state["wincontrols"]["wincontrols"]["vibration"], "medium", "back at the strength it had")
	reg.free()


func test_ally_hhd_back_on_at_its_strength() -> void:
	var f: RefCounted = Fakes.new(_root("ally_hhd"))
	f.with_hhd({"controllers": {"rog_ally": {"limits": {"mode": "manual", "manual": {"vibration": 40}}}}},
		{"controllers": {"rog_ally": {"type": "container", "children": {"limits": {"type": "mode", "modes": {
			"default": {}, "manual": {"children": {"vibration": {"type": "int", "min": 0, "max": 100, "step": 20}}}}}}}}})
	var reg := _setup(f, _row("asus-rog-ally"))
	eq(_value(reg, "controller.rumble_strength"), 40)
	ok(_w(reg, "controller.rumble", false), "off")
	ok(_w(reg, "controller.rumble", true), "on")
	eq(int(f.hhd.state["controllers"]["rog_ally"]["limits"]["manual"]["vibration"]), 40, "not 100: the strength it had")
	reg.free()


# ---- devices.json rumble -----------------------------------------------------------------------

func test_rows_say_where_the_strength_lives() -> void:
	var want := {"msi-claw-8-ex": "kernel", "msi-claw-a1m": "kernel", "lenovo-legion-go": "kernel",
		"lenovo-legion-go-2": "kernel", "lenovo-legion-go-s-z2go": "none", "lenovo-legion-go-s-z1e": "none",
		"asus-rog-ally": "hhd", "asus-rog-ally-x": "hhd", "asus-rog-xbox-ally-x": "hhd",
		"steam-deck-lcd": "steam", "steam-deck-oled": "steam"}
	for id in want:
		var r: Dictionary = _row(id).get("rumble", {})
		eq(str(r.get("strength", "")), want[id], id)
		ok("strength" in r.get("unverified", []), id + ": the strength comes from source, not from a device")
	eq(_row("msi-claw-8-ex")["rumble"]["checked"], ["on_off", "test"], "Claw 8 EX: on/off and test checked live")
	eq(_row("asus-rog-ally")["rumble"]["checked"], ["on_off", "test"], "Ally RC71L: on/off and test checked live")
	eq(_row("msi-claw-8-ex")["verified"], true, "rumble data never makes a row unverified")
	ok(DeviceScript.rumble_problems("x", {"strength": "kernel", "driver": "hid-foo", "values": [0, 1], "source": "s"}).size() > 0, "unknown driver")
	ok(DeviceScript.rumble_problems("x", {"strength": "hhd", "values": [0, 1], "source": "s"}).size() > 0, "hhd without its setting")
	ok(DeviceScript.rumble_problems("x", {"strength": "steam", "checked": ["test"], "source": "s"}).size() > 0, "checked without where")
	eq(DeviceScript.rumble_problems("x", {"strength": "none", "source": "s"}), [])


func test_same_never_trips_on_mixed_types() -> void:
	ok(Rumble.same(10, 10.0), "int and float")
	ok(not Rumble.same("low", 50), "word vs number: false, no script error")
	ok(not Rumble.same(null, 0), "null vs 0")
	ok(Rumble.same("off", "off"), "words")
	eq(Rumble.knob_options({"kind": "percent", "lo": 0, "hi": 100}).size(), 10)
	eq(Rumble.knob_options({"kind": "percent", "lo": 0, "hi": 64}).map(func(o): return o["value"]).back(), 64, "an odd top is offered too")
