# shellcheck shell=sh
# Shared by the prompt-free fixes whose changes wear something out (sourced; needs ROOT set).
#
# rate_take <name> <max> <seconds>   0, and counts one change, when fewer than <max> changes were
#                                     counted in the last <seconds>; 1 (nothing counted) otherwise.
#
# Review L4: any local process in the active session can call gamecove-fix-set without a password,
# so a loop alternating controller-rumble values rewrote the controller's flash on every call, and a
# loop of claw8ex-gyro accel-on/accel-off restarted InputPlumber on every call. Callers count only real
# changes (an unchanged value is a no-op before this is asked). The count lives in /run (tmpfs), so the
# bookkeeping itself never writes to flash, and it starts empty after a reboot.
rate_take() {
	_rf="$ROOT/run/gamecove/rate-$1"
	_now="$(date +%s)"
	mkdir -p "${_rf%/*}" 2>/dev/null || true
	_keep="$(awk -v now="$_now" -v w="$3" '$1 ~ /^[0-9]+$/ && $1 > now - w' "$_rf" 2>/dev/null || true)"
	_n=0
	[ -z "$_keep" ] || _n="$(printf '%s\n' "$_keep" | wc -l | tr -d ' ')"
	[ "$_n" -lt "$2" ] || return 1
	{
		[ -z "$_keep" ] || printf '%s\n' "$_keep"
		printf '%s\n' "$_now"
	} >"$_rf.tmp" 2>/dev/null && mv -f "$_rf.tmp" "$_rf" 2>/dev/null
	return 0
}
