extends "res://tests/test_case.gd"
## Launch focus: app ids and systemd scopes for games we start, the Steam launch
## command, and GameSession (focus the game, apply its settings, go home when it
## ends) against the real Gamescope service on a fake xprop. Nothing is started.

const LibraryScript := preload("res://scripts/library/library.gd")
const Steam := preload("res://scripts/library/stores/steam.gd")
const GamescopeScript := preload("res://scripts/gamescope/gamescope.gd")
const GameSession := preload("res://scripts/launch/game_session.gd")
const LauncherScript := preload("res://scripts/launch/launcher.gd")
const SettingsForm := preload("res://scripts/ui/settings_form.gd")
const MainScript := preload("res://scripts/main.gd")


## Fake xprop: a root window gamescope "writes" and we read.
class FakeXprop:
	extends RefCounted
	var root := {}
	var calls: Array = []

	func run(program: String, args: PackedStringArray) -> Dictionary:
		calls.append(" ".join(args))
		var i := args.find("-set")
		if i >= 0:
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


class FakePower:
	extends RefCounted
	var calls: Array = []
	func autotune_start() -> bool:
		calls.append("start")
		return true
	func autotune_stop() -> void:
		calls.append("stop")


## Like Power with its worker: jobs are queued by name, newest wins, run on flush().
class QueuedPower:
	extends FakePower
	var jobs := {}
	func request_autotune(on: bool, _key := "") -> void:
		jobs["autotune"] = autotune_start if on else autotune_stop
	func flush() -> void:
		for k in jobs:
			jobs[k].call()
		jobs.clear()


class FakeLauncher:
	extends RefCounted
	var s := {"goal": "battery", "fps_limit": 30, "upscaler": "auto", "frame_gen": false, "low_latency": true}
	func settings_for(_key: String) -> Dictionary:
		return s.duplicate()
	func save_settings(_key: String, v: Dictionary) -> void:
		s = v.duplicate()
	func auto_tdp_for(_key: String) -> bool:
		return s["goal"] in LauncherScript.AUTO_TDP_GOALS


const EPIC := {"key": "epic:Quail", "store": "epic", "id": "Quail", "installed": true}
const STEAM := {"key": "steam:976730", "store": "steam", "id": "976730", "installed": true}


func _gamescope(in_session := true) -> Array:
	var x := FakeXprop.new()
	var g = GamescopeScript.new()
	g.runner = x
	g.env = {"GAMESCOPE_WAYLAND_DISPLAY": "gamescope-0" if in_session else "", "DISPLAY": ""}
	x.root[GamescopeScript.ATOM_FOCUSABLE_APPS] = [769]
	return [g, x]


func _session(gs, power, launcher) -> Node:
	var s = GameSession.new()
	s.setup(gs, power, launcher)
	return s


func _base(x: FakeXprop) -> Array:
	return x.root.get(GamescopeScript.ATOM_BASELAYER_APPID, [])


func _fps(x: FakeXprop) -> Array:
	return x.root.get(GamescopeScript.ATOM_FPS_LIMIT, [])


# ------------------------------------------------------------ app ids and commands

func test_app_id_is_stable_and_out_of_steam_range() -> void:
	var a := LibraryScript.app_id_for("epic:Quail")
	eq(a, LibraryScript.app_id_for("epic:Quail"), "same key, same id")
	ok(a != LibraryScript.app_id_for("gog:1207664663"), "different games, different ids")
	for k in ["epic:Quail", "gog:1", "amazon:amzn1.adg.product.aaaa-1111", ""]:
		var id := LibraryScript.app_id_for(k)
		ok(id >= 0x40000000 and id <= 0x7FFFFFFF, "%s: bit 30 set, positive 31-bit (%d)" % [k, id])


func test_scope_command_matches_gamescope_cgroup_pattern() -> void:
	var cmd := LibraryScript.scope_command(["env", "A=1", "/usr/bin/legendary", "launch", "Quail"], 1234567890, 42, "/usr/bin/systemd-run")
	eq(cmd, ["/usr/bin/systemd-run", "--user", "--scope", "--collect", "--quiet",
		"--unit=app-steam-app1234567890-42", "--", "env", "A=1", "/usr/bin/legendary", "launch", "Quail"] as Array[String],
		"systemd-run wraps the store command")
	# gamescope: sscanf(scope, "app-steam-app%u-%d.scope", ...)
	var unit := cmd[5].trim_prefix("--unit=") + ".scope"
	var m := RegEx.create_from_string("^app-steam-app(\\d+)-(-?\\d+)\\.scope$").search(unit)
	ok(m != null, "unit name parses like gamescope's sscanf")
	eq(m.get_string(1).to_int() if m else 0, 1234567890, "app id read back")


