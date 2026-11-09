extends "res://tests/test_case.gd"
## Auto TDP: ClawDeck's autotune tests (tests/test_backend.py, 2026-11-08), ported one for one to
## autotune.gd with fake levers and a fake clock, plus GameCove's Power plumbing (levers on
## every backend, learned results per game and power source, battery only, thermald / guard).

const AutotuneScript := preload("res://scripts/device/autotune.gd")
const PowerScript := preload("res://scripts/device/power.gd")
const DeviceScript := preload("res://scripts/device/device.gd")
const Fake := preload("res://tests/fixtures/power/fake_runner.gd")
const Guard := preload("res://scripts/controls/power/thermal_guard.gd")


## Levers on a fake handheld: every write succeeds unless told otherwise; records them.
class FakeLevers extends RefCounted:
	var tdp_ok := true
	var writes: Array = []
	var floor_ok := true
	var rpe := 1000
	var gpu_top := 2400
	var floor := -1
	var profile := ""          # "" = no GPU efficiency mode on this GPU
	var boost_ok_v := true
	var boost_on := true
	var cpu_ok := true
	var cpu_pct := 100
	var tau := 56_000_000
	var tau_fw := 56_000_000
	var tau_refuse := false
	var tau_tries: Array = []
	var epp_v := ""

	func tdp(w: int) -> bool:
		writes.append(w)
		return tdp_ok

	func gpu_floor_ok() -> bool:
		return floor_ok

	func gpu_limits() -> Array:
		return [rpe, gpu_top]

	func gpu_floor(mhz: int) -> bool:
		floor = mhz
		return true

	func gpu_profile_now() -> String:
		return profile

	func gpu_profiles() -> Array:
		return ["base", "power_saving"] if profile != "" else []

	func gpu_profile(v: String) -> bool:
		if profile == "":
			return false
		profile = v
		return true

	func boost_ok() -> bool:
		return boost_ok_v

	func boost(on: bool) -> bool:
		boost_on = on
		return true

	func cpu_ceiling_ok() -> bool:
		return cpu_ok

	func cpu_ceiling(pct: int) -> bool:
		cpu_pct = pct
		return true

	func epp_now() -> String:
		return epp_v

	func epp_choices() -> Array:
		return ["performance", "balance_performance", "balance_power", "power"] if epp_v != "" else []

	func epp(v: String) -> bool:
		epp_v = v
		return true

	func tau_ok() -> bool:
		return true

	func set_tau(us: int) -> bool:
		tau_tries.append(us)
		if tau_refuse:
			return false
		tau = us
		return true

	func restore_tau() -> bool:
		tau = tau_fw
		return true


var _t := 10000.0
var _game: Callable
var _extra := {}


func _tuner(ceiling := 20, learned := {}, lev: RefCounted = null) -> RefCounted:
	var at: RefCounted = AutotuneScript.new()
	at.levers = lev if lev != null else FakeLevers.new()
	_t = 10000.0
	at.clock = func() -> float: return _t
	at.start("1", {}, 8, ceiling)
	var l = at.session.learned
	for k in learned:
		l.set(k, learned[k])
	at.session.settle = 1
	_extra = {}
	return at


## A game whose rendered fps follows the power it gets: fps(tdp, cpu_max_pct, gpu_min_mhz, boost).
func _play(at: RefCounted, fps: Callable, extra := {}) -> void:
	_game = fps
	_extra = extra


func _step(at: RefCounted, n := 1) -> void:
	for i in n:
		_t += 1.0
		var l = at.session.learned if at.session != null else null
		if l == null:
			return
		var f: float = _game.call(l.tdp, l.cpu_max_pct, l.gpu_min_mhz, l.boost)
		var smp := {"fps": f, "source": "rendered", "shown_fps": f, "gpu_busy": 70, "cpu_pct": 40.0,
			"gpu_mhz": 1500.0, "gpu_max_mhz": 2400.0, "pkg_w": float(l.tdp)}
		smp.merge(_extra, true)
		at.step(smp)


func _target(target: int, auto_fps := true, ceiling := 25) -> RefCounted:
	var at := _tuner(ceiling)
	at._start_target(at.session, {}, target, auto_fps)
	return at


# ---- ClawDeck: autotune v3 ----------------------------------------------------------------------

