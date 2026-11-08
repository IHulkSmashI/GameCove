extends RefCounted
## Stands in for scripts/library/manage/job_runner.gd in tests: records every
## command and lets the test feed output lines and exit codes synchronously.
## Never runs anything.

signal line(handle: int, text: String)
signal exited(handle: int, code: int)

## [{"handle", "cmd": Array, "env": Dictionary}] in start order.
var started: Array = []
var stopped: Array = []
var _next := 0


func start(cmd: Array, env := {}) -> int:
	_next += 1
	started.append({"handle": _next, "cmd": cmd.duplicate(), "env": env.duplicate()})
	return _next


func stop(handle: int) -> void:
	stopped.append(handle)


func feed(handle: int, text: String) -> void:
	line.emit(handle, text)


## Feeds every line of a fixture log (split on \n and \r like the real runner).
func feed_file(handle: int, path: String) -> void:
	for l in FileAccess.get_file_as_string(path).replace("\r", "\n").split("\n", false):
		line.emit(handle, l)


func finish(handle: int, code := 0) -> void:
	exited.emit(handle, code)


func last() -> Dictionary:
	return started.back() if not started.is_empty() else {}


## Program and arguments of the last command, joined by spaces.
func last_cmd() -> String:
	return " ".join(PackedStringArray(last().get("cmd", [])))
