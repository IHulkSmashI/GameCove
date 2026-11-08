extends Node
## Manages Steam games from outside Steam, in layers (docs/STORES.md):
##
## 1. SteamClient over CEF (SteamCef), when the user opted in and Steam answers:
##    install without a dialog, uninstall, update, verify, move, pause/resume/
##    cancel, launch options, compatibility tool, launch with extra arguments.
## 2. steam:// URIs handed to the running client: install, uninstall (both show
##    a Steam dialog, so we bring Steam's window forward: window_needed), verify,
##    store page, game properties, Downloads page.
## 3. Local files: appmanifest_<id>.acf for state and progress (polled every
##    POLL_S only while something is being watched), localconfig.vdf and
##    config.vdf for launch options and compatibility tool, written only while
##    Steam is stopped; otherwise the change waits for a Steam restart (pending).
##
## Every action returns {"ok", "via", "why"} at once; results come as signals.

signal progress(appid: String, bytes_done: int, bytes_total: int, rate: float, eta: int)
## installed | not_installed | downloading | verifying | uninstalling | paused | moving | update_required
signal state_changed(appid: String, state: String)
signal finished(appid: String, action: String, ok: bool, message: String)
## Steam is showing a dialog the user has to answer (reason: install | uninstall | page).
signal window_needed(appid: String, reason: String)
## A Steam setting we couldn't write yet waits for Steam to stop (appid, what).
signal pending_changed

const Acf := preload("res://scripts/steam/acf.gd")
const SteamConfig := preload("res://scripts/steam/steam_config.gd")
const SteamCef := preload("res://scripts/steam/steam_cef.gd")
const SteamStore := preload("res://scripts/library/stores/steam.gd")
const Proton := preload("res://scripts/launch/proton.gd")

const POLL_S := 2.0
## Give up watching an action that never shows up in the manifest (a dialog the user closed).
const WATCH_TIMEOUT_S := 600.0
## A verify or update that never turns busy within this long is treated as already done.
const START_GRACE_S := 60.0

var home := OS.get_environment("HOME")
var steam_root := ""
var proc_root := "/proc"
## func(uri: String) -> bool. Hands a steam:// URI to the running client.
var open_uri: Callable
## func(args: Array) -> void. Runs `steam <args>` without waiting.
var run_steam := func(args: Array) -> void: OS.create_process(_steam_cmd(), PackedStringArray(args))
var cef: Node
## appid -> {"launch_options": String?, "compat_tool": String?}
var pending := {}

var _watch := {}   # appid -> {"action", "t", "seen_busy", "last_done", "last_t", "rate", "target"}
var _timer: Timer
var _clock := 0.0
var _cef_watching := false
var _last_probe := -60000


func _init() -> void:
	open_uri = _default_open_uri
	cef = SteamCef.new()
	cef.name = "SteamCef"
	add_child(cef)
	cef.binding_called.connect(_on_cef_binding)
	_timer = Timer.new()
	_timer.wait_time = POLL_S
	_timer.timeout.connect(poll)
	add_child(_timer)


func setup(home_dir: String, cef_on := false, cef_flag_ours := false) -> void:
	home = home_dir
	steam_root = Proton.steam_root(home) if home != "" else ""
	cef.steam_root = steam_root
	cef.set_enabled(cef_on, cef_flag_ours)
	if cef.is_usable() and is_inside_tree():
		cef.evaluate("true")


func _default_open_uri(uri: String) -> bool:
	return SteamStore.open_uri(uri, SteamStore.steam_bin())


func steam_running() -> bool:
	return SteamConfig.is_running(home, proc_root)


## Steam control is on and Steam hasn't been found unreachable. After a failure
## it's tried again at most once a minute (the answer then is the fallback).
func cef_usable() -> bool:
	if not cef.is_usable():
		return false
	if cef.status == "unreachable":
		var now := Time.get_ticks_msec()
		if now - _last_probe > 60000 and is_inside_tree():
			_last_probe = now
			cef.evaluate("true")
		return false
	return true


