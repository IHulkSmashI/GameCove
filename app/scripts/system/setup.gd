extends "res://scripts/system/service.gd"
## First run and the setup checklist. Stores which steps are done or skipped
## in user://setup.cfg; reports per-step status for the screens to show.
##
## Steps, in order: welcome, theme, stores, steamgriddb (Game art), keys
## (gg.deals), device_fixes, done. Optional (skippable): all but welcome and done.
## The UI marks a step with complete(id) or skip(id); is_first_run() is true
## until "done" is completed.
##
## Store sign-in: start_login(store) -> `login_started(store, info)` with a URL
## for a QR code and what to type back; finish_login(store, text) ->
## `login_finished(store, ok, message)`. Runs legendary / gogdl / nile on the
## worker, as the user. Device fixes: check_fixes() reads
## `gamecove-fix --list` and each `status` (no root) -> `fixes_checked(list)`.

signal changed(steps: Array)
## info: {"store", "url" ("" for steam), "needs": steam|code|redirect_url|heroic|unavailable,
##        "param": query parameter that carries the code ("" if none)}
signal login_started(store: String, info: Dictionary)
signal login_finished(store: String, ok: bool, message: String)
## [{"name", "applies", "installed", "state", "status": {key: value}}]
signal fixes_checked(fixes: Array)

const SettingsFile := preload("res://scripts/system/settings_file.gd")
const Login := preload("res://scripts/system/store_login.gd")
const BgCommand := preload("res://scripts/ui/bg_command.gd")

const STEPS: Array[String] = ["welcome", "theme", "stores", "steamgriddb", "keys", "device_fixes", "done"]
const OPTIONAL: Array[String] = ["theme", "stores", "steamgriddb", "keys", "device_fixes"]
const CONFIG_PATH := "user://setup.cfg"
const FIX_HELPER := "/usr/libexec/gamecove/gamecove-fix"

var config_path := CONFIG_PATH
var home := OS.get_environment("HOME")
var path_env := OS.get_environment("PATH")
var fix_helper := FIX_HELPER
## Row of devices.json for this handheld ({} when unknown).
var device: Dictionary = {}

var _cfg := ConfigFile.new()
var _loaded := false
var _pending := {}   # store -> data a finish_login needs (nile's verifier)
var _fixes: Array = []
var _fixes_checked := false


func _ready() -> void:
	var dev := get_node_or_null("/root/Device")
	if dev:
		device = dev.profile


## Tests: fake runner, fixture home, a config file under user://.
func setup(command_runner: RefCounted, home_dir: String, cfg_path: String, device_row := {}, path := "/usr/bin") -> void:
	runner = command_runner
	home = home_dir
	config_path = cfg_path
	device = device_row
	path_env = path
	_loaded = false
	_pending.clear()
	_fixes.clear()
	_fixes_checked = false


func _load() -> void:
	if _loaded:
		return
	_cfg = SettingsFile.load_cfg(config_path)
	_loaded = true


## Private (0600): the file holds the user's SteamGridDB key.
func _save() -> void:
	SettingsFile.save_text(config_path, _cfg.encode_to_text(), true)


func is_done(step: String) -> bool:
	_load()
	return bool(_cfg.get_value("steps", step, false))


func is_skipped(step: String) -> bool:
	_load()
	return bool(_cfg.get_value("skipped", step, false))


func is_first_run() -> bool:
	return not is_done("done")


## First step neither done nor skipped ("done" when everything is).
func next_step() -> String:
	for s in STEPS:
		if not is_done(s) and not is_skipped(s):
			return s
	return "done"


## [{"id", "optional", "done", "skipped", "status": {...}}] in order.
## status per step: stores -> store_status(); device_fixes -> {"suggested": [...],
## "checked": bool, "fixes": [...]}; steamgriddb -> {"has_key": bool}.
func steps() -> Array:
	var out: Array = []
	for s in STEPS:
		var st := {}
		match s:
			"stores": st = {"stores": store_status()}
			"device_fixes": st = {"suggested": suggested_fixes(), "checked": _fixes_checked, "fixes": _fixes.duplicate(true)}
			"steamgriddb": st = {"has_key": steamgriddb_key() != ""}
		out.append({"id": s, "optional": s in OPTIONAL, "done": is_done(s), "skipped": is_skipped(s), "status": st})
	return out


func complete(step: String) -> bool:
	if not step in STEPS:
		return false
	_load()
	_cfg.set_value("steps", step, true)
	if _cfg.has_section_key("skipped", step):
		_cfg.erase_section_key("skipped", step)
	_save()
	changed.emit(steps())
	return true


func skip(step: String) -> bool:
	if not step in OPTIONAL:
		return false
	_load()
	_cfg.set_value("skipped", step, true)
	_save()
	changed.emit(steps())
	return true


## Starts setup over (keeps the SteamGridDB key).
func reset() -> void:
	_load()
	for section in ["steps", "skipped"]:
		if _cfg.has_section(section):
			_cfg.erase_section(section)
	_save()
	changed.emit(steps())


func steamgriddb_key() -> String:
	_load()
	return str(_cfg.get_value("keys", "steamgriddb", ""))


