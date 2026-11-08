extends "res://scripts/system/service.gd"
## Updates: the OS image, device firmware (fwupd) and Flatpak apps.
##
## Nothing runs on its own: no timer, no check at start. The UI calls
## check(kind) / check_updates() and apply(kind) / apply_update(); work happens
## on the worker thread and comes back on the main thread as signals.
## apply() refuses while a game runs (set_game_running(), wired by main.gd).
##
## kinds: "os", "firmware", "flatpak". Per kind, phase is one of
##   unsupported  no tool for it on this system
##   idle         not checked yet
##   checking     a check is running
##   up_to_date   checked, nothing new
##   available    checked, an update can be applied
##   applying     an update is downloading / installing (see `progress`)
##   staged       installed, takes effect after a restart
##   error        last check or apply failed (`error` says why)
##
## Privileges (docs/SYSTEM.md): every check runs as the user. Applying uses the
## OS's own polkit rules, never our root helper: steamos-update (polkit, no
## password in the active session), rpm-ostree upgrade (Fedora Atomic 41+
## rule: no password for active local sessions), fwupd trusted updates and
## Flatpak app/runtime updates (both "yes" for active sessions upstream).

signal changed(state: Dictionary)
## A check finished. result: os {"available", "version", "notes_url", "staged",
## "staged_version"}; firmware {"available", "devices"}; flatpak {"available", "pending"}.
signal checked(kind: String, result: Dictionary)
## While applying. percent is 0..100, or -1 when the tool doesn't say.
signal progress(kind: String, percent: float, line: String)
## An apply (or reboot) finished. message is "" on success, else a short reason:
## "game_running", "busy", "not_available", "unsupported" or the tool's last line.
signal finished(kind: String, ok: bool, message: String)

const OsInfo := preload("res://scripts/system/os_info.gd")
const Parse := preload("res://scripts/system/update_parse.gd")

const KINDS: Array[String] = ["os", "firmware", "flatpak"]
const PROGRESS_EVERY_MS := 250

## Filesystem prefix for every file read ("" = real system; fixtures in tests).
var root := ""
var home := OS.get_environment("HOME")
var path_env := OS.get_environment("PATH")
var game_running := false

var os_info: Dictionary = {}
var _phase := {}
var _os := {"available": false, "version": "", "notes_url": "", "staged": false, "staged_version": "", "current": "", "error": ""}
var _fw := {"available": false, "devices": [], "error": ""}
var _fp := {"available": false, "pending": [], "error": ""}
var _tools := {}
var _detected := false
var _last_progress_ms := 0


## Tests: point at a fixture root and a fake runner. Detection runs at once.
func setup(command_runner: RefCounted, fs_root: String, home_dir: String, path := "/usr/bin:/bin") -> void:
	runner = command_runner
	root = fs_root
	home = home_dir
	path_env = path
	_detected = false
	detect()


## Reads os-release and looks for the tools. Only file checks: cheap enough
## for the main thread, and runs on first use, not at start.
func detect() -> Dictionary:
	os_info = OsInfo.detect(root)
	_tools = {
		"fwupdmgr": _which("fwupdmgr"),
		"flatpak": _which("flatpak"),
		"systemctl": _which("systemctl"),
	}
	_phase = {
		"os": "idle" if os_info["backend"] != "none" else "unsupported",
		"firmware": "idle" if _tools["fwupdmgr"] != "" else "unsupported",
		"flatpak": "idle" if _tools["flatpak"] != "" else "unsupported",
	}
	_os["notes_url"] = os_info["notes_url"]
	_os["current"] = os_info["version"]
	_detected = true
	return os_info


func _ensure() -> void:
	if not _detected:
		detect()


func _which(name: String) -> String:
	for dir in path_env.split(":", false):
		if FileAccess.file_exists(root + dir.path_join(name)):
			return dir.path_join(name)
	return ""


func phase(kind: String) -> String:
	_ensure()
	return _phase.get(kind, "unsupported")


func supported(kind: String) -> bool:
	return phase(kind) != "unsupported"


## Everything the Updates page shows. Safe to call any time.
func state() -> Dictionary:
	_ensure()
	return {
		"os_info": os_info.duplicate(),
		"phase": _phase.duplicate(),
		"os": _os.duplicate(true),
		"firmware": _fw.duplicate(true),
		"flatpak": _fp.duplicate(true),
		"supported": {"os": supported("os"), "firmware": supported("firmware"), "flatpak": supported("flatpak")},
		"game_running": game_running,
		"reboot_needed": _phase.get("os") == "staged" or (_phase.get("firmware") == "staged"),
	}


## main.gd / GameSession: true while a game runs. apply() refuses meanwhile.
func set_game_running(on: bool) -> void:
	if game_running == on:
		return
	game_running = on
	changed.emit(state())


## Checks every supported kind. Results arrive as `checked` and `changed`.
func check_updates() -> void:
	for k in KINDS:
		if supported(k):
			check(k)


## The OS image update: same as apply("os").
func apply_update() -> bool:
	return apply("os")