## {"install", "uninstall", "update", "verify", "move", "launch_options",
##  "compat_tool", "progress", "pause", "resume", "cancel": bool,
##  "how": {cap: "steam-cef|steam-uri|steam-files|steam-files-after-restart"},
##  "why": {cap: reason when false}, "needs_window": [caps that show a Steam dialog]}
func capabilities(installed: bool) -> Dictionary:
	var c := {"how": {}, "why": {}, "needs_window": []}
	var api := cef_usable()
	var have_steam := steam_root != ""
	var running := steam_running()
	var files_how := "steam-files" if not running else "steam-files-after-restart"
	var put := func(cap: String, ok: bool, how: String, why := "") -> void:
		c[cap] = ok
		if ok:
			c["how"][cap] = how
		else:
			c["why"][cap] = why
	if not have_steam:
		for cap in ["install", "uninstall", "update", "verify", "move", "launch_options", "compat_tool", "progress", "pause", "resume", "cancel"]:
			put.call(cap, false, "", "Steam isn't installed")
		return c
	put.call("install", not installed, "steam-cef" if api else "steam-uri", "Already installed")
	put.call("uninstall", installed, "steam-cef" if api else "steam-uri", "Not installed")
	put.call("verify", installed, "steam-cef" if api else "steam-uri", "Not installed")
	put.call("update", installed and api, "steam-cef", "Not installed" if not installed else "Steam updates games by itself; turn on Steam control to start one now")
	put.call("move", installed and api, "steam-cef", "Not installed" if not installed else "Turn on Steam control, or use Steam's Properties > Installed Files")
	put.call("launch_options", true, "steam-cef" if api else files_how)
	put.call("compat_tool", true, "steam-cef" if api else files_how)
	put.call("progress", true, "steam-cef" if api else "steam-files")
	for cap in ["pause", "resume", "cancel"]:
		put.call(cap, api, "steam-cef", "Turn on Steam control, or use Steam's Downloads page")
	if not api:
		c["needs_window"] = ["install", "uninstall"]
	return c


func _result(ok: bool, via: String, why := "") -> Dictionary:
	return {"ok": ok, "via": via, "why": why}


## Installs into the Steam library folder `library_path` ("" = Steam's default).
func install(appid: String, library_path := "") -> Dictionary:
	if cef_usable():
		cef.evaluate(SteamCef.js_install(appid.to_int(), library_path), func(r: Dictionary) -> void:
			if not r["ok"]:
				_uri_install(appid)
			elif str(r["value"]) == "wizard":
				window_needed.emit(appid, "install"))
		_start_watch(appid, "install")
		return _result(true, "steam-cef")
	return _uri_install(appid)


func _uri_install(appid: String) -> Dictionary:
	var ok: bool = open_uri.call("steam://install/" + appid)
	if ok:
		_start_watch(appid, "install")
		window_needed.emit(appid, "install")
	return _result(ok, "steam-uri", "" if ok else "Couldn't reach Steam")


func uninstall(appid: String) -> Dictionary:
	if cef_usable():
		cef.evaluate(SteamCef.js_uninstall(appid.to_int()), func(r: Dictionary) -> void:
			if not r["ok"]:
				_uri_simple(appid, "uninstall", "steam://uninstall/", true))
		_start_watch(appid, "uninstall")
		return _result(true, "steam-cef")
	return _uri_simple(appid, "uninstall", "steam://uninstall/", true)


func verify(appid: String) -> Dictionary:
	if cef_usable():
		cef.evaluate(SteamCef.js_verify(appid.to_int()), func(r: Dictionary) -> void:
			if not r["ok"]:
				_uri_simple(appid, "verify", "steam://validate/", false))
		_start_watch(appid, "verify")
		return _result(true, "steam-cef")
	return _uri_simple(appid, "verify", "steam://validate/", false)


func _uri_simple(appid: String, action: String, prefix: String, dialog: bool) -> Dictionary:
	var ok: bool = open_uri.call(prefix + appid)
	if ok:
		_start_watch(appid, action)
		if dialog:
			window_needed.emit(appid, action)
	return _result(ok, "steam-uri", "" if ok else "Couldn't reach Steam")


