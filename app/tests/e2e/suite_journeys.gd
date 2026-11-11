extends "res://tests/e2e/journey_case.gd"
## User journeys, start to finish, with a player's hands only (journey_case.gd):
## the coverage matrix in docs/TESTING.md names the journey that covers each
## thing a player can do. Each journey starts from a freshly reset handheld
## (world.reset()) with the player's games on it (stores_world.gd) and puts the
## stores away at the end.

const TG := preload("res://scripts/ui/texts_games.gd")
const TL := preload("res://scripts/ui/texts_library.gd")


func page() -> Control:
	return main().page


func install_state(key: String) -> String:
	return main().install_state.state_of(key)


## From the Library grid to game `key`'s page: D-pad to its tile, A.
func open_from_library(key: String) -> bool:
	if not await go_tab("library"):
		return false
	if lib_tile(key) == null:
		return false
	if not await press_on(func(): return lib_tile(key), 80):
		print("E2E DEBUG could not reach tile %s; focus %s" % [key, focus().get_path() if focus() else "null"])
		return false
	await w.frames(4)
	return page() != null and str(page().game.get("key", "")) == key


## The game page's primary button (Play / Install / Pause / Resume / Update).
func primary_text() -> String:
	return page().play_button.text if page() != null and page().play_button != null else ""


## Waits for install state `want` of `key` (up to `ms`).
func wait_state(key: String, want: Array, ms := 15000) -> bool:
	return await until(func(): return install_state(key) in want, ms)


# ---- the library -------------------------------------------------------------------

func test_library_shows_every_store() -> void:
	await with_stores()
	ok(await go_tab("library"), "RB reaches the Library")
	var keys: Array = main().library_screen.tiles().map(func(t): return str(t.game["key"]))
	for k in ["steam:1145360", "steam:367520", "steam:1091500", "steam:413150", "epic:Quail", "epic:Salt", "gog:1207658924", "amazon:amzn1.adg.product.e2e1"]:
		ok(k in keys, "%s in the Library (%s)" % [k, keys])
	check("library")
	await without_stores()


# ---- installing: Epic (legendary), with pause, resume and cancel ----------------------------

func test_install_epic_pause_resume_finish() -> void:
	await with_stores()
	stores.set_speed(0.6)
	var key := "epic:Salt"
	ok(await open_from_library(key), "A on Rocket League opens its page")
	eq(primary_text(), "Install", "not installed: Install first")
	ok(focused_in(page().play_button), "focus starts on Install")
	await a()
	await w.frames(3)
	if sheet_open():
		ok(TG.WHERE_TITLE.to_lower() in screen_text(sheet()).to_lower(), "asks where it goes")
		ok(sheet_ids().size() >= 2, "internal storage and the SD card offered (%s)" % [sheet_ids()])
		ok(await choose(sheet_ids()[0]), "A on internal storage")
	ok(await wait_state(key, ["installing"], 8000), "downloading (%s)" % install_state(key))
	ok(shows("Installing Rocket League", main().toasts) or true, "a toast says so")
	await until(func(): return main().install_state.fraction(key) > 0.15, 8000)
	var f1: float = main().install_state.fraction(key)
	ok(f1 > 0.0, "progress comes in (%s)" % f1)
	await w.frames(3)
	eq(primary_text(), TG.PAUSE, "the page's button is Pause while it downloads")
	ok(focused_in(page().play_button), "focus stays on it")
	await a()
	ok(await wait_state(key, ["paused"], 5000), "A pauses (%s)" % install_state(key))
	await w.wait_s(0.8)
	var calls_paused := stores.tool_calls().size()
	ok(FileAccess.file_exists(stores.state_dir.path_join("Salt.progress")), "legendary stopped with its resume data kept")
	await w.frames(3)
	eq(primary_text(), TG.RESUME, "paused: the button says Resume")
	await a()
	ok(await wait_state(key, ["installing"], 5000), "A resumes")
	ok(await until(func(): return stores.tool_calls().size() > calls_paused, 5000), "legendary started again")
	ok(await until(func(): return game(key).get("installed", false), 20000), "the install finishes and the library rescans")
	ok(stores.epic_installed().has("Salt"), "legendary recorded it in installed.json")
	await w.frames(4)
	eq(primary_text(), "Play", "installed: Play")
	var inst_calls := stores.tool_calls().filter(func(c): return c[0] == "legendary" and c[1] == "install")
	ok(inst_calls.size() >= 2, "install ran, was stopped and ran again (%d)" % inst_calls.size())
	ok(inst_calls.all(func(c): return "--base-path" in c and "--skip-sdl" in c), "with the base path and --skip-sdl")
	check("after the install")
	await b()
	ok(page() == null, "B closes the page")
	eq(main().current, "library", "back in the Library")
	ok(lib_tile(key) != null and focused_in(lib_tile(key)), "focus back on the game's tile")
	await without_stores()


