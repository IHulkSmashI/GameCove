extends "res://tests/test_case.gd"
## Cloud saves never lose a save (final review, blocker 1 and the saves findings after it).
## gogdl and legendary are the ports in tests/fixtures/saves/fake_clouds.gd, which do to a
## cloud and a folder what the real tools would; tar is real; everything lives under user://.

const Service := preload("res://scripts/system/saves_service.gd")
const CloudSaves := preload("res://scripts/system/cloud_saves.gd")
const ExecSafe := preload("res://scripts/system/exec_safe.gd")
const Fakes := preload("res://tests/fixtures/saves/fake_clouds.gd")
const SettingsFile := preload("res://scripts/system/settings_file.gd")
const BASE := "user://test_saves_safety"
## A day in the past the saves were made on, and the clock after it.
const T0 := 1762000000


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


func _json(path: String, data: Variant) -> void:
	Fakes.put(path, JSON.stringify(data))


## A world with one GOG game (its save folder inside a Wine prefix, found through Heroic's
## library cache) and one Epic game, both tools faked. w["gog_cloud"] / w["epic_cloud"] are
## the clouds, w["calls"] every tool call.
func _world(name: String) -> Dictionary:
	var root := ProjectSettings.globalize_path(BASE).path_join(name)
	_rm(root)
	var heroic := root.path_join("heroic")
	var prefix := root.path_join("prefix")
	var user := prefix.path_join("drive_c/users/steamuser")
	var gsaves := user.path_join("Documents/Witcher")
	_json(heroic.path_join("gog_store/auth.json"), {})
	_json(heroic.path_join("store_cache/gog_library.json"), {"games": [{"app_name": "1207", "cloud_save_enabled": true,
		"gog_save_location": [{"name": "saves", "location": "<?DOCUMENTS?>/Witcher"}]}]})
	Fakes.put(prefix.path_join("user.reg"), "reg")
	DirAccess.make_dir_recursive_absolute(user.path_join("Documents"))
	var gog := {"key": "gog:1207", "store": "gog", "id": "1207", "title": "The Witcher", "installed": true, "heroic_root": heroic,
		"install_path": root.path_join("gog/game"), "prefix": prefix, "platform": "windows"}
	var cfg := root.path_join("legendary")
	var esaves := user.path_join("Saved Games/Min")
	_json(cfg.path_join("user.json"), {})
	_json(cfg.path_join("metadata/Min.json"), {"metadata": {"customAttributes": {"CloudSaveFolder": {"value": "{UserSavedGames}/Min"}}}})
	_json(cfg.path_join("installed.json"), {"Min": {"save_path": esaves}})
	var epic := {"key": "epic:Min", "store": "epic", "id": "Min", "title": "Minecraft Dungeons", "installed": true,
		"config_dir": cfg, "platform": "Windows", "prefix": prefix}
	var gc := Fakes.Gog.new()
	gc.now = T0 + 100000
	var ec := Fakes.Epic.new()
	ec.config = cfg
	ec.app = "Min"
	ec.computed = esaves
	var w := {"root": root, "prefix": prefix, "user": user, "gsaves": gsaves, "esaves": esaves, "gog": gog, "epic": epic,
		"gog_cloud": gc, "epic_cloud": ec, "calls": [], "now": [T0 + 100000], "running": [false], "entries": {"gog:1207": gog, "epic:Min": epic}}
	var s: Node = Service.new()
	s.cfg_path = root.path_join("saves.cfg")
	s.off_path = root.path_join("saves_off.json")
	s.privacy_path = root.path_join("settings.cfg")
	s.backup_dir = root.path_join("backups")
	s.backups.base_dir = s.backup_dir
	s.clock = func() -> int: return int(w["now"][0])
	s.game_running = func() -> bool: return bool(w["running"][0])
	s.entry_lookup = func(k: String) -> Dictionary: return w["entries"].get(k, {}).duplicate()
	s.tools_lookup = func() -> Dictionary: return {"legendary": "/bin/legendary", "gogdl": "/bin/gogdl", "heroic_flatpak": []}
	s.run = func(program: String, args: PackedStringArray) -> Dictionary:
		if program in ["tar", "touch"]:
			return ExecSafe.run(program, args)
		var a := Array(args)
		var i := a.find("/bin/legendary")
		var tool := "legendary"
		if i < 0:
			i = a.find("/bin/gogdl")
			tool = "gogdl"
		var rest: Array = a.slice(i + 1)
		w["calls"].append(tool + " " + " ".join(PackedStringArray(rest)))
		w["now"][0] += 1
		gc.now = int(w["now"][0])
		if tool == "gogdl":
			return gc.run(rest)
		# legendary reads its config folder from LEGENDARY_CONFIG_PATH (a cloud copy runs on a copy)
		var own: String = ec.config
		for x in a.slice(0, i):
			if str(x).begins_with("LEGENDARY_CONFIG_PATH="):
				ec.config = str(x).trim_prefix("LEGENDARY_CONFIG_PATH=")
		var r: Dictionary = ec.run(rest)
		ec.config = own
		return r
	w["s"] = s
	return w


func _done(w: Dictionary) -> void:
	w["s"].free()
	_rm(w["root"])
	w.clear()


func _cfg(w: Dictionary, key: String, name: String, fallback: Variant = null) -> Variant:
	var c := ConfigFile.new()
	c.load(w["s"].cfg_path)
	return c.get_value("game:" + key, name, fallback)


## One play session: before_launch, the game writes `files` ({rel: data}) with fresh
## times, after_exit. Returns what before_launch answered.
func _play(w: Dictionary, game: Dictionary, folder: String, files: Dictionary) -> Dictionary:
	var got := []
	w["s"].before_launch(game, func(r): got.append(r))
	w["now"][0] += 600
	for rel in files:
		Fakes.put(folder.path_join(rel), str(files[rel]), int(w["now"][0]))
	w["s"].after_exit(game)
	return got[0] if not got.is_empty() else {}


# ---- blocker 1: GOG, a deleted or changed prefix ---------------------------------------------

## The review's scenario, end to end: a synced game, the prefix deleted, one play session.
## The post-game sync used to upload the fresh default file and delete every cloud slot.
func test_gog_deleted_prefix_never_wipes_the_cloud() -> void:
	var w := _world("gog_prefix_deleted")
	var cloud: Object = w["gog_cloud"]
	for slot in ["slot1.sav", "slot2.sav", "slot3.sav"]:
		Fakes.put(w["gsaves"].path_join(slot), "progress " + slot, T0)
	# a normal first sync: everything goes up
	_play(w, w["gog"], w["gsaves"], {})
	w["s"].sync_now(w["gog"])
	eq(cloud.files("saves"), ["slot1.sav", "slot2.sav", "slot3.sav"], "the three slots are in the cloud")
	ok(str(Dictionary(_cfg(w, "gog:1207", "gog_ts", {})).get("saves", "")) != "", "and a sync time is kept")
	# the user deletes the prefix to fix the game; the game makes a fresh one with a default file
	_rm(w["prefix"])
	cloud.did.clear()
	var got := []
	w["s"].before_launch(w["gog"], func(r): got.append(r))
	eq(got, [{"go": true}], "the game still starts")
	eq(w["s"].status(w["gog"])["state"], "not_set_up", "nothing to sync into yet")
	w["now"][0] += 900
	Fakes.put(w["prefix"].path_join("user.reg"), "reg")
	Fakes.put(w["gsaves"].path_join("settings.ini"), "defaults", int(w["now"][0]))
	w["s"].after_exit(w["gog"])
	eq(cloud.files("saves"), ["slot1.sav", "slot2.sav", "slot3.sav"], "every cloud slot is still there")
	ok(cloud.did.filter(func(x): return str(x).begins_with("delete cloud")).is_empty(), "gogdl deleted nothing in the cloud")
	eq(w["s"].status(w["gog"])["state"], "conflict", "the user is asked which side to keep")
	# choosing the cloud brings the slots back (the default file is backed up first)
	w["s"].resolve(w["gog"], "cloud")
	eq(Fakes.walk(w["gsaves"]), ["slot1.sav", "slot2.sav", "slot3.sav"], "the cloud's saves are back in the new prefix")
	_done(w)


## Same, when the save folders are Heroic's own (they resolve even without a prefix): the
## launch finds the folder empty, so the cloud comes down before the game starts.
func test_gog_empty_folder_gets_the_cloud_before_play_and_keeps_it_after() -> void:
	var w := _world("gog_empty_folder")
	var cloud: Object = w["gog_cloud"]
	_json(w["gog"]["heroic_root"].path_join("GamesConfig/1207.json"), {"1207": {"gogSaves": [{"name": "saves", "location": w["gsaves"]}]}})
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "progress", T0)
	Fakes.put(w["gsaves"].path_join("slot2.sav"), "more", T0)
	w["s"].sync_now(w["gog"])
	eq(cloud.files("saves"), ["slot1.sav", "slot2.sav"], "synced")
	_rm(w["prefix"])
	# the cloud can't be reached at this launch, so nothing comes down
	cloud.offline = true
	var got := []
	w["s"].before_launch(w["gog"], func(r): got.append(r))
	eq(got, [{"go": true}], "offline: the game still starts")
	cloud.offline = false
	w["now"][0] += 900
	Fakes.put(w["gsaves"].path_join("settings.ini"), "defaults", int(w["now"][0]))
	cloud.did.clear()
	w["s"].after_exit(w["gog"])
	eq(cloud.files("saves"), ["slot1.sav", "slot2.sav"], "the cloud keeps both slots")
	eq(w["s"].status(w["gog"])["state"], "conflict", "a conflict, not an upload")
	_done(w)


## A prefix changed in compatibility settings: the folder moved, so the old sync time
## means nothing for it.
func test_gog_changed_prefix_starts_over() -> void:
	var w := _world("gog_prefix_changed")
	var cloud: Object = w["gog_cloud"]
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "progress", T0)
	Fakes.put(w["gsaves"].path_join("slot2.sav"), "more", T0)
	w["s"].sync_now(w["gog"])
	eq(cloud.files("saves"), ["slot1.sav", "slot2.sav"], "synced")
	var other: String = w["root"].path_join("prefix2")
	var osaves := other.path_join("drive_c/users/steamuser/Documents/Witcher")
	Fakes.put(other.path_join("user.reg"), "reg")
	w["now"][0] += 5000
	Fakes.put(osaves.path_join("other.sav"), "an older try in the other prefix", int(w["now"][0]))
	w["entries"]["gog:1207"]["prefix"] = other
	cloud.did.clear()
	w["s"].after_exit(w["gog"])
	eq(cloud.files("saves"), ["slot1.sav", "slot2.sav"], "nothing deleted in the cloud")
	eq(w["s"].status(w["gog"])["state"], "conflict", "the new folder is a conflict")
	_done(w)


