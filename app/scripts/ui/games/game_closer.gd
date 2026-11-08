extends Node
## Closes the running game when the quick menu's "Exit game" asks. Never
## blocks: every step is a fire-and-forget process, and the hard kill waits
## on a timer. GameSession notices the game is gone on its own exit check
## and emits `ended` as usual.
##
## How, by kind of game:
##   Steam game:  Steam has no URI to close a game (there is no
##                steam://close/), so we stop Steam's launch wrapper for that
##                app: `pkill -TERM -f "AppId=<appid>"` matches the reaper
##                process (`reaper SteamLaunch AppId=<appid> -- ...`), which
##                takes the game down with it, as Steam's own "Stop" does.
##                After GRACE_S, the same with -KILL.
##   Our scoped games (umu / store launchers started in an
##                app-steam-app<id>-<n>.scope): `systemctl --user stop
##                app-steam-app<id>-*.scope`, which signals the whole scope.
##   Unscoped process: SIGTERM the pid, then SIGKILL after GRACE_S if alive.

const GRACE_S := 5.0

## func(cmd: Array) -> int (pid or -1). Swapped in tests.
var run: Callable = func(cmd: Array) -> int: return OS.create_process(str(cmd[0]), PackedStringArray(cmd.slice(1)))
## func(pid: int) -> bool. Swapped in tests.
var alive: Callable = func(pid: int) -> bool: return pid > 0 and OS.is_process_running(pid)
var _pending: Array = []


## [first commands, commands for after GRACE_S] to close `game`.
## app_id: gamescope's id (Steam appid or our scope's id); pid: our process or 0.
static func plan(game: Dictionary, app_id: int, pid: int) -> Array:
	var now: Array = []
	var later: Array = []
	if str(game.get("store", "")) == "steam":
		var appid := str(game.get("id", app_id))
		now.append(["pkill", "-TERM", "-f", "AppId=%s( |$)" % appid])
		later.append(["pkill", "-KILL", "-f", "AppId=%s( |$)" % appid])
		return [now, later]
	if app_id > 0:
		now.append(["systemctl", "--user", "stop", "app-steam-app%d-*.scope" % app_id])
	if pid > 0:
		now.append(["kill", "-TERM", str(pid)])
		later.append(["kill", "-KILL", str(pid)])
	return [now, later]


## Starts closing what `session` runs. Returns false when nothing runs.
func close(session: Object) -> bool:
	if session == null or not session.is_active():
		return false
	var p := plan(session.game, int(session.app_id), int(session.pid))
	for cmd in p[0]:
		run.call(cmd)
	_pending = p[1]
	var pid := int(session.pid)
	if _pending.is_empty():
		return true
	if not is_inside_tree():
		return true
	get_tree().create_timer(GRACE_S).timeout.connect(_hard.bind(session, pid))
	return true


## After the grace period: force it, unless it's already gone.
func _hard(session: Object, pid: int) -> void:
	if (is_instance_valid(session) and session.is_active()) or alive.call(pid):
		for cmd in _pending:
			run.call(cmd)
	_pending = []
