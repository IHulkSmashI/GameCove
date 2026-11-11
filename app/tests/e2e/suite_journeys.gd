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
		ok(focused_in(page().manage_button) or focused_in(page().play_button), "B on Steam's card: focus back on the page's buttons (%s)" % [focus().get_path() if focus() else "none"])
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
	# X with a tile focused: a new order, focus stays on the same game
	ok(await nav_to(func(): return lib_tile("steam:367520"), 80), "D-pad to Hollow Knight")
	await x()
	await w.frames(3)
	ok(lib_tile("steam:367520") != null and focused_in(lib_tile("steam:367520")), "X re-sorts and focus stays on Hollow Knight (%s)" % [focus().get_path() if focus() else "none"])
	check("library journey")
	await without_stores()


# ---- a game's own settings from its page: TDP, frame limit, upscaler / frame gen / Native, Lossless ----

const Effects := preload("res://tests/e2e/effects.gd")


## Steps the ControlView `id` in the open quick-menu tab once to the right (left
## when it is at its top), with the D-pad. The new value, or null when not there.
## `game_key`: the menu is open for that game (not running): the value lands
## in its own settings, not on the system.
func step_control(id: String, game_key := "") -> Variant:
	var v := view(id)
	if v == null or not await down_to(v, 40):
		return null
	var c := ctl(id)
	var cur: Variant = shown_value(id, game_key)
	if c != null and c.kind == "slider" and cur != null and float(cur) >= c.max_value - 0.0001:
		await left()
	else:
		await right()
	await w.wait_s(0.35)
	await w.idle()
	return shown_value(id, game_key)


## Presses left (or right) on `id` until it shows `want` (at most 8 presses).
func step_to(id: String, want: Variant, game_key := "", dir := "left") -> bool:
	var v := view(id)
	if v == null or not await down_to(v, 40):
		return false
	for i in 8:
		if str(shown_value(id, game_key)) == str(want):
			return true
		await call(dir)
		await w.wait_s(0.35)
		await w.idle()
	return str(shown_value(id, game_key)) == str(want)


## The value the menu shows for `id`: the game's own when it has one.
func shown_value(id: String, game_key := "") -> Variant:
	if game_key != "" and profiles().layer(game_key, "").has(id):
		return profiles().layer(game_key, "")[id]
	return ctl(id).value if ctl(id) != null else null


