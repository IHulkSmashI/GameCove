extends "res://scripts/system/service.gd"
## Carries out an installer plan: runs the tasks from commands.gd in order on
## the worker thread, logs every step to ~/.local/share/gamecove/installer.log,
## and reports each one as signals on the main thread. Never runs while a game
## does. Each finished task can be undone (undo(), newest first).
##
## Not an autoload: the installer screen makes one. Tests: setup(fake_runner,
## Paths.for_home(tmp), target) and call outside the tree (runs synchronously).

const SettingsFile := preload("res://scripts/system/settings_file.gd")
const Commands := preload("res://scripts/installer/commands.gd")
const UserFiles := preload("res://scripts/installer/user_files.gd")
const Paths := preload("res://scripts/installer/paths.gd")
const LaunchFiles := preload("res://scripts/controls/perf/launch_files.gd")
const SteamConfig := preload("res://scripts/steam/steam_config.gd")
const Proton := preload("res://scripts/launch/proton.gd")

## How long uninstall waits for Steam to close before editing its launch options.
const STEAM_STOP_WAIT_S := 30
## Tests: "/proc" except in fixtures.
var proc_root := "/proc"

signal task_started(index: int, task: Dictionary)
signal task_line(index: int, line: String)
## message: "" | game_running | no_password | the command's last output line
signal task_finished(index: int, ok: bool, message: String)
signal finished(action: String, ok: bool, message: String)
signal undone(ok: bool)

var paths: RefCounted = Paths.new()
var target: Dictionary = {}
var action := ""
var choices: Dictionary = {}
var tasks: Array = []
## Per task: "" waiting | running | ok | failed | skipped (optional, failed) | pending (waits for the reboot) | undone
var results: Array = []
var running := false
var last_message := ""
## Fixes installed (from install-state.json, plus this run).
var installed_fixes: Array = []
## Fixes that wait until the package is live (staged install: after the reboot).
var deferred_fixes: Array = []
## The app binary desktop entries point to before the package is live.
var exe_path := OS.get_executable_path()
var _log_mutex := Mutex.new()
var _clock: Callable = func() -> String: return Time.get_datetime_string_from_system(true) + "Z"


func setup(command_runner: RefCounted, p: RefCounted, t: Dictionary, exe := "") -> void:
	runner = command_runner
	paths = p
	target = t
	if exe != "":
		exe_path = exe


## Starts `act` (install | change | repair | update | uninstall | finish) with the
## plan's choices. False while another run is going.
func start(act: String, plan_choices: Dictionary) -> bool:
	if running:
		return false
	action = act
	choices = plan_choices.duplicate(true)
	tasks = Commands.tasks_for(act, choices, target, paths)
	results = []
	results.resize(tasks.size())
	results.fill("")
	var st: Dictionary = target.get("state", {})
	installed_fixes = (st.get("fixes", []) as Array).duplicate() if st.get("fixes", []) is Array else []
	deferred_fixes = []
	running = true
	last_message = ""
	log_line("---- %s (%s, %s)" % [act, target.get("family", "?"), target.get("method", "?")])
	_queue("run", _run_all)
	return true


## Runs the failed task and everything after it again.
func retry() -> bool:
	if running or tasks.is_empty():
		return false
	var from := results.find("failed")
	if from < 0:
		return false
	running = true
	log_line("---- retry %s from %s" % [action, tasks[from]["id"]])
	_queue("run", _run_all.bind(from))
	return true


func _run_all(from := 0) -> void:
	for i in range(from, tasks.size()):
		if results[i] in ["ok", "pending"]:
			continue
		if not _run_task(i):
			var msg := last_message
			_main(func():
				running = false
				finished.emit(action, false, msg))
			return
	log_line("---- %s finished" % action)
	_main(func():
		running = false
		finished.emit(action, true, ""))


