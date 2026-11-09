extends "res://tests/test_case.gd"
## "What works here" (capabilities.gd): devices.json plus live Controls, and
## the About panel / quick menu showing the same answer.

const Caps := preload("res://scripts/device/capabilities.gd")
const DeviceScript := preload("res://scripts/device/device.gd")
const FakeControls := preload("res://tests/fixtures/ui_controls/fake_controls.gd")
const Fakes := preload("res://tests/fixtures/device_ui/fakes.gd")


func _row(id: String) -> Dictionary:
	for r in DeviceScript.load_table():
		if r.get("id", "") == id:
			return r
	return {}


func _by_key(list: Array) -> Dictionary:
	var out := {}
	for s in list:
		out[s["key"]] = s
	return out


func test_claw_from_devices_json() -> void:
	var r := _row("msi-claw-8-ex")
	var st := _by_key(Caps.states(DeviceScript.features_of(r), r.get("unverified", [])))
	for k in ["tdp", "fan_control", "charge_limit", "vrr", "paddles", "rgb"]:
		eq(st[k]["state"], "yes", k + " works on a full-support Claw")
	eq(st["trackpads"]["state"], "absent", "no trackpads: not a failure")
	eq(st["gyro"]["state"], "maybe", "gyro needs its fix")
	ok(st["gyro"]["note"] != "", "with a reason")


func test_unverified_is_maybe() -> void:
	var r := _row("lenovo-legion-go-s-z2go")
	var st := _by_key(Caps.states(DeviceScript.features_of(r), ["charge_limit"]))
	eq(st["charge_limit"]["state"], "absent", "Legion Go S battery has no limit")
	var f := DeviceScript.features_of(r)
	f["charge_limit"] = true
	st = _by_key(Caps.states(f, ["charge_limit"]))
	eq(st["charge_limit"]["state"], "maybe", "listed as unverified")


func test_live_controls_win() -> void:
	var r := _row("msi-claw-8-ex")
	var c := FakeControls.new()
	c.add({"id": "power.tdp", "reason": "No TDP service on this system"})
	c.add({"id": "controller.gyro", "value": true})
	c.add({"id": "controller.trackpad", "reason": "This handheld has no trackpad"})
	c.add({"id": "display.vrr", "reason": "Not checked yet"})
	var st := _by_key(Caps.states(DeviceScript.features_of(r), [], c))
	eq(st["tdp"]["state"], "maybe", "hardware there, backend missing")
	eq(st["tdp"]["note"], "No TDP service on this system")
	eq(st["gyro"]["state"], "yes", "gyro detected")
	eq(st["trackpads"]["state"], "absent")
	eq(st["vrr"]["state"], "yes", "not checked yet falls back to devices.json")
	c.free()


func test_about_never_crosses_supported() -> void:
	var s := Fakes.services()
	var p: Control = load("res://scripts/ui/device/about_panel.gd").build(s)
	var feats: Node = p.find_child("Features", true, false)
	ok(feats != null, "what works card")
	var absent := 0
	for f in feats.get_children():
		if f.find_child("Absent", true, false) != null:
			absent += 1
	eq(absent, 1, "only trackpads are absent on the Claw")
	ok(p.find_child("Loading", true, false) == null, "resolved info: no loading line")
	ok(p.find_child("DrawingCredit", true, false) != null, "drawing credit under the picture")
	p.free()
	Fakes.free_services(s)


func test_drawing_credit_from_body() -> void:
	var About: GDScript = load("res://scripts/ui/device/about_panel.gd")
	var t: String = About._drawing_credit("msi-claw-8-ex", DeviceScript.picture_for("msi-claw-8-ex"))
	ok("321" in t and "130" in t, "real size: " + t)
	eq(About._drawing_credit("unknown", DeviceScript.art_path("generic")), "", "generic drawing isn't to scale")
