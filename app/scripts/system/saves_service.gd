extends Node
## Cloud saves around a game: Epic through legendary, GOG through heroic-gogdl (the stores'
## own clouds; cloud_saves.gd has the commands, parsing and rules). Never while a game runs:
##   before_launch(game, done)  pulls a newer cloud save down (a local backup first), or
##                              reports a conflict for the user to settle, then calls done
##   after_exit(game)           pushes what the game just saved up
##   resolve(game, "local"|"cloud", done)  settles a conflict (both sides backed up first;
##                              refused while a game runs, like sync_now and restore)
##   sync_now(game, done)       both ways, from the game page or Settings > Saves
##   restore(game, id, done)    puts a local backup back (the current saves backed up first)
## Offline, signed out or a failed step: the game still starts, nothing is deleted, and the
## status says so; the next launch or exit tries again. A download that fails half way puts
## the backup taken just before it back.
##
## Status per game in user://saves.cfg [game:<key>]: enabled, last_sync, state, at, detail,
## local, remote, restored_at (a backup was put back and not synced since), prefer (the side
## a conflict sheet offers first: "local" after a restore), gog_ts ({location: gogdl timestamp}), gog_paths ({location: the folder that
## timestamp is about}), own (we keep our own sync times: Heroic's are no longer a fallback);
## [gog_remote] caches GOG's answer per client id.
##
## A sync time is only worth something for the folder it was made with. When the folder is
## empty or isn't there (a deleted or new prefix), moved (another prefix), or the game was
## uninstalled, the time is dropped: the next sync then sees both sides as changed and asks,
## where gogdl with the old time would upload a fresh default save and delete every cloud
## file the new folder lacks (final review, blocker 1). One worker thread runs the tools in order (a launch waits for the last exit's
## upload of the same game). Tests run jobs inline (no tree) with a fake `run`.

signal status_changed(key: String)
## A sync found saves changed on both sides; the game page and Settings > Saves offer the choice.
signal conflict_found(key: String)
## A job ended: phase pre | post | now | resolve | restore, state the status it left.
signal finished(key: String, phase: String, state: String)

const CloudSaves := preload("res://scripts/system/cloud_saves.gd")
const SaveBackup := preload("res://scripts/system/save_backup.gd")
const SettingsFile := preload("res://scripts/system/settings_file.gd")
const Privacy := preload("res://scripts/system/privacy.gd")
const ExecSafe := preload("res://scripts/system/exec_safe.gd")

const CFG := "user://saves.cfg"
## exec_safe.gd stop group of legendary and gogdl: at app exit they're ended so the
## exit never waits on a sync (a download cut short puts its backup back, which
## is never stopped).
const GROUP := "saves"

var cfg_path := CFG
var privacy_path := Privacy.PREFS_PATH
## Where backups go (an absolute folder).
var backup_dir := ""
## func(program, args: PackedStringArray) -> {"code", "out"} with stderr folded in.
## The real one puts the store tools in GROUP; backups go through the same call
## outside it (tests swap this for one fake that sees both).
var run: Callable = func(program: String, args: PackedStringArray) -> Dictionary: return ExecSafe.run(program, args, true, GROUP)
var _real_run: Callable
## func(key) -> store entry (Library.entry_for); func() -> tools (Library.tools).
var entry_lookup: Callable = func(_k: String) -> Dictionary: return {}
var tools_lookup: Callable = func() -> Dictionary: return {}
## func() -> unix seconds (tests swap it).
var clock: Callable = func() -> int: return int(Time.get_unix_time_from_system())
## func() -> bool: a game runs now (restores wait).
var game_running: Callable = func() -> bool: return false

var backups: RefCounted
var _busy := {}       # key -> "pre" | "post" | "now" | "resolve" | "restore" (main thread)
var _thread: Thread
var _jobs: Array = []
var _mutex := Mutex.new()
var _sem := Semaphore.new()
var _quit := false


func _init() -> void:
	backup_dir = ProjectSettings.globalize_path("user://saves/backups")
	_real_run = run
	backups = SaveBackup.new(backup_dir, func(p, a): return _backup_run(p, a))


## Backups and put-backs: never stopped (a download cut short at exit must get its
## backup back).
func _backup_run(program: String, args: PackedStringArray) -> Dictionary:
	if run == _real_run:
		return ExecSafe.run(program, args, true)
	return run.call(program, args)