func test_finds_the_lowest_tdp_within_keep_of_the_most() -> void:
	var at := _tuner()
	_play(at, func(tdp, _c, _g, _b): return minf(60.0, 3.0 * tdp))
	_step(at, 3)
	var s = at.session
	eq(s.learned.max_fps, 60.0, "median of three windows at the set TDP")
	eq(s.phase, "balance", "then balance")
	_step(at, 12)
	eq([s.learned.tdp, s.phase, s.learned.fps], [19, "hold", 57.0], "19 W = 95 % of 60, 18 W missed twice")
	var st: Dictionary = at.status()
	ok(st["pct_of_max"] >= 95 and st["fps_per_w"] > 0.0 and st["source"] == "rendered", "status %s" % [st])


func test_one_slow_window_is_measured_again_not_acted_on() -> void:
	var at := _tuner()
	var seq := [60, 60, 60, 60, 59, 40, 59, 59]
	var i := [0]
	_play(at, func(_t2, _c, _g, _b): i[0] += 1; return float(seq[i[0] - 1]))
	_step(at, 7)
	var s = at.session
	ok(s.learned.tdp < 18 and s.phase == "balance" and s.last_delta.begins_with("-"), "lowering went on (%s %s %s)" % [s.learned.tdp, s.phase, s.last_delta])


func test_keeps_a_cpu_gpu_lever_only_if_it_helps() -> void:
	var at := _tuner()
	var lev: FakeLevers = at.levers
	_play(at, func(tdp, _c, gmin, _b): return (52.0 if gmin > 0 else 50.0) if tdp == 20 else 30.0, {"cpu_pct": 35.0, "gpu_busy": 97})
	_step(at, 3)
	var s = at.session
	eq(s.learned.max_fps, 50.0, "measured")
	_step(at)
	ok(s.learned.gpu_min_mhz > 0 and "trying" in s.last_action and "GPU floor" in s.last_action, "GPU floor on trial")
	var first: int = s.learned.gpu_min_mhz
	eq(first, lev.rpe + 100, "floor starts above the efficient clock")
	_step(at)
	eq([s.learned.max_fps, s.learned.gpu_min_mhz], [52.0, first + 100], "+4 %: kept, next step tried")
	_step(at)
	ok(s.learned.gpu_min_mhz == first and "undone" in s.last_action, "no gain: undone")
	eq(s.learned.cpu_max_pct, 100, "the CPU ceiling is never trimmed")


func test_cpu_bound_gets_boost_before_anything_else() -> void:
	var at := _tuner(20, {"boost": false, "cpu_max_pct": 70})
	var lev: FakeLevers = at.levers
	_play(at, func(_t2, cpu, _g, boost): return 40.0 + (5.0 if boost else 0.0) + (5.0 if cpu == 100 else 0.0), {"cpu_pct": 95.0, "gpu_busy": 50})
	_step(at, 4)
	var s = at.session
	ok(s.learned.boost and lev.boost_on, "boost on first")
	_step(at, 2)
	eq([s.learned.cpu_max_pct, s.learned.max_fps], [100, 50.0], "then the CPU ceiling")


func test_cpu_bound_raises_a_power_saving_epp() -> void:
	var lev := FakeLevers.new()
	lev.epp_v = "power"
	lev.boost_ok_v = false
	lev.cpu_ok = false
	var at := _tuner(20, {}, lev)
	_play(at, func(_t2, _c, _g, _b): return 50.0 if lev.epp_v == "balance_performance" else 40.0, {"cpu_pct": 95.0, "gpu_busy": 50})
	_step(at, 5)
	var s = at.session
	eq([lev.epp_v, s.learned.epp], ["balance_performance", "balance_performance"], "EPP lever kept (+25 %%): %s" % s.last_action)


func test_measures_again_when_frame_generation_changes() -> void:
	var at := _tuner()
	var mult := [2.0]
	_play(at, func(_t2, _c, _g, _b): return 30.0)
	for i in 5:
		_extra = {"shown_fps": 30.0 * mult[0]}
		_step(at)
	var s = at.session
	ok(s.phase != "measure" and s.multiplier == 2.0, "2x seen")
	mult[0] = 3.0
	_extra = {"shown_fps": 90.0}
	_step(at)
	ok(s.phase == "measure" and "frame generation changed" in s.last_action, "3x: measured again")


