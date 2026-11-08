extends RefCounted
## Auto TDP, pure logic: no timers, no files, no system access. The caller feeds
## one sample per second while a game runs and applies the TDP it returns;
## when nothing runs nobody calls it, so it costs nothing.
##
## Rule: find the most frames the TDP ceiling (the user's own limit) gives, then
## settle on the lowest TDP whose frames stay within KEEP (5 %) of that.
## Frames-per-watt is not chased: it improves all the way to the minimum TDP.
##
## Count RENDERED frames, never generated ones. With frame generation the game
## presents 2-4 frames per rendered frame; feed the rendered rate (presented
## fps divided by the frame-generation multiplier).
##
## Where fps comes from (not wired yet): gamescope's mangoapp / MangoHud
## (MANGOHUD_CONFIG=output_folder=...,log_interval=1000, one CSV row per second)
## gives presented fps; for XeSS frame generation the xess-xmx-linux shim logs
## XeLL's "xellSleep stats" once per 100 rendered frames, which is the rendered
## rate. Watts come from the RAPL energy counter or Device.battery().
##
## Phases:
##   measure  run at the ceiling for MEASURE_WINDOWS windows; their mean is ref_fps
##   lower    step down (BIG_STEP_W while clearly above the line, else 1 W) while
##            each window holds the line (ref_fps * (1 - KEEP)); a miss after a big
##            step goes back and continues in 1 W steps; a 1 W miss is checked
##            once more, then it goes back to the last TDP that held and holds
##   hold     no changes while the line holds. Two windows under it: +1 W.
##            Two seconds far under it (a heavy scene): straight to the ceiling
##            and measure again, so heavy scenes recover within ~3 s.
##            Two windows well above ref_fps (a calm scene, uncapped fps):
##            measure again, then lower from there. Two windows drawing well
##            under the TDP (a calm scene under a frame cap: the limit no longer
##            binds): jump to the watts drawn + 1 W and lower in 1 W steps.
##            Without watts, a fresh measurement every RESCAN_WINDOWS instead.
## Credit: the rules follow ClawDeck's autotune (same author, GPL-3.0).

const KEEP := 0.05          ## frames we accept losing to save watts (5 %)
const WINDOW_N := 4         ## samples (seconds) per decision window
const SETTLE_N := 2         ## samples skipped after a TDP change (power limits take a moment)
const MEASURE_WINDOWS := 2
const BIG_STEP_W := 3.0
const HEAVY := 0.85         ## a second under this share of the line counts toward a heavy scene
const HEAVY_N := 2          ## ... this many in a row: back to the ceiling
const SHIFT_UP := 0.15      ## a window this far above ref_fps counts toward a calm scene
const SHIFT_N := 2
const BELOW_N := 2          ## windows under the line in hold before +1 W
const SLACK := 0.85         ## drawing under this share of the TDP: the limit doesn't bind
const SLACK_N := 2
const RESCAN_WINDOWS := 300 ## hold windows (~20 min) between fresh measurements when no watts come in

var floor_w := 8.0
var ceiling_w := 35.0
var tdp_w := 35.0
var phase := "idle"         ## idle | measure | lower | hold
var ref_fps := 0.0
var last_good_w := 35.0
var changes := 0            ## TDP changes made since start (for tests and the UI)

var _window: Array[float] = []
var _wwindow: Array[float] = []
var _slack := 0
var _hold_windows := 0
var _runs: Array[float] = []
var _settle := 0
var _heavy := 0
var _below := 0
var _up := 0
var _misses := 0
var _fine := false
var _last_step := 0.0


## Start for a game. ceiling_w is the TDP the user picked (profile or slider).
func start(min_w: float, max_w: float) -> float:
	floor_w = min_w
	ceiling_w = max(min_w, max_w)
	return _remeasure()


func stop() -> void:
	phase = "idle"
	_window.clear()
	_wwindow.clear()
	_runs.clear()


## The user moved the TDP or picked a profile while a game runs.
func set_ceiling(max_w: float) -> float:
	ceiling_w = max(floor_w, max_w)
	return _remeasure()


func line() -> float:
	return ref_fps * (1.0 - KEEP)


