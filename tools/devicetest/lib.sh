# shellcheck shell=sh
# Helpers for the device journeys (tools/devicetest/suites/NN-*.sh), on top of the
# hardware checks' own (tools/testbed/checks/lib.sh: results, read-backs, the
# controls CLI, gamescope's display). A suite writes PASS / FAIL / WARN / SKIP /
# INFO / MANUAL lines to $GC_RESULTS like a check, and its evidence (screenshots,
# logs, samples) to $GC_OUT/<suite>/.
#
# Every program goes through a variable (tools/devicetest/test.sh puts stand-ins
# first on PATH and runs everything with DT_DRY=1, so nothing on the machine
# running the tests is touched). A suite always puts back what it changed.

DT_DIR="${DT_DIR:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}"
# shellcheck source=../testbed/checks/lib.sh
. "$DT_DIR/../testbed/checks/lib.sh"

DT_DRY="${DT_DRY:-0}"
DT_STEAM="${DT_STEAM:-steam}"
DT_PYTHON="${DT_PYTHON:-python3}"
DT_FLATPAK="${DT_FLATPAK:-flatpak}"
DT_UPSCALE="${DT_UPSCALE:-/usr/libexec/gamecove/gamecove-upscale}"
# The flags the owner gave (devicetest.sh run --allow-...): space separated words.
DT_ALLOW="${DT_ALLOW:-}"
DT_STEAM_ROOT="${DT_STEAM_ROOT:-$GC_HOME/.local/share/Steam}"

allowed() { case " $DT_ALLOW " in *" $1 "*) return 0 ;; esac; return 1; }

# Runs a command, or (dry run) only says it would.
run() {
	if [ "$DT_DRY" = 1 ]; then
		printf 'dry-run:' >>"$CHECK_OUT/commands.txt"
		printf ' %s' "$@" >>"$CHECK_OUT/commands.txt"
		printf '\n' >>"$CHECK_OUT/commands.txt"
		return 0
	fi
	"$@"
}

# The virtual gamepad (vpad.py): presses, e.g. pad "guide down a".
pad() {
	if [ "$DT_DRY" = 1 ]; then
		"$DT_PYTHON" -I "$DT_DIR/vpad.py" --dry-run seq "$*" >>"$CHECK_OUT/pad.txt" 2>&1
		return 0
	fi
	"$DT_PYTHON" -I "$DT_DIR/vpad.py" seq "$*" >>"$CHECK_OUT/pad.txt" 2>&1
}

# A screenshot of what's on screen (gamescope's own, through its root atom) into the
# evidence folder as <name>.png. 0 when one came.
shot() {
	name="$1"
	if [ "$DT_DRY" = 1 ]; then
		: >"$CHECK_OUT/$name.png"
		return 0
	fi
	d="$(gamescope_display)"
	[ -n "$d" ] || return 1
	before="$(ls -t /tmp/gamescope_*.png 2>/dev/null | head -n 1)"
	DISPLAY="$d" "$GC_XPROP" -root -f GAMESCOPECTRL_REQUEST_SCREENSHOT 32c -set GAMESCOPECTRL_REQUEST_SCREENSHOT 1 2>/dev/null || return 1
	n=0
	while [ "$n" -lt 20 ]; do
		sleep 0.25
		now="$(ls -t /tmp/gamescope_*.png 2>/dev/null | head -n 1)"
		if [ -n "$now" ] && [ "$now" != "$before" ]; then
			sleep 0.5
			cp "$now" "$CHECK_OUT/$name.png" && return 0
		fi
		n=$((n + 1))
	done
	return 1
}

# Waits up to $1 seconds for the command after it to succeed (1 s steps; at once in a dry run).
wait_for() {
	limit="$1"
	shift
	[ "$DT_DRY" = 1 ] && return 0
	n=0
	while [ "$n" -lt "$limit" ]; do
		"$@" && return 0
		sleep 1
		n=$((n + 1))
	done
	return 1
}

# Steam: a steam:// URI handed to the running client.
steam_uri() { run "$DT_STEAM" "$1" >/dev/null 2>&1 & }

# The appmanifest of $1 in any Steam library, or "".
manifest() {
	for lib in "$DT_STEAM_ROOT" $(sed -n 's/.*"path"[[:space:]]*"\(.*\)"/\1/p' "$DT_STEAM_ROOT/steamapps/libraryfolders.vdf" 2>/dev/null); do
		[ -f "$lib/steamapps/appmanifest_$1.acf" ] && { echo "$lib/steamapps/appmanifest_$1.acf"; return 0; }
	done
	echo ""
}

installed() { m="$(manifest "$1")"; [ -n "$m" ] && grep -q '"StateFlags"[[:space:]]*"4"' "$m"; }
not_installed() { [ -z "$(manifest "$1")" ]; }

# The folder a Steam game is installed in, or "".
game_dir() {
	m="$(manifest "$1")"
	[ -n "$m" ] || { echo ""; return 0; }
	d="$(sed -n 's/.*"installdir"[[:space:]]*"\(.*\)"/\1/p' "$m" | head -n 1)"
	echo "$(dirname "$m")/common/$d"
}

# A process whose command line has $1 (pgrep -f).
running_with() { pgrep -u "$(id -u)" -f "$1" >/dev/null 2>&1; }

# GameCove's pid ("" when it isn't running).
gamecove_pid() { pgrep -u "$(id -u)" -f 'gamecove.x86_64' 2>/dev/null | head -n 1; }

# CPU % and RSS MiB of $1 over $2 seconds, as "cpu rss" (from /proc: no tools needed).
proc_sample() {
	pid="$1"
	secs="$2"
	[ -r "/proc/$pid/stat" ] || { echo "-1 -1"; return 0; }
	hz="$(getconf CLK_TCK 2>/dev/null || echo 100)"
	t0="$(awk '{print $14 + $15}' "/proc/$pid/stat")"
	sleep "$secs"
	t1="$(awk '{print $14 + $15}' "/proc/$pid/stat" 2>/dev/null || echo "$t0")"
	rss="$(awk '/^VmRSS:/ {printf "%d", $2 / 1024}' "/proc/$pid/status" 2>/dev/null)"
	awk -v a="$t0" -v b="$t1" -v hz="$hz" -v s="$secs" -v r="${rss:-0}" 'BEGIN { printf "%.2f %d\n", (b - a) / hz / s * 100, r }'
}
