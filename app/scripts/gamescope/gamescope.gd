extends Node
## Talks to gamescope: frame limit, refresh rate, overlay focus. Owner: session
## agent. See docs/SESSION.md for the why.
##
## Gamescope takes orders through X11 window properties ("atoms"): on the root
## window for global settings, on our own window for focus and overlay. We set
## them with the stock `xprop` tool, the same properties OpenGamepadUI sets
## through its gamescope-x11-client crate (GPL-3.0). Every call goes through
## `runner`, so tests use fake output and never touch a real display.
##
## Each xprop call takes a few milliseconds, so anything that runs while the UI
## is up uses the *_async variants: the command runs on the runner's worker
## thread and the callback comes back on the main thread. The plain versions
## stay for tests and one-off checks. A fake runner without run_async() runs
## the async variants synchronously (callback before they return).

const CommandRunner := preload("res://scripts/gamescope/command_runner.gd")

## Gamescope treats the window whose STEAM_GAME is 769 as the main launcher
## (normally Steam's). Hard-coded in gamescope; see gamescope-x11-client.
const MAIN_APP_ID := 769
## Steam always puts this id first in the base-layer list; OpenGamepadUI copies it.
const EXTRA_UNKNOWN_GAME_ID := 413091

# Root-window atoms (read by gamescope's steamcompmgr.cpp).
const ATOM_FPS_LIMIT := "GAMESCOPE_FPS_LIMIT"
const ATOM_DYNAMIC_REFRESH := "GAMESCOPE_DYNAMIC_REFRESH"
const ATOM_BASELAYER_APPID := "GAMESCOPECTRL_BASELAYER_APPID"
const ATOM_FOCUSABLE_APPS := "GAMESCOPE_FOCUSABLE_APPS"
const ATOM_FOCUSED_APP := "GAMESCOPE_FOCUSED_APP"
# Per-window atoms, set on our own window.
const ATOM_STEAM_GAME := "STEAM_GAME"
const ATOM_STEAM_OVERLAY := "STEAM_OVERLAY"
const ATOM_STEAM_INPUT_FOCUS := "STEAM_INPUT_FOCUS"

const XPROP := "xprop"
const MAX_FPS := 1000
const MAX_HZ := 1000

## Swap for a fake in tests: any object with run(program, args) -> {"exit", "output"}.
var runner = CommandRunner.new()
## Environment overrides for tests; a key here wins over the real environment.
var env: Dictionary = {}
## Our X11 window id. 0 means "look it up from the display server".
var window_id := 0

var _running := -1   # -1 unknown, 0 no, 1 yes (cached: gamescope can't appear mid-session)


func _ready() -> void:
	if is_running():
		claim_main_window_async.call_deferred()


func _exit_tree() -> void:
	if runner != null and runner.has_method("shutdown"):
		runner.shutdown()


## True when we run inside a gamescope session. Cheap after the first call.
func is_running() -> bool:
	if _running == -1:
		_running = 1 if _detect_running() else 0
	return _running == 1


## Caps the frame rate gamescope shows. 0 removes the cap. True once read back.
func set_fps_limit(fps: int) -> bool:
	if fps < 0 or fps > MAX_FPS or not is_running():
		return false
	if not _set_root(ATOM_FPS_LIMIT, [fps]):
		return false
	return read_root(ATOM_FPS_LIMIT) == [fps]


## Asks gamescope to drive the panel at this rate while a game has focus.
## 0 goes back to the panel's top rate. Only works on panels where gamescope
## knows the valid rates (e.g. CUSTOM_REFRESH_RATES) and VRR is off.
func set_refresh_rate(hz: int) -> bool:
	if hz < 0 or hz > MAX_HZ or not is_running():
		return false
	if not _set_root(ATOM_DYNAMIC_REFRESH, [hz]):
		return false
	return read_root(ATOM_DYNAMIC_REFRESH) == [hz]