func _run_task(i: int) -> bool:
	var t: Dictionary = tasks[i]
	results[i] = "running"
	_main(func(): task_started.emit(i, t))
	if bool(t["needs_live"]) and not is_live():
		results[i] = "pending"
		if t["id"] == "fix_install":
			deferred_fixes.append(t["fix"])
		log_line("%s: waits for the reboot" % _name(t))
		_main(func(): task_finished.emit(i, true, "pending"))
		return true
	var ok := false
	var msg := ""
	if t["kind"] == "internal":
		var r := _internal(str(t["id"]))
		ok = r[0]
		msg = r[1]
	else:
		var r := _command(i, t["cmd"])
		if r[0] != 0 and not (t["fallback"] as Array).is_empty():
			log_line("%s: trying again without applying live" % _name(t))
			r = _command(i, t["fallback"])
		ok = r[0] == 0
		msg = "" if ok else _why(r[0], r[1])
	if ok:
		match str(t["id"]):
			"fix_install":
				if not t["fix"] in installed_fixes:
					installed_fixes.append(t["fix"])
			"fix_remove":
				installed_fixes.erase(t["fix"])
	results[i] = "ok" if ok else ("skipped" if bool(t["optional"]) else "failed")
	log_line("%s: %s%s" % [_name(t), "ok" if ok else "failed", "" if msg == "" else " (" + msg + ")"])
	_main(func(): task_finished.emit(i, ok, msg))
	if not ok and not bool(t["optional"]):
		last_message = msg
		return false
	return true


## [exit code, last output line]
func _command(i: int, cmd: Array) -> Array:
	log_line("$ " + " ".join(PackedStringArray(cmd.map(func(a): return str(a)))))
	var last := [""]
	var code: int = runner.stream(str(cmd[0]), PackedStringArray(cmd.slice(1)), func(line: String):
		var l := line.strip_edges()
		if l == "":
			return
		last[0] = l
		log_line("  " + l)
		_main(func(): task_line.emit(i, l)))
	log_line("  exit %d" % code)
	return [code, last[0]]


static func _why(code: int, last: String) -> String:
	# pkexec: 126 = the password dialog was dismissed / not authorized, 127 = no agent or failed.
	if code == 126 or code == 127:
		return "no_password"
	return last if last != "" else "exit %d" % code


static func _name(t: Dictionary) -> String:
	return str(t["id"]) + ("" if str(t["fix"]) == "" else " " + str(t["fix"]))


## GameCove is in /usr now (installed and live, not just staged).
func is_live() -> bool:
	return FileAccess.file_exists(paths.fix_helper()) or FileAccess.file_exists(paths.installed_binary())


## [ok, message]
func _internal(id: String) -> Array:
	match id:
		"check_game":
			var r: Dictionary = runner.run(Commands.game_check()[0], PackedStringArray(Commands.game_check().slice(1)))
			if int(r.get("code", 1)) == 0:
				return [false, "game_running"]
			return [true, ""]
		"user_files":
			var wrote := UserFiles.write_all(paths, choices, exe_path)
			log_line("wrote " + ", ".join(PackedStringArray(wrote)))
			return [true, ""]
		"pending":
			var left := deferred_fixes.duplicate()
			var pending := {}
			if action == "finish":
				if not left.is_empty():
					pending["FIXES"] = ",".join(PackedStringArray(left))
			else:
				pending = pending_for(choices, left)
			UserFiles.write_pending(paths, pending, exe_path)
			log_line("pending: " + str(pending))
			return [true, ""]
		"state":
			_write_state()
			return [true, ""]
		"remove_user_files":
			log_line("removed " + ", ".join(PackedStringArray(UserFiles.remove_all(paths))))
			return [true, ""]
		"steam_unwrap":
			return _steam_unwrap()
		"remove_settings":
			var user_dir := OS.get_user_data_dir()
			# Only GameCove's own folders: the app's user:// and ~/.local/share/gamecove (but its log).
			if user_dir.ends_with("/GameCove") or user_dir.ends_with("/gamecove"):
				UserFiles.remove_tree(user_dir, user_dir.get_base_dir())
			UserFiles.remove_tree(paths.installer_dir(), paths.data_dir())
			log_line("removed settings")
			return [true, ""]
		"forget":
			for p in [paths.state_file(), paths.pending_file()]:
				if FileAccess.file_exists(p):
					DirAccess.remove_absolute(p)
			return [true, ""]
	return [false, "unknown task " + id]


## Review S2-1: takes GameCove's launcher out of every Steam game. Steam writes its settings back
## when it exits, so it is closed first (and waited for). If it won't close, nothing is lost: the
## launch options fall through to the game when GameCove's wrapper is gone.
func _steam_unwrap() -> Array:
	var root := Proton.steam_root(paths.home)
	if root == "" or not DirAccess.dir_exists_absolute(root.path_join("userdata")):
		return [true, ""]
	if SteamConfig.is_running(paths.home, proc_root):
		runner.run("steam", PackedStringArray(["-shutdown"]))
		var waited := 0
		while SteamConfig.is_running(paths.home, proc_root) and waited < STEAM_STOP_WAIT_S * 2:
			OS.delay_msec(500)
			waited += 1
	var r: Dictionary = LaunchFiles.unwrap_all(paths.home, root, proc_root)
	if int(r["error"]) == ERR_BUSY:
		log_line("Steam is still running: launch options left (they fall through to the game without GameCove)")
		return [false, "Steam is running"]
	log_line("launch options: GameCove taken out of %d game(s)" % (r["changed"] as Array).size())
	return [int(r["error"]) == OK, "" if int(r["error"]) == OK else error_string(int(r["error"]))]