## Stores the user's own SteamGridDB API key ("" removes it). Keys are 32 hex chars.
func set_steamgriddb_key(key: String) -> bool:
	var k := key.strip_edges()
	if k != "" and not (k.length() == 32 and k.is_valid_hex_number()):
		return false
	_load()
	if k == "":
		if _cfg.has_section_key("keys", "steamgriddb"):
			_cfg.erase_section_key("keys", "steamgriddb")
	else:
		_cfg.set_value("keys", "steamgriddb", k)
	_save()
	changed.emit(steps())
	return true


## Which stores are signed in (file reads only; cheap).
func store_status() -> Dictionary:
	return Login.status(home, path_env)


# ---- store sign-in --------------------------------------------------------------

## Starts signing in to `store`. False when it can't (no tool, already busy).
## The answer comes as `login_started` (nile needs a process to make its URL).
func start_login(store: String) -> bool:
	if not store in Login.STORES:
		return false
	var st: Dictionary = store_status()[store]
	var info := {"store": store, "url": "", "needs": st["how"], "param": ""}
	match st["how"]:
		"steam", "heroic", "unavailable":
			login_started.emit(store, info)
			return st["how"] == "steam"
	match store:
		"epic":
			info["url"] = Login.EPIC_LOGIN_URL
			info["param"] = "authorizationCode"
			_pending["epic"] = {"config": st["config"], "tool": st["tool"]}
			login_started.emit(store, info)
		"gog":
			info["url"] = Login.GOG_LOGIN_URL
			info["param"] = "code"
			_pending["gog"] = {"config": st["config"], "tool": st["tool"]}
			login_started.emit(store, info)
		"amazon":
			if job_pending("login:amazon"):
				return false
			var cmd := Login.with_env(Login.env_for("amazon", st["config"], home), [st["tool"], "auth", "--login", "--non-interactive"])
			_queue("login:amazon", func():
				var r: Dictionary = runner.run(cmd[0], PackedStringArray(cmd.slice(1)))
				var data := Login.nile_login_data(str(r.get("out", "")))
				_main(func():
					if data.is_empty():
						login_finished.emit("amazon", false, "nile did not start a sign-in")
						return
					_pending["amazon"] = {"config": st["config"], "tool": st["tool"], "data": data}
					info["url"] = str(data["url"])
					info["param"] = "openid.oa2.authorization_code"
					login_started.emit("amazon", info)))
	return true


## Finishes a sign-in with what the person typed (the code, or the whole
## address they were sent to). False when there's nothing to finish.
func finish_login(store: String, text: String) -> bool:
	if not _pending.has(store):
		return false
	var p: Dictionary = _pending[store]
	var cmd: Array = []
	match store:
		"epic":
			var code := Login.epic_code(text)
			if code == "":
				login_finished.emit(store, false, "no code")
				return false
			cmd = Login.with_env(Login.env_for("epic", p["config"], home), [p["tool"], "auth", "--code", code])
		"gog":
			var code := Login.code_from(text, "code")
			if code == "":
				login_finished.emit(store, false, "no code")
				return false
			DirAccess.make_dir_recursive_absolute(str(p["config"]).get_base_dir())
			cmd = [p["tool"], "--auth-config-path", p["config"], "auth", "--code", code]
		"amazon":
			var code := Login.code_from(text, "openid.oa2.authorization_code")
			if code == "":
				login_finished.emit(store, false, "no code")
				return false
			var d: Dictionary = p["data"]
			cmd = Login.with_env(Login.env_for("amazon", p["config"], home), [p["tool"], "register", "--code", code,
				"--client-id", str(d["client_id"]), "--code-verifier", str(d["code_verifier"]), "--serial", str(d["serial"])])
		_:
			return false
	_queue("login:" + store, func():
		var r: Dictionary = runner.run(cmd[0], PackedStringArray(cmd.slice(1)))
		_main(func():
			# The tools print errors but may still exit 0: the saved login decides.
			var now: Dictionary = store_status()[store]
			var ok: bool = now["signed_in"]
			if ok:
				_pending.erase(store)
			var msg := "" if ok else (BgCommand.error_line(str(r.get("out", ""))) if BgCommand.error_line(str(r.get("out", ""))) != "" else "sign-in failed")
			login_finished.emit(store, ok, msg)
			changed.emit(steps())))
	return true


func cancel_login(store: String) -> void:
	_pending.erase(store)


# ---- device fixes ----------------------------------------------------------------

## The fixes devices.json suggests for this handheld (names of fixes/ folders).
func suggested_fixes() -> Array:
	var f: Variant = device.get("fixes", [])
	return (f as Array).duplicate() if f is Array else []


## Reads which suggested fixes exist here and their status (no root).
func check_fixes() -> void:
	var wanted := suggested_fixes()
	_queue("fixes", func():
		var out: Array = []
		var listed: Array = []
		if not wanted.is_empty():
			var r: Dictionary = runner.run(fix_helper, PackedStringArray(["--list"]))
			if int(r.get("code", -1)) == 0:
				for l in str(r.get("out", "")).split("\n", false):
					listed.append(l.strip_edges())
		for name in wanted:
			if not name in listed:
				continue
			var s: Dictionary = runner.run(fix_helper, PackedStringArray([name, "status"]))
			var kv := BgCommand.key_values(str(s.get("out", "")))
			out.append({"name": name, "applies": kv.get("applies", "no") == "yes",
				"installed": kv.get("installed", "no") == "yes", "state": kv.get("state", "unknown"), "status": kv})
		_main(func():
			_fixes = out
			_fixes_checked = true
			fixes_checked.emit(out.duplicate(true))
			changed.emit(steps())))