## Marks our window as the overlay on top of the running game (quick menu open).
## Closed: the game is shown again and gets the controller back.
func set_overlay(open: bool) -> void:
	if not is_running():
		return
	var wid := _window()
	if wid == 0:
		return
	var v := 1 if open else 0
	# Fire and forget: the quick menu opens without waiting on xprop.
	_run_async(set_args(wid, ATOM_STEAM_OVERLAY, [v]), Callable())
	_run_async(set_args(wid, ATOM_STEAM_INPUT_FOCUS, [v]), Callable())


## Tells gamescope our window is the main launcher (what Steam's window is in
## Steam's own session) and brings it to the front. Called once at start.
func claim_main_window() -> bool:
	var wid := _window()
	if wid == 0:
		return false
	var ok := _set_window(wid, ATOM_STEAM_GAME, [MAIN_APP_ID])
	return focus_home() and ok


## Shows the home screen even while a game is running.
func focus_home() -> bool:
	return _set_root(ATOM_BASELAYER_APPID, [EXTRA_UNKNOWN_GAME_ID, MAIN_APP_ID])


## Brings a running game (gamescope app id, e.g. its Steam app id) to the front.
func focus_app(app_id: int) -> bool:
	if app_id <= 0:
		return false
	return _set_root(ATOM_BASELAYER_APPID, [EXTRA_UNKNOWN_GAME_ID, app_id, MAIN_APP_ID])


## App ids gamescope can put in front right now (each has a mapped window).
## Our home screen (769) is always among them under gamescope. [] if unknown.
func focusable_apps() -> Array:
	return read_root(ATOM_FOCUSABLE_APPS)


## App id gamescope has in front now (MAIN_APP_ID means our home screen), 0 if unknown.
func focused_app() -> int:
	var v := read_root(ATOM_FOCUSED_APP)
	return v[0] if v.size() > 0 else 0


# --- Async variants (the command runs off the main thread) ---

## done(values: Array) with read_root()'s result, on the main thread.
func read_root_async(atom: String, done: Callable) -> void:
	_run_async(get_args(atom), func(r: Dictionary) -> void:
		done.call(parse_values(str(r.get("output", "")), atom) if int(r.get("exit", -1)) == 0 else []))


## done(apps: Array): like focusable_apps(). [] outside gamescope.
func focusable_apps_async(done: Callable) -> void:
	if not is_running():
		done.call([])
		return
	read_root_async(ATOM_FOCUSABLE_APPS, done)


## done(app_id: int): like focused_app(). 0 outside gamescope or when unknown.
func focused_app_async(done: Callable) -> void:
	if not is_running():
		done.call(0)
		return
	read_root_async(ATOM_FOCUSED_APP, func(v: Array) -> void: done.call(v[0] if v.size() > 0 else 0))


## done(ok: bool) optional. Like focus_home().
func focus_home_async(done := Callable()) -> void:
	_set_root_async(ATOM_BASELAYER_APPID, [EXTRA_UNKNOWN_GAME_ID, MAIN_APP_ID], done)


## done(ok: bool) optional. Like focus_app().
func focus_app_async(app_id: int, done := Callable()) -> void:
	if app_id <= 0:
		_reply(done, false)
		return
	_set_root_async(ATOM_BASELAYER_APPID, [EXTRA_UNKNOWN_GAME_ID, app_id, MAIN_APP_ID], done)


## done(ok: bool) optional. Like set_fps_limit(): true once read back.
func set_fps_limit_async(fps: int, done := Callable()) -> void:
	_set_checked_async(ATOM_FPS_LIMIT, fps, MAX_FPS, done)


## done(ok: bool) optional. Like set_refresh_rate().
func set_refresh_rate_async(hz: int, done := Callable()) -> void:
	_set_checked_async(ATOM_DYNAMIC_REFRESH, hz, MAX_HZ, done)


## Like claim_main_window(), without waiting.
func claim_main_window_async() -> void:
	var wid := _window()
	if wid == 0:
		return
	_run_async(set_args(wid, ATOM_STEAM_GAME, [MAIN_APP_ID]), Callable())
	focus_home_async()


