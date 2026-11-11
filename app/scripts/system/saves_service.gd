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
## local, remote, pending ({"backup": id, "empty": [folders]}: a download is replacing the save folders right
## now; still there at the next sync means it was cut off by a crash or power loss and is put
## right first), uploading ({"at", "fp": the folders' fingerprint, "folders"}: an upload is
## going up right now; still there at the next sync means it was cut off and the cloud may hold
## part of it: finished first, see _finish_upload), restored_at (a backup was put back and not synced since), prefer (the side
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
## func(path) -> "<device>:<inode>:<birth>" of a folder, "" when it isn't there (tests swap it). A
## save folder's anchor (CloudSaves.identity_anchor) with another identity than at the last
## sync is a new folder, whatever is in it now.
var folder_id: Callable = func(path: String) -> String: return stat_id(path)

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
	if lib.has_signal("changed"):
		lib.changed.connect(repair_cut_uploads)


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
##  "store", "prefer": "" | "local" (a conflict after a restore: the restored side first),
##  "fresh" (a conflict with no sync time for this folder: nothing says the local save is
##  further on, it may be a blank one), "local_files", "local_bytes", "cloud_files",
##  "cloud_bytes" (both sides of a conflict, -1 when unknown; the cloud's from the copy of it
##  kept when the conflict was found)}. state "off" when the game's switch is off, "disabled" when the global one is.
func status(game: Dictionary) -> Dictionary:
	var key := str(game.get("key", ""))
	var cfg := SettingsFile.load_cfg(cfg_path)
	var sec := _sec(key)
	var st := {"state": str(cfg.get_value(sec, "state", "never")), "at": int(cfg.get_value(sec, "at", 0)),
		"detail": str(cfg.get_value(sec, "detail", "")), "local": int(cfg.get_value(sec, "local", 0)),
		"remote": int(cfg.get_value(sec, "remote", 0)), "last_sync": int(cfg.get_value(sec, "last_sync", 0)),
		"enabled": bool(cfg.get_value(sec, "enabled", true)), "busy": str(_busy.get(key, "")),
		"store": str(game.get("store", "")), "prefer": str(cfg.get_value(sec, "prefer", "")),
		"fresh": bool(cfg.get_value(sec, "fresh", false)), "local_files": int(cfg.get_value(sec, "local_files", -1)),
		"local_bytes": int(cfg.get_value(sec, "local_bytes", -1)), "cloud_files": int(cfg.get_value(sec, "cloud_files", -1)),
		"cloud_bytes": int(cfg.get_value(sec, "cloud_bytes", -1))}
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
	if applies(game):
		folder_guard(key)   # also with sync off or signed out: what's seen now is kept
	if not applies(game) or not enabled(key) or not allowed():
		done.call({"go": true})
		return
	_queue(game, "pre", func(e, t): return _sync(key, e, t, "pre"), func(r: Dictionary) -> void:
		if bool(r.get("conflict", false)):
			done.call({"conflict": status(game)})
		else:
			done.call({"go": true}))


## After the game ended: uploads what it saved. True when an upload job was queued (its
## `finished` with phase "post" follows).
func after_exit(game: Dictionary) -> bool:
	var key := str(game.get("key", ""))
	if applies(game):
		folder_guard(key)
	if not applies(game) or not enabled(key) or not allowed():
		return false
	_queue(game, "post", func(e, t): return _sync(key, e, t, "post"), Callable())
	return true


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
			done.call(status(game).merged({"refused": true}))
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
	var anchors := {}
	if bool(extra.get("synced", false)):
		var folders: Array = []
		if str(extra.get("epic_path", "")) != "":
			folders.append(str(extra["epic_path"]))
		if extra.get("gog_paths") is Dictionary:
			folders.append_array(extra["gog_paths"].values())
		anchors = _anchors_of(folders)
	SettingsFile.update_cfg(cfg_path, func(c: ConfigFile):
		var sec := _sec(key)
		c.set_value(sec, "state", state)
		c.set_value(sec, "at", now)
		c.set_value(sec, "detail", detail)
		c.set_value(sec, "local", int(extra.get("local", 0)))
		c.set_value(sec, "remote", int(extra.get("remote", 0)))
		c.set_value(sec, "prefer", str(extra.get("prefer", "")))
		c.set_value(sec, "fresh", bool(extra.get("fresh", false)))
		for n in ["local_files", "local_bytes", "cloud_files", "cloud_bytes"]:
			c.set_value(sec, n, int(extra.get(n, -1)))
		c.set_value(sec, "local_fp", str(extra.get("local_fp", "")))
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
			c.set_value(sec, "epic_path", str(extra["epic_path"]))
		if bool(extra.get("synced", false)):
			c.set_value(sec, "anchors", anchors)
			# the cloud save's own time as of this sync (Epic), -1 when this step didn't learn it
			c.set_value(sec, "synced_remote", int(extra.get("synced_remote", -1))))
	return {"state": state, "conflict": state == "conflict"}


