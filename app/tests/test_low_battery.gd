extends "res://tests/test_case.gd"
## Sleep at low battery: the two power controls (off by default, 3-10 %, kept per handheld),
## the watcher (scripts/system/low_battery.gd) that only acts on Power's existing events,
## and the 30 s warning any button cancels (scripts/ui/low_battery_dialog.gd).

const Low := preload("res://scripts/system/low_battery.gd")
const Dialog := preload("res://scripts/ui/low_battery_dialog.gd")
const Trees := preload("res://tests/fixtures/power_controls/trees.gd")
const ControlsScript := preload("res://scripts/controls/controls.gd")
const ProviderScript := preload("res://scripts/controls/providers/power.gd")
const PowerScript := preload("res://scripts/device/power.gd")
const Catalog := preload("res://scripts/ui/controls/catalog.gd")


## A watcher with settings `s` and a suspend that only counts.
func _low(s: Dictionary) -> Dictionary:
	var w := {"slept": 0, "warned": [], "cancelled": 0, "plugged": false, "level": -1}
	var l: Node = Low.new()
	l.level_now = func() -> int: return int(w["level"])
	l.settings = func() -> Dictionary: return s
	l.plugged_now = func() -> bool: return bool(w["plugged"])
	l.suspend = func() -> void: w["slept"] = int(w["slept"]) + 1
	l.warn_requested.connect(func(p): w["warned"].append(p))
	l.warn_cancelled.connect(func(): w["cancelled"] = int(w["cancelled"]) + 1)
	w["l"] = l
	return w


func test_warns_only_on_battery_at_the_level_when_on() -> void:
	ok(Low.should_warn(5, false, true, 5, false, false), "at the level on battery")
	ok(not Low.should_warn(5, true, true, 5, false, false), "never on the charger")
	ok(not Low.should_warn(5, false, false, 5, false, false), "off by default")
	ok(not Low.should_warn(6, false, true, 5, false, false), "above the level")
	ok(not Low.should_warn(-1, false, true, 5, false, false), "no battery")
	ok(Low.should_warn(10, false, true, 40, false, false), "the level is held to 3-10 %")
	var w := _low({"on": true, "at": 5})
	var l: Node = w["l"]
	l.on_level(6, false)
	eq(w["warned"], [], "6 %: nothing")
	l.on_level(5, false)
	eq(w["warned"], [5], "5 %: the warning")
	l.on_level(4, false)
	eq(w["warned"], [5], "not twice while it shows")
	l.confirm()
	eq(w["slept"], 1, "the count ran out: sleep")
	l.on_level(4, false)
	eq(w["warned"], [5], "after the wake at the same level: not straight back to sleep")
	l.on_level(2, false)
	eq(w["warned"], [5, 2], "2 % lower: it asks again")
	l.free()


func test_a_button_holds_it_off_and_the_charger_cancels() -> void:
	var w := _low({"on": true, "at": 8})
	var l: Node = w["l"]
	l.on_level(9, false)
	l.on_level(8, false)
	l.cancel()
	eq(w["slept"], 0, "a button: stays awake")
	l.on_level(7, false)
	eq(w["warned"], [8], "one percent less: still held off")
	l.on_level(9, false)
	l.on_level(8, false)
	eq(w["warned"], [8, 8], "back above the line and down again: asks again")
	l.on_source(true)
	eq(w["cancelled"], 1, "plugged in while it shows: the warning closes")
	ok(not l.warning, "no warning")
	l.on_level(8, false)
	w["plugged"] = true
	l.confirm()
	eq(w["slept"], 0, "plugged in meanwhile: no sleep")
	l.free()


func test_follows_powers_signals() -> void:
	var w := _low({"on": true, "at": 5})
	var l: Node = w["l"]
	var power: Node = PowerScript.new()
	l.setup(power, null)
	l.settings = func() -> Dictionary: return {"on": true, "at": 5}
	power.battery_level.emit(6, false)
	power.battery_level.emit(4, false)
	eq(w["warned"], [4], "Power's 15 s check reports the level")
	power.source_changed.emit(true)
	eq(w["cancelled"], 1, "and the charger")
	ok(not FileAccess.get_file_as_string("res://scripts/system/low_battery.gd").contains("Timer.new()"), "no timer that keeps running")
	power.free()
	l.free()


