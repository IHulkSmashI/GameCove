extends Node
## Closes the running game when the quick menu's "Exit game" asks. Never
## blocks: every step is a fire-and-forget process, and the hard kill waits
## on a timer. GameSession notices the game is gone on its own exit check
## and emits `ended` as usual.
##
## How, by kind of game:
##   Steam game:  Steam has no URI to close a game (there is no
##                steam://close/), so we stop Steam's launch wrapper for that
##                app the way Steam's own "Stop" does: the reaper process
##                (`reaper SteamLaunch AppId=<appid> -- ...`), found with
##                `pgrep -u <our uid> -f "SteamLaunch AppId=<appid>( |$)"`, and
##                everything under it (its process group when it leads one,
##                and every descendant: pressure-vessel, wine, the game). Only
##                our own user's processes, only that exact app id.
##                After GRACE_S, the same with KILL.
##                The same for a non-Steam shortcut Steam started (an emulated
##                game Steam ROM Manager added: `shortcut` true, its id is the
##                shortcut's app id): Steam wraps it in the same reaper, and no
##                scope of ours exists for it.
##   Our scoped games (umu / store launchers started in an
##                app-steam-app<id>-<n>.scope): `systemctl --user stop
##                app-steam-app<id>-*.scope`, which signals the whole scope.
##   Unscoped process: TERM its process group (when it leads one) and every
##                descendant, then KILL after GRACE_S if alive.
## A group is only signalled when its leader is the process itself, so Steam's
## or GameCove's own group is never hit.

const GRACE_S := 5.0

## sh -c script: $1 signal, $2 "steam" or "pid", $3 app id or pid. The kill
## command is $GC_KILL (tests put a recorder there), else kill.
const KILL_SCRIPT := """sig="$1"; mode="$2"; arg="$3"
k="${GC_KILL:-kill}"
case "$arg" in ''|*[!0-9]*) exit 2 ;; esac
tree() {
	for c in $(pgrep -P "$1" 2>/dev/null); do tree "$c"; done
	$k -"$sig" "$1" 2>/dev/null
}
group_or_tree() {
	g="$(ps -o pgid= -p "$1" 2>/dev/null | tr -d ' ')"
	[ "$g" = "$1" ] && $k -"$sig" -- "-$1" 2>/dev/null
	tree "$1"
}
if [ "$mode" = steam ]; then
	for p in $(pgrep -u "$(id -u)" -f "SteamLaunch AppId=$arg( |$)" 2>/dev/null); do group_or_tree "$p"; done
else
	group_or_tree "$arg"
fi
exit 0"""

## func(cmd: Array) -> int (pid or -1). Swapped in tests.
var run: Callable = func(cmd: Array) -> int: return OS.create_process(str(cmd[0]), PackedStringArray(cmd.slice(1)))
## func(pid: int) -> bool. Swapped in tests.
var alive: Callable = func(pid: int) -> bool: return pid > 0 and OS.is_process_running(pid)


static func _kill(sig: String, mode: String, arg: String) -> Array:
	return ["sh", "-c", KILL_SCRIPT, "gamecove-close", sig, mode, arg]


## [first commands, commands for after GRACE_S] to close `game`.
## app_id: gamescope's id (Steam appid or our scope's id); pid: our process or 0.
static func plan(game: Dictionary, app_id: int, pid: int) -> Array:
	var now: Array = []
	var later: Array = []
	# Steam's own games, and non-Steam shortcuts Steam starts (Steam ROM Manager's
	# emulated games: store "emu", shortcut true, id = the shortcut's app id). Steam
	# wraps both in the same reaper, so both stop the same way. Keyed on `shortcut`,
	# not on the store: an "emu" game we start ourselves has our scope or pid.
	if str(game.get("store", "")) == "steam" or game.get("shortcut", false) == true:
		var appid := str(game.get("id", app_id))
		if not preload("res://scripts/steam/app_id.gd").valid(appid):
			return [now, later]
		now.append(_kill("TERM", "steam", appid))
		later.append(_kill("KILL", "steam", appid))
		return [now, later]
	if app_id > 0:
		now.append(["systemctl", "--user", "stop", "app-steam-app%d-*.scope" % app_id])
	if pid > 0:
		now.append(_kill("TERM", "pid", str(pid)))
		later.append(_kill("KILL", "pid", str(pid)))
	return [now, later]


## Starts closing what `session` runs. Returns false when nothing runs.
func close(session: Object) -> bool:
	if session == null or not session.is_active():
		return false
	var p := plan(session.game, int(session.app_id), int(session.pid))
	for cmd in p[0]:
		run.call(cmd)
	var later: Array = p[1]
	var pid := int(session.pid)
	if later.is_empty():
		return true
	if not is_inside_tree():
		return true
	# each close carries its own forced step (a second close, e.g. of a cancelled
	# launch whose game showed up late, must not lose or cut short the first one's)
	get_tree().create_timer(GRACE_S).timeout.connect(_hard.bind(session, pid, later))
	return true


## After the grace period: force it, unless it's already gone.
func _hard(session: Object, pid: int, cmds: Array) -> void:
	if (is_instance_valid(session) and session.is_active()) or alive.call(pid):
		for cmd in cmds:
			run.call(cmd)
