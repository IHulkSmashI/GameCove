extends "res://tests/test_case.gd"
## Main-loop pacing behind a game (scripts/system/background_mode.gd): long sleeps only
## while nothing of ours is visible, never past a Timer that is due, full speed at once for
## the quick menu, our window, and after a resume from sleep (the resume re-apply must not
## get slower behind a game).

const BackgroundMode := preload("res://scripts/system/background_mode.gd")


func _root() -> Window:
	return (Engine.get_main_loop() as SceneTree).root


## A BackgroundMode in the tree on a clock the test moves: [wall s, ticks ms].
func _mode(clock: Array) -> Node:
	var m: Node = BackgroundMode.new()
	m.clock = func() -> Array: return clock.duplicate()
	m.front_sleep_us = 6900
	_root().add_child(m)
	return m


func _done(m: Node) -> void:
	m.queue_free()
	_root().remove_child(m)
	OS.low_processor_usage_mode_sleep_usec = 6900


func test_full_speed_in_front_long_sleeps_behind() -> void:
	var clock := [1000.0, 50_000]
	var m := _mode(clock)
	m._ready()
	eq(OS.low_processor_usage_mode_sleep_usec, 6900, "in front: the project's sleep")
	ok(not m.in_background(), "starts in front")
	ok(not m.is_processing(), "nothing per iteration in front, even after READY turned _process on")
	m.set_front(false)
	ok(m.throttled(), "a game in front: throttled")
	eq(OS.low_processor_usage_mode_sleep_usec, BackgroundMode.BACK_SLEEP_US, "long sleep with no Timer due")
	ok(m.is_processing(), "looks once per iteration while behind")
	m.set_front(true)
	eq(OS.low_processor_usage_mode_sleep_usec, 6900, "our window back: full speed at once")
	ok(not m.is_processing(), "nothing runs per iteration in front")
	_done(m)


func test_the_quick_menu_restores_full_speed_at_once() -> void:
	var clock := [1000.0, 50_000]
	var m := _mode(clock)
	m.set_front(false)
	m.set_menu(true)
	eq(OS.low_processor_usage_mode_sleep_usec, 6900, "menu over the game: full speed before its first frame")
	ok(not m.throttled(), "not throttled with the menu open")
	m.set_menu(false)
	eq(OS.low_processor_usage_mode_sleep_usec, BackgroundMode.BACK_SLEEP_US, "menu closed over the game: long sleep again")
	_done(m)


## Stands in for a Timer in the tree (the unit runner's tree isn't running).
class FakeTimer extends RefCounted:
	var time_left := 0.0
	var paused := false
	var running := true
	var in_tree := true

	func is_stopped() -> bool:
		return not running

	func can_process() -> bool:
		return true

	func is_inside_tree() -> bool:
		return in_tree


func test_a_due_timer_is_never_slept_past() -> void:
	var clock := [1000.0, 50_000]
	var m := _mode(clock)
	var t := FakeTimer.new()
	t.time_left = 0.010
	m._timers = [t]
	m.set_front(false)
	eq(OS.low_processor_usage_mode_sleep_usec, 10_000, "sleeps only until the Timer is due")
	t.time_left = 0.001
	m._tick()
	eq(OS.low_processor_usage_mode_sleep_usec, 6900, "never shorter than in front")
	t.paused = true
	m._tick()
	eq(OS.low_processor_usage_mode_sleep_usec, BackgroundMode.BACK_SLEEP_US, "a paused Timer doesn't count")
	t.paused = false
	t.running = false
	m._tick()
	eq(OS.low_processor_usage_mode_sleep_usec, BackgroundMode.BACK_SLEEP_US, "a stopped Timer doesn't count")
	var a := FakeTimer.new()
	a.time_left = 0.030
	var b := FakeTimer.new()
	b.time_left = 0.020
	m._timers.append_array([a, b])
	m._tick()
	eq(OS.low_processor_usage_mode_sleep_usec, 20_000, "the soonest of several")
	b.in_tree = false
	m._tick()
	eq(OS.low_processor_usage_mode_sleep_usec, 30_000, "a Timer that left the tree is forgotten")
	eq(m._timers.size(), 2, "and dropped from the list")
	_done(m)


