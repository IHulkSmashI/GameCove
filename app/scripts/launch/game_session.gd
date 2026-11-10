extends Node
## The game that is running now: brings it to the front, applies its settings
## while it runs, and puts everything back when it ends.
##
## On begin(): the game's frame limit goes to gamescope and Auto TDP starts if its
## goal wants it. A 0.5 s timer then waits (up to FOCUS_WAIT_S) for the game's
## app id to show up in GAMESCOPE_FOCUSABLE_APPS, i.e. the game has a window,
## and focuses it. Then a slow timer (EXIT_CHECK_S) watches for the end: the app
## id gone from the focusable list and our process gone, twice in a row. On the
## end: home in front, frame limit cleared, Auto TDP stopped.
##
## While the game's window is listed, nothing polls: Gamescope.watch_focusable()
## (`xprop -spy`, one idle child blocked on the X socket) reports every change of
## the list, and the exit timer only runs once the game looks gone (its second look
## confirms the end, as before) or when there is no watch. Polling every
## EXIT_CHECK_S meant a process (sh + xprop) every 3 s behind every game.
##
## Nothing waits: each tick asks Gamescope for one xprop read on its worker
## thread (focusable_apps_async) and handles the answer when it comes back; a
## tick is skipped while the previous read is still out. Focus and frame-limit
## writes go the same way. Timers only run while a game does. Services are
## passed in (the autoloads, or fakes in tests); tests call poll_focus() /
## poll_exit() directly instead of running timers. A Gamescope without the
## async calls (simple fakes) is used synchronously.

const DeviceScript := preload("res://scripts/device/device.gd")
signal started(game: Dictionary)
signal ended(game: Dictionary)

const ExecSafe := preload("res://scripts/system/exec_safe.gd")
const FOCUS_POLL_S := 0.5
const FOCUS_WAIT_S := 60.0
## Past FOCUS_WAIT_S a Steam launch is followed by its process tree (Steam's reaper,
## `reaper SteamLaunch AppId=<id> -- ...`) instead of given up (review S5-1): shader
## pre-caching, a Steam update, an EULA or cloud-sync dialog often take longer. Checked
## this often, and the session ends only after it's gone GONE_TICKS times in a row.
const REAPER_CHECK_S := 3.0
const EXIT_CHECK_S := 3.0
## Ticks in a row the game must look gone before we call it ended (a launcher
## window closing before the game's opens shouldn't send you home).
const GONE_TICKS := 2

var gamescope: Object
var power: Object
var launcher: Object
## The Controls registry (autoload when in the tree; tests set it). While it has
## an available display.fps_limit, Profiles owns the frame limit (it migrates
## the Launcher's per-game value into the game's profile, applies it and puts
## the pre-game value back) and GameSession leaves gamescope's limit alone.
var controls: Object
## func(pid: int) -> bool. Swapped in tests.
var pid_running: Callable = func(pid: int) -> bool: return OS.is_process_running(pid)
## func(app_id: int) -> bool: Steam's launch of this app is still alive (its reaper). Swapped in tests.
var steam_alive: Callable = steam_launch_alive

var game: Dictionary = {}
var app_id := 0
var pid := 0
## "idle" | "waiting" (for the game's window) | "running"
var phase := "idle"
var focused := false
var autotune_on := false

var _waited := 0.0
var _reaper_wait := 0.0
var _reaper_gone := 0
var _seen := false
var _gone := 0
var _focus_timer: Timer
var _exit_timer: Timer
var _reading := false   # a focusable-apps read is out
var _gen := 0           # bumps per session so a late answer can't touch the next one
var _steam_task := -1   # WorkerThreadPool task of a reaper check that's out
var _watch: RefCounted  # Gamescope.watch_focusable() while running, null when polling
## True while the exit check polls (no watch, or the game looks gone): tests read it.
var exit_polling := false
## The reaper check runs on a pool thread (set in _ready; tests outside the tree run it inline).
var threaded_checks := false


func setup(gamescope_svc: Object, power_svc: Object, launcher_svc: Object) -> void:
	gamescope = gamescope_svc
	power = power_svc
	launcher = launcher_svc


func _ready() -> void:
	threaded_checks = true
	_focus_timer = _make_timer(FOCUS_POLL_S, poll_focus)
	_exit_timer = _make_timer(EXIT_CHECK_S, poll_exit)
	if controls == null:
		controls = get_node_or_null("/root/Controls")
	# A frame limit left over from a crash or an earlier session shouldn't cap home.
	if gamescope != null and gamescope.is_running() and not profiles_own_fps():
		_fps_limit(0)


func is_active() -> bool:
	return phase != "idle"


