extends RefCounted
## What has to happen around a running game, in one place (main.gd calls it
## from GameSession.started / ended and from window focus changes):
##   started: PerfMonitor.start(app id, frame limit, frame-gen multiplier),
##            the frame limit being the game's profile's (display.fps_limit) when
##            Profiles owns it, and followed while the game runs, so Auto TDP's
##            target and "can't reach" never work from an older value,
##            Updates.set_game_running(true), Controller.start_game(key),
##            Discover.pause() (no background refresh while you play),
##            Library.set_background_paused(true) (no metadata / art fill either)
##   ended:   PerfMonitor.stop(), Achievements.invalidate(appid) (Steam just
##            wrote new stats), Updates.set_game_running(false),
##            Controller.end_game(), Discover.resume(), Library.set_background_paused(false)
##   home in front of a running game: PerfMonitor.set_focused(false)
##   who has the controller: Controller.set_game_focused(game in front and no
##            quick menu over it), sent again on every change (InputPlumber
##            moves itself from Pass to Always when Guide is pressed, so the
##            last mode we sent can't be trusted). With no game, any other
##            window in front (Steam's install dialog, a login prompt) gets the
##            controller the same way (review M15).
## Services are passed in (autoloads, or fakes in tests); any may be missing.

var perf: Object
var achievements: Object
var updates: Object
var controller: Object
var discover: Object
var launcher: Object
var library: Object
var controls: Object
var profiles: Object
var game: Dictionary = {}
var running := false
var _front := true       # GameCove's window has focus (it has at start)
var _menu := false       # the quick menu is open over the game
var _away := false       # Steam's own screen is in front (ui/steam_trip.gd): the pad is Steam's
var _other_sent := false # no game: we last told the Controller another window is in front


func setup(svc: Dictionary) -> void:
	perf = svc.get("perf")
	achievements = svc.get("achievements")
	updates = svc.get("updates")
	controller = svc.get("controller")
	discover = svc.get("discover")
	launcher = svc.get("launcher")
	library = svc.get("library")
	controls = svc.get("controls")
	profiles = svc.get("profiles")
	if controls != null and controls.has_signal("control_changed"):
		controls.control_changed.connect(_on_control_changed)


const FPS_ID := "display.fps_limit"


## True while Profiles owns the frame limit (as GameSession.profiles_own_fps).
func _profiles_own_fps() -> bool:
	if profiles == null or controls == null or not controls.has_method("has") or not controls.has(FPS_ID):
		return false
	var c: Object = controls.control(FPS_ID) if controls.has_method("control") else null
	return c != null and bool(c.get("available"))


## The frame limit the game runs with: its profile's when Profiles owns it.
func frame_limit_for(key: String, settings: Dictionary) -> int:
	if _profiles_own_fps() and profiles.has_method("effective"):
		var v: Variant = profiles.effective(key).get(FPS_ID)
		if v is int or v is float:
			return int(v)
	return int(settings.get("fps_limit", 0))


func _on_control_changed(id: String, v: Variant) -> void:
	if running and id == FPS_ID and (v is int or v is float):
		_call(perf, "set_target_fps", [float(v)])


## PerfMonitor.start options from the game's settings.
static func perf_opts(settings: Dictionary) -> Dictionary:
	return {"target_fps": int(settings.get("fps_limit", 0)), "frame_gen_multiplier": 2.0 if settings.get("frame_gen", false) else 1.0}


## Tells the perf controls which game runs: changes to its upscaler files wait
## until it has quit (review M7).
func _upscale_running(key: String) -> void:
	if controls == null or not ("ctx" in controls):
		return
	var f: Variant = (controls.get("ctx") as Dictionary).get("upscale_running") if controls.get("ctx") is Dictionary else null
	if f is Callable and (f as Callable).is_valid():
		(f as Callable).call(key)
		if key == "" and controls.has_method("detect_all"):
			controls.detect_all()     # a change that waited for the game to quit is made now (on the worker)


static func _call(o: Object, method: String, args: Array = []) -> void:
	if o != null and o.has_method(method):
		o.callv(method, args)


func game_started(g: Dictionary, app_id: int) -> void:
	game = g
	running = true
	_menu = false
	var key := str(g.get("key", ""))
	var s: Dictionary = launcher.settings_for(key) if launcher != null and launcher.has_method("settings_for") else {}
	var opts := perf_opts(s)
	opts["target_fps"] = frame_limit_for(key, s)
	_call(perf, "start", [app_id, opts])
	_call(updates, "set_game_running", [true])
	_call(controller, "start_game", [key])
	_upscale_running(key)
	_call(discover, "pause")
	_call(library, "set_background_paused", [true])


func game_ended(g: Dictionary) -> void:
	running = false
	game = {}
	_call(perf, "stop")
	if str(g.get("store", "")) == "steam":
		_call(achievements, "invalidate", [str(g.get("id", ""))])
	_call(updates, "set_game_running", [false])
	_call(controller, "end_game")
	_call(discover, "resume")
	_upscale_running("")
	_call(library, "set_background_paused", [false])
	_other_sent = false   # end_game put our UI in charge; the next focus change says otherwise


## GameCove's window gained (true) or lost (false) focus while a game runs.
func home_in_front(front: bool) -> void:
	_front = front
	if running:
		_call(perf, "set_focused", [not front])
	sync_focus()


## The quick menu opened (true) or closed (false). Over a running game it
## takes the controller while it is open.
func menu_over_game(open: bool) -> void:
	_menu = open
	sync_focus()


## Tells the Controller again who has focus (also after a special button:
## InputPlumber may have switched modes by itself). While a game runs, every
## time. With no game, when another window comes in front or goes (review M15:
## Steam's dialogs got no pad input while GameCove kept Always).
func sync_focus() -> void:
	if running:
		_call(controller, "set_game_focused", [game_focused()])
		return
	var other := other_window_focused()
	if other != _other_sent:
		_other_sent = other
		_call(controller, "set_game_focused", [other])


## Steam's controller settings screen came in front (true) or went (false). While
## it's there the controller is Steam's, whatever our window's focus says.
func set_away(away: bool) -> void:
	_away = away
	sync_focus()


func game_focused() -> bool:
	return running and (_away or not (_front or _menu))


## No game, and a window that isn't GameCove's has focus (the quick menu means ours does).
func other_window_focused() -> bool:
	return not running and (_away or not (_front or _menu))
