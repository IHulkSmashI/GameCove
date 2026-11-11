extends "res://tests/test_case.gd"
## Every ROM as a Library game (scripts/library/stores/roms.gd, esde_launch.gd and
## the ROM parts of emu.gd): titles, what counts as a game (.cue / .m3u / folder
## games, extensions), ES-DE's gamelist and art, the cache, how each setup
## starts a game (EmuDeck's launcher scripts, RetroDECK's CLI, ES-DE's own
## command, alternative emulators, odd file names through exec_safe), Steam ROM
## Manager shortcuts folded in, the Library filter, the Emulation page and the
## setting. Throwaway homes only; nothing reads this machine.

const Roms := preload("res://scripts/library/stores/roms.gd")
const Emu := preload("res://scripts/library/stores/emu.gd")
const EsdeLaunch := preload("res://scripts/library/stores/esde_launch.gd")
const LibraryScript := preload("res://scripts/library/library.gd")
const Collections := preload("res://scripts/library/collections.gd")
const Playtime := preload("res://scripts/library/playtime.gd")
const View := preload("res://scripts/ui/library_view.gd")
const EmulationPage := preload("res://scripts/ui/emulation_page.gd")
const MetadataCard := preload("res://scripts/ui/games/metadata_card.gd")
const MetaResolver := preload("res://scripts/library/meta/resolver.gd")
const FallbackArt := preload("res://scripts/ui/fallback_art.gd")
const TL := preload("res://scripts/ui/texts_library.gd")
const Tile := preload("res://scripts/ui/game_tile.gd")
const Shelf := preload("res://scripts/ui/shelf.gd")
const SettingsFile := preload("res://scripts/system/settings_file.gd")
const ExecSafe := preload("res://scripts/system/exec_safe.gd")
const EmuTests := preload("res://tests/test_emulation.gd")
const GameDB := preload("res://scripts/library/gamedb.gd")

const BASE := "user://test_roms"
const STEAM := ".local/share/Steam"
## Names that break anything that builds a shell line: spaces, quotes, brackets, $ and &.
const ODD := "Kirby's \"Dream\" Land [!] (USA) $HOME & more.gb"


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


func _dir(name: String) -> String:
	var p := ProjectSettings.globalize_path(BASE).path_join(name)
	_rm(p)
	DirAccess.make_dir_recursive_absolute(p)
	Roms.cache_path = p.path_join("cache/roms.cache")
	Emu.prefs_path = p.path_join("emulation.json")
	return p


func _touch(path: String, text := "x") -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## A script that prints each argument it gets on its own line (stands in for
## EmuDeck's launchers and the emulators).
func _echo_script(path: String) -> void:
	_touch(path, "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done\n")
	FileAccess.set_unix_permissions(path, 493)   # 0755


## Every folder and file under `root` dated `t` (unix), so a later change shows.
func _age(root: String, t := 1700000000) -> void:
	var paths := PackedStringArray(["-h", "-d", "@%d" % t])
	var walk := func(self_ref: Callable, p: String) -> void:
		paths.append(p)
		var d := DirAccess.open(p)
		if d == null:
			return
		for f in d.get_files():
			paths.append(p.path_join(f))
		for sub in d.get_directories():
			self_ref.call(self_ref, p.path_join(sub))
	walk.call(walk, root)
	ExecSafe.run("touch", paths)


## A home with EmuDeck: Emulation folder with launcher scripts, ROMs for
## several systems, ES-DE's gamelists (an alternative emulator for PS1, a
## per-game one for SNES), downloaded media, RetroArch's Flatpak cores and an
## EmuDeck custom Wii U system.
func _emudeck(name: String) -> String:
	var home := _dir(name)
	var emu := home.path_join("Emulation")
	_touch(home.path_join(".config/EmuDeck/settings.sh"), "emulationPath=\"%s\"\n" % emu)
	_touch(home.path_join("Applications/ES-DE.AppImage"))
	for s in ["retroarch.sh", "duckstation.sh", "pcsx2-qt.sh", "rpcs3.sh", "cemu.sh", "supermodel.sh"]:
		_echo_script(emu.path_join("tools/launchers").path_join(s))
	var cores := home.path_join(".var/app/org.libretro.RetroArch/config/retroarch/cores")
	for c in ["snes9x_libretro.so", "mednafen_psx_hw_libretro.so", "gambatte_libretro.so"]:
		_touch(cores.path_join(c))
	var roms := emu.path_join("roms")
	for f in ["Super Game (USA).sfc", "Legend of Hyrule, The - A Link (USA) (Rev 1).smc", "Third_Game.zip", "systeminfo.txt", ".hidden.sfc", "notes.pdf"]:
		_touch(roms.path_join("snes").path_join(f))
	_touch(roms.path_join("snes/media/covers/Super Game (USA).png"))
	_touch(roms.path_join("snes/updates/Patch.sfc"))
	_touch(roms.path_join("gb").path_join(ODD))
	var psx := roms.path_join("psx")
	for f in ["Disc Game (USA) (Disc 1).cue", "Disc Game (USA) (Disc 1).bin", "Disc Game (USA) (Disc 2).cue", "Disc Game (USA) (Disc 2).bin",
			"Loose (Disc 1).chd", "Loose (Disc 2).chd", "Single [SLUS-0001].chd"]:
		_touch(psx.path_join(f))
	_touch(psx.path_join("Disc Game (USA).m3u"), "Disc Game (USA) (Disc 1).cue\r\nDisc Game (USA) (Disc 2).cue\n")
	_touch(roms.path_join("ps3/Big Game.ps3/PS3_GAME/USRDIR/EBOOT.BIN"))
	_touch(roms.path_join("ps3/Other.ps3/Other.ps3"), "BLUS00000")
	_touch(roms.path_join("wiiu/roms/Island Game [ABCD01]/code/island.rpx"))
	_touch(roms.path_join("wiiu/roms/Island Game [ABCD01]/code/title.tmd"))
	_touch(roms.path_join("wiiu/roms/Island Game [ABCD01]/meta/meta.xml"))
	_touch(roms.path_join("wiiu/mlc01/usr/x.rpx"))
	_touch(roms.path_join("gc/noload.txt"))
	_touch(roms.path_join("gc/game.iso"))
	_touch(roms.path_join("notasystem/x.bin"))
	_touch(roms.path_join("model3/Racer.zip"))
	var esde := home.path_join("ES-DE")
	_touch(esde.path_join("gamelists/snes/gamelist.xml"), """<?xml version="1.0"?>
<gameList>
	<game><path>./Super Game (USA).sfc</path><name>Super Game &amp; Friends</name><desc>A plumber's day out.</desc>
		<rating>0.8</rating><releasedate>19910821T000000</releasedate><developer>Studio A</developer><publisher>Pub B</publisher>
		<genre>Platform / Action</genre><players>1-2</players><playcount>3</playcount><lastplayed>20240131T201500</lastplayed>
		<favorite>true</favorite><altemulator>bsnes</altemulator></game>
	<game><path>./Third_Game.zip</path><hidden>true</hidden></game>
</gameList>""")
	_touch(esde.path_join("gamelists/psx/gamelist.xml"), """<?xml version="1.0"?>
<gameList>
	<alternativeEmulator><label>DuckStation (Standalone)</label></alternativeEmulator>
	<game><path>./Single [SLUS-0001].chd</path><altemulator>Beetle PSX HW</altemulator></game>
</gameList>""")
	var media := esde.path_join("downloaded_media")
	_touch(media.path_join("snes/covers/Super Game (USA).png"))
	_touch(media.path_join("snes/3dboxes/Super Game (USA).png"))
	_touch(media.path_join("snes/screenshots/Super Game (USA).png"))
	_touch(media.path_join("snes/fanart/Super Game (USA).jpg"))
	_touch(media.path_join("snes/marquees/Super Game (USA).png"))
	_touch(media.path_join("snes/3dboxes/Third_Game.png"))
	_touch(media.path_join("snes/titlescreens/Third_Game.png"))
	_touch(media.path_join("wiiu/covers/Island Game [ABCD01]/code/island.png"))
	_touch(esde.path_join("custom_systems/es_systems.xml"), """<?xml version="1.0"?>
<systemList>
  <system>
	<name>wiiu</name>
	<fullname>Nintendo Wii U</fullname>
	<path>%%ROMPATH%%/wiiu/roms</path>
	<extension>.rpx .RPX .tmd .TMD .wua .WUA .wud .wux</extension>
	<command label="Cemu (Native)">/bin/bash %s/tools/launchers/cemu.sh -f -g %%ROM%%</command>
	<platform>wiiu</platform>
  </system>
</systemList>""" % emu)
	return home