func test_the_warning_counts_down_and_any_button_cancels() -> void:
	var d: Control = Dialog.new()
	d.build(5, 3)
	var got := []
	d.decided.connect(func(stay): got.append(stay))
	eq(d.title_label.text, "Battery at 5 %", "the level")
	eq(d.count_label.text, "Sleeping in 3 s", "the count")
	d.tick()
	d.tick()
	eq(d.count_label.text, "Sleeping in 1 s", "counts down")
	d.tick()
	eq(got, [false], "ran out: sleep")
	d.free()
	var d2: Control = Dialog.new()
	d2.build(4, 30)
	d2.decided.connect(func(stay): got.append(stay))
	var ev := InputEventJoypadButton.new()
	ev.button_index = JOY_BUTTON_Y
	ev.pressed = true
	# any button, not only A
	d2._input(ev)
	eq(got, [false, true], "Y pressed: stay awake")
	d2.tick()
	eq(got.size(), 2, "no decision after it closed")
	if is_instance_valid(d2):
		d2.free()


func test_the_two_controls_are_off_by_default_and_kept() -> void:
	Trees.make_bin()
	var t: Dictionary = Trees.new().claw8ex()
	var runner: RefCounted = Trees.runner(t)
	var power: Node = PowerScript.new()
	power.setup(runner, t["row"], t["root"])
	power.config_path = t["root"] + "/power.cfg"
	power.detect()
	var reg: Node = ControlsScript.new()
	reg.sync_mode = true
	var ctx := {"sys_root": t["root"], "runner": runner, "home": t["root"], "device": t["row"], "power": power, "registry": reg}
	reg.setup(ctx)
	var prov: RefCounted = ProviderScript.new()
	prov.cfg_path = t["root"] + "/power_controls.cfg"
	prov.setup(ctx)
	reg.register_provider(prov)
	reg.detect_all()
	var on: RefCounted = reg.control("power.low_battery_sleep")
	var at: RefCounted = reg.control("power.low_battery_sleep_at")
	ok(on != null and on.available, "Sleep at low battery offered with a battery")
	eq(reg.value("power.low_battery_sleep"), false, "off by default")
	eq(reg.value("power.low_battery_sleep_at"), 5.0, "5 % by default")
	eq([at.min_value, at.max_value, at.step], [3.0, 10.0, 1.0], "3 to 10 %")
	reg.set_value("power.low_battery_sleep", true)
	reg.set_value("power.low_battery_sleep_at", 7)
	eq(prov.saved_device_values().get("power.low_battery_sleep"), true, "kept per handheld")
	eq(int(prov.saved_device_values().get("power.low_battery_sleep_at")), 7, "its level too")
	var l: Node = Low.new()
	l.setup(null, reg)
	eq(l.settings.call(), {"on": true, "at": 7}, "the watcher reads them from Controls")
	l.free()
	var battery_card: Array = Catalog.CARDS["power"].filter(func(c): return c[0] == "Battery")[0][2]
	ok(battery_card.find("power.low_battery_sleep") == battery_card.find("power.battery_saver_at") + 1, "next to battery saver")
	reg.free()
	power.free()


