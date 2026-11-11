extends "res://tests/test_case.gd"
## The trip to Steam's controller settings (scripts/steam/steam_handoff.gd) on a
## fake gamescope, and which games have the button (ui/controls/steam_input.gd).
## Nothing real runs.

const Handoff := preload("res://scripts/steam/steam_handoff.gd")
const SteamInput := preload("res://scripts/ui/controls/steam_input.gd")
const SteamFocus := preload("res://scripts/steam/steam_focus.gd")
const TC := preload("res://scripts/ui/texts_controls.gd")
const SessionWiring := preload("res://scripts/ui/games/session_wiring.gd")

const STEAM := {"key": "steam:620", "store": "steam", "id": "620", "title": "Portal 2"}
const ROM := {"key": "emu:2789567361", "store": "emu", "id": "2789567361", "title": "Chrono Trigger", "shortcut": true}


## Gamescope's root window: the focusable windows, and what was set or removed.
class FakeScope extends RefCounted:
	var windows: Array = []      # [wid, appid, pid, ...]
	var forced := 0
	var log: Array = []
	var running := true
	func is_running() -> bool: return running
	func read_root(_atom: String) -> Array: return windows.duplicate()
	func _run_async(args: PackedStringArray, _done: Callable) -> void:
		log.append(" ".join(args))
		if "-set" in args:
			forced = int(args[args.size() - 1])
		elif "-remove" in args:
			forced = 0


func _trip(scope: FakeScope) -> Dictionary:
	var w := {"uris": [], "events": [], "steam": true, "ok": true}
	var h: Node = Handoff.new()
	h.gamescope = scope
	h.open_uri = func(uri: String) -> bool:
		w["uris"].append(uri)
		return bool(w["ok"])
	h.steam_running = func() -> bool: return bool(w["steam"])
	h.comm_of = func(triples: Array) -> Dictionary:
		var out := {}
		var i := 2
		while i < triples.size():
			out[int(triples[i])] = "steam" if int(triples[i]) >= 5000 else "gamecove"
			i += 3
		return out
	h.own_pid = 100
	h.left.connect(func(): w["events"].append("left"))
	h.finished.connect(func(why): w["events"].append(why))
	w["h"] = h
	return w


func test_which_games_have_steam_controller_settings() -> void:
	eq(SteamInput.uri_for(STEAM), "steam://controllerconfig/620", "a Steam game: its app id")
	eq(SteamInput.uri_for(ROM), "steam://controllerconfig/2789567361", "a Steam ROM Manager shortcut: the shortcut's own app id")
	eq(SteamInput.uri_for({"key": "gog:1", "store": "gog", "id": "1207664663", "shortcut": true}), "steam://controllerconfig/1207664663", "any entry Steam starts as a shortcut")
	for g in [{"key": "epic:Quail", "store": "epic", "id": "Quail"}, {"key": "gog:1", "store": "gog", "id": "1207664663"},
			{"key": "amazon:x", "store": "amazon", "id": "amzn1.adg.product.x"}, {"key": "emu:rom1", "store": "emu", "id": "rom1", "shortcut": false},
			{"key": "emu:frontend", "store": "emu", "id": "frontend"}]:
		eq(SteamInput.uri_for(g), "", "%s: not started by Steam, no screen" % g["key"])
		eq(SteamInput.why_not(g), TC.GYRO_STEAM_NOT_STEAM, "%s: one line says why" % g["key"])
	eq(SteamInput.uri_for({"key": "emu:x", "store": "emu", "id": "620/../uninstall/440", "shortcut": true}), "", "a shortcut id that isn't a number never reaches a steam:// URI")
	eq(SteamInput.why_not(STEAM), "", "nothing to explain when there's a button")
	eq(SteamInput.why_not({}), TC.GYRO_STEAM_NO_GAME, "no game picked")
	ok(not TC.GYRO_STEAM_NOT_STEAM.contains("\n") and TC.GYRO_STEAM_NOT_STEAM.length() < 110, "one plain line")
	# the app's hand-off takes every button; an explicit opener (tests, tools) still wins
	var went := []
	SteamInput.handoff = func(g: Dictionary) -> bool:
		went.append(g["key"])
		return true
	ok(SteamInput.open(ROM), "opened through the hand-off")
	eq(went, ["emu:2789567361"], "with the game")
	var uris := []
	ok(SteamInput.open(STEAM, func(u): uris.append(u); return true), "an explicit opener")
	eq([uris, went.size()], [["steam://controllerconfig/620"], 1], "gets the URI itself")
	SteamInput.handoff = Callable()


