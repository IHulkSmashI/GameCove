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


# ---- the launch splash (final review: High 3, High 4, input under the splash) ----

## Play as main._play() does it up to the launch itself: the splash over the
## screen it was pressed on, that screen stepped back, the session following
## Steam's launch (its reaper runs; no window yet).
func _press_play(g: Dictionary) -> void:
	var m: Control = w.main
	m.playing = g
	m.launch_overlay.show_for(g, Color.CYAN, {"node": m.home.frame})
	m._launch_recede()
	m._pause_motion()
	w.fake_apps[int(g["id"])] = true
	m.session.begin(g, {"ok": true, "app_id": int(g["id"]), "pid": 0})
	await w.wait_s(0.3)


func _closes(sig: String, app: String) -> int:
	return calls_with(["sh", "-c", "*", "gamecove-close", sig, "steam", app]).size()


## High 3: B on the splash really stops the game, and nothing treats it as ended
## before it is.
func test_cancel_on_the_splash_closes_the_game() -> void:
	var m: Control = w.main
	var ended := []
	var on_end := func(g: Dictionary) -> void: ended.append(g.get("key", ""))
	m.session.ended.connect(on_end)
	await _press_play(GAME_A)
	ok(m.launch_overlay.is_open() and m.session.is_active(), "starting")
	await b()
	ok(not m.launch_overlay.is_open(), "B: the splash goes back")
	ok(m.session.is_active(), "still followed: it isn't gone yet")
	eq(ended, [], "no `ended` on B: no save upload, no Profiles restore while it's still starting")
	ok(await until(func(): return _closes("TERM", str(GAME_A["id"])) == 1, 3000), "and the game is told to close (GameCloser, like Exit game)")
	ok(m.session.is_active(), "closing isn't ended either")
	eq(m.playing.get("key", ""), GAME_A["key"], "the UI still says it runs (Exit game stays available)")
	# Play again meanwhile: no second copy, the first stays followed
	m._play(GAME_A)
	m._play(GAME_B)
	await w.frames(2)
	ok(not m.launch_overlay.is_open(), "Play while it closes starts nothing")
	eq(m.session.game.get("key", ""), GAME_A["key"], "the session still follows the first game")
	ok(await until(func(): return not m.session.is_active(), 20000), "it ends once Steam's launch is gone")
	eq(ended, [GAME_A["key"]], "ended once, through the session's own check")
	ok(m.playing.is_empty(), "nothing running any more")
	await w.idle()
	eq(m.home.modulate.a, 1.0, "Home shown")
	eq(m._screen_layer.modulate.a, 1.0, "and not faded out and in again: it never left")
	m.session.ended.disconnect(on_end)
	for p in Checks.now(w):
		ok(false, "after a cancelled launch: " + p)


## High 3: Steam hadn't started the game yet when B was pressed; it shows up
## later, never gets the screen, and is closed again.
func test_cancelled_launch_that_shows_up_late_is_closed_again() -> void:
	var m: Control = w.main
	await _press_play(GAME_B)
	var app := int(GAME_B["id"])
	w.fake_apps.erase(app)   # Steam hasn't started its reaper yet
	await b()
	await w.wait_s(1.0)
	eq(_closes("TERM", str(app)), 0, "nothing of it to close yet")
	ok(m.session.is_active(), "and no reaper yet isn't 'ended'")
	# Steam gets to it now: the window appears
	w.fake_apps[app] = true
	_set_focusable(app, true)
	ok(await until(func(): return _closes("TERM", str(app)) >= 1, 8000), "there it is: closed")
	ok(not app in _base(), "and it never got the screen")
	ok(m._window_focused, "GameCove stays in front")
	ok(await until(func(): return not m.session.is_active(), 20000), "then it ends")
	await w.idle()


## High 4: Play from Home, the game takes the screen, Guide: Home is there to see.
func test_home_is_visible_after_guide_in_a_game_launched_from_home() -> void:
	var m: Control = w.main
	await _press_play(GAME_A)
	ok(m.home.modulate.a < 0.01, "Home stepped back under the splash")
	_set_focusable(int(GAME_A["id"]), true)
	ok(await until(func(): return m.session.phase == "running", 4000), "the game's window shows")
	await w.idle()
	ok(not m._window_focused, "the game has the screen")
	await guide()
	await w.idle()
	eq(_base(), [413091, 769], "Guide: home in front")
	eq(m.current, "home", "on Home")
	eq(m.home.modulate.a, 1.0, "and Home is visible")
	eq(m.home.position.y, 0.0, "in place")
	ok(m.home.is_visible_in_tree(), "shown")
	await end_game()


## Medium: the pad doesn't reach the screen under the splash.
func test_the_pad_does_not_reach_the_screen_under_the_splash() -> void:
	var m: Control = w.main
	m.home.play_button.grab_focus()
	await w.frames(2)
	var presses := [0]
	var on_press := func() -> void: presses[0] += 1
	m.home.play_button.pressed.connect(on_press)
	await _press_play(GAME_A)
	var before := focus()
	await down()
	await right()
	await a()
	await lb()
	await w.frames(2)
	ok(focus() == before, "D-pad under the splash moves nothing")
	eq(presses[0], 0, "A under the splash presses nothing")
	eq(m.current, "home", "LB / RB don't change the screen under it")
	eq(m.session.game.get("key", ""), GAME_A["key"], "still the one game")
	ok(m.launch_overlay.is_open(), "the splash is still up")
	await b()
	ok(not m.launch_overlay.is_open(), "B still cancels")
	m.home.play_button.pressed.disconnect(on_press)
	ok(await until(func(): return not m.session.is_active(), 20000), "and the game is closed")
	await w.idle()


