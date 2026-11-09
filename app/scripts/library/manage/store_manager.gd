extends Node
## Store management behind the Library API (docs/STORES.md): install,
## uninstall, update, verify/repair, move, pause/resume/cancel, launch options and
## compatibility tool, for Steam (SteamBackend) and Epic/GOG/Amazon
## (StoreCommands + DownloadQueue). Library owns one as a child and forwards its
## signals; the UI only ever talks to Library.
##
## Every action returns at once with {"ok", "via", "why"}; what happens next
## arrives as signals. No polling while nothing is going on: the queue reacts to
## process output, Steam is watched only while one of its downloads is active.

signal download_progress(key: String, bytes_done: int, bytes_total: int, rate: float, eta: int)
signal install_state_changed(key: String, state: String)
signal queue_changed
signal action_failed(key: String, action: String, message: String)
## A store's own window needs the user (app: steam | heroic; reason: install | uninstall | page | manage).
signal external_window_needed(key: String, app: String, reason: String)
## Something changed on disk for this store: rescan it.
signal store_changed(store: String)
signal settings_changed

const SettingsFile := preload("res://scripts/system/settings_file.gd")
const LaunchFiles := preload("res://scripts/controls/perf/launch_files.gd")
const JobRunner := preload("res://scripts/library/manage/job_runner.gd")
const DownloadQueue := preload("res://scripts/library/manage/download_queue.gd")
const StoreCommands := preload("res://scripts/library/manage/store_commands.gd")
const Disk := preload("res://scripts/library/manage/disk.gd")
const Common := preload("res://scripts/library/stores/common.gd")
const SteamBackend := preload("res://scripts/steam/steam_backend.gd")
const SteamFocus := preload("res://scripts/steam/steam_focus.gd")
const GamescopeScript := preload("res://scripts/gamescope/gamescope.gd")

const CAPS := ["install", "uninstall", "update", "verify", "move", "launch_options", "compat_tool", "progress", "pause", "resume", "cancel"]
## install_state_changed states.
const STATE_FOR_ACTION := {"install": "installing", "update": "updating", "verify": "verifying", "move": "moving", "uninstall": "uninstalling"}

var home := OS.get_environment("HOME")
var settings_path := "user://store_settings.json"
var queue_path := "user://downloads.json"
var media_root := "/run/media"
var user := OS.get_environment("USER")
## Tools found on this machine (Common.find_tools); filled on setup.
var tools := {}
## func(key) -> store entry (Library's full entry, with paths), or {}.
var entry_lookup := func(_key: String) -> Dictionary: return {}
## The Launcher service (per-game compat settings for non-Steam games), or null.
## Looked up lazily: the Launcher autoload is added after Library.
var launcher: Object
## func(cmd: Array) -> bool. Starts a store's GUI (Heroic) without waiting.
var open_external := func(cmd: Array) -> bool: return OS.create_process(str(cmd[0]), PackedStringArray(cmd.slice(1))) > 0
## Bring Steam's dialogs forward under gamescope (StoreSettings "focus_steam_dialogs").
var under_gamescope := OS.get_environment("GAMESCOPE_WAYLAND_DISPLAY") != ""

var runner: Object
var queue: DownloadQueue
var steam: Node
var settings := {}
var _restored := false
var _capture := {}    # runner handle -> {"out": String, "cb": Callable}
var _steam_jobs := {} # appid -> action (what we asked Steam for)


func _init(job_runner: Object = null) -> void:
	runner = job_runner if job_runner != null else JobRunner.new()
	runner.line.connect(_on_capture_line)
	runner.exited.connect(_on_capture_exit)
	queue = DownloadQueue.new(runner)
	queue.job_changed.connect(_on_job_changed)
	queue.job_progress.connect(_on_job_progress)
	queue.job_finished.connect(_on_job_finished)
	steam = SteamBackend.new()
	steam.name = "SteamBackend"
	add_child(steam)
	steam.progress.connect(func(appid, d, t, r, e): download_progress.emit("steam:" + appid, d, t, r, e))
	steam.state_changed.connect(_on_steam_state)
	steam.finished.connect(_on_steam_finished)
	steam.setting_failed.connect(func(appid: String, what: String, msg: String):
		action_failed.emit("steam:" + appid, what, msg))
	steam.window_needed.connect(func(appid, reason): _need_window("steam:" + appid, "steam", reason))
	steam.pending_changed.connect(_save_settings)