func test_the_round_trip() -> void:
	var scope := FakeScope.new()
	scope.windows = [11, 769, 100]            # GameCove's own window
	var w := _trip(scope)
	var h: Node = w["h"]
	eq(h.start(ROM), "", "under way")
	eq(h.state, "opening", "opening")
	eq(w["uris"], ["steam://controllerconfig/2789567361"], "the URI went to Steam")
	eq(h.start(STEAM), "busy", "one trip at a time")
	h.poll()
	eq([h.state, scope.forced], ["opening", 0], "no Steam window yet: nothing forced")
	scope.windows = [11, 769, 100, 42, 769, 5001]
	h.poll()
	eq(h.state, "away", "Steam's window showed")
	eq(scope.forced, 42, "and is put in front (GAMESCOPECTRL_BASELAYER_WINDOW)")
	eq(w["events"], ["left"], "left")
	h.poll()
	eq(h.state, "away", "still there")
	scope.windows = [11, 769, 100]            # B out of Steam's screen: its window closes
	h.poll()
	eq(h.state, "returning", "its window is gone: coming back")
	eq(scope.forced, 0, "the screen is given back")
	h.arrived()
	eq([h.state, w["events"]], ["idle", ["left", "closed"]], "over once our window has focus again")
	h.free()


func test_guide_brings_it_back_and_focus_never_hangs() -> void:
	var scope := FakeScope.new()
	scope.windows = [11, 769, 100, 42, 769, 5001]   # Steam's handheld mode: one window, always there
	var w := _trip(scope)
	var h: Node = w["h"]
	eq(h.start(STEAM), "", "under way")
	h.poll()
	eq(h.state, "opening", "holds out for a new window first")
	for i in int(Handoff.NEW_WINDOW_S / Handoff.POLL_S) + 1:
		h.poll()
	eq([h.state, scope.forced], ["away", 42], "then takes the window Steam has")
	h.back("guide")
	eq([h.state, scope.forced], ["returning", 0], "Guide: back, though Steam's window is still there")
	for i in int(Handoff.RETURN_S / Handoff.POLL_S) + 1:
		h.poll()
	eq([h.state, w["events"]], ["idle", ["left", "guide"]], "our focus never arrived: over anyway, never a hang")
	h.free()


func test_slow_or_missing_steam() -> void:
	var scope := FakeScope.new()
	scope.windows = [11, 769, 100]
	var w := _trip(scope)
	var h: Node = w["h"]
	w["steam"] = false
	eq(h.start(STEAM), "no_steam", "Steam isn't running: said at once")
	eq([h.state, w["uris"]], ["idle", []], "nothing started, nothing sent")
	w["steam"] = true
	eq(h.start(STEAM), "", "under way")
	for i in int(Handoff.WAIT_S / Handoff.POLL_S) - 1:
		h.poll()
	eq(h.state, "opening", "still waiting just before the limit")
	h.poll()
	h.poll()
	eq([h.state, w["events"], scope.forced], ["idle", ["timeout"], 0], "no window in time: a timeout, nothing forced")
	# B while it's still opening
	eq(h.start(STEAM), "", "again")
	h.back("cancelled")
	eq([h.state, w["events"][-1]], ["idle", "cancelled"], "B stops the wait")
	# Steam didn't take the URI
	w["ok"] = false
	eq(h.start(STEAM), "", "started")
	eq([h.state, w["events"][-1]], ["idle", "failed"], "failed at once")
	# no gamescope (a desktop): the URI is handed over and that's all
	w["ok"] = true
	scope.running = false
	eq(h.start(STEAM), "direct", "outside gamescope: just opened")
	eq(h.state, "idle", "no trip to follow")
	eq(h.start({"key": "epic:Q", "store": "epic", "id": "Q"}), "none", "a game without the screen")
	h.free()


func test_the_controller_is_steams_while_its_screen_is_in_front() -> void:
	var calls := []
	var ctl := FakeController.new()
	ctl.calls = calls
	var wiring = SessionWiring.new()
	wiring.controller = ctl
	wiring.set_away(true)
	eq(calls, [true], "no game: Steam's screen in front means the pad isn't ours (intercept on Pass)")
	ok(wiring.other_window_focused(), "though our window may still say it has focus")
	wiring.set_away(false)
	eq(calls, [true, false], "back: ours again")
	wiring.running = true
	wiring._menu = true
	ok(not wiring.game_focused(), "a game with the quick menu over it: ours")
	wiring.set_away(true)
	ok(wiring.game_focused(), "Steam's screen over it: not ours")
	if wiring is Node:
		wiring.free()


class FakeController extends RefCounted:
	var calls: Array
	func set_game_focused(on: bool) -> void:
		calls.append(on)