## Starts a check. False when the kind is unsupported or busy.
func check(kind: String) -> bool:
	_ensure()
	var p := phase(kind)
	if p == "unsupported" or p == "applying" or p == "checking":
		return false
	_set_phase(kind, "checking")
	match kind:
		"os": _queue("check_os", _check_os)
		"firmware": _queue("check_firmware", _check_firmware)
		"flatpak": _queue("check_flatpak", _check_flatpak)
	return true


## Starts applying. `target` picks one firmware device id ("" = all with an update).
## False (and `finished(kind, false, reason)`) when a game runs, nothing is
## available or something is already running.
func apply(kind: String, target := "") -> bool:
	_ensure()
	var reason := ""
	var p := phase(kind)
	if p == "unsupported":
		reason = "unsupported"
	elif game_running:
		reason = "game_running"
	elif p == "applying" or p == "checking":
		reason = "busy"
	elif p != "available":
		reason = "not_available"
	if reason != "":
		finished.emit(kind, false, reason)
		return false
	_set_phase(kind, "applying")
	match kind:
		"os": _queue("apply_os", _apply_os)
		"firmware": _queue("apply_firmware", _apply_firmware.bind(target))
		"flatpak": _queue("apply_flatpak", _apply_flatpak)
	return true


## Restarts the device (logind allows the active session). Refused while a game runs.
func reboot() -> bool:
	if game_running:
		finished.emit("reboot", false, "game_running")
		return false
	_queue("reboot", func():
		var r: Dictionary = runner.run("systemctl", PackedStringArray(["reboot"]))
		var ok := int(r.get("code", -1)) == 0
		_main(func(): finished.emit("reboot", ok, "" if ok else Parse.last_line(str(r.get("out", ""))))))
	return true


## Main thread only.
func _set_phase(kind: String, p: String) -> void:
	_phase[kind] = p
	changed.emit(state())


# ---- OS -----------------------------------------------------------------------

## Reads rpm-ostree's deployments: is an update already staged for the next boot?
func _read_staged() -> Dictionary:
	if not _rpm_ostree():
		return {}
	var r: Dictionary = runner.run("rpm-ostree", PackedStringArray(["status", "--json"]))
	if int(r.get("code", -1)) != 0:
		return {}
	return Parse.rpm_ostree_status(str(r.get("out", "")))


func _rpm_ostree() -> bool:
	return FileAccess.file_exists(root + OsInfo.RPM_OSTREE) and os_info.get("atomic", false)


func _check_os() -> void:
	var res := {"available": false, "version": "", "error": "", "staged": false, "staged_version": ""}
	var st := _read_staged()
	if not st.is_empty():
		if not st["booted"].is_empty() and str(st["booted"]["version"]) != "":
			res["current"] = st["booted"]["version"]
		if not st["staged"].is_empty():
			res["staged"] = true
			res["staged_version"] = st["staged"]["version"]
	if os_info["backend"] == "rpm-ostree":
		var r: Dictionary = runner.run("rpm-ostree", PackedStringArray(["upgrade", "--check"]))
		var c := Parse.rpm_ostree_check(int(r.get("code", -1)), str(r.get("out", "")))
		res.merge(c, true)
		if res["version"] == "" and not st.is_empty() and not st["cached"].is_empty():
			res["version"] = st["cached"]["version"]
		# The staged deployment is the update: nothing newer to fetch.
		if res["staged"] and res["available"] and (res["version"] == "" or res["version"] == res["staged_version"]):
			res["available"] = false
	elif os_info["backend"] == "steamos-update":
		var r: Dictionary = runner.run(OsInfo.STEAM_HELPER, PackedStringArray(["check"]))
		res.merge(Parse.steamos_check(int(r.get("code", -1)), str(r.get("out", ""))), true)
	_finish_os_check(res)


func _finish_os_check(res: Dictionary) -> void:
	_main(func():
		if res.has("current"):
			_os["current"] = res["current"]
		_os["available"] = res["available"]
		_os["version"] = res["version"]
		_os["staged"] = res["staged"] or _os["staged"]
		if res["staged_version"] != "":
			_os["staged_version"] = res["staged_version"]
		_os["error"] = res["error"]
		_phase["os"] = "error" if res["error"] != "" else ("available" if res["available"] else ("staged" if _os["staged"] else "up_to_date"))
		checked.emit("os", {"available": _os["available"], "version": _os["version"], "notes_url": _os["notes_url"],
			"staged": _os["staged"], "staged_version": _os["staged_version"], "error": _os["error"]})
		changed.emit(state()))


