extends "res://tests/test_case.gd"
## Emulation through EmuDeck / RetroDECK / ES-DE (scripts/library/stores/emu.gd):
## detection on throwaway homes, ROM folder counts, ES-DE's gamelists, Steam
## ROM Manager's shortcuts (binary shortcuts.vdf written here), Steam's game id
## for them, play time, and the Emulation page. Nothing reads this machine.

const Emu := preload("res://scripts/library/stores/emu.gd")
const LibraryScript := preload("res://scripts/library/library.gd")
const Playtime := preload("res://scripts/library/playtime.gd")
const StoreManager := preload("res://scripts/library/manage/store_manager.gd")
const EmulationPage := preload("res://scripts/ui/emulation_page.gd")
const TL := preload("res://scripts/ui/texts_library.gd")
const SettingsFile := preload("res://scripts/system/settings_file.gd")
const Logic := preload("res://tests/test_ui_logic.gd")

const BASE := "user://test_emulation"
const STEAM := ".local/share/Steam"


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
	return p


func _touch(path: String, text := "x") -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## A home with EmuDeck: settings.sh pointing at an Emulation folder elsewhere,
## its AppImages, two systems' ROMs, ES-DE's gamelists.
func _emudeck(name: String) -> String:
	var home := _dir(name)
	var emu := home.path_join("sd/Emulation")
	_touch(home.path_join(".config/EmuDeck/settings.sh"), "#!/bin/bash\nexpert=false\nemulationPath=\"%s\"\nromsPath=x\n" % emu)
	_touch(home.path_join("Applications/EmuDeck.AppImage"))
	_touch(home.path_join("Applications/ES-DE.AppImage"))
	_touch(home.path_join("Applications/srm/Steam-ROM-Manager.AppImage"))
	var snes := emu.path_join("roms/snes")
	for f in ["Super Game (USA).sfc", "Other Game.smc", "Third.zip", "systeminfo.txt", "metadata.txt", ".hidden.sfc"]:
		_touch(snes.path_join(f))
	_touch(snes.path_join("media/covers/Super Game (USA).png"))
	var psx := emu.path_join("roms/psx")
	for f in ["Disc Game (Disc 1).cue", "Disc Game (Disc 1).bin", "Disc Game (Disc 2).cue", "Disc Game (Disc 2).bin", "Single.chd"]:
		_touch(psx.path_join(f))
	_touch(psx.path_join("Disc Game.m3u"), "Disc Game (Disc 1).cue\nDisc Game (Disc 2).cue\n")
	_touch(emu.path_join("roms/ps3/Big Game.ps3/PS3_GAME/USRDIR/EBOOT.BIN"))
	DirAccess.make_dir_recursive_absolute(emu.path_join("roms/n64"))
	_touch(emu.path_join("roms/gc/noload.txt"))
	_touch(emu.path_join("roms/gc/game.iso"))
	_touch(home.path_join("ES-DE/gamelists/snes/gamelist.xml"), """<?xml version="1.0"?>
<gameList>
	<game><path>./Super Game (USA).sfc</path><name>Super Game</name><playcount>3</playcount><lastplayed>20240131T201500</lastplayed></game>
	<game><path>./Other Game.smc</path><name>Other &amp; Game</name></game>
</gameList>""")
	_touch(home.path_join("ES-DE/gamelists/psx/gamelist.xml"), """<?xml version="1.0"?>
<gameList><game><path>./Single.chd</path><lastplayed>20250305T090000</lastplayed></game></gameList>""")
	return home