## Uninstalling forgets the sync times (the folders may be gone when it comes back).
func test_uninstall_forgets_the_sync_times() -> void:
	var w := _world("forget")
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "progress", T0)
	w["s"].sync_now(w["gog"])
	w["s"].set_enabled("gog:1207", false)
	ok(Dictionary(_cfg(w, "gog:1207", "gog_ts", {})).has("saves"), "a sync time is kept")
	w["s"].forget("gog:1207")
	eq(_cfg(w, "gog:1207", "gog_ts", {}), {}, "gone after the uninstall")
	eq(int(_cfg(w, "gog:1207", "last_sync", 0)), 0, "last sync gone")
	eq(_cfg(w, "gog:1207", "enabled", true), false, "the game's switch stays as the user set it")
	# Library says so through install_state_changed
	var lib := FakeLibrary.new()
	w["s"].setup_library(lib)
	w["s"].set_enabled("gog:1207", true)
	w["s"].sync_now(w["gog"])
	eq(w["s"].status(w["gog"])["state"], "conflict", "after forgetting, both sides count as changed: we ask")
	w["s"].resolve(w["gog"], "local")
	ok(str(Dictionary(_cfg(w, "gog:1207", "gog_ts", {})).get("saves", "0")) != "0", "synced again")
	lib.install_state_changed.emit("gog:1207", "not_installed")
	eq(_cfg(w, "gog:1207", "gog_ts", {}), {}, "Library's uninstall forgets it")
	lib.install_state_changed.emit("steam:440", "not_installed")
	var c := ConfigFile.new()
	c.load(w["s"].cfg_path)
	ok(not c.has_section("game:steam:440"), "a game we never synced gets no entry")
	lib.free()
	_done(w)


class FakeLibrary extends Node:
	signal install_state_changed(key: String, state: String)


## Heroic's own sync time is only taken for the folder Heroic synced, and never after we
## dropped ours.
func test_heroic_time_is_not_a_fallback_for_another_folder() -> void:
	var w := _world("heroic_ts")
	_json(w["gog"]["heroic_root"].path_join("gog_store/saveTimestamps.json"), {"1207": {"saves": "1762050000.0"}})
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "progress", T0)
	w["gog_cloud"].seed("saves", "slot1.sav", "cloud progress", T0 + 10)
	var got := []
	w["s"].before_launch(w["gog"], func(r): got.append(r))
	ok(str(w["calls"][-1]).contains("--ts 0 "), "our own folder: Heroic's time isn't used (%s)" % str(w["calls"][-1]))
	_done(w)
	# the folder Heroic itself syncs: its time is where we start, so that game isn't a conflict at first
	var h := _world("heroic_ts_own")
	_json(h["gog"]["heroic_root"].path_join("gog_store/saveTimestamps.json"), {"1207": {"saves": "1762050000.0"}})
	_json(h["gog"]["heroic_root"].path_join("GamesConfig/1207.json"), {"1207": {"gogSaves": [{"name": "saves", "location": h["gsaves"]}]}})
	Fakes.put(h["gsaves"].path_join("slot1.sav"), "progress", T0)
	h["gog_cloud"].seed("saves", "slot1.sav", "progress", T0 + 10)
	h["s"].before_launch(h["gog"], func(_r): pass)
	ok(str(h["calls"][-1]).contains("--ts 1762050000.0 "), "Heroic's folder: Heroic's time")
	eq(h["s"].status(h["gog"])["state"], "synced", "and no conflict")
	# once we dropped ours (a new prefix), Heroic's is never picked up again
	h["s"].forget("gog:1207")
	h["s"].before_launch(h["gog"], func(_r): pass)
	ok(str(h["calls"][-1]).contains("--ts 0 "), "after a forget: never Heroic's again")
	_done(h)


## An upload that would delete cloud files this handheld doesn't have keeps a copy of the
## cloud first (a save slot deleted in the game is the honest case).
func test_gog_upload_that_deletes_cloud_files_keeps_a_cloud_copy() -> void:
	var w := _world("gog_cloud_copy")
	var cloud: Object = w["gog_cloud"]
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "progress", T0)
	Fakes.put(w["gsaves"].path_join("slot2.sav"), "second", T0)
	w["s"].sync_now(w["gog"])
	eq(cloud.files("saves"), ["slot1.sav", "slot2.sav"], "synced")
	eq(w["s"].backup_list("gog:1207").filter(func(b): return b["reason"] == "cloud_copy").size(), 0, "no cloud copy for a plain upload")
	# the game deletes slot 2 and saves slot 1
	var got := []
	w["s"].before_launch(w["gog"], func(r): got.append(r))
	w["now"][0] += 900
	DirAccess.remove_absolute(w["gsaves"].path_join("slot2.sav"))
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "further", int(w["now"][0]))
	w["s"].after_exit(w["gog"])
	eq(cloud.files("saves"), ["slot1.sav"], "the upload went through (slot 2 deleted in the cloud too)")
	var copies: Array = w["s"].backup_list("gog:1207").filter(func(b): return b["reason"] == "cloud_copy")
	eq(copies.size(), 1, "with a copy of the cloud taken first")
	# and that copy holds slot 2
	var r: Dictionary = w["s"].backups.restore("gog:1207", str(copies[0]["id"]))
	ok(r["ok"], "restorable")
	eq(FileAccess.get_file_as_string(w["gsaves"].path_join("slot2.sav")), "second", "slot 2 is in the cloud copy")
	_done(w)


## A gogdl whose log doesn't list the cloud's files: we can't tell what an upload would
## delete, so the copy is taken anyway.
func test_gog_cloud_copy_when_the_listing_cant_be_read() -> void:
	var w := _world("gog_no_listing")
	var cloud: Object = w["gog_cloud"]
	cloud.hide_listing = true
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "progress", T0)
	w["s"].sync_now(w["gog"])
	var got := []
	w["s"].before_launch(w["gog"], func(r): got.append(r))
	w["now"][0] += 900
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "further", int(w["now"][0]))
	w["s"].after_exit(w["gog"])
	eq(w["s"].backup_list("gog:1207").filter(func(b): return b["reason"] == "cloud_copy").size(), 1, "a cloud copy, to be safe")
	eq(w["s"].status(w["gog"])["state"], "uploaded", "then the upload")
	_done(w)


## If the cloud copy can't be made, nothing is uploaded.
func test_gog_no_upload_without_the_cloud_copy() -> void:
	var w := _world("gog_copy_fails")
	var cloud: Object = w["gog_cloud"]
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "progress", T0)
	Fakes.put(w["gsaves"].path_join("slot2.sav"), "second", T0)
	w["s"].sync_now(w["gog"])
	var got := []
	w["s"].before_launch(w["gog"], func(r): got.append(r))
	w["now"][0] += 900
	DirAccess.remove_absolute(w["gsaves"].path_join("slot2.sav"))
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "further", int(w["now"][0]))
	# the look works, the fetch of the cloud copy is cut off
	cloud.cut_download_after = 0
	w["s"].after_exit(w["gog"])
	eq(cloud.files("saves"), ["slot1.sav", "slot2.sav"], "nothing was deleted in the cloud")
	eq(cloud.cloud["saves/slot1.sav"]["data"], "progress", "and nothing uploaded")
	ok(w["s"].status(w["gog"])["state"] in ["offline", "backup_failed"], "the status says it didn't sync")
	_done(w)


# ---- blocker 1 everywhere: the folder check doesn't need a sync to run (review at ff76ca4) ---

## A world whose folder identities are ours to change: w["gen"][path] bumps when the test
## "re-makes" a folder (a real stat can hand a deleted folder's inode to the next one).
func _ided(w: Dictionary) -> void:
	w["gen"] = {}
	w["s"].folder_id = func(path: String) -> String:
		return "" if not DirAccess.dir_exists_absolute(path) else path + "#" + str(w["gen"].get(path, 0))


## GOG, sync switched off for the first launch after the prefix was lost: the launch sees the
## empty folder and drops the sync time, so the blank save that game makes is a conflict
## when sync is back on, never an upload that deletes the cloud's slots.
func test_gog_lost_prefix_with_sync_off_never_uploads_the_blank_save() -> void:
	var w := _world("gog_lost_sync_off")
	var cloud: Object = w["gog_cloud"]
	for slot in ["slot1.sav", "slot2.sav"]:
		Fakes.put(w["gsaves"].path_join(slot), "progress " + slot, T0)
	w["s"].sync_now(w["gog"])
	eq(cloud.files("saves"), ["slot1.sav", "slot2.sav"], "synced")
	_rm(w["prefix"])
	w["s"].set_enabled("gog:1207", false)
	var got := []
	w["s"].before_launch(w["gog"], func(r): got.append(r))
	eq(got, [{"go": true}], "sync off: the game starts at once")
	eq(str(Dictionary(_cfg(w, "gog:1207", "gog_ts", {})).get("saves", "0")), "0", "but the empty folder's sync time is gone")
	w["now"][0] += 900
	Fakes.put(w["prefix"].path_join("user.reg"), "reg")
	Fakes.put(w["gsaves"].path_join("settings.ini"), "defaults", int(w["now"][0]))
	w["s"].after_exit(w["gog"])
	w["s"].set_enabled("gog:1207", true)
	cloud.did.clear()
	w["s"].sync_now(w["gog"])
	eq(cloud.files("saves"), ["slot1.sav", "slot2.sav"], "both slots are still in the cloud")
	ok(cloud.did.filter(func(x): return str(x).begins_with("delete cloud") or str(x).begins_with("upload")).is_empty(), "nothing uploaded or deleted (%s)" % str(cloud.did))
	eq(w["s"].status(w["gog"])["state"], "conflict", "we ask")
	_done(w)