func test_a_new_scene_or_the_clock_measures_again() -> void:
	var at := _tuner()
	var fps := [60.0]
	_play(at, func(tdp, _c, _g, _b): return fps[0] if tdp >= 19 else fps[0] * 0.8)
	_step(at, 14)
	var s = at.session
	eq([s.phase, s.learned.tdp], ["hold", 19], "settled")
	fps[0] = 40.0
	_step(at, 2)
	ok(s.learned.tdp == 20 and "at once" in s.last_action, "heavier area: watts back at once (%s)" % s.last_action)
	_step(at, 4)
	eq([s.learned.max_fps, s.learned.tdp], [40.0, 20], "the new area is measured")
	s.phase = "hold"
	s.measured_at = _t - AutotuneScript.RESCAN_S - 1.0
	s.learned.fps = 40.0
	_step(at)
	ok(s.phase == "measure" and "routine" in s.last_action, "routine re-measure (%s, %s, %s, %s, %s)" % [s.phase, s.last_action, s.measured_at, _t, s.misses])


func test_set_tdp_is_measured_again_and_hands_control_back() -> void:
	var at := _tuner(20, {"tdp": 15})
	at.pause("manual GPU clocks")
	eq(at.set_ceiling(12), 12, "new ceiling applied")
	ok(at.session.phase == "measure" and not at.session.paused, "measured again, pause over")
	at.set_ceiling(3)
	eq(at.session.ceiling_tdp, 8, "never below the floor")
	at.session.ceiling_tdp = 20
	at.set_floor(10, 8)
	ok(at.session.floor_tdp == 10 and at.session.learned.tdp >= 10, "floor raised")


func test_start_reuses_a_result_only_for_the_same_ceiling() -> void:
	var at: RefCounted = AutotuneScript.new()
	at.levers = FakeLevers.new()
	var saved := {"tdp": 14, "max_fps": 60.0, "fps": 58.0, "ceiling": 20, "cpu_max_pct": 90, "confidence": 3}
	at.start("1", saved, 8, 20)
	eq([at.session.phase, at.session.learned.tdp], ["hold", 14], "same ceiling: hold")
	at.start("1", saved, 8, 25)
	eq([at.session.phase, at.session.learned.tdp, at.session.learned.cpu_max_pct], ["measure", 25, 90], "new ceiling: measure")


func test_pause_stops_changes() -> void:
	var at := _tuner()
	_play(at, func(tdp, _c, _g, _b): return minf(60.0, 3.0 * tdp))
	_step(at, 4)
	var t: int = at.session.learned.tdp
	ok(t < 20, "it lowered")
	at.pause()
	_step(at, 5)
	eq(at.session.learned.tdp, t, "no changes while paused")


func test_a_refused_tdp_is_not_learned() -> void:
	var at := _tuner()
	at.levers.tdp_ok = false
	_play(at, func(_t2, _c, _g, _b): return 60.0)
	_step(at, 5)
	eq([at.session.learned.tdp, at.session.phase], [20, "hold"], "a refused write is no change")


func test_stays_under_the_thermal_step_until_the_user_sets_a_tdp() -> void:
	var at := _tuner(25)
	_play(at, func(tdp, _c, _g, _b): return 2.0 * tdp)
	_step(at, 3)
	var s = at.session
	eq([s.learned.max_fps, s.learned.tdp], [50.0, 25], "measured at 25 W")
	ok(at.thermal_step(23) and s.learned.tdp == 23 and s.thermal_cap == 23, "stepped")
	eq(s.last_action, "thermal: stepped to 23 W", "said so")
	var over := false
	for i in 30:
		_step(at)
		over = over or s.learned.tdp > 23
	ok(not over, "never above the step")
	at._remeasure(s, "routine check")
	ok(s.learned.tdp == 23 and "23 W" in s.last_action, "a re-measure goes to the step")
	eq(at.set_ceiling(25), 25, "the user's choice replaces the step")
	eq(s.thermal_cap, -1, "step gone")


func test_learns_on_an_8s_window_and_gives_the_firmwares_back_once_settled() -> void:
	var at := _tuner()
	var lev: FakeLevers = at.levers
	_play(at, func(tdp, _c, _g, _b): return minf(60.0, 3.0 * tdp))
	_step(at)
	ok(lev.tau == 8_000_000 and at.session.short_tau and at.status()["learning"], "short window while learning")
	var steps := 0
	while at.session.phase != "hold" and steps < 40:
		_step(at)
		steps += 1
	eq(lev.tau, 8_000_000, "every learning window on sustained power")
	_step(at, AutotuneScript.SETTLED_WINDOWS)
	ok(lev.tau == lev.tau_fw and not at.session.short_tau and not at.status()["learning"], "learned: firmware window back")
	at._remeasure(at.session, "routine check")
	eq(lev.tau, 8_000_000, "learning again: short at once")
	at.stop()
	eq(lev.tau, lev.tau_fw, "stop gives it back")


