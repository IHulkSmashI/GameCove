extends "res://tests/e2e/e2e_case.gd"
## Performance gate behind a game (docs/performance.md): with a game in front GameCove's main
## loop must stay near idle, only the Timers that have to run behind a game may run, the
## quick-menu button must still open the menu fast, and a resume from sleep must be handled
## as promptly as in front (BackgroundMode never makes Power's resume check late).
##
## Budgets come from tools/perf/measure.py on a 2-core CI box (headless): behind a game the
## loop ran 31 iterations a second (145 before), the menu opened in 47-99 ms, the resume was
## handled 7 ms after Power's check was due (the same as before). They have headroom so a
## busy CI machine doesn't fail them; a regression to the old pace (145 a second) still does.

const ProcStats := preload("res://tests/perf/proc_stats.gd")

## Main-loop iterations a second behind a game (measured 31; the old pace was 145).
const MAX_LOOPS_PER_S := 50.0
## Main-thread wake-ups a second behind a game (measured 32; 145 before).
const MAX_MAIN_WAKE_PER_S := 70.0
## CPU of the whole process behind a game, ms per second (measured 6-7 with Auto TDP sampling).
const MAX_CPU_MS_PER_S := 30.0
## Quick-menu button (the intercept's deferred call) to the menu processed, worst press.
const MAX_MENU_MS := 250.0
## Power's resume check due -> `resumed` on the main thread (measured 7 ms before and after).
const MAX_RESUME_MS := 60.0
## Scripts whose Timers may run behind a game, and why (anything else running there fails).
const ALLOWED_BEHIND_GAME := {
	"power.gd": "the 15 s resume/charger check (review M19) and the thermal guard",
	"game_session.gd": "the exit check, only while the game's window isn't watched",
	"session_health.gd": "the heartbeat tick (writes only when the mode changes)",
	"perf_monitor.gd": "samples for Auto TDP, only while it runs",
}
const MEASURE_S := 6.0


func _bg() -> Node:
	return w.main.background


func _behind_game() -> void:
	await start_game(GAME_A)
	await w.idle()
	await w.wait_s(1.5)


## Running Timers in the tree, by script file name.
func _running_timers() -> Array:
	var out: Array = []
	for t in w.tree.root.find_children("*", "Timer", true, false):
		if t.is_stopped() or t.paused:
			continue
		var sc: Script = t.get_script()
		var p: Node = t.get_parent()
		while sc == null and p != null:
			sc = p.get_script()
			p = p.get_parent()
		out.append(sc.resource_path.get_file() if sc != null else "?")
	return out


func test_behind_a_game_the_main_loop_is_near_idle() -> void:
	await _behind_game()
	ok(not w.main._window_focused, "the game in front")
	ok(_bg().throttled(), "BackgroundMode throttles behind the game")
	var a := ProcStats.snapshot()
	await w.wait_s(MEASURE_S)
	var d := ProcStats.delta(a, ProcStats.snapshot())
	ok(float(d["loops_per_s"]) <= MAX_LOOPS_PER_S, "main-loop iterations %s/s <= %s" % [d["loops_per_s"], MAX_LOOPS_PER_S])
	ok(float(d["main_wake_per_s"]) <= MAX_MAIN_WAKE_PER_S, "main-thread wake-ups %s/s <= %s" % [d["main_wake_per_s"], MAX_MAIN_WAKE_PER_S])
	ok(float(d["cpu_ms_per_s"]) <= MAX_CPU_MS_PER_S, "CPU %s ms/s <= %s" % [d["cpu_ms_per_s"], MAX_CPU_MS_PER_S])
	eq(d["children"], [], "no child process of ours behind the game (here: no xprop watch, the fake polls)")
	for f in _running_timers():
		ok(ALLOWED_BEHIND_GAME.has(f), "a Timer in %s runs behind the game: stop it there (see ALLOWED_BEHIND_GAME)" % f)
	var perf: Node = w.autoload("PerfMonitor")
	var pw: Node = power()
	if perf != null and pw != null and not pw.autotune_active():
		ok(perf._timer.is_stopped(), "no performance sampling behind a game without Auto TDP")


func test_front_and_menu_run_at_full_speed() -> void:
	ok(not _bg().throttled(), "home in front: full speed")
	await _behind_game()
	ok(_bg().throttled(), "behind the game: throttled")
	await qam()
	ok(qm().visible and not _bg().throttled(), "the menu over the game: full speed")
	eq(OS.low_processor_usage_mode_sleep_usec, _bg().front_sleep_us, "the project's own pace")
	await b()
	await w.idle()
	ok(_bg().throttled(), "menu closed over the game: throttled again")
	await end_game()
	await w.idle()
	ok(not _bg().throttled(), "the game ended, home in front: full speed")