func _ids(list: Array) -> Array:
	var out: Array = list.map(func(e): return e["rel"])
	out.sort()
	return out


# ------------------------------------------------------------ titles

func test_clean_titles() -> void:
	eq(Roms.clean_title("Super Game (USA)"), "Super Game", "region")
	eq(Roms.clean_title("Super Game (USA, Europe) (Rev 1) [!]"), "Super Game", "revision and dump tags")
	eq(Roms.clean_title("Disc Game (USA) (Disc 1)"), "Disc Game", "disc")
	eq(Roms.clean_title("Legend of Hyrule, The - A Link (USA)"), "The Legend of Hyrule: A Link", "No-Intro's ', The' turned round, its ' - ' the colon again")
	eq(Roms.clean_title("Castlevania - Symphony of the Night (USA)"), "Castlevania: Symphony of the Night", "the colon No-Intro can't write")
	eq(Roms.clean_title("Super Metroid (Japan, USA) (En,Ja)"), "Super Metroid", "languages")
	eq(Roms.clean_title("Sonic the Hedgehog 2 (World) (Rev A)"), "Sonic the Hedgehog 2", "revision letter")
	eq(Roms.clean_title("Star Wars - Episode I - Racer (USA)"), "Star Wars: Episode I - Racer", "only the first dash")
	eq(Roms.clean_title("Adventure, An"), "An Adventure", "', An'")
	eq(Roms.clean_title("Third_Game_Plus"), "Third Game Plus", "underscores when there are no spaces")
	eq(Roms.clean_title("Keep_This Name"), "Keep_This Name", "underscores kept beside spaces")
	eq(Roms.clean_title("(Prototype)"), "(Prototype)", "never empty")
	eq(Roms.disc_number("Game (Disc 2)"), 2, "disc number")
	eq(Roms.disc_number("Game (CD3)"), 3, "CD")
	eq(Roms.disc_number("Game"), 0, "none")
	eq(Roms.es_date("19910821T000000"), "1991-08-21", "ES-DE's date")
	eq(Roms.es_date("garbage"), "", "not a date")


# ------------------------------------------------------------ what counts as a game

func test_listing_rules() -> void:
	var home := _emudeck("list")
	var roms := home.path_join("Emulation/roms")
	var snes := Roms.list_games(roms.path_join("snes"), ["sfc", "smc", "zip"])
	eq(_ids(snes["games"]), ["Legend of Hyrule, The - A Link (USA) (Rev 1).smc", "Super Game (USA).sfc", "Third_Game.zip"],
		"the system's extensions only: no notes, media, update folders or dot files")
	var psx := Roms.list_games(roms.path_join("psx"), ["cue", "bin", "chd", "m3u"])
	eq(_ids(psx["games"]), ["Disc Game (USA).m3u", "Loose (Disc 1).chd", "Loose (Disc 2).chd", "Single [SLUS-0001].chd"],
		"a .m3u stands for its discs (CRLF lines too), a .cue for its tracks")
	var ps3 := Roms.list_games(roms.path_join("ps3"), ["ps3", "iso", "desktop"])
	eq(_ids(ps3["games"]), ["Big Game.ps3", "Other.ps3"], "folders named like a game file are one game each")
	var big: Dictionary = ps3["games"].filter(func(g): return g["rel"] == "Big Game.ps3")[0]
	var other: Dictionary = ps3["games"].filter(func(g): return g["rel"] == "Other.ps3")[0]
	eq(big["path"], roms.path_join("ps3/Big Game.ps3"), "started as the folder")
	eq(other["path"], roms.path_join("ps3/Other.ps3/Other.ps3"), "or as its same-named file, like ES-DE")
	var wiiu := Roms.list_games(roms.path_join("wiiu/roms"), ["rpx", "tmd", "wua"])
	eq(_ids(wiiu["games"]), ["Island Game [ABCD01]/code/island.rpx"], "a Wii U game folder: its .rpx, not title.tmd beside it")
	eq(Roms.list_games(roms.path_join("gc"), ["iso"])["games"], [], "noload.txt: skipped like ES-DE does")
	var unknown := Roms.list_games(roms.path_join("snes"), [])
	ok(unknown["games"].size() == 3, "an unknown system: anything that isn't notes, media or saves")
	ok(Roms.list_games(roms.path_join("snes"), ["sfc", "smc", "zip"], 2)["games"].size() == 2, "capped")
	ok(snes["dirs"].has(roms.path_join("snes")), "folders read are kept for the cache")


func test_rom_systems_follow_esde() -> void:
	var home := _emudeck("systems")
	var setup := Emu.detect(home, "", [], false)
	var custom := EsdeLaunch.read_custom(setup["esde_dir"])
	var list := Emu.rom_systems(setup, custom)
	var by := {}
	for s in list:
		by[s["id"]] = s
	ok(by.has("notasystem") and not by["notasystem"]["known"] and by["notasystem"]["exts"].is_empty(), "a folder ES-DE doesn't know is still read (by the NOT_ROM_EXT rules)")
	eq(by["wiiu"]["root"], setup["roms_dir"].path_join("wiiu/roms"), "EmuDeck's custom Wii U system: its <path>")
	ok("rpx" in by["wiiu"]["exts"] and not "iso" in by["wiiu"]["exts"], "its extensions")
	ok("sfc" in by["snes"]["exts"] and "smc" in by["snes"]["exts"], "ES-DE's own list otherwise")
	eq(setup["media_dir"], home.path_join("ES-DE/downloaded_media"), "ES-DE's downloaded_media")


# ------------------------------------------------------------ gamelist and art

func test_gamelist_and_art() -> void:
	var home := _emudeck("gamelist")
	var roms := home.path_join("Emulation/roms")
	var gl := Roms.parse_gamelist(home.path_join("ES-DE/gamelists/psx/gamelist.xml"), roms.path_join("psx"))
	eq(gl["alt"], "DuckStation (Standalone)", "the system's alternative emulator")
	eq(gl["games"]["Single [SLUS-0001].chd"]["altemulator"], "Beetle PSX HW", "a game's own")
	eq(Roms.rel_path("./a/b.sfc", "/r"), "a/b.sfc", "relative")
	eq(Roms.rel_path("/r/sub/c.sfc", "/r"), "sub/c.sfc", "absolute inside the folder")
	eq(Roms.rel_path("/elsewhere/c.sfc", "/r"), "", "absolute outside")
	var res := Roms.scan_system("snes", roms.path_join("snes"), ["sfc", "smc", "zip"], home.path_join("ES-DE/gamelists/snes/gamelist.xml"),
		home.path_join("ES-DE/downloaded_media"))
	var by := {}
	for g in res["games"]:
		by[g["rel"]] = g
	var sg: Dictionary = by["Super Game (USA).sfc"]
	eq(sg["title"], "Super Game & Friends", "ES-DE's name")
	eq(sg["id"], "rom:snes/Super Game (USA).sfc", "id: system and file")
	eq(sg["meta"], {"summary": "A plumber's day out.", "developers": ["Studio A"], "publishers": ["Pub B"],
		"genres": ["Platform", "Action"], "release_date": "1991-08-21"}, "details from the gamelist")
	eq([sg["players"], sg["rating"], sg["playcount"], sg["favorite"], sg["hidden"], sg["altemulator"]], ["1-2", 0.8, 3, true, false, "bsnes"], "and the rest")
	eq(sg["last_played"], int(Time.get_unix_time_from_datetime_string("2024-01-31T20:15:00")), "last played")
	var media := home.path_join("ES-DE/downloaded_media/snes")
	eq(sg["art"], {"cover": media.path_join("covers/Super Game (USA).png"), "hero": media.path_join("fanart/Super Game (USA).jpg"),
		"logo": media.path_join("marquees/Super Game (USA).png"), "icon": ""}, "covers -> tile, fanart -> hero (before screenshots), marquees -> logo")
	var third: Dictionary = by["Third_Game.zip"]
	eq(third["title"], "Third Game", "no name in the gamelist: a clean title from the file")
	ok(third["hidden"], "ES-DE's hidden flag")
	eq([third["art"]["cover"].get_file(), third["art"]["hero"].get_base_dir().get_file()], ["Third_Game.png", "titlescreens"], "3D box and title screen when that's all there is")
	eq(by["Legend of Hyrule, The - A Link (USA) (Rev 1).smc"]["art"]["cover"], "", "no art: the system placeholder draws")
	var wiiu := Roms.scan_system("wiiu", roms.path_join("wiiu/roms"), ["rpx", "tmd"], "", home.path_join("ES-DE/downloaded_media"))
	eq(wiiu["games"][0]["title"], "Island Game", "a Wii U game is named after its folder")
	ok(wiiu["games"][0]["art"]["cover"].ends_with("covers/Island Game [ABCD01]/code/island.png"), "media mirrors sub-folders like ES-DE")
	var psx := Roms.scan_system("psx", roms.path_join("psx"), ["cue", "bin", "chd", "m3u"], "", "")
	var titles: Array = psx["games"].map(func(g): return g["title"])
	titles.sort()
	eq(titles, ["Disc Game", "Loose (Disc 1)", "Loose (Disc 2)", "Single"], "discs without a .m3u keep their number")


