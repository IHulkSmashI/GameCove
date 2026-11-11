extends "res://tests/e2e/e2e_case.gd"
## Every ROM as a Library game on the real app with a controller: an EmuDeck
## setup is laid into the fake home (ROM folders, ES-DE's gamelist and art,
## EmuDeck's launcher scripts), the Library rescans, and Filter > Emulation >
## a system shows that console's games; search finds a ROM; its game page has
## the system's facts and a Play button; the Emulation page's system buttons
## open the Library on that system. Then a 160-system, 5,000+ ROM folder is
## timed: the scan (first and cached) and opening the Library on it.
## Everything is removed afterwards (the other suites expect an empty library).

const TL := preload("res://scripts/ui/texts_library.gd")
const Roms := preload("res://scripts/library/stores/roms.gd")
const Emu := preload("res://scripts/library/stores/emu.gd")
const View := preload("res://scripts/ui/library_view.gd")
const ExecSafe := preload("res://scripts/system/exec_safe.gd")
const ProcStats := preload("res://tests/perf/proc_stats.gd")


## This process's memory in MB: resident now, its peak (VmHWM) and Godot's own.
func _mem() -> Dictionary:
	var st := ProcStats._status("/proc/self/status")
	return {"rss": int(st.get("VmRSS", 0)) / 1024, "hwm": int(st.get("VmHWM", 0)) / 1024, "static": OS.get_static_memory_usage() / 1048576}


## A 160-system, 5,000+ ROM folder: scanned on the Library's thread (first time,
## then from the cache), the Library opened on it, the Emulation page and its
## rescan, and what it all cost the process (docs/PERFORMANCE.md).
## Measured on the 2-core box: quiet, first scan 2.5 s, whole-Library rescan with
## nothing changed 0.2 s (the ROM games aren't made again), Library open on the
## Emulation view 0.3 s, Emulation rescan 0.15 s; with a dozen other jobs on the
## same cores 5.8-6.6 s / 0.2-0.5 s / 0.6 s / 0.3 s. Process memory peak +127 MB
## over the start, Godot's own +54 MB (before: +313 MB and +142 MB, and 1.6 GB
## when a game database was there to read). Budgets: the quiet numbers with
## headroom; a scan that rebuilds every ROM game, a Library that makes every
## tile, or ROM data held twice fails them.
const MAX_SCAN_COLD_MS := 8000.0
const MAX_SCAN_CACHED_MS := 3000.0
const MAX_LIBRARY_OPEN_MS := 1000.0
const MAX_EMU_RESCAN_MS := 1500
const MAX_ROMS_RSS_GROWTH_MB := 200
const MAX_ROMS_STATIC_GROWTH_MB := 80
const BIG_SYSTEMS := 160
const BIG_PER_SYSTEM := 34


func _touch(path: String, text := "x") -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


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


func _lib() -> Node:
	return w.autoload("Library")


func _emudeck() -> void:
	var home: String = w.home
	var emu: String = home.path_join("Emulation")
	_touch(home.path_join(".config/EmuDeck/settings.sh"), "emulationPath=\"%s\"\n" % emu)
	_touch(home.path_join("Applications/ES-DE.AppImage"))
	_touch(emu.path_join("tools/launchers/retroarch.sh"), "#!/bin/sh\nexit 0\n")
	_touch(home.path_join(".var/app/org.libretro.RetroArch/config/retroarch/cores/snes9x_libretro.so"))
	for f in ["Moonlit Harbor (USA).sfc", "Copper Canyon Racing (Europe) (Rev 1).sfc", "systeminfo.txt"]:
		_touch(emu.path_join("roms/snes").path_join(f))
	_touch(emu.path_join("roms/nes/Thwaite.nes"))
	_touch(emu.path_join("roms/gbc/µCity (World).gbc"))
	_touch(home.path_join("ES-DE/gamelists/snes/gamelist.xml"), """<?xml version="1.0"?>
<gameList><game><path>./Moonlit Harbor (USA).sfc</path><name>Moonlit Harbor</name><desc>A lighthouse keeper's long night.</desc>
<developer>Tidewater</developer><players>1</players><lastplayed>20250102T101010</lastplayed></game></gameList>""")


func _clean() -> void:
	for p in ["Emulation", "ES-DE", ".config/EmuDeck", "Applications", ".var/app/org.libretro.RetroArch"]:
		_rm(w.home.path_join(p))


func _rescan() -> void:
	_lib().refresh()
	await w.idle(60000)
	await until(func(): return _lib()._task == -1, 60000)
	await w.frames(4)