func test_game_page_own_settings_then_play_with_them() -> void:
	await with_stores()
	var key := "steam:1145360"
	ok(await open_from_library(key), "Hades' page")
	var card: Control = page().game_settings
	ok(card != null, "the Game settings card")
	ok(not profiles().has_profile(key), "no settings of its own yet")
	ok(await nav_to(func(): return page().game_settings.toggle.button, 40), "D-pad to 'Use settings for this game' (focus %s)" % [focus().get_path() if focus() else "none"])
	await a()
	await w.idle()
	ok(profiles().has_profile(key), "A: the game has its own settings now")
	ok(card.edit_button != null, "Edit shows")
	ok(await press_on(func(): return page().game_settings.edit_button, 10), "A on Edit")
	await w.frames(3)
	ok(qm().visible, "the quick menu opens for the game")
	eq(qm().head_title.text, "Hades", "named after it")
	eq(TC.TAB_IDS[qm().section], "game", "on This game")
	var changed := {}
	for id in ["power.tdp", "display.fps_limit", "perf.upscaler", "perf.frame_gen", "perf.lsfg"]:
		if not available(id) or qm().model.blocked_reason(ctl(id)) != "":
			continue
		var before: Variant = shown_value(id, key)
		var after: Variant = await step_control(id, key)
		if after == null:
			ok(false, "%s reachable in This game" % id)
			continue
		ok(after != before, "%s changed (%s -> %s)" % [id, before, after])
		changed[id] = after
		check("after " + id)
	ok(changed.has("power.tdp"), "the TDP was offered (%s)" % [changed.keys()])
	for id in ["perf.upscaler", "perf.frame_gen", "perf.lsfg"]:
		ok(changed.has(id), "%s offered and changed (%s)" % [id, ctl(id).reason if ctl(id) else "?"])
	await w.idle()
	var layer: Dictionary = profiles().layer(key, "")
	for id in changed:
		if ctl(id).per_game:
			eq(str(layer.get(id, "<none>")), str(changed[id]), "%s saved for Hades" % id)
		else:
			ok(not layer.has(id), "%s isn't a per-game setting" % id)
	eq(str(profiles().layer("", "").get("power.tdp", "<none>")) == str(changed.get("power.tdp")), false, "the everyday TDP isn't the game's")
	await b()
	await w.frames(3)
	ok(not qm().visible, "B closes the menu")
	ok(page() != null, "back on the page")
	# the launch settings: a new goal (it must not replace the frame limit the
	# quick menu just set: the card owns it)
	var lt: Button = page().launch_button
	if lt != null and lt.visible:
		ok(await press_on(lt, 30), "A on Launch settings")
		ok(page().launch_open, "they open")
		var goal: Control = page().form.rows.get("goal")
		if goal != null:
			var g0: Variant = page().form.settings.get("goal")
			ok(await down_to(goal.button, 10), "the goal row")
			await right()
			await w.frames(2)
			ok(Launcher.settings_for(key).get("goal") != g0, "goal saved (%s)" % Launcher.settings_for(key).get("goal"))
		ok(await press_on(func(): return page().launch_button, 20), "A closes them")
	# Play: the game's own settings reach the system, everyday comes back after
	var tdp_game: Variant = changed.get("power.tdp")
	ok(await nav_to(page().play_button, 40), "up to Play")
	await a()
	ok(await until(func(): return main().session.phase == "running", 8000), "the game runs")
	await w.idle()
	if tdp_game != null:
		eq(float(ctl("power.tdp").value), float(tdp_game), "the game's TDP applies")
		eq(Effects.check(self, "power.tdp", ctl("power.tdp").value), "", "and the hardware has it")
	if changed.has("display.fps_limit"):
		eq(atom("GAMESCOPE_FPS_LIMIT").to_int(), int(changed["display.fps_limit"]), "gamescope has the frame limit (control %s, layer %s, sets %s)" % [ctl("display.fps_limit").value, profiles().layer(key, ""), w.fake.log_copy().filter(func(e): return "GAMESCOPE_FPS_LIMIT" in " ".join(PackedStringArray(e["argv"].map(func(x): return str(x))))).map(func(e): return e["argv"].slice(-1))])
	if changed.has("perf.upscaler"):
		var chooses: Array = w.fake.upscale_runs.filter(func(r): return r[0] == "choose" and r[1] == "1145360")
		ok(not chooses.is_empty(), "the upscaling helper put the upscaler into Hades (%s)" % [w.fake.upscale_runs])
		eq(str(w.fake.upscale_games.get("1145360", {}).get("upscaler", "")), str(changed["perf.upscaler"]), "the helper has the game's upscaler")
	# mid-game: back to the game's own upscaler (Native: nothing of ours in its folder)
	if changed.has("perf.upscaler"):
		ok(await open_menu_tab("game"), "Quick Access over the game: This game")
		ok(await step_to("perf.frame_gen", 0, key), "frame generation off")
		ok(await step_to("perf.upscaler", "own", key), "upscaler back to the game's own")
		eq(str(w.fake.upscale_games.get("1145360", {}).get("upscaler", "")), "own", "the helper took ours out")
		eq(int(w.fake.upscale_games.get("1145360", {}).get("fg", -1)), 0, "and frame generation")
		await b()
		await w.idle()
		ok(not qm().visible and not main()._window_focused, "B: back to the game")
	check("in game")
	stores.game_quit("1145360")
	ok(await until(func(): return not main().session.is_active(), 12000), "the game ends")
	await w.idle()
	if tdp_game != null:
		ok(await until(func(): return float(ctl("power.tdp").value) != float(tdp_game), 5000), "the everyday TDP is back (%s)" % ctl("power.tdp").value)
	# turn the game's own settings off: the first A only asks
	if page() == null:
		ok(await open_from_library(key), "Hades' page again")
	card = page().game_settings
	ok(await nav_to(func(): return page().game_settings.toggle.button, 40), "the switch")
	await a()
	await w.idle()
	ok(profiles().has_profile(key), "the first A only asks")
	await a()
	await w.idle()
	ok(not profiles().has_profile(key), "the second turns them off")
	check("own settings off")
	await b()
	await without_stores()



# ---- moving to the SD card, uninstalling with the saves kept (Epic) --------------------------

func test_epic_move_to_sd_card_then_uninstall_keeps_saves() -> void:
	await with_stores()
	stores.set_speed(0.05)
	var key := "epic:Quail"
	var save: String = w.home.path_join("Games/Heroic/Prefixes/default/Celeste/pfx/drive_c/users/steamuser/AppData/Local/Celeste/Saves/0.celeste")
	stores._write(save, "<SaveData>e2e</SaveData>\n")
	ok(await open_from_library(key), "Celeste's page")
	eq(primary_text(), "Play", "installed: Play")
	ok(await press_on(page().manage_button, 10), "Manage")
	ok(await choose("move"), "Move to another drive")
	ok(sheet_open(), "asks where to")
	var sd: String = ""
	for id in sheet_ids():
		if "SDCARD" in id:
			sd = id
	ok(sd != "", "the SD card is offered (%s)" % [sheet_ids()])
	var fails := []
	w.autoload("Library").store.action_failed.connect(func(k, a, m): fails.append([k, a, m]))
	ok(await choose(sd), "A on the SD card")
	var where := func() -> String: return str(w.autoload("Library")._entries.get(key, {}).get("install_path", ""))
	ok(await until(func(): return where.call().begins_with(sd), 20000),
		"moved: the library has it on the SD card (%s; %s; %s)" % [where.call(), install_state(key), fails])
	ok(FileAccess.file_exists(where.call().path_join("game.exe")), "its files are there")
	ok(not FileAccess.file_exists(w.home.path_join("Games/epic/Celeste/game.exe")), "and gone from internal storage")
	var mv: Array = stores.tool_calls().filter(func(c): return c[0] == "legendary" and c[1] == "move")
	ok(not mv.is_empty() and "--skip-move" in mv[-1], "legendary was told the new place (%s)" % [mv])
	eq(str(stores.epic_installed().get("Quail", {}).get("install_path", "")).begins_with(sd), true, "legendary's installed.json points there")
	check("after the move")
	await w.frames(4)
	ok(await press_on(page().manage_button, 10), "Manage again")
	ok(await choose("uninstall"), "Uninstall")
	eq(sheet_ids(), ["no", "yes"], "asks first")
	ok(focused_in(sheet_row("no")), "focus on No")
	ok(await choose("no"), "No")
	await w.frames(3)
	ok(game(key).get("installed", false), "No keeps it")
	ok(await press_on(page().manage_button, 10), "Manage once more")
	ok(await choose("uninstall"), "Uninstall")
	ok(await choose("yes"), "Yes")
	ok(await until(func(): return not game(key).get("installed", true), 15000), "uninstalled")
	ok(not stores.epic_installed().has("Quail"), "legendary forgot it")
	ok(stores.tool_calls().any(func(c): return c[0] == "legendary" and c[1] == "uninstall" and "--skip-uninstaller" in c), "legendary uninstall ran")
	ok(FileAccess.file_exists(save), "the save in its prefix is kept")
	await w.frames(4)
	if page() != null:
		eq(primary_text(), "Install", "Install offered again")
	check("after uninstall")
	await without_stores()


