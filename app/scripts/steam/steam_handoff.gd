extends Node
## The trip to Steam's controller settings and back (steam://controllerconfig/<id>,
## ui/controls/steam_input.gd), under gamescope.
##
## Steam shows that screen in a window of its own. Gamescope lists every window
## that can take focus as [window, app id, pid] in GAMESCOPE_FOCUSABLE_WINDOWS and
## puts one in front when GAMESCOPECTRL_BASELAYER_WINDOW names it (steam_focus.gd);
## removing the property gives the screen back to whoever had it (GameCove's
## home, or the running game).
##
##   start(game)   "opening": the URI goes to Steam and we look for its window
##                 every POLL_S, for at most WAIT_S. A window Steam didn't have
##                 before wins; after NEW_WINDOW_S any Steam window will do (in
##                 its handheld mode Steam shows the screen in the window it
##                 already has). No window in time: finished("timeout").
##   "away"        Steam's window is in front. We keep looking: when that window
##                 is gone (B out of Steam's screen closes it) we come back.
##                 back() does the same on Guide.
##   "returning"   the property is removed; arrived() (our window has focus
##                 again, or RETURN_S at most) ends it: finished(why).
##
## Only one Timer, and only while a trip is under way (the user started it).
## Nothing here blocks: every xprop goes through Gamescope's worker.

signal started
## Steam's screen is in front.
signal left
## Over: "closed" (Steam's screen went away) | "guide" | "cancelled" (B while
## still opening) | "timeout" | "failed" (the URI couldn't be handed over).
signal finished(why: String)

const SteamFocus := preload("res://scripts/steam/steam_focus.gd")
const SteamInput := preload("res://scripts/ui/controls/steam_input.gd")
const GamescopeScript := preload("res://scripts/gamescope/gamescope.gd")
const SteamConfig := preload("res://scripts/steam/steam_config.gd")
const SteamStore := preload("res://scripts/library/stores/steam.gd")

const POLL_S := 0.4
## How long Steam gets to show its screen.
const WAIT_S := 8.0
## How long we hold out for a new window before taking one Steam already had.
const NEW_WINDOW_S := 1.6
## Longest wait for our window to get focus back.
const RETURN_S := 1.5
## A read of the windows that has not answered after this many polls is given up on (the next poll asks again),
## and a trip still "opening" this long after WAIT_S ends whatever the reads did: the pad is never held for ever.
const STUCK_POLLS := 8
const HARD_WAIT_S := WAIT_S + 3.0

## The Gamescope service (autoload), or a fake.
var gamescope: Object
## func(uri: String) -> bool.
var open_uri: Callable = func(uri: String) -> bool: return SteamStore.open_uri(uri, SteamStore.steam_bin())
## func() -> bool: the Steam client runs.
var steam_running: Callable = func() -> bool: return SteamConfig.is_running(OS.get_environment("HOME"))
## func(triples: Array) -> Dictionary pid -> process name (tests swap it).
var comm_of: Callable = func(triples: Array) -> Dictionary: return SteamFocus.comms(triples)
var own_pid := OS.get_process_id()

## "idle" | "opening" | "away" | "returning"
var state := "idle"
var game: Dictionary = {}
var window := 0
var _why := ""
var _before: Array = []
var _waited := 0.0
var _gen := 0
var _reading := false
var _reading_polls := 0
var _timer: Timer


func active() -> bool:
	return state != "idle"


## Starts the trip. "" = under way; "direct" = no gamescope: the URI was handed
## to Steam and that's all there is to do; "none" = this game has no Steam
## controller settings; "no_steam" = Steam isn't running; "failed" = Steam didn't
## take the URI; "busy" = a trip is already under way.
func start(for_game: Dictionary) -> String:
	if active():
		return "busy"
	var uri := SteamInput.uri_for(for_game)
	if uri == "":
		return "none"
	if gamescope == null or not gamescope.is_running():
		return "direct" if bool(open_uri.call(uri)) else "failed"
	if not bool(steam_running.call()):
		return "no_steam"
	game = for_game
	state = "opening"
	window = 0
	_why = ""
	_waited = 0.0
	_gen += 1
	_reading = false
	var gen := _gen
	started.emit()
	# the timer runs from the start: it is what ends a trip whose first read never answers
	_run_timer(true)
	# what Steam shows already, so its new window can be told apart; then the URI
	_read(func(triples: Array) -> void:
		if gen != _gen or state != "opening":
			return
		_before = _steam_windows(triples)
		if not bool(open_uri.call(uri)):
			_end("failed")
			return)
	return ""


