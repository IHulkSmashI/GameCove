extends "res://tests/test_case.gd"
## Auto TDP logic against a simple game model: a 60 fps cap that needs `need`
## watts; below that, frames fall with the watts. Watts drawn = min(TDP, need).

const AutotuneScript := preload("res://scripts/device/autotune.gd")

var _seed := 1


## Small deterministic noise, +-pct.
func _noise(pct: float) -> float:
	_seed = (_seed * 1103515245 + 12345) % 2147483648
	return 1.0 + pct * (float(_seed % 2001) / 1000.0 - 1.0)


func _fps(need: float, w: float, cap := 60.0) -> float:
	return minf(cap, cap * w / need)


## Runs `seconds` samples; returns the seconds until the TDP first reached
## `until_w` (or -1).
func _run(at: RefCounted, need: float, seconds: int, noise := 0.0, until_w := -1.0) -> int:
	for i in seconds:
		var w: float = at.tdp_w
		at.feed(_fps(need, w) * _noise(noise), minf(w, need) * _noise(noise))
		if until_w > 0.0 and is_equal_approx(at.tdp_w, until_w):
			return i + 1
	return -1


func test_calm_game_lowers_to_the_knee() -> void:
	var at: RefCounted = AutotuneScript.new()
	eq(at.start(8.0, 35.0), 35.0, "starts at the ceiling")
	_run(at, 12.0, 180)
	eq(at.phase, "hold", "settled")
	eq(at.ref_fps, 60.0, "most frames the ceiling gives")
	ok(at.tdp_w >= 12.0 and at.tdp_w <= 13.0, "lowest TDP within 5 %% of 60 fps (got %s W)" % at.tdp_w)


func test_never_below_floor() -> void:
	var at: RefCounted = AutotuneScript.new()
	at.start(8.0, 35.0)
	_run(at, 4.0, 200)
	eq(at.tdp_w, 8.0, "stops at the floor")
	eq(at.phase, "hold", "holds at the floor")


func test_heavy_scene_raises_within_five_seconds() -> void:
	var at: RefCounted = AutotuneScript.new()
	at.start(8.0, 35.0)
	_run(at, 12.0, 180)
	var secs := _run(at, 30.0, 10, 0.0, 35.0)
	ok(secs > 0 and secs <= 5, "back at the ceiling in %d s" % secs)
	_run(at, 30.0, 240)
	eq(at.phase, "hold", "settled again")
	ok(at.tdp_w >= 29.0 and at.tdp_w <= 31.0, "heavy scene holds ~29-30 W (got %s W)" % at.tdp_w)


func test_calm_after_heavy_lowers_again() -> void:
	var at: RefCounted = AutotuneScript.new()
	at.start(8.0, 35.0)
	_run(at, 30.0, 240)
	ok(at.tdp_w >= 29.0, "heavy first (%s W)" % at.tdp_w)
	_run(at, 12.0, 120)
	ok(at.tdp_w <= 13.0, "capped calm scene draws under the limit: lowered to %s W" % at.tdp_w)


func test_uncapped_calm_scene_measures_again() -> void:
	var at: RefCounted = AutotuneScript.new()
	at.start(8.0, 35.0)
	# no watts: only fps. Heavy uncapped game: 40 fps at 35 W.
	for i in 240:
		at.feed(minf(40.0, 40.0 * at.tdp_w / 30.0))
	var before: float = at.ref_fps
	for i in 240:
		at.feed(minf(90.0, 90.0 * at.tdp_w / 20.0))
	ok(at.ref_fps > before * 1.5, "fresh measurement for the lighter scene (%s -> %s fps)" % [before, at.ref_fps])
	ok(at.tdp_w <= 21.0, "and lower watts (%s W)" % at.tdp_w)


func test_no_oscillation_when_steady() -> void:
	var at: RefCounted = AutotuneScript.new()
	at.start(8.0, 35.0)
	_run(at, 17.0, 240, 0.01)
	eq(at.phase, "hold", "settled with noise")
	var settled_w: float = at.tdp_w
	var changes: int = at.changes
	_run(at, 17.0, 900, 0.015)
	eq(at.changes, changes, "no TDP changes over 15 steady minutes")
	eq(at.tdp_w, settled_w, "same TDP")


func test_ceiling_change_measures_again() -> void:
	var at: RefCounted = AutotuneScript.new()
	at.start(8.0, 35.0)
	_run(at, 12.0, 180)
	eq(at.set_ceiling(20.0), 20.0, "new ceiling applied at once")
	eq(at.phase, "measure", "measures again")
	_run(at, 12.0, 120)
	ok(at.tdp_w <= 13.0 and at.tdp_w <= 20.0, "lowers under the new ceiling (%s W)" % at.tdp_w)


func test_idle_does_nothing() -> void:
	var at: RefCounted = AutotuneScript.new()
	eq(at.feed(60.0, 10.0), -1.0, "not started: no change")
	at.start(8.0, 35.0)
	at.stop()
	eq(at.feed(60.0, 10.0), -1.0, "stopped: no change")
	at.start(8.0, 35.0)
	eq(at.feed(0.0, 10.0), -1.0, "no frames: no change")


func test_heavier_settings_at_ceiling_take_a_new_reference() -> void:
	var at: RefCounted = AutotuneScript.new()
	at.start(8.0, 35.0)
	_run(at, 30.0, 240)
	# the game now needs more than the ceiling: 60 fps would take 50 W
	_run(at, 50.0, 240)
	ok(at.ref_fps < 45.0, "reference follows what the ceiling gives now (%s fps)" % at.ref_fps)
	eq(at.phase, "hold", "settled")
	ok(at.tdp_w >= 33.0, "stays near the ceiling (%s W)" % at.tdp_w)