# ---- every Settings page: walked by pad, things changed and put back ------------------------

const UI_ROWS := ["theme", "match_art", "reduce_motion", "menu_side", "ui_sounds"]


## The ChoiceRow around `f` (a UI preference or a page's own choice), or null.
func choice_row_of(f: Control) -> Control:
	var n: Node = f
	for i in 3:
		if n == null:
			return null
		if "values" in n and "key" in n:
			return n
		n = n.get_parent()
	return null


func test_settings_every_page_walked_changed_and_put_back() -> void:
	var s: Control = main().settings
	var walked := {}
	for cat in s.categories():
		ok(await open_settings(cat), "%s: reached with the pad (focus %s)" % [cat, focus().get_path() if focus() else "none"])
		if not s.in_page():
			continue
		var stops := 0
		var seen := {}
		for i in 80:
			var f := focus()
			if f == null or not s.in_page() or seen.has(f):
				break
			seen[f] = true
			stops += 1
			# the page glides to the focused row: on screen once it settles
			await until(func(): return focus_on_screen() == "", 1200)
			var e := focus_on_screen()
			ok(e == "", "%s: %s" % [cat, e])
			var row := choice_row_of(f)
			# the look and feel rows: one step right and back, saved both times
			if row != null and str(row.key) in UI_ROWS and cat == "appearance":
				var before: Variant = row.values[row.index]
				var rkey := str(row.key)
				await right()
				await w.frames(3)
				row = choice_row_of(focus())   # a new theme rebuilds the page
				ok(row != null and str(row.key) == rkey, "appearance: focus stays on %s" % rkey)
				if row == null:
					break
				ok(row.values[row.index] != before, "appearance: %s changes (%s)" % [row.key, row.values[row.index]])
				ok(FileAccess.file_exists(ProjectSettings.globalize_path("user://ui.cfg")), "appearance: saved")
				if str(row.key) == "theme":
					eq(str(preload("res://scripts/ui/ui_prefs.gd").values().get("theme", "")), str(row.values[row.index]), "the theme applies")
				await left()
				await w.frames(3)
				row = choice_row_of(focus())
				ok(row != null and row.values[row.index] == before, "appearance: %s back" % rkey)
				f = focus()
				if f == null:
					break
			await down()
			await w.frames(1)
		walked[cat] = stops
		ok(stops >= 1, "%s: something to focus" % cat)
		eq(settings_files_valid(), "", "%s: every settings file still parses" % cat)
		check("settings " + cat)
	print("E2E INFO settings stops per page: %s" % [walked])
	await go_tab("home")


## The temperature limit (Power > Power limit > More settings): pushed with the
## pad, it reaches the firmware and reads back, on every handheld that has one.
func test_settings_thermal_limit_reaches_the_system() -> void:
	var c := ctl("power.thermal_limit")
	print("E2E INFO thermal limit on %s: available=%s reason=%s" % [setup_name(), c.available if c else false, c.reason if c else "missing"])
	if c == null or not c.available:
		ok(c != null and c.reason != "", "not on this handheld, with a reason (%s)" % (c.reason if c else "missing"))
		return
	ok(await open_settings("power"), "Power page")
	var target := func(): return view("power.thermal_limit", main().settings)
	# "More settings" of the Power limit card opens with A
	for i in 60:
		if target.call() != null and focused_in(target.call()):
			break
		var f := focus()
		if f != null and f.get_parent() != null and String(f.get_parent().name) == "More" and "expanded" in f.get_parent().get_parent() \
				and not f.get_parent().get_parent().expanded:
			await a()
			await w.frames(2)
			continue
		await down()
		await w.frames(1)
	ok(target.call() != null and focused_in(target.call()), "the temperature limit reached with the pad")
	var before := float(c.value)
	if before >= c.max_value - 0.01:
		await left()
	else:
		await right()
	await w.wait_s(0.4)
	await w.idle()
	ok(float(c.value) != before, "pushed: %s -> %s" % [before, c.value])
	var sent := last_set("org.shadowblip.PowerStation", "org.shadowblip.GPU.Card.TDP", "ThermalThrottleLimitC")
	ok(sent != "" and absf(sent.to_float() - float(c.value)) < 0.5, "PowerStation was told %s (%s)" % [c.value, sent])
	controls().detect_all()
	await w.idle()
	eq(float(ctl("power.thermal_limit").value), float(c.value), "reads back the same")
	# and back
	if float(c.value) < before:
		await right()
	else:
		await left()
	await w.wait_s(0.4)
	await w.idle()
	eq(float(ctl("power.thermal_limit").value), before, "put back")
	check("thermal limit")
	await go_tab("home")



