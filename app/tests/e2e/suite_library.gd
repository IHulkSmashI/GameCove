extends "res://tests/e2e/e2e_case.gd"
## Favourites, hidden games, collections and the Emulation page on the real
## app with a controller: Menu on a tile opens the game's options, a favourite
## gets Home's shelf, a hidden game leaves the grid and comes back through the
## Library's Filter sheet (View), and the Emulation page (nothing
## installed in the fake home) shows the EmuDeck QR code.

const TL := preload("res://scripts/ui/texts_library.gd")


func _games() -> Array:
	var out: Array = []
	for g in [GAME_A, GAME_B]:
		var d: Dictionary = g.duplicate()
		d["art"] = {"cover": "", "hero": "", "logo": "", "icon": ""}
		d["info"] = {"released": null, "time_to_beat": null, "anticheat": null, "protondb": null, "summary": ""}
		d["last_played"] = 0
		d["playtime_min"] = 0
		out.append(d)
	return out


## The hint bar's words now.
func _hints() -> String:
	var bar: Control = main().hint_bar
	return preload("res://scripts/ui/ui_kit.gd").prompts_text(bar.get_child(bar.get_child_count() - 1)) if bar.get_child_count() > 0 else ""


func _sheet() -> Control:
	return main().game_actions.sheet


func _pick(id: String) -> void:
	_sheet().pick(id)
	await w.frames(4)


func test_favourite_hide_and_show_again() -> void:
	var lib: Node = w.autoload("Library")
	var before: Array = lib.games.duplicate()
	lib.collections.path = w.home.path_join(".local/share/gamecove-e2e-collections.json")
	lib.collections.reload()
	lib.games.assign(_games())
	lib.changed.emit()
	await w.frames(3)
	main().show_screen("library")
	await w.frames(4)
	var tiles: Array = main().library_screen.tiles()
	eq(tiles.size(), 2, "both games in the grid")
	tiles[0].grab_focus()
	var key: String = tiles[0].game["key"]
	await press(JOY_BUTTON_START)
	ok(_sheet().is_open(), "Menu on a tile opens its options")
	await _pick("favourite")
	await w.frames(4)
	ok(lib.collections.is_favourite(key), "favourited")
	ok(main().home.shelf_ids().has("favourites"), "Home has a Favourites shelf")
	main().library_screen.tiles()[0].grab_focus()
	for t in main().library_screen.tiles():
		if t.game["key"] == key:
			t.grab_focus()
	await press(JOY_BUTTON_START)
	await _pick("hide")
	await w.frames(4)
	eq(main().library_screen.tiles().size(), 1, "a hidden game leaves the grid")
	await press(JOY_BUTTON_BACK)
	ok(_sheet().is_open(), "View opens the Filter sheet")
	await _pick("hidden")
	eq(main().library_screen.tiles().map(func(t): return t.game["key"]), [key], "Hidden games view")
	main().library_screen.tiles()[0].grab_focus()
	await press(JOY_BUTTON_START)
	await _pick("unhide")
	await w.frames(4)
	ok(not lib.collections.is_hidden(key), "shown again")
	main().library_screen.set_view("")
	await w.frames(3)
	eq(main().library_screen.tiles().size(), 2, "back in the grid")
	lib.collections.set_favourite(key, false)
	# Leave the library as the other suites expect it (no games: "no game running" checks).
	lib.games.assign(before)
	lib.changed.emit()
	main().show_screen("home")
	await w.frames(3)


func test_emulation_page_empty_state() -> void:
	main().open_emulation()
	await w.frames(6)
	var p: Control = main().page
	ok(p != null and p.name == "EmulationPage", "the Emulation page opens")
	ok(p.find_child("Qr", true, false) != null, "nothing installed: EmuDeck's QR code")
	eq(focus(), p.get_button, "focus on Open emudeck.com")
	await a()
	ok(p.handoff.is_open(), "it hands the address to the phone")
	await b()
	await b()
	ok(main().page == null, "B closes the page")


## Final review (Low): Menu on a pinned app's tile (or "All apps") offered a
## game's options: favourite, hide, collections. Apps have none.
func test_menu_on_an_app_tile_offers_no_game_options() -> void:
	var m: Control = main()
	var lib: Node = w.autoload("Library")
	var before: Array = lib.games.duplicate()
	lib.games.assign(_games())
	lib.changed.emit()
	var pinned := [{"key": "app:vlc", "id": "vlc", "store": "app", "title": "VLC", "exec": ["vlc"], "installed": true, "art": {}}]
	m.home.set_apps(pinned)
	await w.frames(4)
	var row: Node = m.home.find_child("Row_apps", true, false)
	ok(row != null and row.tiles.size() == 2, "the Apps shelf: the pinned app and All apps")
	for t in row.tiles:
		t.grab_focus()
		await w.frames(2)
		ok(not _hints().contains("Options"), "%s: no Options hint" % t.game["title"])
		await press(JOY_BUTTON_START)
		ok(not _sheet().is_open(), "%s: Menu opens no game options" % t.game["title"])
	# a game's tile still has them
	var games_row: Node = m.home.find_child("Row_all", true, false)
	games_row.tiles[0].grab_focus()
	await w.frames(2)
	ok(_hints().contains("Options"), "a game's tile says Options")
	await press(JOY_BUTTON_START)
	ok(_sheet().is_open(), "and Menu opens them")
	await b()
	m.home.set_apps([])
	lib.games.assign(before)
	lib.changed.emit()
	await w.frames(3)