## Wires to the Library autoload (entries, tools) when there is one.
func setup_library(lib: Object) -> void:
	if lib == null:
		return
	if lib.has_method("entry_for"):
		entry_lookup = func(k: String) -> Dictionary: return lib.entry_for(k)
	if lib.has_method("tools"):
		tools_lookup = func() -> Dictionary: return lib.tools()
	if lib.has_signal("install_state_changed"):
		lib.install_state_changed.connect(_on_install_state)


## An uninstalled game's sync times are forgotten: its folders may be gone or new when it
## comes back.
func _on_install_state(key: String, state: String) -> void:
	if state == "not_installed":
		forget(key)


## Forgets what the last sync knew about a game (sync times and the folders they were for).
## The next sync asks instead of picking a side. The game's switch and backups stay.
func forget(key: String) -> void:
	if _drop_sync(key, false):
		status_changed.emit(key)


func _ready() -> void:
	_thread = Thread.new()
	_thread.start(_worker)


## main.gd owns us for the app's whole life: this is real app exit. The running
## sync's tool is ended (queued jobs are dropped), so the wait is short.
func _exit_tree() -> void:
	if _thread == null:
		return
	_mutex.lock()
	_quit = true
	_mutex.unlock()
	ExecSafe.stop_group(GROUP)
	_sem.post()
	_thread.wait_to_finish()
	_thread = null


# ---- what the UI asks ------------------------------------------------------------------------

## The game is one we sync (an installed Epic or GOG game).
func applies(game: Dictionary) -> bool:
	return str(game.get("store", "")) in ["epic", "gog"] and bool(game.get("installed", false))


## Sync cloud saves at all (the privacy switch).
func allowed() -> bool:
	return Privacy.cloud_saves_allowed(privacy_path)


func set_allowed(on: bool) -> bool:
	return Privacy.set_cloud_saves_allowed(on, privacy_path)


func enabled(key: String) -> bool:
	return bool(SettingsFile.load_cfg(cfg_path).get_value(_sec(key), "enabled", true))


func set_enabled(key: String, on: bool) -> bool:
	var ok := SettingsFile.update_cfg(cfg_path, func(c: ConfigFile): c.set_value(_sec(key), "enabled", on)) == OK
	status_changed.emit(key)
	return ok


func busy(key: String) -> bool:
	return _busy.has(key)


## {"state", "at", "detail", "local", "remote", "last_sync", "enabled", "busy": "" | phase,
##  "store", "prefer": "" | "local" (a conflict after a restore: the restored side first)}. state "off" when the game's switch is off, "disabled" when the global one is.
func status(game: Dictionary) -> Dictionary:
	var key := str(game.get("key", ""))
	var cfg := SettingsFile.load_cfg(cfg_path)
	var sec := _sec(key)
	var st := {"state": str(cfg.get_value(sec, "state", "never")), "at": int(cfg.get_value(sec, "at", 0)),
		"detail": str(cfg.get_value(sec, "detail", "")), "local": int(cfg.get_value(sec, "local", 0)),
		"remote": int(cfg.get_value(sec, "remote", 0)), "last_sync": int(cfg.get_value(sec, "last_sync", 0)),
		"enabled": bool(cfg.get_value(sec, "enabled", true)), "busy": str(_busy.get(key, "")),
		"store": str(game.get("store", "")), "prefer": str(cfg.get_value(sec, "prefer", ""))}
	if not st["enabled"]:
		st["state"] = "off"
	elif not allowed():
		st["state"] = "disabled"
	return st


## Installed Epic and GOG games of `games` with their status, for Settings > Saves.
func overview(games: Array) -> Array:
	var out: Array = []
	for g in games:
		if g is Dictionary and applies(g):
			out.append({"game": g, "status": status(g)})
	out.sort_custom(func(a, b): return str(a["game"].get("title", "")).naturalnocasecmp_to(str(b["game"].get("title", ""))) < 0)
	return out


## Local backups of a game, newest first (SaveBackup.list).
func backup_list(key: String) -> Array:
	return backups.list(key)


# ---- around a game ---------------------------------------------------------------------------