func _apply_os() -> void:
	var code := -1
	var tail: Array = []
	var on_line := func(line: String):
		tail.append(line)
		if tail.size() > 5:
			tail.remove_at(0)
		_progress("os", line)
	if os_info["apply_via"] == "steamos-update":
		code = runner.stream(OsInfo.STEAM_HELPER, PackedStringArray([]), on_line)
	elif os_info["apply_via"] == "rpm-ostree":
		code = runner.stream("rpm-ostree", PackedStringArray(["upgrade"]), on_line)
	var ok := code == 0
	var msg := "" if ok else _tail_message(tail, code)
	var staged_version := ""
	if _rpm_ostree():
		# Bazzite's os-update exits 0 even when uupd failed: trust the deployments.
		var st := _read_staged()
		if not st.is_empty():
			ok = not st["staged"].is_empty()
			if ok:
				staged_version = st["staged"]["version"]
				msg = ""
			elif msg == "":
				var last := _tail_message(tail, code)
				msg = last if not tail.is_empty() else "no update was staged"
	_main(func():
		if ok:
			_os["staged"] = true
			_os["available"] = false
			_os["error"] = ""
			if staged_version != "":
				_os["staged_version"] = staged_version
			_phase["os"] = "staged"
		else:
			_os["error"] = msg
			_phase["os"] = "error"
		finished.emit("os", ok, msg)
		changed.emit(state()))


func _tail_message(tail: Array, code: int) -> String:
	for i in range(tail.size() - 1, -1, -1):
		if str(tail[i]).strip_edges() != "":
			return str(tail[i]).strip_edges()
	return "exit code %d" % code


func _progress(kind: String, line: String) -> void:
	var pct := Parse.progress_percent(line)
	var now := Time.get_ticks_msec()
	if pct < 0.0 and now - _last_progress_ms < PROGRESS_EVERY_MS:
		return
	_last_progress_ms = now
	_main(func(): progress.emit(kind, pct, line.strip_edges()))


# ---- firmware -------------------------------------------------------------------

func _check_firmware() -> void:
	# Metadata refresh: polkit action refresh-remote is "yes" upstream. Exit 2 =
	# already up to date; failures (offline) still let us read what we have.
	runner.run("fwupdmgr", PackedStringArray(["refresh"]))
	var r: Dictionary = runner.run("fwupdmgr", PackedStringArray(["get-updates", "--json", "--no-unreported-check", "--no-metadata-check"]))
	var res := Parse.fwupd_updates(int(r.get("code", -1)), str(r.get("out", "")))
	_main(func():
		_fw = res
		_phase["firmware"] = "error" if res["error"] != "" else ("available" if res["available"] else "up_to_date")
		checked.emit("firmware", res.duplicate(true))
		changed.emit(state()))


func _apply_firmware(target: String) -> void:
	var ok := true
	var msg := ""
	var reboot := false
	var tail: Array = []
	for dev in _fw.get("devices", []):
		if target != "" and dev["id"] != target:
			continue
		var code: int = runner.stream("fwupdmgr", PackedStringArray(["update", dev["id"], "--assume-yes", "--no-reboot-check"]),
			func(line: String):
				tail.append(line)
				if tail.size() > 5:
					tail.remove_at(0)
				_progress("firmware", line))
		if code != 0 and code != 2:
			ok = false
			msg = _tail_message(tail, code)
			break
		reboot = reboot or dev.get("needs_reboot", false)
	_main(func():
		if ok:
			_fw["available"] = false
			_fw["error"] = ""
			_phase["firmware"] = "staged" if reboot else "up_to_date"
		else:
			_fw["error"] = msg
			_phase["firmware"] = "error"
		finished.emit("firmware", ok, msg)
		changed.emit(state()))


# ---- Flatpak ----------------------------------------------------------------------

func _installations() -> Array[String]:
	var out: Array[String] = []
	if DirAccess.dir_exists_absolute(home + "/.local/share/flatpak"):
		out.append("user")
	if DirAccess.dir_exists_absolute(root + "/var/lib/flatpak"):
		out.append("system")
	return out


func _check_flatpak() -> void:
	var pending: Array = []
	var err := ""
	for inst in _installations():
		var r: Dictionary = runner.run("flatpak", PackedStringArray(["remote-ls", "--updates", "--" + inst,
			"--columns=application,name,version,branch,origin"]))
		if int(r.get("code", -1)) != 0:
			err = Parse.last_line(str(r.get("out", "")))
			continue
		pending.append_array(Parse.flatpak_updates(str(r.get("out", "")), inst))
	var res := {"available": not pending.is_empty(), "pending": pending, "error": err if pending.is_empty() else ""}
	_main(func():
		_fp = res
		_phase["flatpak"] = "error" if res["error"] != "" else ("available" if res["available"] else "up_to_date")
		checked.emit("flatpak", res.duplicate(true))
		changed.emit(state()))


func _apply_flatpak() -> void:
	var ok := true
	var msg := ""
	var tail: Array = []
	var done := {}
	for item in _fp.get("pending", []):
		var inst: String = item["installation"]
		if done.has(inst):
			continue
		done[inst] = true
		var code: int = runner.stream("flatpak", PackedStringArray(["update", "--" + inst, "--noninteractive", "-y"]),
			func(line: String):
				tail.append(line)
				if tail.size() > 5:
					tail.remove_at(0)
				_progress("flatpak", line))
		if code != 0:
			ok = false
			msg = _tail_message(tail, code)
	_main(func():
		if ok:
			_fp = {"available": false, "pending": [], "error": ""}
			_phase["flatpak"] = "up_to_date"
		else:
			_fp["error"] = msg
			_phase["flatpak"] = "error"
		finished.emit("flatpak", ok, msg)
		changed.emit(state()))
