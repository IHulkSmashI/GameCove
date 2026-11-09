# shellcheck shell=sh
# Shared by every fix that keeps a changes.log (sourced).
#
# log_cap <file>   keeps a log from growing without bound (review L1): once it is over
#                  GAMECOVE_LOG_MAX bytes (256 KiB by default) it becomes <file>.1, replacing
#                  the previous one, and the next line starts a new file. Every prompt-free
#                  call appends a line, so without this the logs grow for as long as the
#                  handheld is used. Never fails the caller.
log_cap() {
	_max="${GAMECOVE_LOG_MAX:-262144}"
	case "$_max" in '' | *[!0-9]* | 0?*) _max=262144 ;; esac
	[ -f "$1" ] || return 0
	_size="$(wc -c <"$1" 2>/dev/null | tr -d ' ')"
	case "$_size" in '' | *[!0-9]*) return 0 ;; esac
	[ "$_size" -le "$_max" ] || mv -f "$1" "$1.1" 2>/dev/null || true
	return 0
}
