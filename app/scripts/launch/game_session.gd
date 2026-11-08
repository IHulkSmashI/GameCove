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
## Nothing waits: each tick is one short xprop read. Timers only run while a game
## does. Services are passed in (the autoloads, or fakes in tests); tests call
## poll_focus() / poll_exit() directly instead of running timers.

signal started(game: Dictionary)
signal ended(game: Dictionary)

const FOCUS_POLL_S := 0.5
const FOCUS_WAIT_S := 60.0
const EXIT_CHECK_S := 3.0
## Ticks in a row the game must look gone before we call it ended (a launcher
## window closing before the game's opens shouldn't send you home).
const GONE_TICKS := 2
const POWER_JOB := "game_autotune"

var gamescope: Object
var power: Object
var launcher: Object
## func(pid: int) -> bool. Swapped in tests.
var pid_running: Callable = func(pid: int) -> bool: return OS.is_process_running(pid)

var game: Dictionary = {}
var app_id := 0
var pid := 0
## "idle" | "waiting" (for the game's window) | "running"
var phase := "idle"
var focused := false
var autotune_on := false

var _waited := 0.0
var _seen := false
var _gone := 0
var _focus_timer: Timer
var _exit_timer: Timer


func setup(gamescope_svc: Object, power_svc: Object, launcher_svc: Object) -> void:
	gamescope = gamescope_svc
	power = power_svc
	launcher = launcher_svc


func _ready() -> void:
	_focus_timer = _make_timer(FOCUS_POLL_S, poll_focus)
	_exit_timer = _make_timer(EXIT_CHECK_S, poll_exit)
	# A frame limit left over from a crash or an earlier session shouldn't cap home.
	if gamescope != null and gamescope.is_running():
		gamescope.set_fps_limit(0)


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
	_waited = 0.0
	_seen = false
	_gone = 0
	var key := str(g.get("key", ""))
	var s: Dictionary = launcher.settings_for(key) if launcher != null else {}
	if gamescope != null and gamescope.is_running():
		gamescope.set_fps_limit(int(s.get("fps_limit", 0)))
	if power != null and launcher != null and launcher.auto_tdp_for(key):
		autotune_on = true
		_power_job(power.autotune_start)
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
	if app_id in _focusable():
		_seen = true
		focused = gamescope.focus_app(app_id)
		_enter_running()
		return
	_waited += FOCUS_POLL_S
	if _waited < FOCUS_WAIT_S:
		return
	# Never got a window with our app id. With a process to watch, keep the
	# session going (settings stay applied) and end when it exits; otherwise
	# (a Steam launch that never came up) give up now.
	if pid > 0 and bool(pid_running.call(pid)):
		_enter_running()
	else:
		_finish(true)


## One look for the end of the game.
func poll_exit() -> void:
	if phase != "running":
		_stop(_exit_timer)
		return
	var listed := app_id > 0 and app_id in _focusable()
	if listed:
		_seen = true
	var alive: bool = listed or (pid > 0 and bool(pid_running.call(pid)))
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


func _enter_running() -> void:
	phase = "running"
	_gone = 0
	_stop(_focus_timer)
	_start(_exit_timer)


func _finish(go_home: bool) -> void:
	var g := game
	_stop(_focus_timer)
	_stop(_exit_timer)
	phase = "idle"
	if autotune_on and power != null:
		_power_job(power.autotune_stop)
	autotune_on = false
	if gamescope != null and gamescope.is_running():
		gamescope.set_fps_limit(0)
		if go_home:
			gamescope.focus_home()
	game = {}
	app_id = 0
	pid = 0
	focused = false
	ended.emit(g)


func _focusable() -> Array:
	if gamescope == null or not gamescope.is_running():
		return []
	return gamescope.focusable_apps()


## Power's autotune_start does busctl on the caller's thread, so it goes through
## Power's worker queue when there is one. Start and stop share one job name:
## the newest wins, so a quick start-then-stop never leaves Auto TDP on.
func _power_job(job: Callable) -> void:
	if power.has_method("_queue"):
		power._queue(POWER_JOB, func(): job.call(); return true)
	else:
		job.call()


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
