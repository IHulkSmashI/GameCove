extends "res://tests/e2e/e2e_case.gd"
## The trip to Steam's controller settings and back, in the running app on the
## fake gamescope: the button hands off (a cover, the pad dead for GameCove,
## Steam's window forced in front, the controller Steam's), and coming back
## lands exactly where it started with no button leaking through. Also Steam
## not running, Steam too slow, Guide, and the quick menu over a running game.
##
## "Steam" here: the test adds a window owned by pid 5001 to
## GAMESCOPE_FOCUSABLE_WINDOWS when Steam would show its screen, and takes it
## away when the person backs out of it.

const SteamInput := preload("res://scripts/ui/controls/steam_input.gd")
const STEAM_WID := 4242
const STEAM_PID := 5001
const ROM := {"key": "emu:2789567361", "title": "Chrono Trigger", "store": "emu", "id": "2789567361", "installed": true, "shortcut": true}

var _uris: Array = []


func _trip() -> Control:
	return w.main.steam_trip


func _svc() -> Node:
	return w.main.steam_trip.service


## Steam "runs", takes URIs, and its windows are the ones owned by STEAM_PID.
func _fake_steam(running := true) -> void:
	_uris = []
	var s := _svc()
	s.steam_running = func() -> bool: return running
	s.open_uri = func(uri: String) -> bool:
		_uris.append(uri)
		return true
	s.comm_of = func(triples: Array) -> Dictionary:
		var out := {}
		var i := 2
		while i < triples.size():
			out[int(triples[i])] = "steam" if int(triples[i]) == STEAM_PID else "gamecove"
			i += 3
		return out
	_steam_window(false)
	w.fake._mutex.lock()
	w.fake.xroot.erase("GAMESCOPECTRL_BASELAYER_WINDOW")
	w.fake._mutex.unlock()


func _steam_window(shown: bool) -> void:
	w.fake._mutex.lock()
	var ours := "%d, 769, %d" % [w.WINDOW_ID, OS.get_process_id()]
	w.fake.xroot["GAMESCOPE_FOCUSABLE_WINDOWS"] = ours + (", %d, 769, %d" % [STEAM_WID, STEAM_PID] if shown else "")
	w.fake._mutex.unlock()


func _forced() -> String:
	return atom("GAMESCOPECTRL_BASELAYER_WINDOW")


func _toasts() -> String:
	var out := ""
	for l in w.main.toasts.find_children("*", "Label", true, false):
		out += str(l.text) + " | "
	return out


## Out: a cover, the pad dead, Steam's window in front, the controller Steam's.
## Back (B out of Steam's screen): the same screen, the same focused control, and
## that B doesn't also mean Back here.
func test_round_trip_from_a_screen() -> void:
	var m: Control = w.main
	_fake_steam()
	m.show_screen("library")
	await w.frames(6)
	var here: Control = m.library_screen.filter_button
	here.grab_focus()
	await w.frames(2)
	ok(SteamInput.open(ROM), "the button: a Steam ROM Manager game has the screen too")
	ok(await until(func(): return not _uris.is_empty(), 2000), "the address goes to Steam")
	eq(_uris, ["steam://controllerconfig/2789567361"], "Steam gets the shortcut's app id")
	eq(_svc().state, "opening", "on its way")
	ok(_trip().visible, "a cover comes up (no flash of what's behind)")
	eq(_trip().label.text, TC.GYRO_STEAM_OPENING, "and says what's happening")
	await down()
	await a()
	await rb()
	ok(focus() == here, "the pad does nothing in GameCove meanwhile")
	eq(m.current, "library", "no screen change")
	ok(not m.game_actions.is_modal(), "nothing opened")
	eq(_forced(), "", "nothing forced in front before Steam has a window")
	_steam_window(true)                       # Steam shows its screen
	ok(await until(func(): return _svc().state == "away", 3000), "Steam's window is found")
	await w.idle()
	eq(_forced(), str(STEAM_WID), "and put in front")
	ok(_trip().modulate.a > 0.99, "the cover is fully up behind it")
	ok(not m._window_focused, "GameCove's window isn't in front")
	ok(m.wiring.other_window_focused(), "the controller is Steam's (InputPlumber on Pass)")
	await down()
	ok(focus() == here, "and nothing here reacts to buttons")
	# B backs out of Steam's screen: its window closes. That same B arrives here too.
	_steam_window(false)
	var e := InputEventJoypadButton.new()
	e.device = 0
	e.button_index = JOY_BUTTON_B
	e.pressed = true
	_send(e)
	ok(await until(func(): return _svc().state != "away", 3000), "the window is gone: coming back")
	ok(await until(func(): return _forced() == "", 2000), "the screen is given back")
	await w.idle()
	ok(await until(func(): return not _svc().active(), 4000), "the trip is over")
	ok(m._window_focused, "GameCove has the focus again")
	eq(m.current, "library", "still on the Library: the B that closed Steam's screen didn't mean Back here")
	ok(focus() == here, "focus is on the very control it left")
	ok(_trip().blocks(), "and the pad is still held off while that B is down")
	var u := InputEventJoypadButton.new()
	u.device = 0
	u.button_index = JOY_BUTTON_B
	u.pressed = false
	_send(u)
	await w.wait_s(0.5)
	ok(not _trip().blocks(), "released, and a moment later the pad is GameCove's again")
	ok(not _trip().visible, "the cover has faded away")
	ok(not m.wiring.other_window_focused(), "the controller is ours again")
	await b()
	await w.frames(4)
	eq(m.current, "home", "and B works as ever")