## A game was just started. `launched` is Library.launch()'s result.
func begin(g: Dictionary, launched: Dictionary) -> void:
	if is_active():
		_finish(false)
	if not bool(launched.get("ok", false)):
		return
	game = g
	app_id = int(launched.get("app_id", 0))
	pid = int(launched.get("pid", 0))
	if app_id <= 0 and pid <= 0:
		return   # nothing we can follow (e.g. shell_open with no app id)
	phase = "waiting"
	focused = false
	_gen += 1
	_reading = false
	_waited = 0.0
	_reaper_wait = 0.0
	_reaper_gone = 0
	_seen = false
	_gone = 0
	var key := str(g.get("key", ""))
	var s: Dictionary = launcher.settings_for(key) if launcher != null else {}
	# A stream from a PC (store "stream"): the game's frame rate and power are the
	# PC's business; here only the decoder runs, so no frame limit and no Auto TDP.
	# A desktop app or a clip's player (store "app") isn't a game either.
	var streamed := str(g.get("store", "")) in ["stream", "app"]
	if gamescope != null and gamescope.is_running() and not profiles_own_fps() and not streamed:
		_fps_limit(int(s.get("fps_limit", 0)))
	if power != null and launcher != null and not streamed and launcher.auto_tdp_for(key):
		autotune_on = true
		_power_autotune(true)
	started.emit(game)
	if app_id > 0:
		_start(_focus_timer)
	else:
		_enter_running()


## One look for the game's window. Focuses it once gamescope lists its app id.
func poll_focus() -> void:
	if phase != "waiting":
		_stop(_focus_timer)
		return
	_read_focusable(_on_focus_read)


func _on_focus_read(apps: Array) -> void:
	if phase != "waiting":
		return
	if app_id in apps:
		_seen = true
		_focus_game()
		_enter_running()
		return
	_waited += FOCUS_POLL_S
	if _waited < FOCUS_WAIT_S:
		return
	# Never got a window with our app id. With a process to watch, keep the
	# session going (settings stay applied) and end when it exits.
	if pid > 0 and bool(pid_running.call(pid)):
		_enter_running()
		return
	# A Steam launch: keep waiting for its window (and keep the profile and Auto TDP)
	# while Steam's reaper for it runs; the window gets focus when it appears.
	if pid <= 0 and app_id > 0:
		_reaper_wait += FOCUS_POLL_S
		if _reaper_wait < REAPER_CHECK_S and _waited > FOCUS_WAIT_S:
			return
		_reaper_wait = 0.0
		if threaded_checks:
			# pgrep off the main thread (review L19): the answer comes back to _steam_checked
			if _steam_task < 0:
				var id := app_id
				var gen := _gen
				var fn := steam_alive
				_steam_task = WorkerThreadPool.add_task(func(): _steam_checked.call_deferred(gen, id, bool(fn.call(id))),
					false, "GameSession reaper check")
			return
		_reaper_result(bool(steam_alive.call(app_id)))
		return
	_finish(true)


func _steam_checked(gen: int, id: int, alive: bool) -> void:
	if _steam_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_steam_task)
		_steam_task = -1
	if gen != _gen or id != app_id or phase != "waiting":
		return   # a later session, or the window came meanwhile
	_reaper_result(alive)


func _reaper_result(alive: bool) -> void:
	if alive:
		_reaper_gone = 0
		return
	_reaper_gone += 1
	if _reaper_gone < GONE_TICKS:
		return
	_finish(true)


## True while a process of ours runs Steam's launch of this app: Steam's reaper
## (`reaper SteamLaunch AppId=<id> -- ...`), the same match game_closer.gd uses.
static func steam_launch_alive(id: int) -> bool:
	if id <= 0:
		return false
	var uid := ""
	# /proc files report a size of 0: read to the real end (get_file_as_string() gives "")
	var st := FileAccess.open("/proc/self/status", FileAccess.READ)
	for line in (DeviceScript.read_all(st) if st != null else "").split("\n"):
		if line.begins_with("Uid:"):
			uid = line.substr(4).strip_edges().split("\t", false)[0]
	var args := ["-f", "SteamLaunch AppId=%d( |$)" % id]
	if uid.is_valid_int():
		args = ["-u", uid] + args
	return ExecSafe.run("pgrep", PackedStringArray(args), false)["code"] == 0


## One look for the end of the game.
func poll_exit() -> void:
	if phase != "running":
		_stop(_exit_timer)
		return
	_read_focusable(_on_exit_read)


func _on_exit_read(apps: Array) -> void:
	if phase != "running":
		return
	var listed := app_id > 0 and app_id in apps
	if listed:
		_seen = true
	var alive: bool = listed or (pid > 0 and bool(pid_running.call(pid)))
	# the watch tells us when the window goes; poll only without it or once it went
	_set_exit_polling(not (listed and _watch != null and _watch.alive()))
	if alive:
		_gone = 0
		return
	_gone += 1
	if _gone >= GONE_TICKS:
		_finish(true)


