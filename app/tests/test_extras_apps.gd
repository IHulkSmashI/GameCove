extends "res://tests/test_case.gd"
## Desktop apps: .desktop parsing and filtering, Exec field codes, icons, pins,
## the launch command (scope + reaper), Home's Apps shelf and the Apps view.
## A temp folder stands in for $HOME and /usr; nothing is started.

const Apps := preload("res://scripts/library/apps.gd")
const AppsView := preload("res://scripts/ui/apps_view.gd")
const Home := preload("res://scripts/ui/home.gd")
const Tile := preload("res://scripts/ui/game_tile.gd")
const ArtColor := preload("res://theme/art_color.gd")
const GameSession := preload("res://scripts/launch/game_session.gd")
const TX := preload("res://scripts/ui/texts_extras.gd")


func _tmp(tag: String) -> String:
	var d := OS.get_cache_dir().path_join("gamecove_apps_%s_%d" % [tag, Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(d)
	return d


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _wipe(dir: String) -> void:
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(d))
	DirAccess.remove_absolute(dir)


static func _entry(name: String, exec: String, extra := "") -> String:
	return "[Desktop Entry]\nType=Application\nName=%s\nExec=%s\n%s\n[Desktop Action new]\nName=New window\nExec=nope\n" % [name, exec, extra]


func test_parses_the_main_group_only() -> void:
	var e := Apps.parse_desktop("# c\n[Desktop Entry]\nName=Firefox\nName[de]=Feuerfuchs\nExec=firefox %u\nIcon=firefox\n[Desktop Action private]\nName=Private\nExec=firefox --private\n", "de_DE")
	eq([e["Name"], e["Name@local"], e["Exec"], e["Icon"]], ["Firefox", "Feuerfuchs", "firefox %u", "firefox"], "keys, localised name")
	ok(not e.values().has("firefox --private"), "actions ignored")


func test_keeps_what_a_person_would_open() -> void:
	var good := {"Type": "Application", "Exec": "vlc", "Categories": "AudioVideo;Player;"}
	ok(Apps.keep(good, "org.videolan.VLC", ""), "a player")
	ok(not Apps.keep(good.merged({"NoDisplay": "true"}, true), "x", ""), "NoDisplay")
	ok(not Apps.keep(good.merged({"Hidden": "true"}, true), "x", ""), "Hidden")
	ok(not Apps.keep(good.merged({"Terminal": "true"}, true), "x", ""), "terminal programs")
	ok(not Apps.keep(good.merged({"OnlyShowIn": "KDE;"}, true), "x", ""), "one desktop's tools")
	ok(not Apps.keep(good.merged({"Type": "Link"}, true), "x", ""), "links")
	ok(not Apps.keep({"Type": "Application", "Exec": "systemsettings", "Categories": "Qt;KDE;Settings;"}, "systemsettings", ""), "settings")
	ok(not Apps.keep({"Type": "Application", "Exec": "konsole", "Categories": "System;TerminalEmulator;"}, "konsole", ""), "system tools")
	ok(Apps.keep({"Type": "Application", "Exec": "es-de", "Categories": "Game;System;"}, "es-de", ""), "a game front-end tagged System stays")
	ok(not Apps.keep(good, "steam", ""), "Steam has its own mode")
	ok(not Apps.keep(good, "gamecove-installer", ""), "never GameCove itself")
	ok(not Apps.keep(good.merged({"TryExec": "/nonexistent/vlc"}, true), "x", ""), "TryExec missing")


func test_exec_field_codes_and_quoting() -> void:
	eq(Apps.exec_argv("firefox %u"), ["firefox"], "URL code dropped")
	eq(Apps.exec_argv("/usr/bin/flatpak run --branch=stable --arch=x86_64 --command=discord com.discordapp.Discord @@u %U @@"),
		["/usr/bin/flatpak", "run", "--branch=stable", "--arch=x86_64", "--command=discord", "com.discordapp.Discord", "@@u", "@@"], "Flatpak exports")
	eq(Apps.exec_argv("\"/opt/My App/run\" --title \"a \\\"b\\\"\" %F"), ["/opt/My App/run", "--title", "a \"b\""], "quotes and escapes")
	eq(Apps.exec_argv("app --name=%c 100%%", "My App"), ["app", "--name=My App", "100%"], "%c and %%")
	eq(Apps.exec_argv("broken \"quote"), [], "unclosed quote: unusable")


func test_scans_folders_with_icons_and_user_copies_first() -> void:
	var home := _tmp("scan")
	var sysd := home + "/usr/share"
	_write(sysd + "/applications/org.videolan.VLC.desktop", _entry("VLC media player", "vlc --started-from-file %U", "Icon=vlc\nCategories=AudioVideo;"))
	_write(sysd + "/applications/org.kde.konsole.desktop", _entry("Konsole", "konsole", "Categories=System;TerminalEmulator;"))
	_write(sysd + "/applications/hidden.desktop", _entry("Hidden", "x", "NoDisplay=true"))
	_write(sysd + "/applications/steam.desktop", _entry("Steam", "steam %U"))
	_write(home + "/.local/share/flatpak/exports/share/applications/com.discordapp.Discord.desktop",
		_entry("Discord", "/usr/bin/flatpak run --command=discord com.discordapp.Discord", "Icon=com.discordapp.Discord\nX-Flatpak=com.discordapp.Discord"))
	# the user hides the system Firefox with their own NoDisplay copy
	_write(sysd + "/applications/firefox.desktop", _entry("Firefox", "firefox %u"))
	_write(home + "/.local/share/applications/firefox.desktop", _entry("Firefox", "firefox %u", "NoDisplay=true"))
	var png := Image.create_empty(64, 64, false, Image.FORMAT_RGBA8)
	png.fill(Color.ORANGE)
	DirAccess.make_dir_recursive_absolute(sysd + "/icons/hicolor/64x64/apps")
	png.save_png(sysd + "/icons/hicolor/64x64/apps/vlc.png")
	_write(home + "/.local/share/flatpak/exports/share/icons/hicolor/scalable/apps/com.discordapp.Discord.svg",
		"<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'><rect width='16' height='16' fill='#5865F2'/></svg>")
	var list := Apps.scan({"home": home, "xdg_data_dirs": sysd, "path_env": ""})
	eq(list.map(func(a): return a["title"]), ["Discord", "VLC media player"], "apps a person opens, A to Z")
	var vlc: Dictionary = list[1]
	eq([vlc["key"], vlc["store"], vlc["exec"]], ["app:org.videolan.VLC", "app", ["vlc", "--started-from-file"]], "key, store, command")
	eq(vlc["icon"], sysd + "/icons/hicolor/64x64/apps/vlc.png", "theme icon")
	eq(list[0]["flatpak"], "com.discordapp.Discord", "a Flatpak")
	var cached := Apps.cached_icon(list[0])
	ok(cached.ends_with(".png") and FileAccess.file_exists(cached), "SVG icons become PNGs")
	eq(Image.load_from_file(cached).get_width(), Apps.ICON_PX, "at 256 px")
	eq(Apps.with_art(vlc, "/x.png")["art"], {"icon": "/x.png"}, "tiles show the icon")
	DirAccess.remove_absolute(cached)
	_wipe(home)


func test_pins() -> void:
	var dir := _tmp("pins")
	var path := dir.path_join("apps.json")
	var vlc := {"key": "app:vlc", "id": "vlc", "store": "app", "title": "VLC", "exec": ["vlc"], "icon": "", "art": {}}
	var mpv := {"key": "app:mpv", "id": "mpv", "store": "app", "title": "mpv", "exec": ["mpv"], "icon": "", "art": {}}
	eq(Apps.pinned(path), [], "none yet")
	ok(Apps.set_pinned(vlc, true, path) and Apps.set_pinned(mpv, true, path), "pinned two")
	eq(Apps.pinned(path).map(func(a): return a["key"]), ["app:vlc", "app:mpv"], "in pin order")
	ok(Apps.is_pinned("app:mpv", path), "known")
	Apps.set_pinned(vlc, false, path)
	eq(Apps.pinned(path).map(func(a): return a["key"]), ["app:mpv"], "unpinned")
	var renamed := mpv.duplicate()
	renamed["title"] = "mpv Media Player"
	var kept := Apps.refresh_pins([renamed], path)
	eq(kept[0]["title"], "mpv Media Player", "follows the installed app")
	eq(Apps.refresh_pins([], path), [], "uninstalled apps drop off")
	eq(Apps.pinned(path), [], "saved")
	_wipe(dir)


func test_launch_command_gives_gamescope_an_app_id() -> void:
	var app := {"key": "app:com.discordapp.Discord", "exec": ["/usr/bin/flatpak", "run", "com.discordapp.Discord"]}
	var id := Apps.app_id_for(app["key"])
	ok(id & 0x40000000 != 0 and id > 0, "never a real Steam id")
	var full := Apps.launch_command(app, 7, "/usr/bin/systemd-run", true, Apps.REAPER)
	eq(full["cmd"], ["/usr/bin/systemd-run", "--user", "--scope", "--collect", "--quiet", "--unit=app-steam-app%d-7" % id, "--",
		Apps.REAPER, "SteamLaunch", "AppId=%d" % id, "--", "/usr/bin/flatpak", "run", "com.discordapp.Discord"], "scope around the reaper around the app")
	eq(full["app_id"], id, "followed by its id")
	eq(Apps.launch_command(app, 7, "", false, "")["app_id"], 0, "nothing to follow it by")
	eq(Apps.launch_command({"key": "app:x", "exec": []}, 1, "", false, "")["cmd"], [], "no command")


func test_apps_run_without_frame_limit_or_auto_tdp() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/launch/game_session.gd")
	ok(src.contains('str(g.get("store", "")) in ["stream", "app"]'), "an app isn't a game")
	var lib := FileAccess.get_file_as_string("res://scripts/library/library.gd")
	ok(lib.contains("if str(game.get(\"store\", \"\")) == Apps.STORE:\n\t\treturn launch_app(game, path_env)"), "Library starts apps through launch_app")


func test_home_apps_shelf() -> void:
	var games := [{"key": "steam:1", "store": "steam", "title": "Hades", "installed": true, "last_played": 5}]
	eq(Home.shelf_specs(games, []).filter(func(s): return s["id"] == "apps"), [], "nothing pinned: no shelf")
	var pinned := [{"key": "app:vlc", "store": "app", "title": "VLC", "exec": ["vlc"], "installed": true, "art": {}}]
	var specs := Home.shelf_specs(games, pinned)
	var shelf: Dictionary = specs.filter(func(s): return s["id"] == "apps")[0]
	eq(shelf["title"], TX.APPS_SHELF, "Apps")
	eq(shelf["games"].map(func(g): return g["key"]), ["app:vlc", AppsView.ALL_KEY], "pinned apps, then All apps")
	var h: Control = Home.new()
	h.set_games(games)
	var played := []
	var opened := []
	h.play_requested.connect(func(g): played.append(g["key"]))
	h.apps_requested.connect(func(): opened.append(true))
	h.set_apps(pinned)
	var row: Node = h.find_child("Row_apps", true, false)
	ok(row != null, "the shelf is there")
	eq(row.count_label.text, "1 app", "counted as apps")
	row.tile_pressed.emit(pinned[0])
	row.tile_pressed.emit(AppsView.all_tile())
	eq(played, ["app:vlc"], "A starts the app")
	eq(opened, [true], "All apps opens the view")
	h.free()


func test_apps_view_lists_pins_first_and_pins_with_x() -> void:
	var dir := _tmp("view")
	var v: Control = AppsView.new()
	v.pins_path = dir.path_join("apps.json")
	var list := [
		{"key": "app:zed", "id": "zed", "store": "app", "title": "Zed", "exec": ["zed"], "icon": "", "art": {}, "installed": true},
		{"key": "app:vlc", "id": "vlc", "store": "app", "title": "VLC", "exec": ["vlc"], "icon": "", "art": {}, "installed": true},
		{"key": "app:anki", "id": "anki", "store": "app", "title": "Anki", "exec": ["anki"], "icon": "", "art": {}, "installed": true},
	]
	v.scan_fn = func() -> Array: return list
	var changes := []
	v.pins_changed.connect(func(): changes.append(true))
	v.open()
	eq(v.tiles.map(func(t): return t.game["title"]), ["Anki", "VLC", "Zed"], "A to Z")
	v.toggle_pin(list[0])
	eq(v.tiles.map(func(t): return t.game["title"]), ["Zed", "Anki", "VLC"], "pinned first")
	eq(changes.size(), 1, "Home is told")
	ok(Apps.is_pinned("app:zed", v.pins_path), "saved")
	var hints: Array = v.hints_for_focus(v.tiles[0])
	eq(hints[1], ["X", TX.APPS_UNPIN], "X unpins a pinned app")
	var launched := []
	v.launch_requested.connect(func(a): launched.append(a["key"]))
	v.tiles[1].pressed.emit()
	eq(launched, ["app:anki"], "A starts it")
	v.free()
	_wipe(dir)


func test_app_tiles_show_their_icon() -> void:
	var dir := _tmp("tile")
	var img := Image.create_empty(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color.RED)
	img.save_png(dir + "/i.png")
	var t: Button = Tile.new()
	t.setup({"key": "app:x", "store": "app", "title": "Thing", "installed": true, "art": {"icon": dir + "/i.png"}}, false)
	ok(t.app_icon != null and t.app_icon.texture != null, "icon in the middle")
	ok(not t.fallback.monogram, "instead of the monogram")
	ok(t.title_label.visible, "the title on the plate")
	eq(t.sub_label.text, "App", "says it's an app")
	ok(t.fallback.plain, "no generated scenery behind the icon")
	var bg: Color = t.fallback.colors[1]
	ok(bg.h < 0.05 or bg.h > 0.95, "the card takes the icon's own hue (red): %s" % bg)
	ok(bg.v < 0.5, "and stays dark, so the icon is the bright thing: %s" % bg)
	t.free()
	_wipe(dir)


func test_app_card_colours_from_the_icon() -> void:
	var grey := ArtColor.app_card_colors(Color(0, 0, 0, 0))
	ok(absf(grey[1].s) < 0.2, "a grey or unknown icon gets a neutral slate")
	var blue := ArtColor.app_card_colors(Color.from_hsv(0.6, 0.9, 0.9))
	ok(absf(blue[0].h - 0.6) < 0.01 and absf(blue[1].h - 0.6) < 0.01, "same hue as the icon")
	ok(blue[0].v < blue[1].v and blue[1].v <= 0.4, "dark, darker at the base")
	ok(blue[1].s <= 0.6, "muted, never louder than the icon")