func test_gamelist_art_tags_fallback() -> void:
	var home := _dir("gl_art")
	_touch(home.path_join("roms/snes/A.sfc"))
	_touch(home.path_join("roms/snes/media/images/A.png"))
	_touch(home.path_join("gl.xml"), "<gameList><game><path>./A.sfc</path><image>./media/images/A.png</image></game></gameList>")
	var r := Roms.scan_system("snes", home.path_join("roms/snes"), ["sfc"], home.path_join("gl.xml"), "")
	eq(r["games"][0]["art"]["cover"], home.path_join("roms/snes/media/images/A.png"), "a scraper's <image> when ES-DE downloaded nothing")


# ------------------------------------------------------------ cache

## scan_all's one system, by its id.
func _sa(systems: Array, media: String) -> Dictionary:
	var r := Roms.scan_all(systems, media)
	var out := {}
	for k in r:
		out[str(k).get_slice("|", 0)] = r[k]
	return out


func test_cache_and_invalidation() -> void:
	var home := _emudeck("cache")
	var roms := home.path_join("Emulation/roms")
	_age(home)
	var gl := {"snes": home.path_join("ES-DE/gamelists/snes/gamelist.xml")}
	var systems := [{"id": "snes", "root": roms.path_join("snes"), "exts": ["sfc", "smc", "zip"], "gamelist": gl["snes"]}]
	var media := home.path_join("ES-DE/downloaded_media")
	var first := _sa(systems, media)
	eq(first["snes"]["games"].size(), 3, "scanned")
	ok(FileAccess.file_exists(Roms.cache_path), "cached")
	# Mark the cached copy: a second start that reuses it returns the mark.
	var c := Roms.load_cache()
	var key: String = c["systems"].keys()[0]
	ok(c["systems"][key]["games"] is PackedByteArray, "games kept packed (checking the folders unpacks none)")
	var packed: Array = bytes_to_var(c["systems"][key]["games"])
	packed[0]["title"] = "FROM CACHE"
	c["systems"][key]["games"] = var_to_bytes(packed)
	Roms.save_cache(c)
	var again := _sa(systems, media)
	ok(again["snes"]["games"].any(func(g): return g["title"] == "FROM CACHE"), "nothing changed: the cache is used")
	_touch(roms.path_join("snes/New One.sfc"))
	var after_add := _sa(systems, media)
	eq(after_add["snes"]["games"].size(), 4, "a ROM added: read again")
	ok(not after_add["snes"]["games"].any(func(g): return g["title"] == "FROM CACHE"), "fresh data")
	_age(home)
	_sa(systems, media)
	_touch(gl["snes"], "<gameList><game><path>./New One.sfc</path><name>Renamed</name></game></gameList>")
	var after_gl := _sa(systems, media)
	ok(after_gl["snes"]["games"].any(func(g): return g["title"] == "Renamed"), "the gamelist changed: read again")
	_age(home)
	_sa(systems, media)
	_touch(media.path_join("snes/covers/New One.png"))
	var after_art := _sa(systems, media)
	ok(after_art["snes"]["games"].any(func(g): return g["art"]["cover"].ends_with("covers/New One.png")), "new art: read again")
	_age(home)
	_sa(systems, media)
	_touch(roms.path_join("snes/sub/Deep.sfc"))
	ok(_sa(systems, media)["snes"]["games"].any(func(g): return g["rel"] == "sub/Deep.sfc"), "a new sub-folder: read again")
	_touch(Roms.cache_path, "junk")
	eq(_sa(systems, media)["snes"]["games"].size(), 5, "a broken cache is just read again")


## The stamp of folders the cache saw: "" until they're cached and settled, the
## same while nothing changes, "" again the moment one does.
func test_unchanged_stamp() -> void:
	var home := _emudeck("ustamp")
	var roms := home.path_join("Emulation/roms")
	_age(home)
	var systems := [{"id": "snes", "root": roms.path_join("snes"), "exts": ["sfc", "smc", "zip"], "gamelist": ""},
		{"id": "psx", "root": roms.path_join("psx"), "exts": ["cue", "chd", "m3u"], "gamelist": ""}]
	eq(Roms.unchanged_stamp(systems, ""), "", "nothing cached yet")
	Roms.scan_all(systems, "")
	var st := Roms.unchanged_stamp(systems, "")
	ok(st != "", "cached and settled")
	eq(Roms.unchanged_stamp(systems, ""), st, "the same while nothing changes")
	_touch(roms.path_join("psx/New (USA).chd"))
	eq(Roms.unchanged_stamp(systems, ""), "", "a new file: read again")


## A rescan of ROM folders that didn't change makes nothing again (the Library or
## Emulation page opening): Emu.scan's stamp matches, the Library keeps the very
## games it has and redraws nothing. A new ROM, play time or a picked cover (the
## salt) makes them again.
func test_unchanged_rescan_makes_nothing() -> void:
	var home := _emudeck("rescan")
	_age(home)
	SettingsFile.reset_for_tests()
	var reuse := {"salt": PackedByteArray()}
	var first := Emu.scan(home, Emu.detect(home, "", [], false), true, reuse)
	var stamp := str(reuse.get("stamp_now", ""))
	ok(first.size() > 4 and stamp != "", "a stamp for what was read")
	var again := {"salt": PackedByteArray(), "stamp": stamp}
	eq(Emu.scan(home, Emu.detect(home, "", [], false), true, again).size(), 0, "nothing changed: nothing made")
	ok(again.get("same", false) and again["stamp_now"] == stamp, "and it says so")
	var salted := {"salt": var_to_bytes([{"emu:x": 1}]), "stamp": stamp}
	ok(Emu.scan(home, Emu.detect(home, "", [], false), true, salted).size() == first.size() and not salted.get("same", false),
		"play time or picked art changed: made again")
	var lib: Node = LibraryScript.new()
	lib.home = home
	lib.collections = Collections.new(home.path_join("collections.json"))
	var redraws := [0]
	lib.changed.connect(func(): redraws[0] += 1)
	var apply := func(res: Dictionary) -> void:
		lib._task = WorkerThreadPool.add_task(func(): pass)
		lib._apply(res)
	apply.call(LibraryScript.collect(home, "/nonexistent/gamedb.json.gz", [], lib._emu_stamp))
	var had: Array = lib.games.filter(func(g): return g["emulated"].get("rom", false))
	ok(had.size() > 4 and lib._emu_stamp != "" and redraws[0] == 1, "first scan: the ROM games")
	var res := LibraryScript.collect(home, "/nonexistent/gamedb.json.gz", ["emu"], lib._emu_stamp)
	ok(res["emu_same"] and res["games"].is_empty() and not res.has("emulation"), "rescan of Emulation: nothing made")
	apply.call(res)
	var now: Array = lib.games.filter(func(g): return g["emulated"].get("rom", false))
	ok(now.size() == had.size() and is_same(now[0], had[0]) and redraws[0] == 1, "the games we had stay, nothing redrawn")
	apply.call(LibraryScript.collect(home, "/nonexistent/gamedb.json.gz", [], lib._emu_stamp))
	now = lib.games.filter(func(g): return g["emulated"].get("rom", false))
	ok(now.size() == had.size() and is_same(now[0], had[0]) and redraws[0] == 1 and not (lib.emulation["systems"] as Array).is_empty(),
		"a whole Library rescan keeps them too, and the Emulation page's consoles")
	_touch(home.path_join("Emulation/roms/snes/Brand New (USA).sfc"))
	apply.call(LibraryScript.collect(home, "/nonexistent/gamedb.json.gz", ["emu"], lib._emu_stamp))
	ok(lib.games.any(func(g): return g["title"] == "Brand New") and redraws[0] == 2, "a new ROM: made again and shown")
	lib.free()