## Same with Epic and the user signed out of Epic at that launch.
func test_epic_lost_prefix_while_signed_out_never_uploads_the_blank_save() -> void:
	var w := _world("epic_lost_signed_out")
	var cloud: Object = w["epic_cloud"]
	Fakes.put(w["esaves"].path_join("world.sav"), "40 hours", T0)
	w["s"].sync_now(w["epic"])
	eq(cloud.saves.size(), 1, "synced")
	_rm(w["prefix"])
	var user_json: String = w["epic"]["config_dir"].path_join("user.json")
	DirAccess.remove_absolute(user_json)
	var got := []
	w["s"].before_launch(w["epic"], func(r): got.append(r))
	eq(got, [{"go": true}], "signed out: the game starts")
	eq(int(_cfg(w, "epic:Min", "last_sync", -1)), 0, "the sync time of the folder that's gone is dropped")
	w["now"][0] += 900
	Fakes.put(w["prefix"].path_join("user.reg"), "reg")
	Fakes.put(w["esaves"].path_join("world.sav"), "new game", int(w["now"][0]))
	w["s"].after_exit(w["epic"])
	_json(user_json, {})
	w["s"].sync_now(w["epic"])
	eq(cloud.saves.size(), 1, "nothing was uploaded")
	eq(cloud.saves[-1]["files"]["world.sav"], "40 hours", "the cloud's newest save is the real one")
	eq(w["s"].status(w["epic"])["state"], "conflict", "we ask")
	_done(w)


## A prefix lost and re-made while GameCove never looked (the game played from Heroic): the
## folder is full again by the time we see it, but its prefix isn't the one we synced with.
func test_remade_prefix_seen_only_after_the_fact_is_a_conflict() -> void:
	var w := _world("remade_unseen")
	_ided(w)
	var cloud: Object = w["gog_cloud"]
	for slot in ["slot1.sav", "slot2.sav"]:
		Fakes.put(w["gsaves"].path_join(slot), "progress " + slot, T0)
	w["s"].sync_now(w["gog"])
	Fakes.put(w["esaves"].path_join("world.sav"), "40 hours", T0)
	w["s"].sync_now(w["epic"])
	ok(Dictionary(_cfg(w, "gog:1207", "anchors", {})).has(w["gsaves"]), "the folder's prefix is noted at the sync")
	_rm(w["prefix"])
	var drive: String = w["prefix"].path_join("drive_c")
	w["gen"][drive] = 1
	w["now"][0] += 900
	Fakes.put(w["prefix"].path_join("user.reg"), "reg")
	Fakes.put(w["gsaves"].path_join("settings.ini"), "defaults", int(w["now"][0]))
	Fakes.put(w["esaves"].path_join("world.sav"), "new game", int(w["now"][0]))
	cloud.did.clear()
	w["s"].sync_now(w["gog"])
	eq(cloud.files("saves"), ["slot1.sav", "slot2.sav"], "GOG: the slots stay")
	ok(cloud.did.filter(func(x): return str(x).begins_with("upload")).is_empty(), "GOG: nothing uploaded")
	eq(w["s"].status(w["gog"])["state"], "conflict", "GOG: we ask")
	w["s"].sync_now(w["epic"])
	eq(w["epic_cloud"].saves.size(), 1, "Epic: nothing uploaded")
	eq(w["s"].status(w["epic"])["state"], "conflict", "Epic: we ask")
	_done(w)


## Our own put-back of a backup (a download that failed) isn't a new folder.
func test_our_own_restore_keeps_the_folder_identity() -> void:
	var w := _world("own_restore_identity")
	var cloud: Object = w["gog_cloud"]
	var folder: String = w["root"].path_join("gogsaves")   # outside any prefix: its own anchor
	_json(w["gog"]["heroic_root"].path_join("GamesConfig/1207.json"), {"1207": {"gogSaves": [{"name": "saves", "location": folder}]}})
	Fakes.put(folder.path_join("slot1.sav"), "progress", T0)
	w["s"].sync_now(w["gog"])
	var before := str(Dictionary(_cfg(w, "gog:1207", "anchors", {})).get(folder, ""))
	ok(before != "", "noted (a real stat: %s)" % before)
	Fakes.put(folder.path_join("slot2.sav"), "x", T0)
	var b: Dictionary = w["s"].backups.backup("gog:1207", "The Witcher", "before_download", [{"name": "saves", "path": folder}], true)
	w["s"]._put_back("gog:1207", b, [])
	ok(not w["s"].folder_guard("gog:1207"), "the swapped-in folder still counts as ours")
	ok(str(Dictionary(_cfg(w, "gog:1207", "gog_ts", {})).get("saves", "0")) != "0", "the sync time stays")
	_done(w)


func test_stat_id_reads_a_folder() -> void:
	var dir := ProjectSettings.globalize_path(BASE).path_join("stat_id")
	DirAccess.make_dir_recursive_absolute(dir)
	var id := Service.stat_id(dir)
	eq(id.split(":").size(), 3, "device, inode and birth (%s)" % id)
	eq(Service.stat_id(dir.path_join("missing")), "", "nothing for a folder that isn't there")
	eq(CloudSaves.identity_anchor("/p/pfx/drive_c/users/steamuser/Documents/W"), "/p/pfx/drive_c", "a prefix folder: its drive_c")
	eq(CloudSaves.identity_anchor("/games/W/saves"), "/games/W/saves", "elsewhere: the folder")
	_rm(dir)


# ---- blocker 1, Epic: a blank save never becomes the newest cloud save ------------------------

## Synced, prefix deleted, the launch can't reach Epic, the game writes a blank save. The
## post-game sync used to upload it (legendary: local newer), burying the real save.
func test_epic_blank_save_after_a_deleted_prefix_is_a_conflict() -> void:
	var w := _world("epic_prefix_deleted")
	var cloud: Object = w["epic_cloud"]
	Fakes.put(w["esaves"].path_join("world.sav"), "40 hours", T0)
	w["s"].sync_now(w["epic"])
	eq(cloud.saves.size(), 1, "the save is in the cloud")
	ok(int(_cfg(w, "epic:Min", "last_sync", 0)) > 0, "synced")
	_rm(w["prefix"])
	cloud.offline = true
	var got := []
	w["s"].before_launch(w["epic"], func(r): got.append(r))
	eq(got, [{"go": true}], "offline: the game still starts")
	cloud.offline = false
	w["now"][0] += 900
	Fakes.put(w["prefix"].path_join("user.reg"), "reg")
	Fakes.put(w["esaves"].path_join("world.sav"), "new game", int(w["now"][0]))
	w["s"].after_exit(w["epic"])
	eq(cloud.saves.size(), 1, "nothing was uploaded")
	eq(cloud.saves[-1]["files"]["world.sav"], "40 hours", "the cloud's newest save is still the real one")
	eq(w["s"].status(w["epic"])["state"], "conflict", "the user is asked")
	_done(w)


## With Epic reachable at that launch, the cloud save simply comes down into the new prefix.
func test_epic_empty_folder_gets_the_cloud_save() -> void:
	var w := _world("epic_empty")
	var cloud: Object = w["epic_cloud"]
	Fakes.put(w["esaves"].path_join("world.sav"), "40 hours", T0)
	w["s"].sync_now(w["epic"])
	_rm(w["prefix"])
	var got := []
	w["s"].before_launch(w["epic"], func(r): got.append(r))
	eq(got, [{"go": true}], "starts")
	eq(FileAccess.get_file_as_string(w["esaves"].path_join("world.sav")), "40 hours", "the cloud save is back")
	eq(w["s"].status(w["epic"])["state"], "downloaded", "downloaded")
	_done(w)


## A game that never had a prefix: not_set_up at launch, and whatever it writes is new.
func test_epic_not_set_up_drops_the_last_sync() -> void:
	var w := _world("epic_not_set_up")
	_json(w["epic"]["config_dir"].path_join("installed.json"), {"Min": {}})
	var c := ConfigFile.new()
	c.set_value("game:epic:Min", "last_sync", T0)
	c.save(w["s"].cfg_path)
	_rm(w["prefix"])
	var got := []
	w["s"].before_launch(w["epic"], func(r): got.append(r))
	eq(w["s"].status(w["epic"])["state"], "not_set_up", "no prefix yet")
	eq(int(_cfg(w, "epic:Min", "last_sync", -1)), 0, "an old sync time doesn't outlive the prefix")
	_done(w)


# ---- Epic variant: the conflict sheet and a copy of the cloud (review at ff76ca4) ---------------

const SavesCard := preload("res://scripts/ui/games/saves_card.gd")
const TS := preload("res://scripts/ui/texts_saves.gd")


## The blank save after a lost prefix: the conflict keeps a copy of the cloud's save at once,
## knows what both sides hold, and the sheet never calls the blank one Newer. legendary's own
## files never point at the scratch folder the copy is made in.
func test_epic_blank_save_conflict_keeps_the_cloud_and_isnt_newer() -> void:
	var w := _world("epic_blank_sheet")
	var cloud: Object = w["epic_cloud"]
	Fakes.put(w["esaves"].path_join("world.sav"), "40 hours of progress", T0)
	Fakes.put(w["esaves"].path_join("world2.sav"), "and a second world", T0)
	w["s"].sync_now(w["epic"])
	var user_before := FileAccess.get_file_as_string(w["epic"]["config_dir"].path_join("user.json"))
	_rm(w["prefix"])
	cloud.offline = true
	w["s"].before_launch(w["epic"], func(_r): pass)
	cloud.offline = false
	w["now"][0] += 900
	Fakes.put(w["prefix"].path_join("user.reg"), "reg")
	Fakes.put(w["esaves"].path_join("world.sav"), "new", int(w["now"][0]))
	w["s"].after_exit(w["epic"])
	var st: Dictionary = w["s"].status(w["epic"])
	eq(st["state"], "conflict", "asked")
	ok(st["fresh"], "no sync time for this folder: in doubt")
	eq([st["local_files"], st["cloud_files"]], [1, 2], "what each side holds")
	var rows := SavesCard.conflict_rows(st, int(w["now"][0]))
	eq(rows[0]["id"], "cloud", "the cloud's save first")
	ok(rows.all(func(r): return r.get("value", "") != TS.NEWER or r["id"] == "cloud"), "the blank one is never Newer")
	var copies: Array = w["s"].backup_list("epic:Min").filter(func(b): return b["reason"] == "cloud_copy")
	eq(copies.size(), 1, "a copy of the cloud's save is kept already")
	eq(cloud.save_path(), w["esaves"], "legendary still keeps the game's own folder")
	eq(FileAccess.get_file_as_string(w["epic"]["config_dir"].path_join("user.json")), user_before, "the sign-in is untouched")
	eq(Array(DirAccess.get_directories_at(w["s"].backup_dir)).filter(func(d): return d.begins_with(".")), [], "no scratch folder left behind")
	# the copy goes back into the game's folder
	var r: Dictionary = w["s"].backups.restore("epic:Min", str(copies[0]["id"]))
	ok(r["ok"], "restorable")
	eq(Fakes.walk(w["esaves"]), ["world.sav", "world2.sav"], "both worlds")
	eq(FileAccess.get_file_as_string(w["esaves"].path_join("world.sav")), "40 hours of progress", "the cloud's save")
	_done(w)


