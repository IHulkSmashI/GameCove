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
const UserData := preload("res://scripts/installer/user_data.gd")
const RootKeyboard := preload("res://scripts/installer/root_keyboard.gd")

## How long uninstall waits for Steam to close before editing its launch options.
const STEAM_STOP_WAIT_S := 30
## Tests: "/proc" except in fixtures.
var proc_root := "/proc"
## The app's own data folder (user://). Tests point it at a temp folder.
var user_dir := OS.get_user_data_dir()

signal task_started(index: int, task: Dictionary)
signal task_line(index: int, line: String)
## message: "" | game_running | no_password | the command's last output line
signal task_finished(index: int, ok: bool, message: String)
signal finished(action: String, ok: bool, message: String)
signal undone(ok: bool)
## A small job on its own (Heroic from Flathub): its lines, then its end.
signal job_line(id: String, line: String)
signal job_finished(id: String, ok: bool, message: String)
## A single fix tried again from the done page (retry_fix).
signal fix_retried(fix: String, ok: bool, message: String)

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
## Fixes whose install failed this run: [{"fix", "message"}]. The install went on without them; the done page
## lists each with its own retry (retry_fix).
var failed_fixes: Array = []
## The app binary desktop entries point to before the package is live.
var exe_path := OS.get_executable_path()
## The session the password dialog shows in (tests set them; the keyboard switch is KDE Plasma on Wayland only).
var desktop := OS.get_environment("XDG_CURRENT_DESKTOP")
var session_type := OS.get_environment("XDG_SESSION_TYPE")
## Root steps of this run that already ran in the one batch: task index -> {"code", "last", "pending", "retried"}.
var _batch := {}
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
	failed_fixes = []
	_batch.clear()
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
	for k in range(from, tasks.size()):
		_batch.erase(k)
	_queue("run", _run_all.bind(from))
	return true


## Runs `cmds` ([[program, args...], ...]) in order as the user, one after another, on the worker thread
## (Install Heroic on the stores step). job_line for every output line, job_finished at the end. False while
## another run is going or a game is.
func start_job(id: String, cmds: Array) -> bool:
	if running:
		return false
	running = true
	log_line("---- job %s" % id)
	_queue("job", func():
		var ok := true
		var last := ""
		for c in cmds:
			log_line("$ " + " ".join(PackedStringArray((c as Array).map(func(a): return str(a)))))
			var code: int = runner.stream(str(c[0]), PackedStringArray((c as Array).slice(1)), func(line: String):
				var l := line.strip_edges()
				if l == "":
					return
				last = l
				log_line("  " + l)
				_main(func(): job_line.emit(id, l)))
			log_line("  exit %d" % code)
			if code != 0:
				ok = false
				break
		log_line("job %s: %s" % [id, "ok" if ok else "failed"])
		_main(func():
			running = false
			job_finished.emit(id, ok, "" if ok else (last if last != "" else "failed"))))
	return true


## Tries one failed fix again, on its own (the rest of the install is done). Result: fix_retried.
func retry_fix(fix: String) -> bool:
	if running:
		return false
	var i := -1
	for k in tasks.size():
		if tasks[k]["id"] == "fix_install" and tasks[k]["fix"] == fix:
			i = k
	if i < 0 or not failed_fixes.any(func(x): return x["fix"] == fix):
		return false
	running = true
	log_line("---- retry fix %s" % fix)
	_batch.erase(i)
	_queue("run", func():
		results[i] = ""
		var ok := _run_task(i)
		var good: bool = results[i] in ["ok", "pending"]
		if good:
			failed_fixes = failed_fixes.filter(func(x): return x["fix"] != fix)
			_write_state()
		var msg := "" if good else last_message_for(i)
		_main(func():
			running = false
			fix_retried.emit(fix, good, msg))
		return ok)
	return true


func last_message_for(i: int) -> String:
	for x in failed_fixes:
		if x["fix"] == tasks[i]["fix"]:
			return str(x["message"])
	return ""


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
		var r: Array
		if bool(t["privileged"]):
			# every queued root step of the run went in one pkexec (one password): this step's own result
			r = _batch_result(i)
			if bool(_batch.get(i, {}).get("pending", false)):
				results[i] = "pending"
				if t["id"] == "fix_install":
					deferred_fixes.append(t["fix"])
				log_line("%s: waits for the reboot" % _name(t))
				_main(func(): task_finished.emit(i, true, "pending"))
				return true
		else:
			r = _command(i, t["cmd"])
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
	if not ok and t["id"] == "fix_install":
		failed_fixes = failed_fixes.filter(func(x): return x["fix"] != t["fix"])
		failed_fixes.append({"fix": t["fix"], "message": msg})
	results[i] = "ok" if ok else ("skipped" if bool(t["optional"]) else "failed")
	log_line("%s: %s%s" % [_name(t), "ok" if ok else "failed", "" if msg == "" else " (" + msg + ")"])
	_main(func(): task_finished.emit(i, ok, msg))
	if not ok and not bool(t["optional"]):
		last_message = msg
		return false
	return true