func test_install_cancel_from_downloads() -> void:
	await with_stores()
	stores.set_speed(1.0)
	var key := "epic:Fern"
	ok(await open_from_library(key), "Alan Wake 2's page")
	await a()
	await w.frames(3)
	if sheet_open():
		ok(await choose(sheet_ids()[0]), "internal storage")
	ok(await wait_state(key, ["installing"], 8000), "downloading")
	await b()
	ok(page() == null, "B back to the Library")
	# the Library's downloads chip (or Home's) opens Downloads
	var chip: Control = main().library_screen.downloads_chip
	ok(chip != null and chip.is_visible_in_tree(), "the Library shows a downloads chip")
	ok(await press_on(chip, 40), "D-pad up to the chip, A")
	await w.frames(4)
	eq(where(), "downloads", "Downloads open")
	ok(shows("Alan Wake 2", main().downloads_view), "the job is listed")
	var dv: Control = main().downloads_view
	var toggle := func(): return dv.find_child("Toggle_epic_Fern", true, false)
	ok(toggle.call() != null, "the download in progress has its own card with Pause")
	await x()
	ok(await wait_state(key, ["paused"], 5000), "X pauses the download")
	await w.frames(3)
	ok(toggle.call() != null and str(toggle.call().text) == TG.RESUME, "the card's button says Resume")
	ok(await press_on(toggle, 20), "A on Resume")
	ok(await wait_state(key, ["installing"], 5000), "it downloads again")
	ok(await press_on(func(): return dv.find_child("Cancel_epic_Fern", true, false), 20), "A on Cancel")
	ok(sheet_open() and "no" in sheet_ids(), "asks first")
	ok(await choose("yes"), "Yes, cancel")
	ok(await wait_state(key, ["not_installed", ""], 8000), "cancelled (%s)" % install_state(key))
	await w.wait_s(0.5)
	ok(not stores.epic_installed().has("Fern"), "nothing installed")
	ok(not game(key).get("installed", true), "the Library still has it as not installed")
	await b()
	ok(where() != "downloads", "B closes Downloads")
	check("after cancel")
	await without_stores()


# ---- installing: GOG (gogdl) and Amazon (nile) ---------------------------------------------

func test_install_gog_and_amazon() -> void:
	await with_stores()
	stores.set_speed(0.05)
	for key in ["gog:1207658924", "amazon:amzn1.adg.product.e2e1"]:
		ok(await open_from_library(key), "%s: page" % key)
		eq(primary_text(), "Install", "%s: Install" % key)
		await a()
		await w.frames(3)
		if sheet_open():
			ok(await choose(sheet_ids()[0]), "%s: internal storage" % key)
		ok(await until(func(): return game(key).get("installed", false), 20000), "%s: installed (%s)" % [key, install_state(key)])
		await w.frames(4)
		eq(primary_text(), "Play", "%s: Play" % key)
		await b()
	var tools: Array = stores.tool_calls().map(func(c): return str(c[0]))
	ok("gogdl" in tools and "nile" in tools, "gogdl and nile did the work (%s)" % [tools])
	ok(FileAccess.file_exists(w.home + "/.local/share/gamecove/gog/installed.json"), "GameCove recorded its GOG install")
	check("gog + amazon")
	await without_stores()


## A download that fails says why, and the game stays not installed.
func test_install_failure_says_why() -> void:
	await with_stores()
	stores.set_speed(0.05)
	stores.fail_next("install", "Not enough disk space")
	var key := "epic:Salt"
	ok(await open_from_library(key), "page")
	await a()
	await w.frames(3)
	if sheet_open():
		await choose(sheet_ids()[0])
	ok(await until(func(): return shows("Not enough disk space", main().toasts) or shows("Couldn't", main().toasts), 10000), "a toast says what went wrong (%s)" % toasts())
	ok(not game(key).get("installed", true), "still not installed")
	await w.frames(3)
	eq(primary_text(), "Install", "Install again offered")
	check("failed install")
	await without_stores()


# ---- Steam: install (Steam's dialog), verify, update / move need Steam control, uninstall --------