## Guide while Steam's screen is in front comes back too (Steam's handheld mode
## keeps one window: nothing closes).
func test_guide_comes_back() -> void:
	var m: Control = w.main
	_fake_steam()
	m.show_screen("home")
	await w.frames(4)
	var here: Control = m.home.default_focus()
	here.grab_focus()
	await w.frames(2)
	_steam_window(true)                       # Steam already has its one window
	ok(SteamInput.open(GAME_A), "opened")
	ok(await until(func(): return _svc().state == "away", 5000), "after a moment the window Steam has is used")
	await w.idle()
	eq(_forced(), str(STEAM_WID), "in front")
	await guide()
	ok(await until(func(): return not _svc().active(), 4000), "Guide: back")
	await w.idle()
	eq(_forced(), "", "the screen is ours")
	eq(m.current, "home", "on the screen it left")
	ok(focus() == here, "focus where it was (%s)" % [focus()])
	ok(not m.quick_menu.visible, "Guide did nothing else")
	await w.wait_s(0.5)
	ok(not _trip().visible and not _trip().blocks(), "cover gone, pad back")


## Steam isn't running: said calmly, nothing starts. Steam too slow: a calm
## message after the wait, focus back, never a hang.
func test_steam_missing_or_slow() -> void:
	var m: Control = w.main
	_fake_steam(false)
	m.show_screen("home")
	await w.frames(4)
	var here: Control = m.home.default_focus()
	here.grab_focus()
	await w.frames(2)
	ok(SteamInput.open(GAME_A), "handled")
	ok(not _svc().active() and not _trip().visible, "Steam isn't running: no trip, no cover")
	eq(_uris, [], "nothing sent")
	ok(_toasts().contains(TC.GYRO_STEAM_NOT_RUNNING), "it says Steam isn't running")
	ok(not _trip().blocks(), "and the pad stays GameCove's")
	_fake_steam(true)
	here.grab_focus()
	await w.frames(2)
	ok(SteamInput.open(GAME_A), "Steam runs, but never shows its screen")
	eq(_svc().state, "opening", "waiting")
	_svc()._waited = _svc().WAIT_S - 0.5      # the wait is nearly over (8 s in real life)
	ok(await until(func(): return not _svc().active(), 4000), "it gives up: no hang")
	eq(_forced(), "", "nothing was forced in front")
	ok(_toasts().contains(TC.GYRO_STEAM_SLOW), "with a calm message (%s)" % _toasts())
	ok(focus() == here, "focus is back where it was")
	await w.wait_s(0.5)
	ok(not _trip().visible and not _trip().blocks(), "cover gone, pad back")
	# B while it's still opening stops the wait
	ok(SteamInput.open(GAME_A), "again")
	await w.frames(3)
	await b()
	ok(not _svc().active(), "B while it's opening: stopped")
	await w.wait_s(0.5)
	eq(m.current, "home", "and that B did nothing else")


## From the quick menu over a running game: the menu stays (the game doesn't get
## the pad) until Steam's screen is up, then steps aside; afterwards the game is
## in front again with the menu open on the same tab and button.
func test_from_the_quick_menu_over_a_running_game() -> void:
	var m: Control = w.main
	_fake_steam()
	await start_game(GAME_A)
	ok(await open_menu_tab("controller"), "the quick menu's Controller tab, over the game")
	var btn: Control = qm().body.find_child("OpenSteamInput", true, false)
	var by_button := btn != null
	if by_button:
		ok(await focus_on(btn), "Steam controller settings reachable with the pad")
		await a()
	else:
		# this handheld's Controller tab has no gyro card: the same call the button makes
		btn = focus()
		ok(SteamInput.open(GAME_A), "opened from the menu")
	var name := str(btn.name)
	ok(await until(func(): return not _uris.is_empty(), 2000), "the address goes to Steam")
	eq(_uris, ["steam://controllerconfig/%s" % GAME_A["id"]], "Steam asked for the game's controller settings")
	eq(_svc().state, "opening", "on its way")
	ok(qm().visible, "the menu stays up while Steam gets its window ready")
	ok(not m.wiring.game_focused(), "so the game under it doesn't get the pad")
	_steam_window(true)
	ok(await until(func(): return _svc().state == "away", 3000), "Steam's screen is up")
	await w.idle()
	ok(not qm().visible, "the menu steps aside for it")
	eq(_forced(), str(STEAM_WID), "Steam's window in front of the game")
	ok(m.wiring.game_focused(), "the controller isn't ours")
	ok(m.session.is_active(), "the game keeps running")
	_steam_window(false)
	ok(await until(func(): return not _svc().active(), 6000), "Steam's screen closed: back")
	await w.idle()
	eq(_forced(), "", "the game has the screen again")
	ok(qm().visible, "and the quick menu is open again")
	eq(qm().section, TC.TAB_IDS.find("controller"), "on the same tab")
	await w.frames(3)
	ok(focus() != null and str(focus().name) == name, "on the same button (%s)" % name)
	ok(not m.wiring.game_focused(), "the pad is the menu's")
	await w.wait_s(0.5)
	await b()
	await w.idle()
	ok(not qm().visible, "B closes the menu as usual")
	ok(m.session.is_active(), "the game is still there")
	await end_game()