## Reads settings and finds tools. Call once, from the main thread.
func setup(home_dir := "") -> void:
	if home_dir != "":
		home = home_dir
	_load_settings()
	tools = Common.find_tools(home, OS.get_environment("PATH"))
	queue.save_path = queue_path
	queue.auto_resume = settings["auto_resume"]
	queue.max_parallel = settings["max_parallel"]
	steam.setup(home, settings["steam_cef"], settings["cef_flag_created"])
	steam.pending = settings["steam_pending"]
	steam.pending_base = settings["steam_pending_base"]
	steam.apply_pending()
	# review S2-1: older builds put the bare wrapper path in launch options, which stops the game if
	# GameCove is gone; while Steam is stopped, move them to the fall-through form
	if steam.steam_root != "" and not steam.steam_running():
		var w := LaunchFiles.wrapper_path("")
		if w != "":
			LaunchFiles.upgrade_legacy_all(home, steam.steam_root, w, steam.proc_root)
	mark_steam_ready(OS.get_environment("XDG_RUNTIME_DIR"))


static func default_settings(home_dir: String) -> Dictionary:
	return {"install_root": home_dir.path_join("Games"), "steam_cef": false, "cef_flag_created": false,
		"auto_resume": true, "max_parallel": 1, "focus_steam_dialogs": true, "steam_pending": {}, "steam_pending_base": {}}


func _load_settings() -> void:
	settings = default_settings(home)
	var d: Variant = SettingsFile.load_json(settings_path)["data"]
	if not (d is Dictionary):
		return
	for k in settings:
		if d.has(k) and typeof(d[k]) == typeof(settings[k]):
			settings[k] = d[k]
	settings["max_parallel"] = clampi(int(settings["max_parallel"]), 1, 4)
	if not (str(settings["install_root"]).is_absolute_path()):
		settings["install_root"] = home.path_join("Games")


## Tells session/gamecove-session-client that Steam's settings that waited are written, so it can
## start Steam now (review S2-4: Steam writes its files back from memory, so they're written
## before it starts). Written even when nothing waited.
static func mark_steam_ready(runtime_dir: String) -> void:
	if runtime_dir == "" or not DirAccess.dir_exists_absolute(runtime_dir):
		return
	var f := FileAccess.open(runtime_dir.path_join("gamecove-steam-ready"), FileAccess.WRITE)
	if f != null:
		f.store_string(str(Time.get_unix_time_from_system()))
		f.close()


func _save_settings() -> void:
	settings["steam_pending"] = steam.pending
	settings["steam_pending_base"] = steam.pending_base
	SettingsFile.save_json(settings_path, settings, "\t")


## Settings the UI can show: install_root, steam_cef, auto_resume, max_parallel,
## focus_steam_dialogs, plus read-only steam_cef_status and steam_pending_count.
func get_settings() -> Dictionary:
	var s := settings.duplicate(true)
	s.erase("cef_flag_created")
	s.erase("steam_pending")
	s.erase("steam_pending_base")
	s["steam_cef_status"] = steam.cef.status
	s["steam_pending_count"] = steam.pending.size()
	return s


## Changes one setting. Returns false for unknown names or bad values.
func set_setting(name: String, value: Variant) -> bool:
	match name:
		"install_root":
			if not (value is String) or not value.is_absolute_path():
				return false
			settings[name] = value
		"steam_cef":
			if not (value is bool):
				return false
			settings[name] = value
			var created: bool = steam.cef.set_enabled(value, settings["cef_flag_created"])
			if value:
				settings["cef_flag_created"] = settings["cef_flag_created"] or created
			else:
				settings["cef_flag_created"] = false
		"auto_resume", "focus_steam_dialogs":
			if not (value is bool):
				return false
			settings[name] = value
			queue.auto_resume = settings["auto_resume"]
		"max_parallel":
			if not (value is int) or value < 1 or value > 4:
				return false
			settings[name] = value
			queue.max_parallel = value
		_:
			return false
	_save_settings()
	settings_changed.emit()
	return true


func _entry(game: Dictionary) -> Dictionary:
	var e: Dictionary = entry_lookup.call(str(game.get("key", "")))
	return e if not e.is_empty() else game