## Keeping this handheld's save over Epic's: the cloud's save is copied first, and without
## that copy nothing is uploaded.
func test_epic_keep_local_copies_the_cloud_first() -> void:
	var w := _world("epic_keep_local_copy")
	var cloud: Object = w["epic_cloud"]
	Fakes.put(w["esaves"].path_join("world.sav"), "here", T0)
	cloud.saves.append({"t": T0 + 3000, "files": {"world.sav": "the cloud's"}})
	w["s"].sync_now(w["epic"])
	eq(w["s"].status(w["epic"])["state"], "conflict", "never synced, saves on both sides")
	for b in w["s"].backup_list("epic:Min"):
		DirAccess.remove_absolute(w["s"].backups.dir_for("epic:Min").path_join(str(b["id"]) + ".json"))
	cloud.offline = true
	w["s"].resolve(w["epic"], "local")
	eq(cloud.saves.size(), 1, "no copy (offline): nothing uploaded")
	eq(w["s"].status(w["epic"])["state"], "backup_failed", "and the status says why")
	cloud.offline = false
	w["s"].resolve(w["epic"], "local")
	eq(cloud.saves[-1]["files"]["world.sav"], "here", "uploaded")
	var copies: Array = w["s"].backup_list("epic:Min").filter(func(b): return b["reason"] == "cloud_copy")
	eq(copies.size(), 1, "after a copy of the cloud's save")
	w["s"].backups.restore("epic:Min", str(copies[0]["id"]))
	eq(FileAccess.get_file_as_string(w["esaves"].path_join("world.sav")), "the cloud's", "which holds the cloud's save")
	_done(w)


## GOG's side of it: the conflict after a lost prefix is marked as in doubt too.
func test_gog_blank_save_conflict_is_in_doubt() -> void:
	var w := _world("gog_blank_sheet")
	for slot in ["slot1.sav", "slot2.sav"]:
		Fakes.put(w["gsaves"].path_join(slot), "progress " + slot, T0)
	w["s"].sync_now(w["gog"])
	_rm(w["prefix"])
	w["s"].set_enabled("gog:1207", false)
	w["s"].before_launch(w["gog"], func(_r): pass)
	w["now"][0] += 900
	Fakes.put(w["prefix"].path_join("user.reg"), "reg")
	Fakes.put(w["gsaves"].path_join("settings.ini"), "d", int(w["now"][0]))
	w["s"].set_enabled("gog:1207", true)
	w["s"].sync_now(w["gog"])
	var st: Dictionary = w["s"].status(w["gog"])
	eq(st["state"], "conflict", "asked")
	ok(st["fresh"], "in doubt")
	eq([st["local_files"], st["cloud_files"]], [1, 2], "what each side holds")
	eq(w["s"].backup_list("gog:1207").filter(func(b): return b["reason"] == "cloud_copy").size(), 1, "the cloud's slots are copied already")
	eq(SavesCard.conflict_rows(st, int(w["now"][0]))[0]["id"], "cloud", "the cloud's first on the sheet")
	_done(w)


# ---- the review's Low items (review at ff76ca4, section 3) ----------------------------------------

## L1: a cloud save is named by when it was saved, not uploaded. Saved on another device before
## our last sync and uploaded after it, it looked older than our sync, so "unchanged", and our
## post-game upload buried it. The cloud save's own time at our last sync is kept and compared.
func test_epic_a_cloud_save_older_than_our_sync_but_new_to_us_is_a_change() -> void:
	var w := _world("epic_l1")
	var cloud: Object = w["epic_cloud"]
	Fakes.put(w["esaves"].path_join("world.sav"), "ours", T0)
	w["s"].sync_now(w["epic"])
	eq(cloud.saves.size(), 1, "synced")
	# the other device saved an hour after T0 (long before our sync), and only now uploaded
	cloud.saves.append({"t": T0 + 3600, "files": {"world.sav": "the other device's"}})
	cloud.offline = true
	w["s"].before_launch(w["epic"], func(_r): pass)
	cloud.offline = false
	w["now"][0] += 900
	Fakes.put(w["esaves"].path_join("world.sav"), "ours, played on", int(w["now"][0]))
	w["s"].after_exit(w["epic"])
	eq(cloud.saves[-1]["files"]["world.sav"], "the other device's", "nothing uploaded over it")
	eq(w["s"].status(w["epic"])["state"], "conflict", "we ask")
	_done(w)


# ---- Epic: a changed prefix ---------------------------------------------------------------------

## legendary keeps the save folder it computed once. After a prefix change we hand it the
## same folder inside the prefix the game runs in now.
func test_epic_follows_a_changed_prefix() -> void:
	var w := _world("epic_prefix_changed")
	var cloud: Object = w["epic_cloud"]
	Fakes.put(w["esaves"].path_join("world.sav"), "40 hours", T0)
	w["s"].sync_now(w["epic"])
	var other: String = w["root"].path_join("prefix2")
	Fakes.put(other.path_join("user.reg"), "reg")
	DirAccess.make_dir_recursive_absolute(other.path_join("drive_c/users/steamuser"))
	w["entries"]["epic:Min"]["prefix"] = other
	var want := other.path_join("drive_c/users/steamuser/Saved Games/Min")
	eq(CloudSaves.epic_moved_save_path(w["esaves"], other), want, "the same folder in the new prefix")
	eq(CloudSaves.epic_moved_save_path(w["esaves"], w["prefix"]), "", "same prefix: nothing to move")
	eq(CloudSaves.epic_moved_save_path("/games/Min/save", other), "", "a folder outside any prefix stays")
	var got := []
	w["s"].before_launch(w["epic"], func(r): got.append(r))
	ok(str(w["calls"][-1]).contains("--save-path " + want) or str(w["calls"][-2]).contains("--save-path " + want), "legendary is told the new folder")
	eq(cloud.save_path(), want, "and keeps it")
	eq(FileAccess.get_file_as_string(want.path_join("world.sav")), "40 hours", "the cloud save came down into the new prefix")
	eq(FileAccess.get_file_as_string(w["esaves"].path_join("world.sav")), "40 hours", "the old prefix's save is left alone")
	# a different Windows user name in the new prefix
	var third: String = w["root"].path_join("prefix3")
	DirAccess.make_dir_recursive_absolute(third.path_join("drive_c/users/deck"))
	eq(CloudSaves.epic_moved_save_path(w["esaves"], third), third.path_join("drive_c/users/deck/Saved Games/Min"), "the prefix's own user folder")
	# the play session in the new prefix then syncs there
	w["now"][0] += 900
	Fakes.put(want.path_join("world.sav"), "41 hours", int(w["now"][0]))
	w["s"].after_exit(w["epic"])
	eq(cloud.saves[-1]["files"]["world.sav"], "41 hours", "the next save goes up from the new prefix")
	_done(w)


# ---- high 5: no conflict choice under a running game -----------------------------------------

## "Decide later" at launch, Guide, the game page, "Keep the cloud save": the forced
## download would empty the folder under the live game.
func test_resolve_waits_while_a_game_runs() -> void:
	var w := _world("resolve_running")
	var cloud: Object = w["gog_cloud"]
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "local", T0)
	cloud.seed("saves", "slot1.sav", "cloud", T0 + 50)
	var got := []
	w["s"].before_launch(w["gog"], func(r): got.append(r))
	ok(got[0].has("conflict"), "a conflict at launch")
	w["running"][0] = true
	w["calls"].clear()
	var answers := []
	for choice in ["cloud", "local"]:
		ok(not w["s"].resolve(w["gog"], choice, func(st): answers.append(st["state"])), choice + ": refused while the game runs")
	eq(w["calls"], [], "no tool ran")
	eq(answers, ["conflict", "conflict"], "the caller hears the conflict still stands")
	eq(FileAccess.get_file_as_string(w["gsaves"].path_join("slot1.sav")), "local", "the folder is untouched")
	eq(w["s"].status(w["gog"])["state"], "conflict", "still a conflict to settle")
	ok(not w["s"].busy("gog:1207"), "not marked busy")
	w["running"][0] = false
	ok(w["s"].resolve(w["gog"], "cloud"), "after the game: goes ahead")
	eq(FileAccess.get_file_as_string(w["gsaves"].path_join("slot1.sav")), "cloud", "the cloud save is in place")
	_done(w)


# ---- backups ------------------------------------------------------------------------------------

## Restoring a backup makes the folder what the backup holds: slots made since don't stay
## (they were merged in before), and a restore that can't unpack changes nothing.
func test_restore_replaces_the_folder() -> void:
	var w := _world("restore_replace")
	var bk: RefCounted = w["s"].backups
	Fakes.put(w["esaves"].path_join("slot1.sav"), "one", T0)
	Fakes.put(w["esaves"].path_join("sub/meta.dat"), "meta", T0)
	var b: Dictionary = bk.backup("epic:Min", "M", "before_download", [{"name": "saves", "path": w["esaves"]}])
	Fakes.put(w["esaves"].path_join("slot1.sav"), "one, later", T0 + 500)
	Fakes.put(w["esaves"].path_join("slot2.sav"), "made after the backup", T0 + 500)
	Fakes.put(w["esaves"].path_join("newdir/x.dat"), "also after", T0 + 500)
	# a link out of the folder must never be followed when the old contents go
	var outside: String = w["root"].path_join("outside")
	Fakes.put(outside.path_join("keep.txt"), "not ours")
	OS.execute("ln", ["-s", outside, w["esaves"].path_join("link")])
	var r: Dictionary = bk.restore("epic:Min", str(b["id"]))
	ok(r["ok"], "restored")
	eq(Fakes.walk(w["esaves"]), ["slot1.sav", "sub/meta.dat"], "exactly what the backup holds")
	eq(FileAccess.get_file_as_string(w["esaves"].path_join("slot1.sav")), "one", "the backed up content")
	eq(FileAccess.get_file_as_string(outside.path_join("keep.txt")), "not ours", "what a link pointed at is untouched")
	ok(not DirAccess.dir_exists_absolute(w["esaves"] + ".gamecove-restore") and not DirAccess.dir_exists_absolute(w["esaves"] + ".gamecove-old"), "no working folders left")
	# a damaged backup file: the folder stays as it is
	Fakes.put(w["esaves"].path_join("slot3.sav"), "current", T0 + 900)
	Fakes.put(bk.dir_for("epic:Min").path_join(str(bk.find("epic:Min", str(b["id"]))["parts"][0]["file"])), "not a tar file")
	var bad: Dictionary = bk.restore("epic:Min", str(b["id"]))
	ok(not bad["ok"], "a damaged backup doesn't restore")
	eq(Fakes.walk(w["esaves"]), ["slot1.sav", "slot3.sav", "sub/meta.dat"], "and the folder is as it was")
	_done(w)