## Before a launch. done({"go": true}) to start now, or done({"conflict": status}) when the
## user must pick first. Calls done right away when there's nothing to do.
func before_launch(game: Dictionary, done: Callable) -> void:
	var key := str(game.get("key", ""))
	if not applies(game) or not enabled(key) or not allowed():
		done.call({"go": true})
		return
	_queue(game, "pre", func(e, t): return _sync(key, e, t, "pre"), func(r: Dictionary) -> void:
		if bool(r.get("conflict", false)):
			done.call({"conflict": status(game)})
		else:
			done.call({"go": true}))


## After the game ended: uploads what it saved.
func after_exit(game: Dictionary) -> void:
	var key := str(game.get("key", ""))
	if not applies(game) or not enabled(key) or not allowed():
		return
	_queue(game, "post", func(e, t): return _sync(key, e, t, "post"), Callable())


## Both ways now (never while that game runs). done(status).
func sync_now(game: Dictionary, done: Callable = Callable()) -> void:
	var key := str(game.get("key", ""))
	if not applies(game) or not allowed() or game_running.call():
		if done.is_valid():
			done.call(status(game))
		return
	_queue(game, "now", func(e, t): return _sync(key, e, t, "now"), func(_r):
		if done.is_valid():
			done.call(status(game)))


## Settles a conflict: "local" keeps this handheld's saves (uploads them), "cloud" keeps the
## cloud's (downloads them). Both sides are backed up locally first. done(status).
## Never while a game runs (a forced download empties the folder under it): then nothing
## happens, done gets the status as it stands and this returns false.
func resolve(game: Dictionary, choice: String, done: Callable = Callable()) -> bool:
	var key := str(game.get("key", ""))
	if game_running.call() or not choice in ["local", "cloud"]:
		if done.is_valid():
			done.call(status(game))
		return false
	_queue(game, "resolve", func(e, t): return _resolve(key, e, t, choice), func(_r):
		if done.is_valid():
			done.call(status(game)))
	return true


## Puts local backup `id` back (the current saves are backed up first). done({"ok", "why"}).
func restore(game: Dictionary, id: String, done: Callable = Callable()) -> void:
	var key := str(game.get("key", ""))
	if game_running.call():
		if done.is_valid():
			done.call({"ok": false, "why": "running"})
		return
	_queue(game, "restore", func(e, _t): return _restore(key, str(e.get("title", key)), id), func(r):
		if done.is_valid():
			done.call(r))


func _queue(game: Dictionary, phase: String, job: Callable, done: Callable) -> void:
	var key := str(game.get("key", ""))
	var entry: Dictionary = entry_lookup.call(key)
	if entry.is_empty():
		entry = game.duplicate()
	var tools: Dictionary = tools_lookup.call()
	_busy[key] = phase
	status_changed.emit(key)
	if not entry.has("title"):
		entry["title"] = str(game.get("title", key))
	var wrapped := func() -> Dictionary: return job.call(entry, tools)
	var finish := func(r: Dictionary) -> void:
		_busy.erase(key)
		status_changed.emit(key)
		if bool(r.get("conflict", false)):
			conflict_found.emit(key)
		finished.emit(key, phase, str(r.get("state", "")))
		if done.is_valid():
			done.call(r)
	if _thread == null:
		finish.call(wrapped.call())
		return
	_mutex.lock()
	_jobs.append([wrapped, finish])
	_mutex.unlock()
	_sem.post()


func _worker() -> void:
	while true:
		_sem.wait()
		_mutex.lock()
		if _quit:
			_mutex.unlock()
			return
		var j: Array = _jobs.pop_front() if not _jobs.is_empty() else []
		_mutex.unlock()
		if j.is_empty():
			continue
		var r: Dictionary = j[0].call()
		j[1].call_deferred(r)


# ---- the work (worker thread) ------------------------------------------------------------------

func _sec(key: String) -> String:
	return "game:" + key


func _cfg_value(key: String, name: String, fallback: Variant) -> Variant:
	return SettingsFile.load_cfg(cfg_path).get_value(_sec(key), name, fallback)


