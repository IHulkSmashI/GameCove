extends "res://scripts/system/service.gd"
## Updates: the OS image, device firmware (fwupd), the maker's own BIOS/EC/controller firmware
## (firmware index), the driver stack and Flatpak apps.
##
## Nothing runs on its own except one opt-in: "Update apps by themselves" (Settings >
## Device > Updates, off by default) updates Flatpak apps at most once a day, 3 minutes
## after start and after a game ends, never while a game runs, only with Background
## lookups on and on AC or an unmetered network; the update runs at the lowest CPU and
## disk priority (nice 19, ionice idle), so a game started meanwhile isn't held up.
## Otherwise there's no timer and no check at start. The UI calls
## check(kind) / check_updates() and apply(kind) / apply_update(); work happens
## on the worker thread and comes back on the main thread as signals.
## apply() refuses while a game runs (set_game_running(), wired by main.gd).
##
## kinds: "os", "firmware", "flatpak", "maker", "drivers". Per kind, phase is one of
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
##
## The Updates hub (hub_items(), also state()["hub"]) is one list over fwupd devices, the maker's
## firmware from the nightly index and the driver stack; see firmware_index.gd for the item shape.
## "maker" and "drivers" are check-only: maker firmware is never flashed by GameCove (guided steps,
## a prepared USB drive for ASUS EZ Flash, or the maker's page), drivers update with the OS.
## Firmware installs (fwupd) and USB preparation need the charger in and the battery at 50% or more.

signal changed(state: Dictionary)
## A check finished. result: os {"available", "version", "notes_url", "staged",
## "staged_version"}; firmware {"available", "devices"}; flatpak {"available", "pending"}.
signal checked(kind: String, result: Dictionary)
## While applying. percent is 0..100, or -1 when the tool doesn't say.
signal progress(kind: String, percent: float, line: String)
## An apply (or reboot) finished. message is "" on success, else a short reason:
## "game_running", "busy", "not_available", "unsupported", "needs_ac", "low_battery",
## "guided" (maker firmware: GameCove never flashes it) or the tool's last line.
## prepare_usb() finishes as kind "usb".
signal finished(kind: String, ok: bool, message: String)

const OsInfo := preload("res://scripts/system/os_info.gd")
const Parse := preload("res://scripts/system/update_parse.gd")
const Index := preload("res://scripts/system/firmware_index.gd")
const SettingsFile := preload("res://scripts/system/settings_file.gd")
const Drivers := preload("res://scripts/system/driver_versions.gd")
const Upscale := preload("res://scripts/controls/perf/upscale.gd")

const KINDS: Array[String] = ["os", "firmware", "flatpak", "maker", "drivers"]
## Firmware installs and USB preparation: charger in and at least this much battery.
const MIN_BATTERY := 50
## fwupd metadata refresh: at most this often, and only on AC or an unmetered network.
const REFRESH_EVERY_S := 24 * 3600
const POWER_SUPPLY := "/sys/class/power_supply/"
const JUPITER_BIOSUPDATE := "/usr/bin/jupiter-biosupdate"
const PROGRESS_EVERY_MS := 250
## Automatic app updates (opt-in): first try this long after start, then at most daily.
const AUTO_FIRST_S := 180.0
const AUTO_EVERY_S := 24 * 3600
const AUTO_STAMP := "auto_apps.stamp"
const Privacy := preload("res://scripts/system/privacy.gd")

## Filesystem prefix for every file read ("" = real system; fixtures in tests).
var root := ""
var home := OS.get_environment("HOME")
var path_env := OS.get_environment("PATH")
var game_running := false
## Where the firmware index and stamps are kept ("" = user://firmware).
var cache_dir := ""
## The devices.json row of this handheld ({} = ask the Device autoload).
var device_row: Dictionary = {}
## Tests: a fixed clock (unix seconds); 0 = the real one.
var now_unix := 0

