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
	eq(w["s"].backup_list("epic:Min").size(), before, "and no backup slot was used up")
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
	eq(w["s"].status(w["gog"])["state"], "uploaded", "the retry finishes location 2 without calling location 1 a conflict")
	eq(cloud.cloud["cfg/keys.ini"]["data"], "esdf", "location 2 went up")
	_done(w)
