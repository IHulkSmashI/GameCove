extends Node
## "Record" in the quick menu: one recording at a time with GPU Screen Recorder
## (recorder.gd), started and stopped by the person, never by itself.
##
## Nothing runs until Record is pressed. While it records, one thread waits on
## the recorder's output (a blocking read, woken only when it prints or ends),
## so there's no timer and no polling; the encoding itself runs on the GPU's
## video engine. Stop sends SIGINT, the recorder finishes the file and ends,
## and saved(path) follows. A game ending stops the recording too (main.gd),
## and so does GameCove closing.
##
## The clip's picture for the Clips list is a gamescope screenshot of the game
## (base plane only, so no quick menu in it), taken right after recording
## starts and kept in user://clips/thumbs (clips.gd).
##
## Tests: set `spawner`, `runner`, `thumb_fn` and `threaded = false`.

signal changed
## A clip was written: its path and {"game", "seconds"}.
signal saved(path: String, info: Dictionary)
## Recording didn't start or didn't finish: a recorder.gd error kind
## ("needs_setup", "no_encoder", "missing", "no_screen", "failed", "empty",
## "not_ready") and the recorder's last line.
signal failed(kind: String, detail: String)

const Recorder := preload("res://scripts/system/recorder.gd")
const Clips := preload("res://scripts/system/clips.gd")
const Proc := preload("res://scripts/system/proc.gd")
const SettingsFile := preload("res://scripts/system/settings_file.gd")
const PREFS := "user://settings.cfg"
const SECTION := "recording"
## Lines of the recorder's output kept for the error message.
const KEEP_LINES := 30
## How long Stop waits for the file to be finished before it asks harder (SIGTERM).
const STOP_GRACE_MS := 10000

## Runs the recorder and waits for it: run_blocking(argv, on_pid, on_line) -> exit code.
var spawner: Object = PipeSpawner.new()
## Short commands: kill, kms-server-proxy is-setup, flatpak (proc.gd or a fake).
var runner: RefCounted = Proc.new()
## func(clip_path: String) -> void: saves the clip's picture. Runs off the main thread.
var thumb_fn: Callable = func(clip: String) -> void: Clips.grab_gamescope_thumb(clip)
## {"home", "path_env", "sys_root", "proc_root"}.
var env := {"home": OS.get_environment("HOME"), "path_env": OS.get_environment("PATH"), "sys_root": "", "proc_root": "/proc"}
var prefs_path := PREFS
## False in tests: everything runs inline.
var threaded := true

## "idle" | "starting" | "recording" | "stopping"
var state := "idle"
var path := ""
var game: Dictionary = {}
var pid := 0
## True after a recording failed for want of the one-time screen-capture OK,
## until Settings > Media finds it allowed (set_ready) or a recording starts.
var setup_needed := false
var _started_ms := 0
var _lines: Array = []
var _thread: Thread
## Pool tasks (stop, clip picture) not yet freed; finished ones go as new ones start.
var _tasks: Array[int] = []
## The recorder's pid as the worker knows it (before _on_pid reaches the main thread).
var _child := 0
## App exit: how long the recorder gets to finish the file after SIGINT, then SIGTERM.
var exit_grace_ms := 3000
var _mutex := Mutex.new()


func _init() -> void:
	name = "Recording"


func is_recording() -> bool:
	return state in ["starting", "recording", "stopping"]


## Seconds since recording started (0 when not recording).
func elapsed_s() -> int:
	return int((Time.get_ticks_msec() - _started_ms) / 1000) if state in ["recording", "stopping"] else 0


## "0:42", "12:05", "1:02:03".
static func clock(seconds: int) -> String:
	var s := maxi(0, seconds)
	if s >= 3600:
		return "%d:%02d:%02d" % [s / 3600, (s / 60) % 60, s % 60]
	return "%d:%02d" % [s / 60, s % 60]


# ---- settings -----------------------------------------------------------------------

## {"audio": bool (default on), "fps": 30 | 60 (default 60)}.
func options() -> Dictionary:
	var cfg := SettingsFile.load_cfg(prefs_path)
	var fps := int(cfg.get_value(SECTION, "fps", 60))
	return {"audio": bool(cfg.get_value(SECTION, "audio", true)), "fps": fps if fps in Recorder.FPS_CHOICES else 60}


