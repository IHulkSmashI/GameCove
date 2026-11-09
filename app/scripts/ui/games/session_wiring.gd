extends RefCounted
## What has to happen around a running game, in one place (main.gd calls it
## from GameSession.started / ended and from window focus changes):
##   started: PerfMonitor.start(app id, frame limit, frame-gen multiplier),
##            Updates.set_game_running(true), Controller.start_game(key),
##            Discover.pause() (no background refresh while you play)
##   ended:   PerfMonitor.stop(), Achievements.invalidate(appid) (Steam just
##            wrote new stats), Updates.set_game_running(false),
##            Controller.end_game(), Discover.resume()
##   home in front of a running game: PerfMonitor.set_focused(false)
##   who has the controller: Controller.set_game_focused(game in front and no
##            quick menu over it), sent again on every change (InputPlumber
##            moves itself from Pass to Always when Guide is pressed, so the
##            last mode we sent can't be trusted)
## Services are passed in (autoloads, or fakes in tests); any may be missing.

var perf: Object
var achievements: Object
var updates: Object
var controller: Object
var discover: Object
var launcher: Object
var game: Dictionary = {}
var running := false
var _front := false      # GameCove's window has focus
var _menu := false       # the quick menu is open over the game


func setup(svc: Dictionary) -> void:
	perf = svc.get("perf")
	achievements = svc.get("achievements")
	updates = svc.get("updates")
	controller = svc.get("controller")
	discover = svc.get("discover")
	launcher = svc.get("launcher")


## PerfMonitor.start options from the game's settings.
static func perf_opts(settings: Dictionary) -> Dictionary:
	return {"target_fps": int(settings.get("fps_limit", 0)), "frame_gen_multiplier": 2.0 if settings.get("frame_gen", false) else 1.0}


static func _call(o: Object, method: String, args: Array = []) -> void:
	if o != null and o.has_method(method):
		o.callv(method, args)


func game_started(g: Dictionary, app_id: int) -> void:
	game = g
	running = true
	_menu = false
	var key := str(g.get("key", ""))
	var s: Dictionary = launcher.settings_for(key) if launcher != null and launcher.has_method("settings_for") else {}
	_call(perf, "start", [app_id, perf_opts(s)])
	_call(updates, "set_game_running", [true])
	_call(controller, "start_game", [key])
	_call(discover, "pause")


func game_ended(g: Dictionary) -> void:
	running = false
	game = {}
	_call(perf, "stop")
	if str(g.get("store", "")) == "steam":
		_call(achievements, "invalidate", [str(g.get("id", ""))])
	_call(updates, "set_game_running", [false])
	_call(controller, "end_game")
	_call(discover, "resume")


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
## InputPlumber may have switched modes by itself). Only while a game runs;
## with no game Controller.end_game already put our UI in charge.
func sync_focus() -> void:
	if running:
		_call(controller, "set_game_focused", [game_focused()])


func game_focused() -> bool:
	return running and not (_front or _menu)