func test_detect_emudeck() -> void:
	var home := _emudeck("emudeck")
	var e := Emu.detect(home, "", [])
	eq(e["kind"], "emudeck", "EmuDeck found")
	eq(e["roms_dir"], home.path_join("sd/Emulation/roms"), "its ROM folder from settings.sh (an SD card here)")
	eq(e["frontend"], {"name": "ES-DE", "command": [home.path_join("Applications/ES-DE.AppImage")]}, "ES-DE's AppImage")
	eq(e["app"]["command"], [home.path_join("Applications/EmuDeck.AppImage")], "EmuDeck's own app")
	eq(e["srm"]["command"], [home.path_join("Applications/srm/Steam-ROM-Manager.AppImage")], "Steam ROM Manager")
	var counts := {}
	for s in e["systems"]:
		counts[s["id"]] = s["count"]
	eq(counts, {"snes": 3, "psx": 2, "ps3": 1}, "games only: no notes, media, dot files, tracks or listed discs; empty and noload folders left out")
	eq(e["systems"][0]["id"], "snes", "most games first")
	eq(e["systems"][0]["short"], "SNES", "short names")
	eq(e["rom_total"], 6, "total")
	eq(e["recent"].map(func(r): return [r["title"], r["system"]]), [["Single", "PS1"], ["Super Game", "SNES"]], "recently played from the gamelists, newest first; no name: the file name")
	eq(e["recent"][1]["last_played"], int(Time.get_unix_time_from_datetime_string("2024-01-31T20:15:00")), "ES-DE's date read")


func test_detect_retrodeck_and_esde_and_none() -> void:
	var home := _dir("retrodeck")
	var fp := _dir("retrodeck_flatpak") + "/"
	DirAccess.make_dir_recursive_absolute(fp + "net.retrodeck.retrodeck/current/active/files/share/es-de/resources/systems/linux")
	_touch(fp + "net.retrodeck.retrodeck/current/active/files/share/es-de/resources/systems/linux/es_systems.xml",
		"<?xml version=\"1.0\"?>\n<systemList><system><name>snes</name><fullname>RetroDECK Super Nintendo</fullname></system></systemList>")
	_touch(home.path_join(".var/app/net.retrodeck.retrodeck/config/retrodeck/retrodeck.cfg"), "version=0.9.1\n[paths]\nrdhome=%s/rd\nroms_folder=%s/rd/roms\n" % [home, home])
	_touch(home.path_join("rd/roms/snes/a.sfc"))
	var e := Emu.detect(home, "", [fp])
	eq(e["kind"], "retrodeck", "RetroDECK")
	eq(e["frontend"]["command"], ["flatpak", "run", "net.retrodeck.retrodeck"], "starts through Flatpak")
	eq(e["app"]["command"], ["flatpak", "run", "net.retrodeck.retrodeck", "--configurator"], "its configurator")
	eq(e["roms_dir"], home.path_join("rd/roms"), "roms_folder from retrodeck.cfg")
	eq(e["systems"][0]["name"], "RetroDECK Super Nintendo", "system names from the installed ES-DE's own es_systems.xml")

	var h2 := _dir("esde")
	_touch(h2.path_join("Applications/ES-DE_x64.AppImage"))
	_touch(h2.path_join("ES-DE/settings/es_settings.xml"), "<?xml version=\"1.0\"?>\n<string name=\"ROMDirectory\" value=\"~/Games/roms\" />\n")
	_touch(h2.path_join("Games/roms/gba/x.gba"))
	var e2 := Emu.detect(h2, "", [])
	eq(e2["kind"], "esde", "ES-DE on its own")
	eq(e2["roms_dir"], h2.path_join("Games/roms"), "ROMDirectory from es_settings.xml")
	eq(e2["app"], {}, "no EmuDeck app")
	eq(e2["systems"][0]["id"], "gba", "its systems")

	var e3 := Emu.detect(_dir("none"), "", [])
	eq(e3["kind"], "", "nothing installed")
	eq(e3["systems"], [], "nothing counted")


# ------------------------------------------------------------ Steam ROM Manager shortcuts