## Writes the outcome. last_sync moves only when both sides agree after this step.
func _set_status(key: String, state: String, detail := "", extra := {}) -> Dictionary:
	var now: int = clock.call()
	SettingsFile.update_cfg(cfg_path, func(c: ConfigFile):
		var sec := _sec(key)
		c.set_value(sec, "state", state)
		c.set_value(sec, "at", now)
		c.set_value(sec, "detail", detail)
		c.set_value(sec, "local", int(extra.get("local", 0)))
		c.set_value(sec, "remote", int(extra.get("remote", 0)))
		c.set_value(sec, "prefer", str(extra.get("prefer", "")))
		if bool(extra.get("synced", false)):
			c.set_value(sec, "last_sync", now)
			if c.has_section_key(sec, "restored_at"):
				c.erase_section_key(sec, "restored_at")   # both sides agree again
		if extra.has("gog_ts"):
			c.set_value(sec, "gog_ts", extra["gog_ts"])
			c.set_value(sec, "own", true)
		if extra.has("gog_paths"):
			c.set_value(sec, "gog_paths", extra["gog_paths"])
		if bool(extra.get("synced", false)) and str(extra.get("epic_path", "")) != "":
			c.set_value(sec, "epic_path", str(extra["epic_path"])))
	return {"state": state, "conflict": state == "conflict"}


## Drops the game's sync times (worker or main thread). `create`: also for a game with no
## section yet (so Heroic's times aren't picked up later). True when something was written.
func _drop_sync(key: String, create: bool) -> bool:
	var wrote := [false]
	SettingsFile.update_cfg(cfg_path, func(c: ConfigFile):
		var sec := _sec(key)
		if not c.has_section(sec) and not create:
			return false
		for name in ["gog_ts", "gog_paths", "epic_path"]:
			if c.has_section_key(sec, name):
				c.erase_section_key(sec, name)
		c.set_value(sec, "last_sync", 0)
		c.set_value(sec, "own", true)
		wrote[0] = true
		return true)
	return wrote[0]


func _sync(key: String, entry: Dictionary, tools: Dictionary, mode: String) -> Dictionary:
	match CloudSaves.kind_of(entry):
		"epic": return _sync_epic(key, entry, tools, mode)
		"gog": return _sync_gog(key, entry, tools, mode)
	return _set_status(key, "unsupported")


func _sync_epic(key: String, entry: Dictionary, tools: Dictionary, mode: String) -> Dictionary:
	var plan := CloudSaves.epic_plan(entry, tools)
	if not plan["ok"]:
		if plan["why"] == "not_set_up":
			# no prefix, so no save folder yet: whatever the game makes there is new to us
			_drop_sync(key, true)
		return _set_status(key, str(plan["why"]))
	var app := str(entry.get("id", ""))
	if bool(plan.get("moved", false)):
		_drop_sync(key, true)   # another prefix's folder: the old sync time isn't about it
	_epic_folder_check(key, str(plan["save_path"]))
	var look := _legendary(plan, app, "check")
	if look["state"] in ["offline", "failed", "unsupported", "no_path"]:
		return _set_status(key, _plain_state(look["state"]), str(look.get("error", "")))
	# legendary may only now have worked the folder out
	var folder := CloudSaves.epic_save_path(str(entry.get("config_dir", "")), app)
	if look["state"] == "none":
		return _set_status(key, "no_saves", "", {"synced": true, "epic_path": folder})
	if look["state"] == "same":
		return _set_status(key, "synced", "", {"synced": true, "local": look["local"], "remote": look["remote"], "epic_path": folder})
	var last := int(_cfg_value(key, "last_sync", 0))
	var times := {"local": look["local"], "remote": look["remote"], "epic_path": folder}
	# a restored backup has its old file times: legendary sees "cloud newer" and would download
	# straight over the restore (final review, high 6)
	var restored := int(_cfg_value(key, "restored_at", 0)) > 0
	match CloudSaves.epic_decide(look, last, mode, restored):
		"conflict":
			return _set_status(key, "conflict", "", times.merged({"prefer": "local"} if restored and look["state"] == "remote_newer" else {}))
		"download":
			return _epic_download(key, entry, plan, app, look, "download", times)
		"upload":
			var up := _legendary(plan, app, "upload")
			if up["state"] in ["offline", "failed"]:
				return _set_status(key, up["state"], str(up.get("error", "")), times)
			return _set_status(key, "uploaded", "", times.merged({"synced": true}, true))
		"later":
			# the other direction waits for its turn (next exit uploads, next launch downloads)
			return _set_status(key, "pending_up" if look["state"] == "local_newer" else "pending_down", "", times)
	return _set_status(key, "synced", "", times.merged({"synced": true}, true))