## Ten launches don't rotate out the backup of a conflict choice or a copy of the cloud:
## those have their own ten.
func test_rotation_keeps_conflict_and_cloud_copies() -> void:
	var w := _world("rotation")
	var bk: RefCounted = w["s"].backups
	var parts := [{"name": "saves", "path": w["esaves"]}]
	Fakes.put(w["esaves"].path_join("slot1.sav"), "the save a conflict choice replaced", T0)
	var kept: Dictionary = bk.backup("epic:Min", "M", "before_upload", parts, true, true)
	var copy: Dictionary = bk.backup("epic:Min", "M", "cloud_copy", parts, true, true)
	for i in 14:
		Fakes.put(w["esaves"].path_join("slot1.sav"), "launch %d" % i, T0 + 100 + i)
		bk.backup("epic:Min", "M", "before_download", parts)
	var all: Array = bk.list("epic:Min")
	eq(all.filter(func(b): return not bool(b.get("pinned", false))).size(), 10, "ten everyday backups")
	ok(not bk.find("epic:Min", str(kept["id"])).is_empty(), "the conflict backup outlives fourteen launches")
	ok(not bk.find("epic:Min", str(copy["id"])).is_empty(), "so does the cloud copy")
	for i in 12:
		bk.backup("epic:Min", "M", "before_upload", parts, true, true)
	eq(bk.list("epic:Min").filter(func(b): return bool(b.get("pinned", false))).size(), 10, "and those are capped at ten of their own")
	eq(bk.list("epic:Min").size(), 20, "twenty at most per game")
	_done(w)


## L2: with the clock behind (no network time yet after a flat battery) a new backup's stamp
## sorted before the older ones, so rotation dropped the backup just made, and backup() said ok.
func test_rotation_with_the_clock_behind_keeps_the_new_backup() -> void:
	var w := _world("rotation_clock")
	var bk: RefCounted = w["s"].backups
	var parts := [{"name": "saves", "path": w["esaves"]}]
	var t := [T0 + 100000]
	bk.clock = func() -> int: return int(t[0])
	for i in 10:
		t[0] += 10
		Fakes.put(w["esaves"].path_join("slot1.sav"), "launch %d" % i, T0 + i)
		bk.backup("epic:Min", "M", "before_download", parts)
	t[0] = T0 - 86400 * 365   # the clock a year behind
	Fakes.put(w["esaves"].path_join("slot1.sav"), "the save before this download", T0 + 50)
	var b: Dictionary = bk.backup("epic:Min", "M", "before_download", parts)
	ok(b["ok"], "made")
	ok(not bk.find("epic:Min", str(b["id"])).is_empty(), "and kept")
	eq(str(bk.list("epic:Min")[0]["id"]), str(b["id"]), "it's the newest, whatever its stamp")
	eq(bk.list("epic:Min").size(), 10, "the oldest one made went instead")
	_done(w)


## L3: a backup of two folders whose second can't be unpacked used to leave the first one
## restored and the second not: a save from two different times. All or nothing now.
func test_a_two_folder_restore_is_all_or_nothing() -> void:
	var w := _world("restore_atomic")
	var bk: RefCounted = w["s"].backups
	var a: String = w["root"].path_join("a")
	var b2: String = w["root"].path_join("b")
	Fakes.put(a.path_join("slot.sav"), "a then", T0)
	Fakes.put(b2.path_join("keys.ini"), "b then", T0)
	var b: Dictionary = bk.backup("gog:1207", "W", "before_download", [{"name": "saves", "path": a}, {"name": "cfg", "path": b2}])
	Fakes.put(a.path_join("slot.sav"), "a now", T0 + 10)
	Fakes.put(b2.path_join("keys.ini"), "b now", T0 + 10)
	# the second folder's archive is damaged
	var second: String = bk.dir_for("gog:1207").path_join(str(bk.find("gog:1207", str(b["id"]))["parts"][1]["file"]))
	Fakes.put(second, "not a tar file")
	var r: Dictionary = bk.restore("gog:1207", str(b["id"]))
	ok(not r["ok"], "the restore fails")
	eq(FileAccess.get_file_as_string(a.path_join("slot.sav")), "a now", "and the first folder wasn't touched either")
	eq(FileAccess.get_file_as_string(b2.path_join("keys.ini")), "b now", "nor the second")
	eq(Array(DirAccess.get_directories_at(w["root"])).filter(func(d): return d.contains(".gamecove-")), [], "nothing left next to them")
	_done(w)


## L4: a save folder with a linked subfolder (the tools follow links, so its files are part of
## the save) was backed up as the bare link: the files themselves weren't in the backup.
func test_a_linked_subfolder_is_backed_up_by_its_files() -> void:
	var w := _world("backup_link")
	var bk: RefCounted = w["s"].backups
	var outside: String = w["root"].path_join("elsewhere")
	Fakes.put(outside.path_join("slot2.sav"), "the linked slot", T0)
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "slot 1", T0)
	OS.execute("ln", ["-s", outside, w["gsaves"].path_join("more")])
	var b: Dictionary = bk.backup("gog:1207", "W", "before_download", [{"name": "saves", "path": w["gsaves"]}])
	ok(b["ok"], "backed up")
	_rm(outside)
	ok(bk.restore("gog:1207", str(b["id"]))["ok"], "restored")
	eq(FileAccess.get_file_as_string(w["gsaves"].path_join("more/slot2.sav")), "the linked slot", "the linked folder's file came back")
	_done(w)


## L5: the sheet shows the save as it was when the conflict was found. Changed since (played
## from Heroic), "keep the cloud" used to download over a save nobody had looked at.
func test_a_choice_on_a_save_that_changed_since_asks_again() -> void:
	var w := _world("resolve_changed")
	var cloud: Object = w["gog_cloud"]
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "local", T0)
	cloud.seed("saves", "slot1.sav", "cloud", T0 + 50)
	w["s"].sync_now(w["gog"])
	eq(w["s"].status(w["gog"])["state"], "conflict", "a conflict")
	w["now"][0] += 900
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "played on from Heroic", int(w["now"][0]))
	var got := []
	w["s"].resolve(w["gog"], "cloud", func(st): got.append(st))
	eq(FileAccess.get_file_as_string(w["gsaves"].path_join("slot1.sav")), "played on from Heroic", "nothing downloaded over it")
	eq(str(got[0]["state"]), "conflict", "asked again")
	eq(int(got[0]["local_bytes"]), "played on from Heroic".length(), "with what's there now")
	# asked again and chosen: it goes through
	w["s"].resolve(w["gog"], "cloud")
	eq(FileAccess.get_file_as_string(w["gsaves"].path_join("slot1.sav")), "cloud", "the cloud's save")
	_done(w)


## L6: with sync off for a game, its launch didn't wait for a restore still at work on the
## worker: the game could start while its folder was being swapped.
func test_a_launch_with_sync_off_waits_for_a_restore_at_work() -> void:
	var w := _world("launch_waits_restore")
	w["s"].set_enabled("gog:1207", false)
	var phases := []
	w["s"].finished.connect(func(_k, ph, _st): phases.append(ph))
	w["s"]._busy["gog:1207"] = "restore"   # a restore queued on the worker, not done yet
	var got := []
	w["s"].before_launch(w["gog"], func(r): got.append([r, phases.duplicate()]))
	eq(got.size(), 1, "the launch goes ahead once")
	eq(got[0][1], ["wait"], "after its turn on the worker, behind the restore")
	_done(w)


## L7: saves.cfg found damaged is set aside and read as empty, which switched sync back on for
## every game the user had switched off, and later writes failed unseen.
func test_a_damaged_saves_cfg_keeps_games_off_and_syncs_nothing() -> void:
	var w := _world("cfg_damaged")
	var cloud: Object = w["gog_cloud"]
	cloud.seed("saves", "slot1.sav", "cloud", T0)
	w["s"].set_enabled("gog:1207", false)
	var f := FileAccess.open(w["s"].cfg_path, FileAccess.WRITE)
	f.store_string("[game:gog:1207\nthis isn't a config file =")
	f.close()
	expect_error("ConfigFile parse error", 1)
	ok(not w["s"].enabled("gog:1207"), "a game switched off stays off")
	eq(w["s"].status(w["gog"])["state"], "off", "and says so")
	w["s"].set_enabled("gog:1207", true)
	var calls: int = w["calls"].size()
	w["s"].sync_now(w["gog"])
	eq(w["calls"].size(), calls, "with nowhere to keep what a sync does, nothing runs")
	eq(w["s"].status(w["gog"])["state"], "state_unsaved", "and the status says why")
	SettingsFile.reset_for_tests()
	_done(w)


## L7: a note that can't be written (a full disk) means no tool runs: a crash after it couldn't
## be put right.
func test_no_download_without_its_note() -> void:
	var w := _world("note_unwritable")
	var cloud: Object = w["gog_cloud"]
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "local", T0)
	w["s"].sync_now(w["gog"])
	cloud.seed("saves", "slot1.sav", "cloud, newer", int(w["now"][0]) + 500)
	w["now"][0] += 1000
	SettingsFile.test_write_limit = 0   # every write from here comes out short
	var got := []
	w["s"].before_launch(w["gog"], func(r): got.append(r))
	SettingsFile.reset_for_tests()
	eq(got, [{"go": true}], "the game still starts")
	eq(FileAccess.get_file_as_string(w["gsaves"].path_join("slot1.sav")), "local", "nothing downloaded without its note")
	_done(w)


## L8: the remote-config answer from behind a captive portal isn't kept; the next sync asks GOG again.
func test_a_captive_portal_answer_isnt_cached() -> void:
	var w := _world("captive")
	var install: String = w["gog"]["install_path"]
	_json(install.path_join("goggame-1207.info"), {"clientId": "53035488294233580"})
	_json(w["gog"]["heroic_root"].path_join("store_cache/gog_library.json"), {"games": []})
	var answers := ["<html>hotel wifi</html>"]
	var real: Callable = w["s"].run
	w["s"].run = func(program: String, args: PackedStringArray) -> Dictionary:
		if program == "curl":
			return {"code": 0, "out": answers[0]}
		return real.call(program, args)
	w["s"].sync_now(w["gog"])
	eq(w["s"].status(w["gog"])["state"], "offline", "said as offline, not 'no cloud saves'")
	var c := ConfigFile.new()
	c.load(w["s"].cfg_path)
	ok(not c.has_section_key("gog_remote", "53035488294233580"), "and nothing kept")
	answers[0] = JSON.stringify({"content": {"Windows": {"cloudStorage": {"enabled": true, "locations": []}}}})
	w["s"].sync_now(w["gog"])
	ok(w["s"].status(w["gog"])["state"] != "unsupported", "GOG's real answer next time (%s)" % w["s"].status(w["gog"])["state"])
	_done(w)