## Thousands of ROMs: what's the same for many is one copy. Unscraped ROMs of a
## console share their details, the console line and the empty art, all
## read-only (a write meant for one game is refused instead of reaching all of
## them); a scraped one keeps its own. The game database isn't read for ROMs.
func test_rom_games_share_what_they_can() -> void:
	var home := _dir("share")
	var emu := home.path_join("Emulation")
	_touch(home.path_join(".config/EmuDeck/settings.sh"), "emulationPath=\"%s\"\n" % emu)
	_touch(home.path_join("Applications/ES-DE.AppImage"))
	for i in 3:
		_touch(emu.path_join("roms/nes/Game %d (USA).nes" % i))
	_touch(emu.path_join("roms/nes/gamelist.xml"), "<gameList><game><path>./Game 2 (USA).nes</path><desc>Our own words.</desc></game></gameList>")
	SettingsFile.reset_for_tests()
	var db := home.path_join("gamedb.json.gz")
	_touch(db, "not read")
	GameDB._handoff = {"path": db, "modified": int(FileAccess.get_modified_time(db)), "doc": {"games": []}}
	var res := LibraryScript.collect(home, db, ["emu"])
	ok(not GameDB._handoff.is_empty(), "the game database isn't read for ROMs")
	GameDB._handoff = {}
	var by := {}
	for g in res["games"]:
		by[g["title"]] = g
	var a: Dictionary = by["Game 0"]
	var b: Dictionary = by["Game 1"]
	ok(is_same(a["info"], b["info"]) and is_same(a["emulated"], b["emulated"]) and is_same(a["art"], b["art"]), "one copy for both")
	ok(a["info"].is_read_only() and a["info"]["meta"].is_read_only() and a["emulated"].is_read_only() and a["art"].is_read_only(),
		"read-only")
	var c: Dictionary = by["Game 2"]
	ok(not is_same(c["info"], a["info"]) and c["info"]["summary"] == "Our own words.", "a scraped one has its own")
	ok(str(a["info"]["summary"]).begins_with("A Nintendo Entertainment System game from your ROM folder."), "the console line")


# ------------------------------------------------------------ starting a game

func _ctx(home: String, kind := "emudeck") -> Dictionary:
	var setup := Emu.detect(home, "", [], false)
	return {"kind": kind, "home": home, "path_env": "", "emu_path": home.path_join("Emulation") if kind == "emudeck" else "",
		"roms_dir": setup["roms_dir"], "es_path": "", "custom": EsdeLaunch.read_custom(setup["esde_dir"]), "system_alt": ""}


func test_emudeck_launch_through_its_scripts() -> void:
	var home := _emudeck("launch")
	var roms := home.path_join("Emulation/roms")
	var l := home.path_join("Emulation/tools/launchers")
	var cores := home.path_join(".var/app/org.libretro.RetroArch/config/retroarch/cores")
	var ctx := _ctx(home)
	var snes := roms.path_join("snes/Super Game (USA).sfc")
	var r := EsdeLaunch.build({"system": "snes", "path": snes, "altemulator": ""}, ctx)
	eq(r["cmd"], ["/bin/bash", l.path_join("retroarch.sh"), "-L", cores.path_join("snes9x_libretro.so"), snes], "ES-DE's default (Snes9x) through EmuDeck's RetroArch script")
	eq([r["label"], r["via"]], ["Snes9x - Current", "emudeck"], "which one")
	var c2 := ctx.duplicate()
	c2["system_alt"] = "DuckStation (Standalone)"
	var disc := roms.path_join("psx/Disc Game (USA).m3u")
	eq(EsdeLaunch.build({"system": "psx", "path": disc, "altemulator": ""}, c2)["cmd"], ["/bin/bash", l.path_join("duckstation.sh"), "-batch", disc],
		"the system's alternative emulator from the gamelist")
	var single := roms.path_join("psx/Single [SLUS-0001].chd")
	eq(EsdeLaunch.build({"system": "psx", "path": single, "altemulator": "Beetle PSX HW"}, c2)["cmd"],
		["/bin/bash", l.path_join("retroarch.sh"), "-L", cores.path_join("mednafen_psx_hw_libretro.so"), single], "a game's own <altemulator> wins")
	eq(EsdeLaunch.build({"system": "psx", "path": single, "altemulator": "No Such Label"}, c2)["label"], "DuckStation (Standalone)", "an unknown label falls back like ES-DE")
	var island := roms.path_join("wiiu/roms/Island Game [ABCD01]/code/island.rpx")
	eq(EsdeLaunch.build({"system": "wiiu", "path": island}, ctx)["cmd"], ["/bin/bash", l.path_join("cemu.sh"), "-f", "-g", island], "EmuDeck's custom system's own command")
	var ps3 := roms.path_join("ps3/Big Game.ps3")
	var c3 := ctx.duplicate()
	c3["system_alt"] = "RPCS3 Directory (Standalone)"
	eq(EsdeLaunch.build({"system": "ps3", "path": ps3}, c3)["cmd"], ["/bin/bash", l.path_join("rpcs3.sh"), "--no-gui", ps3], "a folder game")
	var ps3_default := EsdeLaunch.build({"system": "ps3", "path": ps3}, ctx)
	eq([ps3_default["label"], ps3_default["cmd"][1]], ["RPCS3 Directory (Standalone)", l.path_join("rpcs3.sh")],
		"ES-DE's default only runs shortcuts: a game folder gets the first command that opens it")
	var racer := roms.path_join("model3/Racer.zip")
	var c4 := ctx.duplicate()
	c4["system_alt"] = "Supermodel (Standalone)"
	eq(EsdeLaunch.build({"system": "model3", "path": racer}, c4)["cmd"], ["/bin/bash", l.path_join("supermodel.sh"), racer],
		"supermodel.sh gets only the ROM, as EmuDeck's own shortcuts give it")
	var model3 := EsdeLaunch.build({"system": "model3", "path": racer}, c4)
	eq(model3["cwd"], racer.get_base_dir(), "ES-DE's start folder (%STARTDIR%=%GAMEDIR%)")


func test_odd_names_reach_the_emulator_whole() -> void:
	var home := _emudeck("quoting")
	var rom := home.path_join("Emulation/roms/gb").path_join(ODD)
	var r := EsdeLaunch.build({"system": "gb", "path": rom}, _ctx(home))
	ok(r["ok"], "built: %s" % r["why"])
	eq(r["cmd"][-1], rom, "one argument, unchanged")
	# Run it: the stand-in launcher prints each argument it got on its own line.
	var cmd: Array = r["cmd"]
	var out := ExecSafe.run(str(cmd[0]), PackedStringArray(cmd.slice(1)))
	eq(out["code"], 0, "ran")
	var lines := str(out["out"]).strip_edges(false, true).split("\n")
	eq(lines[lines.size() - 1], rom, "the emulator gets the exact path: spaces, quotes, brackets, $ and & intact")
	eq(lines[0], "-L", "and ES-DE's arguments before it")
	# The same through Library.launch's wrapping (env for launch settings, the scope's argv).
	var entry := {"store": "emu", "id": "rom:gb/" + ODD, "rom": rom, "emulated": {"system": "gb"}, "launch_ctx": {"kind": "emudeck",
		"emu_path": home.path_join("Emulation"), "roms_dir": home.path_join("Emulation/roms"), "esde_dir": home.path_join("ES-DE"), "system_alt": ""}}
	var plan := Emu.launch_plan(entry, {"MANGOHUD": "1"}, home, "")
	eq(plan["cmd"].slice(0, 2), ["env", "MANGOHUD=1"], "the game's environment from its launch settings")
	var wrapped := LibraryScript.scope_command(plan["cmd"], 1, 2, "systemd-run")
	eq(wrapped[-1], rom, "still one argument inside the scope command")