## Values of a CARDINAL atom on the root window; [] if it isn't set.
func read_root(atom: String) -> Array:
	var r: Dictionary = runner.run(XPROP, get_args(atom))
	if int(r.get("exit", -1)) != 0:
		return []
	return parse_values(str(r.get("output", "")), atom)


# --- Command construction (static so tests can check it directly) ---

## xprop arguments that set a 32-bit CARDINAL atom. target is "root" or a window id.
static func set_args(target, atom: String, values: Array) -> PackedStringArray:
	var vals := PackedStringArray()
	for v in values:
		vals.append(str(int(v)))
	var a := _target_args(target)
	a.append_array(PackedStringArray(["-f", atom, "32c", "-set", atom, ",".join(vals)]))
	return a


static func get_args(atom: String, target = "root") -> PackedStringArray:
	var a := _target_args(target)
	a.append_array(PackedStringArray(["-notype", atom]))
	return a


## Parses `xprop -notype` output like "ATOM = 413091, 769". [] when not set.
static func parse_values(output: String, atom: String) -> Array:
	for line in output.split("\n"):
		var l := line.strip_edges()
		if not l.begins_with(atom + " = "):
			continue
		var out := []
		for part in l.substr(atom.length() + 3).split(","):
			var p := part.strip_edges()
			if not p.is_valid_int():
				return []
			out.append(p.to_int())
		return out
	return []


static func _target_args(target) -> PackedStringArray:
	if typeof(target) == TYPE_STRING and target == "root":
		return PackedStringArray(["-root"])
	return PackedStringArray(["-id", "0x%x" % int(target)])


# --- Internals ---

func _set_root(atom: String, values: Array) -> bool:
	var r: Dictionary = runner.run(XPROP, set_args("root", atom, values))
	return int(r.get("exit", -1)) == 0


func _set_window(wid: int, atom: String, values: Array) -> bool:
	var r: Dictionary = runner.run(XPROP, set_args(wid, atom, values))
	return int(r.get("exit", -1)) == 0


## Runs xprop on the runner's worker when it has one, else right here.
func _run_async(args: PackedStringArray, done: Callable) -> void:
	if runner.has_method("run_async"):
		runner.run_async(XPROP, args, done)
		return
	var r: Dictionary = runner.run(XPROP, args)
	if done.is_valid():
		done.call(r)


func _set_root_async(atom: String, values: Array, done: Callable) -> void:
	_run_async(set_args("root", atom, values), func(r: Dictionary) -> void:
		_reply(done, int(r.get("exit", -1)) == 0))


## Set a one-value root atom, then read it back (both queued, in order).
func _set_checked_async(atom: String, value: int, max_value: int, done: Callable) -> void:
	if value < 0 or value > max_value or not is_running():
		_reply(done, false)
		return
	var set_ok := [false]
	_run_async(set_args("root", atom, [value]), func(r: Dictionary) -> void:
		set_ok[0] = int(r.get("exit", -1)) == 0)
	read_root_async(atom, func(v: Array) -> void: _reply(done, set_ok[0] and v == [value]))


static func _reply(done: Callable, v) -> void:
	if done.is_valid():
		done.call(v)


func _env(name: String) -> String:
	return str(env[name]) if env.has(name) else OS.get_environment(name)


func _detect_running() -> bool:
	# gamescope-session-plus exports this once gamescope answers on its socket.
	if _env("GAMESCOPE_WAYLAND_DISPLAY") != "":
		return true
	# Started some other way: gamescope always publishes this list on its root window.
	if _env("DISPLAY") == "":
		return false
	var r: Dictionary = runner.run(XPROP, get_args(ATOM_FOCUSABLE_APPS))
	return int(r.get("exit", -1)) == 0 and str(r.get("output", "")).begins_with(ATOM_FOCUSABLE_APPS + " = ")


func _window() -> int:
	if window_id == 0 and DisplayServer.get_name() == "X11":
		window_id = DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE)
	return window_id