func _roms() -> Array:
	return _lib().games.filter(func(g): return g.get("emulated", {}).get("rom", false))


func _sheet() -> Control:
	return main().game_actions.sheet


func test_rom_games_in_the_library() -> void:
	_emudeck()
	await _rescan()
	var roms := _roms()
	var titles: Array = roms.map(func(g): return g["title"])
	titles.sort()
	eq(titles, ["Copper Canyon Racing", "Moonlit Harbor", "Thwaite", "µCity"], "every ROM is a Library game, clean titles")
	main().show_screen("library")
	await w.frames(4)
	await press(JOY_BUTTON_BACK)
	ok(_sheet().is_open(), "View opens the Filter sheet")
	_sheet().pick("+emulation")
	await w.frames(4)
	ok(_sheet().is_open(), "Emulation opens the systems")
	_sheet().pick("emulation:snes")
	await w.frames(4)
	var shown: Array = main().library_screen.tiles().map(func(t): return t.game["title"])
	shown.sort()
	eq(shown, ["Copper Canyon Racing", "Moonlit Harbor"], "Filter > Emulation > SNES")
	eq(main().library_screen.view_label.text, "SNES  ·", "the view says which console")
	ok(main().library_screen.tiles().all(func(t): return t.title_label.visible and t.title_label.text == t.game["title"] and t.sub_label.text.begins_with("SNES")),
		"each tile names its game and its console")
	main().library_screen.set_view("")
	main().library_screen.set_query("moonlit")
	await w.frames(3)
	eq(main().library_screen.tiles().map(func(t): return t.game["title"]), ["Moonlit Harbor"], "search finds a ROM")
	main().library_screen.set_query("")
	await w.frames(2)
	var g: Dictionary = roms.filter(func(x): return x["title"] == "Moonlit Harbor")[0]
	main()._open_page(g)
	await w.frames(6)
	var p: Control = main().page
	ok(p != null and p.has_method("update_game") and p.name != "EmulationPage", "its game page opens")
	var facts := p.find_child("GameDetails", true, false)
	ok(facts != null and facts.find_child("Fact_System", true, false) != null, "with the console in its facts")
	ok(p.find_child("Fact_Developer", true, false) != null, "and ES-DE's details")
	ok(main().home.shelf_ids().has("recent") or main().home.shelf_ids().has("emulation"), "Home shows emulated games")
	await b()
	await w.frames(4)
	main().open_emulation()
	await w.frames(6)
	var ep: Control = main().page
	# The games on the page itself: the console picker and the grid.
	ok(ep.games_grid != null and ep.game_tiles.size() == 4, "the Emulation page shows every ROM game")
	await down()
	eq(focus(), ep._current_pick(), "down from the actions: the console picker")
	var pick_snes: Button = ep.find_child("Pick_snes", true, false)
	pick_snes.grab_focus()
	await a()
	await w.frames(3)
	eq(ep.game_tiles.map(func(t): return t.game["title"]), ["Moonlit Harbor", "Copper Canyon Racing"], "SNES picked: its games, played last first")
	await down()
	eq(focus(), ep.game_tiles[0], "down into the grid")
	var tile_key := str(ep.game_tiles[0].game["key"])
	await press(JOY_BUTTON_START)
	await w.frames(6)
	ok(main().page != null and main().page.name != "EmulationPage" and str(main().page.game.get("key", "")) == tile_key, "Menu on a tile opens its game page")
	await b()
	await w.frames(4)
	main().open_emulation()
	await w.frames(6)
	ep = main().page
	var snes: Button = ep.find_child("System_snes", true, false)
	ok(snes != null, "the Emulation page lists the system as a button")
	ok(ep.find_child("InLibrary", true, false).text.contains("own page"), "and says every ROM is in the Library")
	snes.grab_focus()
	await a()
	await w.frames(6)
	ok(main().page == null and main().current == "library", "a system opens the Library")
	eq(main().library_screen.view, "emulation:snes", "on that system")
	main().library_screen.set_view("")
	_clean()
	await _rescan()
	eq(_roms().size(), 0, "fixture gone")
	main().show_screen("home")
	await w.frames(3)