func test_recognise_launch_lines() -> void:
	var r := Emu.recognise("\"/home/deck/Emulation/tools/launchers/retroarch.sh\"",
		"-L /home/deck/.var/app/org.libretro.RetroArch/config/retroarch/cores/snes9x_libretro.so \"'/home/deck/Emulation/roms/snes/Super Game (USA).sfc'\"")
	eq([r["system"], r["via"], r["emulator"]], ["snes", "emudeck", "RetroArch"], "EmuDeck's RetroArch launcher")
	eq(r["rom"], "Super Game (USA).sfc", "the ROM")
	var d := Emu.recognise("\"flatpak\"", "run net.retrodeck.retrodeck \"/home/deck/retrodeck/roms/psx/Game.chd\"")
	eq([d["system"], d["via"]], ["psx", "retrodeck"], "RetroDECK")
	var p := Emu.recognise("\"/home/deck/Emulation/tools/launchers/pcsx2-qt.sh\"", "-batch \"/run/media/sd/Emulation/roms/ps2/Game.iso\"")
	eq([p["system"], p["emulator"]], ["ps2", "PCSX2"], "a standalone emulator through EmuDeck, ROMs on an SD card")
	eq(Emu.recognise("\"/home/deck/Games/Hades/Hades.exe\"", ""), {}, "a PC game isn't")
	eq(Emu.recognise("\"/home/deck/Applications/ES-DE.AppImage\"", ""), {}, "ES-DE itself isn't a game")
	eq(Emu.recognise("\"/usr/bin/foo\"", "/data/roms/notasystem/x.bin"), {}, "an unknown folder with no emulator isn't")


func test_shortcut_game_id() -> void:
	eq(Emu.shortcut_game_id(-1), "18446744069448138752", "top bit set (stored as a negative int32)")
	eq(Emu.shortcut_game_id(3000000001), "12884901892328521728", "a typical SRM id")
	eq(Emu.shortcut_game_id(1), "4328521728", "small")
	ok(Emu.valid_game_id("12884901892328521728"), "valid")
	ok(not Emu.valid_game_id("1288/../x") and not Emu.valid_game_id("") and not Emu.valid_game_id("000"), "anything else never reaches a steam:// URI")


## Valve binary KeyValues: what shortcuts.vdf holds.
static func _kv(map: Dictionary) -> PackedByteArray:
	var b := PackedByteArray()
	for k in map:
		var v: Variant = map[k]
		if v is Dictionary:
			b.append(0)
			b.append_array(str(k).to_utf8_buffer())
			b.append(0)
			b.append_array(_kv(v))
		elif v is int:
			b.append(2)
			b.append_array(str(k).to_utf8_buffer())
			b.append(0)
			var n := PackedByteArray()
			n.resize(4)
			n.encode_s32(0, v)
			b.append_array(n)
		else:
			b.append(1)
			b.append_array(str(k).to_utf8_buffer())
			b.append(0)
			b.append_array(str(v).to_utf8_buffer())
			b.append(0)
	b.append(8)
	return b


func _shortcuts_home(name: String) -> String:
	var home := _dir(name)
	var steam := home.path_join(STEAM)
	_touch(steam.path_join("config/loginusers.vdf"), "\"users\"\n{\n\t\"76561197972611406\"\n\t{\n\t\t\"MostRecent\"\t\"1\"\n\t}\n}\n")
	var shortcuts := {"shortcuts": {
		"0": {"appid": -1294967295, "AppName": "Super Game", "Exe": "\"/home/deck/Emulation/tools/launchers/retroarch.sh\"",
			"StartDir": "\"/home/deck/Emulation/tools/launchers/\"", "LaunchOptions": "-L core.so \"'/home/deck/Emulation/roms/snes/Super Game (USA).sfc'\"",
			"IsHidden": 0, "LastPlayTime": 1700000000, "tags": {"0": "Nintendo SNES"}},
		"1": {"appid": -1294967294, "AppName": "Hades", "Exe": "\"/home/deck/Games/Hades.exe\"", "LaunchOptions": "", "IsHidden": 0},
		"2": {"appid": -1294967293, "appname": "Disc Game", "exe": "\"flatpak\"", "LaunchOptions": "run net.retrodeck.retrodeck \"/home/deck/retrodeck/roms/psx/Disc Game.m3u\"", "IsHidden": 1},
	}}
	var path := steam.path_join("userdata/12345678/config/shortcuts.vdf")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(_kv(shortcuts))
	f.close()
	var u := -1294967295 & 0xFFFFFFFF
	_touch(steam.path_join("userdata/12345678/config/grid/%dp.png" % u))
	_touch(steam.path_join("userdata/12345678/config/grid/%d_hero.png" % u))
	return home