func set_option(key: String, value: Variant) -> bool:
	if not key in ["audio", "fps"]:
		return false
	return SettingsFile.update_cfg(prefs_path, func(cfg: ConfigFile): cfg.set_value(SECTION, key, value)) == OK


func locate() -> Dictionary:
	return Recorder.locate(env)


## Recorder.locate() found something that can record (file checks only: cheap).
func installed() -> bool:
	return str(locate().get("kind", "")) in ["host", "flatpak"]


## What the quick menu's row should offer: "record", "stop", "busy" or "set_up".
func row_state() -> String:
	if state in ["starting", "stopping"]:
		return "busy"
	if state == "recording":
		return "stop"
	return "record" if installed() and not setup_needed else "set_up"


## Settings > Media read the recorder's status.
func set_ready(ready: bool) -> void:
	setup_needed = not ready


# ---- start / stop ----------------------------------------------------------------------

## Starts recording the screen for `for_game` ({} = no game). False (and
## failed()) when it can't; true when the recorder is starting.
func start(for_game: Dictionary) -> bool:
	if is_recording():
		return false
	var loc := locate()
	if not str(loc.get("kind", "")) in ["host", "flatpak"]:
		failed.emit("not_ready", "")
		return false
	var title := str(for_game.get("title", "")) if not for_game.is_empty() else Recorder.NO_GAME
	path = Recorder.clip_path(str(env.get("home", "")), title, Time.get_datetime_dict_from_system())
	if DirAccess.make_dir_recursive_absolute(path.get_base_dir()) != OK:
		failed.emit("failed", path.get_base_dir())
		path = ""
		return false
	game = for_game
	state = "starting"
	pid = 0
	_started_ms = Time.get_ticks_msec()
	_lines.clear()
	var argv := Recorder.command(loc, Recorder.record_args(path, options()))
	changed.emit()
	if threaded:
		_join()
		_thread = Thread.new()
		_thread.start(_run.bind(argv))
	else:
		_run(argv)
	return true


## Worker: runs the recorder until it ends.
func _run(argv: PackedStringArray) -> void:
	var code: int = spawner.run_blocking(argv, func(p: int):
		_mutex.lock()
		_child = p
		_mutex.unlock()
		_deliver("_on_pid", [p]), func(line: String):
		_mutex.lock()
		_lines.append(line)
		if _lines.size() > KEEP_LINES:
			_lines.pop_front()
		_mutex.unlock())
	_mutex.lock()
	var lines := _lines.duplicate()
	_child = 0
	_mutex.unlock()
	_deliver("_on_exit", [code, lines])


func _deliver(method: String, args: Array) -> void:
	if threaded:
		call_deferred("callv", method, args)
	else:
		callv(method, args)


func _on_pid(p: int) -> void:
	pid = p
	setup_needed = false
	if state == "stopping":
		_send_stop()   # Stop was pressed before the recorder had started
		return
	if state != "starting":
		return
	state = "recording"
	_started_ms = Time.get_ticks_msec()
	changed.emit()
	if thumb_fn.is_valid():
		var clip := path
		var fn := thumb_fn
		if threaded:
			_reap_tasks()
			_tasks.append(WorkerThreadPool.add_task(func(): fn.call(clip), false, "GameCove clip picture"))
		else:
			fn.call(clip)


func _on_exit(code: int, lines: Array) -> void:
	var was := state
	var secs := elapsed_s()
	var clip := path
	var g := game
	state = "idle"
	pid = 0
	path = ""
	game = {}
	_join()
	changed.emit()
	var size := FileAccess.get_size(clip) if clip != "" and FileAccess.file_exists(clip) else 0
	if was == "stopping" and size > 0:
		saved.emit(clip, {"game": str(g.get("title", "")), "seconds": secs})
		return
	if size > 0 and code == 0:
		saved.emit(clip, {"game": str(g.get("title", "")), "seconds": secs})
		return
	# it ended by itself, or wrote nothing: say why, leave no empty file behind
	if clip != "" and FileAccess.file_exists(clip) and size == 0:
		DirAccess.remove_absolute(clip)
		Clips.remove_thumb(clip)
	var kind := Recorder.error_kind(code, lines)
	if was == "stopping" and kind == "failed":
		kind = "empty"
	if kind == "needs_setup":
		setup_needed = true
	failed.emit(kind, Recorder.last_line(lines))