func update(appid: String) -> Dictionary:
	return _api_only(appid, "update", SteamCef.js_update(appid.to_int()))


func pause(appid: String) -> Dictionary:
	var r := _api_only(appid, "", SteamCef.js_pause(appid.to_int()))
	if r["ok"]:
		state_changed.emit(appid, "paused")
	return r


func resume(appid: String) -> Dictionary:
	return _api_only(appid, "update", SteamCef.js_resume(appid.to_int()))


func cancel(appid: String) -> Dictionary:
	var r := _api_only(appid, "", SteamCef.js_cancel(appid.to_int()))
	if r["ok"]:
		_stop_watch(appid)
		finished.emit(appid, "cancel", true, "")
	return r


## Moves the install to another Steam library folder (added to Steam if new).
func move(appid: String, library_path: String) -> Dictionary:
	if library_path == "":
		return _result(false, "", "Pick a folder")
	var r := _api_only(appid, "move", SteamCef.js_move(appid.to_int(), library_path))
	if r["ok"]:
		_watch[appid]["target"] = library_path
		state_changed.emit(appid, "moving")
	return r


func _api_only(appid: String, action: String, js: String) -> Dictionary:
	if not cef_usable():
		return _result(false, "", "Turn on Steam control in GameCove's settings")
	cef.evaluate(js, func(r: Dictionary) -> void:
		if not r["ok"]:
			_stop_watch(appid)
			finished.emit(appid, action, false, "Steam didn't take the request: %s" % r["error"]))
	if action != "":
		_start_watch(appid, action)
	return _result(true, "steam-cef")


## Starts the game, with extra arguments if given. Through SteamClient.RunGame
## when available (arguments go before the game's own launch options), else
## steam://run/<id>//<args>/ (Steam asks the user to confirm custom arguments).
func launch(appid: String, args := "") -> Dictionary:
	if args == "":
		return _result(open_uri.call("steam://rungameid/" + appid), "steam-uri")
	if cef_usable():
		cef.evaluate(SteamCef.js_run(appid.to_int(), args), func(r: Dictionary) -> void:
			if not r["ok"]:
				open_uri.call(run_uri(appid, args)))
		return _result(true, "steam-cef")
	return _result(open_uri.call(run_uri(appid, args)), "steam-uri")


static func run_uri(appid: String, args: String) -> String:
	return "steam://run/%s//%s/" % [appid, args.uri_encode()]


## Opens a Steam page: store | properties | details | downloads.
func open_page(appid: String, page: String) -> Dictionary:
	var uri: String = {"store": "steam://store/%s", "properties": "steam://gameproperties/%s",
		"details": "steam://nav/games/details/%s", "downloads": "steam://open/downloads"}.get(page, "")
	if uri == "":
		return _result(false, "", "Unknown page")
	var ok: bool = open_uri.call(uri % appid if "%s" in uri else uri)
	if ok:
		window_needed.emit(appid, "page")
	return _result(ok, "steam-uri")


# --- Launch options and compatibility tool ---

func launch_options(appid: String) -> String:
	if pending.has(appid) and pending[appid].has("launch_options"):
		return pending[appid]["launch_options"]
	var user := SteamConfig.current_user_dir(steam_root)
	return SteamConfig.launch_options(user, appid) if user != "" else ""


func compat_tool(appid: String) -> String:
	if pending.has(appid) and pending[appid].has("compat_tool"):
		return pending[appid]["compat_tool"]
	return SteamConfig.compat_tool(steam_root, appid) if steam_root != "" else ""


func set_launch_options(appid: String, options: String) -> Dictionary:
	return _set_setting(appid, "launch_options", options, SteamCef.js_set_launch_options(appid.to_int(), options))


func set_compat_tool(appid: String, tool: String) -> Dictionary:
	return _set_setting(appid, "compat_tool", tool, SteamCef.js_set_compat_tool(appid.to_int(), tool))


