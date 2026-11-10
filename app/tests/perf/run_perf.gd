extends SceneTree
## Performance harness: the real app on a fake handheld (the e2e world, see
## tests/e2e/world.gd) held in each state for PERF_SECONDS while /proc/self
## says what it costs (tests/perf/proc_stats.gd). Start it through
## tools/perf/measure.py, which builds the fixture, gives the process private
## HOME / XDG folders and prints the table.
##
## States (PERF_STATES, comma list, all by default):
##   home       home screen in front, nobody touching it
##   home_menu  the quick menu open over home
##   game       a game in front: our window lost focus (gamescope's focus change)
##   game_menu  the quick menu open over the game
## Then, in the game state:
##   latency    PERF_LATENCY_RUNS times: the handheld's quick-menu button arrives the way
##              InputPlumber's intercept delivers it (a deferred call from the monitor's
##              reader thread) at a random moment; time until the menu's first drawn frame
##   resume     PERF_RESUME_RUNS times: a sleep (the wall clock jumps 60 s ahead of the
##              monotonic one, Power's own test clock) just before Power's resume check
##              is due; time from that check being due to `resumed` on the main thread
##              (TDP and charge limit put back) and to the controls' replay done on the
##              Controls worker
## Prints "PERF STATE {json}" per state and a last line "PERF RESULT {json}".

const ProcStats := preload("res://tests/perf/proc_stats.gd")
const Case := preload("res://tests/e2e/e2e_case.gd")

var world: RefCounted
var case: RefCounted
var seconds := 60.0
var result := {"states": {}, "latency_ms": [], "resume": []}


func _initialize() -> void:
	_run()


func _env_num(n: String, d: float) -> float:
	var v := OS.get_environment(n)
	return v.to_float() if v.is_valid_float() else d


func _run() -> void:
	seconds = _env_num("PERF_SECONDS", 60.0)
	var states := Array(OS.get_environment("PERF_STATES").split(",", false))
	if states.is_empty():
		states = ["home", "home_menu", "game", "game_menu", "latency", "resume"]
	set_meta(&"gamecove_e2e", true)
	world = load("res://tests/e2e/world.gd").new(self)
	var err: String = await world.configure()
	if err != "":
		printerr("PERF FAIL setup: " + err)
		quit(2)
		return
	print("PERF STEP boot")
	await world.boot_main()
	case = Case.new()
	case.w = world
	# start-up work (library scan, first detections, art) ends before anything is measured
	await world.idle()
	await _wait(_env_num("PERF_SETTLE_S", 10.0))
	result["setup"] = world.setup_name
	result["seconds"] = seconds
	result["display"] = DisplayServer.get_name()
	for s in states:
		print("PERF STEP " + s)
		match s:
			"home":
				await _measure("home")
			"home_menu":
				await case.qam()
				await world.idle()
				await _measure("home_menu")
				await case.b()
				await world.idle()
			"game":
				await _ensure_game()
				await _measure("game")
			"game_menu":
				await _ensure_game()
				await case.qam()
				await world.idle()
				await _measure("game_menu")
				await case.b()
				await world.idle()
			"latency":
				await _ensure_game()
				await _latency(int(_env_num("PERF_LATENCY_RUNS", 10)))
			"resume":
				await _ensure_game()
				await _resume(int(_env_num("PERF_RESUME_RUNS", 4)))
	print("PERF RESULT " + JSON.stringify(result))
	if world.main != null and world.main.session.is_active():
		world.main.session.stop()
	await world.shutdown_main()
	quit(0)


func _wait(s: float) -> void:
	if s > 0.0:
		await create_timer(s).timeout


func _ensure_game() -> void:
	if world.main.session.is_active():
		return
	await case.start_game(Case.GAME_A)
	await world.idle()
	if world.main._window_focused:
		printerr("PERF FAIL game: our window still has focus with the game in front")
	await _wait(3.0)


func _heartbeat_seq() -> int:
	var p := OS.get_environment("GAMECOVE_HEARTBEAT")
	if p == "" or not FileAccess.file_exists(p):
		return -1
	return FileAccess.get_file_as_string(p).split(" ", false)[0].to_int()


func _measure(state: String) -> void:
	var hb0 := _heartbeat_seq()
	var a := ProcStats.snapshot()
	await _wait(seconds)
	var b := ProcStats.snapshot()
	var hb1 := _heartbeat_seq()
	var d := ProcStats.delta(a, b)
	d["heartbeats_per_min"] = snappedf((hb1 - hb0) * 60.0 / d["seconds"], 0.1) if hb0 >= 0 else -1
	d["heartbeat"] = FileAccess.get_file_as_string(OS.get_environment("GAMECOVE_HEARTBEAT")).strip_edges() if hb1 >= 0 else ""
	d["processing"] = _processing_nodes()
	d["window_focused"] = world.main._window_focused
	d["menu_open"] = world.main.quick_menu.visible
	result["states"][state] = d
	print("PERF STATE %s %s" % [state, JSON.stringify(d)])