func _facts(entry: Dictionary, options: Dictionary) -> Dictionary:
	var root := str(entry.get("heroic_root", ""))
	var path := str(entry.get("install_path", ""))
	var id := str(entry.get("id", ""))
	return {
		"install_root": settings.get("install_root", home.path_join("Games")),
		"home": home,
		"options": options,
		"gog_auth_exists": root != "" and FileAccess.file_exists(root.path_join("gog_store/auth.json")),
		"gog_marker_exists": StoreCommands.gog_folder_is(path, id),
	}


# --- Capabilities ---

## What can be done for this game here: {cap: bool for each of CAPS,
## "how": {cap: backend}, "why": {cap: reason when false}, "needs_window": [caps]}.
func capabilities(game: Dictionary) -> Dictionary:
	var e := _entry(game)
	var installed: bool = e.get("installed", false)
	if str(e.get("store", "")) == "steam":
		return steam.capabilities(installed)
	var c := {"how": {}, "why": {}, "needs_window": []}
	for action in StoreCommands.ACTIONS:
		var p := StoreCommands.plan(action, e, tools, _facts(e, {"path": "/x"} if action == "move" else {}))
		c[action] = p["ok"]
		if p["ok"]:
			c["how"][action] = p["via"]
			if p["via"] == "heroic":
				c["needs_window"].append(action)
		else:
			c["why"][action] = p["why"]
	var queued := not queue.job_for(str(e.get("store", "")) + ":" + str(e.get("id", ""))).is_empty()
	var ours: bool = installed and tools.get("umu", "") != ""
	c["launch_options"] = installed
	c["compat_tool"] = installed and ours
	if c["compat_tool"]:
		c["how"]["compat_tool"] = "umu"
		c["how"]["launch_options"] = "gamecove"
	else:
		c["why"]["compat_tool"] = "Not installed" if not installed else "Install umu-launcher to pick a Proton version"
		if not installed:
			c["why"]["launch_options"] = "Not installed"
	for cap in ["progress", "pause", "resume", "cancel"]:
		c[cap] = true
		c["how"][cap] = "queue"
	if not queued:
		for cap in ["pause", "resume", "cancel"]:
			c[cap] = false
			c["why"][cap] = "Nothing running for this game"
	return c


# --- Actions ---

func _key(e: Dictionary) -> String:
	return "%s:%s" % [e.get("store", ""), e.get("id", "")]


func _ok(via: String) -> Dictionary:
	return {"ok": true, "via": via, "why": ""}


func _fail(key: String, action: String, why: String) -> Dictionary:
	action_failed.emit(key, action, why)
	return {"ok": false, "via": "", "why": why}


## options: {"path": install folder (default <install_root>/<store>; for Steam a
## Steam library folder, default Steam's), "platform": "windows"|"linux" (GOG)}.
func install(game: Dictionary, options := {}) -> Dictionary:
	return _do("install", game, options)


func uninstall(game: Dictionary) -> Dictionary:
	return _do("uninstall", game, {})


func update(game: Dictionary) -> Dictionary:
	return _do("update", game, {})


func verify(game: Dictionary) -> Dictionary:
	return _do("verify", game, {})


func move(game: Dictionary, path: String) -> Dictionary:
	return _do("move", game, {"path": path})


func _do(action: String, game: Dictionary, options: Dictionary) -> Dictionary:
	var e := _entry(game)
	var key := _key(e)
	if str(e.get("store", "")) == "steam":
		return _steam_do(action, e, options)
	if not queue.job_for(key).is_empty():
		return _fail(key, action, "Already in the download queue")
	var p := StoreCommands.plan(action, e, tools, _facts(e, options))
	if not p["ok"]:
		return _fail(key, action, p["why"])
	if p["via"] == "heroic":
		if not open_external.call(p["external"]):
			return _fail(key, action, "Couldn't start Heroic")
		_need_window(key, "heroic", action if action in ["install", "uninstall"] else "manage")
		return _ok("heroic")
	if action == "move" and DirAccess.dir_exists_absolute(str(p["finalize"].get("new_path", ""))):
		return _fail(key, action, "There's already a folder with that name there")
	if action == "install":
		var base := str(p["finalize"].get("base", ""))
		DirAccess.make_dir_recursive_absolute(base)
		if p["finalize"].has("gog_record"):
			# what was there before, so the new folder can be told apart after
			p["finalize"]["before"] = StoreCommands.list_dirs(base)
	var job := queue.add(key, action, p, str(e.get("title", "")))
	if job.is_empty():
		return _fail(key, action, "Already in the download queue")
	return _ok(p["via"])