func test_gives_the_window_back_when_paused_and_stops_asking_if_refused() -> void:
	var at := _tuner()
	var lev: FakeLevers = at.levers
	_play(at, func(_t2, _c, _g, _b): return 50.0)
	_step(at)
	eq(lev.tau, 8_000_000, "short")
	at.pause("CPU ceiling by hand")
	_step(at)
	ok(lev.tau == lev.tau_fw and not at.session.short_tau, "the user has the controls")
	var lev2 := FakeLevers.new()
	lev2.tau_refuse = true
	var at2 := _tuner(20, {}, lev2)
	_play(at2, func(_t2, _c, _g, _b): return 50.0)
	_step(at2, 5)
	ok(lev2.tau_tries == [8_000_000] and at2.session.tau_refused and lev2.tau == lev2.tau_fw, "asked once (%s)" % [lev2.tau_tries])


func test_a_saved_result_starts_settled_with_the_firmwares_window() -> void:
	var at: RefCounted = AutotuneScript.new()
	var lev := FakeLevers.new()
	at.levers = lev
	at.start("1", {"tdp": 17, "ceiling": 20, "max_fps": 60}, 8, 20)
	ok(at.session.phase == "hold" and lev.tau == lev.tau_fw, "saved: hold, firmware window")
	at.start("2", {}, 8, 20)
	ok(at.session.phase == "measure" and lev.tau == 8_000_000, "new game: short window")
	at.stop()
	eq(lev.tau, lev.tau_fw, "back")


func test_gpu_bound_turns_efficiency_mode_off_before_any_floor() -> void:
	var lev := FakeLevers.new()
	lev.profile = "power_saving"
	var at := _tuner(20, {}, lev)
	_play(at, func(_t2, _c, _g, _b): return 40.0, {"gpu_mhz": 2400.0, "gpu_max_mhz": 2400.0, "gpu_busy": 98})
	at.session.learned.bound = "gpu"
	eq(at._levers(at.session)[0][0], "gpu_base", "efficiency off first")
	_step(at, 4)
	ok(at.session.balance_tried.has("gpu_base") and lev.profile == "base", "tried first")
	eq(at.session.last_delta, "GPU efficiency off", "said so")


func test_tries_efficiency_mode_at_the_floor_and_keeps_it_only_on_the_line() -> void:
	var lev := FakeLevers.new()
	lev.profile = "base"
	var at := _tuner(9, {}, lev)
	_play(at, func(_t2, _c, _g, _b): return 60.0)
	_step(at, 5)
	var s = at.session
	ok(s.learned.tdp == 8 and s.phase == "hold" and s.eff_trial, "floor reached, trial (%s %s)" % [s.learned.tdp, s.phase])
	ok(lev.profile == "power_saving" and s.last_delta == "GPU efficiency on", "efficiency on")
	_step(at)
	ok(lev.profile == "power_saving" and s.learned.gpu_profile == "power_saving" and "kept" in s.last_action, "kept")
	_step(at, 3)
	ok(not s.eff_trial and lev.profile == "power_saving", "tried once")
	var lev2 := FakeLevers.new()
	lev2.profile = "base"
	var at2 := _tuner(9, {}, lev2)
	var seq := [60.0, 60.0, 60.0, 60.0, 60.0, 50.0]
	var i := [0]
	_play(at2, func(_t2, _c, _g, _b): i[0] += 1; return seq[mini(i[0] - 1, seq.size() - 1)])
	_step(at2, 6)
	ok(lev2.profile == "base" and "undone" in at2.session.last_action, "costs frames: undone (%s)" % at2.session.last_action)


func test_short_in_hold_and_gpu_bound_turns_efficiency_off_before_adding_watts() -> void:
	var lev := FakeLevers.new()
	lev.profile = "power_saving"
	var at := _tuner(20, {}, lev)
	var s = at.session
	s.phase = "hold"
	s.learned.max_fps = 60.0
	s.learned.fps = 58.0
	s.learned.tdp = 15
	s.learned.bound = "gpu"
	s.measured_at = _t
	_play(at, func(_t2, _c, _g, _b): return 54.0, {"gpu_mhz": 2400.0, "gpu_max_mhz": 2400.0, "gpu_busy": 98})
	_step(at, 2)
	eq([lev.profile, s.learned.tdp, s.last_delta], ["base", 15, "GPU efficiency off"], "efficiency before watts")