func test_the_quick_menu_opens_fast_behind_a_game() -> void:
	await _behind_game()
	var c: Node = w.autoload("Controller")
	var ev := dbus_event_for("quick_menu")
	var path := "/org/shadowblip/InputPlumber/CompositeDevice0"
	var worst := 0.0
	for i in 4:
		ok(_bg().throttled(), "throttled before the press")
		var box := {"t0": 0}
		var th := Thread.new()
		th.start(func():
			OS.delay_msec(100 + 97 * i)   # different points in the main loop's sleep
			box["t0"] = Time.get_ticks_usec()
			c.monitor_line.call_deferred({"kind": "event", "path": path, "event": ev, "value": 1.0})
			c.monitor_line.call_deferred({"kind": "event", "path": path, "event": ev, "value": 0.0}))
		await until(func(): return qm().visible, 3000)
		await w.frames(1)
		var ms := (Time.get_ticks_usec() - int(box["t0"])) / 1000.0
		th.wait_to_finish()
		ok(qm().visible, "the button opened the menu")
		worst = maxf(worst, ms)
		await b()
		await w.idle()
		await w.wait_s(0.3)
	ok(worst <= MAX_MENU_MS, "quick menu over a game in %.0f ms (worst) <= %.0f" % [worst, MAX_MENU_MS])


## A sleep while throttled behind a game: Power's 15 s check notices it on time and the
## re-apply runs at once. Twice: when BackgroundMode doesn't see the clock jump (Timers alone
## keep the check on time) and when it does (full speed for the re-apply).
func test_resume_is_handled_promptly_behind_a_game() -> void:
	await _behind_game()
	var p: Node = power()
	var reg: Node = controls()
	var timers: Array = p.get_children().filter(func(n): return n is Timer and is_equal_approx(n.wait_time, p.SOURCE_CHECK_S) and not n.is_stopped())
	ok(not timers.is_empty(), "Power's resume check runs behind the game")
	if timers.is_empty():
		return
	var offset := [0.0]
	var bg_offset := [0.0]
	var real_clock: Callable = p.clock
	var real_bg: Callable = _bg().clock
	p.clock = func(): return [Time.get_unix_time_from_system() + offset[0], Time.get_ticks_msec()]
	# Power counts a sleep between two looks only: wait for its first look after the reset
	var t0 := Time.get_ticks_msec()
	while int(p._clock_mark[1]) == 0 and Time.get_ticks_msec() - t0 < 20000:
		await w.frames(1)
	_bg().clock = func() -> Array: return [Time.get_unix_time_from_system() + bg_offset[0], Time.get_ticks_msec()]
	for bg_sees in [false, true]:
		var soonest := func() -> float:
			var best := 1e9
			for t in timers:
				if not t.is_stopped():
					best = minf(best, t.time_left)
			return best
		await w.wait_s(maxf(0.0, float(soonest.call()) - 0.5) + (15.0 if float(soonest.call()) < 0.6 else 0.0))
		ok(_bg().throttled(), "throttled before the sleep")
		var box := {"resumed": 0, "replayed": 0}
		var on_resumed := func():
			box["resumed"] = Time.get_ticks_usec()
			reg.run_on_worker(func(): box["replayed"] = Time.get_ticks_usec())
		p.resumed.connect(on_resumed, CONNECT_ONE_SHOT)
		var inject := Time.get_ticks_usec()
		var fired := []
		for t in timers:
			var due := inject + int(t.time_left * 1e6)
			t.timeout.connect(func(): fired.append(due), CONNECT_ONE_SHOT)
		offset[0] += 600.0   # ten minutes asleep
		if bg_sees:
			bg_offset[0] += 600.0
		ok(await until(func(): return int(box["replayed"]) > 0, 20000), "resume handled (BackgroundMode sees it: %s)" % bg_sees)
		if p.resumed.is_connected(on_resumed):
			p.resumed.disconnect(on_resumed)
		if box["replayed"] == 0 or fired.is_empty():
			continue
		var ms := (int(box["resumed"]) - int(fired[0])) / 1000.0
		ok(ms <= MAX_RESUME_MS, "`resumed` %.1f ms after Power's check was due <= %.0f (BackgroundMode sees it: %s)" % [ms, MAX_RESUME_MS, bg_sees])
		if bg_sees:
			ok(_bg().resumes_seen() >= 1 and not _bg().throttled(), "full speed after the resume")
		await w.idle()
	p.clock = real_clock
	_bg().clock = real_bg
