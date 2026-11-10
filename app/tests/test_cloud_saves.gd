extends "res://tests/test_case.gd"
## Cloud saves, the pure part (scripts/system/cloud_saves.gd): which tool runs how, what
## legendary and gogdl print (copied from their logging calls), the rules that decide
## download / upload / conflict, and where GOG games keep their saves in a Wine prefix.
## Fixture folders live under user://; nothing runs and nothing goes out.

const CS := preload("res://scripts/system/cloud_saves.gd")
const BASE := "user://test_cloud_saves"


func _root(name: String) -> String:
	var r := ProjectSettings.globalize_path(BASE).path_join(name)
	_rm(r)
	DirAccess.make_dir_recursive_absolute(r)
	return r


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


# ---- legendary -----------------------------------------------------------------------------------

const L_REMOTE := """[cli] INFO: Got 1 remote save game(s)
[cli] INFO: Checking "Hades" (Min)
[cli] INFO: Cloud save for "Hades" is newer:
[cli] INFO: - Cloud save date: 2026-11-10 12:00:00
[cli] INFO: - Local save date: 2026-11-09 08:30:00
[cli] INFO: Save game downloading is disabled, skipping...
"""
const L_LOCAL := """[cli] INFO: Got 1 remote save game(s)
[cli] INFO: Checking "Hades" (Min)
[cli] INFO: Local save for "Hades" is newer
[cli] INFO: - Cloud save date: N/A
[cli] INFO: - Local save date: 2026-11-10 13:00:00
"""
const L_SAME := """[cli] INFO: Got 1 remote save game(s)
[cli] INFO: Checking "Hades" (Min)
[cli] INFO: Save game for "Hades" is up to date, skipping...
"""


func test_legendary_output_is_read() -> void:
	var r := CS.parse_legendary(L_REMOTE, 0)
	eq(r["state"], "remote_newer", "cloud newer")
	eq(r["remote"], int(Time.get_unix_time_from_datetime_string("2026-11-10T12:00:00")), "cloud date (UTC)")
	eq(r["local"], int(Time.get_unix_time_from_datetime_string("2026-11-09T08:30:00")), "local date (UTC)")
	var l := CS.parse_legendary(L_LOCAL, 0)
	eq(l["state"], "local_newer", "local newer")
	eq(l["remote"], 0, "no cloud save: N/A is 0")
	eq(CS.parse_legendary(L_SAME, 0)["state"], "same", "up to date")
	eq(CS.parse_legendary("[cli] INFO: Got 0 remote save game(s)\n", 0)["state"], "unsupported", "skipped silently = no cloud saves")
	eq(CS.parse_legendary("[cli] INFO: Checking \"X\" (x)\n[cli] INFO: No cloud or local savegame found.\n", 0)["state"], "none", "nothing either side")
	eq(CS.parse_legendary("[cli] ERROR: Login failed! Cannot continue with download process.\n", 1)["state"], "offline", "login failed = offline")
	eq(CS.parse_legendary("", 124)["state"], "offline", "timed out = offline")
	var f := CS.parse_legendary("[cli] INFO: Checking \"X\" (x)\n[Core] ERROR: Download failed, status code: 500\n", 0)
	eq(f["state"], "failed", "an error line fails even with exit 0")
	ok(str(f["error"]).contains("500"), "and says why")
	var p := CS.parse_legendary("[cli] INFO: Checking \"X\" (x)\n[cli] INFO: Computed save path: \"/pfx/drive_c/users/steamuser/Saved Games/X\"\n" + L_SAME.substr(L_SAME.find("[cli] INFO: Save")), 0)
	eq(p["save_path"], "/pfx/drive_c/users/steamuser/Saved Games/X", "computed path kept")


func test_legendary_arguments() -> void:
	eq(CS.legendary_args("Min", "check"), ["-y", "sync-saves", "Min", "--accept-path", "--skip-upload", "--skip-download"], "look only")
	eq(CS.legendary_args("Min", "download"), ["-y", "sync-saves", "Min", "--accept-path", "--skip-upload"], "download only")
	eq(CS.legendary_args("Min", "upload")[-1], "--skip-download", "upload only")
	eq(CS.legendary_args("Min", "force_download")[-1], "--force-download", "forced download")
	eq(CS.legendary_args("Min", "force_upload")[-1], "--force-upload", "forced upload")
	eq(CS.with_timeout(["env", "A=b", "/bin/legendary"], ["-y"]), ["timeout", "-k", "5", str(CS.TIMEOUT_S), "env", "A=b", "/bin/legendary", "-y"] as Array[String], "under timeout")