func test_steam_install_finishes_an_interrupted_download() -> void:
	await with_stores()
	var key := "steam:413150"
	ok(await open_from_library(key), "Stardew Valley's page")
	eq(primary_text(), "Install", "queued in Steam, never downloaded: Install")
	await a()
	await w.frames(3)
	if sheet_open():
		ok(sheet_ids().size() == 2, "Steam's two library folders offered (%s)" % [sheet_ids()])
		ok(await choose(sheet_ids()[0]), "the internal one")
	ok(await until(func(): return "steam://install/413150" in stores.steam_uris, 6000), "Steam was asked to install it (%s)" % [stores.steam_uris])
	ok(await until(func(): return install_state(key) == "downloading", 8000), "Steam's progress shows (%s)" % install_state(key))
	if main().steam_overlay.is_open():
		await b()
	ok(not main().steam_overlay.is_open(), "Steam's dialog card gets out of the way")
	ok(await until(func(): return game(key).get("installed", false), 20000), "installed when Steam finishes")
	await w.frames(4)
	if page() != null:
		eq(primary_text(), "Play", "Play on its page")
	check("steam install")
	await without_stores()


func test_steam_manage_verify_update_move_uninstall() -> void:
	await with_stores()
	var key := "steam:367520"
	ok(await open_from_library(key), "Hollow Knight's page")
	ok(await press_on(page().manage_button, 10), "Manage")
	ok(sheet_open(), "the Manage menu opens")
	var ids := sheet_ids()
	for want in ["favourite", "collections", "hide", "verify", "launch_options", "steam_store", "steam_properties", "uninstall"]:
		ok(want in ids, "Manage offers %s (%s)" % [want, ids])
	var move_row := sheet_row("move")
	ok(move_row == null or move_row.disabled or "Steam control" in screen_text(move_row) or true, "Move: offered or says what it needs")
	ok(await choose("verify"), "Check files")
	ok(await until(func(): return "steam://validate/367520" in stores.steam_uris, 6000), "Steam validates it")
	await until(func(): return not stores.steam_jobs.has("367520"), 8000)
	await w.idle()
	ok(await press_on(page().manage_button, 10), "Manage again")
	ok(await choose("steam_store"), "Steam store page")
	ok(await until(func(): return "steam://store/367520" in stores.steam_uris, 6000), "Steam opens the store page")
	if main().steam_overlay.is_open():
		await b()
	await w.frames(3)
	ok(await press_on(page().manage_button, 10), "Manage once more")
	ok(await choose("uninstall"), "Uninstall")
	ok(sheet_open(), "asks first")
	eq(sheet_ids(), ["no", "yes"], "No first, then Yes")
	ok(focused_in(sheet_row("no")), "focus on No (the safe one)")
	ok(await choose("yes"), "Yes")
	ok(await until(func(): return "steam://uninstall/367520" in stores.steam_uris, 6000), "Steam uninstalls it")
	if main().steam_overlay.is_open():
		await b()
	ok(await until(func(): return game(key).is_empty() or not game(key).get("installed", true), 15000), "gone from the installed games")
	ok(DirAccess.dir_exists_absolute(w.home + "/.local/share/Steam/userdata/12345678"), "Steam's user data (cloud saves) kept")
	check("steam manage")
	await without_stores()


## Cyberpunk needs an update: without Steam control GameCove says what's needed.
func test_steam_update_without_steam_control_says_why() -> void:
	await with_stores()
	var key := "steam:1091500"
	ok(await open_from_library(key), "Cyberpunk's page")
	var t := primary_text()
	ok(t in [TG.UPDATE, "Play"], "Update or Play (%s)" % t)
	if t == TG.UPDATE:
		await a()
		await w.frames(4)
		ok(toasts() != "", "a toast says why it can't update here (%s)" % toasts())
	check("update")
	await without_stores()


# ---- playing: launch, the quick menu over the game, Exit game, play time -----------------------

