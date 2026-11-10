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
##
## Stop groups: a long run (a download, an unpack, a Bluetooth scan, a cloud-save
## tool, an OS update) passes a `group`. Its pid is kept while it runs, and
## stop_group(group) at app exit ends it (SIGTERM, then SIGKILL after a short
## grace), so the thread waiting on it returns and can be joined at once instead
## of holding the app up for minutes. Once a group is stopped, a new run in it
## returns {"code": -1, "out": "stopped"} without starting. NEVER_STOP programs
## (firmware flashes, pkexec, systemctl) still run and are never signalled.

const _MERGE := "exec 2>&1; exec \"$0\" \"$@\""
const _QUIET := "exec 2>/dev/null; exec \"$0\" \"$@\""
const _CHUNK := 65536
## Programs never signalled by stop_group: a firmware flash must finish, pkexec
## runs as root (we can't), systemctl is quick and a reboot or suspend must go.
const NEVER_STOP: Array[String] = ["fwupdmgr", "fwupdtool", "pkexec", "systemctl"]
## "*": every group.
const ALL := "*"

static var _lock := Mutex.new()
static var _live := {}        # pid -> group, for runs with a group
static var _stopped := {}     # group -> true ("*" = all)


## Runs `program args` and waits for it.
## {"code": exit code (127 when the program isn't found, -1 when it can't
##  start at all), "out": stdout as text (with stderr folded in if merge_stderr)}.
## `group`: see "Stop groups" above ("" = never stopped).
static func run(program: String, args: PackedStringArray, merge_stderr := true, group := "") -> Dictionary:
	if program == "":
		return {"code": -1, "out": ""}
	if group != "" and stopped(group) and not program.get_file() in NEVER_STOP:
		return {"code": -1, "out": "stopped"}
	var argv := PackedStringArray(["-c", _MERGE if merge_stderr else _QUIET, program])
	argv.append_array(args)
	var p: Dictionary = OS.execute_with_pipe("/bin/sh", argv, true)
	if p.is_empty() or not p.has("pid"):
		return {"code": -1, "out": ""}
	var tracked := track(int(p["pid"]), program, group)
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
	if tracked:
		untrack(pid)
	return {"code": OS.get_process_exit_code(pid), "out": bytes.get_string_from_utf8()}


## True once stop_group(group) (or stop_group("*")) was called.
static func stopped(group: String) -> bool:
	_lock.lock()
	var s := _stopped.has(group) or _stopped.has(ALL)
	_lock.unlock()
	return s


## Keeps `pid` (just started) under `group` until untrack(). A group stopped
## meanwhile ends it right away. False when nothing is kept (no group, or a
## program that is never stopped).
static func track(pid: int, program: String, group: String) -> bool:
	if group == "" or pid <= 0 or program.get_file() in NEVER_STOP:
		return false
	_lock.lock()
	_live[pid] = group
	var late := _stopped.has(group) or _stopped.has(ALL)
	_lock.unlock()
	if late:
		_term([pid])
	return true


static func untrack(pid: int) -> void:
	_lock.lock()
	_live.erase(pid)
	_lock.unlock()


## Pids running in `group` now ("*" = every group).
static func live(group: String) -> Array:
	_lock.lock()
	var out: Array = []
	for pid in _live:
		if group == ALL or _live[pid] == group:
			out.append(pid)
	_lock.unlock()
	return out


## App exit: ends every run in `group` ("*" = all) and refuses new ones. SIGTERM
## first (timeout forwards it, curl and tar clean up), SIGKILL for what is still
## there after `grace_ms`. Returns once the group's runs have ended or the grace
## is up; main thread at exit only.
static func stop_group(group: String, grace_ms := 1500) -> void:
	_lock.lock()
	_stopped[group] = true
	_lock.unlock()
	var pids := live(group)
	if pids.is_empty():
		return
	_term(pids)
	var waited := 0
	while waited < grace_ms and not live(group).is_empty():
		OS.delay_msec(10)
		waited += 10
	for pid in live(group):
		OS.kill(int(pid))


## Tests: lets a stopped group run again.
static func clear_stopped(group: String) -> void:
	_lock.lock()
	_stopped.erase(group)
	_lock.unlock()


static func _term(pids: Array) -> void:
	var argv := PackedStringArray(["-TERM", "--"])
	for pid in pids:
		argv.append(str(pid))
	var r := run("kill", argv, false)
	if int(r.get("code", -1)) == 127:   # no kill(1): straight to SIGKILL
		for pid in pids:
			OS.kill(int(pid))