## Guide, or B while Steam's screen hasn't shown yet: come back now.
func back(why := "guide") -> void:
	if state == "opening":
		_end(why)
	elif state == "away":
		_return(why)


## Our window has focus again (main.gd's focus-in): the trip is over.
func arrived() -> void:
	if state == "returning":
		_end(_why)


func _steam_windows(triples: Array) -> Array:
	var comms: Dictionary = comm_of.call(triples)
	var out: Array = []
	var i := 0
	while i + 2 < triples.size():
		if int(triples[i + 2]) != own_pid and str(comms.get(int(triples[i + 2]), "")).strip_edges() in SteamFocus.STEAM_PROCESSES:
			out.append(int(triples[i]))
		i += 3
	return out


func _read(done: Callable) -> void:
	if gamescope.has_method("read_root_async"):
		gamescope.read_root_async(SteamFocus.ATOM_FOCUSABLE_WINDOWS, done)
	else:
		done.call(gamescope.read_root(SteamFocus.ATOM_FOCUSABLE_WINDOWS))


func _xprop(args: PackedStringArray) -> void:
	if gamescope.has_method("_run_async"):
		gamescope._run_async(args, Callable())


## One look (the Timer's tick; tests call it).
func poll() -> void:
	if state == "idle":
		_run_timer(false)
		return
	_waited += POLL_S
	if state == "returning":
		if _waited >= RETURN_S:
			_end(_why)   # focus never came back by itself: carry on anyway, never hang
		return
	if state == "opening" and _waited >= HARD_WAIT_S:
		_end("timeout")   # no read answered in time: Steam's screen never showed, as far as we can tell
		return
	if _reading:
		_reading_polls += 1
		if _reading_polls < STUCK_POLLS:
			return
		_reading = false   # that read is lost; ask again
	_reading_polls = 0
	_reading = true
	var gen := _gen
	_read(func(triples: Array) -> void:
		if gen != _gen:
			return
		_reading = false
		_on_windows(_steam_windows(triples)))


func _on_windows(now: Array) -> void:
	if state == "opening":
		var fresh := now.filter(func(w): return not w in _before)
		var pick := 0
		if not fresh.is_empty():
			pick = int(fresh[-1])
		elif _waited >= NEW_WINDOW_S and not now.is_empty():
			pick = int(now[-1])
		if pick != 0:
			window = pick
			state = "away"
			_xprop(SteamFocus.focus_args(pick))
			left.emit()
		elif _waited >= WAIT_S:
			_end("timeout")
	elif state == "away":
		if not window in now:
			_return("closed")


func _return(why: String) -> void:
	_why = why
	state = "returning"
	_waited = 0.0
	_xprop(SteamFocus.release_args())


func _end(why: String) -> void:
	var was := state
	state = "idle"
	_gen += 1
	_reading = false
	_reading_polls = 0
	_run_timer(false)
	if was == "away":
		_xprop(SteamFocus.release_args())
	window = 0
	game = {}
	finished.emit(why)


func _run_timer(on: bool) -> void:
	if not is_inside_tree():
		return
	if _timer == null:
		_timer = Timer.new()
		_timer.wait_time = POLL_S
		_timer.timeout.connect(poll)
		add_child(_timer)
	if on:
		_timer.start()
	else:
		_timer.stop()


func _exit_tree() -> void:
	if state == "away" and gamescope != null and gamescope.has_method("read_root"):
		_xprop(SteamFocus.release_args())   # never leave Steam's window forced in front