## High 7: an emulated game Steam ROM Manager added runs under Steam (store
## "emu", shortcut true). Exit game stops Steam's launch of it, by the shortcut's id.
const ROM := {"key": "emu:2789567361", "title": "Chrono Trigger", "store": "emu", "id": "2789567361", "installed": true,
	"shortcut": true, "emulated": {"system": "snes"}}


func test_exit_game_for_a_steam_rom_manager_game() -> void:
	await start_game(ROM)
	ok(await open_menu_tab("game"), "This game")
	var btn := qm().body.get_node("ExitGame/Button") as Button
	ok(await focus_on(btn), "Exit game reachable with the pad")
	await a()
	await a()
	eq(_closes("TERM", str(ROM["id"])), 1, "Steam's launch of the shortcut is stopped")
	eq(calls_with(["systemctl", "--user", "stop"]).size(), 0, "not a scope that doesn't exist")
	ok(await until(func(): return not w.main.session.is_active(), 15000), "the game ended")
	await w.idle()
	eq(_base(), [413091, 769], "home in front")


## Medium: a stream (or a desktop app, an emulation tool) isn't in Library.games.
## A library change while it runs must not forget what's running.
func test_what_runs_is_kept_when_the_library_changes() -> void:
	var m: Control = w.main
	var stream := {"key": "stream:host1:42", "title": "Desktop", "store": "stream", "id": "42", "installed": true}
	w.fake_pids[7001] = true
	m.playing = stream
	m.session.begin(stream, {"ok": true, "app_id": 0, "pid": 7001})
	await w.frames(2)
	ok(m.session.is_active(), "the stream runs")
	w.autoload("Library").changed.emit()
	await w.frames(2)
	eq(m.playing.get("key", ""), stream["key"], "a library change keeps what's running")
	await qam()
	ok(qm().visible, "the quick menu opens")
	eq(qm().head_title.text, stream["title"], "and This game is still the stream")
	await b()
	w.fake_pids.erase(7001)
	ok(await until(func(): return not m.session.is_active(), 15000), "the stream ends")
	ok(m.playing.is_empty(), "then nothing is playing")
	# nothing follows it (no session): a stale `playing` still goes with the next library change
	m.playing = stream
	w.autoload("Library").changed.emit()
	await w.frames(2)
	ok(m.playing.is_empty(), "not running and not in the library: forgotten")
	await w.idle()


## Review at ff76ca4, high 3 and the Controls medium: Play on another game while one runs used
## to end the running game's session under it (its exit-time cloud-save upload ran while it
## still wrote, and Controls ended on "no game"). Now it asks "Close <game> first?"; "Keep
## playing" (first) changes nothing; yes closes the running game and starts the next only once
## that one has exited.
func test_starting_another_game_asks_to_close_the_first() -> void:
	var m: Control = w.main
	await start_game(GAME_A)
	ok(m.session.phase == "running", "A runs")
	await guide()   # home over the running game, where Play on another one is pressed
	await w.idle()
	var ended := []
	var on_end := func(g: Dictionary) -> void: ended.append(g.get("key", ""))
	m.session.ended.connect(on_end)
	m._play(GAME_B)
	ok(await until(func(): return m.game_actions.sheet.is_open(), 3000), "Play on B asks first")
	eq(m.session.game.get("key", ""), GAME_A["key"], "A is still followed")
	eq(ended, [], "and its session wasn't ended")
	ok(not m.launch_overlay.is_open(), "nothing is launching")
	await a()   # the first answer: keep playing
	ok(await until(func(): return not m.game_actions.sheet.is_open(), 3000), "keep playing: the question goes away")
	await w.wait_s(0.5)
	eq(m.session.game.get("key", ""), GAME_A["key"], "A keeps running")
	eq(_closes("TERM", str(GAME_A["id"])), 0, "and isn't closed")
	# again, and this time yes
	w.fake_apps[int(GAME_B["id"])] = true
	_set_focusable(int(GAME_B["id"]), true)
	m._play(GAME_B)
	ok(await until(func(): return m.game_actions.sheet.is_open(), 3000), "asked again")
	await down()   # "Keep playing" comes first
	await a()
	ok(await until(func(): return _closes("TERM", str(GAME_A["id"])) == 1, 3000), "A is told to close (GameCloser, like Exit game)")
	ok(await until(func(): return m.session.game.get("key", "") == GAME_B["key"], 20000), "B starts once A has closed")
	eq(ended, [GAME_A["key"]], "A ended once, through its own exit check")
	await w.idle()
	await w.frames(3)
	var scope: RefCounted = load("res://scripts/controls/game_scope.gd").of(controls().ctx)
	eq(scope.key() if scope != null else "", GAME_B["key"], "Controls follow B, not \"no game\"")
	m.session.ended.disconnect(on_end)
	await end_game()
