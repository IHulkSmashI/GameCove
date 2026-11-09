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

# lockdir_break <dir>: moves the stale lock aside in one atomic rename, so two waiters can't both
# remove it; if what was moved isn't the stale lock any more (someone took it in between), it goes back.
lockdir_break() {
	_lp="$(cat "$1/pid" 2>/dev/null || true)"
	_aside="$1.stale.$$"
	mv "$1" "$_aside" 2>/dev/null || return 0
	if [ "$(cat "$_aside/pid" 2>/dev/null || true)" = "$_lp" ]; then
		rm -f "$_aside/pid"
		rmdir "$_aside" 2>/dev/null || true
	else
		mv "$_aside" "$1" 2>/dev/null || true
	fi
	return 0
}

lockdir_take() {
	_ln=0
	while ! mkdir "$1" 2>/dev/null; do
		if lockdir_stale "$1"; then
			printf 'gamecove: breaking a stale lock %s (its holder is gone)\n' "$1" >&2
			lockdir_break "$1"
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