## The pending-choices file for an install. The default session can only be
## set once the package is live: gamecove-apply-choices does it (now when it's
## live already, else at the first login after the reboot).
static func pending_for(c: Dictionary, fixes_left: Array) -> Dictionary:
	var out := {"STARTUP": str(c.get("startup", "gamecove"))}
	if out["STARTUP"] == "gamecove":
		out["SWITCH_NOW"] = "1"
	if int(c.get("charge_limit", 100)) < 100:
		out["CHARGE_LIMIT"] = str(int(c["charge_limit"]))
	if not fixes_left.is_empty():
		out["FIXES"] = ",".join(PackedStringArray(fixes_left))
	return out


func _write_state() -> void:
	var st: Dictionary = target.get("state", {}).duplicate(true)
	st["method"] = target.get("method", "none")
	st["family"] = target.get("family", "other")
	var rel: Dictionary = target.get("release", {})
	if action in ["install", "repair", "update", "change"] and str(rel.get("version", "")) != "":
		if action != "change" or not st.has("version"):
			st["version"] = rel["version"]
	st["stage"] = "live" if is_live() and action != "update" else "staged"
	if action == "update" and target.get("method", "") == "sysext":
		st["stage"] = "live"
	st["fixes"] = installed_fixes.duplicate()
	st["waiting_fixes"] = deferred_fixes.duplicate()
	var keep := {}
	for k in ["startup", "steam_mode", "steam_control", "fixes", "auto_tdp", "power_profile", "charge_limit",
			"theme", "match_art", "reduce_motion", "xess_driver", "moonlight"]:
		if choices.has(k):
			keep[k] = choices[k]
	if action == "finish":
		keep = st.get("choices", {})
	st["choices"] = keep
	st["updated"] = _clock.call()
	DirAccess.make_dir_recursive_absolute(paths.data_dir())
	SettingsFile.save_json(paths.state_file(), st, "\t")


## Undoes every finished task, newest first (a failed install's way back).
func undo() -> bool:
	if running or tasks.is_empty():
		return false
	running = true
	log_line("---- undo %s" % action)
	_queue("undo", func():
		var all_ok := true
		for i in range(tasks.size() - 1, -1, -1):
			if results[i] != "ok":
				continue
			var t: Dictionary = tasks[i]
			var u: Variant = t["undo"]
			var ok := true
			if u is Array and not (u as Array).is_empty():
				ok = _command(i, u)[0] == 0
				if ok and t["id"] == "fix_install":
					installed_fixes.erase(t["fix"])
			elif u is String and u != "":
				match u:
					"remove_user_files": UserFiles.remove_all(paths)
					"remove_pending": UserFiles.remove_pending(paths)
			results[i] = "undone" if ok else results[i]
			all_ok = all_ok and ok
			log_line("undo %s: %s" % [_name(t), "ok" if ok else "failed"])
		if results.has("undone") and FileAccess.file_exists(paths.state_file()) and target.get("state", {}).is_empty():
			DirAccess.remove_absolute(paths.state_file())
		_main(func():
			running = false
			undone.emit(all_ok)))
	return true


## Restarts the device (refused while a game runs). Result: finished("reboot", ok, msg).
func reboot() -> bool:
	if running:
		return false
	_queue("reboot", func():
		var g := Commands.game_check()
		if int(runner.run(g[0], PackedStringArray(g.slice(1))).get("code", 1)) == 0:
			_main(func(): finished.emit("reboot", false, "game_running"))
			return
		log_line("reboot")
		var r := Commands.reboot()
		var res: Dictionary = runner.run(r[0], PackedStringArray(r.slice(1)))
		var ok := int(res.get("code", 1)) == 0
		_main(func(): finished.emit("reboot", ok, "" if ok else str(res.get("out", "")).strip_edges())))
	return true


## One timestamped line in installer.log (any thread).
func log_line(text: String) -> void:
	_log_mutex.lock()
	DirAccess.make_dir_recursive_absolute(paths.data_dir())
	var path: String = paths.log_file()
	var f := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if f != null:
		f.seek_end()
		f.store_line("%s installer: %s" % [_clock.call(), text])
		f.close()
	_log_mutex.unlock()