func test_plateau_goes_low_with_big_steps() -> void:
	var at := _tuner(35)
	_play(at, func(tdp, _c, _g, _b): return 60.0 - (35 - tdp) / 13.0 if tdp >= 22 else 59.0 - 3.0 * (22 - tdp))
	var deltas := []
	for i in 80:
		_step(at)
		if not at.session.last_delta in deltas:
			deltas.append(at.session.last_delta)
	var s = at.session
	ok(s.learned.tdp <= 23 and s.phase == "hold", "low on the plateau (%s)" % s.learned.tdp)
	ok(s.learned.fps >= 57.0, "lost at most ~3 fps")
	ok("-3 W" in deltas, "big steps (%s)" % [deltas])
	ok(at.status()["saves_w"] >= 12, "saves 12 W or more")


func test_steep_curve_stops_early() -> void:
	var at := _tuner(35)
	_play(at, func(tdp, _c, _g, _b): return minf(60.0, 2.5 * tdp))
	_step(at, 80)
	var s = at.session
	ok(s.learned.tdp >= 23 and s.learned.tdp <= 25 and s.learned.fps >= 57.0 and s.phase == "hold", "%s W %s fps" % [s.learned.tdp, s.learned.fps])


func test_low_fps_game_keeps_two_fps() -> void:
	var at := _tuner(30)
	_play(at, func(tdp, _c, _g, _b): return minf(30.0, 1.0 * tdp + 8))
	_step(at, 80)
	eq([at.session.learned.tdp, at.session.phase], [20, "hold"], "2 fps rule decides at 30 fps")


func test_frame_limited_holds_the_limit_at_the_floor() -> void:
	var at := _tuner(35)
	_play(at, func(tdp, _c, _g, _b): return 40.0 if tdp >= 12 else 40.0 - 4 * (12 - tdp))
	_step(at, 80)
	var s = at.session
	ok(s.learned.tdp >= s.floor_tdp and s.learned.tdp <= 13 and s.learned.fps >= 38.0, "%s W" % s.learned.tdp)


func test_skips_loading_screens_and_menus() -> void:
	var at := _tuner()
	var seq := [60, 60, 60, 12, 61, 200, 60, 60]
	var i := [0]
	_play(at, func(_t2, _c, _g, _b): i[0] += 1; return float(seq[i[0] - 1]))
	_step(at, 3)
	var s = at.session
	eq(s.learned.max_fps, 60.0, "measured")
	var tdp: int = s.learned.tdp
	_step(at)
	ok(s.learned.tdp == tdp and s.skips == 1, "12 fps skipped")
	_step(at, 2)
	ok(s.skips == 1 and s.phase != "measure", "61 judged, 200 skipped")


func test_three_odd_windows_in_a_row_are_the_game() -> void:
	var at := _tuner()
	_play(at, func(_t2, _c, _g, _b): return 60.0)
	_step(at, 3)
	_play(at, func(_t2, _c, _g, _b): return 15.0)
	_step(at, 3)
	eq(at.session.skips, 0, "the third is used")


func test_saves_only_a_finished_result() -> void:
	var at := _tuner()
	_play(at, func(tdp, _c, _g, _b): return minf(60.0, 3.0 * tdp))
	_step(at, 5)
	var r: Dictionary = at.stop()
	ok(not r["settled"] and "still learning" in r["summary"], "cut short")
	at = _tuner()
	_step(at, 25)
	r = at.stop()
	ok(r["settled"] and str(r["summary"]).begins_with("Auto TDP used 19 W of your 20 W") and "saves 1 W" in r["summary"], r["summary"])


func test_thermal_release_lifts_the_cap_and_measures_again() -> void:
	var at := _tuner(25)
	var s = at.session
	ok(at.thermal_step(19) and s.thermal_cap == 19, "step")
	ok(at.thermal_release(21) and s.thermal_cap == 21 and s.learned.tdp == 19, "partly cooled")
	ok(at.thermal_release(25) and s.thermal_cap == -1 and s.phase == "measure" and s.learned.tdp == 25, "cooled")
	ok(not at.thermal_release(25), "nothing to release")


func test_gives_up_on_a_game_without_a_frame_rate() -> void:
	var at := _tuner()
	var tdp: int = at.session.learned.tdp
	for i in AutotuneScript.NO_FPS_S - 1:
		at.step({"fps": 0.0})
	ok(not at.session.paused and not at.status()["no_frames"], "still waiting")
	at.step({"fps": 0.0})
	ok(at.session.paused and at.status()["no_frames"] and at.session.learned.tdp == tdp, "gave up, limit unchanged")