func _set_setting(appid: String, what: String, value: String, js: String) -> Dictionary:
	if steam_root == "":
		return _result(false, "", "Steam isn't installed")
	if cef_usable():
		cef.evaluate(js, func(r: Dictionary) -> void:
			if not r["ok"]:
				_queue_pending(appid, what, value))
		return _result(true, "steam-cef")
	if not steam_running():
		var err := _write_setting(appid, what, value)
		if err == OK:
			return _result(true, "steam-files")
		return _result(false, "steam-files", "Couldn't write Steam's settings (%s)" % error_string(err))
	_queue_pending(appid, what, value)
	var r := _result(true, "steam-files-after-restart")
	r["pending"] = true
	return r


func _queue_pending(appid: String, what: String, value: String) -> void:
	if not pending.has(appid):
		pending[appid] = {}
	pending[appid][what] = value
	pending_changed.emit()


func _write_setting(appid: String, what: String, value: String) -> Error:
	if what == "launch_options":
		var user := SteamConfig.current_user_dir(steam_root)
		if user == "":
			return ERR_FILE_NOT_FOUND
		return SteamConfig.set_launch_options(home, user, appid, value, proc_root)
	return SteamConfig.set_compat_tool(home, steam_root, appid, value, proc_root)


## Writes every waiting setting if Steam is stopped. Returns how many were written.
func apply_pending() -> int:
	if pending.is_empty() or steam_running():
		return 0
	var n := 0
	for appid in pending.keys():
		var p: Dictionary = pending[appid]
		for what in p.keys():
			if _write_setting(appid, what, p[what]) == OK:
				p.erase(what)
				n += 1
		if p.is_empty():
			pending.erase(appid)
	if n > 0:
		pending_changed.emit()
	return n


## Stops Steam, writes the waiting settings once it's gone, starts it again with
## `start_args` (none: leave it stopped). Checks every 0.5 s, only during this.
func restart_and_apply(start_args: Array) -> void:
	run_steam.call(["-shutdown"])
	var waited := [0.0]
	var t := Timer.new()
	t.wait_time = 0.5
	add_child(t)
	t.timeout.connect(func() -> void:
		waited[0] += 0.5
		if steam_running() and waited[0] < 40.0:
			return
		t.queue_free()
		apply_pending()
		if not start_args.is_empty():
			run_steam.call(start_args))
	t.start()


static func _steam_cmd() -> String:
	var b := SteamStore.steam_bin()
	return b if b != "" else "steam"


## Compatibility tools Steam can use, from local files (Valve Proton apps and
## compatibilitytools.d). First entry is Steam's default ("").
func compat_tools() -> Array[Dictionary]:
	var out: Array[Dictionary] = [{"id": "", "name": "Steam default", "path": "", "source": "default"}]
	if steam_root == "":
		return out
	var valve: Array = []
	for folder in SteamStore.library_folders(steam_root):
		var d := DirAccess.open(folder.path_join("steamapps"))
		if d == null:
			continue
		for f in d.get_files():
			if f.begins_with("appmanifest_") and f.ends_with(".acf"):
				var m := Acf.parse_file(folder.path_join("steamapps").path_join(f))
				if str(m.get("name", "")).begins_with("Proton"):
					valve.append({"name": m["name"], "path": folder.path_join("steamapps/common").path_join(m["installdir"])})
	out.append_array(SteamConfig.local_tools(Proton.tool_dirs(steam_root), valve))
	return out


# --- Watching manifests ---

## Starts following apps Steam is already busy with (found by a library scan).
func observe(busy_appids: Array) -> void:
	for a in busy_appids:
		if not _watch.has(str(a)):
			_start_watch(str(a), "update")


func is_watching(appid: String) -> bool:
	return _watch.has(appid)


func _start_watch(appid: String, action: String) -> void:
	_watch[appid] = {"action": action, "t": 0.0, "seen_busy": false, "last_done": -1, "last_t": _clock, "rate": 0.0, "target": ""}
	if _timer.is_stopped() and is_inside_tree():
		_timer.start()
	_update_cef_watch()


func _stop_watch(appid: String) -> void:
	_watch.erase(appid)
	if _watch.is_empty():
		_timer.stop()
	_update_cef_watch()