# ---- "can't reach target" -----------------------------------------------------

func test_cant_reach_when_ceiling_is_too_low() -> void:
	var at: RefCounted = AutotuneScript.new()
	at.start(8.0, 15.0)
	at.set_target(60.0)
	# the game would need 30 W for 60 fps; the user allows 15 W
	var secs := -1
	for i in 120:
		var w: float = at.tdp_w
		at.feed(_fps(30.0, w), w)
		if at.cant_reach and secs < 0:
			secs = i + 1
	ok(at.cant_reach, "can't reach 60 fps at 15 W")
	ok(secs >= AutotuneScript.CANT_REACH_N and secs <= AutotuneScript.CANT_REACH_N + 2, "after ~N seconds (%d s)" % secs)
	var info: Dictionary = at.limit_info()
	eq(info["target_fps"], 60.0, "info carries the target")
	eq(info["ceiling_w"], 15.0, "and the ceiling")
	at.set_ceiling(35.0)
	ok(not at.cant_reach, "a new ceiling clears it")
	_run(at, 30.0, 240)
	ok(not at.cant_reach, "35 W holds 60 fps: stays clear")


func test_reachable_target_never_flags() -> void:
	var at: RefCounted = AutotuneScript.new()
	at.start(8.0, 35.0)
	at.set_target(60.0)
	_run(at, 12.0, 300, 0.01)
	ok(not at.cant_reach, "light game at 60 fps: never flagged")
	ok(at.tdp_w <= 13.0, "and still lowered (%s W)" % at.tdp_w)


func test_cant_reach_clears_when_the_scene_gets_lighter() -> void:
	var at: RefCounted = AutotuneScript.new()
	at.start(8.0, 20.0)
	at.set_target(60.0)
	_run(at, 40.0, 60)
	ok(at.cant_reach, "heavy scene under target at the ceiling")
	_run(at, 12.0, AutotuneScript.RECOVER_N + 1)
	ok(not at.cant_reach, "clears after RECOVER_N seconds on target")


func test_no_target_no_flag() -> void:
	var at: RefCounted = AutotuneScript.new()
	at.start(8.0, 15.0)
	_run(at, 30.0, 120)
	ok(not at.cant_reach, "without a target (no frame limit) it never flags")
	at.set_target(60.0)
	_run(at, 30.0, 30)
	ok(at.cant_reach, "a target set mid-game counts from then on")
	at.stop()
	ok(not at.cant_reach, "stop clears")


# ---- Power wiring ---------------------------------------------------------------

const PowerScript := preload("res://scripts/device/power.gd")
const DeviceScript := preload("res://scripts/device/device.gd")
const Fake := preload("res://tests/fixtures/power/fake_runner.gd")


func _claw_power(test_name: String) -> Node:
	var row := {}
	for d in DeviceScript.load_table():
		if d.get("id", "") == "msi-claw-8-ex":
			row = d
	var root := ProjectSettings.globalize_path("user://test_power_autotune/" + test_name)
	DirAccess.make_dir_recursive_absolute(root)
	DirAccess.remove_absolute(root + "/power.cfg")
	var p: Node = PowerScript.new()
	p.setup(Fake.from_fixture(fixture("power/bus_claw_powerstation.json")), row, root)
	p.config_path = root + "/power.cfg"
	p.detect()
	return p


func test_power_feed_signals_and_limit() -> void:
	var p := _claw_power("feed")
	var events := []
	p.autotune_changed.connect(func(on): events.append(["autotune", on]))
	p.autotune_limit.connect(func(c, info): events.append(["limit", c, info["tdp_max"] > 0.0]))
	p.request_feed(60.0, 10.0)
	eq(events, [], "feed before start does nothing")
	p.set_tdp(15.0)
	p.request_autotune(true)
	ok(p.autotune_active(), "running")
	eq(events, [["autotune", true]], "autotune_changed(true)")
	p.request_autotune_target(60.0)
	for i in 60:
		var w: float = p.state()["tdp_w"]
		p.request_feed(minf(60.0, 60.0 * w / 30.0), w)
	ok(events.has(["limit", true, true]), "can't reach reported with the device max (%s)" % [events])
	eq(p.autotune_limit_info()["cant_reach"], true, "state readable")
	p.request_autotune(false)
	ok(events.has(["limit", false, true]), "cleared when Auto TDP stops")
	eq(events.back(), ["autotune", false], "autotune_changed(false)")
	eq(p.state()["tdp_w"], 15.0, "user's TDP back")
	p.free()


class CountingAutotune extends "res://scripts/device/autotune.gd":
	var fed := 0
	var thread_ok := true
	func feed(fps: float, watts: float = -1.0) -> float:
		fed += 1
		if OS.get_thread_caller_id() == OS.get_main_thread_id():
			thread_ok = false
		return super(fps, watts)


func test_power_feed_runs_on_the_worker() -> void:
	var p := _claw_power("feed_worker")
	var counting := CountingAutotune.new()
	p.autotune = counting
	p.set_tdp(25.0)
	p.request_autotune(true)
	var gate := Semaphore.new()
	p._thread = Thread.new()
	p._thread.start(p._worker)
	p._queue("hold", func(): gate.wait(); return true)
	for i in 5:
		p.request_feed(60.0, 12.0)
	eq(counting.fed, 0, "nothing fed on the caller's thread")
	gate.post()
	var waited := 0
	while waited < 2000 and counting.fed == 0:
		OS.delay_msec(10)
		waited += 10
	OS.delay_msec(50)
	eq(counting.fed, 1, "five queued samples collapsed to the newest")
	ok(counting.thread_ok, "fed on the worker thread")
	p._exit_tree()
	p.free()
