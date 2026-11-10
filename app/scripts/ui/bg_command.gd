extends Node
## Runs programs off the main thread so the UI never waits on them (pkexec can
## sit on a password prompt for minutes). Results come back on the main thread
## as `finished`. One job per id at a time.
##
## Every program goes through `runner`, so tests swap in a fake and nothing real
## ever runs. A runner has run(program, args) -> {"code": int, "out": String}
## and spawn(program, args) -> pid (or -1). Outside the scene tree (tests) jobs
## run right away and `finished` fires before run() returns.

signal finished(id: String, code: int, output: String)

const ExecSafe := preload("res://scripts/system/exec_safe.gd")
## exec_safe.gd stop group of the real runner.
const GROUP := "bg_command"


class SystemRunner extends RefCounted:
	const ExecSafe := preload("res://scripts/system/exec_safe.gd")

	## Waits for the program; stdout and stderr together, so error lines show up.
	## In the stop group: app exit ends it (pkexec itself is never signalled).
	func run(program: String, args: PackedStringArray) -> Dictionary:
		return ExecSafe.run(program, args, true, GROUP)

	## Starts the program and returns at once.
	func spawn(program: String, args: PackedStringArray) -> int:
		return OS.create_process(program, args)


var runner: Object = SystemRunner.new()
var _tasks := {}   # id -> WorkerThreadPool task id


func busy(id: String) -> bool:
	return _tasks.has(id)


## Starts `program args` in the background. False if job `id` is still running.
func run(id: String, program: String, args: PackedStringArray) -> bool:
	if _tasks.has(id):
		return false
	if not is_inside_tree():
		var r: Dictionary = runner.run(program, args)
		finished.emit(id, int(r.get("code", -1)), str(r.get("out", "")))
		return true
	var rn := runner
	_tasks[id] = WorkerThreadPool.add_task(func():
		var r: Dictionary = rn.run(program, args)
		_done.call_deferred(id, int(r.get("code", -1)), str(r.get("out", ""))),
		false, "GameCove command %s" % id)
	return true


## Starts a program that carries on by itself (no result). True if it started.
func spawn(program: String, args: PackedStringArray) -> bool:
	return int(runner.spawn(program, args)) > 0


func _done(id: String, code: int, output: String) -> void:
	if _tasks.has(id):
		WorkerThreadPool.wait_for_task_completion(_tasks[id])
		_tasks.erase(id)
	finished.emit(id, code, output)


## Real app exit only (the quick menu and the fixes service own us for the app's
## whole life): the programs end first, so the wait is short.
func _exit_tree() -> void:
	if not _tasks.is_empty():
		ExecSafe.stop_group(GROUP)
	for id in _tasks:
		WorkerThreadPool.wait_for_task_completion(_tasks[id])
	_tasks.clear()


## key=value lines (as gamecove-fix status prints them) as a Dictionary.
## Lines without "=" are skipped; later keys win.
static func key_values(text: String) -> Dictionary:
	var out := {}
	for line in text.split("\n", false):
		var i := line.find("=")
		if i > 0:
			out[line.substr(0, i).strip_edges()] = line.substr(i + 1).strip_edges()
	return out


## The last "error: ..." line a helper printed, without the prefix, or "".
static func error_line(text: String) -> String:
	var lines := text.split("\n", false)
	for i in range(lines.size() - 1, -1, -1):
		var l := lines[i].strip_edges()
		for prefix in ["error: ", "gamecove-fix: "]:
			if l.begins_with(prefix):
				return l.substr(prefix.length())
	return ""