func test_can_scope_needs_binary_and_user_manager() -> void:
	var rt := OS.get_user_data_dir().path_join("test_runtime_dir")
	DirAccess.make_dir_recursive_absolute(rt)
	DirAccess.remove_absolute(rt.path_join("systemd"))
	ok(not LibraryScript.can_scope("", rt), "no systemd-run")
	ok(not LibraryScript.can_scope("/usr/bin/systemd-run", ""), "no XDG_RUNTIME_DIR")
	ok(not LibraryScript.can_scope("/usr/bin/systemd-run", rt), "user manager not running")
	DirAccess.make_dir_recursive_absolute(rt.path_join("systemd"))
	ok(LibraryScript.can_scope("/usr/bin/systemd-run", rt), "both present")
	DirAccess.remove_absolute(rt.path_join("systemd"))


func test_steam_launch_args() -> void:
	eq(Steam.launch_args("976730"), PackedStringArray(["steam://rungameid/976730"]), "steam steam://rungameid/<id>")


func test_focusable_apps_read() -> void:
	var r := _gamescope()
	r[1].root[GamescopeScript.ATOM_FOCUSABLE_APPS] = [769, 976730]
	eq(r[0].focusable_apps(), [769, 976730], "list from the root window")
	r[0].free()


# ------------------------------------------------------------ session

func test_scoped_game_gets_focus_settings_and_goes_home() -> void:
	var r := _gamescope()
	var gs = r[0]
	var x: FakeXprop = r[1]
	var power := FakePower.new()
	var s := _session(gs, power, FakeLauncher.new())
	var alive := [true]
	s.pid_running = func(_p: int) -> bool: return alive[0]
	var id := LibraryScript.app_id_for("epic:Quail")
	var ended := []
	s.ended.connect(func(g): ended.append(g["key"]))

	s.begin(EPIC, {"ok": true, "app_id": id, "pid": 4242, "scoped": true})
	eq(s.phase, "waiting", "waits for the game's window")
	eq(_fps(x), [30], "game's frame limit applied at launch")
	eq(power.calls, ["start"], "battery goal starts Auto TDP")
	s.poll_focus()
	eq(s.phase, "waiting", "not focusable yet")
	eq(_base(x), [], "nothing focused yet")

	x.root[GamescopeScript.ATOM_FOCUSABLE_APPS] = [769, id]
	s.poll_focus()
	eq(s.phase, "running", "window appeared")
	eq(_base(x), [413091, id, 769], "game brought to the front")
	ok(s.focused, "focus_app succeeded")

	s.poll_exit()
	eq(s.phase, "running", "still listed")
	x.root[GamescopeScript.ATOM_FOCUSABLE_APPS] = [769]
	s.poll_exit()
	eq(s.phase, "running", "process alive: a gap between windows isn't the end")
	alive[0] = false
	s.poll_exit()
	eq(s.phase, "running", "one miss isn't enough")
	s.poll_exit()
	eq(s.phase, "idle", "two misses: game over")
	eq(_base(x), [413091, 769], "home back in front")
	eq(_fps(x), [0], "frame limit cleared")
	eq(power.calls, ["start", "stop"], "Auto TDP stopped")
	eq(ended, ["epic:Quail"], "ended emitted once")
	s.free()
	gs.free()