# ---- ClawDeck: target fps (DeckyTDPTuner's governor) --------------------------------------------

func test_target_fps_fewest_watts_and_fast_back_up_in_a_heavy_scene() -> void:
	var at := _target(60)
	var scene := [4.0]
	_play(at, func(tdp, _c, _g, _b): return minf(90.0, scene[0] * tdp))
	var s = at.session
	eq(s.learned.tdp, 17, "mid-range start (8..25)")
	_step(at, 300)
	eq([s.learned.tdp, s.phase], [15, "target"], "15 W gives 60")
	var st: Dictionary = at.status()
	eq([st["target"], st["saves_w"]], [60, 10], "status")
	scene[0] = 2.95
	_step(at, 12)
	ok(s.learned.tdp >= 19 and "under the 60 target" in s.last_action, "seconds, not minutes (%s)" % s.learned.tdp)
	_step(at, 60)
	eq(s.learned.tdp, 20, "back in the band")


func test_target_fps_a_miss_right_after_lowering_makes_that_the_floor() -> void:
	var at := _target(60, true, 20)
	_play(at, func(tdp, _c, _g, _b): return 62.0 if tdp >= 18 else 50.0)
	_step(at, 200)
	var s = at.session
	eq([s.g_floor, s.learned.tdp], [18, 18], "tried 17 once, back to 18")
	var tried := 0
	for i in 100:
		_step(at)
		if s.learned.tdp == 17:
			tried += 1
	eq([tried, s.learned.tdp], [0, 18], "not again within the floor's time")


func test_auto_fps_holds_the_closest_fps_it_can_reach_and_goes_back_up() -> void:
	var at := _target(60)
	var most := [2.0]
	_play(at, func(tdp, _c, _g, _b): return most[0] * tdp)
	_step(at, 70)
	var s = at.session
	ok(s.target == 47.0 and s.unreachable and "out of reach" in s.last_action, "Auto FPS: 47 (%s)" % s.target)
	_step(at, 200)
	eq(s.learned.tdp, 23, "fewest watts for 47")
	most[0] = 3.0
	_step(at, 40)
	ok(s.target > 47.0 and "room again" in s.last_action, "back up toward 60")


func test_without_auto_fps_an_out_of_reach_target_stays_at_the_full_tdp() -> void:
	var at := _target(60, false)
	_play(at, func(tdp, _c, _g, _b): return 2.0 * tdp)
	_step(at, 120)
	var s = at.session
	ok(s.target == 60.0 and s.learned.tdp == 25 and s.unreachable and at.status()["best_fps"] == 50.0, "stays")
	ok(at.cant_reach, "the UI's cant_reach follows unreachable in target mode")


func test_target_counts_rendered_frames_with_frame_generation() -> void:
	var at := _target(60)
	at.session.fg = 2
	_play(at, func(tdp, _c, _g, _b): return minf(180.0, 8.0 * tdp), {"source": "presented"})
	_step(at, 300)
	eq([at.session.learned.tdp, at.session.multiplier], [15, 2.0], "120 presented = 60 rendered at 15 W")


func test_most_frames_mode_measures_rendered_frames_with_frame_generation() -> void:
	var at := _tuner()
	at.session.fg = 2
	_play(at, func(tdp, _c, _g, _b): return minf(120.0, 6.0 * tdp), {"source": "presented"})
	_step(at, 3)
	eq(at.session.learned.max_fps, 60.0, "120 presented / 2")


func test_target_fps_gets_the_tdp_moving_and_locked_fast() -> void:
	var at := _target(60, true, 30)
	_play(at, func(tdp, _c, _g, _b): return minf(100.0, 5.0 * tdp))
	var s = at.session
	eq(s.learned.tdp, 19, "mid-range start (8..30)")
	var t := 0
	while s.learned.tdp != 12 and t < 200:
		_step(at)
		t += 1
	ok(s.learned.tdp == 12 and t <= 60, "settled in %d s" % t)
	_step(at, 30)
	var changed: float = s.last_change_at
	_step(at, 240)
	ok(s.learned.tdp == 12 and s.last_change_at == changed and s.g_floor == 12, "locked")


func test_target_fps_a_too_low_start_climbs_in_seconds() -> void:
	var at := _target(60, true, 30)
	_play(at, func(tdp, _c, _g, _b): return minf(100.0, 2.4 * tdp))
	_step(at, 12)
	ok(at.session.learned.tdp >= 25, "19 W -> 25 W within ~12 s (%s)" % at.session.learned.tdp)


