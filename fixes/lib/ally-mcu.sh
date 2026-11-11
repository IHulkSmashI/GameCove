# shellcheck shell=sh
# ROG Ally controller MCU power saving is only safe with new enough MCU firmware (review S1-3).
# Sourced by fixes/ally-mcu-powersave/fix.sh and fixes/power-tune/fix.sh (mcu:on). Needs ROOT and
# the caller's $0 in fixes/<name>/.
#
# Older firmware can leave the controller dead after waking (kernel hid-asus warns: "The MCU firmware
# version must be %d or greater to avoid issues with suspend"; ROG_ALLY_MIN_MCU 319, ROG_ALLY_X_MIN_MCU 313,
# and at or above them validate_mcu_fw_version() calls set_ally_mcu_powersave(true) itself, so those are the
# thresholds; SimpleDeckyTDP's "314" for the Ally X is in commented-out code). The version is read over hidraw by
# ally-mcu-powersave/mcu_version.py (root), cached in /var/lib/gamecove/ally-mcu-version so `status`
# (no root) can say why it isn't available.

ALLY_MCU_CACHE="$ROOT/var/lib/gamecove/ally-mcu-version"
ALLY_MCU_PY="$(cd "$(dirname "$0")/.." && pwd)/ally-mcu-powersave/mcu_version.py"

# model=, version=, min= or error= lines; fresh as root, else the cached answer ("" if none).
ally_mcu_info() {
	if [ -n "$ROOT" ] && [ -n "${GAMECOVE_TEST_MCU_INFO:-}" ]; then
		cat "$GAMECOVE_TEST_MCU_INFO" 2>/dev/null || true # tests: a fake answer, only with a fake root
		return 0
	fi
	if [ "$(id -u)" -eq 0 ] && [ -z "$ROOT" ]; then
		if command -v python3 >/dev/null 2>&1 && [ -f "$ALLY_MCU_PY" ]; then
			_out="$(python3 -I "$ALLY_MCU_PY" 2>/dev/null || true)"
		else
			_out="error=python3 isn't installed, so the MCU firmware version can't be read"
		fi
		[ -n "$_out" ] || _out="error=couldn't read the MCU firmware version"
		mkdir -p "$(dirname "$ALLY_MCU_CACHE")" 2>/dev/null &&
			printf '%s\n' "$_out" >"$ALLY_MCU_CACHE" 2>/dev/null || true
		printf '%s\n' "$_out"
		return 0
	fi
	cat "$ALLY_MCU_CACHE" 2>/dev/null || true
}

# ally_mcu_blocked [strict]: prints why MCU power saving can't be turned on and returns 0; returns 1
# when it may. Without "strict" an unknown version (no root, nothing cached) doesn't block: the
# root install checks again before writing anything.
ally_mcu_blocked() {
	_info="$(ally_mcu_info)"
	_v="$(printf '%s\n' "$_info" | sed -n 's/^version=\([0-9][0-9]*\)$/\1/p' | head -n 1)"
	_min="$(printf '%s\n' "$_info" | sed -n 's/^min=\([0-9][0-9]*\)$/\1/p' | head -n 1)"
	if [ -z "$_v" ] || [ -z "$_min" ]; then
		_err="$(printf '%s\n' "$_info" | sed -n 's/^error=//p' | head -n 1)"
		if [ -z "$_info" ] && [ "${1:-}" != strict ]; then
			return 1
		fi
		printf 'not available: the controller MCU firmware version is unknown (%s); update it in Armoury Crate (Windows) first\n' "${_err:-not checked}"
		return 0
	fi
	if [ "$_v" -lt "$_min" ]; then
		printf 'not available: controller MCU firmware %s is older than %s and may not wake after sleep; update it in Armoury Crate (Windows) first\n' "$_v" "$_min"
		return 0
	fi
	return 1
}