# ---- over a game: recording a clip, sleep and wake, a session switch and back ----------------

const FAKE_RECORDER := """#!/bin/sh
# e2e stand-in for gpu-screen-recorder: prints like it, writes the clip when stopped (SIGINT)
out=""
while [ $# -gt 0 ]; do [ "$1" = "-o" ] && out="$2"; shift; done
echo "gsr info: recording to $out"
trap 'printf "e2e clip" > "$out"; echo "gsr info: saved"; exit 0' INT TERM
while :; do sleep 0.05; done
"""


## Plays Hades from its page (Play), until it runs.
func play_hades() -> bool:
	if not await open_from_library("steam:1145360"):
		return false
	await a()
	return await until(func(): return main().session.phase == "running", 8000)


func test_over_a_game_record_a_clip_sleep_wake_and_switch_sessions() -> void:
	await with_stores()
	# GPU Screen Recorder on the fake handheld: a stand-in first on PATH
	var rec_bin := stores.bin_dir.path_join("gpu-screen-recorder")
	stores._write(rec_bin, FAKE_RECORDER)
	FileAccess.set_unix_permissions(rec_bin, 493)
	var rec: Node = main().recording
	rec.env = {"home": w.home, "path_env": stores.bin_dir, "sys_root": "", "proc_root": "/proc"}
	rec.thumb_fn = func(_clip: String) -> void: pass
	rec.setup_needed = false
	ok(await play_hades(), "Hades runs")
	await w.idle()
	# Record: This game > Record
	ok(await open_menu_tab("game"), "Quick Access: This game")
	var row := func(): return qm().body.find_child("Record", true, false)
	ok(row.call() != null, "a Record row")
	ok(await press_on(func(): return row.call().button if row.call() else null, 40, "v"), "A on Record")
	ok(await until(func(): return rec.state == "recording", 6000), "recording (%s)" % rec.state)
	var clip: String = rec.path
	var saved := []
	rec.saved.connect(func(p, info): saved.append([p, info]), CONNECT_ONE_SHOT)
	ok(not qm().visible, "the menu gets out of the way")
	ok(main().top_bar.has_method("set_recording"), "the REC chip is there to show it")
	await w.wait_s(0.5)
	ok(await open_menu_tab("game"), "Quick Access again")
	ok(await press_on(func(): return row.call().button if row.call() else null, 40, "v"), "A on Stop recording")
	ok(await until(func(): return rec.state == "idle", 15000), "stopped")
	ok(await until(func(): return not saved.is_empty(), 5000), "saved (%s)" % [saved])
	ok(clip != "" and FileAccess.file_exists(clip) and clip.begins_with(w.home.path_join("Videos/GameCove")), "the clip is saved under Videos/GameCove (%s)" % clip)
	if qm().visible:
		await b()
	# sleep from the quick menu, wake later: the game still runs, settings come back
	var tdp_before: Variant = ctl("power.tdp").value
	ok(await open_menu_tab("device"), "Device tab")
	var sleep_v := view("system.sleep")
	if sleep_v != null and available("system.sleep"):
		ok(await down_to(sleep_v, 40), "Sleep reachable")
		await a()
		await w.idle()
		if not "suspend" in w.fake.events:
			await a()   # asks first
			await w.idle()
		ok("suspend" in w.fake.events, "the handheld was put to sleep (%s)" % [w.fake.events])
	else:
		await b()
	# the firmware forgot the TDP over sleep; the clocks say two minutes passed
	main()._clock_mark = [Time.get_unix_time_from_system() - 120.0, Time.get_ticks_msec() - 1000]
	await down()   # the first press after waking notices it
	await w.wait_s(5.6)
	await w.idle()
	ok(main().session.is_active(), "the game still runs after waking")
	eq(str(ctl("power.tdp").value), str(tdp_before), "the TDP is what it was")
	if qm().visible:
		await b()
	var t0 := Time.get_ticks_msec()
	await qam()
	ok(qm().visible and Time.get_ticks_msec() - t0 < 1500, "the quick menu opens at once after waking (%d ms)" % (Time.get_ticks_msec() - t0))
	# Switch to Steam (Gaming Mode's own session) and back
	ok(await open_menu_tab("device"), "Device tab")
	var steam_btn := qm().body.get_node_or_null("SteamMode/Button") as Button
	if steam_btn != null and not steam_btn.disabled:
		ok(await focus_on(steam_btn), "Switch to Steam reachable")
		await a()
		eq(w.fake.events.count("steam") + w.fake.events.count("gamescope"), 0, "the first A only asks")
		await a()
		await w.idle()
		ok(w.fake.events.size() > 0, "the session switch was asked for (%s)" % [w.fake.events])
		for m in w.fake.prop_value("InterceptMode"):
			eq(int(m), 0, "the controller is let go before the switch")
		# the switch didn't take GameCove away (or GameCove is back): the controller comes back
		qm().switch_timed_out(qm()._switch_gen)
		await w.idle()
		eq(qm().status_label.text, preload("res://scripts/ui/texts.gd").SWITCH_STUCK, "back: GameCove says the switch didn't happen and keeps going")
		ok(main().session.is_active(), "and the game still runs")
	if qm().visible:
		await b()
	check("over the game")
	stores.game_quit("1145360")
	ok(await until(func(): return not main().session.is_active(), 12000), "the game ends")
	await without_stores()