## The service marks the backups a choice or a restore made.
func test_choice_backups_are_kept_apart() -> void:
	var w := _world("pinned")
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "local", T0)
	w["gog_cloud"].seed("saves", "slot1.sav", "cloud", T0 + 50)
	w["s"].sync_now(w["gog"])
	eq(w["s"].status(w["gog"])["state"], "conflict", "a conflict")
	w["s"].resolve(w["gog"], "local")
	var by_reason := {}
	for b in w["s"].backup_list("gog:1207"):
		by_reason[b["reason"]] = bool(b.get("pinned", false))
	eq(by_reason.get("before_upload"), true, "the choice's backup")
	eq(by_reason.get("cloud_copy"), true, "the cloud copy")
	eq(by_reason.get("before_download"), false, "the everyday one from the sync")
	_done(w)


# ---- Epic: "Keep this handheld's save" holds ------------------------------------------------------

## legendary names an upload by the newest local file's time, and "the" cloud save is the
## newest name. An older local save, kept on purpose, went up and still lost to the cloud's.
func test_epic_keep_local_becomes_the_newest_cloud_save() -> void:
	var w := _world("epic_keep_local")
	var cloud: Object = w["epic_cloud"]
	cloud.saves.append({"t": T0 + 9000, "files": {"world.sav": "the other device's later save"}})
	Fakes.put(w["esaves"].path_join("world.sav"), "this handheld's older save", T0)
	Fakes.put(w["esaves"].path_join("options.ini"), "older still", T0 - 500)
	var got := []
	w["s"].before_launch(w["epic"], func(r): got.append(r))
	ok(got[0].has("conflict"), "never synced, both have saves: a conflict")
	w["s"].resolve(w["epic"], "local")
	eq(cloud.saves[-1]["files"]["world.sav"], "this handheld's older save", "the kept save is the cloud's newest")
	eq(cloud.saves.size(), 2, "the other one is still there in Epic's history")
	eq(FileAccess.get_file_as_string(w["esaves"].path_join("world.sav")), "this handheld's older save", "the file's content is untouched")
	eq(int(FileAccess.get_modified_time(w["esaves"].path_join("options.ini"))), T0 - 500, "only the newest file's time moved")
	# another device (or this one's next launch) now gets the kept save
	got.clear()
	w["s"].before_launch(w["epic"], func(r): got.append(r))
	eq(got, [{"go": true}], "the next launch starts")
	eq(FileAccess.get_file_as_string(w["esaves"].path_join("world.sav")), "this handheld's older save", "and nothing came down over it")
	_done(w)


# ---- high 5: the guard follows the game's processes (review at ff76ca4) ------------------------

## The session can end while the game still runs (app quitting, a launch given up on): a
## conflict choice, a restore and Sync now are still refused until its process is gone.
func test_choices_wait_for_the_games_processes_not_the_session() -> void:
	var w := _world("guard_processes")
	var GS := preload("res://scripts/launch/game_session.gd")
	var session: Node = GS.new()
	var alive := [true]
	session.pid_running = func(_p: int) -> bool: return alive[0]
	session.unit_alive = func(_u: String) -> bool: return false
	w["s"].game_running = func() -> bool: return session.processes_alive()
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "progress", T0)
	w["gog_cloud"].seed("saves", "slot1.sav", "cloud", T0 + 50)
	w["s"].sync_now(w["gog"])
	eq(w["s"].status(w["gog"])["state"], "conflict", "a conflict to settle")
	session.begin(w["gog"], {"ok": true, "app_id": 0, "pid": 4242})
	session.stop()
	eq(session.phase, "idle", "the session ended")
	ok(not w["s"].resolve(w["gog"], "cloud"), "the choice is refused: the game's process still runs")
	eq(FileAccess.get_file_as_string(w["gsaves"].path_join("slot1.sav")), "progress", "nothing swapped under it")
	var res := []
	w["s"].restore(w["gog"], "x", func(r): res.append(r))
	eq(res, [{"ok": false, "why": "running"}], "a restore too")
	var calls: int = w["calls"].size()
	w["s"].sync_now(w["gog"])
	eq(w["calls"].size(), calls, "and Sync now")
	alive[0] = false
	ok(w["s"].resolve(w["gog"], "cloud"), "gone: the choice goes ahead")
	eq(FileAccess.get_file_as_string(w["gsaves"].path_join("slot1.sav")), "cloud", "the cloud's save")
	session.free()
	_done(w)


# ---- high 6, GOG: a restore holds too (review at ff76ca4) ----------------------------------------

## Synced, then a bad session went up; the user restores the backup from before it. Another
## device uploads meanwhile. The next launch used to download straight over the restore
## (gogdl: only the cloud is newer than --ts, the restored files carry their old times).
func test_gog_restore_is_not_undone_at_the_next_launch() -> void:
	var w := _world("gog_restore")
	var cloud: Object = w["gog_cloud"]
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "before the bad day", T0)
	var bk: Dictionary = w["s"].backups.backup("gog:1207", "W", "before_download", [{"name": "saves", "path": w["gsaves"]}])
	w["s"].sync_now(w["gog"])
	w["now"][0] += 900
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "after the bad day", int(w["now"][0]))
	w["s"].after_exit(w["gog"])
	eq(cloud.cloud["saves/slot1.sav"]["data"], "after the bad day", "the bad save went up")
	var res := []
	w["s"].restore(w["gog"], str(bk["id"]), func(r): res.append(r))
	ok(res[0]["ok"], "restored")
	w["now"][0] += 900
	cloud.now = int(w["now"][0])
	cloud.seed("saves", "slot1.sav", "another device, also bad", int(w["now"][0]))
	var got := []
	w["s"].before_launch(w["gog"], func(r): got.append(r))
	ok(got.size() == 1 and got[0].has("conflict"), "the launch asks instead of downloading over the restore")
	eq(FileAccess.get_file_as_string(w["gsaves"].path_join("slot1.sav")), "before the bad day", "the restore is still in place")
	eq(got[0]["conflict"].get("prefer", ""), "local", "the restored side is offered first")
	w["s"].resolve(w["gog"], "local")
	eq(cloud.cloud["saves/slot1.sav"]["data"], "before the bad day", "kept: the restore is the cloud's save now")
	got.clear()
	w["s"].before_launch(w["gog"], func(r): got.append(r))
	eq(got, [{"go": true}], "the next launch just starts")
	eq(FileAccess.get_file_as_string(w["gsaves"].path_join("slot1.sav")), "before the bad day", "with the restored save")
	_done(w)


## The cloud didn't change since: the whole restore goes up after the game (gogdl alone saw
## nothing to do and the cloud kept the bad save; a played slot alone would have gone up,
## leaving the cloud a mix).
func test_gog_restore_goes_up_whole_when_the_cloud_didnt_change() -> void:
	var w := _world("gog_restore_up")
	var cloud: Object = w["gog_cloud"]
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "good 1", T0)
	Fakes.put(w["gsaves"].path_join("slot2.sav"), "good 2", T0)
	var bk: Dictionary = w["s"].backups.backup("gog:1207", "W", "before_download", [{"name": "saves", "path": w["gsaves"]}])
	w["s"].sync_now(w["gog"])
	w["now"][0] += 900
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "bad 1", int(w["now"][0]))
	Fakes.put(w["gsaves"].path_join("slot2.sav"), "bad 2", int(w["now"][0]))
	w["s"].sync_now(w["gog"])
	eq(cloud.cloud["saves/slot2.sav"]["data"], "bad 2", "the bad saves went up")
	w["s"].restore(w["gog"], str(bk["id"]))
	var got := []
	w["s"].before_launch(w["gog"], func(r): got.append(r))
	eq(got, [{"go": true}], "the game starts")
	eq(w["s"].status(w["gog"])["state"], "pending_up", "the restore waits to go up after the game")
	w["now"][0] += 900
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "good 1, played on", int(w["now"][0]))
	w["s"].after_exit(w["gog"])
	eq(cloud.cloud["saves/slot1.sav"]["data"], "good 1, played on", "the played slot went up")
	eq(cloud.cloud["saves/slot2.sav"]["data"], "good 2", "and the restored slot that wasn't played")
	eq(w["s"].status(w["gog"])["state"], "uploaded", "uploaded")
	eq(int(_cfg(w, "gog:1207", "restored_at", 0)), 0, "settled")
	_done(w)


# ---- high 6: an Epic restore holds ---------------------------------------------------------------

## A restored backup has old file times, so legendary sees "cloud newer" and the next launch
## used to download straight over the restore.
func test_epic_restore_is_not_undone_at_the_next_launch() -> void:
	var w := _world("epic_restore")
	var cloud: Object = w["epic_cloud"]
	Fakes.put(w["esaves"].path_join("world.sav"), "before the bad day", T0)
	var bk: Dictionary = w["s"].backups.backup("epic:Min", "M", "before_download", [{"name": "saves", "path": w["esaves"]}])
	Fakes.put(w["esaves"].path_join("world.sav"), "after the bad day", T0 + 5000)
	w["s"].sync_now(w["epic"])
	eq(cloud.saves[-1]["files"]["world.sav"], "after the bad day", "the bad save is the cloud's newest")
	var res := []
	w["s"].restore(w["epic"], str(bk["id"]), func(r): res.append(r))
	ok(res[0]["ok"], "restored")
	eq(FileAccess.get_file_as_string(w["esaves"].path_join("world.sav")), "before the bad day", "the old save is back")
	var before: int = w["s"].backup_list("epic:Min").size()
	var got := []
	w["s"].before_launch(w["epic"], func(r): got.append(r))
	ok(got[0].has("conflict"), "the launch asks instead of downloading over the restore")
	eq(FileAccess.get_file_as_string(w["esaves"].path_join("world.sav")), "before the bad day", "the restore is still in place")
	var added: Array = w["s"].backup_list("epic:Min").slice(0, w["s"].backup_list("epic:Min").size() - before)
	eq(added.map(func(b): return b["reason"]), ["cloud_copy"], "no everyday backup slot used up: only a copy of the cloud's save")
	eq(got[0]["conflict"].get("prefer", ""), "local", "the restored side is the one offered first")
	# keeping it makes it the cloud's newest
	w["s"].resolve(w["epic"], "local")
	eq(cloud.saves[-1]["files"]["world.sav"], "before the bad day", "the restored save is now the newest cloud save")
	eq(w["s"].status(w["epic"]).get("prefer", ""), "", "settled")
	got.clear()
	w["s"].before_launch(w["epic"], func(r): got.append(r))
	eq(got, [{"go": true}], "the next launch just starts")
	eq(FileAccess.get_file_as_string(w["esaves"].path_join("world.sav")), "before the bad day", "with the restored save")
	_done(w)


