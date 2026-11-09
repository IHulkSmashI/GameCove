extends "res://tests/test_case.gd"

const ControlsScript := preload("res://scripts/controls/controls.gd")
const Ctl := preload("res://scripts/controls/control.gd")


func _reg() -> Node:
	var r: Node = ControlsScript.new()
	r.sync_mode = true
	r.setup({"sys_root": "", "runner": null, "home": "", "device": null})
	return r


func _store_ctl(id: String, store: Dictionary, spec := {}) -> RefCounted:
	var base := {"id": id, "title": id, "group": "display", "kind": "slider",
		"min_value": 0.0, "max_value": 100.0, "step": 5.0}
	base.merge(spec, true)
	return Ctl.make(base,
		func(_c): return "",
		func(_c): return store.get(id),
		func(_c, v): store[id] = v; return true)


func test_coerce_clamps_and_steps() -> void:
	var c := _store_ctl("display.brightness", {})
	eq(c.coerce(103), 100.0, "clamped")
	eq(c.coerce(42), 40.0, "stepped")
	eq(c.coerce("x"), null, "bad type")
	var t := _store_ctl("perf.x", {}, {"kind": "choice", "options": [{"value": "fsr"}, {"value": "nis"}]})
	eq(t.coerce("nis"), "nis", "choice ok")
	eq(t.coerce("dlss"), null, "choice rejects")


func test_detect_set_snapshot_apply() -> void:
	var store := {"display.brightness": 50.0, "power.tdp": 15.0}
	var r := _reg()
	r.register(_store_ctl("display.brightness", store, {"per_game": false}))
	r.register(_store_ctl("power.tdp", store, {"group": "power", "max_value": 30.0, "step": 1.0, "apply_order": 10}))
	var unavailable := Ctl.make({"id": "controller.gyro", "group": "controller", "kind": "toggle"},
		func(_c): return "Needs InputPlumber", func(_c): return true, func(_c, _v): return true)
	r.register(unavailable)
	var changed := []
	r.control_changed.connect(func(id, v): changed.append([id, v]))
	r.detect_all()
	eq(r.value("power.tdp"), 15.0, "read")
	eq(unavailable.reason, "Needs InputPlumber", "reason kept")
	eq(r.snapshot(), {"power.tdp": 15.0}, "per-game only, available only")
	r.set_value("power.tdp", 22)
	eq(store["power.tdp"], 22.0, "written")
	r.apply({"power.tdp": 22, "display.brightness": 80, "controller.gyro": false, "nope": 1})
	eq(store["display.brightness"], 80.0, "applied non-matching")
	eq(changed, [["power.tdp", 22.0], ["display.brightness", 80.0]], "skips equal, unknown, unavailable")
	r.free()
