extends RefCounted
## Runs store tools (legendary, gogdl, nile, mv, rm, steam, xprop) without ever
## blocking the main thread: each process gets a reader thread that splits its
## output on \n and \r (legendary's verify line uses \r) and hands every line,
## then the exit code, back to the main thread with call_deferred.
##
## OS.execute_with_pipe already starts the child as the leader of a new session
## and process group (checked with ps on Godot 4.7.2), so stop() can end the tool
## and its worker processes together (`kill -TERM -- -<pid>`). stderr is merged
## into stdout (the tools log progress to stderr) and PYTHONUNBUFFERED=1 keeps
## Python from holding output back.
##
## Tests use tests/fixtures/library/fake_job_runner.gd, which has the same
## start/stop/signals and never runs anything.

signal line(handle: int, text: String)
signal exited(handle: int, code: int)

var _next := 0
var _jobs := {}   # handle -> {"thread": Thread, "pid": int}
var kill_bin := "kill"


## Starts `cmd` ([program, args...]) with extra environment `env`. Returns a
## handle (> 0), or 0 when the program couldn't start (`exited` still fires with -1).
func start(cmd: Array, env := {}) -> int:
	_next += 1
	var handle: int = _next
	var argv: PackedStringArray = wrap_command(cmd, env)
	var info := OS.execute_with_pipe(argv[0], argv.slice(1), true)
	if info.is_empty():
		_emit_exit.call_deferred(handle, -1)
		return handle
	var t := Thread.new()
	_jobs[handle] = {"thread": t, "pid": int(info["pid"])}
	t.start(_read.bind(handle, info["stdio"], int(info["pid"])))
	return handle


## The full argv: env (PYTHONUNBUFFERED and `env`), then sh to merge stderr.
static func wrap_command(cmd: Array, env: Dictionary) -> PackedStringArray:
	var out := PackedStringArray(["env", "PYTHONUNBUFFERED=1"])
	var keys := env.keys()
	keys.sort()
	for k in keys:
		out.append("%s=%s" % [k, env[k]])
	out.append_array(["sh", "-c", "exec \"$@\" 2>&1", "gamecove-job"])
	for c in cmd:
		out.append(str(c))
	return out


func is_running(handle: int) -> bool:
	return _jobs.has(handle)


## Ends the process group (TERM). `exited` follows once it's gone.
func stop(handle: int) -> void:
	if not _jobs.has(handle):
		return
	var pid: int = _jobs[handle]["pid"]
	if pid > 0:
		OS.create_process(kill_bin, ["-TERM", "--", "-%d" % pid])


## Stops everything and waits for the reader threads (app exit only).
func shutdown() -> void:
	for h in _jobs.keys():
		var pid: int = _jobs[h]["pid"]
		if pid > 0:
			OS.kill(pid)
	for h in _jobs.keys():
		var t: Thread = _jobs[h]["thread"]
		if t.is_started():
			t.wait_to_finish()
	_jobs.clear()


func _read(handle: int, pipe: FileAccess, pid: int) -> void:
	var buf := PackedByteArray()
	while true:
		var b := pipe.get_8()
		if pipe.get_error() != OK:
			break
		if b == 10 or b == 13:
			if not buf.is_empty():
				_emit_line.call_deferred(handle, buf.get_string_from_utf8())
				buf.clear()
		else:
			buf.append(b)
	if not buf.is_empty():
		_emit_line.call_deferred(handle, buf.get_string_from_utf8())
	while OS.is_process_running(pid):
		OS.delay_msec(50)
	_emit_exit.call_deferred(handle, OS.get_process_exit_code(pid))


func _emit_line(handle: int, text: String) -> void:
	line.emit(handle, text)


func _emit_exit(handle: int, code: int) -> void:
	if _jobs.has(handle):
		var t: Thread = _jobs[handle]["thread"]
		t.wait_to_finish()
		_jobs.erase(handle)
	exited.emit(handle, code)
