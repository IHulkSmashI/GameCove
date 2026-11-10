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
## The Timer runs even while the tree is paused.
##
## Fallback notice: the client leaves crash-fallback ("<unix time>\n<reason>") in the data
## folder when it gave up on GameCove for a boot; the next start shows why, once.

const SettingsFile := preload("res://scripts/system/settings_file.gd")

const BEAT_S := 5.0
const FALLBACK_FILE := "crash-fallback"

## Returns true while a game runs (main.gd: GameSession.is_active).
var game_running: Callable = func() -> bool: return false
var path := ""
var seq := 0
var _timer: Timer


func _init(heartbeat_path := "") -> void:
	path = heartbeat_path if heartbeat_path != "" else OS.get_environment("GAMECOVE_HEARTBEAT")


func _ready() -> void:
	if path == "":
		return
	_timer = Timer.new()
	_timer.wait_time = BEAT_S
	_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	_timer.timeout.connect(beat)
	add_child(_timer)
	_timer.start()
	beat()


func mode() -> String:
	return "game" if game_running.is_valid() and bool(game_running.call()) else "ui"


## One beat: the file replaced in one rename, so the client never reads half a line.
func beat() -> bool:
	if path == "":
		return false
	seq += 1
	return SettingsFile.save_text(path, "%d %s\n" % [seq, mode()]) == OK


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
