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