func test_epic_rules_never_overwrite_unsynced_changes() -> void:
	var last := 1000000
	var remote_newer := {"state": "remote_newer", "local": last - 500, "remote": last + 5000}
	eq(CS.epic_decide(remote_newer, last, "pre"), "download", "only the cloud changed: download before play")
	eq(CS.epic_decide(remote_newer, last, "post"), "later", "after play the download waits for the next launch")
	var both := {"state": "remote_newer", "local": last + 3000, "remote": last + 5000}
	eq(CS.epic_decide(both, last, "pre"), "conflict", "local changed since the last sync too: the user picks")
	eq(CS.epic_decide({"state": "remote_newer", "local": 0, "remote": last}, last, "pre"), "download", "nothing local: download")
	eq(CS.epic_decide({"state": "remote_newer", "local": 500, "remote": 900}, 0, "pre"), "conflict", "never synced and both have saves: ask")
	var up := {"state": "local_newer", "local": last + 4000, "remote": last - 100}
	eq(CS.epic_decide(up, last, "post"), "upload", "only local changed: upload after play")
	eq(CS.epic_decide(up, last, "pre"), "later", "before play the upload waits")
	eq(CS.epic_decide({"state": "local_newer", "local": last + 9000, "remote": last + 4000}, last, "post"), "conflict", "cloud changed since too")
	eq(CS.epic_decide({"state": "local_newer", "local": last + 9000, "remote": last + 30}, last, "post"), "upload", "within a minute is the same moment")
	eq(CS.epic_decide({"state": "same"}, last, "now"), "none", "same age: nothing")


func test_epic_plan_waits_for_the_prefix_and_uses_heroics_flatpak() -> void:
	var r := _root("epic_plan")
	var cfg := r.path_join("legendary")
	var entry := {"store": "epic", "id": "Min", "installed": true, "config_dir": cfg, "prefix": r.path_join("pfx"), "platform": "Windows"}
	var tools := {"legendary": "/usr/bin/legendary", "heroic_flatpak": []}
	eq(CS.epic_plan(entry, tools)["why"], "signed_out", "no user.json: signed out")
	_write(cfg.path_join("user.json"), "{}")
	_write(cfg.path_join("metadata/Min.json"), JSON.stringify({"metadata": {"customAttributes": {}}}))
	eq(CS.epic_plan(entry, tools)["why"], "unsupported", "no CloudSaveFolder: no cloud saves")
	_write(cfg.path_join("metadata/Min.json"), JSON.stringify({"metadata": {"customAttributes": {"CloudSaveFolder": {"value": "{AppData}/Hades"}}}}))
	eq(CS.epic_plan(entry, tools)["why"], "not_set_up", "prefix not made yet: legendary would guess ~/.wine")
	_write(r.path_join("pfx/pfx/drive_c/users/steamuser/x"), "")
	_write(r.path_join("pfx/pfx/user.reg"), "")
	var p := CS.epic_plan(entry, tools)
	ok(p["ok"], "ready once the Proton prefix exists")
	eq(p["cmd"], ["env", "LEGENDARY_CONFIG_PATH=" + cfg, "WINEPREFIX=" + r.path_join("pfx/pfx"), "/usr/bin/legendary"], "legendary sees the prefix's pfx/")
	entry["heroic_flatpak"] = true
	var fp := CS.epic_plan(entry, {"legendary": "", "heroic_flatpak": ["/usr/bin/flatpak", "run", CS.HEROIC_FLATPAK_ID]})
	eq(fp["cmd"], ["/usr/bin/flatpak", "run", "--command=legendary", "--env=LEGENDARY_CONFIG_PATH=" + cfg,
		"--env=WINEPREFIX=" + r.path_join("pfx/pfx"), CS.HEROIC_FLATPAK_ID], "Heroic's Flatpak runs its own legendary")
	eq(CS.epic_plan(entry, {"legendary": "", "heroic_flatpak": []})["why"], "no_tool", "no tool at all")
	# a save path legendary already keeps works without the prefix
	_rm(r.path_join("pfx"))
	_write(cfg.path_join("installed.json"), JSON.stringify({"Min": {"save_path": "/games/saves"}}))
	entry["heroic_flatpak"] = false
	eq(CS.epic_plan(entry, tools)["save_path"], "/games/saves", "stored save path")
	_rm(r)


