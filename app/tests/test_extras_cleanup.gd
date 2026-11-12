extends "res://tests/test_case.gd"
## Clean up: Storage's leftover shader caches (games no longer installed) on a
## throwaway Steam tree, and the Storage page's Clean up card. du is faked;
## the folders are real (under user://), so removal is checked for real.

const StorageScript := preload("res://scripts/system/storage.gd")
const StoragePanel := preload("res://scripts/ui/device/storage_panel.gd")
const Fake := preload("res://tests/fixtures/system/fake_runner.gd")
const TX := preload("res://scripts/ui/texts_extras.gd")

const BASE := "user://test_extras_cleanup"


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


func _touch(path: String, text := "x") -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## home/.local/share/Steam (game 10 installed, cache of removed game 20 and a
## non-Steam shortcut's) plus an SD library (game 30 installed there, its
## cache left in the internal library, and a removed game 40's cache).
func _tree(name: String) -> Dictionary:
	var root := ProjectSettings.globalize_path(BASE).path_join(name)
	_rm(root)
	var home := root.path_join("home")
	var steam := home.path_join(".local/share/Steam")
	var sd := root.path_join("sd/SteamLibrary")
	_touch(steam.path_join("steamapps/libraryfolders.vdf"),
		"\"libraryfolders\"\n{\n\t\"0\"\n\t{\n\t\t\"path\"\t\t\"%s\"\n\t}\n\t\"1\"\n\t{\n\t\t\"path\"\t\t\"%s\"\n\t}\n}\n" % [steam, sd])
	_touch(steam.path_join("steamapps/appmanifest_10.acf"))
	_touch(sd.path_join("steamapps/appmanifest_30.acf"))
	for id in ["10", "20", "30", "3000000001"]:
		_touch(steam.path_join("steamapps/shadercache/%s/fozpipelinesv6/steamapp_pipeline_cache.foz" % id))
	_touch(sd.path_join("steamapps/shadercache/40/DXVK_state_cache/x.dxvk-cache"))
	var f: RefCounted = Fake.new()
	f.handler = func(cmd: String) -> Variant:
		if cmd.begins_with("du -sbc "):
			var n := cmd.split(" ").size() - 2
			return {"code": 0, "out": "1000\tdir\n".repeat(n) + "%d\ttotal\n" % (n * 1000)}
		return null
	var s: Node = StorageScript.new()
	s.setup(f, home)
	return {"root": root, "home": home, "steam": steam, "sd": sd, "s": s, "fake": f}


func test_leftovers_are_uninstalled_steam_games_only() -> void:
	var t := _tree("find")
	var dirs: Array = StorageScript.leftover_dirs(t.s.steam_library_paths())
	var ids: Array = dirs.map(func(d): return str(d).get_file())
	ids.sort()
	eq(ids, ["20", "40"], "removed games only: installed ones (even in another library) and shortcuts stay")
	t.s.free()
	_rm(t.root)


## A library nothing was launched from has no shadercache folder: not an error (the engine
## logs one for listing a missing folder; monkey seed 109000 met it on the Storage page).
func test_a_library_without_a_shader_cache_folder_is_quiet() -> void:
	var t := _tree("nocache")
	_rm(t.sd.path_join("steamapps/shadercache"))
	var ids: Array = StorageScript.leftover_dirs(t.s.steam_library_paths()).map(func(d): return str(d).get_file())
	ids.sort()
	eq(ids, ["20"], "the other library's leftovers are still found")
	_rm(t.steam.path_join("steamapps/shadercache"))
	eq(StorageScript.leftover_dirs(t.s.steam_library_paths()), [], "and with no cache folders at all, nothing and no engine error")
	t.s.free()
	_rm(t.root)


func test_measure_then_clean() -> void:
	var t := _tree("clean")
	var got := []
	t.s.changed.connect(func(st): got.append(st["cleanup"].duplicate(true)))
	t.s.leftovers()
	var cl: Dictionary = t.s.state()["cleanup"]
	ok(cl["ready"], "measured")
	eq(cl["dirs"].size(), 2, "two leftovers")
	eq(cl["bytes"], 2000, "their size from du -sbc's total")
	ok(t.s.clean_leftovers(), "clean started")
	ok(not DirAccess.dir_exists_absolute(t.steam.path_join("steamapps/shadercache/20")), "removed game's cache gone")
	ok(not DirAccess.dir_exists_absolute(t.sd.path_join("steamapps/shadercache/40")), "on the SD card too")
	ok(DirAccess.dir_exists_absolute(t.steam.path_join("steamapps/shadercache/10")), "installed game's cache kept")
	ok(DirAccess.dir_exists_absolute(t.steam.path_join("steamapps/shadercache/30")), "game installed in another library kept")
	ok(DirAccess.dir_exists_absolute(t.steam.path_join("steamapps/shadercache/3000000001")), "non-Steam shortcut kept")
	var after: Dictionary = t.s.state()["cleanup"]
	eq(after["dirs"], [], "nothing left")
	eq(after["freed"], 2000, "freed reported")
	eq(after["failed"], 0, "no failures")
	ok(not t.s.clean_leftovers(), "nothing more to clean")
	t.s.free()
	_rm(t.root)