## Playing on from the restore without choosing: the new save goes up after the game.
func test_epic_restore_then_play_uploads() -> void:
	var w := _world("epic_restore_play")
	var cloud: Object = w["epic_cloud"]
	Fakes.put(w["esaves"].path_join("world.sav"), "good", T0)
	var bk: Dictionary = w["s"].backups.backup("epic:Min", "M", "before_download", [{"name": "saves", "path": w["esaves"]}])
	Fakes.put(w["esaves"].path_join("world.sav"), "bad", T0 + 5000)
	w["s"].sync_now(w["epic"])
	w["s"].restore(w["epic"], str(bk["id"]))
	w["now"][0] += 900
	Fakes.put(w["esaves"].path_join("world.sav"), "good, continued", int(w["now"][0]))
	w["s"].after_exit(w["epic"])
	eq(cloud.saves[-1]["files"]["world.sav"], "good, continued", "what was played from the restore is the newest cloud save")
	eq(w["s"].status(w["epic"])["state"], "uploaded", "uploaded")
	_done(w)


## GOG: gogdl compares file times with the sync time, so a restored (older) save is left
## alone at the next launch and what is played from it goes up.
func test_gog_restore_holds_too() -> void:
	var w := _world("gog_restore")
	var cloud: Object = w["gog_cloud"]
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "good", T0)
	var bk: Dictionary = w["s"].backups.backup("gog:1207", "W", "before_download", [{"name": "saves", "path": w["gsaves"]}])
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "bad", T0 + 5000)
	w["s"].sync_now(w["gog"])
	eq(cloud.cloud["saves/slot1.sav"]["data"], "bad", "the bad save is in the cloud")
	w["s"].restore(w["gog"], str(bk["id"]))
	var got := []
	w["s"].before_launch(w["gog"], func(r): got.append(r))
	eq(got, [{"go": true}], "the launch starts")
	eq(FileAccess.get_file_as_string(w["gsaves"].path_join("slot1.sav")), "good", "with the restored save")
	w["now"][0] += 900
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "good, continued", int(w["now"][0]))
	w["s"].after_exit(w["gog"])
	eq(cloud.cloud["saves/slot1.sav"]["data"], "good, continued", "and what was played from it goes up")
	_done(w)


# ---- GOG: two save locations ----------------------------------------------------------------------

## A second location on the game (settings next to saves).
func _two_locations(w: Dictionary) -> String:
	_json(w["gog"]["heroic_root"].path_join("store_cache/gog_library.json"), {"games": [{"app_name": "1207", "cloud_save_enabled": true,
		"gog_save_location": [{"name": "saves", "location": "<?DOCUMENTS?>/Witcher"}, {"name": "cfg", "location": "<?APPLICATION_DATA_LOCAL?>/Witcher"}]}]})
	return w["user"].path_join("AppData/Local/Witcher")


## Location 1 downloads, location 2 fails, the backup of both goes back. Location 1's sync
## time used to move on anyway: its newer cloud files were then never fetched again, and
## the next upload put the old local ones over them.
func test_gog_a_failed_location_rolls_the_sync_times_back_too() -> void:
	var w := _world("gog_two")
	var cloud: Object = w["gog_cloud"]
	var cfgdir := _two_locations(w)
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "hour 1", T0)
	Fakes.put(cfgdir.path_join("keys.ini"), "wasd", T0)
	w["s"].sync_now(w["gog"])
	eq(w["s"].status(w["gog"])["state"], "uploaded", "both locations synced")
	var before: Dictionary = _cfg(w, "gog:1207", "gog_ts", {})
	# another device plays on: both locations are newer in the cloud
	w["now"][0] += 5000
	cloud.cloud["saves/slot1.sav"] = {"data": "hour 9", "t": int(w["now"][0]), "lt": int(w["now"][0]), "hash": "h9"}
	cloud.cloud["cfg/keys.ini"] = {"data": "arrows", "t": int(w["now"][0]), "lt": int(w["now"][0]), "hash": "ar"}
	w["now"][0] += 100
	cloud.fail_names = ["cfg"]
	var got := []
	w["s"].before_launch(w["gog"], func(r): got.append(r))
	eq(got, [{"go": true}], "the game still starts")
	eq(FileAccess.get_file_as_string(w["gsaves"].path_join("slot1.sav")), "hour 1", "everything was put back as it was")
	eq(_cfg(w, "gog:1207", "gog_ts", {}), before, "and so were the sync times")
	# next time GOG answers: location 1's cloud save still comes down
	cloud.fail_names = []
	got.clear()
	w["s"].before_launch(w["gog"], func(r): got.append(r))
	eq(FileAccess.get_file_as_string(w["gsaves"].path_join("slot1.sav")), "hour 9", "the other device's progress arrives")
	eq(FileAccess.get_file_as_string(cfgdir.path_join("keys.ini")), "arrows", "in both locations")
	_done(w)


## After a game it's the other way round: an upload that went through stays through.
func test_gog_a_failed_location_after_play_keeps_what_was_uploaded() -> void:
	var w := _world("gog_two_post")
	var cloud: Object = w["gog_cloud"]
	var cfgdir := _two_locations(w)
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "hour 1", T0)
	Fakes.put(cfgdir.path_join("keys.ini"), "wasd", T0)
	w["s"].sync_now(w["gog"])
	w["now"][0] += 900
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "hour 2", int(w["now"][0]))
	Fakes.put(cfgdir.path_join("keys.ini"), "esdf", int(w["now"][0]))
	cloud.fail_names = ["cfg"]
	w["s"].after_exit(w["gog"])
	eq(cloud.cloud["saves/slot1.sav"]["data"], "hour 2", "location 1 went up")
	cloud.fail_names = []
	w["now"][0] += 100
	w["s"].after_exit(w["gog"])
	eq(w["s"].status(w["gog"])["state"], "upload_finished", "the retry finishes the cut upload (location 2) without calling location 1 a conflict")
	eq(cloud.cloud["saves/slot1.sav"]["data"], "hour 2", "location 1 stays as uploaded")
	eq(cloud.cloud["cfg/keys.ini"]["data"], "esdf", "location 2 went up")
	_done(w)


# ---- an upload cut short (review at ff76ca4, medium) --------------------------------------------

## Two slots changed, the upload is killed after one (the 90 s cap): the cloud is a mix of a
## new slot 1 and an old slot 2. The note stays, the status says so, and the next sync, before
## anything else, finishes it (a copy of the cloud first): never a download of the mix.
func test_gog_cut_upload_is_finished_before_anything_else() -> void:
	var w := _world("gog_cut_upload")
	var cloud: Object = w["gog_cloud"]
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "hour 1", T0)
	Fakes.put(w["gsaves"].path_join("slot2.sav"), "hour 1", T0)
	w["s"].sync_now(w["gog"])
	w["now"][0] += 900
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "hour 2", int(w["now"][0]))
	Fakes.put(w["gsaves"].path_join("slot2.sav"), "hour 2", int(w["now"][0]))
	cloud.cut_upload_after = 1
	w["s"].after_exit(w["gog"])
	eq([cloud.cloud["saves/slot1.sav"]["data"], cloud.cloud["saves/slot2.sav"]["data"]], ["hour 2", "hour 1"], "cut: the cloud is a mix")
	eq(w["s"].status(w["gog"])["state"], "upload_cut", "the status says the upload was cut off")
	ok(not Dictionary(_cfg(w, "gog:1207", "uploading", {})).is_empty(), "and the note stays")
	# another device downloading the mix is beyond us; here, the next launch finishes it first
	cloud.cut_upload_after = -1
	cloud.did.clear()
	var got := []
	w["s"].before_launch(w["gog"], func(r): got.append(r))
	eq(got, [{"go": true}], "the game starts")
	eq([cloud.cloud["saves/slot1.sav"]["data"], cloud.cloud["saves/slot2.sav"]["data"]], ["hour 2", "hour 2"], "the upload is finished")
	ok(cloud.did.filter(func(x): return str(x).begins_with("download")).size() > 0 and Fakes.walk(w["gsaves"]) == ["slot1.sav", "slot2.sav"], "after a copy of the cloud (fetched into a scratch folder)")
	eq(FileAccess.get_file_as_string(w["gsaves"].path_join("slot2.sav")), "hour 2", "nothing of the mix came down here")
	eq(w["s"].status(w["gog"])["state"], "upload_finished", "and the status says so in plain words")
	eq(_cfg(w, "gog:1207", "uploading", {}), {}, "the note is gone")
	eq(w["s"].backup_list("gog:1207").filter(func(b): return b["reason"] == "cloud_copy").size(), 1, "the mix is kept as a cloud copy")
	_done(w)


## While it can't be finished (offline), nothing else syncs for that game: no download of the mix.
func test_gog_cut_upload_blocks_other_syncs_until_finished() -> void:
	var w := _world("gog_cut_upload_offline")
	var cloud: Object = w["gog_cloud"]
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "hour 1", T0)
	Fakes.put(w["gsaves"].path_join("slot2.sav"), "hour 1", T0)
	w["s"].sync_now(w["gog"])
	w["now"][0] += 900
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "hour 2", int(w["now"][0]))
	Fakes.put(w["gsaves"].path_join("slot2.sav"), "hour 2", int(w["now"][0]))
	cloud.cut_upload_after = 1
	w["s"].after_exit(w["gog"])
	cloud.cut_upload_after = -1
	# someone else's newer slot 2 lands in the cloud meanwhile; we're offline at the launch
	cloud.offline = true
	var got := []
	w["s"].before_launch(w["gog"], func(r): got.append(r))
	eq(got, [{"go": true}], "offline: the game starts")
	eq(w["s"].status(w["gog"])["state"], "upload_cut", "still waiting to finish")
	eq(FileAccess.get_file_as_string(w["gsaves"].path_join("slot2.sav")), "hour 2", "this handheld's save untouched")
	ok(not Dictionary(_cfg(w, "gog:1207", "uploading", {})).is_empty(), "the note stays for the next try")
	cloud.offline = false
	_done(w)


