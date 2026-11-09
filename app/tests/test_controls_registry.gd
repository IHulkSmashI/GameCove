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


## After a resume the hardware may differ from what a control holds: force writes anyway.
func test_forced_apply_and_worker_jobs_and_a_runner_always_there() -> void:
	var store := {"display.brightness": 50.0}
	var writes := [0]
	var r := _reg()
	ok(r.ctx["runner"] != null and int(r.ctx["runner"].run("busctl", PackedStringArray()).get("code", 0)) == 127, "NoRunner stands in: nothing runs")
	var c := Ctl.make({"id": "display.brightness", "group": "display", "kind": "slider", "min_value": 0.0, "max_value": 100.0},
		func(_c): return "", func(_c): return store["display.brightness"],
		func(_c, v): writes[0] += 1; store["display.brightness"] = v; return true)
	r.register(c)
	r.detect_all()
	r.apply({"display.brightness": 50.0})
	eq(writes[0], 0, "same value: skipped")
	store["display.brightness"] = 10.0   # the firmware reset it; the control still holds 50
	r.apply({"display.brightness": 50.0}, true)
	eq([writes[0], store["display.brightness"]], [1, 50.0], "forced: written again")
	var seen := []
	r.run_on_worker(func(): seen.append("job"))
	eq(seen, ["job"], "worker job ran")
	r.free()


## normalize() makes every coerced value safe (fan curves: raised to Quiet, never falling).
func test_normalize_runs_after_coerce() -> void:
	var c := Ctl.make({"id": "power.fan_curve", "group": "power", "kind": "curve", "min_value": 0.0, "max_value": 100.0,
		"points": 3, "normalize": func(v): return [maxf(v[0], 20.0), maxf(v[1], v[0]), maxf(v[2], v[1])]},
		func(_c): return "", func(_c): return null, func(_c, _v): return true)
	eq(c.coerce([0, 50, 10]), [20.0, 50.0, 50.0], "raised and never falling")
	eq(c.coerce([0, 50]), null, "point count still checked first")


## review S4-1: snapshot() / value() on the main thread while the worker applies: never a torn
## read, never a state half-way through the apply (one commit per worker job).
func test_snapshot_during_a_worker_apply_is_consistent() -> void:
	var store := {"power.tdp": 15.0, "power.epp": 1.0}
	var gate := Semaphore.new()
	var started := [false]
	var flag := Mutex.new()
	var r: Node = ControlsScript.new()   # a real worker thread
	r.setup({"sys_root": "", "runner": null, "home": "", "device": null})
	var slow := Ctl.make({"id": "power.tdp", "title": "t", "group": "power", "kind": "slider", "min_value": 0.0,
		"max_value": 30.0, "step": 1.0, "apply_order": 1},
		func(_c): return "",
		func(_c): return store["power.tdp"],
		func(_c, v):
			flag.lock(); started[0] = true; flag.unlock()
			gate.wait()                     # the main thread looks while this write is in progress
			store["power.tdp"] = v
			return true)
	r.register(slow)
	# EPP is written first (higher apply_order), then the slow TDP: half-way, EPP is new and TDP old
	r.register(_store_ctl("power.epp", store, {"group": "power", "max_value": 10.0, "step": 1.0, "apply_order": 10}))
	r.detect_all()
	var t0 := Time.get_ticks_msec()
	while r.snapshot() != {"power.tdp": 15.0, "power.epp": 1.0} and Time.get_ticks_msec() - t0 < 3000:
		OS.delay_msec(10)
	eq(r.snapshot(), {"power.tdp": 15.0, "power.epp": 1.0}, "detected")
	r.apply({"power.tdp": 25, "power.epp": 3})
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 3000:
		flag.lock(); var s: bool = started[0]; flag.unlock()
		if s:
			break
		OS.delay_msec(5)
	eq(r.snapshot(), {"power.tdp": 15.0, "power.epp": 1.0}, "mid-apply: the state before it, not half of it")
	eq(r.value("power.tdp"), 15.0, "value() too")
	gate.post()
	t0 = Time.get_ticks_msec()
	while r.value("power.tdp") != 25.0 and Time.get_ticks_msec() - t0 < 3000:
		OS.delay_msec(10)
	eq(r.snapshot(), {"power.tdp": 25.0, "power.epp": 3.0}, "after the job: all of it")
	r._exit_tree()                          # stop the worker (not in the tree)
	r.free()
