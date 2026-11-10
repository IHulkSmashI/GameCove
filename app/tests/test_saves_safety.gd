extends "res://tests/test_case.gd"
## Cloud saves never lose a save (final review, blocker 1 and the saves findings after it).
## gogdl and legendary are the ports in tests/fixtures/saves/fake_clouds.gd, which do to a
## cloud and a folder what the real tools would; tar is real; everything lives under user://.

const Service := preload("res://scripts/system/saves_service.gd")
const CloudSaves := preload("res://scripts/system/cloud_saves.gd")
const ExecSafe := preload("res://scripts/system/exec_safe.gd")
const Fakes := preload("res://tests/fixtures/saves/fake_clouds.gd")
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
		return gc.run(rest) if tool == "gogdl" else ec.run(rest)
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