func test_set_target_switches_modes() -> void:
	var at := _tuner()
	at.set_target(45, false)
	ok(at.session.phase == "target" and at.session.target == 45.0 and not at.session.auto_fps, "target on")
	at.set_target(0)
	eq(at.session.phase, "measure", "off: most frames again")


# ---- ClawDeck: thermal guard --------------------------------------------------------------------

func test_thermal_guard_steps_from_95_to_under_90_never_below_floor() -> void:
	var g := Guard.new()
	var tdp := [17]
	var set_w := func(w): tdp[0] = w; return true
	eq(g.check(95.0, tdp[0], 8, set_w), -1, "95 doesn't trip")
	eq(g.check(96.0, tdp[0], 8, set_w), 15, "over 95: -2 W")
	eq([g.check(92.0, tdp[0], 8, set_w), g.check(90.0, tdp[0], 8, set_w)], [13, 11], "2 W per check")
	ok(g.check(89.5, tdp[0], 8, set_w) == -1 and not g.tripped and tdp[0] == 11, "under 90: stops")
	eq(g.check(93.0, tdp[0], 8, set_w), -1, "90-95 doesn't re-trip")
	eq([g.check(99.0, tdp[0], 8, set_w), g.check(99.0, tdp[0], 8, set_w), g.check(99.0, tdp[0], 8, set_w)], [9, 8, -1], "the floor")
	g.reset()
	ok(not g.tripped and g.stepped_w == -1, "reset")
	eq(Guard.new().check(-1.0, 17, 8, set_w), -1, "no sensor: never acts")


func test_thermal_guard_steps_back_up_to_your_limit_once_cool() -> void:
	var g := Guard.new()
	var tdp := [35]
	var c := func(t): return g.check(t, tdp[0], 8, func(w): tdp[0] = w; return true, 35)
	eq([c.call(97.0), c.call(93.0), c.call(85.0)], [33, 31, -1], "hot, then under 90")
	eq([c.call(85.0), c.call(85.0), tdp[0]], [-1, -1, 31], "80-90 holds")
	eq([c.call(70.0), c.call(70.0), c.call(70.0)], [-1, -1, 33], "30 s under 80: +2 W")
	eq([c.call(70.0), c.call(81.0), c.call(70.0)], [-1, -1, -1], "a warm check starts over")
	eq([c.call(70.0), c.call(70.0), g.stepped_w], [-1, 35, -1], "back at your limit")
	eq([c.call(60.0), tdp[0]], [-1, 35], "nothing to recover")


# ---- GameCove: frame-limit cant_reach (UI) ------------------------------------------------------

func test_frame_limit_cant_reach_at_the_ceiling() -> void:
	var at := _tuner(15)
	at.set_frame_limit(60.0)
	_play(at, func(tdp, _c, _g, _b): return 2.0 * tdp)  # 30 fps at 15 W
	_step(at, 12)
	ok(at.cant_reach, "at the ceiling and under the limit for 10 s")
	var info: Dictionary = at.limit_info()
	eq([info["target_fps"], info["ceiling_w"]], [60.0, 15.0], "info")
	at.set_ceiling(30)
	ok(not at.cant_reach, "a new ceiling clears it")


# ---- GameCove: Power plumbing -------------------------------------------------------------------

func _claw_power(test_name: String) -> Node:
	var row := {}
	for d in DeviceScript.load_table():
		if d["id"] == "msi-claw-8-ex":
			row = d
	var root := ProjectSettings.globalize_path("user://test_power_autotune/" + test_name)
	DirAccess.make_dir_recursive_absolute(root)
	DirAccess.remove_absolute(root + "/power.cfg")
	var p: Node = PowerScript.new()
	p.setup(Fake.from_fixture(fixture("power/bus_claw_powerstation.json")), row, root)
	p.config_path = root + "/power.cfg"
	p.detect()
	p.load_autotune_opts()
	return p