func test_steam_game_never_appears_gives_up_after_wait() -> void:
	var r := _gamescope()
	var x: FakeXprop = r[1]
	var launcher := FakeLauncher.new()
	launcher.s["goal"] = "smooth"
	launcher.s["fps_limit"] = 0
	var power := FakePower.new()
	var s := _session(r[0], power, launcher)
	s.steam_alive = func(_id: int) -> bool: return false   # Steam's launch never started (no reaper)
	s.begin(STEAM, {"ok": true, "app_id": 976730, "pid": 0, "scoped": false})
	eq(power.calls, [], "smooth goal: no Auto TDP")
	var polls := int(GameSession.FOCUS_WAIT_S / GameSession.FOCUS_POLL_S)
	for i in polls - 1:
		s.poll_focus()
	eq(s.phase, "waiting", "still waiting just before the limit")
	s.poll_focus()
	eq(s.phase, "waiting", "no reaper once: checked again")
	for i in int(GameSession.REAPER_CHECK_S / GameSession.FOCUS_POLL_S):
		s.poll_focus()
	eq(s.phase, "idle", "gave up after %d s and no Steam launch twice" % int(GameSession.FOCUS_WAIT_S))
	eq(_base(x), [413091, 769], "home in front")
	eq(power.calls, [], "no stop without a start")
	s.free()
	r[0].free()


func test_slow_steam_launch_keeps_the_session_while_its_reaper_runs() -> void:
	# review S5-1: shader pre-caching / an update / a launcher take minutes; never give up while Steam runs it
	var r := _gamescope()
	var x: FakeXprop = r[1]
	var power := QueuedPower.new()
	var launcher := FakeLauncher.new()
	var s := _session(r[0], power, launcher)
	var alive := [true]
	var asked := [0]
	s.steam_alive = func(_id: int) -> bool:
		asked[0] += 1
		return alive[0]
	var ended := []
	s.ended.connect(func(g): ended.append(g))
	s.begin(STEAM, {"ok": true, "app_id": 976730, "pid": 0})
	power.flush()
	eq(power.calls, ["start"], "battery goal: Auto TDP on")
	for i in int(5 * 60 / GameSession.FOCUS_POLL_S):    # five minutes of shader pre-caching
		s.poll_focus()
	eq(s.phase, "waiting", "still waiting after five minutes: the reaper runs")
	ok(asked[0] > 0 and asked[0] <= int(4 * 60 / GameSession.REAPER_CHECK_S) + 2, "reaper checked every %d s, not every poll" % int(GameSession.REAPER_CHECK_S))
	eq(ended, [], "the session (profile, Auto TDP) was kept")
	x.root[GamescopeScript.ATOM_FOCUSABLE_APPS] = [769, 976730]
	s.poll_focus()
	eq(s.phase, "running", "the window came")
	eq(_base(x), [413091, 976730, 769], "and got focus")
	s.stop()
	x.root[GamescopeScript.ATOM_FOCUSABLE_APPS] = [769]
	# the launch dies before any window: the session ends (InterceptMode back with Controller.end_game)
	s.begin(STEAM, {"ok": true, "app_id": 976730, "pid": 0})
	alive[0] = false
	for i in int((GameSession.FOCUS_WAIT_S + 2 * GameSession.REAPER_CHECK_S) / GameSession.FOCUS_POLL_S) + 2:
		s.poll_focus()
	eq(s.phase, "idle", "the reaper went away: session over")
	eq(ended.size(), 2, "ended both times")
	eq(_base(x), [413091, 769], "home in front")
	s.free()
	r[0].free()


func test_steam_game_focus_and_exit_by_focusable_list() -> void:
	var r := _gamescope()
	var x: FakeXprop = r[1]
	var s := _session(r[0], FakePower.new(), FakeLauncher.new())
	s.begin(STEAM, {"ok": true, "app_id": 976730, "pid": 0})
	x.root[GamescopeScript.ATOM_FOCUSABLE_APPS] = [769, 976730]
	s.poll_focus()
	eq(_base(x), [413091, 976730, 769], "Steam game focused by its app id")
	x.root[GamescopeScript.ATOM_FOCUSABLE_APPS] = [769]
	s.poll_exit()
	s.poll_exit()
	eq(s.phase, "idle", "gone from the list twice: ended")
	eq(_base(x), [413091, 769], "home")
	s.free()
	r[0].free()