## [exit code, last line] of root step i. The first root step of a run (or of a retry) runs the whole
## queue of root steps that follow it without a step in between that isn't one (those wait for the package
## or for each other): one pkexec, one password.
func _batch_result(i: int) -> Array:
	if not _batch.has(i):
		var items: Array = []
		for k in range(i, tasks.size()):
			var t: Dictionary = tasks[k]
			if t["kind"] != "cmd" or not bool(t["privileged"]):
				break
			if k > i and results[k] in ["ok", "pending"]:
				continue
			items.append({"i": k, "cmd": t["cmd"], "fallback": t["fallback"], "optional": bool(t["optional"]),
				"needs_live": bool(t["needs_live"])})
		_batch.merge(_run_batch(items), true)
	var b: Dictionary = _batch.get(i, {"code": 1, "last": "not run", "pending": false, "retried": false})
	if bool(b.get("retried", false)):
		log_line("%s: trying again without applying live" % _name(tasks[i]))
	return [int(b["code"]), str(b["last"])]


## Runs `items` (Commands.batch_script) as ONE pkexec and reads every step's result from its markers.
## Returns index -> {"code", "last", "pending", "retried"}. Without markers (the dialog was dismissed, pkexec
## failed): the exit code is the first step's, and that is the answer for all of them.
func _run_batch(items: Array) -> Dictionary:
	var out := {}
	if items.is_empty():
		return out
	var script := Commands.batch_script(items, [paths.fix_helper(), paths.installed_binary()])
	var cmd := Commands.batch_command(script)
	var ids: Array = items.map(func(x): return _name(tasks[int(x["i"])]) if x["i"] is int and int(x["i"]) < tasks.size() else str(x["i"]))
	log_line("$ pkexec sh -c <one root script for: %s>" % ", ".join(PackedStringArray(ids)))
	var kb: Dictionary = RootKeyboard.prepare(runner, desktop, session_type)
	if bool(kb["on"]):
		log_line("on-screen keyboard for the password dialog: %s" % kb["file"].get_file())
	var cur := [-1]
	var any := [false]
	var code: int = runner.stream(str(cmd[0]), PackedStringArray(cmd.slice(1)), func(line: String):
		var l := line.strip_edges()
		if l == "":
			return
		if l.begins_with(Commands.MARK):
			any[0] = true
			var p := l.trim_prefix(Commands.MARK).split(" ")
			var k := int(p[1]) if p.size() > 1 else -1
			match p[0]:
				"start":
					cur[0] = k
					out[k] = {"code": 1, "last": "", "pending": false, "retried": false}
				"retry":
					if out.has(k):
						out[k]["retried"] = true
						out[k]["last"] = ""
				"pending":
					out[k] = {"code": 0, "last": "pending", "pending": true, "retried": false}
				"end":
					if out.has(k):
						out[k]["code"] = int(p[2]) if p.size() > 2 else 1
			return
		log_line("  " + l)
		if out.has(cur[0]):
			out[cur[0]]["last"] = l
		var kk: int = cur[0]
		_main(func(): task_line.emit(kk, l)))
	RootKeyboard.restore(runner, kb)
	log_line("  exit %d" % code)
	if not any[0]:
		# no step ever started: the password prompt was dismissed or pkexec itself failed. Every step gets
		# that code, so nothing asks again; a fake/plain runner that answers 0 means every step went fine.
		for it in items:
			out[int(it["i"])] = {"code": code, "last": "", "pending": false, "retried": false}
		if code != 0:
			var why := _why(code, "")
			for k in out:
				out[k]["last"] = why
	return out


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
			# Only GameCove's own folders: the app's user:// and ~/.local/share/gamecove (but its log).
			if user_dir.ends_with("/GameCove") or user_dir.ends_with("/gamecove"):
				# final review, high 9: Steam gets its own art back before the copies of it go, and save
				# backups stay unless the user said to delete them (user_data.gd)
				var art: Dictionary = UserData.restore_steam_art(user_dir, UserData.steam_roots(paths.home))
				log_line("Steam art: %d original(s) put back, %d left in the backup" % [art["restored"], art["left"]])
				var keep: Array = []
				if int(art["left"]) > 0:
					keep.append(UserData.ART_BACKUPS)
				if not bool(choices.get("remove_save_backups", false)):
					keep.append(UserData.SAVE_BACKUPS)
				var kept: Array = UserData.remove_except(user_dir, user_dir.get_base_dir(), keep)
				if not kept.is_empty():
					log_line("kept in %s: %s" % [user_dir, ", ".join(PackedStringArray(kept))])
			UserFiles.remove_tree(paths.installer_dir(), paths.data_dir())
			UserFiles.remove_settings_files(paths)
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
		# every root undo in one pkexec (one password), newest first; the rest one by one
		var undo_items: Array = []
		for i in range(tasks.size() - 1, -1, -1):
			var u0: Variant = tasks[i]["undo"]
			if results[i] == "ok" and u0 is Array and not (u0 as Array).is_empty() and (u0 as Array)[0] == Commands.PKEXEC:
				undo_items.append({"i": i, "cmd": u0, "fallback": [], "optional": true, "needs_live": false})
		var undone_root: Dictionary = _run_batch(undo_items)
		for i in range(tasks.size() - 1, -1, -1):
			if results[i] != "ok":
				continue
			var t: Dictionary = tasks[i]
			var u: Variant = t["undo"]
			var ok := true
			if undone_root.has(i):
				ok = int(undone_root[i]["code"]) == 0
				if ok and t["id"] == "fix_install":
					installed_fixes.erase(t["fix"])
			elif u is Array and not (u as Array).is_empty():
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