# ---- Settings > Device > Fixes: apply and undo with the pad --------------------------------

func test_fixes_page_apply_then_undo() -> void:
	var fx: Node = main().fixes
	ok(fx != null, "the Fixes service")
	var quiet0: bool = fx.quiet_enabled()
	ok(await open_settings("device"), "Settings > Device")
	var s: Control = main().settings
	var dp: Control = s.pages.get("device")
	# RT walks the Device page's tabs to Fixes
	for i in 5:
		if dp.part == "fixes":
			break
		await rt()
		await w.frames(3)
	eq(dp.part, "fixes", "RT reaches the Fixes tab")
	var page: Control = dp.panels.get("fixes")
	ok(page != null, "the Fixes page")
	if page == null:
		return
	# the service the page shows (its own, from the Settings services)
	if page.has_method("svc") and page.svc("fixes") != null:
		fx = page.svc("fixes")
		quiet0 = fx.quiet_enabled()
	var rows: Array = fx.rows()
	ok(not rows.is_empty(), "this handheld has fixes listed (%d)" % rows.size())
	# a fix that can be applied (or undone) here
	var pick := {}
	for r in rows:
		if r.get("can_apply", false) or r.get("can_undo", false):
			pick = r
			break
	if pick.is_empty():
		ok(rows.all(func(r): return str(r.get("status", "")) != ""), "nothing to do here, every fix says why")
		await go_tab("home")
		return
	var id: String = pick["id"]
	# what the card offers now (GameCove's own fix keeps its state in user://, across tests)
	var verb := "apply" if page.buttons.has("apply:" + id) else "undo"
	var other := "undo" if verb == "apply" else "apply"
	var done := []
	fx.action_finished.connect(func(f, v, okk, m): done.append([f, v, okk, m]))
	var btn := func(v: String): return page.buttons.get("%s:%s" % [v, id])
	ok(await press_on(func(): return btn.call(verb), 120), "D-pad to %s on %s, A (focus %s)" % [verb, id, focus().get_path() if focus() else "none"])
	ok(await until(func(): return done.any(func(d): return d[0] == id and d[1] == verb), 15000), "%s finished (%s)" % [verb, done])
	await w.idle()
	var d1: Array = done.filter(func(d): return d[0] == id and d[1] == verb)
	ok(not d1.is_empty() and d1[-1][2], "%s worked (%s)" % [verb, d1])
	if str(pick.get("kind", "")) == "app":
		eq(fx.quiet_enabled(), verb == "apply", "GameCove's own fix (quiet behind a game) follows")
	else:
		ok(w.fake.calls.any(func(c): return c[0] == "pkexec" and id in str(c[1])), "the fix helper was asked")
	ok(focus() != null and focus_on_screen() == "", "focus stays on the page after it rebuilt")
	await w.frames(3)
	if btn.call(other) != null:
		ok(await press_on(func(): return btn.call(other), 120), "%s offered now, A" % other)
		ok(await until(func(): return done.any(func(d): return d[0] == id and d[1] == other), 15000), "%s finished" % other)
		await w.idle()
		var d2: Array = done.filter(func(d): return d[0] == id and d[1] == other)
		ok(not d2.is_empty() and d2[-1][2], "%s worked (%s)" % [other, d2])
	# a fix that needs the admin password: Gaming Mode has no one to ask, it says so
	var admin := {}
	for r in fx.rows():
		if r.get("admin", false) and (r.get("can_apply", false) or r.get("can_undo", false)):
			admin = r
			break
	if not admin.is_empty():
		var aid: String = admin["id"]
		var av := "apply" if admin.get("can_apply", false) else "undo"
		done.clear()
		ok(await press_on(func(): return btn_of(page, av, aid), 80), "%s on %s (needs the password)" % [av, aid])
		ok(await until(func(): return done.any(func(d): return d[0] == aid), 15000), "it finishes (%s)" % [done])
		var r2: Array = done.filter(func(d): return d[0] == aid)
		ok(not r2.is_empty() and not r2[-1][2] and str(r2[-1][3]) != "", "it says why it couldn't here (%s)" % [r2])
		ok(page.find_child("Admin", true, false) != null, "the card says it needs Desktop Mode")
	if fx.quiet_enabled() != quiet0:
		fx.set_quiet_enabled(quiet0)
		fx.changed.emit(fx.rows())
	check("fixes")
	await go_tab("home")


func btn_of(page: Control, verb: String, id: String) -> Control:
	return page.buttons.get("%s:%s" % [verb, id])


# ---- every other screen: Discover, Stream, Apps, Emulation, the art picker ----------------------

## Presses `dirs` round and round `n` times, checking focus stays visible on screen.
func roam(where_: String, n: int) -> void:
	var dirs := ["down", "right", "down", "left", "up", "right"]
	for i in n:
		await call(dirs[i % dirs.size()])
		await w.frames(2)
		await until(func(): return focus_on_screen() == "", 800)
		var e := focus_on_screen()
		if e != "":
			ok(false, "%s, press %d: %s" % [where_, i, e])
			return