func test_esde_on_its_own_and_failures() -> void:
	var home := _dir("esde_alone")
	_touch(home.path_join("Applications/ES-DE_x64.AppImage"))
	_touch(home.path_join("ROMs/psx/Game (Disc 1).chd"))
	_echo_script(home.path_join("Applications/DuckStation-x64.AppImage"))
	_touch(home.path_join("ES-DE/gamelists/psx/gamelist.xml"), "<gameList><alternativeEmulator><label>DuckStation (Standalone)</label></alternativeEmulator></gameList>")
	var ctx := _ctx(home, "esde")
	ctx["system_alt"] = "DuckStation (Standalone)"
	var rom := home.path_join("ROMs/psx/Game (Disc 1).chd")
	var r := EsdeLaunch.build({"system": "psx", "path": rom}, ctx)
	eq(r["cmd"], [home.path_join("Applications/DuckStation-x64.AppImage"), "-batch", rom], "ES-DE's find rules: the AppImage in ~/Applications")
	eq(r["via"], "esde", "no launcher script without EmuDeck")
	ctx["system_alt"] = ""
	var missing := EsdeLaunch.build({"system": "psx", "path": rom}, ctx)
	ok(not missing["ok"] and missing["why"].contains("Beetle PSX"), "RetroArch not installed: says which one is missing (%s)" % missing["why"])
	_touch(home.path_join("ES-DE/custom_systems/es_systems.xml"), "<systemList><system><name>psx</name><path>%ROMPATH%/psx</path><extension>.chd</extension>" +
		"<command label=\"Serial\">%EMULATOR_RPCS3% %RPCS3_GAMEID%</command></system></systemList>")
	var odd := EsdeLaunch.build({"system": "psx", "path": rom}, _ctx(home, "esde"))
	ok(not odd["ok"] and odd["why"].contains("%RPCS3_GAMEID%"), "a variable only ES-DE can fill: left to ES-DE")
	var gone := EsdeLaunch.build({"system": "psx", "path": home.path_join("ROMs/psx/nope.chd")}, ctx)
	ok(not gone["ok"] and gone["why"].contains("isn't there"), "a deleted ROM")


func test_inject_and_shortcuts() -> void:
	var home := _dir("inject")
	_touch(home.path_join("Applications/ES-DE.AppImage"))
	_touch(home.path_join("ROMs/switch/Game.nsp"))
	_touch(home.path_join("ROMs/switch/Game.esprefix"), "WINEDEBUG=-all DXVK_HUD=\"fps,frametimes\"")
	_echo_script(home.path_join("bin/eden"))
	_touch(home.path_join("ES-DE/custom_systems/es_systems.xml"), "<systemList><system><name>switch</name><path>%ROMPATH%/switch</path><extension>.nsp</extension>" +
		"<command label=\"Eden\">%INJECT%=%BASENAME%.esprefix %EMULATOR_EDEN% -f -g %ROM%</command></system></systemList>")
	var ctx := _ctx(home, "esde")
	ctx["path_env"] = home.path_join("bin")
	var rom := home.path_join("ROMs/switch/Game.nsp")
	var r := EsdeLaunch.build({"system": "switch", "path": rom}, ctx)
	eq(r["env"], {"WINEDEBUG": "-all", "DXVK_HUD": "fps,frametimes"}, "injected VAR=value words before the program are its environment")
	eq(r["cmd"], [home.path_join("bin/eden"), "-f", "-g", rom], "the program and ES-DE's arguments")
	var bad := EsdeLaunch.build({"system": "switch", "path": home.path_join("ROMs/switch/Other.nsp")}, ctx)
	ok(not bad["ok"], "a missing ROM")
	_touch(home.path_join("ROMs/switch/Other.nsp"))
	eq(EsdeLaunch.build({"system": "switch", "path": home.path_join("ROMs/switch/Other.nsp")}, ctx)["env"], {}, "no injection file: skipped, like ES-DE")
	_touch(home.path_join("ROMs/ports/Port.desktop"), "[Desktop Entry]\nExec=/usr/bin/port-game --full %f\n")
	var p := EsdeLaunch.build({"system": "ports", "path": home.path_join("ROMs/ports/Port.desktop")}, _ctx(home, "esde"))
	eq(p["cmd"], ["/usr/bin/port-game", "--full"], "a .desktop shortcut runs its Exec line")


func test_retrodeck_uses_its_cli() -> void:
	var home := _dir("retrodeck")
	var rom := home.path_join("retrodeck/roms/psx/Game.chd")
	_touch(rom)
	var r := EsdeLaunch.build({"system": "psx", "path": rom}, {"kind": "retrodeck", "home": home, "custom": {}})
	eq(r["cmd"], ["flatpak", "run", "net.retrodeck.retrodeck", "-s", "psx", rom], "RetroDECK picks the emulator itself")
	eq(r["via"], "retrodeck", "via RetroDECK")


# ------------------------------------------------------------ the Library

func test_library_lists_every_rom() -> void:
	var home := _emudeck("library")
	_age(home)
	SettingsFile.reset_for_tests()
	var res := LibraryScript.collect(home, "/nonexistent/gamedb.json.gz")
	var roms: Array = res["games"].filter(func(g): return g["emulated"].get("rom", false))
	var titles: Array = roms.map(func(g): return g["title"])
	for t in ["Super Game & Friends", "The Legend of Hyrule: A Link", "Third Game", "Disc Game", "Big Game", "Island Game", "Racer", "Single"]:
		ok(t in titles, "%s is a game" % t)
	ok(titles.has("x"), "a folder ES-DE doesn't know keeps its games")
	var x: Dictionary = roms[titles.find("x")]
	ok(x["emulated"]["unknown"] and x["emulated"]["system_short"] == "notasystem", "named after its folder, marked")
	var why := str(Emu.launch_plan(res["entries"][x["key"]], {}, home, "")["why"])
	ok(why.contains("notasystem") and why.contains("Rename"), "and Play says why it can't start")
	var g: Dictionary = roms[titles.find("Super Game & Friends")]
	eq(g["key"], "emu:rom:snes/Super Game (USA).sfc", "key")
	eq([g["emulated"]["system_short"], g["emulated"]["emulator"]], ["SNES", "RetroArch (bsnes)"], "the console as its store badge, its emulator")
	eq(g["info"]["summary"], "A plumber's day out.", "ES-DE's description")
	eq(g["info"]["meta"]["genres"], ["Platform", "Action"], "genres")
	eq(g["info"]["meta"]["sources"]["summary"], "esde", "credited to ES-DE's game list")
	ok(g["art"]["cover"].ends_with("covers/Super Game (USA).png"), "ES-DE's cover")
	ok(g["installed"], "playable")
	ok("emu:rom:snes/Super Game (USA).sfc" in res["imported"]["favourites"], "ES-DE's favourite read")
	ok("emu:rom:snes/Third_Game.zip" in res["imported"]["hidden"], "ES-DE's hidden read")
	var setup: Dictionary = res["emulation"]
	ok(setup["roms_shown"], "the page knows ROM games are on")
	var counts := {}
	for s in setup["systems"]:
		counts[s["id"]] = s["count"]
	eq([counts.get("snes"), counts.get("psx"), counts.get("wiiu")], [3, 4, 1], "the page's counts are the Library's games")
	ok(counts.has("notasystem"), "folders ES-DE doesn't know still show on the page")
	ok(setup["systems"].all(func(sy): return sy["roots"] == [home.path_join("Emulation/roms")]), "each system says which ROM folder it's in")
	var e: Dictionary = res["entries"]["emu:rom:snes/Legend of Hyrule, The - A Link (USA) (Rev 1).smc"]
	var cmd := LibraryScript.launch_command(e, {})
	eq(cmd.slice(0, 2), ["/bin/bash", home.path_join("Emulation/tools/launchers/retroarch.sh")] as Array[String], "started by us, through EmuDeck")
	ok(MetaResolver.new().jobs_for(g).is_empty(), "no lookups by title for a ROM")
	var gens := View.filter_view(res["games"], "emulation:snes")
	eq(gens.size(), 3, "Filter > Emulation > SNES")
	var sys := View.systems_in(res["games"])
	eq(sys[0]["id"], "psx", "systems, most games first")
	eq(View.search(res["games"], "hyrule").map(func(x): return x["title"]), ["The Legend of Hyrule: A Link"], "search finds ROM titles")


