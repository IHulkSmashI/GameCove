extends "res://tests/test_case.gd"
## Cloud saves around a launch (scripts/system/saves_service.gd), with legendary and gogdl
## faked and the real tar for backups, all under user://. Checks that a newer cloud save
## comes down only after a local backup, that a conflict stops and asks, that a failed
## download puts the backup back, that offline still launches, that the switches stop
## everything, and that GOG's timestamps are only kept when a sync really happened.

const Service := preload("res://scripts/system/saves_service.gd")
const ExecSafe := preload("res://scripts/system/exec_safe.gd")
const BASE := "user://test_saves_service"

const CHECK_REMOTE := "[cli] INFO: Checking \"Min\" (Min)\n[cli] INFO: Cloud save for \"Min\" is newer:\n[cli] INFO: - Cloud save date: %s\n[cli] INFO: - Local save date: %s\n"
const CHECK_LOCAL := "[cli] INFO: Checking \"Min\" (Min)\n[cli] INFO: Local save for \"Min\" is newer\n[cli] INFO: - Cloud save date: %s\n[cli] INFO: - Local save date: %s\n"


func _rm(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.include_hidden = true
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	for sub in d.get_directories():
		_rm(path.path_join(sub))
	DirAccess.remove_absolute(path)


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


static func _utc(t: int) -> String:
	return Time.get_datetime_string_from_unix_time(t, true)


## A world: an Epic and a GOG game, their folders, and a service whose tools are `handler`
## (func(tool: String, args: Array) -> {"code", "out"}); tar is real.
func _world(name: String) -> Dictionary:
	var root := ProjectSettings.globalize_path(BASE).path_join(name)
	_rm(root)
	var saves := root.path_join("saves/Min")
	var cfg := root.path_join("legendary")
	_write(cfg.path_join("user.json"), "{}")
	_write(cfg.path_join("metadata/Min.json"), JSON.stringify({"metadata": {"customAttributes": {"CloudSaveFolder": {"value": "{InstallDir}/save"}}}}))
	_write(cfg.path_join("installed.json"), JSON.stringify({"Min": {"save_path": saves}}))
	_write(saves.path_join("slot1.sav"), "local progress")
	var heroic := root.path_join("heroic")
	var gsaves := root.path_join("gog/saves")
	_write(heroic.path_join("gog_store/auth.json"), "{}")
	_write(heroic.path_join("GamesConfig/1207.json"), JSON.stringify({"1207": {"gogSaves": [{"name": "__default", "location": gsaves}]}}))
	_write(gsaves.path_join("save0.dat"), "gog local")
	var epic := {"key": "epic:Min", "store": "epic", "id": "Min", "title": "Minecraft Dungeons", "installed": true, "config_dir": cfg,
		"platform": "Windows", "prefix": ""}
	var gog := {"key": "gog:1207", "store": "gog", "id": "1207", "title": "The Witcher", "installed": true, "heroic_root": heroic,
		"install_path": root.path_join("gog/game"), "prefix": "", "platform": "windows"}
	var w := {"root": root, "saves": saves, "gsaves": gsaves, "epic": epic, "gog": gog, "calls": [], "now": [2000000000]}
	var s: Node = Service.new()
	s.cfg_path = root.path_join("saves.cfg")
	s.privacy_path = root.path_join("settings.cfg")
	s.backup_dir = root.path_join("backups")
	s.backups.base_dir = s.backup_dir
	s.clock = func() -> int: return int(w["now"][0])
	var entries := {"epic:Min": epic, "gog:1207": gog}
	s.entry_lookup = func(k: String) -> Dictionary: return entries.get(k, {}).duplicate()
	s.tools_lookup = func() -> Dictionary: return {"legendary": "/bin/legendary", "gogdl": "/bin/gogdl", "heroic_flatpak": []}
	w["handler"] = func(_tool: String, _args: Array) -> Dictionary: return {"code": 0, "out": ""}
	s.run = func(program: String, args: PackedStringArray) -> Dictionary:
		if program == "tar":
			return ExecSafe.run("tar", args)
		var a := Array(args)
		# timeout -k 5 90 env ... /bin/tool args
		var i := a.find("/bin/legendary")
		var tool := "legendary"
		if i < 0:
			i = a.find("/bin/gogdl")
			tool = "gogdl"
		if i < 0:
			tool = program
		var rest: Array = a.slice(i + 1) if i >= 0 else a
		w["calls"].append(tool + " " + " ".join(PackedStringArray(rest)))
		return w["handler"].call(tool, rest)
	w["s"] = s
	return w


func _done(w: Dictionary) -> void:
	w["s"].free()
	_rm(w["root"])
	w.clear()   # the fake tools hold the world: break the loop


func _set_last_sync(w: Dictionary, key: String, t: int) -> void:
	var cfg := ConfigFile.new()
	cfg.load(w["s"].cfg_path)
	cfg.set_value("game:" + key, "last_sync", t)
	cfg.save(w["s"].cfg_path)


func test_newer_cloud_save_comes_down_after_a_backup() -> void:
	var w := _world("download")
	var last := 1999990000
	_set_last_sync(w, "epic:Min", last)
	var backed_up_before := [false]
	w["handler"] = func(tool: String, args: Array) -> Dictionary:
		if tool == "legendary" and "--skip-download" in args and "--skip-upload" in args:
			return {"code": 0, "out": CHECK_REMOTE % [_utc(last + 5000), _utc(last - 100)]}
		if tool == "legendary" and "--skip-upload" in args:
			backed_up_before[0] = w["s"].backup_list("epic:Min").size() == 1
			_write(w["saves"].path_join("slot1.sav"), "cloud progress")
			return {"code": 0, "out": "[cli] INFO: Downloading remote savegame...\n"}
		return {"code": 1, "out": "unexpected"}
	var got := []
	w["s"].before_launch(w["epic"], func(r): got.append(r))
	eq(got, [{"go": true}], "the game starts after the download")
	ok(backed_up_before[0], "a backup existed before legendary downloaded (its download empties the folder)")
	var b: Array = w["s"].backup_list("epic:Min")
	eq(b.size(), 1, "one backup")
	eq(b[0]["reason"], "before_download", "made before the download")
	var st: Dictionary = w["s"].status(w["epic"])
	eq(st["state"], "downloaded", "status: downloaded")
	eq(st["last_sync"], 2000000000, "last sync moved")
	eq(FileAccess.get_file_as_string(w["saves"].path_join("slot1.sav")), "cloud progress", "the cloud save is in place")
	# the backup really holds the old save
	var r: Dictionary = w["s"].backups.restore("epic:Min", str(b[0]["id"]))
	ok(r["ok"], "restorable")
	eq(FileAccess.get_file_as_string(w["saves"].path_join("slot1.sav")), "local progress", "the backup had the local save")
	_done(w)


func test_changes_on_both_sides_stop_and_ask() -> void:
	var w := _world("conflict")
	var last := 1999990000
	_set_last_sync(w, "epic:Min", last)
	w["handler"] = func(tool: String, args: Array) -> Dictionary:
		if tool == "legendary" and "--skip-download" in args and "--skip-upload" in args:
			return {"code": 0, "out": CHECK_REMOTE % [_utc(last + 5000), _utc(last + 3000)]}
		return {"code": 1, "out": "nothing else may run"}
	var got := []
	var conflicts := []
	w["s"].conflict_found.connect(func(k): conflicts.append(k))
	w["s"].before_launch(w["epic"], func(r): got.append(r))
	ok(got.size() == 1 and got[0].has("conflict"), "the launch waits for a choice")
	eq(got[0]["conflict"]["remote"], last + 5000, "cloud time for the prompt")
	eq(got[0]["conflict"]["local"], last + 3000, "local time for the prompt")
	eq(w["calls"].size(), 1, "only the look ran: nothing downloaded or uploaded")
	eq(conflicts, ["epic:Min"], "conflict_found")
	eq(FileAccess.get_file_as_string(w["saves"].path_join("slot1.sav")), "local progress", "local save untouched")
	# keep the cloud: local backed up, forced download
	w["handler"] = func(tool: String, args: Array) -> Dictionary:
		if tool == "legendary" and "--force-download" in args:
			_write(w["saves"].path_join("slot1.sav"), "cloud progress")
			return {"code": 0, "out": ""}
		return {"code": 1, "out": ""}
	w["s"].resolve(w["epic"], "cloud")
	eq(w["s"].status(w["epic"])["state"], "downloaded", "kept the cloud")
	eq(w["s"].backup_list("epic:Min").size(), 1, "the local save was backed up first")
	# keep local: forced upload
	w["handler"] = func(tool: String, args: Array) -> Dictionary:
		return {"code": 0, "out": ""} if tool == "legendary" and "--force-upload" in args else {"code": 1, "out": ""}
	w["s"].resolve(w["epic"], "local")
	eq(w["s"].status(w["epic"])["state"], "uploaded", "kept this handheld's")
	_done(w)


func test_a_failed_download_puts_the_backup_back() -> void:
	var w := _world("failed")
	var last := 1999990000
	_set_last_sync(w, "epic:Min", last)
	w["handler"] = func(tool: String, args: Array) -> Dictionary:
		if tool == "legendary" and "--skip-download" in args and "--skip-upload" in args:
			return {"code": 0, "out": CHECK_REMOTE % [_utc(last + 5000), _utc(last - 100)]}
		if tool == "legendary":
			DirAccess.remove_absolute(w["saves"].path_join("slot1.sav"))   # legendary empties the folder first
			return {"code": 0, "out": "[cli] INFO: Deleting old save files...\n[Core] ERROR: Download failed, status code: 503\n"}
		return {"code": 1, "out": ""}
	var got := []
	w["s"].before_launch(w["epic"], func(r): got.append(r))
	eq(got, [{"go": true}], "the game still starts")
	eq(w["s"].status(w["epic"])["state"], "failed", "status: failed")
	eq(FileAccess.get_file_as_string(w["saves"].path_join("slot1.sav")), "local progress", "the local save is back")
	_done(w)


func test_offline_still_launches_and_after_play_uploads() -> void:
	var w := _world("offline")
	w["handler"] = func(_tool: String, _args: Array) -> Dictionary:
		return {"code": 1, "out": "[cli] ERROR: Login failed! Cannot continue with download process.\n"}
	var got := []
	w["s"].before_launch(w["epic"], func(r): got.append(r))
	eq(got, [{"go": true}], "offline: plays anyway")
	eq(w["s"].status(w["epic"])["state"], "offline", "status says so")
	eq(w["s"].backup_list("epic:Min").size(), 0, "nothing touched")
	var last := 1999990000
	_set_last_sync(w, "epic:Min", last)
	w["handler"] = func(tool: String, args: Array) -> Dictionary:
		if "--skip-download" in args and "--skip-upload" in args:
			return {"code": 0, "out": CHECK_LOCAL % [_utc(last - 50), _utc(last + 900)]}
		if tool == "legendary" and "--skip-download" in args:
			return {"code": 0, "out": "[cli] INFO: Uploading local savegame...\n"}
		return {"code": 1, "out": ""}
	var done := []
	w["s"].finished.connect(func(k, p, s): done.append([k, p, s]))
	w["s"].after_exit(w["epic"])
	eq(done, [["epic:Min", "post", "uploaded"]], "uploaded after play")
	ok(w["calls"][-1].contains("--skip-download") and not w["calls"][-1].contains("--force"), "a plain upload")
	_done(w)


func test_switches_stop_everything() -> void:
	var w := _world("switches")
	w["s"].set_enabled("epic:Min", false)
	var got := []
	w["s"].before_launch(w["epic"], func(r): got.append(r))
	w["s"].after_exit(w["epic"])
	eq(got, [{"go": true}], "off for the game: starts at once")
	eq(w["calls"], [], "no tool ran")
	eq(w["s"].status(w["epic"])["state"], "off", "status: off")
	w["s"].set_enabled("epic:Min", true)
	w["s"].set_allowed(false)
	w["s"].before_launch(w["epic"], func(r): got.append(r))
	w["s"].sync_now(w["epic"])
	eq(w["calls"], [], "the privacy switch off: no tool ran")
	eq(w["s"].status(w["epic"])["state"], "disabled", "status: off for all")
	ok(not w["s"].applies({"store": "amazon", "installed": true}), "Amazon isn't synced")
	ok(not w["s"].applies({"store": "steam", "installed": true}), "Steam has its own cloud")
	_done(w)


func test_gog_keeps_timestamps_only_after_a_real_sync() -> void:
	var w := _world("gog")
	w["handler"] = func(tool: String, args: Array) -> Dictionary:
		if tool == "gogdl" and "--skip-upload" in args:
			return {"code": 0, "out": "[SAVES] WARNING: Files in conflict force downloading or uploading of files\n1762799999.5"}
		return {"code": 1, "out": ""}
	var got := []
	w["s"].before_launch(w["gog"], func(r): got.append(r))
	ok(got[0].has("conflict"), "gogdl's conflict stops the launch for a choice")
	ok(w["calls"][0].contains("--ts 0") and w["calls"][0].contains("--name __default"), "never synced: --ts 0")
	var cfg := ConfigFile.new()
	cfg.load(w["s"].cfg_path)
	eq(cfg.get_value("game:gog:1207", "gog_ts", {}).get("__default", ""), "", "the fresh timestamp printed on a conflict isn't kept")
	eq(w["s"].backup_list("gog:1207").size(), 1, "backed up before gogdl could download")
	# keep this handheld's: the cloud is fetched into a scratch folder and backed up, then forced upload
	w["handler"] = func(tool: String, args: Array) -> Dictionary:
		if tool == "gogdl" and not "--force-upload" in args and not "--skip-upload" in args and not "--skip-download" in args:
			_write(str(args[3]).path_join("cloud.dat"), "gog cloud")
			return {"code": 0, "out": "[SAVES] INFO: No files locally, downloading\n1762800000.1"}
		if tool == "gogdl" and "--force-upload" in args:
			return {"code": 0, "out": "[SAVES] WARNING: Forcing upload\n[SAVES] INFO: Uploading files\n1762800001.2"}
		return {"code": 1, "out": ""}
	w["s"].resolve(w["gog"], "local")
	eq(w["s"].status(w["gog"])["state"], "uploaded", "kept this handheld's")
	var reasons: Array = w["s"].backup_list("gog:1207").map(func(b): return b["reason"])
	ok("cloud_copy" in reasons, "the cloud's files were kept as a backup before the forced upload")
	var copy: Dictionary = w["s"].backup_list("gog:1207").filter(func(b): return b["reason"] == "cloud_copy")[0]
	eq(copy["parts"][0]["path"], w["gsaves"], "a cloud copy restores into the game's own folder")
	cfg.load(w["s"].cfg_path)
	eq(cfg.get_value("game:gog:1207", "gog_ts", {}).get("__default", ""), "1762800001.2", "timestamp after the upload kept")
	ok(not DirAccess.dir_exists_absolute(w["s"].backup_dir.path_join(".cloud-gog_1207")), "scratch folder gone")
	# after play: upload with the stored timestamp
	w["handler"] = func(tool: String, args: Array) -> Dictionary:
		if tool == "gogdl" and "9999999999" in args:
			# the look before an upload: the cloud holds what the folder holds, nothing would be deleted
			return {"code": 0, "out": "[SAVES] INFO: Files in cloud: 1\n[SAVES] DEBUG: Files: [{'name': '__default/save0.dat', 'hash': 'abc', 'last_modified': '2025-11-10T18:00:00+00:00'}]\n[SAVES] INFO: Nothing to do\n1762800050.0"}
		return {"code": 0, "out": "[SAVES] INFO: Uploading files\n1762800100.0"} if tool == "gogdl" and "--skip-download" in args else {"code": 1, "out": ""}
	w["s"].after_exit(w["gog"])
	ok(w["calls"][-2].contains("--ts 9999999999") and not w["calls"][-2].contains("--skip") and not w["calls"][-2].contains("--force"), "first a look that changes nothing")
	ok(w["calls"][-1].contains("--ts 1762800001.2"), "the kept timestamp goes back to gogdl")
	eq(w["s"].backup_list("gog:1207").filter(func(b): return b["reason"] == "cloud_copy").size(), 1, "no second cloud copy: the upload deletes nothing")
	eq(w["s"].status(w["gog"])["state"], "uploaded", "uploaded after play")
	_done(w)


func test_restore_backs_up_the_current_saves_first() -> void:
	var w := _world("restore")
	var b: Dictionary = w["s"].backups.backup("epic:Min", "Minecraft Dungeons", "before_download", [{"name": "saves", "path": w["saves"]}])
	ok(b["ok"] and str(b["id"]) != "", "first backup")
	_write(w["saves"].path_join("slot1.sav"), "newer progress")
	var res := []
	w["s"].restore(w["epic"], str(b["id"]), func(r): res.append(r))
	ok(res[0]["ok"], "restored")
	eq(FileAccess.get_file_as_string(w["saves"].path_join("slot1.sav")), "local progress", "old save back")
	var list: Array = w["s"].backup_list("epic:Min")
	eq(list.size(), 2, "the saves before the restore were backed up")
	eq(list[0]["reason"], "before_restore", "newest: before the restore")
	w["s"].game_running = func() -> bool: return true
	w["s"].restore(w["epic"], str(b["id"]), func(r): res.append(r))
	eq(res[1], {"ok": false, "why": "running"}, "never while a game runs")
	_done(w)


func test_backups_skip_unchanged_and_keep_ten() -> void:
	var w := _world("prune")
	var bk: RefCounted = w["s"].backups
	var parts := [{"name": "saves", "path": w["saves"]}]
	var first: Dictionary = bk.backup("epic:Min", "M", "before_download", parts)
	var again: Dictionary = bk.backup("epic:Min", "M", "before_download", parts)
	eq(again["skipped"], "same", "unchanged folder: no second copy")
	eq(again["id"], first["id"], "points at the last one")
	for i in 12:
		bk.backup("epic:Min", "M", "before_download", parts, true)
	eq(bk.list("epic:Min").size(), 10, "the newest 10 kept")
	var empty: Dictionary = bk.backup("epic:Min", "M", "x", [{"name": "n", "path": w["root"].path_join("nothing")}])
	eq(empty["skipped"], "empty", "nothing to back up")
	_done(w)