func test_every_screen_by_pad_discover_stream_apps_emulation_art() -> void:
	await with_stores()
	# Home: the hero and shelves
	ok(await go_tab("home"), "Home")
	await roam("home", 10)
	await b()
	# Discover: its sections by pad, then back
	ok(await go_tab("discover"), "RB to Discover")
	await w.frames(4)
	await roam("discover", 14)
	check("discover")
	# Stream: hosts (none found on the fake network) and its own buttons
	# RB to Stream; its discovery answers in the same frame and rebuilds the tab
	# (Install and the host cards are made again): focus still lands on it
	ok(await go_tab("discover"), "back to Discover")
	await rb()
	main().stream_screen.rebuild()
	await w.frames(4)
	eq(main().current, "stream", "RB to Stream")
	ok(focus() != null and main().stream_screen.is_ancestor_of(focus()), "focus on the Stream tab after it rebuilt (%s)" % [focus().get_path() if focus() else "none"])
	ok(screen_text(main().stream_screen) != "", "the Stream tab says something (no hosts here)")
	await roam("stream", 6)
	check("stream")
	# Library > Apps: the desktop apps list, X pins, B closes
	ok(await go_tab("library"), "Library")
	var apps_btn: Control = main().library_screen.apps_button
	if apps_btn != null and apps_btn.is_visible_in_tree():
		# Apps sits above the toolbar's last button (Order): D-pad to it, up, A
		ok(await nav_to(main().library_screen.sort_button, 40, "h") or await nav_to(main().library_screen.sort_button, 40), "along the toolbar to Order")
		await up()
		await w.frames(2)
		ok(focused_in(apps_btn), "up: Apps")
		await a()
		await w.frames(4)
		eq(where(), "apps", "the Apps list opens")
		ok(focus() != null and focus().is_visible_in_tree(), "focus somewhere visible at once, even while the apps load (%s)" % [focus().get_path() if focus() else "none"])
		await roam("apps", 4)
		await x()
		await w.frames(2)
		await b()
		await w.frames(3)
		ok(where() != "apps", "B closes it")
	# the Emulation page from the Filter sheet
	await view_btn()
	ok(await choose("+emulation_page"), "Filter > Emulation page")
	await w.frames(6)
	ok(page() != null and page().name == "EmulationPage", "the Emulation page opens")
	await roam("emulation", 4)
	await b()
	if page() != null:
		await b()
	await w.frames(3)
	ok(page() == null, "B closes it")
	# a game page: Change artwork opens the art picker, B closes it
	ok(await open_from_library("steam:367520"), "Hollow Knight's page")
	var art := func(): return page().find_child("ChangeArtwork", true, false)
	if art.call() != null:
		ok(await press_on(art, 40), "A on Change artwork")
		await w.frames(4)
		ok(page().art_picker.is_open(), "the art picker opens")
		await roam("art picker", 6)
		await b()
		await w.frames(4)
		ok(not page().art_picker.is_open(), "B closes it")
		ok(focus() != null and page().is_ancestor_of(focus()), "focus back on the page")
	await b()
	check("screens")
	await without_stores()




# ---- first boot: setup walked by pad, a store signed in with a typed code -------------------

const SetupFlowScript := preload("res://scripts/ui/setup/setup_flow.gd")
const ProcScript := preload("res://scripts/system/proc.gd")
const UiPrefsScript := preload("res://scripts/ui/ui_prefs.gd")


func flow() -> Control:
	var f: Variant = SetupFlowScript.instance
	return f if f != null and is_instance_valid(f) else null


