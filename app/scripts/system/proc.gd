extends RefCounted
## Runs programs for the system services (Updates, Storage, Setup, Controller).
## Goes through exec_safe.gd (arguments reach the program byte for byte), so
## tests swap in tests/fixtures/system/fake_runner.gd and nothing real ever runs.
##
## A runner has:
##   run(program, args) -> {"code": int, "out": String}   stdout and stderr together
##   stream(program, args, on_line: Callable) -> int       calls on_line(line) as lines arrive
## Both block: call them from a worker thread, never the main thread.


const ExecSafe := preload("res://scripts/system/exec_safe.gd")

## Stop group (exec_safe.gd): runs in it end when the owner calls
## ExecSafe.stop_group(group) at app exit. "" = never stopped.
var group := ""


func _init(stop_group := "") -> void:
	group = stop_group


func run(program: String, args: PackedStringArray) -> Dictionary:
	return ExecSafe.run(program, args, true, group)


## Reads the program's output line by line while it runs (for progress).
## stderr is folded into stdout by a `sh -c 'exec "$0" "$@" 2>&1'` wrapper, so
## one pipe carries both and nothing can block on a full stderr pipe.
func stream(program: String, args: PackedStringArray, on_line: Callable) -> int:
	if group != "" and ExecSafe.stopped(group) and not program.get_file() in ExecSafe.NEVER_STOP:
		return -1
	var argv := PackedStringArray(["-c", "exec \"$0\" \"$@\" 2>&1", program])
	argv.append_array(args)
	var p: Dictionary = OS.execute_with_pipe("sh", argv, true)
	if p.is_empty():
		return -1
	var pipe: FileAccess = p["stdio"]
	# `exec` in the wrapper: the pid is the program's own
	var tracked := ExecSafe.track(int(p["pid"]), program, group)
	while true:
		var line := pipe.get_line()
		if pipe.get_error() != OK and line == "":
			break
		on_line.call(line)
	var pid: int = p["pid"]
	while OS.is_process_running(pid):
		OS.delay_msec(20)
	if tracked:
		ExecSafe.untrack(pid)
	return OS.get_process_exit_code(pid)