## Drops the game's sync times (worker or main thread). `create`: also for a game with no
## section yet (so Heroic's times aren't picked up later). True when something was written.
func _drop_sync(key: String, create: bool) -> bool:
	var wrote := [false]
	SettingsFile.update_cfg(cfg_path, func(c: ConfigFile):
		var sec := _sec(key)
		if not c.has_section(sec) and not create:
			return false
		for name in ["gog_ts", "gog_paths", "epic_path", "anchors"]:
			if c.has_section_key(sec, name):
				c.erase_section_key(sec, name)
		c.set_value(sec, "last_sync", 0)
		c.set_value(sec, "own", true)
		wrote[0] = true
		return true)
	return wrote[0]


## The local half of blocker 1, on every path that may upload and at every launch, whether
## sync is on, allowed or signed in or not: a sync time only stands for the folder it was
## made with. A folder the last sync knew that is now empty or gone, or whose anchor (the
## prefix's drive_c) isn't the same folder any more (a deleted and re-made prefix, even one
## the game has written a fresh save into since, played outside GameCove), loses its sync
## time at once, so the next sync sees both sides changed and asks: a blank save never goes
## up over the cloud's on the strength of an old time. Nothing touches the network here.
## True when something was dropped. Main or worker thread.
func folder_guard(key: String) -> bool:
	var cfg := SettingsFile.load_cfg(cfg_path)
	var sec := _sec(key)
	if not cfg.has_section(sec):
		return false
	var anchors: Variant = cfg.get_value(sec, "anchors", {})
	var known: Dictionary = anchors if anchors is Dictionary else {}
	var folders := {}   # path -> GOG location name, "" for Epic's one folder
	var epic := str(cfg.get_value(sec, "epic_path", ""))
	if epic != "" and int(cfg.get_value(sec, "last_sync", 0)) > 0:
		folders[epic] = ""
	var ts: Variant = cfg.get_value(sec, "gog_ts", {})
	var paths: Variant = cfg.get_value(sec, "gog_paths", {})
	if ts is Dictionary and paths is Dictionary:
		for name in paths:
			if str(ts.get(name, "0")) != "0":
				folders[str(paths[name])] = str(name)
	var stale: Array = []
	for path in folders:
		if not CloudSaves.has_files(path):
			stale.append(path)
		elif known.has(path) and str(known[path]) != "" and str(folder_id.call(CloudSaves.identity_anchor(path))) != str(known[path]):
			stale.append(path)
	if stale.is_empty():
		return false
	SettingsFile.update_cfg(cfg_path, func(c: ConfigFile):
		var gts: Variant = c.get_value(sec, "gog_ts", {})
		var new_ts: Dictionary = gts.duplicate() if gts is Dictionary else {}
		var kept: Variant = c.get_value(sec, "anchors", {})
		var new_anchors: Dictionary = kept.duplicate() if kept is Dictionary else {}
		for path in stale:
			if str(folders[path]) != "":
				new_ts[folders[path]] = "0"
			new_anchors.erase(path)
		if c.has_section_key(sec, "gog_ts"):
			c.set_value(sec, "gog_ts", new_ts)
		c.set_value(sec, "anchors", new_anchors)
		c.set_value(sec, "last_sync", 0)
		c.set_value(sec, "own", true))
	if OS.get_thread_caller_id() == OS.get_main_thread_id():
		status_changed.emit(key)
	else:
		call_deferred("_emit_status", key)
	return true


func _emit_status(key: String) -> void:
	status_changed.emit(key)


## {folder: identity of its anchor} for the folders that are there.
func _anchors_of(folders: Array) -> Dictionary:
	var out := {}
	for f in folders:
		var id := str(folder_id.call(CloudSaves.identity_anchor(str(f))))
		if id != "":
			out[str(f)] = id
	return out


## A folder we put back ourselves (a backup restored, the save folder swapped in) keeps
## counting as the folder its sync time is for.
func _refresh_anchors(key: String, folders: Array) -> void:
	var cfg := SettingsFile.load_cfg(cfg_path)
	var kept: Variant = cfg.get_value(_sec(key), "anchors", {})
	if not kept is Dictionary or kept.is_empty():
		return
	var mine: Array = folders.filter(func(f): return kept.has(str(f)))
	if mine.is_empty():
		return
	var fresh := _anchors_of(mine)
	SettingsFile.update_cfg(cfg_path, func(c: ConfigFile):
		var cur: Variant = c.get_value(_sec(key), "anchors", {})
		var d: Dictionary = cur.duplicate() if cur is Dictionary else {}
		for f in fresh:
			d[f] = fresh[f]
		c.set_value(_sec(key), "anchors", d))


## `stat`'s "<device>:<inode>:<birth>" for a folder ("" when it isn't there or stat fails).
## The birth time (0 where the file system doesn't keep one) is there because a deleted
## folder's inode number is often handed straight to the next new one.
static func stat_id(path: String) -> String:
	if path == "" or not DirAccess.dir_exists_absolute(path):
		return ""
	var r := ExecSafe.run("stat", PackedStringArray(["-c", "%d:%i:%W", "--", path]), false)
	var out := str(r.get("out", "")).strip_edges()
	return out if int(r.get("code", -1)) == 0 and out.contains(":") else ""