func test_unscoped_fallback_follows_process_only() -> void:
	var r := _gamescope()
	var x: FakeXprop = r[1]
	var s := _session(r[0], FakePower.new(), FakeLauncher.new())
	var alive := [true]
	s.pid_running = func(_p: int) -> bool: return alive[0]
	s.begin(EPIC, {"ok": true, "app_id": 0, "pid": 99, "scoped": false})
	eq(s.phase, "running", "no app id: nothing to wait for")
	eq(_base(x), [], "no focus call without an app id")
	eq(_fps(x), [30], "settings still applied")
	alive[0] = false
	s.poll_exit()
	s.poll_exit()
	eq(s.phase, "idle", "process gone: ended")
	eq(_fps(x), [0], "limit cleared")
	s.free()
	r[0].free()


func test_failed_launch_and_no_gamescope() -> void:
	var r := _gamescope(false)
	var x: FakeXprop = r[1]
	var power := FakePower.new()
	var s := _session(r[0], power, FakeLauncher.new())
	s.begin(EPIC, {"ok": false, "app_id": 0, "pid": 0})
	eq(s.phase, "idle", "failed launch starts nothing")
	eq(power.calls, [], "no Auto TDP for a failed launch")
	s.pid_running = func(_p: int) -> bool: return false
	s.begin(EPIC, {"ok": true, "app_id": 123, "pid": 5})
	eq(_fps(x), [], "outside gamescope: no xprop writes")
	s.poll_exit()   # still waiting: ignored
	eq(s.phase, "waiting", "waiting for focus")
	s.stop()
	eq(s.phase, "idle", "stop() ends it")
	eq(power.calls, ["start", "stop"], "Auto TDP still paired outside gamescope")
	s.free()
	r[0].free()


func test_power_jobs_go_through_queue_and_coalesce() -> void:
	var r := _gamescope()
	var power := QueuedPower.new()
	var s := _session(r[0], power, FakeLauncher.new())
	s.begin(EPIC, {"ok": true, "app_id": 0, "pid": 7})
	eq(power.calls, [], "start queued, not run on the caller's thread")
	s.stop()
	power.flush()
	eq(power.calls, ["stop"], "start then stop before the worker ran: only stop runs")
	s.begin(EPIC, {"ok": true, "app_id": 0, "pid": 7})
	power.flush()
	eq(power.calls, ["stop", "start"], "start runs on the worker")
	s.free()
	r[0].free()


func test_new_launch_replaces_running_session() -> void:
	var r := _gamescope()
	var power := FakePower.new()
	var s := _session(r[0], power, FakeLauncher.new())
	var ended := []
	s.ended.connect(func(g): ended.append(g["key"]))
	s.begin(EPIC, {"ok": true, "app_id": 0, "pid": 7})
	s.begin(STEAM, {"ok": true, "app_id": 976730, "pid": 0})
	eq(ended, ["epic:Quail"], "old session ended")
	eq(s.game["key"], "steam:976730", "new game tracked")
	eq(power.calls, ["start", "stop", "start"], "Auto TDP restarted for the new game")
	s.free()
	r[0].free()


# ------------------------------------------------------------ settings

func test_auto_tdp_follows_goal() -> void:
	var p := OS.get_user_data_dir().path_join("test_launch_focus_settings.json")
	DirAccess.remove_absolute(p)
	var l: Node = LauncherScript.new()
	l.settings_path = p
	l.home = ""
	l.device_profile = {"gpu_family": "intel-xe3"}
	ok(l.auto_tdp_for("epic:Quail"), "balanced default: on")
	l.save_settings("epic:Quail", {"goal": "smooth"})
	ok(not l.auto_tdp_for("epic:Quail"), "smooth: off")
	l.save_settings("epic:Quail", {"goal": "battery", "fps_limit": 40})
	l.reload()
	eq(l.settings_for("epic:Quail")["fps_limit"], 40, "saved fps limit read back at next launch")
	ok(l.auto_tdp_for("epic:Quail"), "battery: on")
	l.free()
	DirAccess.remove_absolute(p)


func test_steam_form_hides_env_rows() -> void:
	var launcher := FakeLauncher.new()
	var f: VBoxContainer = SettingsForm.new()
	f.setup("steam:976730", launcher, true, false)
	eq(f.rows.keys(), ["goal", "fps_limit"], "only settings we can apply to a Steam launch")
	ok(f.get_node_or_null("SteamNote") != null, "one line points to Steam launch options")
	eq(f.focusables().size(), 2, "the note isn't focusable")
	f.rows["goal"].step(1)   # battery -> balanced, preset touches hidden rows too
	eq(launcher.s["goal"], "balanced", "goal saved")
	eq(launcher.s["fps_limit"], 60, "preset frame limit saved")
	f.free()
	var full: VBoxContainer = SettingsForm.new()
	full.setup("epic:Quail", launcher, true)
	eq(full.rows.keys(), ["goal", "fps_limit", "upscaler", "frame_gen", "low_latency"], "default keeps every row")
	full.free()


