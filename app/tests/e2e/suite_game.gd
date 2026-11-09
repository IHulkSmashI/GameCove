extends "res://tests/e2e/e2e_case.gd"
## The quick menu over a running game: it opens as gamescope's overlay with the
## game's name, closes with B, Guide goes home and back to the game (gamescope's
## base layer), values set in the menu stay when it's opened again, and Exit
## game ends the game (GameCloser's TERM) and brings home back.

const Checks := preload("res://tests/e2e/checks.gd")


func _overlay_calls(v: int) -> int:
	var n := 0
	for argv in calls_with(["xprop", "-id"]):
		var s := " ".join(PackedStringArray(argv.map(func(x): return str(x))))
		if "STEAM_OVERLAY" in s and s.ends_with(" %d" % v):
			n += 1
	return n


func _base() -> Array:
	return Array(atom("GAMESCOPECTRL_BASELAYER_APPID").split(",", false)).map(func(x): return str(x).strip_edges().to_int())


func test_menu_over_a_game_opens_and_closes() -> void:
	await start_game(GAME_A)
	ok(int(GAME_A["id"]) in _base(), "the game has gamescope's base layer")
	await qam()
	ok(qm().visible, "the menu opens over the game")
	eq(qm().section, 0, "on This game")
	eq(qm().head_title.text, GAME_A["title"], "named after the game")
	await w.idle()
	ok(_overlay_calls(1) >= 1, "our window marked as gamescope's overlay")
	ok(qm().body.get_node_or_null("ExitGame") != null, "Exit game offered")
	await b()
	await w.idle()
	ok(not qm().visible, "B closes it")
	ok(_overlay_calls(0) >= 1, "overlay off again: the game gets the pad back")
	ok(w.main.session.is_active(), "the game still runs")


func test_guide_goes_home_and_back_to_the_game() -> void:
	await start_game(GAME_A)
	await w.idle()
	ok(not w.main._window_focused, "the game in front: our window lost focus")
	await guide()
	await w.idle()
	eq(_base(), [413091, 769], "Guide: home in front")
	eq(w.main.current, "home", "on Home")
	ok(w.main.session.is_active(), "the game keeps running")
	await guide()
	await w.idle()
	ok(int(GAME_A["id"]) in _base() and _base()[1] == int(GAME_A["id"]), "Guide again: back to the game")
	await guide()
	await w.idle()
	eq(_base(), [413091, 769], "and home once more")


func test_values_stay_when_the_menu_opens_again() -> void:
	await start_game(GAME_A)
	ok(await open_menu_tab("display"), "Display tab")
	var v := view("display.brightness")
	ok(v != null and await focus_on(v), "brightness row")
	await right()
	await right()
	await w.wait_s(0.4)
	await w.idle()
	var set_to: Variant = ctl("display.brightness").value
	await b()
	ok(await open_menu_tab("display"), "Display tab again")
	var v2 := view("display.brightness")
	eq(qm().model.value("display.brightness"), set_to, "the menu shows what was set")
	ok(v2 != null and v2.row != null and str(v2.row.value_text()).begins_with(str(int(set_to))), "and the row reads %s (%s)" % [set_to, v2.row.value_text() if v2 != null and v2.row != null else "?"])
	await b()


func test_exit_game_from_the_menu() -> void:
	await start_game(GAME_A)
	ok(await open_menu_tab("game"), "This game")
	var btn := qm().body.get_node("ExitGame/Button") as Button
	ok(await focus_on(btn), "Exit game reachable with the pad")
	await a()
	ok(w.main.session.is_active(), "first A only asks")
	await a()
	await until(func(): return not w.main.session.is_active(), 15000)
	await w.idle()
	ok(not w.main.session.is_active(), "the game ended")
	ok(not calls_with(["sh", "-c"]).is_empty() or w.fake.spawned.values().any(func(x): return "TERM" in x), "GameCloser sent TERM")
	eq(_base(), [413091, 769], "home in front")
	ok(not qm().visible, "menu closed")
	for p in Checks.now(w):
		ok(false, "after exit: " + p)