## Nodes that run code every main-loop iteration (_process / _physics_process on, or a
## running Timer), and running Tweens: what the main loop does besides sleeping.
func _processing_nodes() -> Array:
	var out: Array = []
	for n in root.find_children("*", "", true, false):
		var what := ""
		if n is Timer and not n.is_stopped() and not n.paused:
			what = "Timer %.1fs" % n.wait_time
		elif n.is_processing() or n.is_physics_processing():
			what = "process"
		if what != "":
			var sc: Script = n.get_script()
			var owner_sc: Script = n.get_parent().get_script() if n.get_parent() != null else null
			var src := sc.resource_path.get_file() if sc != null else (owner_sc.resource_path.get_file() if owner_sc != null else n.get_class())
			out.append("%s (%s)" % [what, src])
	for tw in get_processed_tweens():
		out.append("Tween")
	out.sort()
	return out


## The quick-menu button from the intercept's reader thread, at a random moment.
func _latency(runs: int) -> void:
	var c: Node = world.autoload("Controller")
	var ev: String = case.dbus_event_for("quick_menu")
	var path := "/org/shadowblip/InputPlumber/CompositeDevice0"
	for i in runs:
		var box := {"t0": 0, "opened": 0}
		var on_action := func(_a): if box["opened"] == 0: box["opened"] = Time.get_ticks_usec()
		c.ui_action.connect(on_action)
		var th := Thread.new()
		th.start(func():
			OS.delay_msec(randi_range(300, 1300))
			box["t0"] = Time.get_ticks_usec()
			# press and release in one go: some handhelds act on the press, others (a button that
			# is also a chord modifier) on the release; either way t0 is the event that acts
			c.monitor_line.call_deferred({"kind": "event", "path": path, "event": ev, "value": 1.0})
			c.monitor_line.call_deferred({"kind": "event", "path": path, "event": ev, "value": 0.0}))
		var deadline := Time.get_ticks_msec() + 5000
		while not world.main.quick_menu.visible and Time.get_ticks_msec() < deadline:
			await process_frame
		# the frame that shows it: drawn on a display, processed headless (nothing is drawn there)
		if DisplayServer.get_name() == "headless":
			await process_frame
		else:
			await RenderingServer.frame_post_draw
		var t1 := Time.get_ticks_usec()
		th.wait_to_finish()
		c.ui_action.disconnect(on_action)
		result.get_or_add("open_ms", []).append(snappedf((int(box["opened"]) - int(box["t0"])) / 1000.0, 0.1))
		if not world.main.quick_menu.visible:
			printerr("PERF FAIL latency: the quick menu didn't open")
			continue
		result["latency_ms"].append(snappedf((t1 - int(box["t0"])) / 1000.0, 0.1))
		await world.idle()
		await case.b()
		await world.idle()
		await _wait(1.0)
	print("PERF LATENCY " + JSON.stringify(result["latency_ms"]))


## A sleep just before Power's 15 s resume check is due (review M19's path, the one
## that notices a sleep while a game is in front).
func _resume(runs: int) -> void:
	var power: Node = world.autoload("Power")
	var controls: Node = world.autoload("Controls")
	# Power's check timers (one in production; the e2e world starts Power twice): the first due
	var timers: Array = power.get_children().filter(func(n): return n is Timer and is_equal_approx(n.wait_time, power.SOURCE_CHECK_S))
	if timers.is_empty():
		printerr("PERF FAIL resume: Power's check timer isn't running")
		return
	var offset := [0.0]
	var real_clock: Callable = power.clock
	power.clock = func(): return [Time.get_unix_time_from_system() + offset[0], Time.get_ticks_msec()]
	var bg: Node = world.main.get("background")
	var real_bg_clock: Variant = bg.clock if bg != null else null
	if bg != null:
		bg.clock = func() -> Array: return [Time.get_unix_time_from_system() + offset[0], Time.get_ticks_msec()]
	for i in runs:
		# right after a check, so the jump lands well before the next one
		await timers[0].timeout
		var next := func() -> float:
			var best := 1e9
			for t in timers:
				if not t.is_stopped():
					best = minf(best, t.time_left)
			return best
		await _wait(float(next.call()) - 0.6)
		var box := {"resumed": 0, "replayed": 0}
		var on_resumed := func():
			box["resumed"] = Time.get_ticks_usec()
			controls.run_on_worker(func(): box["replayed"] = Time.get_ticks_usec())
		power.resumed.connect(on_resumed, CONNECT_ONE_SHOT)
		var due := Time.get_ticks_usec() + int(float(next.call()) * 1e6)
		# the device sleeps (the wall clock jumps; the monotonic one stood still)
		offset[0] += 60.0
		var deadline := Time.get_ticks_msec() + 20000
		while box["replayed"] == 0 and Time.get_ticks_msec() < deadline:
			await process_frame
		if box["replayed"] == 0:
			printerr("PERF FAIL resume: no resume handling within 20 s")
			if power.resumed.is_connected(on_resumed):
				power.resumed.disconnect(on_resumed)
			continue
		var r := {"resumed_ms": snappedf((int(box["resumed"]) - due) / 1000.0, 0.1),
			"replayed_ms": snappedf((int(box["replayed"]) - due) / 1000.0, 0.1)}
		result["resume"].append(r)
		print("PERF RESUME " + JSON.stringify(r))
		await world.idle()
	if bg != null:
		bg.clock = real_bg_clock
	power.clock = real_clock