func test_setting_turns_rom_games_off() -> void:
	var home := _emudeck("setting")
	SettingsFile.reset_for_tests()
	ok(Emu.roms_enabled(), "on unless turned off")
	ok(Emu.set_roms_enabled(false), "saved")
	ok(not Emu.roms_enabled(), "off")
	var res := LibraryScript.collect(home, "/nonexistent/gamedb.json.gz")
	ok(not res["games"].any(func(g): return g["emulated"].get("rom", false)), "no ROM games")
	ok(res["games"].any(func(g): return g["id"] == "frontend"), "ES-DE still there")
	ok(not res["emulation"]["roms_shown"] and res["emulation"]["rom_total"] > 0, "the page counts files as before")
	ok(Emu.set_roms_enabled(true), "back on")


func test_steam_rom_manager_shortcut_folds_in() -> void:
	var home := _emudeck("dedupe")
	var roms := home.path_join("Emulation/roms")
	var steam := home.path_join(STEAM)
	_touch(steam.path_join("config/loginusers.vdf"), "\"users\"\n{\n\t\"76561197972611406\"\n\t{\n\t\t\"MostRecent\"\t\"1\"\n\t}\n}\n")
	var shortcuts := {"shortcuts": {
		"0": {"appid": -1294967295, "AppName": "Legend (SRM)", "Exe": "\"%s/Emulation/tools/launchers/retroarch.sh\"" % home,
			"LaunchOptions": "-L core.so \"%s\"" % roms.path_join("snes/Legend of Hyrule, The - A Link (USA) (Rev 1).smc"), "IsHidden": 0, "LastPlayTime": 1800000000},
		"1": {"appid": -1294967294, "AppName": "Not Here", "Exe": "\"%s/Emulation/tools/launchers/retroarch.sh\"" % home,
			"LaunchOptions": "-L core.so \"%s\"" % roms.path_join("snes/Gone.sfc"), "IsHidden": 0},
		"2": {"appid": -1294967293, "AppName": "Big (SRM)", "Exe": "\"%s/Emulation/tools/launchers/rpcs3.sh\"" % home,
			"LaunchOptions": "--no-gui \"%s\"" % roms.path_join("ps3/Big Game.ps3/PS3_GAME/USRDIR/EBOOT.BIN"), "IsHidden": 0},
	}}
	var path := steam.path_join("userdata/12345678/config/shortcuts.vdf")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(EmuTests._kv(shortcuts))
	f.close()
	var u := -1294967295 & 0xFFFFFFFF
	_touch(steam.path_join("userdata/12345678/config/grid/%dp.png" % u))
	_touch(steam.path_join("userdata/12345678/config/grid/%d_hero.png" % u))
	SettingsFile.reset_for_tests()
	var played := ProjectSettings.globalize_path(Playtime.PATH)
	var had_played := FileAccess.file_exists(played)
	Playtime.record("emu:%d" % u, 1000, 1000 + 600)
	var res := LibraryScript.collect(home, "/nonexistent/gamedb.json.gz")
	var keys: Array = res["games"].map(func(g): return g["key"])
	ok(not ("emu:%d" % u) in keys, "the shortcut for a ROM we list is gone")
	ok(("emu:%d" % (-1294967294 & 0xFFFFFFFF)) in keys, "a shortcut whose ROM we don't list stays (SRM keeps working)")
	ok(not ("emu:%d" % (-1294967293 & 0xFFFFFFFF)) in keys, "a shortcut into a folder game folds into it too")
	var rk := "emu:rom:snes/Legend of Hyrule, The - A Link (USA) (Rev 1).smc"
	var g: Dictionary = res["games"][keys.find(rk)]
	ok(g["art"]["cover"].ends_with("%dp.png" % u) and g["art"]["hero"].ends_with("%d_hero.png" % u), "ES-DE has no art for it: Steam's (SRM's) art kept")
	eq(g["last_played"], 1800000000, "Steam's last played kept")
	ok(g["playtime_min"] >= 10, "time counted while it was a shortcut follows it")
	eq(res["entries"][rk]["aliases"], ["emu:%d" % u], "the shortcut's key is remembered")
	eq(LibraryScript.aliases_of(res["entries"])["emu:%d" % u], rk, "for collections")
	var cols := Collections.new(_dir("dedupe_cols").path_join("collections.json"))
	cols.set_favourite("emu:%d" % u, true)
	var id := cols.create("Retro")
	cols.add(id, "emu:%d" % u)
	ok(cols.adopt_keys(LibraryScript.aliases_of(res["entries"])), "moved")
	ok(cols.is_favourite(rk) and not cols.is_favourite("emu:%d" % u), "the favourite follows the ROM")
	eq(cols.find(id)["games"], [rk], "and the collection")
	ok(not cols.adopt_keys(LibraryScript.aliases_of(res["entries"])), "nothing left to move: not saved again")
	if not had_played:
		DirAccess.remove_absolute(played)


func test_page_is_the_hub() -> void:
	var home := _emudeck("page")
	SettingsFile.reset_for_tests()
	var res := LibraryScript.collect(home, "/nonexistent/gamedb.json.gz")
	var p: Control = EmulationPage.new()
	p.setup(res["emulation"], res["games"])
	var b: Button = p.find_child("System_snes", true, false)
	ok(b != null and b is Button and b.text.contains("3"), "a system with its count is a button")
	var asked: Array = []
	p.system_requested.connect(func(s): asked.append(s))
	b.pressed.emit()
	eq(asked, ["snes"], "opens the Library on that system")
	ok(p.find_child("InLibrary", true, false).text.contains("own page"), "the Library line says every ROM is a game")
	ok(not p.recent_buttons.is_empty(), "recently played: the ROM games played last")
	var opened: Array = []
	p.game_requested.connect(func(g): opened.append(g["key"]))
	p.recent_buttons[0].pressed.emit()
	eq(opened, ["emu:rom:snes/Super Game (USA).sfc"], "each opens its game page")
	ok(p.focusables.has(b) and p.focusables.has(p.recent_buttons[0]), "reachable with the d-pad")
	ok(p.open_button != null, "Open ES-DE stays")
	# The games themselves, on the page: the same list as the Library's Emulation view.
	ok(p.games_grid != null and p.picker_buttons.size() >= 2, "a console picker and a grid of games")
	var all_titles: Array = p.game_tiles.map(func(t): return t.game["title"])
	eq(all_titles.size(), View.filter_view(res["games"], "emulation").filter(func(g): return g["emulated"].get("rom", false)).size(),
		"All: every ROM game (hidden ones go once the screens decorate them)")
	eq(all_titles[0], "Super Game & Friends", "what you played last first")
	p.pick_system("psx")
	eq(p.game_tiles.size(), 4, "PS1: its four games")
	ok(p.game_tiles.all(func(t): return t.game["emulated"]["system"] == "psx"), "only that console's")
	ok(p.picker_buttons.filter(func(b): return b.button_pressed).map(func(b): return str(b.name)) == ["Pick_psx"], "the picker shows which")
	var played: Array = []
	p.play_requested.connect(func(g): played.append(g["key"]))
	p.game_tiles[0].pressed.emit()
	eq(played, [p.game_tiles[0].game["key"]], "A on a tile plays it")
	var ev := InputEventJoypadButton.new()
	ev.button_index = JOY_BUTTON_START
	ev.pressed = true
	opened.clear()
	p.game_tiles[0].gui_input.emit(ev)
	eq(opened, [p.game_tiles[0].game["key"]], "Menu opens its game page")
	eq(p.hints_for_focus(p.game_tiles[0])[0], ["A", TL.EMU_HINT_PLAY], "the hints say so")
	ok(p.game_tiles[0].focus_neighbor_top != NodePath(""), "linked for the d-pad")
	ok(p.find_child("Recent", true, false).find_child("Title", true, false).size_flags_horizontal & Control.SIZE_EXPAND, "a recent title has the row's whole width")
	p.free()