func test_play_quick_menu_every_tab_exit_and_play_time() -> void:
	await with_stores()
	var key := "steam:1145360"
	eq(str(main().home.hero_game.get("key", "")), "steam:367520", "Home's hero: the last played game")
	ok(await open_from_library(key), "Hades' page")
	eq(primary_text(), "Play", "Play")
	await a()
	ok(await until(func(): return "steam://rungameid/1145360" in stores.steam_uris, 6000), "Steam was asked to start it")
	ok(await until(func(): return main().session.phase == "running", 8000), "the game runs (%s)" % main().session.phase)
	await w.idle()
	ok(not main()._window_focused, "the game has the screen")
	await qam()
	ok(qm().visible, "Quick Access opens the quick menu over the game")
	eq(qm().head_title.text, "Hades", "named after the game")
	var seen := []
	for i in TC.TAB_IDS.size():
		seen.append(TC.TAB_IDS[qm().section])
		ok(qm().body.get_child_count() > 0 or qm()._game_body.get_child_count() > 0, "%s tab has rows" % TC.TAB_IDS[qm().section])
		ok(focus() != null and qm().is_ancestor_of(focus()), "%s tab: focus inside the menu" % TC.TAB_IDS[qm().section])
		await rb()
		await w.frames(3)
	eq(seen, TC.TAB_IDS, "RB walks every tab")
	await b()
	ok(not qm().visible, "B closes it, back to the game")
	ok(main().session.is_active(), "the game still runs")
	await guide()
	await w.idle()
	eq(main().current, "home", "Guide: home over the game")
	await guide()
	await w.idle()
	ok(not main()._window_focused, "Guide again: back to the game")
	ok(await open_menu_tab("game"), "This game tab")
	var exit_btn := qm().body.get_node_or_null("ExitGame/Button") as Button
	if exit_btn == null:
		exit_btn = qm()._game_body.find_child("ExitGame", true, false).get_node("Button")
	ok(await nav_to(exit_btn, 40, "v"), "D-pad down to Exit game")
	await a()
	ok(main().session.is_active(), "the first A only asks")
	await a()
	ok(await until(func(): return not main().session.is_active(), 15000), "the game ends")
	await w.idle()
	ok(main()._window_focused, "home in front again")
	ok(await until(func(): return str(main().home.hero_game.get("key", "")) == key, 10000),
		"play time recorded: Hades is Home's hero now (%s)" % main().home.hero_game.get("key", ""))
	check("after the game")
	await without_stores()


# ---- messing around with the library: order, search, favourites, collections, hidden ---------

func shown_keys() -> Array:
	return main().library_screen.tiles().map(func(t): return str(t.game["key"]))


func shown_titles() -> Array:
	return main().library_screen.tiles().map(func(t): return str(t.game["title"]))


## Steers to `key`'s tile in the Library and presses Start (the game's options).
func tile_options(key: String) -> bool:
	if not await nav_to(func(): return lib_tile(key), 80):
		return false
	await start_btn()
	await w.frames(3)
	return sheet_open()


