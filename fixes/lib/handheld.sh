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

handheld_id() {
	[ -f "$HANDHELDS" ] || return 1
	while IFS= read -r line; do
		case "$line" in ''|'#'*) continue ;; esac
		if _row_ok "$line"; then
			printf '%s\n' "${line%%	*}"
			return 0
		fi
	done < "$HANDHELDS"
	return 1
}

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