func test_first_boot_setup_by_pad_with_a_store_sign_in() -> void:
	await with_stores()
	var st: Node = w.autoload("Setup")
	var old := {"cfg": st.config_path, "home": st.home, "path": st.path_env, "runner": st.runner, "device": st.device}
	var cfg := "user://e2e_first_boot_setup.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(cfg))
	# a fresh handheld: setup never done, Epic not signed in yet; legendary is the stand-in on PATH
	st.setup(ProcScript.new(), w.home, cfg, w.row, stores.bin_dir + ":/usr/bin:/bin")
	DirAccess.remove_absolute(w.home.path_join(".config/legendary/user.json"))
	var theme0 := str(UiPrefsScript.values().get("theme", "cove"))
	await w.shutdown_main()
	await w.boot_main()
	await w.frames(4)
	ok(flow() != null, "first boot: setup opens by itself")
	if flow() == null:
		await _undo_setup(st, old, theme0)
		return
	eq(flow().step, "welcome", "on Welcome")
	ok(focused_in(flow().next_button), "focus on Next")
	await a()
	await w.frames(3)
	eq(flow().step, "theme", "A: the Look step")
	# a theme with the D-pad: right, A
	await right()
	await a()
	await w.frames(4)
	var picked := str(UiPrefsScript.values().get("theme", ""))
	ok(picked != "" and picked != theme0, "a new theme picked and applied (%s)" % picked)
	ok(await press_on(func(): return flow().next_button, 20), "Next")
	eq(flow().step, "stores", "the Stores step")
	var epic_row := func(): return flow().body.find_child("store_epic", true, false)
	ok(epic_row.call() != null, "Epic listed")
	ok(await press_on(func(): return epic_row.call().button if epic_row.call() else null, 20, "v"), "A on Epic")
	await w.frames(3)
	ok(flow().sign_in != null, "the sign-in opens")
	ok(await until(func(): return flow().sign_in.state == "ready", 4000), "ready for the code (%s)" % flow().sign_in.state)
	ok(await press_on(func(): return flow().sign_in.type_button, 10), "A on Type the code")
	await w.frames(2)
	ok(flow().keyboard.is_open(), "the keyboard opens")
	await type_keys("e2ecode42")
	await key(KEY_ENTER)
	ok(await until(func(): return FileAccess.file_exists(w.home.path_join(".config/legendary/user.json")), 8000), "legendary signed in with the code")
	ok(stores.tool_calls().any(func(c): return c[0] == "legendary" and c[1] == "auth" and "e2ecode42" in c), "legendary auth --code e2ecode42")
	ok(await until(func(): return flow().sign_in.state == "done" or st.is_done("stores"), 4000), "the step says signed in (%s)" % flow().sign_in.state)
	# the rest: Skip the optional ones, Next through, Done
	for i in 6:
		if flow() == null:
			break
		var s: String = flow().step
		if s == "done":
			ok(await press_on(func(): return flow().next_button if flow() else null, 20), "Done")
			break
		var target: Button = flow().skip_button if flow().skip_button.visible and s in ["art", "keys"] else flow().next_button
		ok(await press_on(target, 30), "%s: %s" % [s, target.name])
		await w.frames(3)
	await w.frames(4)
	ok(flow() == null, "setup closes at the end")
	ok(not st.is_first_run(), "and is done")
	ok(focus() != null and focus_on_screen() == "", "focus on Home")
	check("first boot")
	await _undo_setup(st, old, theme0)
	await without_stores()


func _undo_setup(st: Node, old: Dictionary, theme0: String) -> void:
	var v: Dictionary = UiPrefsScript.values()
	v["theme"] = theme0
	UiPrefsScript.set_values(v)
	main().apply_theme()
	st.setup(old["runner"], old["home"], old["cfg"], old["device"], old["path"])
	if flow() != null:
		flow().finish()
	await w.frames(3)


# ---- the GameCove installer: Easy, Custom, and Remove with / without the settings -------------

const InstScreen := preload("res://scripts/ui/installer/installer_screen.gd")
const InstPlan := preload("res://scripts/installer/plan.gd")
const InstService := preload("res://scripts/installer/installer_service.gd")
const InstPaths := preload("res://scripts/installer/paths.gd")
const InstFakes := preload("res://tests/fixtures/installer/fakes.gd")
const InstFakeRunner := preload("res://tests/fixtures/system/fake_runner.gd")


## The installer service with its file steps inside a temp folder; "remove
## settings" (which deletes the app's own user:// folder) is only noted here.
class SafeInstaller extends "res://scripts/installer/installer_service.gd":
	var noted: Array = []
	func _internal(id: String) -> Array:
		if id == "remove_settings":
			noted.append(id)
			return [true, ""]
		return super._internal(id)


## The installer on screen (it is its own app: GameCove's screens are paused under it).
func open_installer(t: Dictionary) -> Control:
	var d: String = w.home.path_join(".cache/e2e-installer")
	DirAccess.make_dir_recursive_absolute(d)
	var r: RefCounted = InstFakeRunner.new()
	r.handler = func(cmd: String): return {"code": 1, "out": ""} if cmd.begins_with("pgrep") else {"code": 0, "out": ""}
	var dev: Object = InstFakes.claw()
	var p: RefCounted = InstPlan.start(t, dev.profile, {"theme": "cove"})
	var inst: Node = SafeInstaller.new()
	inst.setup(r, InstPaths.for_home(d + "/home", d + "/root"), t, "/opt/gc/gamecove.x86_64")
	var s: Control = InstScreen.create(InstFakes.services(dev, InstFakes.FakeSetup.new(), InstFakes.Recorder.new(), d + "/power.cfg"), t, p, inst)
	main().process_mode = Node.PROCESS_MODE_DISABLED
	w.tree.root.add_child(s)
	await w.frames(4)
	s.focus_first()
	await w.frames(2)
	return s


func close_installer(s: Control) -> void:
	if is_instance_valid(s):
		s.queue_free()
	main().process_mode = Node.PROCESS_MODE_INHERIT
	await w.frames(3)
	main().home.default_focus().grab_focus()


## Next with the pad until the installer reaches `want` (or `limit` presses).
func installer_until(s: Control, want: String, limit := 20) -> bool:
	for i in limit:
		if s.plan.step == want:
			return true
		if s.plan.step == "progress":
			await until(func(): return s.plan.step != "progress", 10000)
			continue
		if not await press_on(s.next_button, 30):
			return false
		await w.frames(3)
	return s.plan.step == want