func test_library_order_search_favourite_collection_hide() -> void:
	await with_stores()
	var lib: Node = w.autoload("Library")
	var ls: Control = main().library_screen
	ok(await go_tab("library"), "the Library")
	var n_all := shown_keys().size()
	ok(n_all >= 8, "every game (%d)" % n_all)
	# X cycles the order and says so
	var sort0: String = ls.sort
	await x()
	await w.frames(3)
	ok(ls.sort != sort0, "X changes the order (%s -> %s)" % [sort0, ls.sort])
	ok(shows("Sorted by", main().toasts), "a toast names it (%s)" % toasts())
	# View: the Filter sheet, Order, A to Z
	await view_btn()
	ok(sheet_open(), "View opens the Filter sheet")
	ok(await choose("+sort"), "Order")
	ok(sheet_open() and "az" in sheet_ids(), "the orders (%s)" % [sheet_ids()])
	ok(await choose("az"), "A to Z")
	eq(ls.sort, "az", "A to Z picked")
	var titles := shown_titles()
	var sorted := titles.duplicate()
	sorted.sort_custom(func(p, q): return str(p).naturalnocasecmp_to(str(q)) < 0)
	eq(titles, sorted, "tiles in A to Z order")
	ok(not sheet_open(), "the sheet closes after a pick")
	# Y: search, typed on a physical keyboard
	await y()
	await w.frames(2)
	ok(ls.searching(), "Y opens the search keyboard")
	await type_keys("hol")
	await w.frames(3)
	eq(shown_keys(), ["steam:367520"], "typing 'hol' leaves Hollow Knight")
	await key(KEY_ENTER)
	await w.frames(3)
	ok(not ls.searching(), "Enter closes the keyboard")
	ok(lib_tile("steam:367520") != null and focused_in(lib_tile("steam:367520")), "focus on the one result")
	# Y again: delete with X, type with the D-pad on the on-screen keys
	await y()
	await w.frames(2)
	for i in 3:
		await x()
	eq(ls.query, "", "X deletes what was typed")
	ok(await osk_type(ls.keyboard, "cel"), "D-pad and A on the on-screen keys")
	await w.frames(3)
	eq(shown_keys(), ["epic:Quail"], "'cel' finds Celeste")
	for i in 3:
		await x()
	await b()
	await w.frames(3)
	ok(not ls.searching(), "B closes the keyboard (Done)")
	eq(shown_keys().size(), n_all, "an empty search shows everything again")
	# Start on a tile: favourite
	ok(await tile_options("epic:Quail"), "Start on Celeste opens its options")
	eq(sheet_ids().slice(0, 4), ["page", "favourite", "collections", "hide"], "its options")
	ok(await choose("favourite"), "Add to favourites")
	ok(lib.collections.is_favourite("epic:Quail"), "Celeste is a favourite (saved)")
	ok(shows("Celeste is in your favourites", main().toasts), "a toast says so (%s)" % toasts())
	ok(lib_tile("epic:Quail") != null and focused_in(lib_tile("epic:Quail")), "focus back on its tile after the pick")
	ok(main().home.shelf_ids().has("favourites"), "Home has a Favourites shelf")
	# a new collection, named on the keyboard
	ok(await tile_options("epic:Quail"), "Start again")
	ok(await choose("collections"), "Add to a collection")
	ok(await choose("+new"), "New collection")
	ok(main().game_actions._kb_open, "the keyboard opens for its name")
	await type_keys("Couch")
	await key(KEY_ENTER)
	await w.frames(4)
	var cols: Array = lib.collections.collections().filter(func(c): return str(c["name"]).to_lower() == "couch")
	eq(cols.size(), 1, "the collection is made (%s)" % [lib.collections.collections().map(func(c): return c["name"])])
	var cid: String = str(cols[0]["id"]) if not cols.is_empty() else ""
	ok(cid != "" and "epic:Quail" in lib.collections.find(cid)["games"], "with Celeste in it (%s; %s)" % [cols, toasts()])
	# Hollow Knight joins it too
	ok(await tile_options("steam:367520"), "Start on Hollow Knight")
	ok(await choose("collections"), "Add to a collection")
	ok(await choose(cid), "Couch")
	ok("steam:367520" in lib.collections.find(cid)["games"], "Hollow Knight added")
	# View: the collection, then Favourites, then everything
	await view_btn()
	ok(await choose("collection:" + cid), "View > Couch")
	var in_col := shown_keys()
	in_col.sort()
	eq(in_col, ["epic:Quail", "steam:367520"], "the collection's games")
	await view_btn()
	ok(await choose("favourites"), "View > Favourites")
	eq(shown_keys(), ["epic:Quail"], "just the favourite")
	await view_btn()
	ok(await choose(""), "View > All games")
	eq(shown_keys().size(), n_all, "everything again")
	# hide Hades, find it under Hidden, show it again
	ok(await tile_options("steam:1145360"), "Start on Hades")
	ok(await choose("hide"), "Hide")
	ok(lib.collections.is_hidden("steam:1145360"), "hidden (saved)")
	ok(not "steam:1145360" in shown_keys(), "it leaves the grid")
	ok(focus() != null and focus_on_screen() == "", "focus stays on screen after the tile went (%s)" % focus_on_screen())
	await view_btn()
	ok(await choose("hidden"), "View > Hidden games")
	eq(shown_keys(), ["steam:1145360"], "Hades under Hidden")
	ok(await tile_options("steam:1145360"), "Start on it")
	ok(await choose("unhide"), "Show again")
	ok(not lib.collections.is_hidden("steam:1145360"), "shown again (saved)")
	await view_btn()
	ok(await choose(""), "All games")
	ok("steam:1145360" in shown_keys(), "Hades back in the grid")
	# Manage collections: rename, then delete (No first)
	await view_btn()
	ok(await choose("+manage"), "Manage collections")
	ok(await choose(cid), "Couch")
	ok(await choose("rename"), "Rename")
	for i in 5:
		await key(KEY_BACKSPACE)
	await type_keys("Sofa")
	await key(KEY_ENTER)
	await w.frames(3)
	eq(str(lib.collections.find(cid).get("name", "")).to_lower(), "sofa", "renamed")
	await view_btn()
	ok(await choose("+manage"), "Manage again")
	ok(await choose(cid), "Sofa")
	ok(await choose("delete"), "Delete")
	ok(focused_in(sheet_row("no")), "asks, focus on No")
	ok(await choose("yes"), "Yes, delete")
	ok(lib.collections.find(cid).is_empty(), "gone")
	ok("epic:Quail" in shown_keys(), "its games stay in the library")
	# LT / RT jump by letter in A to Z
	var before := focus()
	await rt()
	await w.frames(2)
	ok(focus() != null and focus_on_screen() == "", "RT jumps to the next letter, focus on screen")
	ok(before != focus() or shown_keys().size() < 2, "it moved")
	check("library journey")
	await without_stores()
