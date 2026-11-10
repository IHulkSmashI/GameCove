extends RefCounted
## Runs an outside command and returns its exit code and output. The Gamescope
## service only talks to the system through this, so tests can swap in a fake
## runner with canned output and nothing real is touched.
##
## run() blocks the calling thread until the program exits. run_async() hands
## the command to one worker thread instead and calls back on the main thread,
## so the UI never waits on xprop. Jobs run one at a time in the order queued
## (gamescope atoms are set and read back, so order matters). The worker thread
## starts on the first async job and stops in shutdown().

const ExecSafe := preload("res://scripts/system/exec_safe.gd")

var _thread: Thread
var _mutex := Mutex.new()
var _sem := Semaphore.new()
var _queue: Array = []
var _quit := false


## Returns {"exit": int, "output": String} (stdout and stderr together).
## exit is 127 if the program is missing, -1 if it can't start at all.
func run(program: String, args: PackedStringArray) -> Dictionary:
	var r := ExecSafe.run(program, args, true)
	return {"exit": r["code"], "output": r["out"]}


## Runs the command on the worker thread. `done` (optional) gets run()'s result
## on the main thread, deferred to the next idle step.
func run_async(program: String, args: PackedStringArray, done := Callable()) -> void:
	_mutex.lock()
	if _quit:
		_mutex.unlock()
		return
	_queue.append([program, args, done])
	if _thread == null:
		_thread = Thread.new()
		_thread.start(_work)
	_mutex.unlock()
	_sem.post()


## A program that keeps running and prints a line per event (`xprop -spy`): each line
## reaches on_line(line) on the main thread, on_exit() when it ends. Its own reader
## thread blocks on the pipe, so nothing polls. Returns the Watch (stop() it when done),
## or null when it can't start.
func spawn_watch(program: String, args: PackedStringArray, on_line: Callable, on_exit := Callable()) -> RefCounted:
	var w := Watch.new()
	return w if w.start(program, args, on_line, on_exit) else null


class Watch extends RefCounted:
	var pid := 0
	var _pipe: FileAccess
	var _err: FileAccess
	var _thread: Thread

	func start(program: String, args: PackedStringArray, on_line: Callable, on_exit: Callable) -> bool:
		var r: Dictionary = OS.execute_with_pipe(program, args, true)
		if r.is_empty() or int(r.get("pid", 0)) <= 0:
			return false
		pid = int(r["pid"])
		_pipe = r.get("stdio")
		_err = r.get("stderr")
		_thread = Thread.new()
		_thread.start(_read.bind(_pipe, on_line, on_exit))
		return true

	func alive() -> bool:
		if pid > 0 and not OS.is_process_running(pid):
			pid = 0   # it ended and that check reaped it: never ask about this pid again
		return pid > 0

	## Ends the program and its reader (and reaps it). Safe to call twice.
	func stop() -> void:
		if pid > 0 and OS.is_process_running(pid):
			OS.kill(pid)   # SIGKILL, then Godot waits for it: no zombie
		if _thread != null:
			_thread.wait_to_finish()
			_thread = null
		pid = 0
		_pipe = null
		_err = null

	static func _read(pipe: FileAccess, on_line: Callable, on_exit: Callable) -> void:
		while pipe != null and pipe.is_open():
			var line := pipe.get_line()
			if line == "" and (pipe.eof_reached() or pipe.get_error() != OK):
				break
			if on_line.is_valid():
				on_line.call_deferred(line)
		if on_exit.is_valid():
			on_exit.call_deferred()


## Jobs queued and not finished yet.
func pending() -> int:
	_mutex.lock()
	var n := _queue.size()
	_mutex.unlock()
	return n


## Finishes the queued jobs, then stops the worker thread. Safe to call twice.
func shutdown() -> void:
	_mutex.lock()
	_quit = true
	var t := _thread
	_thread = null
	_mutex.unlock()
	if t == null:
		return
	_sem.post()
	t.wait_to_finish()


func _notification(what: int) -> void:
	# Inline: script methods can't be called on self during PREDELETE.
	if what == NOTIFICATION_PREDELETE and _thread != null:
		_mutex.lock()
		_quit = true
		var t := _thread
		_thread = null
		_mutex.unlock()
		_sem.post()
		t.wait_to_finish()


func _work() -> void:
	while true:
		_sem.wait()
		while true:
			_mutex.lock()
			if _queue.is_empty():
				var stop := _quit
				_mutex.unlock()
				if stop:
					return
				break
			var job: Array = _queue[0]
			_mutex.unlock()
			var r := run(job[0], job[1])
			_mutex.lock()
			_queue.pop_front()
			_mutex.unlock()
			var done: Callable = job[2]
			if done.is_valid():
				done.call_deferred(r)