func _steam_do(action: String, e: Dictionary, options: Dictionary) -> Dictionary:
	var appid := str(e["id"])
	var key := "steam:" + appid
	var r: Dictionary
	match action:
		"install":
			r = steam.install(appid, str(options.get("path", "")))
		"uninstall":
			r = steam.uninstall(appid)
		"update":
			r = steam.update(appid)
		"verify":
			r = steam.verify(appid)
		"move":
			r = steam.move(appid, str(options.get("path", "")))
	if not r.get("ok", false):
		return _fail(key, action, r.get("why", "Steam didn't take the request"))
	_steam_jobs[appid] = action
	install_state_changed.emit(key, STATE_FOR_ACTION.get(action, "queued"))
	queue_changed.emit()
	return r


func pause(game: Dictionary) -> Dictionary:
	return _control("pause", game)


func resume(game: Dictionary) -> Dictionary:
	return _control("resume", game)


func cancel(game: Dictionary) -> Dictionary:
	return _control("cancel", game)


func _control(what: String, game: Dictionary) -> Dictionary:
	var e := _entry(game)
	var key := _key(e)
	if str(e.get("store", "")) == "steam":
		var r: Dictionary = steam.call(what, str(e["id"]))
		return r if r["ok"] else _fail(key, what, r["why"])
	var ok: bool = queue.call(what, key)
	return _ok("queue") if ok else _fail(key, what, "Nothing to %s for this game" % what)


## Moves a waiting download up (delta < 0) or down.
func reorder(game: Dictionary, delta: int) -> bool:
	var ok := queue.reorder(_key(_entry(game)), delta)
	if ok:
		queue_changed.emit()
	return ok


## Every unfinished download: our queue in order, then what Steam is doing for us.
## [{"key", "action", "title", "state", "progress": {bytes_done, bytes_total, rate,
##   eta, percent, unit, phase}, "error", "size"}]
func downloads() -> Array[Dictionary]:
	var out := queue.snapshot()
	for appid in _steam_jobs:
		var e: Dictionary = entry_lookup.call("steam:" + appid)
		out.append({"key": "steam:" + appid, "action": _steam_jobs[appid], "title": str(e.get("title", appid)),
			"state": "running", "progress": {}, "error": "", "size": 0})
	return out


# --- Launch options and compatibility tool ---

func _launcher() -> Object:
	if launcher == null and is_inside_tree():
		launcher = get_node_or_null("/root/Launcher")
	return launcher


func launch_options(game: Dictionary) -> String:
	var e := _entry(game)
	if str(e.get("store", "")) == "steam":
		return steam.launch_options(str(e["id"]))
	return _launcher().compat_for(_key(e))["args"] if _launcher() != null else ""


## Steam: the game's launch options in Steam (e.g. "PROTON_LOG=1 %command%").
## Others: extra arguments GameCove passes to the game.
func set_launch_options(game: Dictionary, options: String) -> Dictionary:
	var e := _entry(game)
	if str(e.get("store", "")) == "steam":
		return steam.set_launch_options(str(e["id"]), options)
	if _launcher() == null:
		return _fail(_key(e), "launch_options", "No launcher")
	var c: Dictionary = _launcher().compat_for(_key(e))
	c["args"] = options
	_launcher().save_compat(_key(e), c)
	return _ok("gamecove")


## The same three reads with the result on `done` (main thread). Steam's come
## from big files on a thread; the others are in memory and answer at once.
func launch_options_async(game: Dictionary, done: Callable) -> void:
	var e := _entry(game)
	if str(e.get("store", "")) == "steam":
		steam.launch_options_async(str(e["id"]), done)
	else:
		done.call(launch_options(game))


func compat_tool_async(game: Dictionary, done: Callable) -> void:
	var e := _entry(game)
	if str(e.get("store", "")) == "steam":
		steam.compat_tool_async(str(e["id"]), done)
	else:
		done.call(compat_tool(game))


func compat_tools_async(game: Dictionary, done: Callable) -> void:
	if str(_entry(game).get("store", game.get("store", ""))) == "steam":
		steam.compat_tools_async(done)
	else:
		done.call(compat_tools(game))


