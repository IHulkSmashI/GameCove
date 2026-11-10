extends Node
## Base for the system services: one worker thread that runs queued jobs in
## order, newest job per name wins (same pattern as scripts/device/power.gd).
## The thread starts on the first job, so a service nobody uses costs nothing.
## Results go back to the main thread with _main(callable).
##
## Outside the scene tree (tests) there is no thread: jobs run at once and
## _main() calls straight through, so tests stay synchronous.

const Proc := preload("res://scripts/system/proc.gd")

## The command runner (proc.gd, or a fake in tests).
var runner: RefCounted = Proc.new()

var _thread: Thread
var _jobs := {}          # name -> Callable
var _order: Array = []
var _mutex := Mutex.new()
var _sem := Semaphore.new()
var _quit := false
var _running := ""       # job name the worker is on, "" when idle


func _exit_tree() -> void:
	if _thread == null:
		return
	_mutex.lock()
	_quit = true
	_mutex.unlock()
	_sem.post()
	_thread.wait_to_finish()
	_thread = null


## True while a job called `job_name` is queued or running.
func job_pending(job_name: String) -> bool:
	_mutex.lock()
	var p := _jobs.has(job_name) or _running == job_name
	_mutex.unlock()
	return p


func _queue(job_name: String, job: Callable) -> void:
	if not is_inside_tree():
		job.call()
		return
	_mutex.lock()
	if _thread == null:
		_thread = Thread.new()
		_thread.start(_worker)
	if not _jobs.has(job_name):
		_order.append(job_name)
	_jobs[job_name] = job
	_mutex.unlock()
	_sem.post()


func _worker() -> void:
	while true:
		_sem.wait()
		_mutex.lock()
		if _order.is_empty():
			_mutex.unlock()
			if _quit:
				return
			continue
		# quitting: queued jobs still run first (review H2)
		var job_name: String = _order.pop_front()
		var job: Callable = _jobs[job_name]
		_jobs.erase(job_name)
		_running = job_name
		_mutex.unlock()
		job.call()
		_mutex.lock()
		_running = ""
		_mutex.unlock()


## Runs `fn` on the main thread (deferred from the worker, direct otherwise).
func _main(fn: Callable) -> void:
	if OS.get_thread_caller_id() == OS.get_main_thread_id():
		fn.call()
	else:
		fn.call_deferred()


## Reads a text file, "" when missing. Works for /proc files (length 0).
static func read_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var lines := PackedStringArray()
	while not f.eof_reached():
		lines.append(f.get_line())
	return "\n".join(lines).strip_edges()
