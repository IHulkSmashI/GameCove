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