## Stops and saves. The answer comes as saved() or failed().
func stop() -> void:
	if not state in ["starting", "recording"]:
		return
	state = "stopping"
	changed.emit()
	if pid > 0:
		_send_stop()
	# else: the recorder hasn't told us its pid yet; _on_pid stops it when it does


func _send_stop() -> void:
	var root := pid
	var r := runner
	var proc_root := str(env.get("proc_root", "/proc"))
	var job := func():
		var target := Recorder.recorder_pid(root, Recorder.proc_table(proc_root)) if root > 0 else -1
		if target <= 0:
			return
		r.run("kill", PackedStringArray(["-INT", str(target)]))
		if not threaded:
			return
		var waited := 0
		while OS.is_process_running(root) and waited < STOP_GRACE_MS:
			OS.delay_msec(100)
			waited += 100
		if OS.is_process_running(root):
			r.run("kill", PackedStringArray(["-TERM", str(target)]))
	if threaded:
		_reap_tasks()
		_tasks.append(WorkerThreadPool.add_task(job, false, "GameCove stop recording"))
	else:
		job.call()


## Frees finished tasks only (the wait returns at once for those): a stop still
## in its grace never holds the main thread.
func _reap_tasks() -> void:
	for t in _tasks.duplicate():
		if WorkerThreadPool.is_task_completed(t):
			WorkerThreadPool.wait_for_task_completion(t)
			_tasks.erase(t)


func _join() -> void:
	if _thread != null and not _thread.is_alive():
		_thread.wait_to_finish()
		_thread = null


## GameCove is closing (main.gd owns us for the app's whole life, so this is real
## exit): the recorder gets SIGINT to finish the file, SIGTERM after
## exit_grace_ms, SIGKILL a second later; only then is its thread joined, so a
## recorder that hangs never holds the exit up. Works before _on_pid reached us
## too (the worker's own copy of the pid).
func _exit_tree() -> void:
	_mutex.lock()
	var root := _child if _child > 0 else pid
	_mutex.unlock()
	if root > 0 and _thread != null and _thread.is_alive():
		var target := Recorder.recorder_pid(root, Recorder.proc_table(str(env.get("proc_root", "/proc"))))
		if target <= 0:
			target = root
		runner.run("kill", PackedStringArray(["-INT", str(target)]))
		if not _wait_thread(exit_grace_ms):
			runner.run("kill", PackedStringArray(["-TERM", str(target)]))
			if not _wait_thread(1000):
				OS.kill(target)
				if target != root:
					OS.kill(root)
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	for t in _tasks:
		WorkerThreadPool.wait_for_task_completion(t)
	_tasks.clear()


## True once the recorder's thread has ended (within `ms`).
func _wait_thread(ms: int) -> bool:
	var waited := 0
	while _thread != null and _thread.is_alive() and waited < ms:
		OS.delay_msec(20)
		waited += 20
	return _thread == null or not _thread.is_alive()


## Runs a program, hands its pid over as soon as it has one, then its output
## line by line until it ends (stderr folded in by a tiny sh wrapper, so one
## pipe carries everything and nothing blocks on a full stderr pipe).
class PipeSpawner extends RefCounted:
	func run_blocking(argv: PackedStringArray, on_pid: Callable, on_line: Callable) -> int:
		if argv.is_empty():
			return -1
		var sh := PackedStringArray(["-c", "exec \"$0\" \"$@\" 2>&1"])
		sh.append_array(argv)
		var p: Dictionary = OS.execute_with_pipe("/bin/sh", sh, true)
		if p.is_empty() or not p.has("pid"):
			return -1
		var child: int = p["pid"]
		on_pid.call(child)
		var pipe: FileAccess = p["stdio"]
		while true:
			var line := pipe.get_line()
			if pipe.get_error() != OK and line == "":
				break
			on_line.call(line)
		pipe.close()
		var err: FileAccess = p.get("stderr")
		if err != null:
			err.close()
		while OS.is_process_running(child):
			OS.delay_msec(10)
		return OS.get_process_exit_code(child)