func _sync(key: String, entry: Dictionary, tools: Dictionary, mode: String) -> Dictionary:
	folder_guard(key)
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
	var cut := _recover(key, str(entry.get("title", key)), [{"name": "saves", "path": str(plan["save_path"])}] if str(plan["save_path"]) != "" else [])
	if cut != "":
		return _set_status(key, "backup_failed", cut)
	var cut_up := _finish_upload(key, entry, plan, _epic_parts(entry, plan, app))
	if not cut_up.is_empty():
		return cut_up
	_epic_folder_check(key, str(plan["save_path"]))
	var look := _legendary(plan, app, "check")
	if look["state"] in ["offline", "failed", "unsupported", "no_path"]:
		return _set_status(key, _plain_state(look["state"]), str(look.get("error", "")))
	# legendary may only now have worked the folder out
	var folder := CloudSaves.epic_save_path(str(entry.get("config_dir", "")), app)
	if look["state"] == "none":
		return _set_status(key, "no_saves", "", {"synced": true, "epic_path": folder})
	if look["state"] == "same":
		return _set_status(key, "synced", "", {"synced": true, "local": look["local"], "remote": look["remote"], "epic_path": folder, "synced_remote": look["remote"]})
	var last := int(_cfg_value(key, "last_sync", 0))
	var times := {"local": look["local"], "remote": look["remote"], "epic_path": folder}
	# a restored backup has its old file times: legendary sees "cloud newer" and would download
	# straight over the restore (final review, high 6)
	var restored := int(_cfg_value(key, "restored_at", 0)) > 0
	match CloudSaves.epic_decide(look, last, mode, restored, int(_cfg_value(key, "synced_remote", -1))):
		"conflict":
			var sides := _conflict_sides(key, entry, plan, [{"name": "saves", "path": str(plan["save_path"]) if str(plan["save_path"]) != "" else folder}])
			sides["fresh"] = last <= 0 and not restored
			return _set_status(key, "conflict", "", times.merged(sides).merged({"prefer": "local"} if restored and look["state"] == "remote_newer" else {}))
		"download":
			return _epic_download(key, entry, plan, app, look, "download", times)
		"upload":
			_mark_upload(key, [{"name": "saves", "path": folder}])
			var up := _legendary(plan, app, "upload")
			if up["state"] in ["offline", "failed"]:
				return _set_status(key, "upload_cut", str(up.get("error", "")), times)
			_clear_upload(key)
			# legendary names the new cloud save by the newest local file's time
			return _set_status(key, "uploaded", "", times.merged({"synced": true, "synced_remote": look["local"]}, true))
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
	var parts := [{"name": "saves", "path": folder}]
	var b: Dictionary = backups.backup(key, title, "before_download", parts, chosen, chosen)
	if not b["ok"]:
		return _set_status(key, "too_big" if b["why"] == "too_big" else "backup_failed", str(b["why"]), times)
	var empty := _mark_download(key, b, parts)
	var down := _legendary(plan, app, step)
	if down["state"] in ["offline", "failed"]:
		var back := _put_back(key, b, empty)
		return _set_status(key, down["state"], str(down.get("error", "")) + back, times)
	_clear_mark(key)
	return _set_status(key, "downloaded", "", times.merged({"synced": true, "synced_remote": int(look.get("remote", -1)) if not look.is_empty() else -1}, true))


## Before a tool may write into the save folders: notes it in the status file (the backup to
## put back and the folders that had no files), so a download cut off by a crash or power
## loss, when none of our code runs, is found and put right by the next sync (_recover).
## -> the folders that are empty now.
func _mark_download(key: String, b: Dictionary, parts: Array) -> Array:
	var empty: Array = []
	for p in parts:
		if int(CloudSaves.dir_stats(str(p["path"]))["files"]) == 0:
			empty.append(str(p["path"]))
	var id := "" if str(b.get("skipped", "")) == "empty" else str(b.get("id", ""))
	SettingsFile.update_cfg(cfg_path, func(c: ConfigFile): c.set_value(_sec(key), "pending", {"backup": id, "empty": empty}))
	return empty


func _clear_mark(key: String) -> void:
	SettingsFile.update_cfg(cfg_path, func(c: ConfigFile):
		if not c.has_section_key(_sec(key), "pending"):
			return false
		c.erase_section_key(_sec(key), "pending")
		return true)


## After a failed download: the backup goes back, and a folder that had no files before
## (`empty`, from _mark_download) is emptied again: everything in it is what the cut
## download wrote, and a half file there would look like a newer local save (final review,
## high 10). Text for the status detail.
func _put_back(key: String, b: Dictionary, empty: Array) -> String:
	for path in empty:
		SaveBackup.empty_dir(str(path))
	var why := ""
	if str(b.get("id", "")) != "" and str(b.get("skipped", "")) != "empty":
		var r: Dictionary = backups.restore(key, str(b["id"]))
		why = "" if r["ok"] else " (" + str(r["why"]) + ")"
		if r["ok"]:
			var put: Array = backups.find(key, str(b["id"])).get("parts", [])
			_refresh_anchors(key, put.map(func(p): return str(p.get("path", ""))))
	if why == "":
		_clear_mark(key)
	return why