func test_power_runs_clawdecks_rules_and_restores_on_stop() -> void:
	var p := _claw_power("rules")
	var events := []
	p.autotune_changed.connect(func(on): events.append(on))
	p.request_feed(60.0, 10.0)
	eq(events, [], "feed before start does nothing")
	p.set_tdp(20.0)
	p.request_autotune(true, "steam:1")
	ok(p.autotune_active(), "running on battery")
	p.autotune.session.settle = 1
	for i in 30:
		var w: float = p.state()["tdp_w"]
		p.request_feed(minf(60.0, 3.0 * w), w, {"fps": minf(60.0, 3.0 * w), "cpu_load": 40.0, "gpu_load": 70.0})
	eq(p.state()["tdp_w"], 19.0, "ClawDeck's answer: 19 W holds 57 of 60 fps")
	p.request_autotune(false)
	eq(events, [true, false], "autotune_changed both ways")
	eq(p.state()["tdp_w"], 20.0, "the user's TDP back")
	var cfg := ConfigFile.new()
	cfg.load(p.config_path)
	var saved: Variant = cfg.get_value("autotune@msi-claw-8-ex", "steam:1|battery", {})
	ok(saved is Dictionary and int(saved.get("tdp", 0)) == 19 and int(saved.get("ceiling", 0)) == 20, "learned saved per game and source: %s" % [saved])
	p.request_autotune(true, "steam:1")
	eq([p.autotune.session.phase, p.state()["tdp_w"]], ["hold", 19.0], "next start reuses it")
	p.request_autotune(false)
	p.free()


func test_power_autotune_is_for_battery_unless_asked() -> void:
	var p := _claw_power("plugged")
	p.plugged = true
	p.set_tdp(20.0)
	ok(not p.autotune_start("g"), "plugged in: off by default (ClawDeck)")
	ok(p.set_autotune_option("plugged", true), "option saved")
	ok(p.autotune_start("g"), "on when asked")
	p.load_autotune_opts()
	eq(p.autotune_opts["plugged"], true, "persisted per device")
	p.autotune_stop()
	p.free()


func test_power_options_reach_the_running_session() -> void:
	var p := _claw_power("opts")
	p.set_tdp(25.0)
	p.autotune_start("g")
	p.set_autotune_option("target", 45)
	ok(p.autotune.session.phase == "target" and p.autotune.session.user_target == 45, "target applied at once")
	p.set_autotune_option("keep_pct", 10.0)
	eq(p.autotune.session.keep_pct, 10.0, "keep applied")
	p.set_autotune_option("floor_w", 12)
	eq(p.autotune.session.floor_tdp, 12, "floor applied")
	ok(not p.set_autotune_option("nope", 1), "unknown option refused")
	p.autotune_stop()
	p.free()


func test_power_slider_while_tuning_starts_over_from_the_new_limit() -> void:
	var p := _claw_power("slider")
	p.set_tdp(20.0)
	p.autotune_start("g")
	p.autotune.session.phase = "hold"
	ok(p.set_tdp(15.0), "slider while tuning")
	eq([p.autotune.session.phase, p.autotune.session.ceiling_tdp, p.state()["tdp_w"]], ["measure", 15, 15.0], "measured again from 15 W")
	p.autotune_stop()
	eq(p.state()["tdp_w"], 15.0, "the new pick stays after the game")
	p.free()


func test_power_feed_runs_on_the_worker() -> void:
	var p := _claw_power("feed_worker")
	p.set_tdp(25.0)
	p.request_autotune(true)
	var fed := [0]
	var thread_ok := [true]
	var real: RefCounted = p.autotune
	var probe := func(_smp):
		fed[0] += 1
		if OS.get_thread_caller_id() == OS.get_main_thread_id():
			thread_ok[0] = false
	real.set_meta("probe", probe)
	var gate := Semaphore.new()
	p._thread = Thread.new()
	p._thread.start(p._worker)
	p._queue("hold", func(): gate.wait(); return true)
	for i in 5:
		p.request_feed(60.0, 12.0)
	p._queue("count", func(): probe.call({}); return true)
	gate.post()
	var waited := 0
	while waited < 2000 and fed[0] == 0:
		OS.delay_msec(10)
		waited += 10
	OS.delay_msec(50)
	ok(thread_ok[0] and fed[0] == 1, "worker ran the queued jobs")
	p._job_mutex.lock()
	var left: int = p._job_order.size()
	p._job_mutex.unlock()
	eq(left, 0, "five samples collapsed and ran")
	p._exit_tree()
	p.free()


func test_power_run_sync_waits_for_the_worker() -> void:
	var p := _claw_power("sync")
	eq(p.run_sync(func(): return 7), 7, "inline without a worker")
	p._thread = Thread.new()
	p._thread.start(p._worker)
	var on_worker := [false]
	var r: Variant = p.run_sync(func():
		on_worker[0] = OS.get_thread_caller_id() != OS.get_main_thread_id()
		return "done")
	ok(r == "done" and on_worker[0], "ran on the worker and returned")
	p._exit_tree()
	p.free()