# ---- gogdl ---------------------------------------------------------------------------------------

func test_gogdl_output_is_read() -> void:
	var up := CS.parse_gogdl("[SAVES] INFO: Local files: 2\n[SAVES] INFO: Files in cloud: 2\n[SAVES] INFO: Uploading files\n1762790000.123456[SAVES] INFO: Done\n", 0)
	eq(up["action"], "upload", "uploaded")
	eq(up["ts"], "1762790000.123456", "the timestamp glued to a log line")
	var c := CS.parse_gogdl("[SAVES] DEBUG: Files: [{'name': '__default/a.sav', 'hash': 'ab12', 'last_modified': '2026-11-10T10:00:00+00:00'}, {'name': '__default/b.sav', 'hash': 'cd', 'last_modified': '2026-11-10T11:30:00+01:00'}]\n[SAVES] WARNING: Files in conflict force downloading or uploading of files\n1762799999.5\n", 0)
	eq(c["action"], "conflict", "conflict")
	eq(c["cloud_newest"], int(Time.get_unix_time_from_datetime_string("2026-11-10T10:30:00")), "newest cloud file, offset applied")
	var refused := CS.parse_gogdl("[SAVES] WARNING: Refused to upload files, newer files in the cloud\n1700000000.0\n", 0)
	eq(refused["action"], "refused", "refused")
	eq(refused["ts"], "1700000000.0", "our own timestamp back")
	var down := CS.parse_gogdl("[SAVES] INFO: No files locally, downloading\n[SAVES] INFO: Done\n1762790001.0", 0)
	eq(down["action"], "download", "downloaded into an empty folder")
	var bad := CS.parse_gogdl("[SAVES] INFO: Downloading files\n[SAVES] ERROR: Downloading file failed\n1762790001.0", 0)
	eq(bad["action"], "failed", "a failed file fails the step")
	var off := CS.parse_gogdl("requests.exceptions.ConnectionError: Max retries exceeded", 1)
	ok(off["offline"] and off["action"] == "failed", "no connection")


func test_gogdl_arguments() -> void:
	var a := CS.gogdl_args("/h/auth.json", "/pfx/saves", "1207", "__default", "17.5", "pre")
	eq(a, ["--auth-config-path", "/h/auth.json", "save-sync", "/pfx/saves", "1207", "--os", "windows", "--ts", "17.5",
		"--name", "__default", "--skip-upload", "--debug"], "download before play")
	ok("--skip-download" in CS.gogdl_args("a", "p", "1", "n", "", "post"), "upload after play")
	ok("0" in CS.gogdl_args("a", "p", "1", "n", "", "post"), "never synced: --ts 0")
	ok("--force-upload" in CS.gogdl_args("a", "p", "1", "n", "1", "force_upload"), "forced upload")
	var fetch := CS.gogdl_args("a", "p", "1", "n", "0", "fetch")
	ok(not "--skip-upload" in fetch and not "--force-upload" in fetch, "fetch: plain sync into an empty folder")


func test_gog_save_folders_resolve_in_the_prefix() -> void:
	var r := _root("gog_paths")
	var pfx := r.path_join("pfx")
	_write(pfx.path_join("drive_c/users/steamuser/AppData/Local/GOG.com/x"), "")
	_write(pfx.path_join("drive_c/users/steamuser/Documents/My Games/Witcher/x"), "")
	eq(CS.resolve_gog_location("<?DOCUMENTS?>/my games/witcher", "/games/w", pfx), pfx.path_join("drive_c/users/steamuser/Documents/My Games/Witcher"),
		"Documents, matched case-insensitively")
	eq(CS.resolve_gog_location("<?INSTALL?>/save", "/games/w", pfx), "/games/w/save", "install folder")
	eq(CS.resolve_gog_location("<?APPLICATION_DATA_LOCAL_LOW?>/Studio", "/g", pfx), pfx.path_join("drive_c/users/steamuser/AppData/LocalLow/Studio"), "LocalLow")
	eq(CS.resolve_gog_location(CS.gog_default_location("5150")["location"], "/g", pfx),
		pfx.path_join("drive_c/users/steamuser/AppData/Local/GOG.com/Galaxy/Applications/5150/Storage/Shared/Files"), "Galaxy's default folder")
	eq(CS.resolve_gog_location("<?WHATEVER?>/x", "/g", pfx), "", "unknown variable: not guessed")
	eq(CS.resolve_gog_location("<?SAVED_GAMES?>/x", "/g", ""), "", "no prefix yet")
	_rm(r)