## A download that was cut off with no chance to clean up (the note from _mark_download is
## still there): what's in the folders now is kept as a backup first (someone may have
## played since), then the backup from before the download goes back and the folders that
## were empty are emptied. The sync times are dropped, so the sync that follows asks or
## downloads and never uploads on the strength of a half-written file.
## "" when there was nothing to do or it's done, else why it couldn't (then nothing may sync).
func _recover(key: String, title: String, parts: Array) -> String:
	var note: Variant = _cfg_value(key, "pending", {})
	if not note is Dictionary or note.is_empty():
		return ""
	var found: Dictionary = backups.backup(key, title, "interrupted", parts, true, true)
	if not found["ok"]:
		return str(found["why"])
	var mine := {}
	for p in parts:
		mine[str(p["path"])] = true
	for path in note.get("empty", []):
		if mine.has(str(path)):   # only ever this game's own save folders
			SaveBackup.empty_dir(str(path))
	var id := str(note.get("backup", ""))
	if id != "" and not backups.find(key, id).is_empty():
		var r: Dictionary = backups.restore(key, id)
		if not r["ok"]:
			return str(r["why"])
	_drop_sync(key, true)
	_clear_mark(key)
	return ""


## An upload is about to go up (worker thread): noted first, with what the folders hold now,
## so one cut short (the 90 s cap, the app or the power going) is found and finished by the
## next sync before anything else touches the game's saves (review at ff76ca4, medium: a
## cut-off GOG upload left the cloud a mix of new and old files with nothing to finish it).
func _mark_upload(key: String, parts: Array) -> void:
	var note := {"at": int(clock.call()), "fp": SaveBackup.fingerprint(parts), "folders": parts.map(func(p): return str(p["path"]))}
	SettingsFile.update_cfg(cfg_path, func(c: ConfigFile): c.set_value(_sec(key), "uploading", note))


func _clear_upload(key: String) -> void:
	SettingsFile.update_cfg(cfg_path, func(c: ConfigFile):
		if not c.has_section_key(_sec(key), "uploading"):
			return false
		c.erase_section_key(_sec(key), "uploading")
		return true)


## A gogdl run that may upload location `l` with sync time `ts`: there are files and some is
## newer than the time (or there is no time). The same test as _gog_upload_guard's.
static func _gog_may_upload(l: Dictionary, ts: String) -> bool:
	var st := CloudSaves.dir_stats(str(l["path"]))
	return int(st["files"]) > 0 and (float(ts) <= 0.0 or int(st["newest"]) >= int(float(ts)))


## The game's save folders as a sync sees them ([] when there is no plan).
func _local_parts(entry: Dictionary, tools: Dictionary) -> Array:
	if CloudSaves.kind_of(entry) == "epic":
		var plan := CloudSaves.epic_plan(entry, tools)
		return _epic_parts(entry, plan, str(entry.get("id", ""))) if plan["ok"] else []
	var client := CloudSaves.gog_client_id(str(entry.get("install_path", "")), str(entry.get("id", "")))
	var cached: Variant = SettingsFile.load_cfg(cfg_path).get_value("gog_remote", client, null) if client != "" else null
	var gp := CloudSaves.gog_plan(entry, tools, cached)
	return gp["locations"] if gp["ok"] else []


func _epic_parts(entry: Dictionary, plan: Dictionary, app: String) -> Array:
	var folder := str(plan.get("save_path", ""))
	if folder == "":
		folder = CloudSaves.epic_save_path(str(entry.get("config_dir", "")), app)
	return [{"name": "saves", "path": folder}] if folder != "" else []