var os_info: Dictionary = {}
var _phase := {}
var _os := {"available": false, "version": "", "notes_url": "", "staged": false, "staged_version": "", "current": "", "error": ""}
var _fw := {"available": false, "devices": [], "error": ""}
var _fp := {"available": false, "pending": [], "error": ""}
var _maker := {"available": false, "items": [], "error": "", "index_built": "", "stale": false}
var _drv := {"available": false, "items": [], "error": ""}
var _fw_devices: Array = []
var _tools := {}
var _detected := false
var _last_progress_ms := 0
## Where "Update apps by themselves" is kept ([updates] auto_apps).
var prefs_path := "user://settings.cfg"
## Tests: the Background lookups answer ({} = ask privacy.gd).
var background_override: Variant = null


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
		"curl": _which("curl"),
		"rpm": _which("rpm"),
		"pacman": _which("pacman"),
	}
	_phase = {
		"os": "idle" if os_info["backend"] != "none" else "unsupported",
		"firmware": "idle" if _tools["fwupdmgr"] != "" else "unsupported",
		"flatpak": "idle" if _tools["flatpak"] != "" else "unsupported",
		"maker": "idle" if not _row().is_empty() else "unsupported",
		"drivers": "idle",
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
		"maker": _maker.duplicate(true),
		"drivers": _drv.duplicate(true),
		"hub": hub_items(),
		"power": power_state(),
		"usb_targets": usb_targets(),
		"supported": {"os": supported("os"), "firmware": supported("firmware"), "flatpak": supported("flatpak"),
			"maker": supported("maker"), "drivers": supported("drivers")},
		"game_running": game_running,
		"auto_apps": auto_apps(),
		"reboot_needed": _phase.get("os") == "staged" or (_phase.get("firmware") == "staged"),
	}


func _ready() -> void:
	# one-shot: the opt-in automatic app update, once the first minutes after start are over
	get_tree().create_timer(AUTO_FIRST_S).timeout.connect(maybe_auto_update_apps)   # a method, not a lambda: freed with this node at exit


## main.gd / GameSession: true while a game runs. apply() refuses meanwhile.
func set_game_running(on: bool) -> void:
	if game_running == on:
		return
	game_running = on
	changed.emit(state())
	if not on:
		maybe_auto_update_apps()


# ---- automatic app updates (opt-in) ------------------------------------------------

var _auto: Variant = null   # cached [updates] auto_apps


func auto_apps() -> bool:
	if _auto == null:
		_auto = bool(SettingsFile.load_cfg(prefs_path).get_value("updates", "auto_apps", false))
	return bool(_auto)


func set_auto_apps(on: bool) -> void:
	_auto = on
	SettingsFile.update_cfg(prefs_path, func(cfg: ConfigFile): cfg.set_value("updates", "auto_apps", on))
	changed.emit(state())
	if on:
		maybe_auto_update_apps()


func _background_allowed() -> bool:
	return bool(background_override) if background_override != null else Privacy.background_allowed()


## Starts the automatic app update when everything allows it. "" when it started, else
## why not: "off", "unsupported", "game_running", "privacy", "busy", "not_due".
func maybe_auto_update_apps() -> String:
	if not auto_apps():
		return "off"
	_ensure()
	if not supported("flatpak"):
		return "unsupported"
	if game_running:
		return "game_running"
	if not _background_allowed():
		return "privacy"
	if phase("flatpak") in ["checking", "applying"]:
		return "busy"
	if not _stamp_due(AUTO_STAMP, AUTO_EVERY_S):
		return "not_due"
	_set_phase("flatpak", "checking")
	_queue("auto_apps", _auto_apps)
	return ""