func test_gog_plan_reads_heroic_then_asks_gog() -> void:
	var r := _root("gog_plan")
	var heroic := r.path_join("heroic")
	var pfx := r.path_join("pfx")
	_write(pfx.path_join("drive_c/users/steamuser/AppData/Local/x"), "")
	var entry := {"store": "gog", "id": "1207", "installed": true, "heroic_root": heroic, "install_path": r.path_join("game"), "prefix": pfx, "platform": "windows"}
	var tools := {"gogdl": "/usr/bin/gogdl"}
	eq(CS.gog_plan(entry, tools)["why"], "signed_out", "no GOG sign-in")
	_write(heroic.path_join("gog_store/auth.json"), "{}")
	eq(CS.gog_plan(entry, tools)["why"], "unsupported", "no Heroic data and no client id: nothing to sync")
	_write(r.path_join("game/goggame-1207.info"), JSON.stringify({"clientId": "5150"}))
	var ask := CS.gog_plan(entry, tools)
	eq([ask["why"], ask["client_id"]], ["ask", "5150"], "Heroic doesn't know it: ask GOG for its client id")
	var with_remote := CS.gog_plan(entry, tools, [])
	ok(with_remote["ok"], "GOG says cloud storage on, no locations")
	eq(with_remote["locations"][0]["name"], "__default", "the default folder")
	eq(CS.gog_plan(entry, tools, "none")["why"], "unsupported", "GOG says no cloud saves")
	_write(heroic.path_join("store_cache/gog_library.json"), JSON.stringify({"games": [{"app_name": "1207", "cloud_save_enabled": true,
		"gog_save_location": [{"name": "saves", "location": "<?INSTALL?>/saves"}]}]}))
	var lib := CS.gog_plan(entry, tools)
	eq(lib["locations"], [{"name": "saves", "path": r.path_join("game/saves")}], "Heroic's library cache")
	_write(heroic.path_join("GamesConfig/1207.json"), JSON.stringify({"1207": {"gogSaves": [{"name": "__default", "location": "/already/resolved"}]}}))
	eq(CS.gog_plan(entry, tools)["locations"], [{"name": "__default", "path": "/already/resolved"}], "Heroic's resolved folders first")
	entry["platform"] = "linux"
	eq(CS.gog_plan(entry, tools)["why"], "linux", "Linux versions have no GOG cloud saves")
	_write(heroic.path_join("gog_store/saveTimestamps.json"), JSON.stringify({"1207": {"__default": "1762790000.5"}}))
	eq(CS.heroic_gog_timestamps(heroic, "1207"), {"__default": "1762790000.5"}, "Heroic's timestamps")
	eq(CS.parse_gog_remote(JSON.stringify({"content": {"Windows": {"cloudStorage": {"enabled": true, "locations": [{"name": "a", "location": "<?INSTALL?>"}]}}}})),
		[{"name": "a", "location": "<?INSTALL?>"}], "remote config locations")
	eq(CS.parse_gog_remote(JSON.stringify({"content": {"Windows": {"cloudStorage": {"enabled": false}}}})), null, "remote config: off")
	_rm(r)


func test_iso_and_folder_stats() -> void:
	eq(CS.iso_to_unix("2026-11-10T10:00:00Z"), int(Time.get_unix_time_from_datetime_string("2026-11-10T10:00:00")), "Z")
	eq(CS.iso_to_unix("2026-11-10T10:00:00.123-02:00"), int(Time.get_unix_time_from_datetime_string("2026-11-10T12:00:00")), "fraction and negative offset")
	var r := _root("stats")
	_write(r.path_join("a/one.sav"), "12345")
	_write(r.path_join("a/b/two.sav"), "123")
	var st := CS.dir_stats(r.path_join("a"))
	eq([st["files"], st["bytes"]], [2, 8], "files and bytes, nested")
	ok(int(st["newest"]) > 0, "newest change")
	eq(CS.dir_stats(r.path_join("missing"))["files"], 0, "missing folder: empty")
	eq(CS.kind_of({"store": "amazon", "installed": true}), "", "Amazon isn't covered (nile has no save sync)")
	eq(CS.kind_of({"store": "gog", "installed": false}), "", "not installed")
	_rm(r)