## An upload of this game was cut short (its note from _mark_upload is still there): the cloud
## may hold part of it. Before anything else syncs:
##  - the folders are as they were then: the upload is finished (a forced one, so every file
##    goes up and the cloud ends up exactly this handheld's save), after a copy of the cloud
##    as it is now is kept. Not reachable: nothing else syncs for this game ("upload_cut"),
##    the game still starts, and the next sync tries again;
##  - they changed since (played from Heroic, a restore): finishing would mix it again, so a
##    copy of the cloud is kept, the sync times are dropped and the sync goes on: it asks.
## -> {} to go on, else the status dictionary this sync ends with.
func _finish_upload(key: String, entry: Dictionary, plan: Dictionary, parts: Array) -> Dictionary:
	var note: Variant = _cfg_value(key, "uploading", {})
	if not note is Dictionary or note.is_empty():
		return {}
	var title := str(entry.get("title", key))
	var epic := CloudSaves.kind_of(entry) == "epic"
	var app := str(entry.get("id", ""))
	var same: bool = SaveBackup.fingerprint(parts) == str(note.get("fp", "")) \
			and parts.map(func(p): return str(p["path"])) == Array(note.get("folders", []))
	var why := ""
	if epic:
		why = str(_epic_cloud_copy(key, title, entry, plan, app, str(parts[0]["path"]) if not parts.is_empty() else "")["why"])
	else:
		why = _gog_cloud_copy(key, title, plan, entry, parts, false)
	if not same:
		if why != "":
			return _set_status(key, "upload_cut", why)   # not even a copy of the mixed cloud: wait
		_drop_sync(key, true)
		_clear_upload(key)
		return {}
	if why != "":
		return _set_status(key, "upload_cut", why)
	if epic:
		var up := _legendary(plan, app, "force_upload")
		if up["state"] in ["offline", "failed"]:
			return _set_status(key, "upload_cut", str(up.get("error", "")))
		_clear_upload(key)
		return _set_status(key, "upload_finished", "", {"synced": true, "epic_path": str(parts[0]["path"]) if not parts.is_empty() else ""})
	var ts := _gog_ts(key, entry, parts)
	for l in parts:
		var r := _gogdl(plan, entry, l, str(ts.get(l["name"], "0")), "force_upload")
		if r["action"] == "failed":
			return _set_status(key, "upload_cut", str(r["error"]), {"gog_ts": ts})
		if r["ts"] != "":
			ts[l["name"]] = r["ts"]
	_clear_upload(key)
	return _set_status(key, "upload_finished", "", {"synced": true, "gog_ts": ts, "gog_paths": _gog_paths(parts)})


## Games whose last upload was cut short, looked at once the Library knows them (its
## `changed`), never while a game runs: each gets a "repair" job that finishes it
## (_finish_upload) and says so, so the player hears about it at the next start, not only
## at the game's next launch. Once per game and run.
var _repair_tried := {}


func repair_cut_uploads() -> void:
	if not allowed() or game_running.call():
		return
	var cfg := SettingsFile.load_cfg(cfg_path)
	for sec in cfg.get_sections():
		if not sec.begins_with("game:") or not cfg.has_section_key(sec, "uploading"):
			continue
		var key := sec.trim_prefix("game:")
		if _repair_tried.has(key) or busy(key) or not enabled(key):
			continue
		var entry: Dictionary = entry_lookup.call(key)
		if entry.is_empty() or not applies(entry):
			continue
		_repair_tried[key] = true
		_queue(entry, "repair", func(e, t): return _repair(key, e, t), Callable())


func _repair(key: String, entry: Dictionary, tools: Dictionary) -> Dictionary:
	var plan: Dictionary = CloudSaves.epic_plan(entry, tools) if CloudSaves.kind_of(entry) == "epic" else _gog_plan(entry, tools)
	if not plan["ok"]:
		return _set_status(key, "upload_cut", str(plan["why"]))
	var parts: Array = _epic_parts(entry, plan, str(entry.get("id", ""))) if CloudSaves.kind_of(entry) == "epic" else plan["locations"]
	var r := _finish_upload(key, entry, plan, parts)
	if r.is_empty():
		# changed here since: the sync that follows asks
		return _sync(key, entry, tools, "now")
	return r


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
	var cut := _recover(key, title, locs)
	if cut != "":
		return _set_status(key, "backup_failed", cut)
	var cut_up := _finish_upload(key, entry, plan, locs)
	if not cut_up.is_empty():
		return cut_up
	var b := {"ok": true, "id": "", "skipped": "empty"}
	if mode != "post":
		# gogdl's download deletes local files the cloud doesn't have: a copy first
		b = backups.backup(key, title, "before_download", locs)
		if not b["ok"]:
			return _set_status(key, "too_big" if b["why"] == "too_big" else "backup_failed", str(b["why"]))
	var ts := _gog_ts(key, entry, locs)
	var before := ts.duplicate()
	if int(_cfg_value(key, "restored_at", 0)) > 0:
		return _gog_after_restore(key, title, plan, entry, locs, ts, mode)
	# gogdl downloads into an empty folder whatever it was asked (after a game too)
	var empty := _mark_download(key, b, locs)
	var step := str({"pre": "pre", "post": "post", "now": ""}[mode])
	var acted := ""
	var conflict := false
	var cloud_newest := 0
	var downloaded: Array = []
	var waiting := ""
	var marked := false
	for l in locs:
		var cur := str(ts.get(l["name"], "0"))
		var r := {}
		if mode != "pre":
			if not marked and _gog_may_upload(l, cur):
				_mark_upload(key, locs)   # an upload cut short is finished at the next sync
				marked = true
			# this run may upload, and gogdl's upload deletes cloud files the folder lacks
			var guard := _gog_upload_guard(key, title, plan, entry, l, cur)
			if guard.has("stop"):
				_clear_mark(key)
				_clear_upload(key)   # held before it began
				return _set_status(key, "backup_failed", str(guard["stop"]), {"gog_ts": ts})
			r = guard.get("result", {})
		if r.is_empty():
			r = _gogdl(plan, entry, l, cur, step)
		cloud_newest = maxi(cloud_newest, int(r["cloud_newest"]))
		match r["action"]:
			"failed":
				# after a game no backup was taken (an upload changes nothing here), but a folder that
				# was empty may have been half filled
				var back := _put_back(key, b if mode != "post" else {}, empty)
				for l2 in locs:
					if str(l2["path"]) in empty:
						ts[l2["name"]] = "0"
				if mode != "post":
					# the backup put every folder back as it was: a location that had downloaded is
					# at its old state again, so its old sync time is the true one (an upload that
					# went through stays through, and keeps its new time)
					for name in downloaded:
						ts[name] = before.get(name, "0")
				# an upload may have been under way: the cloud may hold part of it (finished next time)
				var failed_state := "upload_cut" if marked else ("offline" if r["offline"] else "failed")
				return _set_status(key, failed_state, str(r["error"]) + back, {"gog_ts": ts})
			"conflict":
				conflict = true
			"upload", "download":
				acted = r["action"] if acted == "" or acted == r["action"] else "both"
				if r["action"] == "download":
					downloaded.append(str(l["name"]))
				if r["ts"] != "":
					ts[l["name"]] = r["ts"]
			"refused":
				# the other side is newer and this run could only go one way: nothing happened,
				# the sync time stays, and the status says which way is waiting
				waiting = "pending_down" if r["refused"] == "upload" else "pending_up"
			"none":
				if r["ts"] != "":
					ts[l["name"]] = r["ts"]
	var local_newest := 0
	for l in locs:
		local_newest = maxi(local_newest, int(CloudSaves.dir_stats(str(l["path"]))["newest"]))
	_clear_mark(key)
	_clear_upload(key)
	var times := {"local": local_newest, "remote": cloud_newest, "gog_ts": ts, "gog_paths": _gog_paths(locs)}
	if conflict:
		var sides := _conflict_sides(key, entry, plan, locs)
		sides["fresh"] = before.values().has("0") or before.size() < locs.size()
		return _set_status(key, "conflict", "", times.merged(sides))
	if waiting != "":
		return _set_status(key, waiting, "", times)
	var state := str({"upload": "uploaded", "download": "downloaded", "both": "synced", "": "synced"}[acted])
	return _set_status(key, state, "", times.merged({"synced": true}, true))