func test_shortcuts_become_emulated_games() -> void:
	var home := _shortcuts_home("srm")
	var list := Emu.scan(home, Emu.empty_setup())
	eq(list.map(func(e): return e["title"]), ["Super Game", "Disc Game"], "SRM's ROM shortcuts; the PC game's shortcut left alone")
	var g: Dictionary = list[0]
	var u := -1294967295 & 0xFFFFFFFF
	eq([g["store"], g["id"]], ["emu", str(u)], "keyed by Steam's shortcut app id")
	eq(g["game_id"], Emu.shortcut_game_id(u), "Steam's 64-bit id to start it")
	eq(g["emulated"]["system_short"], "SNES", "system")
	eq(g["emulated"]["emulator"], "RetroArch", "emulator")
	ok(g["art"]["cover"].ends_with("%dp.png" % u) and g["art"]["hero"].ends_with("%d_hero.png" % u), "SRM's art from Steam's grid folder")
	eq(g["last_played"], 1700000000, "Steam's last played")
	ok(list[1]["hidden_in_steam"], "hidden in Steam")
	var r := LibraryScript.collect(home, "/nonexistent/gamedb.json.gz")
	var keys: Array = r["games"].map(func(x): return x["key"])
	ok(("emu:%d" % u) in keys, "in the Library")
	ok(("emu:%d" % (-1294967293 & 0xFFFFFFFF)) in r["imported"]["hidden"], "hidden in Steam: hidden here too (read-only)")
	var game: Dictionary = r["games"][keys.find("emu:%d" % u)]
	ok(game["info"]["summary"].contains("Nintendo SNES") and game["info"]["summary"].contains("RetroArch"), "the page says what it is")
	eq(game["info"]["meta"]["steam_twin"], "", "never matched to a PC game by title")
	eq(game["emulated"]["system"], "snes", "the game carries its system")
	ok(game["shortcut"], "marked as a Steam shortcut")
	eq(LibraryScript.launch_command(r["entries"]["emu:%d" % u], {}), [] as Array[String], "not started by us: Steam starts it (Library.launch)")


## Final review (Low): a Steam-only rescan (after an install or uninstall) knew
## no shortcut, so shortcuts hidden in Steam came back on every screen.
func test_hidden_shortcuts_stay_hidden_after_a_one_store_rescan() -> void:
	var home := _shortcuts_home("srm_rescan")
	var hidden_key := "emu:%d" % (-1294967293 & 0xFFFFFFFF)
	var lib: Node = LibraryScript.new()
	lib.collections.path = home.path_join("collections.json")
	lib.collections.reload()
	lib.take(LibraryScript.collect(home, "/nonexistent/gamedb.json.gz"), "")
	ok(lib.collections.is_hidden(hidden_key), "hidden after the full scan")
	var steam_only := LibraryScript.collect(home, "/nonexistent/gamedb.json.gz", ["steam"])
	ok(not hidden_key in steam_only["imported"]["hidden"], "a Steam-only scan doesn't see the shortcut itself")
	lib.take(steam_only, "steam")
	ok(lib.collections.is_hidden(hidden_key), "and it stays hidden after it")
	ok(lib.games.any(func(g): return g["key"] == hidden_key), "the game is still in the library")
	lib.take(LibraryScript.collect(home, "/nonexistent/gamedb.json.gz", ["emu"]), "emu")
	ok(lib.collections.is_hidden(hidden_key), "an Emulation-only scan keeps it too")
	lib.free()


func test_frontend_entry_and_launch() -> void:
	var home := _emudeck("frontend")
	var setup := Emu.detect(home, "", [])
	var list := Emu.scan(home, setup)
	eq(list.size(), 1, "the frontend")
	eq([list[0]["key"] if list[0].has("key") else "emu:" + list[0]["id"], list[0]["title"]], ["emu:frontend", "ES-DE"], "ES-DE as a library entry")
	eq(LibraryScript.launch_command(list[0], {}), [home.path_join("Applications/ES-DE.AppImage")] as Array[String], "started the way any game we start is (scoped by Library.launch)")
	var caps := StoreManager.emu_capabilities()
	ok(not caps["install"] and not caps["uninstall"] and not caps["launch_options"], "nothing for the store manager to do")