## Played on elsewhere since the cut (from Heroic): finishing would mix again. A copy of the
## cloud is kept and we ask.
func test_gog_cut_upload_changed_since_asks() -> void:
	var w := _world("gog_cut_upload_changed")
	var cloud: Object = w["gog_cloud"]
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "hour 1", T0)
	Fakes.put(w["gsaves"].path_join("slot2.sav"), "hour 1", T0)
	w["s"].sync_now(w["gog"])
	w["now"][0] += 900
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "hour 2", int(w["now"][0]))
	Fakes.put(w["gsaves"].path_join("slot2.sav"), "hour 2", int(w["now"][0]))
	cloud.cut_upload_after = 1
	w["s"].after_exit(w["gog"])
	cloud.cut_upload_after = -1
	w["now"][0] += 900
	Fakes.put(w["gsaves"].path_join("slot2.sav"), "hour 3, from Heroic", int(w["now"][0]))
	var got := []
	w["s"].before_launch(w["gog"], func(r): got.append(r))
	ok(got.size() == 1 and got[0].has("conflict"), "we ask")
	eq(FileAccess.get_file_as_string(w["gsaves"].path_join("slot2.sav")), "hour 3, from Heroic", "nothing came down over it")
	ok(w["s"].backup_list("gog:1207").any(func(b): return b["reason"] == "cloud_copy"), "the cloud's mix is kept as a copy")
	eq(_cfg(w, "gog:1207", "uploading", {}), {}, "the note is settled")
	_done(w)


## Epic: an upload killed before legendary wrote its manifest. The next start (the Library
## loading) finishes it on its own, and says so.
func test_epic_cut_upload_is_finished_at_the_next_start() -> void:
	var w := _world("epic_cut_upload")
	var cloud: Object = w["epic_cloud"]
	Fakes.put(w["esaves"].path_join("world.sav"), "hour 1", T0)
	w["s"].sync_now(w["epic"])
	w["now"][0] += 900
	Fakes.put(w["esaves"].path_join("world.sav"), "hour 2", int(w["now"][0]))
	cloud.cut_upload = true
	w["s"].after_exit(w["epic"])
	eq(cloud.saves[-1]["files"]["world.sav"], "hour 1", "cut before the manifest")
	eq(w["s"].status(w["epic"])["state"], "upload_cut", "said so")
	cloud.cut_upload = false
	# the next start: a fresh service, the Library comes up
	var lib := RepairLibrary.new()
	var phases := []
	w["s"].finished.connect(func(k, ph, st): phases.append([k, ph, st]))
	w["s"].setup_library(lib)
	w["s"].entry_lookup = func(k: String) -> Dictionary: return w["entries"].get(k, {}).duplicate()
	lib.changed.emit()
	eq(phases, [["epic:Min", "repair", "upload_finished"]], "finished at the start, before any launch")
	eq(cloud.saves[-1]["files"]["world.sav"], "hour 2", "the save is up")
	lib.changed.emit()
	eq(phases.size(), 1, "once")
	lib.free()
	_done(w)


class RepairLibrary extends Node:
	signal changed


# ---- high 10: a download cut short ------------------------------------------------------------------

## An empty folder, the first download killed by the timeout: the half file used to stay,
## look newer than the cloud, and send the post-game upload deleting cloud files.
func test_gog_cut_first_download_leaves_nothing_behind() -> void:
	var w := _world("gog_cut")
	var cloud: Object = w["gog_cloud"]
	for slot in ["slot1.sav", "slot2.sav", "slot3.sav"]:
		cloud.seed("saves", slot, "progress " + slot, T0)
	cloud.cut_download_after = 1
	var got := []
	w["s"].before_launch(w["gog"], func(r): got.append(r))
	eq(got, [{"go": true}], "the game still starts")
	eq(Fakes.walk(w["gsaves"]), [], "what the cut download wrote is gone (the folder was empty before)")
	eq(str(Dictionary(_cfg(w, "gog:1207", "gog_ts", {})).get("saves", "0")), "0", "and no sync time is kept")
	ok(w["s"].status(w["gog"])["state"] in ["offline", "failed"], "the status says it didn't sync")
	eq(_cfg(w, "gog:1207", "pending", {}), {}, "nothing left to put right")
	# the game didn't save anything; after it, the download simply happens
	cloud.cut_download_after = -1
	cloud.did.clear()
	w["s"].after_exit(w["gog"])
	eq(cloud.files("saves"), ["slot1.sav", "slot2.sav", "slot3.sav"], "the cloud is whole")
	ok(cloud.did.filter(func(x): return str(x).begins_with("delete") or str(x).begins_with("upload")).is_empty(), "nothing was uploaded or deleted")
	_done(w)


## The same for Epic: legendary empties the folder, then writes; cut short with nothing to
## put back, the half file would be "local newer" and go up as the newest cloud save.
func test_epic_cut_first_download_leaves_nothing_behind() -> void:
	var w := _world("epic_cut")
	var cloud: Object = w["epic_cloud"]
	cloud.saves.append({"t": T0, "files": {"world.sav": "40 hours"}})
	cloud.cut_download = true
	var got := []
	w["s"].before_launch(w["epic"], func(r): got.append(r))
	eq(got, [{"go": true}], "the game still starts")
	eq(Fakes.walk(w["esaves"]), [], "the half-written file is gone")
	cloud.cut_download = false
	w["s"].after_exit(w["epic"])
	eq(cloud.saves.size(), 1, "nothing was uploaded after the game")
	eq(cloud.saves[-1]["files"]["world.sav"], "40 hours", "the cloud save is intact")
	_done(w)


## The app (or the handheld) dies in the middle of a download: no code of ours runs to put
## the backup back. The next sync finds the note left before the download and does it then,
## keeping what it found first.
func test_a_download_cut_by_a_crash_is_put_right_at_the_next_sync() -> void:
	var w := _world("crash")
	var cloud: Object = w["gog_cloud"]
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "hour 1", T0)
	Fakes.put(w["gsaves"].path_join("slot2.sav"), "second slot", T0)
	w["s"].sync_now(w["gog"])
	w["now"][0] += 5000
	cloud.cloud["saves/slot1.sav"] = {"data": "hour 9", "t": int(w["now"][0]), "lt": int(w["now"][0]), "hash": "h9"}
	cloud.cloud["saves/slot2.sav"] = {"data": "second slot, later", "t": int(w["now"][0]), "lt": int(w["now"][0]), "hash": "s2"}
	w["now"][0] += 100
	# the crash: the tool is cut after one file and the service never gets to clean up
	var inner: Callable = w["s"].run
	var frozen := [""]
	w["s"].run = func(program: String, args: PackedStringArray) -> Dictionary:
		if program != "tar" and "--skip-upload" in args and frozen[0] == "":
			cloud.cut_download_after = 1
			inner.call(program, args)
			cloud.cut_download_after = -1
			frozen[0] = FileAccess.get_file_as_string(w["s"].cfg_path)
			return {"code": 124, "out": ""}
		return inner.call(program, args)
	var got := []
	w["s"].before_launch(w["gog"], func(r): got.append(r))
	ok(frozen[0].contains("pending"), "a note is written before the download starts")
	# put the world back to the instant of the crash: the note on disk, the folder half replaced
	Fakes.put(w["s"].cfg_path, frozen[0])
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "hour 9", int(w["now"][0]))
	Fakes.put(w["gsaves"].path_join("slot2.sav"), "s")
	w["s"].run = inner
	cloud.offline = true   # and the next launch has no connection
	got.clear()
	w["s"].before_launch(w["gog"], func(r): got.append(r))
	eq(got, [{"go": true}], "the game starts")
	eq(FileAccess.get_file_as_string(w["gsaves"].path_join("slot2.sav")), "second slot", "the half-written slot is whole again (the backup from before the download)")
	eq(FileAccess.get_file_as_string(w["gsaves"].path_join("slot1.sav")), "hour 1", "the folder is as it was before the download")
	ok(w["s"].backup_list("gog:1207").any(func(b): return b["reason"] == "interrupted"), "what was found is kept as a backup too")
	eq(_cfg(w, "gog:1207", "pending", {}), {}, "the note is gone")
	cloud.offline = false
	got.clear()
	w["s"].before_launch(w["gog"], func(r): got.append(r))
	ok(got[0].has("conflict") or FileAccess.get_file_as_string(w["gsaves"].path_join("slot1.sav")) == "hour 9", "and the next sync asks or downloads: it never uploads over the cloud")
	eq(cloud.cloud["saves/slot2.sav"]["data"], "second slot, later", "the cloud is untouched")
	_done(w)


# ---- GOG: "refused" isn't "synced" ---------------------------------------------------------------

## After a game the cloud turns out newer (another device) and nothing changed here: gogdl
## refuses to upload. That was shown as "Saves synced" and moved the last sync time.
func test_gog_refused_is_shown_as_waiting() -> void:
	var w := _world("gog_refused")
	var cloud: Object = w["gog_cloud"]
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "hour 1", T0)
	w["s"].sync_now(w["gog"])
	var synced_at := int(_cfg(w, "gog:1207", "last_sync", 0))
	w["now"][0] += 5000
	cloud.cloud["saves/slot1.sav"] = {"data": "hour 9", "t": int(w["now"][0]), "lt": int(w["now"][0]), "hash": "h9"}
	w["now"][0] += 100
	w["s"].after_exit(w["gog"])
	var st: Dictionary = w["s"].status(w["gog"])
	eq(st["state"], "pending_down", "the cloud's newer save waits for the next launch")
	eq(st["last_sync"], synced_at, "and that wasn't a sync")
	# the other way: before a launch, this handheld is newer
	var got := []
	w["s"].before_launch(w["gog"], func(r): got.append(r))
	eq(w["s"].status(w["gog"])["state"], "downloaded", "the next launch brings it down")
	w["now"][0] += 900
	Fakes.put(w["gsaves"].path_join("slot1.sav"), "hour 10", int(w["now"][0]))
	got.clear()
	w["s"].before_launch(w["gog"], func(r): got.append(r))
	eq(got, [{"go": true}], "starts")
	eq(w["s"].status(w["gog"])["state"], "pending_up", "a newer save here waits for the game to end")
	_done(w)