## A backup was put back and not synced since (review at ff76ca4: high 6 was only fixed for
## Epic). gogdl decides by file times, and a restored backup's files carry their old ones:
## with the cloud changed since the last sync it would download straight over the restore,
## and with the cloud unchanged it would see nothing to do and never send the restore up.
## So: the cloud is listed (gogdl's look). Changed since the last sync (or never synced):
## a conflict with the restored save offered first. Unchanged: the restore goes up, the
## whole of it (a forced upload, after a copy of the cloud: it deletes what the restore
## lacks), right away when this run may upload, else after the game.
func _gog_after_restore(key: String, title: String, plan: Dictionary, entry: Dictionary, locs: Array, ts: Dictionary, mode: String) -> Dictionary:
	var changed := false
	var cloud_newest := 0
	for l in locs:
		var cur := str(ts.get(l["name"], "0"))
		var look := _gogdl(plan, entry, l, cur, "look")
		if look["action"] == "failed":
			return _set_status(key, "offline" if look["offline"] else "failed", str(look["error"]), {"gog_ts": ts})
		cloud_newest = maxi(cloud_newest, int(look["cloud_newest"]))
		if look["action"] in ["upload", "download"]:
			# one side had no files: gogdl already did the whole sync of this location
			if look["ts"] != "":
				ts[l["name"]] = look["ts"]
			continue
		if float(cur) <= 0.0 or int(look["cloud_newest"]) > int(float(cur)) + CloudSaves.SLACK_S:
			changed = true
	var local_newest := 0
	for l in locs:
		local_newest = maxi(local_newest, int(CloudSaves.dir_stats(str(l["path"]))["newest"]))
	var times := {"local": local_newest, "remote": cloud_newest, "gog_ts": ts, "gog_paths": _gog_paths(locs)}
	if changed:
		var sides := _conflict_sides(key, entry, plan, locs)
		return _set_status(key, "conflict", "", times.merged(sides).merged({"prefer": "local"}))
	if mode == "pre":
		return _set_status(key, "pending_up", "", times)
	var why := _gog_cloud_copy(key, title, plan, entry, locs, false)
	if why != "":
		return _set_status(key, "backup_failed", why, times)
	_mark_upload(key, locs)
	for l in locs:
		var r := _gogdl(plan, entry, l, str(ts.get(l["name"], "0")), "force_upload")
		if r["action"] == "failed":
			return _set_status(key, "upload_cut", str(r["error"]), {"gog_ts": ts})
		if r["ts"] != "":
			ts[l["name"]] = r["ts"]
	_clear_upload(key)
	return _set_status(key, "uploaded", "", times.merged({"synced": true, "gog_ts": ts}, true))


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
	# the sheet showed the save as it was when the conflict was found; if it changed since
	# (played from Heroic, a restore), the choice was made on something that isn't there any
	# more: look again instead (review at ff76ca4, L5). The caller sees a conflict again.
	var seen := str(_cfg_value(key, "local_fp", ""))
	if seen != "" and _local_parts(entry, tools).size() > 0 and SaveBackup.fingerprint(_local_parts(entry, tools)) != seen:
		return _sync(key, entry, tools, "now")
	match CloudSaves.kind_of(entry):
		"epic":
			var plan := CloudSaves.epic_plan(entry, tools)
			if not plan["ok"]:
				return _set_status(key, str(plan["why"]))
			var app := str(entry.get("id", ""))
			var folder := str(plan["save_path"]) if str(plan["save_path"]) != "" else CloudSaves.epic_save_path(str(entry.get("config_dir", "")), app)
			var cut := _recover(key, title, [{"name": "saves", "path": folder}] if folder != "" else [])
			if cut != "":
				return _set_status(key, "backup_failed", cut)
			if choice == "cloud":
				_clear_upload(key)   # the user chose the cloud's save: nothing of ours is left to finish
				return _epic_download(key, entry, plan, app, {}, "force_download", {"epic_path": folder})
			# Epic keeps the earlier cloud saves next to the new one, but nothing here could put
			# one back: the cloud's save is fetched and kept as a backup first (no copy, no upload).
			var copy := _epic_cloud_copy(key, title, entry, plan, app, folder)
			if str(copy["why"]) != "":
				return _set_status(key, "backup_failed", str(copy["why"]))
			# legendary names the upload by the newest local file's time and every device takes the
			# newest name, so an older save kept on purpose would lose again: its newest file is
			# stamped now (the content isn't touched).
			var newest := CloudSaves.newest_file(folder)
			if newest != "":
				var touched: Dictionary = run.call("touch", PackedStringArray(["-c", "--", newest]))
				if int(touched.get("code", -1)) != 0:
					return _set_status(key, "failed", "couldn't mark this handheld's save as the newest")
			_mark_upload(key, [{"name": "saves", "path": folder}])
			var up := _legendary(plan, app, "force_upload")
			if up["state"] in ["offline", "failed"]:
				return _set_status(key, "upload_cut", str(up.get("error", "")))
			_clear_upload(key)
			return _set_status(key, "uploaded", "", {"synced": true, "epic_path": folder})
		"gog":
			var plan := _gog_plan(entry, tools)
			if not plan["ok"]:
				return _set_status(key, str(plan["why"]))
			var locs: Array = plan["locations"]
			var cut := _recover(key, title, locs)
			if cut != "":
				return _set_status(key, "backup_failed", cut)
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
			var empty: Array = _mark_download(key, b, locs) if choice == "cloud" else []
			if choice == "local":
				_mark_upload(key, locs)
			for l in locs:
				var r := _gogdl(plan, entry, l, str(ts.get(l["name"], "0")), "force_download" if choice == "cloud" else "force_upload")
				if r["action"] == "failed":
					var back := _put_back(key, b, empty) if choice == "cloud" else ""
					if choice == "cloud":
						ts = before   # every folder is back as it was
					var failed_state := "upload_cut" if choice == "local" else ("offline" if r["offline"] else "failed")
					return _set_status(key, failed_state, str(r["error"]) + back, {"gog_ts": ts})
				if r["ts"] != "":
					ts[l["name"]] = r["ts"]
			_clear_mark(key)
			_clear_upload(key)
			return _set_status(key, "downloaded" if choice == "cloud" else "uploaded", "", {"synced": true, "gog_ts": ts, "gog_paths": _gog_paths(locs)})
	return _set_status(key, "unsupported")