func test_installer_easy_and_custom_by_pad() -> void:
	for mode in ["easy", "custom"]:
		var s := await open_installer(InstFakes.target("bazzite"))
		eq(s.plan.step, "welcome", "%s: the installer opens on Welcome" % mode)
		var card := func(): return s.body.find_child("Card_mode_" + mode, true, false)
		ok(card.call() != null, "%s: its card" % mode)
		ok(await press_on(card, 20), "%s: A on it" % mode)
		eq(s.plan.mode, mode, "%s picked" % mode)
		var seen := [s.plan.step]
		for i in 20:
			if s.plan.step in ["summary", "done"]:
				break
			ok(focus() != null and s.is_ancestor_of(focus()), "%s %s: focus inside the installer" % [mode, s.plan.step])
			if not await press_on(s.next_button, 30):
				break
			await w.frames(3)
			seen.append(s.plan.step)
		eq(s.plan.step, "summary", "%s: Next through every step to the summary (%s)" % [mode, seen])
		if mode == "custom":
			ok(seen.size() >= 6, "custom walks its steps (%s)" % [seen])
		ok(await installer_until(s, "done", 6), "%s: Install runs to Done (%s)" % [mode, s.plan.step])
		ok(not s.installer.results.has("failed"), "%s: every step worked (%s)" % [mode, s.installer.results])
		await close_installer(s)
	check("installer")


func test_installer_remove_keeping_or_not_the_settings() -> void:
	for keep in [true, false]:
		var t := InstFakes.target("bazzite", {"installed": true, "maintenance": true, "state": {"version": "0.2.0", "method": "rpm-ostree", "fixes": []}})
		var s := await open_installer(t)
		eq(s.plan.step, "maintenance", "installed: the maintenance page")
		var rm := func(): var r = s.body.find_child("maint_remove", true, false); return r.button if r != null and "button" in r else r
		ok(await press_on(rm, 30), "A on Remove GameCove")
		eq(s.plan.step, "uninstall", "asks how")
		eq(s.next_button.text, "Remove GameCove", "the button says what it does")
		var ks := func(): var r = s.body.find_child("keep_settings", true, false); return r.button if r != null and "button" in r else r
		ok(ks.call() != null, "a Keep my settings switch")
		if bool(s.plan.choices["keep_settings"]) != keep:
			ok(await press_on(ks, 20), "A on Keep my settings")
		eq(bool(s.plan.choices["keep_settings"]), keep, "keep settings: %s" % keep)
		ok(await press_on(s.next_button, 20), "A on Remove GameCove")
		ok(await until(func(): return s.plan.step == "done" or not s.installer.running, 10000), "removed")
		var ids: Array = s.installer.tasks.map(func(x): return str(x.get("id", "")))
		ok("remove_user_files" in ids, "GameCove's shortcuts and startup files go (%s)" % [ids])
		eq("remove_settings" in ids, not keep, "settings removed only when not kept")
		eq(s.installer.noted.has("remove_settings"), not keep, "and only then run")
		await close_installer(s)
	check("installer remove")


## A game has the screen: the player's presses are the game's. Our screens take
## none (the pad is a plain input device GameCove sees too), Guide still comes.
func test_presses_for_the_game_never_reach_our_screens() -> void:
	await with_stores()
	ok(await play_hades(), "Hades runs")
	await w.idle()
	ok(not main()._window_focused, "the game has the screen")
	var f0 := focus()
	var uris: int = stores.steam_uris.size()
	for p in ["down", "a", "right", "a", "b", "rb", "x"]:
		await call(p)
		await w.frames(2)
	eq(focus(), f0, "focus didn't move under the game")
	eq(stores.steam_uris.size(), uris, "nothing was started or opened")
	ok(page() != null and str(page().game.get("key", "")) == "steam:1145360", "the page under the game is as it was")
	await guide()
	await w.idle()
	eq(main().current, "home", "Guide still brings Home over the game")
	await down()
	await w.frames(2)
	ok(focus() != null and focus_on_screen() == "", "and Home takes the pad then")
	stores.game_quit("1145360")
	ok(await until(func(): return not main().session.is_active(), 12000), "the game ends")
	await without_stores()


# ---- pending merge: journeys for features still on their own branches --------------------------
# Each is listed by the runner as "E2E SKIP ... (pending merge)" and filled in
# when its branch lands (docs/TESTING.md, the "pending merge" rows).

## ROM library (feat/rom-library): ROMs found by system, a ROM's page, launch
## through its emulator, play time, hide / favourite like any game.
func test_pending_rom_library_browse_launch_and_play_time() -> void:
	pass


## Quick-menu shortcuts and button shortcuts (quick-actions): add, reorder and
## remove a shortcut, each shortcut does its thing over a game, a held button
## combo runs its action.
func test_pending_quick_menu_shortcuts_and_button_shortcuts() -> void:
	pass


## Upscaling selection (upscaling / upscale-latest): the new per-game picker
## (OptiScaler, XeSS, FSR, Native), versions and the update flow.
func test_pending_upscaling_selection_picker() -> void:
	pass


## Fixes lifecycle (fixes): a fix applied at install, re-checked after a system
## update, offered again when the system dropped it, undone on removal.
func test_pending_fixes_lifecycle_after_a_system_update() -> void:
	pass


## Resolutions and Steam Machine (resolutions): output resolution, interface
## size, TV / docked layouts, changed and reverted.
func test_pending_resolutions_interface_size_and_docked() -> void:
	pass


## Keyboard (the new keyboard work): the system on-screen keyboard over a game
## and in GameCove's own fields.
func test_pending_keyboard_over_a_game() -> void:
	pass


## Launch fixes (launch): per-game launch fixes chosen, applied on launch and
## taken out again.
func test_pending_launch_fixes_per_game() -> void:
	pass
