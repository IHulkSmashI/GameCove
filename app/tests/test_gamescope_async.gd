extends "res://tests/test_case.gd"
## xprop off the main thread: CommandRunner's worker, Gamescope's async calls,
## and GameSession polling through them. Nothing real runs: the worker test
## overrides run(), the rest use a queued fake that answers on flush().

const CommandRunner := preload("res://scripts/gamescope/command_runner.gd")
const GamescopeScript := preload("res://scripts/gamescope/gamescope.gd")
const GameSession := preload("res://scripts/launch/game_session.gd")


## A real CommandRunner whose run() records instead of starting a program.
class RecordingRunner:
	extends CommandRunner
	var seen: Array = []          # [first arg, thread id], in run order
	var lock := Mutex.new()
	func run(_program: String, args: PackedStringArray) -> Dictionary:
		lock.lock()
		seen.append([args[0], OS.get_thread_caller_id()])
		lock.unlock()
		return {"exit": 0, "output": ""}


## Like the real runner's worker, but jobs wait until flush() (the "worker"
## finishing) so tests can check that nothing happens before the answer.
class QueuedXprop:
	extends RefCounted
	var root := {}
	var jobs: Array = []
	var sync_calls := 0

	func run(_program: String, args: PackedStringArray) -> Dictionary:
		sync_calls += 1
		return _answer(args)

	func run_async(_program: String, args: PackedStringArray, done := Callable()) -> void:
		jobs.append([args, done])

	func flush() -> void:
		while not jobs.is_empty():
			var j: Array = jobs.pop_front()
			var r := _answer(j[0])
			if j[1].is_valid():
				j[1].call(r)

	func _answer(args: PackedStringArray) -> Dictionary:
		var i := args.find("-set")
		if i >= 0:
			var vals := []
			for p in args[i + 2].split(","):
				vals.append(p.to_int())
			root[args[i + 1]] = vals
			return {"exit": 0, "output": ""}
		var atom: String = args[args.size() - 1]
		if root.has(atom):
			var s := PackedStringArray()
			for v in root[atom]:
				s.append(str(v))
			return {"exit": 0, "output": "%s = %s\n" % [atom, ", ".join(s)]}
		return {"exit": 0, "output": "%s:  not found.\n" % atom}


class FakeLauncher:
	extends RefCounted
	func settings_for(_key: String) -> Dictionary:
		return {"goal": "balanced", "fps_limit": 40}
	func auto_tdp_for(_key: String) -> bool:
		return false


func _gamescope() -> Array:
	var x := QueuedXprop.new()
	var g = GamescopeScript.new()
	g.runner = x
	g.env = {"GAMESCOPE_WAYLAND_DISPLAY": "gamescope-0", "DISPLAY": ""}
	x.root[GamescopeScript.ATOM_FOCUSABLE_APPS] = [769]
	return [g, x]


func test_runner_runs_jobs_in_order_on_a_worker_thread() -> void:
	var r := RecordingRunner.new()
	for a in ["a", "b", "c"]:
		r.run_async("xprop", PackedStringArray([a]))
	r.shutdown()   # drains the queue, then joins the thread
	eq(r.seen.map(func(s): return s[0]), ["a", "b", "c"], "all three ran, in the order queued")
	ok(r.seen.all(func(s): return s[1] != OS.get_main_thread_id()), "none ran on the main thread")
	eq(r.pending(), 0, "queue empty")
	r.run_async("xprop", PackedStringArray(["late"]))
	eq(r.seen.size(), 3, "nothing queued after shutdown")
	r.shutdown()


func test_async_reads_wait_for_the_worker() -> void:
	var m := _gamescope()
	m[1].root[GamescopeScript.ATOM_FOCUSABLE_APPS] = [769, 620]
	m[1].root[GamescopeScript.ATOM_FOCUSED_APP] = [620]
	var got := {}
	m[0].focusable_apps_async(func(v): got["apps"] = v)
	m[0].focused_app_async(func(v): got["focused"] = v)
	ok(got.is_empty(), "no answer before the worker runs")
	eq(m[1].sync_calls, 0, "nothing ran on the calling thread")
	m[1].flush()
	eq(got.get("apps"), [769, 620], "focusable list")
	eq(got.get("focused"), 620, "focused app")


func test_async_writes_set_then_read_back_in_order() -> void:
	var m := _gamescope()
	var res := []
	m[0].set_fps_limit_async(40, func(ok_): res.append(ok_))
	eq(m[1].jobs.size(), 2, "set and read-back queued")
	m[1].flush()
	eq(res, [true], "confirmed after read-back")
	eq(m[1].root[GamescopeScript.ATOM_FPS_LIMIT], [40], "atom set")
	m[0].set_fps_limit_async(-1, func(ok_): res.append(ok_))
	eq(res, [true, false], "bad value refused at once")
	m[0].focus_app_async(620)
	m[0].window_id = 0x400001
	m[0].set_overlay(true)
	m[1].flush()
	eq(m[1].root[GamescopeScript.ATOM_BASELAYER_APPID], [GamescopeScript.EXTRA_UNKNOWN_GAME_ID, 620, 769], "focus queued")
	eq(m[1].root[GamescopeScript.ATOM_STEAM_OVERLAY], [1], "overlay queued")
	eq(m[1].sync_calls, 0, "no synchronous xprop for any of it")


func test_session_polls_without_blocking() -> void:
	var m := _gamescope()
	var s = GameSession.new()
	s.setup(m[0], null, FakeLauncher.new())
	s.begin({"key": "steam:620"}, {"ok": true, "app_id": 620, "pid": 0})
	m[1].flush()   # the frame limit write
	eq(m[1].root.get(GamescopeScript.ATOM_FPS_LIMIT), [40], "game's frame limit applied via the worker")
	m[1].root[GamescopeScript.ATOM_FOCUSABLE_APPS] = [769, 620]
	s.poll_focus()
	s.poll_focus()   # the first read is still out: skipped
	eq(m[1].jobs.size(), 1, "one read in flight at a time")
	eq(s.phase, "waiting", "nothing decided before the answer")
	m[1].flush()
	eq(s.phase, "running", "window seen once the read came back")
	ok(s.focused, "focused")
	m[1].flush()
	eq(m[1].root[GamescopeScript.ATOM_BASELAYER_APPID], [GamescopeScript.EXTRA_UNKNOWN_GAME_ID, 620, 769], "game brought to front")
	# The game closes: two empty reads in a row end it.
	m[1].root[GamescopeScript.ATOM_FOCUSABLE_APPS] = [769]
	s.poll_exit()
	m[1].flush()
	eq(s.phase, "running", "one miss isn't enough")
	s.poll_exit()
	m[1].flush()
	eq(s.phase, "idle", "ended")
	eq(m[1].root[GamescopeScript.ATOM_BASELAYER_APPID], [GamescopeScript.EXTRA_UNKNOWN_GAME_ID, 769], "home in front")
	eq(m[1].sync_calls, 0, "never waited on xprop")
	s.free()


func test_late_answer_is_ignored_after_session_ends() -> void:
	var m := _gamescope()
	var s = GameSession.new()
	s.setup(m[0], null, FakeLauncher.new())
	s.begin({"key": "steam:620"}, {"ok": true, "app_id": 620, "pid": 0})
	m[1].root[GamescopeScript.ATOM_FOCUSABLE_APPS] = [769, 620]
	s.poll_focus()
	s.stop()
	m[1].flush()
	eq(s.phase, "idle", "stale read didn't restart the session")
	ok(not s.focused, "not focused")
	s.free()
