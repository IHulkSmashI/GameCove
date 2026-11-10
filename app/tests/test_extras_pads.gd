extends "res://tests/test_case.gd"
## Controller batteries from UPower (fake busctl JSON as systemd 255 prints it)
## and the top bar's chip (and its REC chip).

const UPower := preload("res://scripts/system/upower.gd")
const TopBar := preload("res://scripts/ui/top_bar.gd")
const Fake := preload("res://tests/fixtures/system/fake_runner.gd")

const ENUM := "busctl --system call org.freedesktop.UPower /org/freedesktop/UPower org.freedesktop.UPower EnumerateDevices"
const GETALL := "busctl --system call org.freedesktop.UPower %s org.freedesktop.DBus.Properties GetAll s org.freedesktop.UPower.Device"


static func _dev(t: int, model: String, pct: float, state := 2, level := 1, supply := false) -> String:
	return JSON.stringify({"type": "a{sv}", "data": [{"Type": {"type": "u", "data": t}, "Model": {"type": "s", "data": model},
		"Percentage": {"type": "d", "data": pct}, "State": {"type": "u", "data": state}, "BatteryLevel": {"type": "u", "data": level},
		"PowerSupply": {"type": "b", "data": supply}, "IsPresent": {"type": "b", "data": true}}]})


func _upower() -> RefCounted:
	var f: RefCounted = Fake.new()
	var paths := ["/org/freedesktop/UPower/devices/battery_BAT0", "/org/freedesktop/UPower/devices/line_power_AC",
		"/org/freedesktop/UPower/devices/gaming_input_ps_controller_battery_a", "/org/freedesktop/UPower/devices/gaming_input_xpad",
		"/org/freedesktop/UPower/devices/gaming_input_joycon"]
	f.responses[ENUM] = {"code": 0, "out": JSON.stringify({"type": "ao", "data": [paths]})}
	f.responses[GETALL % paths[0]] = {"code": 0, "out": _dev(2, "BAT0", 77.0, 2, 1, true)}
	f.responses[GETALL % paths[1]] = {"code": 0, "out": _dev(1, "", 0.0)}
	f.responses[GETALL % paths[2]] = {"code": 0, "out": _dev(12, "DualSense Wireless Controller", 62.0)}
	f.responses[GETALL % paths[3]] = {"code": 0, "out": _dev(12, "Xbox Wireless Controller", 9.0, 1)}
	f.responses[GETALL % paths[4]] = {"code": 0, "out": _dev(12, "Joy-Con (L)", 0.0, 2, 6)}
	return f


func test_reads_game_controllers_only() -> void:
	var pads := UPower.pads(_upower())
	eq(pads.map(func(p): return p["name"]), ["DualSense Wireless Controller", "Joy-Con (L)", "Xbox Wireless Controller"], "controllers, not the handheld's battery or the charger")
	eq(pads.map(func(p): return p["percent"]), [62, 80, 9], "a percentage, or a level turned into one")
	eq(pads.map(func(p): return p["charging"]), [false, false, true], "charging")
	eq(UPower.chip_text(pads), "9%", "the lowest shows")
	eq(UPower.detail_text(pads), "DualSense Wireless Controller 62% · Joy-Con (L) 80% · Xbox Wireless Controller 9% charging", "all in the tooltip")
	eq(UPower.pads(Fake.new()), [], "no UPower: nothing")
	eq(UPower.pads(null), [], "no runner")


func test_top_bar_chip() -> void:
	var bar: HBoxContainer = TopBar.new()
	bar.set_status("Claw", {"percent": 50, "status": "Discharging"}, "3:00 PM")
	ok(not bar.pad_label.visible and not bar.pad_icon.visible, "hidden with no controller")
	bar.set_pads([{"name": "DualSense", "percent": 12, "charging": false}])
	ok(bar.pad_label.visible and bar.pad_icon.visible, "shown")
	eq(bar.pad_label.text, "12%", "its battery")
	eq(bar.pad_label.get_theme_color("font_color"), bar.ThemeLib.color("bad"), "low in red")
	ok(bar.status_button.tooltip_text.contains("DualSense 12%"), "tooltip names it")
	bar.set_pads([{"name": "Pad", "percent": -1, "charging": false}])
	ok(not bar.pad_label.visible, "a pad without a battery reading shows nothing")
	ok(not bar.rec_chip.visible, "REC hidden")
	bar.set_recording(true)
	ok(bar.rec_chip.visible, "REC while recording")
	bar.set_recording(false)
	ok(not bar.rec_chip.visible, "and gone after")
	bar.free()


func test_no_polling_for_pads() -> void:
	var main := FileAccess.get_file_as_string("res://scripts/main.gd")
	ok(main.contains("Input.joy_connection_changed.connect(func(_d, _c): read_pads(true))"), "read when a controller connects")
	ok(main.contains("read_pads(false)"), "the live tick only reads when stale")
	ok(not FileAccess.get_file_as_string("res://scripts/system/upower.gd").contains("Timer"), "no timer of its own")