func test_timers_made_while_behind_are_seen() -> void:
	var clock := [1000.0, 50_000]
	var m := _mode(clock)
	m.set_front(false)
	var n := Node.new()
	var t := Timer.new()
	m._on_node_added(n)
	m._on_node_added(t)
	eq(m._timers, [t], "a Timer added while throttled (GameSession's, a toast's) is watched; other nodes aren't")
	n.free()
	t.free()
	_done(m)


func test_resume_from_sleep_goes_full_speed_while_settings_are_put_back() -> void:
	var clock := [1000.0, 50_000]
	var m := _mode(clock)
	m.set_front(false)
	clock[0] += 1.0
	clock[1] += 1000
	m._tick()
	ok(m.throttled(), "an ordinary second: still throttled")
	# asleep 10 minutes: the wall clock moved, the monotonic one didn't
	clock[0] += 600.0
	clock[1] += 30
	m._tick()
	eq(m.resumes_seen(), 1, "the first iteration after waking notices it")
	ok(not m.throttled(), "full speed after a resume")
	eq(OS.low_processor_usage_mode_sleep_usec, 6900, "the resume re-apply runs at the normal pace")
	clock[0] += BackgroundMode.RESUME_FAST_S - 1.0
	clock[1] += int((BackgroundMode.RESUME_FAST_S - 1.0) * 1000.0)
	m._tick()
	eq(OS.low_processor_usage_mode_sleep_usec, 6900, "still full speed while the controller lights come back (5 s)")
	clock[0] += 2.0
	clock[1] += 2000
	m._tick()
	ok(m.throttled(), "throttled again once it's all back")
	eq(OS.low_processor_usage_mode_sleep_usec, BackgroundMode.BACK_SLEEP_US, "long sleep again")
	_done(m)


func test_resume_rule_matches_main_and_power() -> void:
	ok(not BackgroundMode.resumed_between([0.0, 0], [100.0, 10], 20.0), "no mark yet: no resume")
	ok(not BackgroundMode.resumed_between([100.0, 1000], [119.0, 1000], 20.0), "19 s gap: not a sleep")
	ok(BackgroundMode.resumed_between([100.0, 1000], [121.0, 1000], 20.0), "21 s gap: a sleep")
	eq(BackgroundMode.RESUME_GAP_S, preload("res://scripts/main.gd").RESUME_GAP_S, "same gap as main.gd")
	eq(BackgroundMode.RESUME_GAP_S, preload("res://scripts/device/power.gd").RESUME_GAP_S, "same gap as Power")


func test_sleep_bounds() -> void:
	eq(BackgroundMode.sleep_for(-1.0, 6900, 33000), 33000, "no Timer: longest sleep")
	eq(BackgroundMode.sleep_for(5.0, 6900, 33000), 33000, "far Timer: longest sleep")
	eq(BackgroundMode.sleep_for(0.015, 6900, 33000), 15000, "near Timer: until it's due")
	eq(BackgroundMode.sleep_for(0.0, 6900, 33000), 6900, "due now: the normal pace")
	ok(BackgroundMode.BACK_SLEEP_US <= 50_000, "the quick-menu button never waits more than 50 ms for the main loop")


func test_leaving_the_tree_restores_the_sleep() -> void:
	var clock := [1000.0, 50_000]
	var m := _mode(clock)
	m.set_front(false)
	m._exit_tree()
	eq(OS.low_processor_usage_mode_sleep_usec, 6900, "restored when it goes")
	_done(m)
	OS.low_processor_usage_mode_sleep_usec = 6900
