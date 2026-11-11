extends Node
## Tells session/gamecove-session-client that GameCove's main loop is alive (review H1), and
## tells the user why GameCove didn't start last time (review L31).
##
## Heartbeat: when the client sets GAMECOVE_HEARTBEAT (a file in $XDG_RUNTIME_DIR), a Timer on
## the main loop rewrites it every BEAT_S seconds with "<sequence> <ui|game>". The client
## kills an app whose file stops changing for 30 s while it says "ui" (a deadlock, a black
## window) and counts it as a crash. While a game runs it says "game" and the client never
## kills it: the main loop keeps beating behind a game, but a slow game load or gamescope
## holding back frames to a hidden window must never end the session (and the game with it).
## The Timer runs even while the tree is paused. Behind a game it writes nothing: once the
## file says "game" the client never counts it stale, so a beat is written only when the
## mode changes (the game ended: "ui" within BEAT_S), never every 5 s to a tmpfs file.
##
## "front" (final review, session): a game is running but GameCove's own UI holds the screen
## and the controller again (the quick menu is open, or Home was brought back with Guide).
## A deadlock there used to say "game" for good, so nothing ever ended it and the only way
## out was holding the power button. In "front" the file beats every BEAT_S like "ui" and
## the client stops a GameCove whose beats stop (GAMECOVE_HEARTBEAT_FRONT_STALE_S, 45 s).
## It only starts once the game has had the screen: while a game is still starting (our
## window keeps the focus until the game's own window shows) the mode stays "game", so a slow
## launch is never taken for a hang. The change is written at once, not at the next tick.
##
## Fallback notice: the client leaves crash-fallback ("<unix time>\n<reason>") in the data
## folder when it gave up on GameCove for a boot; the next start shows why, once.

const SettingsFile := preload("res://scripts/system/settings_file.gd")

const BEAT_S := 5.0
const FALLBACK_FILE := "crash-fallback"

## Returns true while a game runs (main.gd: GameSession.is_active).
var game_running: Callable = func() -> bool: return false
## Returns true while GameCove's UI is what the user sees and steers (its window has the focus
## or the quick menu is open). Set by watch_background(); never true without it.
var ui_front: Callable = func() -> bool: return false
## The running game has had the screen at least once (see "front" above).
var _game_had_screen := false
var path := ""
var seq := 0
## The mode the file says now ("" before the first beat).
var written_mode := ""
var _timer: Timer


func _init(heartbeat_path := "") -> void:
	path = heartbeat_path if heartbeat_path != "" else OS.get_environment("GAMECOVE_HEARTBEAT")


func _ready() -> void:
	if path == "":
		return
	_timer = Timer.new()
	_timer.wait_time = BEAT_S
	_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	_timer.timeout.connect(tick)
	add_child(_timer)
	_timer.start()
	beat()


## Beats at once when a game starts or ends (review 2, low 13): the mode must not wait for
## the next Timer tick, or a stall right after a launch reads as a hang in "ui".
## `session` has started(game) and ended(game) signals (GameSession).
func watch_session(session: Object) -> void:
	for sig in ["started", "ended"]:
		if session != null and session.has_signal(sig) and not session.is_connected(sig, _on_game_change):
			session.connect(sig, _on_game_change)


func _on_game_change(_game: Dictionary) -> void:
	_game_had_screen = false   # a new game hasn't shown yet; after a game there is none
	beat()


## `background` is main.gd's BackgroundMode: it knows whether our window or the quick menu is
## in front, and says when that changes (front_changed).
func watch_background(background: Object) -> void:
	if background == null or not background.has_method("in_background"):
		return
	ui_front = func() -> bool: return is_instance_valid(background) and not background.in_background()
	if background.has_signal("front_changed") and not background.is_connected("front_changed", _on_front_changed):
		background.connect("front_changed", _on_front_changed)


func _on_front_changed(in_front: bool) -> void:
	if not (game_running.is_valid() and bool(game_running.call())):
		return
	if not in_front:
		_game_had_screen = true
	if mode() != written_mode:
		beat()


func mode() -> String:
	if not (game_running.is_valid() and bool(game_running.call())):
		return "ui"
	if _game_had_screen and ui_front.is_valid() and bool(ui_front.call()):
		return "front"
	return "game"


## The Timer's beat: skipped while the file already says "game" and a game still runs.
func tick() -> bool:
	if written_mode == "game" and mode() == "game":
		return false
	return beat()


## One beat: the file replaced in one rename, so the client never reads half a line.
func beat() -> bool:
	if path == "":
		return false
	seq += 1
	var m := mode()
	if SettingsFile.save_text(path, "%d %s\n" % [seq, m]) != OK:
		return false
	written_mode = m
	return true


## $XDG_DATA_HOME/gamecove (the session client's data folder).
static func data_dir() -> String:
	var d := OS.get_environment("XDG_DATA_HOME")
	if d == "":
		var home := OS.get_environment("HOME")
		if home == "":
			return ""
		d = home.path_join(".local/share")
	return d.path_join("gamecove")


## The reason the client left GameCove last time, read once (the file is removed): "" when
## there's nothing to say.
static func take_fallback_notice(dir: String) -> String:
	if dir == "":
		return ""
	var p := dir.path_join(FALLBACK_FILE)
	if not FileAccess.file_exists(p):
		return ""
	var lines := FileAccess.get_file_as_string(p).split("\n")
	DirAccess.remove_absolute(p)
	var reason := lines[1].strip_edges() if lines.size() > 1 else ""
	return notice_text(reason)


static func notice_text(reason: String) -> String:
	match reason:
		"hung":
			return "GameCove stopped responding 3 times in a row, so Steam started instead last time."
		"missing":
			return "GameCove's files were missing, so Steam started instead last time. Run GameCove Installer and choose Repair if this happens again."
		"unsaved":
			return "GameCove closed unexpectedly and couldn't save to your home folder (is it full?), so Steam started instead last time."
		_:
			return "GameCove closed unexpectedly 3 times in a row, so Steam started instead last time."