## One sample (about once a second). fps = rendered frames per second; watts =
## package power now, or -1 when unknown. Returns the TDP to apply, or -1.0 for
## "no change".
func feed(fps: float, watts: float = -1.0) -> float:
	if phase == "idle" or fps <= 0.0:
		return -1.0
	if _settle > 0:
		_settle -= 1
		return -1.0
	# heavy scene: react per second, not per window
	if (phase == "lower" or phase == "hold") and ref_fps > 0.0:
		if fps < line() * HEAVY:
			_heavy += 1
			if _heavy >= HEAVY_N and tdp_w < ceiling_w:
				return _remeasure()
		else:
			_heavy = 0
	_window.append(fps)
	if watts >= 0.0:
		_wwindow.append(watts)
	if _window.size() < WINDOW_N:
		return -1.0
	var avg := _mean(_window)
	var avg_w := _mean(_wwindow) if _wwindow.size() * 2 >= _window.size() else -1.0
	_window.clear()
	_wwindow.clear()
	match phase:
		"measure":
			return _on_measure(avg)
		"lower":
			return _on_lower(avg)
		"hold":
			return _on_hold(avg, avg_w)
	return -1.0


static func _mean(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var sum := 0.0
	for v in values:
		sum += v
	return sum / values.size()


func _on_measure(avg: float) -> float:
	_runs.append(avg)
	if _runs.size() < MEASURE_WINDOWS:
		return -1.0
	ref_fps = _mean(_runs)
	_runs.clear()
	phase = "lower"
	last_good_w = tdp_w
	_fine = false
	_misses = 0
	return _step_down(avg)


func _on_lower(avg: float) -> float:
	if avg >= line():
		_misses = 0
		last_good_w = tdp_w
		return _step_down(avg)
	# missed the line
	if _last_step > 1.0:
		_fine = true
		_last_step = 0.0
		return _go_to(last_good_w, "lower")
	_misses += 1
	if _misses < 2:
		return -1.0  # measure the same TDP once more: one window can be noise
	_misses = 0
	return _go_to(last_good_w, "hold")


func _on_hold(avg: float, avg_w: float) -> float:
	_hold_windows += 1
	if avg_w < 0.0 and _hold_windows >= RESCAN_WINDOWS:
		return _remeasure()
	# the limit no longer binds: the game draws well under it
	if avg_w >= 0.0 and avg >= line() and avg_w < tdp_w * SLACK and tdp_w > floor_w:
		_slack += 1
		if _slack >= SLACK_N:
			_slack = 0
			_fine = true
			_last_step = 0.0
			_misses = 0
			last_good_w = tdp_w
			return _go_to(max(floor_w, ceilf(avg_w) + 1.0), "lower")
	else:
		_slack = 0
	if avg > ref_fps * (1.0 + SHIFT_UP):
		_up += 1
		_below = 0
		if _up >= SHIFT_N:
			return _remeasure()
		return -1.0
	_up = 0
	if avg < line():
		_below += 1
		if _below >= BELOW_N:
			_below = 0
			if tdp_w >= ceiling_w:
				return _remeasure()  # even the ceiling can't give ref_fps now: a new reference
			last_good_w = min(ceiling_w, tdp_w + 1.0)
			return _go_to(last_good_w, "hold")
		return -1.0
	_below = 0
	return -1.0


func _step_down(avg: float) -> float:
	if tdp_w <= floor_w:
		phase = "hold"
		return -1.0
	var step := 1.0
	if not _fine and avg >= ref_fps * (1.0 - KEEP / 2.0):
		step = BIG_STEP_W
	_last_step = min(step, tdp_w - floor_w)
	return _go_to(tdp_w - _last_step, "lower")


func _remeasure() -> float:
	phase = "measure"
	ref_fps = 0.0
	_runs.clear()
	_window.clear()
	_heavy = 0
	_below = 0
	_up = 0
	_slack = 0
	_misses = 0
	_fine = false
	_last_step = 0.0
	return _go_to(ceiling_w, "measure", true)


func _go_to(watts: float, next_phase: String, force := false) -> float:
	phase = next_phase
	_window.clear()
	_wwindow.clear()
	_heavy = 0
	if next_phase != "hold":
		_hold_windows = 0
	if is_equal_approx(watts, tdp_w) and not force:
		return -1.0
	tdp_w = clamp(watts, floor_w, ceiling_w)
	_settle = SETTLE_N
	changes += 1
	return tdp_w