func test_playtime() -> void:
	SettingsFile.reset_for_tests()
	var path := _dir("playtime").path_join("playtime.json")
	ok(not Playtime.record("emu:frontend", 1000, 1005, path), "a 5 s launch doesn't count")
	ok(Playtime.record("emu:frontend", 1000, 1000 + 1800, path), "half an hour")
	ok(Playtime.record("emu:frontend", 5000, 5000 + 1200, path), "and twenty minutes")
	var t := Playtime.read(path)
	eq(t["emu:frontend"], {"last_played": 6200, "playtime_min": 50}, "added up")
	var e := {"store": "emu", "id": "frontend", "last_played": 7000, "playtime_min": 0}
	Playtime.apply(e, t)
	eq([e["last_played"], e["playtime_min"]], [7000, 50], "newest last played, our minutes")


# ------------------------------------------------------------ Emulation page

func _decorated(home: String) -> Dictionary:
	var setup := Emu.detect(home, "", [])
	var games: Array = []
	for e in Emu.scan(home, setup):
		games.append(LibraryScript.make_game(e))
	return {"setup": setup, "games": games}


func test_page_with_emudeck() -> void:
	var d := _decorated(_emudeck("page"))
	var p: Control = EmulationPage.new()
	p.setup(d["setup"], d["games"] + [Logic.g("emu", "77", "Super Game"), Logic.g("steam", "1", "Alpha")])
	eq(p.open_button.text, TL.EMU_OPEN % "ES-DE", "Open ES-DE first")
	eq(p.app_button.text, TL.EMU_APP_EMUDECK, "EmuDeck's app")
	ok(not p.srm_button.disabled, "Add or update ROMs")
	var asked: Array = []
	p.play_requested.connect(func(g): asked.append(g))
	p.open_button.pressed.emit()
	p.app_button.pressed.emit()
	p.srm_button.pressed.emit()
	eq(asked.map(func(g): return g["key"]), ["emu:frontend", "emu:app", "emu:srm"], "all through main's launch path")
	eq(asked[2]["command"], d["setup"]["srm"]["command"], "Steam ROM Manager's own command")
	ok(p.find_child("System_snes", true, false) != null, "system chips")
	ok(p.find_child("RomTotal", true, false).text.contains("6 games"), "how many ROMs")
	ok(p.library_button != null, "one emulated game in the library: a way to see them")
	var lib := [0]
	p.library_requested.connect(func(): lib[0] += 1)
	p.library_button.pressed.emit()
	eq(lib[0], 1, "Show in Library")
	eq(p.default_focus(), p.open_button, "focus on Open ES-DE")
	p.free()


func test_page_empty_state() -> void:
	var p: Control = EmulationPage.new()
	p.setup(Emu.empty_setup(), [])
	ok(p.get_button != null and p.get_button.text == TL.EMU_GET, "one thing to do: get EmuDeck")
	ok(p.find_child("Qr", true, false).texture != null, "QR code to emudeck.com")
	eq(p.default_focus(), p.get_button, "focus on it")
	ok(p.open_button == null and p.srm_button == null, "nothing to open")
	p.free()


func test_page_without_srm() -> void:
	var home := _emudeck("nosrm")
	DirAccess.remove_absolute(home.path_join("Applications/srm/Steam-ROM-Manager.AppImage"))
	var d := _decorated(home)
	var p: Control = EmulationPage.new()
	p.setup(d["setup"], d["games"])
	ok(p.srm_button.disabled, "no Steam ROM Manager: greyed")
	ok(p.find_child("NoSrm", true, false) != null, "and says how to get it")
	var asked: Array = []
	p.play_requested.connect(func(g): asked.append(g))
	p.srm_button.pressed.emit()
	eq(asked, [], "nothing starts")
	p.free()