## An Epic sync time only stands for the folder it was made with. With that folder empty
## or gone (a deleted or new prefix) or another one, the time is dropped, written at once:
## a blank save the game then makes is "both sides changed" and we ask, where legendary
## alone would see "local newer" and make the blank one the newest cloud save.
func _epic_folder_check(key: String, folder: String) -> void:
	var cfg := SettingsFile.load_cfg(cfg_path)
	var sec := _sec(key)
	if int(cfg.get_value(sec, "last_sync", 0)) <= 0:
		return
	var kept := str(cfg.get_value(sec, "epic_path", ""))
	if folder == "" or (kept != "" and kept != folder) or int(CloudSaves.dir_stats(folder)["files"]) == 0:
		SettingsFile.update_cfg(cfg_path, func(c: ConfigFile): c.set_value(sec, "last_sync", 0))


## Backs the save folder up, downloads (step download or force_download), and puts the
## backup back if the download didn't finish.
func _epic_download(key: String, entry: Dictionary, plan: Dictionary, app: String, look: Dictionary, step: String, times: Dictionary) -> Dictionary:
	var folder := str(plan.get("save_path", ""))   # where legendary will write (a changed prefix: the new folder)
	if folder == "":
		folder = CloudSaves.epic_save_path(str(entry.get("config_dir", "")), app)
	if folder == "":
		folder = str(look.get("save_path", ""))
	if folder == "":
		return _set_status(key, "no_path", "", times)
	var title := str(entry.get("title", key))
	# a conflict choice: its backup is the one copy of the side not kept, so it's pinned
	var chosen := step == "force_download"
	var b: Dictionary = backups.backup(key, title, "before_download", [{"name": "saves", "path": folder}], chosen, chosen)
	if not b["ok"]:
		return _set_status(key, "too_big" if b["why"] == "too_big" else "backup_failed", str(b["why"]), times)
	var down := _legendary(plan, app, step)
	if down["state"] in ["offline", "failed"]:
		var back := _put_back(key, b)
		return _set_status(key, down["state"], str(down.get("error", "")) + back, times)
	return _set_status(key, "downloaded", "", times.merged({"synced": true}, true))


## After a failed download: the backup goes back. Text for the status detail.
func _put_back(key: String, b: Dictionary) -> String:
	if str(b.get("id", "")) == "" or str(b.get("skipped", "")) == "empty":
		return ""
	var r: Dictionary = backups.restore(key, str(b["id"]))
	return "" if r["ok"] else " (" + str(r["why"]) + ")"


## A plan with "moved" (a changed prefix) tells legendary the folder on every call until
## legendary keeps it.
func _legendary(plan: Dictionary, app: String, step: String) -> Dictionary:
	var argv := CloudSaves.with_timeout(plan["cmd"], CloudSaves.legendary_args(app, step, str(plan["save_path"]) if bool(plan.get("moved", false)) else ""))
	var r: Dictionary = run.call(argv[0], PackedStringArray(argv.slice(1)))
	return CloudSaves.parse_legendary(str(r.get("out", "")), int(r.get("code", -1)))


static func _plain_state(s: String) -> String:
	return {"no_path": "not_set_up"}.get(s, s)


## The GOG plan, asking GOG's remote config once per client id when Heroic doesn't know the game.
func _gog_plan(entry: Dictionary, tools: Dictionary) -> Dictionary:
	var plan := CloudSaves.gog_plan(entry, tools)
	if plan["why"] != "ask":
		return plan
	var client := str(plan["client_id"])
	var cfg := SettingsFile.load_cfg(cfg_path)
	var cached: Variant = cfg.get_value("gog_remote", client, null)
	if cached == null:
		var r: Dictionary = run.call("curl", PackedStringArray(["-sS", "--fail", "-m", "15", CloudSaves.GOG_REMOTE_CONFIG % client]))
		if int(r.get("code", -1)) != 0:
			return {"ok": false, "why": "offline"}
		var locs: Variant = CloudSaves.parse_gog_remote(str(r.get("out", "")))
		cached = locs if locs != null else "none"
		SettingsFile.update_cfg(cfg_path, func(c: ConfigFile): c.set_value("gog_remote", client, cached))
	return CloudSaves.gog_plan(entry, tools, cached)