func _update_cef_watch() -> void:
	var want := not _watch.is_empty() and cef_usable()
	if want == _cef_watching:
		return
	_cef_watching = want
	if want:
		cef.add_binding(SteamCef.DOWNLOADS_BINDING)
		cef.evaluate(SteamCef.js_watch_downloads())
	else:
		cef.remove_binding(SteamCef.DOWNLOADS_BINDING)
		if cef_usable():
			cef.evaluate(SteamCef.js_unwatch_downloads())


## Manifest of an app in any library folder, plus the folder: {"m": {...}, "folder": path}.
func find_manifest(appid: String) -> Dictionary:
	if steam_root == "":
		return {}
	for folder in SteamStore.library_folders(steam_root):
		var m := Acf.parse_file(Acf.manifest_path(folder, appid))
		if not m.is_empty():
			return {"m": m, "folder": folder}
	return {}


## One look at every watched manifest (the timer calls this every POLL_S).
func poll(dt := POLL_S) -> void:
	_clock += dt
	for appid in _watch.keys():
		var w: Dictionary = _watch[appid]
		w["t"] += dt
		var found := find_manifest(appid)
		var m: Dictionary = found.get("m", {})
		var action: String = w["action"]
		if action == "uninstall":
			if m.is_empty():
				_done(appid, action, true, "not_installed")
			elif w["t"] > WATCH_TIMEOUT_S:
				_stop_watch(appid)
			continue
		if action == "move":
			if not m.is_empty() and str(found["folder"]).simplify_path() == str(w["target"]).simplify_path() and not Acf.is_busy(m["flags"]):
				_done(appid, action, true, "installed")
			elif w["t"] > WATCH_TIMEOUT_S:
				_stop_watch(appid)
			continue
		if m.is_empty():
			if w["t"] > WATCH_TIMEOUT_S:
				_stop_watch(appid)
			continue
		var flags: int = m["flags"]
		var state := Acf.state_name(flags)
		if Acf.is_busy(flags) or state == "paused":
			w["seen_busy"] = true
			state_changed.emit(appid, state)
			var p := Acf.progress(m)
			var rate: float = w["rate"]
			if w["last_done"] >= 0 and p["bytes_done"] >= w["last_done"] and _clock > w["last_t"]:
				var now_rate: float = (p["bytes_done"] - w["last_done"]) / (_clock - w["last_t"])
				rate = now_rate if rate <= 0.0 else rate * 0.6 + now_rate * 0.4
			w["rate"] = rate
			w["last_done"] = p["bytes_done"]
			w["last_t"] = _clock
			var eta := int((p["bytes_total"] - p["bytes_done"]) / rate) if rate > 0.0 and p["bytes_total"] > p["bytes_done"] else -1
			progress.emit(appid, p["bytes_done"], p["bytes_total"], rate, eta)
		elif Acf.is_installed(flags) and not (flags & Acf.UPDATE_REQUIRED):
			if w["seen_busy"] or action == "install" or w["t"] > START_GRACE_S:
				_done(appid, action, true, "installed")
		elif w["t"] > WATCH_TIMEOUT_S:
			_stop_watch(appid)


func _done(appid: String, action: String, ok: bool, state: String) -> void:
	_stop_watch(appid)
	state_changed.emit(appid, state)
	finished.emit(appid, action, ok, "")


## Steam's own download numbers (CEF), finer than the manifest's.
func _on_cef_binding(name: String, payload: String) -> void:
	if name != SteamCef.DOWNLOADS_BINDING:
		return
	var d: Variant = JSON.parse_string(payload)
	if not (d is Dictionary) or d.get("kind", "") != "overview":
		return
	var appid := str(int(d.get("appid", 0)))
	if appid == "0":
		return
	if not _watch.has(appid):
		_start_watch(appid, "update")
	progress.emit(appid, int(d.get("bytes_done", 0)), int(d.get("bytes_total", 0)), float(d.get("rate", 0.0)), int(d.get("eta", -1)))


func _exit_tree() -> void:
	_timer.stop()
	cef.close()