## Every tile of a ROM game names it and its console, with box art too (scanned
## or scraped console art often has no readable title): Home's shelves, the
## Library grid and search (the same tiles) and the Emulation page's grid.
## A store cover keeps its painted logo alone.
func test_rom_tiles_show_name_and_system() -> void:
	var home := _emudeck("tiles")
	SettingsFile.reset_for_tests()
	var res := LibraryScript.collect(home, "/nonexistent/gamedb.json.gz")
	var roms: Array = res["games"].filter(func(g): return g["emulated"].get("rom", false) and not g["emulated"].get("unknown", false))
	ok(roms.size() >= 4, "ROM games to show")
	var cover := ImageTexture.create_from_image(Image.create(30, 40, false, Image.FORMAT_RGBA8))
	var check := func(t: Button, where: String) -> void:
		var g: Dictionary = t.game
		for with_art in [false, true]:
			if with_art:
				t._show_art(cover, false)
			ok(t.title_label != null and t.title_label.visible and t.title_label.text == str(g["title"]) and str(g["title"]) != "",
				"%s: %s shows its name (%s)" % [where, g["title"], "with box art" if with_art else "no art"])
			ok(t.sub_label.text.begins_with(str(g["emulated"]["system_short"]) + " ·") or t.sub_label.text == str(g["emulated"]["system_short"]),
				"%s: and its console, not the store (%s)" % [where, t.sub_label.text])
			ok(not t.sub_label.text.contains("Emulation"), "%s: never \"Emulation\"" % where)
	for g in roms:
		var t: Button = Tile.new()
		t.setup(g, true, Tile.SIZE, false)
		check.call(t, "Library tile")
		t.free()
	var shelf: VBoxContainer = Shelf.new()
	shelf.setup("emulation", "Emulation", View.emulation_shelf(res["games"]))
	for t in shelf.tiles:
		if View.system_of(t.game) != "":
			check.call(t, "Home shelf")
	shelf.free()
	var p: Control = EmulationPage.new()
	p.setup(res["emulation"], res["games"])
	for t in p.game_tiles:
		check.call(t, "Emulation page")
	p.free()
	var steam := {"key": "steam:1", "store": "steam", "id": "1", "title": "Store Game", "installed": true, "art": {"cover": ""},
		"info": {}, "last_played": 0, "playtime_min": 0, "emulated": {}, "shortcut": false}
	var st: Button = Tile.new()
	st.setup(steam, true, Tile.SIZE, false)
	st._show_art(cover, false)
	ok(not st.title_label.visible, "a store cover keeps its own logo alone")
	st.free()


func test_page_hero() -> void:
	var home := _dir("hero")
	var a := Image.create(30, 40, false, Image.FORMAT_RGBA8)
	a.fill(Color.RED)
	a.save_png(home.path_join("a.png"))
	var b := Image.create(80, 40, false, Image.FORMAT_RGBA8)
	b.fill(Color.BLUE)
	b.save_png(home.path_join("b.png"))
	var games := [
		{"key": "emu:rom:snes/a", "store": "emu", "title": "A", "last_played": 5, "art": {"cover": home.path_join("a.png")}, "emulated": {"rom": true, "system": "snes", "system_short": "SNES"}},
		{"key": "emu:rom:gba/b", "store": "emu", "title": "B", "last_played": 9, "art": {"cover": home.path_join("b.png")}, "emulated": {"rom": true, "system": "gba", "system_short": "GBA"}},
		{"key": "emu:rom:gba/c", "store": "emu", "title": "C", "last_played": 0, "art": {"cover": ""}, "emulated": {"rom": true, "system": "gba", "system_short": "GBA"}},
		{"key": "emu:rom:gba/d", "store": "emu", "title": "D", "hidden": true, "art": {"cover": home.path_join("a.png")}, "emulated": {"rom": true, "system": "gba"}}]
	eq(EmulationPage.collage_covers(games), [home.path_join("b.png"), home.path_join("a.png")], "your own covers, played last first; hidden games left out")
	var img: Image = EmulationPage.collage([home.path_join("b.png"), home.path_join("a.png")], Vector2i(400, 120))
	eq(img.get_size(), Vector2i(400, 120), "drawn at the hero's size")
	ok(img.get_pixel(399, 60).is_equal_approx(Color.BLUE), "the latest cover at the right edge, filling its cell (cut, not stretched)")
	var red := img.get_pixel(400 - 90 - 10 - 2, 60)
	ok(red.r > 0.99 and red.a > 0.9, "then the next, while it starts right of COLLAGE_FROM")
	ok(img.get_pixel(400 - 90 - 10 - 89, 60).a < 0.2, "its left end fades in")
	eq(img.get_pixel(5, 60).a, 0.0, "clear where the title sits (the theme's card shows through)")
	var p: Control = EmulationPage.new()
	var setup := Emu.empty_setup()
	setup["kind"] = "emudeck"
	p.setup(setup, [games[2]])
	eq(p.hero_fallback.pattern_systems, ["GBA"], "no covers yet: a pattern of your consoles")
	p.free()


func test_game_page_facts_and_placeholder() -> void:
	var g := {"key": "emu:rom:snes/A.sfc", "store": "emu", "title": "A", "emulated": {"rom": true, "system": "snes", "system_name": "Nintendo SNES",
		"system_short": "SNES", "emulator": "RetroArch (Snes9x - Current)", "players": "1-2", "rating": 0.8, "playcount": 3}}
	eq(MetadataCard.emu_rows(g), [[TL.FACT_SYSTEM, "Nintendo SNES"], [TL.FACT_RUNS_IN, "RetroArch (Snes9x - Current)"], [TL.FACT_PLAYERS, "1-2"],
		[TL.FACT_RATING, "4 / 5"], [TL.FACT_PLAYED_ESDE, "3 times"]], "system, emulator, players, rating, times played")
	eq(MetadataCard.emu_rows({"store": "steam"}), [], "nothing for other games")
	var a: Control = FallbackArt.new()
	a.setup(g, 22, 12.0, false)
	var b: Control = FallbackArt.new()
	b.setup({"key": "emu:rom:snes/B.sfc", "store": "emu", "title": "B", "emulated": {"rom": true, "system": "snes", "system_short": "SNES"}}, 22, 12.0, false)
	eq(a.system_text, "SNES", "the placeholder carries the console")
	eq(a.colors, b.colors, "and every game of a console shares its colours")
	a.free()
	b.free()


func test_home_shelf_is_capped() -> void:
	var games: Array = [{"key": "emu:frontend", "store": "emu", "id": "frontend", "title": "ES-DE", "last_played": 0}]
	for i in 120:
		games.append({"key": "emu:rom:snes/%d" % i, "store": "emu", "id": "rom:snes/%d" % i, "title": "Game %03d" % i, "last_played": 500 if i == 77 else 0,
			"emulated": {"system": "snes"}})
	var shelf := View.emulation_shelf(games)
	eq(shelf.size(), View.EMU_SHELF_MAX, "a ROM folder with thousands of games doesn't fill Home")
	eq([shelf[0]["id"], shelf[1]["title"]], ["frontend", "Game 077"], "ES-DE, then what you played")