## gogdl timestamps per location: ours, else Heroic's for a folder Heroic itself synced (so
## that game isn't a conflict at first), and "0" (never synced: gogdl then asks when both
## sides have files) for a location whose folder is empty, isn't there, or isn't the folder
## the time was kept for. What was dropped is written down at once, so it holds when this
## sync fails and the game runs anyway.
func _gog_ts(key: String, entry: Dictionary, locs: Array) -> Dictionary:
	var cfg := SettingsFile.load_cfg(cfg_path)
	var sec := _sec(key)
	var ours: Variant = cfg.get_value(sec, "gog_ts", {})
	var paths: Variant = cfg.get_value(sec, "gog_paths", {})
	var ts: Dictionary = ours.duplicate() if ours is Dictionary else {}
	var heroic := {}
	var root := str(entry.get("heroic_root", ""))
	if ts.is_empty() and root != "" and not bool(cfg.get_value(sec, "own", false)):
		heroic = CloudSaves.heroic_gog_timestamps(root, str(entry.get("id", "")))
	var dropped := false
	for l in locs:
		var name := str(l["name"])
		if not ts.has(name) and heroic.has(name) and bool(l.get("heroic", false)):
			ts[name] = heroic[name]
		var moved: bool = paths is Dictionary and paths.has(name) and str(paths[name]) != str(l["path"])
		if (moved or int(CloudSaves.dir_stats(str(l["path"]))["files"]) == 0) and str(ts.get(name, "0")) != "0":
			ts[name] = "0"
			dropped = true
	if dropped:
		SettingsFile.update_cfg(cfg_path, func(c: ConfigFile):
			c.set_value(sec, "gog_ts", ts)
			c.set_value(sec, "gog_paths", _gog_paths(locs))
			c.set_value(sec, "last_sync", 0)
			c.set_value(sec, "own", true))
	return ts


static func _gog_paths(locs: Array) -> Dictionary:
	var out := {}
	for l in locs:
		out[str(l["name"])] = str(l["path"])
	return out


func _sync_gog(key: String, entry: Dictionary, tools: Dictionary, mode: String) -> Dictionary:
	var plan := _gog_plan(entry, tools)
	if not plan["ok"]:
		if plan["why"] == "not_set_up":
			# no folder to sync yet (no prefix): whatever the game makes there is new to us
			_drop_sync(key, true)
		return _set_status(key, str(plan["why"]))
	var locs: Array = plan["locations"]
	var title := str(entry.get("title", key))
	var b := {"ok": true, "id": "", "skipped": "empty"}
	if mode != "post":
		# gogdl's download deletes local files the cloud doesn't have: a copy first
		b = backups.backup(key, title, "before_download", locs)
		if not b["ok"]:
			return _set_status(key, "too_big" if b["why"] == "too_big" else "backup_failed", str(b["why"]))
	var ts := _gog_ts(key, entry, locs)
	var before := ts.duplicate()
	var step := str({"pre": "pre", "post": "post", "now": ""}[mode])
	var acted := ""
	var conflict := false
	var cloud_newest := 0
	var downloaded: Array = []
	for l in locs:
		var cur := str(ts.get(l["name"], "0"))
		var r := {}
		if mode != "pre":
			# this run may upload, and gogdl's upload deletes cloud files the folder lacks
			var guard := _gog_upload_guard(key, title, plan, entry, l, cur)
			if guard.has("stop"):
				return _set_status(key, "backup_failed", str(guard["stop"]), {"gog_ts": ts})
			r = guard.get("result", {})
		if r.is_empty():
			r = _gogdl(plan, entry, l, cur, step)
		cloud_newest = maxi(cloud_newest, int(r["cloud_newest"]))
		match r["action"]:
			"failed":
				var back := _put_back(key, b) if mode != "post" else ""
				if mode != "post":
					# the backup put every folder back as it was: a location that had downloaded is
					# at its old state again, so its old sync time is the true one (an upload that
					# went through stays through, and keeps its new time)
					for name in downloaded:
						ts[name] = before.get(name, "0")
				return _set_status(key, "offline" if r["offline"] else "failed", str(r["error"]) + back, {"gog_ts": ts})
			"conflict":
				conflict = true
			"upload", "download":
				acted = r["action"] if acted == "" or acted == r["action"] else "both"
				if r["action"] == "download":
					downloaded.append(str(l["name"]))
				if r["ts"] != "":
					ts[l["name"]] = r["ts"]
			"none":
				if r["ts"] != "":
					ts[l["name"]] = r["ts"]
	var local_newest := 0
	for l in locs:
		local_newest = maxi(local_newest, int(CloudSaves.dir_stats(str(l["path"]))["newest"]))
	var times := {"local": local_newest, "remote": cloud_newest, "gog_ts": ts, "gog_paths": _gog_paths(locs)}
	if conflict:
		return _set_status(key, "conflict", "", times)
	var state := str({"upload": "uploaded", "download": "downloaded", "both": "synced", "": "synced"}[acted])
	return _set_status(key, state, "", times.merged({"synced": true}, true))