func test_panel_card() -> void:
	var t := _tree("panel")
	var p: Control = StoragePanel.build({"storage": t.s})
	ok(p.find_child("CleanUp", true, false) != null, "Clean up card")
	p.opened()
	ok(p.clean_button != null, "a button once leftovers are found")
	ok(p.clean_button.text.begins_with("Clean up "), "button says what it does")
	ok(p.clean_button in p.focusables(), "in the focus chain")
	ok(p.find_child("CleanWhy", true, false) != null, "one plain line on what goes")
	var toasts := []
	p.toast_requested.connect(func(text, _i, tone): toasts.append([text, tone]))
	p.start_clean()   # what the (deferred) press runs
	eq(toasts.size(), 1, "one toast")
	ok(toasts.size() == 1 and toasts[0][1] == "good", "freed")
	ok(p.clean_button == null, "nothing left: no button")
	p.closed()
	p.free()
	t.s.free()
	_rm(t.root)


# ---- review 3, medium 4 ---------------------------------------------------------------------

## The SD card isn't mounted: its games' manifests can't be seen, so the cache of
## game 30 (kept on internal storage) must not count as left over.
func test_unmounted_library_blocks_the_clean_up() -> void:
	var t := _tree("unmounted")
	_rm(t.sd)   # card out: libraryfolders.vdf still lists it
	eq(StorageScript.missing_libraries(t.s.steam_library_paths()), [t.sd], "the missing library is noticed")
	eq(StorageScript.leftover_dirs(t.s.steam_library_paths()), [], "nothing counts as left over meanwhile")
	t.s.leftovers()
	var cl: Dictionary = t.s.state()["cleanup"]
	eq(cl["dirs"], [], "nothing offered")
	eq(cl["missing"], [t.sd], "and why")
	ok(not t.s.clean_leftovers(), "nothing to clean")
	ok(DirAccess.dir_exists_absolute(t.steam.path_join("steamapps/shadercache/30")), "the card game's cache stays")
	var p: Control = StoragePanel.build({"storage": t.s})
	p.opened()
	var note := p.find_child("CleanMissing", true, false)
	ok(note != null and note.text == TX.CLEAN_MISSING % t.sd, "the page says a drive is missing")
	ok(p.clean_button == null, "no Clean up button")
	p.closed()
	p.free()
	t.s.free()
	_rm(t.root)


## A game installed between the scan and the button keeps its cache; a library
## unmounted in between stops the clean-up.
func test_clean_rechecks_on_the_worker() -> void:
	var t := _tree("recheck")
	t.s.leftovers()
	eq(t.s.state()["cleanup"]["dirs"].size(), 2, "20 and 40 shown")
	_touch(t.steam.path_join("steamapps/appmanifest_20.acf"))   # 20 installed again meanwhile
	ok(t.s.clean_leftovers(), "clean started")
	ok(DirAccess.dir_exists_absolute(t.steam.path_join("steamapps/shadercache/20")), "the reinstalled game's cache stays")
	ok(not DirAccess.dir_exists_absolute(t.sd.path_join("steamapps/shadercache/40")), "the real leftover went")
	# shown, then the card was pulled: nothing is removed
	var t2 := _tree("recheck2")
	t2.s.leftovers()
	_rm(t2.sd)
	ok(t2.s.clean_leftovers(), "clean started")
	ok(DirAccess.dir_exists_absolute(t2.steam.path_join("steamapps/shadercache/20")), "nothing removed while a library is missing")
	eq(t2.s.state()["cleanup"]["missing"], [t2.sd], "and the page learns why")
	t.s.free()
	t2.s.free()
	_rm(t.root)
	_rm(t2.root)


# ---- final review, medium (other data) --------------------------------------------------------

const Memory := preload("res://scripts/system/steam_library_memory.gd")
const SteamStore := preload("res://scripts/library/stores/steam.gd")