## A fresh EmuDeck (Easy Mode, ES-DE) the way it lands on a Bazzite handheld:
## ~/Emulation/roms/<system>/ each with systeminfo.txt and metadata.txt, ES-DE's
## AppImage in ~/Applications, ~/ES-DE with custom_systems (EmuDeck's 11
## overrides; NES and GBC use ES-DE's bundled list) and custom find rules that
## point RETROARCH at EmuDeck's launcher, no downloaded_media yet.
func test_fresh_emudeck_install() -> void:
	var home := _dir("fresh")
	var emu := home.path_join("Emulation")
	_touch(home.path_join(".config/EmuDeck/settings.sh"), "emulationPath=\"%s\"\nromsPath=\"%s/roms\"\n" % [emu, emu])
	_touch(home.path_join("Applications/ES-DE.AppImage"))
	for s in ["retroarch.sh", "cemu.sh", "dolphin-emu.sh", "duckstation.sh", "shadps4.sh", "supermodel.sh", "xemu-emu.sh"]:
		_echo_script(emu.path_join("tools/launchers").path_join(s))
	_touch(home.path_join(".var/app/org.libretro.RetroArch/config/retroarch/cores/gambatte_libretro.so"))
	_touch(home.path_join(".var/app/org.libretro.RetroArch/config/retroarch/cores/mesen_libretro.so"))
	for sys in ["gbc", "nes", "snes", "psx"]:
		_touch(emu.path_join("roms").path_join(sys).path_join("systeminfo.txt"))
		_touch(emu.path_join("roms").path_join(sys).path_join("metadata.txt"))
	_touch(emu.path_join("roms/gbc/µCity (World).gbc"))
	_touch(emu.path_join("roms/nes/Nova the Squirrel (World) (v1.0.6a).nes"))
	_touch(emu.path_join("roms/nes/Thwaite.nes"))
	var esde := home.path_join("ES-DE")
	DirAccess.make_dir_recursive_absolute(esde.path_join("gamelists"))
	DirAccess.make_dir_recursive_absolute(esde.path_join("themes"))
	_touch(esde.path_join("settings/es_settings.xml"), "<?xml version=\"1.0\"?>\n<string name=\"ROMDirectory\" value=\"%s/roms\" />\n" % emu)
	_touch(esde.path_join("custom_systems/es_systems.xml"), "<systemList><system><name>wiiu</name><path>%%ROMPATH%%/wiiu/roms</path><extension>.rpx</extension>" +
		"<command label=\"Cemu (Native)\">/bin/bash %s/tools/launchers/cemu.sh -f -g %%ROM%%</command></system></systemList>" % emu)
	_touch(esde.path_join("custom_systems/es_find_rules.xml"), "<?xml version=\"1.0\"?>\n<ruleList>\n<emulator name=\"RETROARCH\"><rule type=\"staticpath\"><entry>%s/tools/launchers/retroarch.sh</entry></rule></emulator>\n</ruleList>" % emu)
	SettingsFile.reset_for_tests()
	var res := LibraryScript.collect(home, "/nonexistent/gamedb.json.gz")
	var roms: Array = res["games"].filter(func(g): return g["emulated"].get("rom", false))
	var titles: Array = roms.map(func(g): return g["title"])
	titles.sort()
	eq(titles, ["Nova the Squirrel", "Thwaite", "µCity"], "three games: EmuDeck's notes in each folder aren't, tags dropped, µ kept")
	eq(res["emulation"]["kind"], "emudeck", "EmuDeck")
	var nova: Dictionary = res["entries"]["emu:rom:nes/Nova the Squirrel (World) (v1.0.6a).nes"]
	eq(nova["art"], {"cover": "", "hero": "", "logo": "", "icon": ""}, "no downloaded_media yet: the system placeholder")
	var rom := emu.path_join("roms/nes/Nova the Squirrel (World) (v1.0.6a).nes")
	var plan := Emu.launch_plan(nova, {}, home, "")
	eq(plan["cmd"], ["/bin/bash", emu.path_join("tools/launchers/retroarch.sh"), "-L",
		home.path_join(".var/app/org.libretro.RetroArch/config/retroarch/cores/mesen_libretro.so"), rom], "ES-DE's bundled NES command through EmuDeck's RetroArch launcher, Flatpak core")
	var city: Dictionary = res["entries"]["emu:rom:gbc/µCity (World).gbc"]
	var out := ExecSafe.run(str(Emu.launch_plan(city, {}, home, "")["cmd"][0]), PackedStringArray(Emu.launch_plan(city, {}, home, "")["cmd"].slice(1)))
	ok(str(out["out"]).strip_edges().ends_with(emu.path_join("roms/gbc/µCity (World).gbc")), "a non-ASCII name reaches the launcher whole")
	# The custom find rule alone (no launcher map) finds the same script.
	var ctx := {"kind": "esde", "home": home, "path_env": "", "custom": EsdeLaunch.read_custom(esde)}
	eq(EsdeLaunch.find_emulator("RETROARCH", ctx), emu.path_join("tools/launchers/retroarch.sh"), "custom find rules before ES-DE's own")



## Several ROM roots: EmuDeck's on a fake SD card (settings.sh), ES-DE's own
## ROMDirectory, RetroDECK's, a symlinked system folder, nested folders, an
## unknown folder, an empty system and a configured SD card that isn't in.
func test_every_rom_root() -> void:
	var home := _dir("roots")
	var sd := home.path_join("run/media/deck/SD/Emulation")
	_touch(home.path_join(".config/EmuDeck/settings.sh"), "emulationPath=\"%s\"\nromsPath=\"%s/roms\"\n" % [sd, sd])
	_touch(home.path_join("Applications/ES-DE.AppImage"))
	_touch(sd.path_join("roms/nes/Sd Game (USA).nes"))
	_touch(sd.path_join("roms/nes/Sub/Deeper/Nested Game.nes"))
	DirAccess.make_dir_recursive_absolute(sd.path_join("roms/n64"))
	_touch(sd.path_join("roms/homebrew-stuff/Thing.bin"))
	_touch(home.path_join("Games/ROMs/gba/Home Game.gba"))
	_touch(home.path_join("ES-DE/settings/es_settings.xml"), "<?xml version=\"1.0\"?>\n<string name=\"ROMDirectory\" value=\"~/Games/ROMs\" />\n")
	_touch(home.path_join(".var/app/net.retrodeck.retrodeck/config/retrodeck/retrodeck.cfg"), "roms_folder=%s/retrodeck/roms\n" % home)
	_touch(home.path_join("retrodeck/roms/psx/Rd Game.chd"))
	_touch(home.path_join("elsewhere/snes/Linked Game.sfc"))
	DirAccess.make_dir_recursive_absolute(home.path_join("Games/ROMs"))
	ExecSafe.run("ln", PackedStringArray(["-s", home.path_join("elsewhere/snes"), home.path_join("Games/ROMs/snes")]))
	ExecSafe.run("ln", PackedStringArray(["-s", home.path_join("elsewhere/snes"), sd.path_join("roms/snes")]))
	var setup := Emu.detect(home, "", [], false)
	var paths: Array = setup["roots"].map(func(r): return r["path"])
	ok(sd.path_join("roms") in paths and home.path_join("Games/ROMs") in paths and home.path_join("retrodeck/roms") in paths,
		"EmuDeck's (on the SD card), ES-DE's own and RetroDECK's: %s" % [paths])
	eq(Emu.real_path(home.path_join("Games/ROMs/snes")), home.path_join("elsewhere/snes"), "symlinks followed")
	SettingsFile.reset_for_tests()
	var res := LibraryScript.collect(home, "/nonexistent/gamedb.json.gz")
	var titles: Array = res["games"].filter(func(g): return g["emulated"].get("rom", false)).map(func(g): return g["title"])
	titles.sort()
	eq(titles, ["Home Game", "Linked Game", "Nested Game", "Rd Game", "Sd Game", "Thing"], "every root, nested folders, the linked folder once, the unknown folder too")
	var sys := {}
	for s in res["emulation"]["systems"]:
		sys[s["id"]] = s
	ok(not sys.has("n64"), "an empty system is left out")
	eq(sys["gba"]["roots"], [home.path_join("Games/ROMs")], "each system knows its ROM folder")
	ok(not sys["homebrew-stuff"]["known"], "the unknown folder is marked")
	# The SD card comes out: its games hide; nothing about them is forgotten.
	var nes_key := "emu:rom:nes/Sd Game (USA).nes"
	ok(res["entries"].has(nes_key), "on the card")
	var cache_before: Array = Roms.load_cache()["systems"].keys().filter(func(k): return k.begins_with("nes|"))
	ExecSafe.run("mv", PackedStringArray([home.path_join("run/media/deck/SD"), home.path_join("SD-out")]))
	Emu.removable = Emu.REMOVABLE + [home.path_join("run/media") + "/"]
	var setup2 := Emu.detect(home, "", [], false)
	var gone := LibraryScript.collect(home, "/nonexistent/gamedb.json.gz")
	ok(not gone["entries"].has(nes_key), "card out: its games hide")
	ok(Roms.load_cache()["systems"].keys().filter(func(k): return k.begins_with("nes|")) == cache_before, "and stay cached for when it's back")
	ok(gone["entries"].has("emu:rom:gba/Home Game.gba"), "the other roots stay")
	ok(setup2["roots"].any(func(r): return r["path"] == sd.path_join("roms") and not r["online"]), "listed as offline on the page")
	ExecSafe.run("mv", PackedStringArray([home.path_join("SD-out"), home.path_join("run/media/deck/SD")]))
	ok(LibraryScript.collect(home, "/nonexistent/gamedb.json.gz")["entries"].has(nes_key), "card back: its games are back")
	Emu.removable = Emu.REMOVABLE