func test_resume_detection_by_clock_gap() -> void:
	ok(not MainScript.resumed_between([1000.0, 0], [5000.0, 9000], 20.0), "no mark yet")
	ok(not MainScript.resumed_between([1000.0, 5000], [1005.0, 10000], 20.0), "clocks agree")
	ok(MainScript.resumed_between([1000.0, 5000], [1600.0, 10000], 20.0), "wall clock 10 min ahead: slept")


func test_guide_brings_home_and_back_without_ending_the_game() -> void:
	var r := _gamescope()
	var x: FakeXprop = r[1]
	var s := _session(r[0], FakePower.new(), FakeLauncher.new())
	s.begin(STEAM, {"ok": true, "app_id": 976730, "pid": 0})
	x.root[GamescopeScript.ATOM_FOCUSABLE_APPS] = [769, 976730]
	s.poll_focus()
	ok(s.bring_home(), "home brought forward")
	eq(_base(x), [413091, 769], "GameCove in front")
	eq(s.phase, "running", "game still running")
	ok(s.runs(STEAM["key"]), "runs() knows the game")
	ok(s.return_to_game(), "back to the game")
	eq(_base(x), [413091, 976730, 769], "game in front again")
	s.stop()
	ok(not s.return_to_game(), "nothing to return to once stopped")
	s.free()
	r[0].free()


## xprop with `-spy`: the watch GameSession keeps while a game runs (lines pushed by the test).
class SpyXprop:
	extends FakeXprop
	var watches: Array = []

	func spawn_watch(program: String, args: PackedStringArray, on_line: Callable, on_exit := Callable()) -> RefCounted:
		calls.append(program + " " + " ".join(args))
		var w := SpyWatch.new()
		w.on_line = on_line
		w.on_exit = on_exit
		watches.append(w)
		return w


class SpyWatch:
	extends RefCounted
	var on_line: Callable
	var on_exit: Callable
	var running := true

	func alive() -> bool:
		return running

	func stop() -> void:
		running = false

	func say(line: String) -> void:
		on_line.call(line)


func test_no_polling_behind_a_listed_game() -> void:
	var x := SpyXprop.new()
	var g = GamescopeScript.new()
	g.runner = x
	g.env = {"GAMESCOPE_WAYLAND_DISPLAY": "gamescope-0", "DISPLAY": ""}
	x.root[GamescopeScript.ATOM_FOCUSABLE_APPS] = [769, 976730]
	var s := _session(g, FakePower.new(), FakeLauncher.new())
	s.begin(STEAM, {"ok": true, "app_id": 976730, "pid": 0})
	s.poll_focus()
	eq(s.phase, "running", "the game's window came")
	eq(x.watches.size(), 1, "one watch on the focusable list")
	ok(x.calls.has("xprop -spy -root -notype GAMESCOPE_FOCUSABLE_APPS"), "xprop -spy on the root window")
	ok(s.exit_polling, "polling until the watch reports")
	var w: SpyWatch = x.watches[0]
	w.say("GAMESCOPE_FOCUSABLE_APPS = 769, 976730")
	ok(not s.exit_polling, "the game is listed and watched: no exit polling at all")
	w.say("something else = 1")
	ok(not s.exit_polling, "other lines are ignored")
	w.say("GAMESCOPE_FOCUSABLE_APPS = 769, 976730, 12")
	ok(not s.exit_polling and s.phase == "running", "another window came: still running, still no polling")
	# the game quits: the watch says so at once, one confirming look ends it (as before: twice gone)
	x.root[GamescopeScript.ATOM_FOCUSABLE_APPS] = [769]
	w.say("GAMESCOPE_FOCUSABLE_APPS = 769")
	eq(s.phase, "running", "gone once: not ended yet (a launcher closing before the game's window)")
	ok(s.exit_polling, "the exit check polls to confirm")
	s.poll_exit()
	eq(s.phase, "idle", "gone twice: ended")
	ok(not w.running, "the watch stopped with the session")
	eq(_base(x), [413091, 769], "home")
	s.free()
	g.free()