## A conflict was found: what each side holds, so the sheet can tell a near-empty save from a
## real one, and a copy of the cloud's save kept as a backup right away (before any choice can
## replace it). The copy failing (offline) leaves the cloud's side unknown; the choice itself
## takes its own copy again before it uploads.
func _conflict_sides(key: String, entry: Dictionary, plan: Dictionary, locs: Array) -> Dictionary:
	var out := {"local_files": 0, "local_bytes": 0, "cloud_files": -1, "cloud_bytes": -1, "local_fp": SaveBackup.fingerprint(locs)}
	for l in locs:
		var st := CloudSaves.dir_stats(str(l["path"]))
		out["local_files"] += int(st["files"])
		out["local_bytes"] += int(st["bytes"])
	var title := str(entry.get("title", key))
	var copy := {}
	match CloudSaves.kind_of(entry):
		"epic":
			copy = _epic_cloud_copy(key, title, entry, plan, str(entry.get("id", "")), str(locs[0]["path"]) if not locs.is_empty() else "")
		"gog":
			var stats := {}
			copy = {"why": _gog_cloud_copy(key, title, plan, entry, locs, false, stats)}
			copy.merge(stats)
	if str(copy.get("why", "x")) == "":
		out["cloud_files"] = int(copy.get("files", 0))
		out["cloud_bytes"] = int(copy.get("bytes", 0))
	return out


