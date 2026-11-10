extends RefCounted
## The long-lived owner of slow jobs that Settings cards start: a GE-Proton
## download and unpack (minutes), a Bluetooth scan or pairing (up to about 50 s).
##
## A card only subscribes. Pages are dropped and built again at any time (a
## theme change rebuilds every Settings page, a quick-menu tab switch frees its
## page), and the job carries on here: it never waits for a card, and no card
## ever waits for it. The result goes to whichever cards of that channel exist
## when it's done, looked up by instance id on the main thread (a freed card is
## skipped). With no card there, the result waits for the next card to subscribe
## (so "GE-Proton10-26 installed" still shows when the page comes back).
##
## Channels are independent ("ge_proton", "bluetooth"); one job per channel at a
## time. memo(channel) keeps what a card shows across rebuilds (the release a
## check found, the last Bluetooth read).
##
## Only real app exit joins: main.gd calls shutdown() from _exit_tree. It first
## ends the jobs' programs (ExecSafe.stop_group: curl, tar, sha512sum,
## bluetoothctl, busctl), then waits for the threads, which then return at once.
##
## shared() is the app's one instance; tests make their own with new().

const ExecSafe := preload("res://scripts/system/exec_safe.gd")
const Proc := preload("res://scripts/system/proc.gd")

## The stop group of the runners these jobs use (runner()).
const GROUP := "card_jobs"

static var _shared: RefCounted

var group := GROUP
## Tests: run jobs on the worker even for a card outside the tree.
var force_threads := false
var _busy := {}       # channel -> job name ("" / missing = idle)
var _memo := {}       # channel -> Dictionary
var _subs := {}       # channel -> {instance id: true}
var _waiting := {}    # channel -> [method, args] with nobody to take it yet
var _tasks: Array[int] = []
var _done: Array = []   # [channel, method, args] handed back by workers
var _lock := Mutex.new()
var _closed := false


static func shared() -> RefCounted:
	if _shared == null:
		_shared = load("res://scripts/system/card_jobs.gd").new()
	return _shared


## main.gd at real app exit (no-op if nothing was ever started).
static func shutdown_shared() -> void:
	if _shared != null:
		_shared.shutdown()


## A runner whose programs end at shutdown().
func runner() -> RefCounted:
	return Proc.new(group)


func busy(channel: String) -> String:
	return str(_busy.get(channel, ""))


## What cards of `channel` keep across rebuilds (a live Dictionary).
func memo(channel: String) -> Dictionary:
	if not _memo.has(channel):
		_memo[channel] = {}
	return _memo[channel]


## `obj` gets the results of `channel` (the method a job names, on the main
## thread). A result that found nobody earlier comes on the next frame.
func subscribe(channel: String, obj: Object) -> void:
	if not _subs.has(channel):
		_subs[channel] = {}
	_subs[channel][obj.get_instance_id()] = true
	if _waiting.has(channel):
		call_deferred("_flush_waiting", channel)


func unsubscribe(channel: String, obj: Object) -> void:
	if _subs.has(channel):
		_subs[channel].erase(obj.get_instance_id())


## Runs `fn` for `channel` and hands its result (then `extra`) to `method` on
## every subscriber. threaded = false (tests, a card outside the tree) runs it
## at once. False when the channel is busy or the app is closing.
func start(channel: String, job_name: String, fn: Callable, method: String, extra: Array = [], threaded := true) -> bool:
	if _closed or busy(channel) != "":
		return false
	_busy[channel] = job_name
	if not threaded:
		_finish(channel, method, [fn.call()] + extra)
		return true
	_reap()
	_tasks.append(WorkerThreadPool.add_task(func():
		var res: Variant = fn.call()
		_lock.lock()
		_done.append([channel, method, [res] + extra])
		_lock.unlock()
		call_deferred("_drain"),
		false, "GameCove %s" % channel))
	return true


## A one-off for one object, no channel (a page's scan): `fn` on the worker,
## then `method(result, extra...)` on `obj` on the main thread if it still
## exists (looked up by instance id). Nothing waits for it but app exit.
## threaded = false runs it at once.
func run_for(obj: Object, fn: Callable, method: String, extra: Array = [], threaded := true) -> void:
	if _closed:
		return
	if not threaded:
		obj.callv(method, [fn.call()] + extra)
		return
	_reap()
	var id := obj.get_instance_id()
	_tasks.append(WorkerThreadPool.add_task(func():
		var res: Variant = fn.call()
		_lock.lock()
		_done.append([id, method, [res] + extra])
		_lock.unlock()
		call_deferred("_drain"),
		false, "GameCove job"))


## From any thread: `method(args...)` on the object with instance id `id`, on
## the main thread (at once when called there), if it still exists then. For
## workers that aren't ours (the Controls worker): they never touch a Node.
func hand_back(id: int, method: String, args: Array) -> void:
	if OS.get_thread_caller_id() == OS.get_main_thread_id():
		_to_instance(id, method, args)
		return
	_lock.lock()
	_done.append([id, method, args])
	_lock.unlock()
	call_deferred("_drain")


## Main thread: hands every finished job's result over.
func _drain() -> void:
	_reap()
	_lock.lock()
	var list := _done.duplicate()
	_done.clear()
	_lock.unlock()
	for d in list:
		if d[0] is int:
			_to_instance(d[0], d[1], d[2])
		else:
			_finish(d[0], d[1], d[2])


func _to_instance(id: int, method: String, args: Array) -> void:
	if _closed:
		return
	var o: Object = instance_from_id(id)
	if o == null or (o is Node and (o as Node).is_queued_for_deletion()):
		return
	o.callv(method, args)


func _finish(channel: String, method: String, args: Array) -> void:
	_busy.erase(channel)
	if _closed:
		return
	if not _deliver(channel, method, args):
		_waiting[channel] = [method, args]


## True when at least one live subscriber took it.
func _deliver(channel: String, method: String, args: Array) -> bool:
	var took := false
	var subs: Dictionary = _subs.get(channel, {})
	for id in subs.keys():
		var o: Object = instance_from_id(id)
		if o == null or (o is Node and (o as Node).is_queued_for_deletion()):
			subs.erase(id)
			continue
		if o.has_method(method):
			o.callv(method, args)
			took = true
	return took


func _flush_waiting(channel: String) -> void:
	if not _waiting.has(channel) or busy(channel) != "":
		return
	var w: Array = _waiting[channel]
	if _deliver(channel, w[0], w[1]):
		_waiting.erase(channel)


## Frees finished tasks (wait returns at once for those).
func _reap() -> void:
	for t in _tasks.duplicate():
		if WorkerThreadPool.is_task_completed(t):
			WorkerThreadPool.wait_for_task_completion(t)
			_tasks.erase(t)


## Tests: waits for every job started so far, then hands the results over.
func wait_idle() -> void:
	for t in _tasks.duplicate():
		WorkerThreadPool.wait_for_task_completion(t)
	_tasks.clear()
	_drain()


## Real app exit only: ends the jobs' programs, then waits for their threads
## (each returns as soon as its program is gone). Nothing is delivered after.
func shutdown(grace_ms := 1500) -> void:
	_closed = true
	ExecSafe.stop_group(group, grace_ms)
	for t in _tasks:
		WorkerThreadPool.wait_for_task_completion(t)
	_tasks.clear()
	_subs.clear()
	_waiting.clear()
