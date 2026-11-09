extends "res://tests/test_case.gd"
## A stream runs through the same GameSession as a game: focused by its app id,
## ended when Moonlight goes, but without a frame limit or Auto TDP (the PC
## renders; this handheld only decodes).

const LF := preload("res://tests/test_launch_focus.gd")
const GameSession := preload("res://scripts/launch/game_session.gd")
const GamescopeScript := preload("res://scripts/gamescope/gamescope.gd")
const Streaming := preload("res://scripts/streaming/streaming.gd")


func test_stream_session_focus_no_fps_limit_no_autotune() -> void:
	var helper = LF.new()
	var r: Array = helper._gamescope()
	var gs = r[0]
	var x = r[1]
	var power = LF.FakePower.new()
	var s = GameSession.new()
	s.setup(gs, power, LF.FakeLauncher.new())
	var alive := [true]
	s.pid_running = func(_p: int) -> bool: return alive[0]
	var game := {"key": "stream:A1B2:1450239417", "store": "stream", "id": "1450239417", "title": "Cyberpunk", "installed": true}
	var id := Streaming.app_id_for(game["key"])
	var ended := []
	s.ended.connect(func(g): ended.append(g["key"]))
	s.begin(game, {"ok": true, "app_id": id, "pid": 4100, "scoped": true})
	eq(s.phase, "waiting", "waits for Moonlight's window")
	eq(x.root.get(GamescopeScript.ATOM_FPS_LIMIT, []), [], "no frame limit for a stream")
	eq(power.calls, [], "no Auto TDP for a stream")
	x.root[GamescopeScript.ATOM_FOCUSABLE_APPS] = [769, id]
	s.poll_focus()
	eq(s.phase, "running", "Moonlight focused")
	eq(x.root.get(GamescopeScript.ATOM_BASELAYER_APPID, []), [413091, id, 769], "stream in front")
	ok(s.bring_home(), "Guide: home in front, stream keeps running")
	ok(s.return_to_game(), "back to the stream")
	x.root[GamescopeScript.ATOM_FOCUSABLE_APPS] = [769]
	alive[0] = false
	s.poll_exit()
	s.poll_exit()
	eq(ended, ["stream:A1B2:1450239417"], "Moonlight gone: session over")
	eq(power.calls, [], "still no Auto TDP calls")
	s.free()
	gs.free()
