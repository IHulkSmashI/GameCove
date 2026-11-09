# shellcheck shell=sh
# Shared by the fan and charge-limit fixes (sourced; needs ROOT set).
#
# handheld_ok      0 when /sys/class/dmi/id matches a row of handhelds.txt (the
#                  handhelds in devices.json that use these fixes). MSI and ASUS
#                  laptops share the same fan and battery drivers, so the fixes
#                  never write anything on hardware that isn't on that list.
# handheld_id      prints the matching row's id ("" when none)
# fix_lock <name>  one run of this fix at a time ($ROOT/run/gamecove-<name>.lock);
#                  removed on exit. Waits up to 30 s, then fails.

HANDHELDS="$(cd "$(dirname "$0")/../lib" && pwd)/handhelds.txt"

_dmi() {
	# lower case, outer spaces trimmed; fails when the file is missing
	[ -f "$ROOT/sys/class/dmi/id/$1" ] || return 1
	tr '[:upper:]' '[:lower:]' < "$ROOT/sys/class/dmi/id/$1" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# _row_ok "<id>\t<key>=<pat>|<pat>\t..."
_row_ok() {
	rest="${1#*	}"
	[ "$rest" != "$1" ] || return 1
	compared=0
	while [ -n "$rest" ]; do
		field="${rest%%	*}"
		if [ "$field" = "$rest" ]; then rest=""; else rest="${rest#*	}"; fi
		key="${field%%=*}"
		pats="$(printf '%s' "${field#*=}" | tr '[:upper:]' '[:lower:]')"
		case "$key" in
			sys_vendor|product_name|board_name|board_vendor|product_family) ;;
			*) return 1 ;;
		esac
		value="$(_dmi "$key")" || return 1
		[ -n "$value" ] || return 1
		hit=1
		old_ifs="$IFS"
		IFS='|'
		set -f
		for p in $pats; do
			# shellcheck disable=SC2254  # the pattern is a glob on purpose
			case "$value" in $p) hit=0; break ;; esac
		done
		set +f
		IFS="$old_ifs"
		[ "$hit" -eq 0 ] || return 1
		compared=$((compared + 1))
	done
	[ "$compared" -gt 0 ]
}

# A subshell: _row_ok's working variables (key, value, rest, line...) must never
# leak into the fix that sourced this (power-tune printed "board_name=28" after a
# handheld check had clobbered its own $key).
handheld_id() (
	[ -f "$HANDHELDS" ] || return 1
	while IFS= read -r line; do
		case "$line" in ''|'#'*) continue ;; esac
		if _row_ok "$line"; then
			printf '%s\n' "${line%%	*}"
			return 0
		fi
	done < "$HANDHELDS"
	return 1
)

handheld_ok() {
	handheld_id >/dev/null
}

fix_lock() {
	FIX_LOCK="$ROOT/run/gamecove-$1.lock"
	mkdir -p "$ROOT/run" 2>/dev/null || true
	n=0
	while ! mkdir "$FIX_LOCK" 2>/dev/null; do
		n=$((n + 1))
		[ "$n" -lt 30 ] || { printf '%s: another run is busy (%s)\n' "$1" "$FIX_LOCK" >&2; FIX_LOCK=""; exit 1; }
		sleep 1
	done
}

fix_unlock() {
	[ -z "${FIX_LOCK:-}" ] || rmdir "$FIX_LOCK" 2>/dev/null || true
	FIX_LOCK=""
}

# ---- per-device saved state ------------------------------------------------------------------------------
# One drive can boot several handhelds. A fix's saved originals (fan tables, charge limit) belong to the
# handheld they were read on, so <dir>/device names that handheld; another handheld's files are parked in
# <dir>/devices/<id>/ and come back when that handheld runs the fix again. Without this, `remove` on a ROG
# Ally would write back values read on a Claw.
STATE_FILES="original limit"

# Root (or a test root): only then is /var/lib/gamecove writable.
can_write_state() { [ -n "$ROOT" ] || [ "$(id -u)" -eq 0 ]; }

state_owner() { cat "$1/device" 2>/dev/null || true; }

# state_mine <dir>: 0 when what <dir> holds (if anything) is this handheld's. Read-only (for status).
state_mine() {
	_o="$(state_owner "$1")"
	[ -z "$_o" ] || [ "$_o" = "$(handheld_id)" ]
}

# state_file <dir> <name>: where this handheld's <name> is now (parked while another handheld owns <dir>).
state_file() {
	if state_mine "$1"; then printf '%s/%s\n' "$1" "$2"; else printf '%s/devices/%s/%s\n' "$1" "$(handheld_id)" "$2"; fi
}

# state_switch <dir> [legacy-check]: make <dir> hold this handheld's state (root only; install/set/remove).
# State saved before this existed has no owner: it is taken as this handheld's when <legacy-check> (a
# command) succeeds or none is given, else parked as "unknown".
state_switch() {
	_d="$1"
	_cur="$(handheld_id)" || return 0
	_o="$(state_owner "$_d")"
	[ "$_o" = "$_cur" ] && return 0
	if [ -z "$_o" ] && [ -f "$_d/original" ]; then
		if [ -z "${2:-}" ] || "$2"; then
			printf '%s\n' "$_cur" > "$_d/device"
			return 0
		fi
		_o=unknown
	fi
	if [ -n "$_o" ]; then
		mkdir -p "$_d/devices/$_o"
		for _f in $STATE_FILES; do
			if [ -f "$_d/$_f" ]; then mv -f "$_d/$_f" "$_d/devices/$_o/$_f"; fi
		done
	fi
	if [ -d "$_d/devices/$_cur" ]; then
		for _f in $STATE_FILES; do
			if [ -f "$_d/devices/$_cur/$_f" ]; then mv -f "$_d/devices/$_cur/$_f" "$_d/$_f"; fi
		done
		rmdir "$_d/devices/$_cur" 2>/dev/null || true
		rmdir "$_d/devices" 2>/dev/null || true
	fi
	mkdir -p "$_d"
	printf '%s\n' "$_cur" > "$_d/device"
}