func compat_tool(game: Dictionary) -> String:
	var e := _entry(game)
	if str(e.get("store", "")) == "steam":
		return steam.compat_tool(str(e["id"]))
	return _launcher().compat_for(_key(e))["proton"] if _launcher() != null else ""


## Steam: internal tool name for Steam's per-game setting ("" = Steam's default).
## Others: a tool id from compat_tools(game), used as umu's PROTONPATH.
func set_compat_tool(game: Dictionary, tool_id: String) -> Dictionary:
	var e := _entry(game)
	if str(e.get("store", "")) == "steam":
		return steam.set_compat_tool(str(e["id"]), tool_id)
	if _launcher() == null:
		return _fail(_key(e), "compat_tool", "No launcher")
	var c: Dictionary = _launcher().compat_for(_key(e))
	c["proton"] = tool_id
	_launcher().save_compat(_key(e), c)
	return _ok("umu")


## Tools to choose from: [{"id", "name", "path", ...}], the default first.
## For a Steam game, Steam's tools; otherwise umu's.
func compat_tools(game: Dictionary = {}) -> Array[Dictionary]:
	if str(_entry(game).get("store", game.get("store", ""))) == "steam":
		return steam.compat_tools()
	if _launcher() != null:
		return _launcher().compat_tools()
	return [{"id": "", "name": "Default (UMU-Proton)", "path": ""}] as Array[Dictionary]


## Where new games can go: [{"path", "label", "free", "removable"}].
func install_locations() -> Array[Dictionary]:
	return Disk.locations(settings.get("install_root", home.path_join("Games")), media_root, user)


# --- Library scans ---

## Called with Library's entries after every scan: follows Steam downloads that
## are already running, restores the saved queue once, and drops saved jobs the
## stores have made pointless.
func on_library_scanned(entries: Dictionary) -> void:
	var busy: Array = []
	for key in entries:
		var e: Dictionary = entries[key]
		if e.get("store", "") == "steam" and e.get("busy", false):
			busy.append(str(e["id"]))
	steam.observe(busy)
	if not _restored:
		_restored = true
		queue.restore(func(j: Dictionary) -> bool:
			var e: Dictionary = entries.get(j["key"], {})
			if e.is_empty():
				return j["action"] == "install"
			var inst: bool = e.get("installed", false)
			return inst != (j["action"] == "install") or j["state"] == DownloadQueue.RUNNING)
		queue_changed.emit()


# --- Queue and Steam events ---

func _on_job_changed(j: Dictionary) -> void:
	var state: String = j["state"]
	match state:
		DownloadQueue.RUNNING:
			state = STATE_FOR_ACTION.get(j["action"], "running")
		DownloadQueue.DONE:
			state = "not_installed" if j["action"] == "uninstall" else "installed"
		DownloadQueue.CANCELLED:
			var e: Dictionary = entry_lookup.call(j["key"])
			state = "installed" if e.get("installed", false) else "not_installed"
	install_state_changed.emit(j["key"], state)
	queue_changed.emit()


func _on_job_progress(j: Dictionary) -> void:
	var p: Dictionary = j["progress"]
	download_progress.emit(j["key"], int(p["bytes_done"]), int(p["bytes_total"]), float(p["rate"]), int(p["eta"]))


func _on_job_finished(j: Dictionary) -> void:
	var store := str(j["key"]).get_slice(":", 0)
	if j["state"] == DownloadQueue.FAILED:
		action_failed.emit(j["key"], j["action"], j["error"])
	if j["state"] == DownloadQueue.DONE:
		_finalize(j)
	if j["state"] != DownloadQueue.CANCELLED or j["action"] == "install":
		store_changed.emit(store)