## Before a run that may upload location `loc`: lists the cloud (gogdl "look") and, when the
## upload would delete cloud files the folder doesn't have, keeps a copy of the cloud first.
## -> {} to go on, {"result": r} when gogdl already did the whole sync during the look (one
## side had no files), {"stop": why} when the copy couldn't be made (then nothing is uploaded).
func _gog_upload_guard(key: String, title: String, plan: Dictionary, entry: Dictionary, loc: Dictionary, ts: String) -> Dictionary:
	var stats := CloudSaves.dir_stats(str(loc["path"]))
	if float(ts) <= 0.0 or int(stats["files"]) == 0:
		return {}   # never synced: gogdl asks when both sides have files; no files: nothing to upload
	if int(stats["newest"]) < int(float(ts)):
		return {}   # nothing changed here since the last sync: gogdl won't upload
	var look := _gogdl(plan, entry, loc, ts, "look")
	if look["action"] in ["failed", "upload", "download"]:
		return {"result": look}
	var only: Variant = CloudSaves.gog_cloud_only(look["cloud_files"], str(loc["name"]), str(loc["path"]))
	if only is Array and only.is_empty():
		return {}
	var why := _gog_cloud_copy(key, title, plan, entry, [loc], false)
	return {} if why == "" else {"stop": why}


func _gogdl(plan: Dictionary, entry: Dictionary, loc: Dictionary, ts: String, step: String) -> Dictionary:
	var args := CloudSaves.gogdl_args(str(plan["auth"]), str(loc["path"]), str(entry.get("id", "")), str(loc["name"]), ts, step)
	var argv := CloudSaves.with_timeout(plan["cmd"], args)
	var r: Dictionary = run.call(argv[0], PackedStringArray(argv.slice(1)))
	return CloudSaves.parse_gogdl(str(r.get("out", "")), int(r.get("code", -1)))


func _resolve(key: String, entry: Dictionary, tools: Dictionary, choice: String) -> Dictionary:
	var title := str(entry.get("title", key))
	match CloudSaves.kind_of(entry):
		"epic":
			var plan := CloudSaves.epic_plan(entry, tools)
			if not plan["ok"]:
				return _set_status(key, str(plan["why"]))
			var app := str(entry.get("id", ""))
			var folder := str(plan["save_path"]) if str(plan["save_path"]) != "" else CloudSaves.epic_save_path(str(entry.get("config_dir", "")), app)
			if choice == "cloud":
				return _epic_download(key, entry, plan, app, {}, "force_download", {"epic_path": folder})
			# Epic keeps the earlier cloud saves next to the new one, so uploading loses nothing there.
			# legendary names the upload by the newest local file's time and every device takes the
			# newest name, so an older save kept on purpose would lose again: its newest file is
			# stamped now (the content isn't touched).
			var newest := CloudSaves.newest_file(folder)
			if newest != "":
				var touched: Dictionary = run.call("touch", PackedStringArray(["-c", "--", newest]))
				if int(touched.get("code", -1)) != 0:
					return _set_status(key, "failed", "couldn't mark this handheld's save as the newest")
			var up := _legendary(plan, app, "force_upload")
			if up["state"] in ["offline", "failed"]:
				return _set_status(key, up["state"], str(up.get("error", "")))
			return _set_status(key, "uploaded", "", {"synced": true, "epic_path": folder})
		"gog":
			var plan := _gog_plan(entry, tools)
			if not plan["ok"]:
				return _set_status(key, str(plan["why"]))
			var locs: Array = plan["locations"]
			var b: Dictionary = backups.backup(key, title, "before_download" if choice == "cloud" else "before_upload", locs, true, true)
			if not b["ok"]:
				return _set_status(key, "too_big" if b["why"] == "too_big" else "backup_failed", str(b["why"]))
			if choice == "local":
				# gogdl's forced upload deletes cloud files this handheld doesn't have: fetch a copy of
				# the cloud into an empty folder and keep it as a backup first
				var cloud := _gog_cloud_copy(key, title, plan, entry, locs, true)
				if cloud != "":
					return _set_status(key, "backup_failed", cloud)
			var ts := _gog_ts(key, entry, locs)
			var before := ts.duplicate()
			for l in locs:
				var r := _gogdl(plan, entry, l, str(ts.get(l["name"], "0")), "force_download" if choice == "cloud" else "force_upload")
				if r["action"] == "failed":
					var back := _put_back(key, b) if choice == "cloud" else ""
					if choice == "cloud":
						ts = before   # every folder is back as it was
					return _set_status(key, "offline" if r["offline"] else "failed", str(r["error"]) + back, {"gog_ts": ts})
				if r["ts"] != "":
					ts[l["name"]] = r["ts"]
			return _set_status(key, "downloaded" if choice == "cloud" else "uploaded", "", {"synced": true, "gog_ts": ts, "gog_paths": _gog_paths(locs)})
	return _set_status(key, "unsupported")