## Epic's newest cloud save fetched into a scratch folder and kept as a backup ("cloud
## copy", restored into the game's own folder `folder`). legendary only downloads into the
## save folder it keeps for the game, so it runs on a private copy of its config folder whose
## installed.json names the scratch folder: the user's own legendary files never point
## anywhere else, even if this is cut off. The sign-in (user.json) is copied, 0600, and gone
## afterwards; should legendary refresh it meanwhile, the fresh one goes back to the user's
## folder (unless something else changed that one), as legendary would have written it there.
## -> {"why": "" when done (also when the cloud has no save), "files", "bytes"}.
func _epic_cloud_copy(key: String, title: String, entry: Dictionary, plan: Dictionary, app: String, folder: String) -> Dictionary:
	var cfg := str(entry.get("config_dir", ""))
	var name := SaveBackup.game_dir_name(key)
	var scratch := backup_dir.path_join(".cloud-" + name)
	var tmp := backup_dir.path_join(".legendary-" + name)
	_remove_tree(scratch)
	_remove_tree(tmp)
	if DirAccess.make_dir_recursive_absolute(tmp.path_join("metadata")) != OK or DirAccess.make_dir_recursive_absolute(scratch) != OK:
		return _copy_failed(scratch, tmp, "couldn't make a scratch folder")
	FileAccess.set_unix_permissions(tmp, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER | FileAccess.UNIX_EXECUTE_OWNER)
	var user := FileAccess.get_file_as_string(cfg.path_join("user.json"))
	if user == "":
		return _copy_failed(scratch, tmp, "signed out")
	var inst: Variant = SettingsFile.load_json(cfg.path_join("installed.json")).get("data")
	var mine: Dictionary = inst.get(app, {}).duplicate() if inst is Dictionary and inst.get(app) is Dictionary else {}
	mine["save_path"] = scratch
	var wrote := SettingsFile.save_text(tmp.path_join("user.json"), user, true) == OK
	wrote = wrote and SettingsFile.save_json(tmp.path_join("installed.json"), {app: mine}) == OK
	for f in ["metadata/%s.json" % app, "config.ini"]:
		if wrote and FileAccess.file_exists(cfg.path_join(f)):
			wrote = SettingsFile.save_bytes(tmp.path_join(f), FileAccess.get_file_as_bytes(cfg.path_join(f))) == OK
	if not wrote:
		return _copy_failed(scratch, tmp, "couldn't copy legendary's settings")
	var cmd: Array = []
	for c in plan["cmd"]:
		var a := str(c)
		if a == "LEGENDARY_CONFIG_PATH=" + cfg:
			a = "LEGENDARY_CONFIG_PATH=" + tmp
		elif a == "--env=LEGENDARY_CONFIG_PATH=" + cfg:
			a = "--env=LEGENDARY_CONFIG_PATH=" + tmp
		cmd.append(a)
	var argv := CloudSaves.with_timeout(cmd, CloudSaves.legendary_args(app, "force_download"))
	var r: Dictionary = run.call(argv[0], PackedStringArray(argv.slice(1)))
	var got := CloudSaves.parse_legendary(str(r.get("out", "")), int(r.get("code", -1)))
	var renewed := FileAccess.get_file_as_string(tmp.path_join("user.json"))
	if renewed != "" and renewed != user and FileAccess.get_file_as_string(cfg.path_join("user.json")) == user:
		SettingsFile.save_text(cfg.path_join("user.json"), renewed, true)
	if got["state"] in ["offline", "failed"]:
		return _copy_failed(scratch, tmp, str(got["error"]) if str(got["error"]) != "" else "couldn't reach Epic")
	var st := CloudSaves.dir_stats(scratch)
	var parts := [{"name": "saves", "path": scratch, "restore_path": folder}]
	var b: Dictionary = backups.backup(key, title, "cloud_copy", parts, true, true)
	if b["ok"] and str(b["id"]) != "" and folder != "":
		_point_parts(key, str(b["id"]), parts)
	_remove_tree(scratch)
	_remove_tree(tmp)
	return {"why": "" if b["ok"] else str(b["why"]), "files": int(st["files"]), "bytes": int(st["bytes"])}


static func _copy_failed(scratch: String, tmp: String, why: String) -> Dictionary:
	_remove_tree(scratch)
	_remove_tree(tmp)
	return {"why": why, "files": 0, "bytes": 0}


## Downloads every cloud file of each location into a scratch folder and backs that up
## ("cloud copy"). "" when done (or the cloud is empty), else why it couldn't. `again`:
## keep a copy even when the last cloud copy holds the same files.
func _gog_cloud_copy(key: String, title: String, plan: Dictionary, entry: Dictionary, locs: Array, again: bool, stats := {}) -> String:
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
		var st := CloudSaves.dir_stats(dir)
		stats["files"] = int(stats.get("files", 0)) + int(st["files"])
		stats["bytes"] = int(stats.get("bytes", 0)) + int(st["bytes"])
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
		_refresh_anchors(key, parts.map(func(p): return str(p["path"])))
		var now: int = clock.call()
		SettingsFile.update_cfg(cfg_path, func(c: ConfigFile): c.set_value(_sec(key), "restored_at", now))
		_set_status(key, "restored", str(b.get("time", 0)))
	return r
