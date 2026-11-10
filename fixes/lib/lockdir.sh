# shellcheck shell=sh
# Shared lock for the fixes (sourced): a directory under /run, made atomically with mkdir, with the
# holder's PID inside (review L3). /run is emptied at boot, but a run killed with SIGKILL has no
# chance to remove its lock, and the fix then refused every call until the next reboot. Now a lock
# whose holder is gone is broken and taken over.
#
# lockdir_take <dir> <tries>   0 once taken; 1 after <tries> one-second waits for a live holder
# lockdir_drop <dir>           releases it (only call after lockdir_take succeeded)

# lockdir_stale <dir>: the holder named in <dir>/pid no longer runs, or (a lock from before PIDs were
# recorded, or a holder killed between mkdir and writing its PID) there is no PID after a minute.
lockdir_stale() {
	_lp="$(cat "$1/pid" 2>/dev/null || true)"
	case "$_lp" in
	'') [ -n "$(find "$1" -maxdepth 0 -mmin +1 2>/dev/null)" ] ;;
	*[!0-9]*) return 1 ;;
	*) [ ! -d "/proc/$_lp" ] ;;
	esac
}

# lockdir_break <dir> <judged pid>: 1 when another breaker is busy; removes the lock only while it still names the holder that was
# judged dead (review L3 follow-up). Every breaker first takes <dir>.break (mkdir, held for a moment), then
# re-reads the PID: a waiter that judged the old holder dead but was overtaken by another waiter that broke
# the lock and took it never removes the new holder's lock. A <dir>.break left by a breaker killed in that
# moment is cleared after a minute.
lockdir_break() {
	if ! mkdir "$1.break" 2>/dev/null; then
		[ -z "$(find "$1.break" -maxdepth 0 -mmin +1 2>/dev/null)" ] || rmdir "$1.break" 2>/dev/null || true
		return 1
	fi
	if [ "$(cat "$1/pid" 2>/dev/null || true)" = "$2" ] && lockdir_stale "$1"; then
		rm -f "$1/pid"
		rmdir "$1" 2>/dev/null || true
	fi
	rmdir "$1.break" 2>/dev/null || true
	return 0
}

lockdir_take() {
	_ln=0
	while ! mkdir "$1" 2>/dev/null; do
		if lockdir_stale "$1"; then
			printf 'gamecove: breaking a stale lock %s (its holder is gone)\n' "$1" >&2
			lockdir_break "$1" "$_lp" || sleep 1
		else
			sleep 1
		fi
		_ln=$((_ln + 1))
		[ "$_ln" -lt "$2" ] || return 1
	done
	printf '%s\n' "$$" >"$1/pid"
}

lockdir_drop() {
	rm -f "$1/pid"
	rmdir "$1" 2>/dev/null || true
}