## Ends the session now (e.g. the app is closing).
func stop() -> void:
	if is_active():
		_finish(true)


## Puts GameCove in front of the running game (Guide pressed in a game).
## The game keeps running; return_to_game() brings it back.
func bring_home() -> bool:
	if not is_active() or gamescope == null or not gamescope.is_running():
		return false
	_focus_home()
	focused = false
	return true


## Gives the screen back to the running game. False when it isn't known to
## gamescope yet (still launching) or nothing runs. The switch itself happens
## on Gamescope's worker; `focused` turns false if xprop fails.
func return_to_game() -> bool:
	if phase != "running" or app_id <= 0 or gamescope == null or not gamescope.is_running():
		return false
	focused = true
	_focus_game()
	return focused


## True when Profiles applies the frame limit (Controls has display.fps_limit).
func profiles_own_fps() -> bool:
	if controls == null or not controls.has_method("has") or not controls.has("display.fps_limit"):
		return false
	var c: Object = controls.control("display.fps_limit")
	return c != null and bool(c.available)


func runs(key: String) -> bool:
	return is_active() and str(game.get("key", "")) == key


func _enter_running() -> void:
	phase = "running"
	_gone = 0
	_stop(_focus_timer)
	_set_exit_polling(true)
	_start_watch()


func _set_exit_polling(on: bool) -> void:
	exit_polling = on
	if on:
		_start(_exit_timer)
	else:
		_stop(_exit_timer)


## The focusable list's watch for this session (its first report comes at once).
func _start_watch() -> void:
	if _watch != null or app_id <= 0 or gamescope == null or not gamescope.has_method("watch_focusable"):
		return
	var gen := _gen
	_watch = gamescope.watch_focusable(func(apps: Array) -> void:
		if gen == _gen:
			_on_exit_read(apps),
		func() -> void:
			if gen == _gen:
				_stop_watch()   # joins its reader thread
				if phase == "running":
					_set_exit_polling(true))


func _stop_watch() -> void:
	if _watch != null:
		var w := _watch
		_watch = null
		w.stop()


func _exit_tree() -> void:
	_stop_watch()
	if _steam_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_steam_task)
		_steam_task = -1


func _finish(go_home: bool) -> void:
	var g := game
	_stop(_focus_timer)
	_stop(_exit_timer)
	exit_polling = false
	_stop_watch()
	phase = "idle"
	_gen += 1
	_reading = false
	if autotune_on and power != null:
		_power_autotune(false)
	autotune_on = false
	if gamescope != null and gamescope.is_running():
		if not profiles_own_fps():
			_fps_limit(0)
		if go_home:
			_focus_home()
	game = {}
	app_id = 0
	pid = 0
	focused = false
	ended.emit(g)


## One read of gamescope's focusable app list; `cb(apps)` on the main thread.
## Skipped while the last read is still out.
func _read_focusable(cb: Callable) -> void:
	if gamescope == null or not gamescope.is_running():
		cb.call([])
		return
	if not gamescope.has_method("focusable_apps_async"):
		cb.call(gamescope.focusable_apps())
		return
	if _reading:
		return
	_reading = true
	var gen := _gen
	gamescope.focusable_apps_async(func(apps: Array) -> void:
		if gen != _gen:
			return
		_reading = false
		cb.call(apps))


func _focus_game() -> void:
	if not gamescope.has_method("focus_app_async"):
		focused = gamescope.focus_app(app_id)
		return
	focused = true
	var gen := _gen
	gamescope.focus_app_async(app_id, func(ok: bool) -> void:
		if gen == _gen and not ok:
			focused = false)


func _focus_home() -> void:
	if gamescope.has_method("focus_home_async"):
		gamescope.focus_home_async()
	else:
		gamescope.focus_home()


func _fps_limit(fps: int) -> void:
	if gamescope.has_method("set_fps_limit_async"):
		gamescope.set_fps_limit_async(fps)
	else:
		gamescope.set_fps_limit(fps)


## Auto TDP on or off through Power's worker (it runs busctl). Start and stop
## share one job there, so a quick start-then-stop never leaves it on.
func _power_autotune(on: bool) -> void:
	if power.has_method("request_autotune"):
		# the game's key: Power keeps what Auto TDP learned per game and power source
		power.request_autotune(on, str(game.get("key", "")))
	elif on:
		power.autotune_start()
	else:
		power.autotune_stop()


func _make_timer(wait: float, cb: Callable) -> Timer:
	var t := Timer.new()
	t.wait_time = wait
	t.timeout.connect(cb)
	add_child(t)
	return t


func _start(t: Timer) -> void:
	if t != null and t.is_inside_tree() and t.is_stopped():
		t.start()


func _stop(t: Timer) -> void:
	if t != null and t.is_inside_tree():
		t.stop()