## Final review (Low): one reading of 0 started the 30 s countdown to sleep.
func test_one_odd_reading_never_starts_the_countdown() -> void:
	ok(Low.sudden(62, 0, 5) and Low.sudden(-1, 3, 5) and Low.sudden(40, 5, 5) and Low.sudden(8, 5, 5), "0, a first reading, and a fall of more than 2 % to the line are odd")
	ok(not Low.sudden(7, 5, 5) and not Low.sudden(6, 5, 5) and not Low.sudden(62, 40, 5) and not Low.sudden(5, 4, 5), "a step of 2 % or less, or a level above the line, isn't")
	var w := _low({"on": true, "at": 5})
	var l: Node = w["l"]
	l.on_level(62, false)
	l.on_level(0, false)     # the gauge says 0 for a moment
	eq(w["warned"], [], "a fall from 62 to 0 isn't believed at once")
	w["level"] = 62
	l.confirm_reading()      # read again a few seconds later: it's 62
	eq(w["warned"], [], "it was a glitch: no warning")
	l.on_level(62, false)
	eq(w["warned"], [], "and none when the level comes back")
	eq(w["slept"], 0, "nothing sleeps")
	# a real fall (a long sleep on a low battery, then awake): confirmed by the second look
	l.on_level(4, false)
	eq(w["warned"], [], "not at once")
	w["level"] = 4
	l.confirm_reading()
	eq(w["warned"], [4], "still 4 % a few seconds later: the warning")
	l.cancel()
	# a fall of 3 % to the line is odd too (a battery loses a percent or two between checks)
	var w5 := _low({"on": true, "at": 5})
	w5["l"].on_level(8, false)
	w5["l"].on_level(5, false)
	eq(w5["warned"], [], "8 to 5 in one check waits for the second look")
	# the first reading after the start has nothing before it
	var w2 := _low({"on": true, "at": 5})
	var l2: Node = w2["l"]
	l2.on_level(3, false)
	eq(w2["warned"], [], "the very first reading is looked at twice too")
	l2.on_source(false)
	eq(w2["warned"], [], "and an unplug meanwhile doesn't jump the check")
	w2["level"] = 3
	l2.confirm_reading()
	eq(w2["warned"], [3], "then it counts")
	# a second low report before the second look is its own confirmation
	var w3 := _low({"on": true, "at": 5})
	var l3: Node = w3["l"]
	l3.on_level(40, false)
	l3.on_level(1, false)
	l3.on_level(0, false)
	eq(w3["warned"], [0], "two low reports in a row: believed")
	# a battery that can't be read when the second look comes: nothing happens on a guess
	var w4 := _low({"on": true, "at": 5})
	var l4: Node = w4["l"]
	l4.on_level(40, false)
	l4.on_level(0, false)
	w4["level"] = -1
	l4.confirm_reading()
	eq(w4["warned"], [], "unreadable: no warning on a guess")
	# the second look is a one-shot timer that fires for the reading it belongs to
	var src := FileAccess.get_file_as_string("res://scripts/system/low_battery.gd")
	ok(src.contains("create_timer(confirm_s)") and not src.contains("Timer.new()"), "one one-shot timer, no running one")
	# the real reader, on a fixture battery
	var root := ProjectSettings.globalize_path("user://test_low_battery_sys")
	var bat := root + "/sys/class/power_supply/BAT0/"
	DirAccess.make_dir_recursive_absolute(bat)
	for pair in [["type", "Battery"], ["capacity", "7"]]:
		var f := FileAccess.open(bat + pair[0], FileAccess.WRITE)
		f.store_string(pair[1] + "\n")
		f.close()
	eq(Low.read_level(root), 7, "the level, straight from the battery")
	eq(Low.read_level(root + "/nope"), -1, "no battery: unknown")
	for n in ["type", "capacity"]:
		DirAccess.remove_absolute(bat + n)
	for d in [bat, root + "/sys/class/power_supply", root + "/sys/class", root + "/sys", root]:
		DirAccess.remove_absolute(d)
	for x in [l, l2, l3, l4, w5["l"]]:
		x.free()


func test_a_charger_the_kernel_doesnt_list_never_starts_the_countdown() -> void:
	var w := _low({"on": true, "at": 5})
	var l: Node = w["l"]
	var charging := [true]
	l.charging_now = func() -> bool: return charging[0]
	l.on_level(6, false)
	l.on_level(5, false)
	eq(w["warned"], [], "the charger isn't in the list, but the battery is charging: no countdown")
	l.on_source(false)
	eq(w["warned"], [], "nor when the charger list changes")
	charging[0] = false
	l.on_level(4, false)
	eq(w["warned"], [4], "really on battery: warned")
	l.free()
	# Power reads the battery's own status
	var root := ProjectSettings.globalize_path("user://test_low_battery_sys")
	DirAccess.make_dir_recursive_absolute(root + "/sys/class/power_supply/BAT0")
	for f in [["type", "Battery"], ["capacity", "4"], ["status", "Charging"]]:
		FileAccess.open(root + "/sys/class/power_supply/BAT0/" + f[0], FileAccess.WRITE).store_string(f[1] + "\n")
	var power: Node = PowerScript.new()
	power.sys_root = root
	var seen: Array = []
	power.battery_level.connect(func(p, ac): seen.append([p, ac]))
	power._report_battery(false)
	ok(power.battery_charging(), "status Charging: on the charger whatever the charger list says")
	power._report_battery(false)
	eq(seen, [[4, false]], "an unchanged level is reported once")
	FileAccess.open(root + "/sys/class/power_supply/BAT0/status", FileAccess.WRITE).store_string("Discharging\n")
	power._report_battery(false)
	ok(not power.battery_charging(), "status Discharging: on battery")
	var l2: Node = Low.new()
	l2.setup(power, null)
	FileAccess.open(root + "/sys/class/power_supply/BAT0/status", FileAccess.WRITE).store_string("Charging\n")
	power._report_battery(false)
	ok(l2.plugged_now.call(), "the countdown's last check sees the charging battery too")
	l2.free()
	power.free()
