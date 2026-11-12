extends Node
## Keeps GameCove close to free while something else is in front (a game, Steam,
## a store's window): the main loop sleeps longer between iterations, and wakes
## the moment the quick menu opens or our window comes back.
##
## Godot's low-processor mode sleeps low_processor_usage_mode_sleep_usec after
## every main-loop iteration (6.9 ms by default: about 145 wake-ups a second
## even when nothing changes). Behind a game nothing of ours is visible, so here
## it sleeps up to BACK_SLEEP_US instead (about 30 a second). main.gd tells it
## who is in front (set_front) and whether the quick menu is open (set_menu).
##
## What must not get late doesn't:
##  - Timers: before each sleep the next due Timer in the tree is found and the
##    sleep ends when it is due, so a heartbeat, Power's 15 s resume/charger check,
##    the thermal guard or GameSession's exit check fire exactly as they would in
##    front (never later than the normal 6.9 ms granularity).
##  - Sleep and wake: the first iteration after a resume sees the wall clock jump
##    ahead of the monotonic clock (the same rule as main.gd and Power use) and
##    goes back to full speed for RESUME_FAST_S, so the resume re-apply (Power's
##    worker, `resumed` on the main thread, the controls' replay, the controller
##    lights 5 s later, InputPlumber's intercept) runs as fast as it would in front.
##    Nothing here runs before a suspend, and nothing is debounced or delayed.
##  - The quick menu: InputPlumber's button reaches the main thread as a deferred
##    call from the intercept's reader thread, so it waits at most one sleep
##    (BACK_SLEEP_US); set_menu(true) restores full speed before the menu's first
##    frame. Measured in tools/perf/measure.py ("latency").

## Wall clock running this far ahead of the monotonic clock between two iterations = the
## device slept (main.gd RESUME_GAP_S, Power RESUME_GAP_S).
const RESUME_GAP_S := 20.0
## After a resume: full speed this long (the controller lights re-apply 5 s after it).
const RESUME_FAST_S := 30.0
## After a Timer of ours queued work for a worker thread (Power's 15 s check): full speed this
## long, so what the worker hands back with a deferred call lands within one front sleep, not
## after a long one (the resume re-apply was up to 33 ms late behind a game, review of 56f5255).
const WORKER_BURST_S := 0.25
## Longest sleep between main-loop iterations while nothing of ours is visible.
## The quick-menu button waits at most this long, so it stays well under 100 ms.
const BACK_SLEEP_US := 33_000

## The sleep in front (the project's own setting, read at start).
var front_sleep_us := 6900
## Our window has focus / the quick menu is open.
var front := true
var menu := false
## Our UI came in front (true: the window has focus or the quick menu is open) or went behind
## (false). Only on a change. SessionHealth listens: the hang watchdog is on while we are in
## front of a game.
signal front_changed(in_front: bool)
var _was_front := true
## Clocks (tests swap it): [unix seconds, ticks msec].
var clock: Callable = func() -> Array: return [Time.get_unix_time_from_system(), Time.get_ticks_msec()]

var _fast_until_ms := 0
var _mark: Array = [0.0, 0]
var _timers: Array = []
var _watching := false
var _resumes := 0


func _init() -> void:
	name = "BackgroundMode"
	# after every Timer (priority 0) has counted this iteration's time, so time_left is current
	process_priority = 1 << 30
	process_mode = Node.PROCESS_MODE_ALWAYS
	front_sleep_us = OS.low_processor_usage_mode_sleep_usec
	set_process(false)


func _ready() -> void:
	_apply()   # Godot turns processing on at READY for a script with _process: only behind


func _exit_tree() -> void:
	_stop_watching()
	OS.low_processor_usage_mode_sleep_usec = front_sleep_us


## Our window gained (true) or lost (false) focus.
func set_front(on: bool) -> void:
	front = on
	_apply()


## The quick menu opened (true) or closed (false).
func set_menu(open: bool) -> void:
	menu = open
	_apply()


## True while nothing of ours is visible: the main loop may sleep long.
func in_background() -> bool:
	return not (front or menu)


## Something was just handed to a worker thread and its answer comes back as a deferred call on
## this thread: stay at full speed for WORKER_BURST_S so the main loop is not asleep when it does.
func burst(seconds := WORKER_BURST_S) -> void:
	if not in_background():
		return
	_fast_until_ms = maxi(_fast_until_ms, int(clock.call()[1]) + int(seconds * 1000.0))
	OS.low_processor_usage_mode_sleep_usec = front_sleep_us


## Sleeping long now (in the background and not just after a resume).
func throttled() -> bool:
	return in_background() and int(clock.call()[1]) >= _fast_until_ms


## Resumes noticed while in the background (tests, the perf harness).
func resumes_seen() -> int:
	return _resumes


func _apply() -> void:
	var now_front := not in_background()
	if now_front != _was_front:
		_was_front = now_front
		front_changed.emit(now_front)
	if in_background():
		_mark = clock.call()
		_start_watching()
		set_process(true)
		_tick()
	else:
		set_process(false)
		_stop_watching()
		OS.low_processor_usage_mode_sleep_usec = front_sleep_us


func _process(_delta: float) -> void:
	_tick()


## One iteration in the background: a resume check (two clock reads) and the next sleep.
func _tick() -> void:
	var now: Array = clock.call()
	if resumed_between(_mark, now, RESUME_GAP_S):
		_resumes += 1
		_fast_until_ms = int(now[1]) + int(RESUME_FAST_S * 1000.0)
	_mark = now
	var sleep := front_sleep_us
	if int(now[1]) >= _fast_until_ms:
		sleep = sleep_for(next_timer_s(), front_sleep_us, BACK_SLEEP_US)
	OS.low_processor_usage_mode_sleep_usec = sleep


static func resumed_between(before: Array, after: Array, gap_s: float) -> bool:
	if int(before[1]) == 0:
		return false
	var wall: float = float(after[0]) - float(before[0])
	var mono: float = (int(after[1]) - int(before[1])) / 1000.0
	return wall - mono > gap_s


## Microseconds to sleep so the next Timer (due in `next_s` seconds, < 0 = none) isn't late.
static func sleep_for(next_s: float, lo_us: int, hi_us: int) -> int:
	if next_s < 0.0:
		return hi_us
	return clampi(int(next_s * 1_000_000.0), lo_us, hi_us)


## Seconds until the next running Timer in the tree fires, -1 when none runs.
func next_timer_s() -> float:
	var best := -1.0
	var i := 0
	while i < _timers.size():
		var t: Variant = _timers[i]
		if not is_instance_valid(t) or not t.is_inside_tree():
			_timers.remove_at(i)
			continue
		if not t.is_stopped() and not t.paused and t.can_process():
			if best < 0.0 or t.time_left < best:
				best = t.time_left
		i += 1
	return best


func _start_watching() -> void:
	if _watching or not is_inside_tree():
		return
	_watching = true
	_timers = get_tree().root.find_children("*", "Timer", true, false)
	get_tree().node_added.connect(_on_node_added)


func _stop_watching() -> void:
	if not _watching:
		return
	_watching = false
	_timers.clear()
	if is_inside_tree() and get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)


func _on_node_added(n: Node) -> void:
	if n is Timer:
		_timers.append(n)