## Downloads every cloud file of each location into a scratch folder and backs that up
## ("cloud copy"). "" when done (or the cloud is empty), else why it couldn't. `again`:
## keep a copy even when the last cloud copy holds the same files.
func _gog_cloud_copy(key: String, title: String, plan: Dictionary, entry: Dictionary, locs: Array, again: bool) -> String:
	var scratch := backup_dir.path_join(".cloud-" + SaveBackup.game_dir_name(key))
	_remove_tree(scratch)
	var parts: Array = []
	for l in locs:
		var dir := scratch.path_join(str(l["name"]).validate_filename())
		DirAccess.make_dir_recursive_absolute(dir)
		var r := _gogdl(plan, entry, {"name": l["name"], "path": dir}, "0", "fetch")
		if r["action"] == "failed":
			_remove_tree(scratch)
			return str(r["error"]) if r["error"] != "" else "couldn't reach GOG"
		# restored into the real folder, should anyone want the cloud's version back
		parts.append({"name": l["name"], "path": dir, "restore_path": l["path"]})
	if not again:
		var fp: String = SaveBackup.fingerprint(parts.filter(func(p): return int(CloudSaves.dir_stats(str(p["path"]))["files"]) > 0))
		for old in backups.list(key):
			if str(old.get("reason", "")) == "cloud_copy":
				if str(old.get("fingerprint", "")) == fp:
					_remove_tree(scratch)
					return ""   # an upload that failed after its copy: the copy is already kept
				break
	var b: Dictionary = backups.backup(key, title, "cloud_copy", parts, true, true)
	if b["ok"] and str(b["id"]) != "":
		_point_parts(key, str(b["id"]), parts)
	_remove_tree(scratch)
	return "" if b["ok"] else str(b["why"])


## A cloud copy is restored into the game's own folders, not the scratch one it came from.
func _point_parts(key: String, id: String, parts: Array) -> void:
	var path: String = backups.dir_for(key).path_join(id + ".json")
	var j: Variant = SettingsFile.load_json(path).get("data")
	if not j is Dictionary:
		return
	for p in j["parts"]:
		for q in parts:
			if str(q["name"]) == str(p["name"]):
				p["path"] = str(q["restore_path"])
	SettingsFile.save_json(path, j, "\t")


static func _remove_tree(path: String) -> void:
	SaveBackup.remove_tree(path)


func _restore(key: String, title: String, id: String) -> Dictionary:
	var b: Dictionary = backups.find(key, id)
	if b.is_empty():
		return {"ok": false, "why": "missing"}
	var parts: Array = []
	for p in b["parts"]:
		parts.append({"name": p["name"], "path": p["path"]})
	var before: Dictionary = backups.backup(key, title, "before_restore", parts, true, true)
	if not before["ok"]:
		return {"ok": false, "why": str(before["why"])}
	var r: Dictionary = backups.restore(key, id)
	if r["ok"]:
		var now: int = clock.call()
		SettingsFile.update_cfg(cfg_path, func(c: ConfigFile): c.set_value(_sec(key), "restored_at", now))
		_set_status(key, "restored", str(b.get("time", 0)))
	return r