func test_a_window_back_before_the_confirming_look_keeps_the_game() -> void:
	var x := SpyXprop.new()
	var g = GamescopeScript.new()
	g.runner = x
	g.env = {"GAMESCOPE_WAYLAND_DISPLAY": "gamescope-0", "DISPLAY": ""}
	x.root[GamescopeScript.ATOM_FOCUSABLE_APPS] = [769, 976730]
	var s := _session(g, FakePower.new(), FakeLauncher.new())
	s.begin(STEAM, {"ok": true, "app_id": 976730, "pid": 0})
	s.poll_focus()
	var w: SpyWatch = x.watches[0]
	w.say("GAMESCOPE_FOCUSABLE_APPS = 769")
	w.say("GAMESCOPE_FOCUSABLE_APPS = 769, 976730")
	s.poll_exit()
	eq(s.phase, "running", "back in the list: still running")
	ok(not s.exit_polling, "and no polling again")
	s.stop()
	s.free()
	g.free()


func test_polling_comes_back_when_the_watch_ends() -> void:
	var x := SpyXprop.new()
	var g = GamescopeScript.new()
	g.runner = x
	g.env = {"GAMESCOPE_WAYLAND_DISPLAY": "gamescope-0", "DISPLAY": ""}
	x.root[GamescopeScript.ATOM_FOCUSABLE_APPS] = [769, 976730]
	var s := _session(g, FakePower.new(), FakeLauncher.new())
	s.begin(STEAM, {"ok": true, "app_id": 976730, "pid": 0})
	s.poll_focus()
	var w: SpyWatch = x.watches[0]
	w.say("GAMESCOPE_FOCUSABLE_APPS = 769, 976730")
	ok(not s.exit_polling, "watched")
	w.running = false
	w.on_exit.call()
	ok(s.exit_polling, "xprop -spy died: the 3 s exit check polls again")
	x.root[GamescopeScript.ATOM_FOCUSABLE_APPS] = [769]
	s.poll_exit()
	s.poll_exit()
	eq(s.phase, "idle", "and still notices the end")
	s.free()
	g.free()


func test_spy_lines() -> void:
	eq(GamescopeScript.spy_values("GAMESCOPE_FOCUSABLE_APPS = 769, 5", "GAMESCOPE_FOCUSABLE_APPS"), [769, 5], "values")
	eq(GamescopeScript.spy_values("GAMESCOPE_FOCUSABLE_APPS:  not found.", "GAMESCOPE_FOCUSABLE_APPS"), [], "removed: empty")
	eq(GamescopeScript.spy_values("OTHER = 1", "GAMESCOPE_FOCUSABLE_APPS"), null, "other atoms ignored")
	eq(GamescopeScript.spy_values("", "GAMESCOPE_FOCUSABLE_APPS"), null, "blank ignored")
	var g = GamescopeScript.new()
	g.runner = FakeXprop.new()
	g.env = {"GAMESCOPE_WAYLAND_DISPLAY": "gamescope-0", "DISPLAY": ""}
	eq(g.watch_focusable(func(_a): pass), null, "a runner that can't keep a program running: no watch (GameSession polls)")
	g.free()


func test_a_real_watch_stops_and_is_reaped() -> void:
	var CR := preload("res://scripts/gamescope/command_runner.gd")
	var r = CR.new()
	var w: RefCounted = r.spawn_watch("/bin/sh", PackedStringArray(["-c", "echo a; exec sleep 30"]), func(_l): pass)
	ok(w != null, "started")
	ok(w.alive(), "running")
	var pid: int = w.pid
	w.stop()
	ok(not w.alive(), "stopped")
	ok(not DirAccess.dir_exists_absolute("/proc/%d" % pid), "and reaped: no zombie left")
	w.stop()
	var gone: RefCounted = r.spawn_watch("/nonexistent/xprop", PackedStringArray(), func(_l): pass)
	if gone != null:
		OS.delay_msec(100)
		ok(not gone.alive(), "a missing program ends at once (GameSession polls then)")
		gone.stop()