## The SD card is out AND Steam no longer lists its library in libraryfolders.vdf: the
## file can't tell us a library is missing. We remember the libraries we've seen and the
## games they held, so the card games' caches still aren't offered.
func test_a_library_steam_dropped_from_its_list_still_protects_its_caches() -> void:
	var t := _tree("dropped")
	t.s.memory_path = t.root.path_join("steam_libraries.json")
	t.s.leftovers()   # the page was open once with the card in
	eq(t.s.state()["cleanup"]["dirs"].size(), 2, "20 and 40 are left over")
	eq(Memory.read(t.s.memory_path).get(t.sd, {}).get("apps", []), ["30"], "the card's library and its game are remembered")
	_rm(t.sd)
	_touch(t.steam.path_join("steamapps/libraryfolders.vdf"), "\"libraryfolders\"\n{\n\t\"0\"\n\t{\n\t\t\"path\"\t\t\"%s\"\n\t}\n}\n" % t.steam)
	eq(StorageScript.missing_libraries(t.s.steam_library_paths()), [], "Steam's list no longer shows anything missing")
	t.s.leftovers()
	var cl: Dictionary = t.s.state()["cleanup"]
	eq(cl["dirs"], [t.steam.path_join("steamapps/shadercache/20")], "only the really uninstalled game's cache is offered")
	eq(cl["away"], [t.sd], "and the page learns a drive's games are being kept")
	ok(t.s.clean_leftovers(), "clean started")
	ok(DirAccess.dir_exists_absolute(t.steam.path_join("steamapps/shadercache/30")), "the card game's cache stays")
	ok(not DirAccess.dir_exists_absolute(t.steam.path_join("steamapps/shadercache/20")), "the leftover went")
	var p: Control = StoragePanel.build({"storage": t.s})
	p.opened()
	var note := p.find_child("CleanAway", true, false)
	ok(note != null and note.text == TX.CLEAN_AWAY % t.sd, "the page says whose caches it kept")
	p.closed()
	p.free()
	# the card comes back with the game uninstalled on another device: its cache is a leftover again
	_touch(t.sd.path_join("steamapps/appmanifest_31.acf"))
	t.s.leftovers()
	ok(t.steam.path_join("steamapps/shadercache/30") in t.s.state()["cleanup"]["dirs"], "seen again without game 30: its cache counts as left over")
	t.s.free()
	_rm(t.root)


## A library that was never listed again and hasn't been seen for two months is let go
## (a card that was sold): its games' caches can be cleaned.
func test_a_library_gone_for_two_months_is_forgotten() -> void:
	var t := _tree("forgotten")
	var mem: String = t.root.path_join("steam_libraries.json")
	var now := 1800000000
	Memory.remember({t.sd: ["30"]}, now, mem)
	_rm(t.sd)
	eq(Memory.away([t.steam], now + 59 * 86400, mem), {"30": t.sd}, "59 days: still protected")
	eq(Memory.away([t.steam], now + 61 * 86400, mem), {}, "61 days: forgotten")
	Memory.remember({t.steam: ["10"]}, now + 61 * 86400, mem)
	ok(not Memory.read(mem).has(t.sd), "and dropped from the file at the next write")
	t.s.free()
	_rm(t.root)


## The Library's Steam scan (every start) feeds the memory, so it's there even if the
## Storage page was never opened while the card was in.
func test_the_steam_scan_remembers_libraries() -> void:
	var t := _tree("scan")
	var mem: String = t.root.path_join("steam_libraries.json")
	var keep := Memory.path
	Memory.path = mem
	SteamStore.scan(t.home)
	Memory.path = keep
	var got: Dictionary = Memory.read(mem)
	eq(got.get(t.sd, {}).get("apps", []), ["30"], "the SD library and its game")
	eq(got.get(t.steam, {}).get("apps", []), ["10"], "the internal one")
	t.s.free()
	_rm(t.root)


## Settings > Device > Storage: what upscaling keeps here, from one helper call
## made only while the page is open; nothing shown without the helper.
func test_upscaling_files_card() -> void:
	var t := _tree("upscaling")
	var asked := []
	var helper: String = t.root.path_join("gamecove-upscale")
	_touch(helper)
	var du: Callable = t.fake.handler
	t.fake.handler = func(cmd: String) -> Variant:
		if cmd.begins_with(helper + " "):
			asked.append(cmd)
			return {"code": 0, "out": "{\"ok\": true, \"bytes\": 314572800, \"games\": 2, \"bundle_bytes\": 209715200, \"folder\": \"/h/.local/share/gamecove\", \"parts\": []}\n"}
		return du.call(cmd)
	var none: Control = StoragePanel.build({"storage": t.s})
	none.opened()
	ok(none.find_child("UpscalingFiles", true, false) == null, "no helper: no card")
	eq(asked.size(), 0, "and nothing was run")
	none.closed()
	none.free()
	t.s.upscale_helper = helper
	var p: Control = StoragePanel.build({"storage": t.s})
	ok(p.find_child("UpscalingFiles", true, false) == null and asked.is_empty(), "nothing is measured before the page opens")
	p.opened()
	eq(asked, ["%s storage --home %s" % [helper, t.home]], "one call, as the user")
	var size: Label = p.find_child("UpscalingSize", true, false)
	ok(size != null and size.text == TX.UPSCALE_STORE_SIZE % load("res://scripts/ui/texts_device.gd").bytes(314572800.0), "the folder's size")
	var games: Label = p.find_child("UpscalingGames", true, false)
	ok(games != null and games.text.begins_with("Set up in 2 games"), "how many games have our files")
	ok(p.find_child("UpscalingBundle", true, false) != null, "what came with the install is said apart")
	ok(p.find_child("UpscalingWhy", true, false) != null, "one plain line on what it is and how it goes")
	p.closed()
	p.free()
	t.fake.handler = func(cmd: String) -> Variant:
		return {"code": 0, "out": "not json\n"} if cmd.begins_with(helper + " ") else du.call(cmd)
	eq(t.s.upscaling_report(), {}, "a broken answer shows nothing")
	t.s.free()
	_rm(t.root)
