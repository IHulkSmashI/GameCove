extends RefCounted
## The one place GameCove waits on a program and reads what it printed.
##
## Godot 4.7's OS.execute() with an output array builds a shell command line
## and loses double quotes: ["{\"a\":\"b c\"}"] arrives as two words, {a:b and
## c}. Every JSON argument (busctl calls to InputPlumber, helper options) broke
## on real hardware. OS.execute_with_pipe() passes argv through untouched, so
## this builds on it.
##
## stderr is redirected inside a tiny `sh -c` wrapper (folded into stdout, or
## sent to /dev/null) so only one pipe is ever read and the child can't block
## on a full stderr pipe. The wrapper redirects its own stderr first, so sh's
## "not found" line lands in the output just as it used to.
##
## Blocking: call from a worker thread, never the main thread.

const _MERGE := "exec 2>&1; exec \"$0\" \"$@\""
const _QUIET := "exec 2>/dev/null; exec \"$0\" \"$@\""
const _CHUNK := 65536


## Runs `program args` and waits for it.
## {"code": exit code (127 when the program isn't found, -1 when it can't
##  start at all), "out": stdout as text (with stderr folded in if merge_stderr)}.
static func run(program: String, args: PackedStringArray, merge_stderr := true) -> Dictionary:
	if program == "":
		return {"code": -1, "out": ""}
	var argv := PackedStringArray(["-c", _MERGE if merge_stderr else _QUIET, program])
	argv.append_array(args)
	var p: Dictionary = OS.execute_with_pipe("/bin/sh", argv, true)
	if p.is_empty() or not p.has("pid"):
		return {"code": -1, "out": ""}
	var stdio: FileAccess = p.get("stdio")
	var stderr: FileAccess = p.get("stderr")
	var bytes := PackedByteArray()
	if stdio != null:
		while true:
			var chunk := stdio.get_buffer(_CHUNK)
			if chunk.is_empty():
				break
			bytes.append_array(chunk)
		stdio.close()
	if stderr != null:
		stderr.close()
	var pid: int = p["pid"]
	while OS.is_process_running(pid):
		OS.delay_msec(1)
	return {"code": OS.get_process_exit_code(pid), "out": bytes.get_string_from_utf8()}
