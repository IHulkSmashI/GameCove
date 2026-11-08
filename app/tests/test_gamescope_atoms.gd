extends "res://tests/test_case.gd"
## Gamescope service: xprop command construction, parsing and detection, with a
## fake runner. Nothing here touches a real X display.

const GamescopeScript := preload("res://scripts/gamescope/gamescope.gd")


## Records every command; answers "get" calls from a fake root window.
class FakeRunner:
	extends RefCounted
	var calls: Array = []
	var root := {}          # atom -> Array of ints
	var fail_sets := false
	var missing := false    # pretend xprop isn't installed

	func run(program: String, args: PackedStringArray) -> Dictionary:
		calls.append([program, args])
		if missing:
			return {"exit": -1, "output": ""}
		var i := args.find("-set")
		if i >= 0:
			if fail_sets:
				return {"exit": 1, "output": "X Error of failed request:  BadWindow"}
			if args[0] == "-root":
				var vals := []
				for p in args[i + 2].split(","):
					vals.append(p.to_int())
				root[args[i + 1]] = vals
			return {"exit": 0, "output": ""}
		var atom: String = args[args.size() - 1]
		if root.has(atom):
			var s := PackedStringArray()
			for v in root[atom]:
				s.append(str(v))
			return {"exit": 0, "output": "%s = %s\n" % [atom, ", ".join(s)]}
		return {"exit": 0, "output": "%s:  not found.\n" % atom}


func _make(in_session := true) -> Array:
	var g = GamescopeScript.new()
	var r := FakeRunner.new()
	g.runner = r
	g.env = {"GAMESCOPE_WAYLAND_DISPLAY": "gamescope-0" if in_session else "", "DISPLAY": ""}
	g.window_id = 0x2a00003
	return [g, r]


func test_set_args_root_and_window() -> void:
	eq(GamescopeScript.set_args("root", "GAMESCOPE_FPS_LIMIT", [40]),
		PackedStringArray(["-root", "-f", "GAMESCOPE_FPS_LIMIT", "32c", "-set", "GAMESCOPE_FPS_LIMIT", "40"]), "root fps")
	eq(GamescopeScript.set_args(0x2a00003, "STEAM_GAME", [769]),
		PackedStringArray(["-id", "0x2a00003", "-f", "STEAM_GAME", "32c", "-set", "STEAM_GAME", "769"]), "window STEAM_GAME")
	eq(GamescopeScript.set_args("root", "GAMESCOPECTRL_BASELAYER_APPID", [413091, 976730, 769])[6],
		"413091,976730,769", "array values are comma separated")
	eq(GamescopeScript.get_args("GAMESCOPE_FOCUSED_APP"),
		PackedStringArray(["-root", "-notype", "GAMESCOPE_FOCUSED_APP"]), "get args")


func test_parse_values() -> void:
	eq(GamescopeScript.parse_values("GAMESCOPE_FPS_LIMIT = 40\n", "GAMESCOPE_FPS_LIMIT"), [40], "single")
	eq(GamescopeScript.parse_values("GAMESCOPECTRL_BASELAYER_APPID = 413091, 769", "GAMESCOPECTRL_BASELAYER_APPID"), [413091, 769], "array")
	eq(GamescopeScript.parse_values("GAMESCOPE_FPS_LIMIT:  not found.", "GAMESCOPE_FPS_LIMIT"), [], "missing")
	eq(GamescopeScript.parse_values("GAMESCOPE_FPS_LIMIT_X = 3", "GAMESCOPE_FPS_LIMIT"), [], "no prefix match")
	eq(GamescopeScript.parse_values("GAMESCOPE_FPS_LIMIT = abc", "GAMESCOPE_FPS_LIMIT"), [], "garbage")


func test_fps_limit_sets_root_atom_and_reads_back() -> void:
	var m := _make()
	ok(m[0].set_fps_limit(40), "fps limit set")
	eq(m[1].root.get("GAMESCOPE_FPS_LIMIT"), [40], "root atom written")
	eq(m[1].calls[0][0], "xprop", "uses xprop")
	ok(m[0].set_fps_limit(0), "0 clears the cap")
	ok(not m[0].set_fps_limit(-5), "negative rejected")
	ok(not m[0].set_fps_limit(5000), "absurd value rejected")
	m[0].free()


func test_refresh_rate_uses_dynamic_refresh_atom() -> void:
	var m := _make()
	ok(m[0].set_refresh_rate(60), "refresh set")
	eq(m[1].root.get("GAMESCOPE_DYNAMIC_REFRESH"), [60], "dynamic refresh atom")
	m[0].free()


func test_failed_set_returns_false() -> void:
	var m := _make()
	m[1].fail_sets = true
	ok(not m[0].set_fps_limit(30), "xprop error reported")
	m[1].fail_sets = false
	m[1].missing = true
	ok(not m[0].set_refresh_rate(60), "missing xprop reported")
	m[0].free()


func test_overlay_sets_window_atoms() -> void:
	var m := _make()
	m[0].set_overlay(true)
	var sets: Array = m[1].calls.map(func(c): return " ".join(c[1]))
	ok(sets.has("-id 0x2a00003 -f STEAM_OVERLAY 32c -set STEAM_OVERLAY 1"), "overlay on")
	ok(sets.has("-id 0x2a00003 -f STEAM_INPUT_FOCUS 32c -set STEAM_INPUT_FOCUS 1"), "input focus on")
	m[1].calls.clear()
	m[0].set_overlay(false)
	sets = m[1].calls.map(func(c): return " ".join(c[1]))
	ok(sets.has("-id 0x2a00003 -f STEAM_OVERLAY 32c -set STEAM_OVERLAY 0"), "overlay off")
	ok(sets.has("-id 0x2a00003 -f STEAM_INPUT_FOCUS 32c -set STEAM_INPUT_FOCUS 0"), "input focus off")
	m[0].free()


func test_claim_main_window_and_focus() -> void:
	var m := _make()
	ok(m[0].claim_main_window(), "claimed")
	eq(" ".join(m[1].calls[0][1]), "-id 0x2a00003 -f STEAM_GAME 32c -set STEAM_GAME 769", "STEAM_GAME=769 on our window")
	eq(m[1].root.get("GAMESCOPECTRL_BASELAYER_APPID"), [413091, 769], "home on base layer")
	ok(m[0].focus_app(976730), "focus game")
	eq(m[1].root.get("GAMESCOPECTRL_BASELAYER_APPID"), [413091, 976730, 769], "game sandwiched like Steam does")
	ok(not m[0].focus_app(0), "bad app id")
	m[1].root["GAMESCOPE_FOCUSED_APP"] = [976730]
	eq(m[0].focused_app(), 976730, "focused app read")
	m[0].free()


func test_outside_gamescope_does_nothing() -> void:
	var m := _make(false)
	ok(not m[0].is_running(), "not running without env or root atom")
	ok(not m[0].set_fps_limit(40), "no-op outside gamescope")
	m[0].set_overlay(true)
	eq(m[1].calls.size(), 0, "no commands outside gamescope")
	m[0].free()