func _auto_apps() -> void:
	if not network_ok():
		_main(func(): _set_phase("flatpak", "idle"))
		return
	var found := _flatpak_pending()
	if found["pending"].is_empty():
		if found["error"] == "":
			_touch_stamp(AUTO_STAMP)
		_main(func():
			_fp = {"available": false, "pending": [], "error": found["error"]}
			_set_phase("flatpak", "error" if found["error"] != "" else "up_to_date"))
		return
	_main(func():
		_fp = {"available": true, "pending": found["pending"], "error": ""}
		_set_phase("flatpak", "applying"))
	if _flatpak_update(found["pending"], true):
		_touch_stamp(AUTO_STAMP)


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
		"maker": _queue("check_maker", _check_maker)
		"drivers": _queue("check_drivers", _check_drivers)
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
	elif kind == "maker" or kind == "drivers":
		reason = "guided"
	elif p != "available":
		reason = "not_available"
	elif kind == "firmware":
		reason = power_block()
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
	# At most daily, and only on AC or an unmetered network (no mobile data).
	if _stamp_due("fwupd_refresh", REFRESH_EVERY_S) and network_ok():
		runner.run("fwupdmgr", PackedStringArray(["refresh"]))
		_touch_stamp("fwupd_refresh")
	var r: Dictionary = runner.run("fwupdmgr", PackedStringArray(["get-updates", "--json", "--no-unreported-check", "--no-metadata-check"]))
	var res := Parse.fwupd_updates(int(r.get("code", -1)), str(r.get("out", "")))
	var all_r: Dictionary = runner.run("fwupdmgr", PackedStringArray(["get-devices", "--json"]))
	var all := Parse.fwupd_devices(str(all_r.get("out", ""))) if int(all_r.get("code", -1)) == 0 else []
	_main(func():
		_fw_devices = all
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


## Pending Flatpak updates of every installation: {"pending": [...], "error": ""}. Worker.
func _flatpak_pending() -> Dictionary:
	var pending: Array = []
	var err := ""
	for inst in _installations():
		var r: Dictionary = runner.run("flatpak", PackedStringArray(["remote-ls", "--updates", "--" + inst,
			"--columns=application,name,version,branch,origin"]))
		if int(r.get("code", -1)) != 0:
			err = Parse.last_line(str(r.get("out", "")))
			continue
		pending.append_array(Parse.flatpak_updates(str(r.get("out", "")), inst))
	return {"pending": pending, "error": err if pending.is_empty() else ""}


func _check_flatpak() -> void:
	var found := _flatpak_pending()
	var res := {"available": not found["pending"].is_empty(), "pending": found["pending"], "error": found["error"]}
	_main(func():
		_fp = res
		_phase["flatpak"] = "error" if res["error"] != "" else ("available" if res["available"] else "up_to_date")
		checked.emit("flatpak", res.duplicate(true))
		changed.emit(state()))


func _apply_flatpak() -> void:
	_flatpak_update(_fp.get("pending", []), false)


## Updates every installation with something pending. `background`: lowest CPU and
## disk priority (the automatic update). Worker; finishes like apply("flatpak").
func _flatpak_update(pending: Array, background: bool) -> bool:
	var ok := true
	var msg := ""
	var tail: Array = []
	var done := {}
	for item in pending:
		var inst: String = item["installation"]
		if done.has(inst):
			continue
		done[inst] = true
		var prog := "flatpak"
		var args := PackedStringArray(["update", "--" + inst, "--noninteractive", "-y"])
		if background:
			var pre := PackedStringArray(["-n", "19"])
			if _which("ionice") != "":
				pre.append_array(["ionice", "-c", "3"])
			pre.append("flatpak")
			pre.append_array(args)
			prog = "nice"
			args = pre
		var code: int = runner.stream(prog, args,
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
	return ok


# ---- power / network gates ---------------------------------------------------------

## {"ac": bool, "battery": int (-1 = no battery), "ok": bool, "reason": "" | "needs_ac" | "low_battery"}
func power_state() -> Dictionary:
	var why := power_block()
	return {"ac": _ac(), "battery": battery_percent(), "ok": why == "", "reason": why}


## "" when firmware may be written now, else "needs_ac" or "low_battery".
func power_block() -> String:
	if not _ac():
		return "needs_ac"
	var b := battery_percent()
	if b >= 0 and b < MIN_BATTERY:
		return "low_battery"
	return ""


## True when a charger is connected, and always on a box with no battery (a Steam Machine, a desktop): it
## has nothing to run out and often no supply entry that says "online", so it used to be refused every
## firmware update with "needs_ac".
func _ac() -> bool:
	if not has_battery():
		return true
	return preload("res://scripts/device/device.gd").ac_online(root)


## A battery (a BAT* supply, or one whose type says Battery) exists, readable or not.
func has_battery() -> bool:
	var dir := DirAccess.open(root + POWER_SUPPLY)
	if dir == null:
		return false
	for n in Array(dir.get_directories()) + Array(dir.get_files()):
		if str(n).begins_with("BAT") or read_text(root + POWER_SUPPLY + n + "/type") == "Battery":
			return true
	return false


func battery_percent() -> int:
	var dir := DirAccess.open(root + POWER_SUPPLY)
	if dir == null:
		return -1
	var names := Array(dir.get_directories()) + Array(dir.get_files())
	names.sort()
	for n in names:
		if str(n).begins_with("BAT"):
			var cap := read_text(root + POWER_SUPPLY + n + "/capacity")
			if cap.is_valid_int():
				return cap.to_int()
	return -1


## Downloads (index, fwupd metadata) only on AC or a network NetworkManager doesn't call metered
## (NMMetered: 1 yes, 3 guess-yes). No NetworkManager answer counts as unmetered.
func network_ok() -> bool:
	if _ac():
		return true
	var r: Dictionary = runner.run("busctl", PackedStringArray(["get-property", "org.freedesktop.NetworkManager",
		"/org/freedesktop/NetworkManager", "org.freedesktop.NetworkManager", "Metered"]))
	if int(r.get("code", -1)) != 0:
		return true
	var parts := str(r.get("out", "")).strip_edges().split(" ", false)
	return not (parts.size() == 2 and parts[1] in ["1", "3"])


func _now() -> int:
	return now_unix if now_unix > 0 else int(Time.get_unix_time_from_system())


func _cache() -> String:
	var d := cache_dir if cache_dir != "" else ProjectSettings.globalize_path("user://firmware")
	DirAccess.make_dir_recursive_absolute(d)
	return d


func _stamp_due(stamp: String, every_s: int) -> bool:
	var t := read_text(_cache().path_join(stamp))
	return not t.is_valid_int() or _now() - t.to_int() >= every_s


func _touch_stamp(stamp: String) -> void:
	var f := FileAccess.open(_cache().path_join(stamp), FileAccess.WRITE)
	if f != null:
		f.store_string(str(_now()))


func _row() -> Dictionary:
	if not device_row.is_empty():
		return device_row
	var d: Node = get_node_or_null("/root/Device") if is_inside_tree() else null
	if d != null and d.get("profile") is Dictionary:
		return d.get("profile")
	return {}


# ---- firmware index (maker BIOS / EC / controller) -----------------------------------

## The cached index, downloaded first when it's over a week old and the network allows.
## The download is accepted only when its sha256 matches the published .sha256 and it parses.
func load_index() -> Dictionary:
	var path := _cache().path_join("firmware.json.gz")
	var mod := int(FileAccess.get_modified_time(path)) if FileAccess.file_exists(path) else 0
	# A failed download is retried at most daily.
	if Index.is_stale(mod, _now()) and _stamp_due("index_fetch", REFRESH_EVERY_S) and network_ok():
		_touch_stamp("index_fetch")
		var part := path + ".part"
		var r: Dictionary = runner.run("curl", PackedStringArray(["--proto", "=https", "--proto-redir", "=https", "-fsSL", "--max-time", "60", "-o", part, "--", Index.URL]))
		var s: Dictionary = runner.run("curl", PackedStringArray(["--proto", "=https", "--proto-redir", "=https", "-fsSL", "--max-time", "20", "--", Index.URL + ".sha256"]))
		var want := Index.sha_from_text(str(s.get("out", "")))
		var good := int(r.get("code", -1)) == 0 and int(s.get("code", -1)) == 0 and want != "" \
			and FileAccess.file_exists(part) and FileAccess.get_sha256(part) == want \
			and not Index.parse_gz(FileAccess.get_file_as_bytes(part)).is_empty()
		var sig := _index_signature(part) if good else "bad"
		if good and sig != "bad":
			DirAccess.rename_absolute(part, path)
			# the sha256 of the file cosign accepted; any other file at `path` counts as unverified
			if sig == "verified":
				SettingsFile.save_text(path + VERIFIED_SUFFIX, want + "\n")
			elif FileAccess.file_exists(path + VERIFIED_SUFFIX):
				DirAccess.remove_absolute(path + VERIFIED_SUFFIX)
		elif FileAccess.file_exists(part):
			DirAccess.remove_absolute(part)
	return Index.parse_gz(FileAccess.get_file_as_bytes(path)) if FileAccess.file_exists(path) else {}


## cosign on this device: the system's, else the copy the installer downloaded (get-gamecove.sh's pinned
## COSIGN_VERSION and sha256); "" when there is none.
const COSIGN_VERSION := "v2.5.3"
const VERIFIED_SUFFIX := ".verified"
## A maker's firmware download: redirects and size are capped (review problem 1).
const MAX_FW_REDIRS := 5
const MAX_FW_BYTES := 512 * 1024 * 1024


func _cosign() -> String:
	var sys := _which("cosign")
	if sys != "":
		return sys
	var mine := home.path_join(".local/share/gamecove/tools/cosign-" + COSIGN_VERSION)
	return mine if home != "" and FileAccess.file_exists(mine) else ""


## The cached index's signature was checked on this device (review problem 1): only then are maker downloads
## offered. Checking a Sigstore keyless bundle needs the Fulcio chain, the Rekor entry and the certificate's
## identity extensions; that is cosign's job (the copy get-gamecove.sh pins, or the system's), not GDScript's.
func index_verified() -> bool:
	var path := _cache().path_join("firmware.json.gz")
	if not FileAccess.file_exists(path) or not FileAccess.file_exists(path + VERIFIED_SUFFIX):
		return false
	return FileAccess.get_file_as_string(path + VERIFIED_SUFFIX).strip_edges() == FileAccess.get_sha256(path)


## The index's Sigstore signature (review M21): "verified" when firmware.json.gz.sigstore.json proves it was made by
## the nightly workflow on main, "bad" when cosign refuses it (the download isn't used), "unverified" without cosign
## (the index is shown, but firmware_items drops every download URL).
func _index_signature(part: String) -> String:
	var cos := _cosign()
	if cos == "":
		return "unverified"
	var bundle := part + ".sigstore.json"
	var b: Dictionary = runner.run("curl", PackedStringArray(["--proto", "=https", "--proto-redir", "=https", "-fsSL", "--max-time", "20", "-o", bundle, "--", Index.URL + ".sigstore.json"]))
	var ok := int(b.get("code", -1)) == 0 and FileAccess.file_exists(bundle) and int(runner.run(cos, PackedStringArray([
		"verify-blob", "--bundle", bundle, "--certificate-oidc-issuer", Index.OIDC_ISSUER,
		"--certificate-identity-regexp", Index.SIGNER_IDENTITY, part])).get("code", -1)) == 0
	if FileAccess.file_exists(bundle):
		DirAccess.remove_absolute(bundle)
	return "verified" if ok else "bad"


func _check_maker() -> void:
	var row := _row()
	var index := load_index()
	var installed := Index.read_installed(root)
	var items := Index.firmware_items(index, row, installed, _fw_devices, index_verified())
	if str(row.get("family", "")) == "steam-deck":
		items = _deck_local(items, installed)
	var res := {"available": items.any(func(i): return i["status"] == "update"), "items": items,
		"error": "" if not (index.is_empty() and items.is_empty()) else "index_unavailable",
		"index_built": str(index.get("built", "")),
		"stale": bool(Index.entries_for(index, row)["entry"].get("stale", false))}
	_main(func():
		_maker = res
		_phase["maker"] = "error" if res["error"] != "" else ("available" if res["available"] else "up_to_date")
		checked.emit("maker", res.duplicate(true))
		changed.emit(state()))


## Steam Deck: the OS image carries the BIOS and its updater, so "what this OS would install" is
## read from its own jupiter-biosupdate, and whether that runs at boot from its service state.
## The index (Valve's newest jupiter-hw-support) says what a newer OS image would bring.
func _deck_local(items: Array, installed: Dictionary) -> Array:
	var script := read_text(root + JUPITER_BIOSUPDATE)
	if script == "":
		return items
	var cur := str(installed.get("bios_version", ""))
	var target := Index.deck_bios_target(script, cur)
	var svc := "unknown"
	if _tools.get("systemctl", "") != "":
		var r: Dictionary = runner.run("systemctl", PackedStringArray(["is-enabled", "jupiter-biosupdate.service"]))
		svc = str(r.get("out", "")).strip_edges().get_slice("\n", 0) if str(r.get("out", "")).strip_edges() != "" else "unknown"
	var upstream := ""
	var out: Array = []
	for it in items:
		if it["kind"] == "bios":
			upstream = it["latest"]
		else:
			out.append(it)
	var latest := target if target != "" else cur
	var item := {
		"id": "local:bios", "section": "firmware", "kind": "bios", "name": "BIOS", "current": cur, "latest": latest,
		"status": "update" if target != "" and Index.compare("valve", cur, target) < 0 else "current",
		"severity": "recommended" if target != "" else "info", "how": "guided", "flash": "steamos",
		"notes": "", "notes_url": "https://store.steampowered.com/news/app/1675200", "download_page": "",
		"download_url": "", "sha256": "", "date": "", "source": "local", "service": svc,
		"os_family": str(os_info.get("family", "")), "upstream": upstream,
	}
	if upstream != "" and Index.compare("valve", latest, upstream) < 0:
		item["upstream_note"] = upstream
	out.push_front(item)
	return out


# ---- driver stack ---------------------------------------------------------------------

func _check_drivers() -> void:
	var installed := {}
	var k := read_text(root + "/proc/sys/kernel/osrelease")
	if k != "":
		installed["kernel"] = k
	var pkg_names := {}
	for name in Drivers.STACK:
		var spec: Dictionary = Drivers.STACK[name]
		if _tools.get("rpm", "") != "" and spec.has("rpm"):
			pkg_names[spec["rpm"]] = name
		elif _tools.get("pacman", "") != "" and spec.has("pacman"):
			pkg_names[spec["pacman"]] = name
	if not pkg_names.is_empty():
		var vers := {}
		if _tools.get("rpm", "") != "":
			var r: Dictionary = runner.run("rpm", PackedStringArray(["-q", "--qf", "%{NAME} %{VERSION}\n"] + pkg_names.keys()))
			vers = Drivers.rpm_versions(str(r.get("out", "")))
		else:
			var r2: Dictionary = runner.run("pacman", PackedStringArray(["-Q"] + pkg_names.keys()))
			vers = Drivers.pacman_versions(str(r2.get("out", "")))
		for p in vers:
			if pkg_names.has(p):
				installed[pkg_names[p]] = vers[p]
	var decky := read_text(home + Drivers.DECKY_VERSION)
	if decky != "":
		installed["decky"] = decky
	var up_cmd := Upscale.command(root)
	if up_cmd != "":
		var r3: Dictionary = runner.run(up_cmd, PackedStringArray(["state", "--home", home, "--gpu", Upscale.gpu_arg(Upscale.gpu(_row()))]))
		var st := Drivers.helper_json(str(r3.get("out", "")))
		var xe: Variant = st.get("xess")
		if xe is Dictionary and str(xe.get("version", "")) not in ["", "<null>"]:
			installed["xess-xmx"] = str(xe["version"])
		var op: Variant = st.get("optiscaler")
		if op is Dictionary and bool(op.get("installed", false)):
			installed["optiscaler"] = str(op.get("version", ""))
	var next := {}
	if os_info.get("backend", "") == "rpm-ostree" and bool(_os.get("available", false)):
		var r4: Dictionary = runner.run("rpm-ostree", PackedStringArray(["upgrade", "--preview"]))
		var diff := Drivers.rpm_ostree_preview(str(r4.get("out", "")))
		for p in diff:
			if p == "kernel" or p == "kernel-core":
				next["kernel"] = diff[p]
			elif pkg_names.has(p):
				next[pkg_names[p]] = diff[p]
	var index := load_index()
	var sw: Dictionary = index.get("software", {}) if index.get("software") is Dictionary else {}
	var items := Drivers.items(installed, sw, next, str(os_info.get("family", "")))
	var res := {"available": items.any(func(i): return i["status"] == "update"), "items": items, "error": ""}
	_main(func():
		_drv = res
		_phase["drivers"] = "available" if res["available"] else "up_to_date"
		checked.emit("drivers", res.duplicate(true))
		changed.emit(state()))


# ---- the hub ------------------------------------------------------------------------------

## One list for everything on the handheld: fwupd devices, maker firmware, driver stack.
## Updates first, then by section.
func hub_items() -> Array:
	var out: Array = []
	var pending := {}
	for d in _fw.get("devices", []):
		pending[str(d.get("id", ""))] = d
	var seen := {}
	for d in _fw_devices:
		var merged: Dictionary = d.duplicate()
		if pending.has(d["id"]):
			merged.merge(pending[d["id"]], true)
		seen[d["id"]] = true
		out.append(Index.fwupd_item(merged))
	for id in pending:
		if not seen.has(id):
			out.append(Index.fwupd_item(pending[id]))
	# fwupd covers a part the index also lists (e.g. the ROG MCU): keep fwupd's, it can install.
	var fw_names := out.map(func(i): return str(i["name"]).to_lower())
	for it in _maker.get("items", []):
		if it["kind"] == "controller" and fw_names.any(func(n): return n.contains("mcu") or n.contains("controller")):
			continue
		out.append(it)
	out.append_array(_drv.get("items", []))
	var rank := {"update": 0, "unknown": 1, "upstream": 2, "current": 3}
	var order := out.map(func(i): return i["id"])
	out.sort_custom(func(a, b):
		var ra: int = rank.get(a["status"], 4)
		var rb: int = rank.get(b["status"], 4)
		if a["section"] != b["section"]:
			return a["section"] == "firmware"
		return ra < rb if ra != rb else order.find(a["id"]) < order.find(b["id"]))
	return out


# ---- USB drive for a maker's UEFI flasher -----------------------------------------------

## FAT32 drives mounted under /run/media (where the desktop and Steam mount USB sticks).
## [{"mount", "label", "device"}]
func usb_targets() -> Array:
	var out: Array = []
	for line in read_text(root + "/proc/self/mounts").split("\n", false):
		var p := line.split(" ", false)
		if p.size() < 3 or p[2] != "vfat":
			continue
		var mnt := p[1].replace("\\040", " ")
		if mnt.begins_with("/run/media/") or mnt.begins_with("/media/"):
			out.append({"mount": mnt, "label": mnt.get_file(), "device": p[0]})
	return out


## Puts a maker's UEFI-flasher file on a FAT32 USB drive: only for ASUS EZ Flash (a documented
## route: EZ Flash in the UEFI reads the .CAP from a FAT32 drive). Downloads the maker's zip,
## checks the sha256 the maker publishes, copies the .CAP files to the drive's root. Never flashes.
## Refused during a game, without AC or under 50% battery. Ends with finished("usb", ok, message).
func prepare_usb(item_id: String, mount: String) -> bool:
	var it: Dictionary = {}
	for i in _maker.get("items", []):
		if i["id"] == item_id:
			it = i
	var reason := ""
	if game_running:
		reason = "game_running"
	elif it.is_empty() or it.get("flash") != "ez-flash" or str(it.get("sha256", "")).length() != 64 \
			or Index.download_host(str(it.get("download_url", "")), str(_row().get("maker", ""))) == "":
		reason = "not_available"
	elif not usb_targets().any(func(t): return t["mount"] == mount):
		reason = "no_usb"
	else:
		reason = power_block()
	if reason != "":
		finished.emit("usb", false, reason)
		return false
	_queue("prepare_usb", _prepare_usb.bind(it, mount))
	return true


func _prepare_usb(it: Dictionary, mount: String) -> void:
	var zip := _cache().path_join("usb_download.zip")
	if FileAccess.file_exists(zip):
		DirAccess.remove_absolute(zip)
	_main(func(): progress.emit("usb", -1.0, "Downloading " + str(it["name"])))
	# curl prints the URL it ended up at (after redirects): that host must be on the maker's list too
	var r: Dictionary = runner.run("curl", PackedStringArray(["--proto", "=https", "--proto-redir", "=https", "-fsSL",
		"--max-redirs", str(MAX_FW_REDIRS), "--max-filesize", str(MAX_FW_BYTES), "--max-time", "600",
		"-w", "%{url_effective}", "-o", zip, "--", str(it["download_url"])]))
	var msg := ""
	var written: Array = []
	if int(r.get("code", -1)) != 0 or not FileAccess.file_exists(zip):
		msg = "download_failed"
	elif Index.download_host(str(r.get("out", "")).strip_edges(), str(_row().get("maker", ""))) == "":
		msg = "not_available"
	elif FileAccess.get_sha256(zip) != str(it["sha256"]).to_lower():
		msg = "checksum_mismatch"
	else:
		var zr := ZIPReader.new()
		if zr.open(zip) != OK:
			msg = "bad_archive"
		else:
			for f in zr.get_files():
				var name := str(f).get_file()
				if name.to_upper().ends_with(".CAP"):
					var data := zr.read_file(f)
					var dest := root + mount.path_join(name)
					var out := FileAccess.open(dest, FileAccess.WRITE)
					if out == null:
						msg = "write_failed"
						break
					out.store_buffer(data)
					out.close()
					if FileAccess.get_file_as_bytes(dest).size() != data.size():
						msg = "write_failed"
						break
					written.append(name)
			zr.close()
			if msg == "" and written.is_empty():
				msg = "bad_archive"
	DirAccess.remove_absolute(zip)
	var ok := msg == ""
	_main(func():
		finished.emit("usb", ok, ", ".join(PackedStringArray(written)) if ok else msg))