## After a GOG job we ran ourselves, keep our install record in step.
func _finalize(j: Dictionary) -> void:
	var f: Dictionary = j["finalize"]
	if not f.has("gog_record"):
		return
	var id := str(j["key"]).get_slice(":", 1)
	var list := StoreCommands.read_gog_record(home)
	match str(f["gog_record"]):
		"add":
			var taken: Array = []
			for item in list:
				if item is Dictionary and str(item.get("appName", "")) != id:
					taken.append(str(item.get("install_path", "")))
			var path := StoreCommands.find_gog_install(str(f.get("base", "")), id, f.get("before"), taken)
			if path == "":
				action_failed.emit(j["key"], j["action"], "Installed, but couldn't tell which folder in %s is the game" % f.get("base", ""))
				return
			# proof for uninstall later: this folder is this game's
			var mark := FileAccess.open(path.path_join(StoreCommands.GOG_OWNER_FILE % id), FileAccess.WRITE)
			if mark != null:
				mark.store_string(id + "\n")
				mark.close()
			list = StoreCommands.gog_record_with(list, {"appName": id, "install_path": path, "platform": str(f.get("platform", "windows")), "title": j["title"]})
		"remove":
			list = StoreCommands.gog_record_with(list, {"appName": id}, true)
		"move":
			for item in list:
				if item is Dictionary and str(item.get("appName", "")) == id:
					item["install_path"] = str(f.get("new_path", ""))
	StoreCommands.write_gog_record(home, list)


func _on_steam_state(appid: String, state: String) -> void:
	install_state_changed.emit("steam:" + appid, state)
	# Steam has started on it, so its dialog has been answered.
	if state in ["downloading", "verifying", "uninstalling"]:
		return_from_steam()


func _on_steam_finished(appid: String, action: String, ok: bool, message: String) -> void:
	_steam_jobs.erase(appid)
	if not ok:
		action_failed.emit("steam:" + appid, action, message)
	return_from_steam()
	queue_changed.emit()
	store_changed.emit("steam")


# --- Steam's window under gamescope ---

var _steam_focused := false


func _need_window(key: String, app: String, reason: String) -> void:
	external_window_needed.emit(key, app, reason)
	if app == "steam" and under_gamescope and settings.get("focus_steam_dialogs", true):
		focus_steam()


## Puts Steam's newest window in front (its dialog). Reads the focusable window
## list off the main thread, then sets GAMESCOPECTRL_BASELAYER_WINDOW.
func focus_steam() -> void:
	_run_capture(["xprop"] + Array(SteamFocus.read_args()), func(code: int, out: String) -> void:
		if code != 0:
			return
		var triples := GamescopeScript.parse_values(out, SteamFocus.ATOM_FOCUSABLE_WINDOWS)
		var wid := SteamFocus.pick_window(triples, OS.get_process_id(), SteamFocus.comms(triples))
		if wid != 0:
			_steam_focused = true
			_run_capture(["xprop"] + Array(SteamFocus.focus_args(wid)), Callable()))


## Gives the screen back to GameCove after a Steam dialog.
func return_from_steam() -> void:
	if not _steam_focused:
		return
	_steam_focused = false
	_run_capture(["xprop"] + Array(SteamFocus.release_args()), Callable())


func _run_capture(cmd: Array, cb: Callable) -> void:
	var h: int = runner.start(cmd, {})
	_capture[h] = {"out": "", "cb": cb}


func _on_capture_line(handle: int, text: String) -> void:
	if _capture.has(handle):
		_capture[handle]["out"] += text + "\n"


func _on_capture_exit(handle: int, code: int) -> void:
	if not _capture.has(handle):
		return
	var c: Dictionary = _capture[handle]
	_capture.erase(handle)
	if c["cb"].is_valid():
		c["cb"].call(code, c["out"])


## Writes Steam settings that waited for Steam to stop; with restart = true,
## stops Steam (steam -shutdown), writes them, and starts it again in the
## session's mode (GAMECOVE_STEAM_MODE, docs/SESSION.md).
func apply_pending_steam_changes(restart := false) -> Dictionary:
	if steam.pending.is_empty():
		return _ok("steam-files")
	if not steam.steam_running():
		steam.apply_pending()
		return _ok("steam-files")
	if not restart:
		return {"ok": false, "via": "", "why": "Steam is running; restart it to apply"}
	steam.restart_and_apply(steam_start_args(OS.get_environment("GAMECOVE_STEAM_MODE")))
	return _ok("steam-restart")


## Arguments Steam starts with in our session (session/gamecove-session-client).
static func steam_start_args(mode: String) -> Array[String]:
	match mode:
		"gamepadui":
			return ["-silent", "-gamepadui", "-steamos3", "-steampal", "-steamdeck"] as Array[String]
		"off":
			return [] as Array[String]
	return ["-silent"] as Array[String]


func _exit_tree() -> void:
	if runner != null and runner.has_method("shutdown"):
		runner.shutdown()