func test_five_thousand_roms() -> void:
	var home: String = w.home
	var emu: String = home.path_join("Emulation")
	_touch(home.path_join(".config/EmuDeck/settings.sh"), "emulationPath=\"%s\"\n" % emu)
	_touch(home.path_join("Applications/ES-DE.AppImage"))
	var data: Dictionary = preload("res://scripts/library/stores/esde_launch.gd").data()["systems"]
	var ids: Array = data.keys()
	ids.sort()
	var n := 0
	var made := 0
	for id in ids:
		if made >= BIG_SYSTEMS or id in preload("res://scripts/library/stores/esde_launch.gd").NOT_GAME_SYSTEMS:
			continue
		var ext := ""
		for e in data[id]["ext"]:
			if not e in [".desktop", ".sh", ".appimage", ".m3u", ".cue", ".gdi", "."]:
				ext = e
				break
		if ext == "":
			continue
		made += 1
		var dir: String = emu.path_join("roms").path_join(id)
		DirAccess.make_dir_recursive_absolute(dir)
		for j in BIG_PER_SYSTEM:
			var f := FileAccess.open(dir.path_join("Game %03d of %s (USA)%s" % [j, id, ext]), FileAccess.WRITE)
			f.close()
			n += 1
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Roms.CACHE_PATH))
	var mem0 := _mem()
	var t0 := Time.get_ticks_msec()
	await _rescan()
	var cold := Time.get_ticks_msec() - t0
	var mem_scan := OS.get_static_memory_usage() / 1048576
	var count := _roms().size()
	ok(count >= 5000, "%d ROM games from %d systems (%d files)" % [count, made, n])
	# Files dated a while back, so the cache's same-second rule doesn't force a re-read.
	ExecSafe.run("touch", PackedStringArray(["-d", "@1700000000", emu.path_join("roms")] + Array(DirAccess.get_directories_at(emu.path_join("roms"))).map(func(x): return emu.path_join("roms").path_join(x))))
	await _rescan()
	t0 = Time.get_ticks_msec()
	await _rescan()
	var cached := Time.get_ticks_msec() - t0
	main().show_screen("home")
	await w.frames(3)
	t0 = Time.get_ticks_msec()
	main().show_screen("library")
	main().library_screen.set_view("emulation")
	await w.frames(1)
	var opened := Time.get_ticks_msec() - t0
	await w.frames(2)
	print("E2E ROMS_MS cold=%d cached=%d library_open=%d games=%d mem_after_scan=%dMB mem_library=%dMB peak=%dMB" % [cold, cached, opened, count,
		mem_scan, OS.get_static_memory_usage() / 1048576, OS.get_static_memory_peak_usage() / 1048576])
	ok(cold <= MAX_SCAN_COLD_MS, "first scan of %d ROMs in %d ms <= %d" % [count, cold, MAX_SCAN_COLD_MS])
	ok(cached <= MAX_SCAN_CACHED_MS, "cached scan in %d ms <= %d" % [cached, MAX_SCAN_CACHED_MS])
	ok(opened <= MAX_LIBRARY_OPEN_MS, "Library opened on them in %d ms <= %d" % [opened, MAX_LIBRARY_OPEN_MS])
	main().library_screen.set_view("")
	main().show_screen("home")
	await w.frames(2)
	ok(main().home.shelves().all(func(s): return s.tiles.size() <= main().home.SHELF_MAX + 1), "Home's shelves stay short")
	# The Emulation page with every console, then an Emulation rescan as it opens again.
	main().open_emulation()
	await w.frames(30)
	await b()
	await w.frames(4)
	_lib()._last_emu_scan = 0
	t0 = Time.get_ticks_msec()
	ok(_lib().rescan_emulation(), "the Emulation rescan runs")
	await until(func(): return _lib()._task == -1, 60000)
	var emu_rescan := Time.get_ticks_msec() - t0
	await w.frames(4)
	var mem1 := _mem()
	var rss_growth: int = mem1["hwm"] - mem0["rss"]
	var static_growth: int = mem1["static"] - mem0["static"]
	print("E2E ROMS_MEM rss_start=%dMB rss_end=%dMB peak=%dMB peak_growth=%dMB static_growth=%dMB emu_rescan=%dms" % [mem0["rss"], mem1["rss"],
		mem1["hwm"], rss_growth, static_growth, emu_rescan])
	ok(rss_growth <= MAX_ROMS_RSS_GROWTH_MB, "process memory peak grew %d MB with %d ROM games <= %d" % [rss_growth, count, MAX_ROMS_RSS_GROWTH_MB])
	ok(static_growth <= MAX_ROMS_STATIC_GROWTH_MB, "Godot's own memory grew %d MB <= %d" % [static_growth, MAX_ROMS_STATIC_GROWTH_MB])
	ok(emu_rescan <= MAX_EMU_RESCAN_MS, "an Emulation rescan with nothing changed in %d ms <= %d" % [emu_rescan, MAX_EMU_RESCAN_MS])
	_clean()
	await _rescan()
	eq(_roms().size(), 0, "fixture gone")
