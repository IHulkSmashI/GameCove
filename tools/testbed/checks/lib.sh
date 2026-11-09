# shellcheck shell=sh
# Shared helpers for the hardware checks (tools/testbed/checks/NN-*.sh). Sourced by each
# check; `gamecove-testbed.sh check` runs them. A check writes one line per result to
# $GC_RESULTS (tab-separated):
#
#   PASS|FAIL|WARN|SKIP|INFO|MANUAL <tab> <check>.<item> <tab> <message>
#
# MANUAL lines are steps for the owner's hands or eyes (press a button, look at the screen,
# feel the rumble); Claude asks for them and writes the answer with `testbed note`.
# Read-backs go to $GC_OUT/<check>/ (before/after values, command output).
#
# Every system path is read through $GC_ROOT (empty on the handheld, a fixture tree in
# tools/testbed/test.sh) and every program through a variable below, so the checks run in
# tests without touching the machine. Nothing here prints secrets: no serials (DMI
# product_serial / board_serial are never read), MAC addresses, account names or tokens.

GC_ROOT="${GC_ROOT:-}"
GC_RESULTS="${GC_RESULTS:-/dev/stdout}"
GC_OUT="${GC_OUT:-${TMPDIR:-/tmp}/gamecove-checks}"
GC_HOME="${GC_HOME:-$HOME}"
GC_APP="${GC_APP:-/usr/lib/gamecove/gamecove.x86_64}"
GC_FIX="${GC_FIX:-/usr/libexec/gamecove/gamecove-fix}"
GC_FIXSET="${GC_FIXSET:-/usr/libexec/gamecove/gamecove-fix-set}"
GC_PKEXEC="${GC_PKEXEC:-pkexec}"
GC_BUSCTL="${GC_BUSCTL:-busctl}"
GC_SYSTEMCTL="${GC_SYSTEMCTL:-systemctl}"
GC_STEAMOSCTL="${GC_STEAMOSCTL:-steamosctl}"
GC_XPROP="${GC_XPROP:-xprop}"
GC_JOURNALCTL="${GC_JOURNALCTL:-journalctl}"
GC_SELFTEST="${GC_SELFTEST:-gamecove-selftest}"
# shellcheck disable=SC2034  # used by the checks that source this
GC_DATA="$GC_HOME/.local/share/gamecove"
CHECK="${CHECK:-$(basename "$0" .sh | sed 's/^[0-9]*-//')}"
CHECK_OUT="$GC_OUT/$CHECK"
mkdir -p "$CHECK_OUT"

_res() { printf '%s\t%s.%s\t%s\n' "$1" "$CHECK" "$2" "$(printf '%s' "$3" | tr '\t\n' '  ')" >>"$GC_RESULTS"; }
pass() { _res PASS "$1" "$2"; }
fail() { _res FAIL "$1" "$2"; }
warn() { _res WARN "$1" "$2"; }
skip() { _res SKIP "$1" "$2"; }
info() { _res INFO "$1" "$2"; }
manual() { _res MANUAL "$1" "$2"; }

have() { command -v "$1" >/dev/null 2>&1; }
# One file's first line, trailing space removed ("" when missing).
rd() { head -n 1 "$GC_ROOT$1" 2>/dev/null | sed 's/[[:space:]]*$//'; }
exists() { [ -e "$GC_ROOT$1" ]; }

dmi() { rd "/sys/class/dmi/id/$1"; }
os_field() { sed -n "s/^$1=//p" "$GC_ROOT/etc/os-release" 2>/dev/null | tr -d '"' | head -n 1; }
os_id() { i="$(os_field ID)"; printf '%s' "${i:-unknown}"; }

# claw8ex | ally | legiongos | other: the three test devices, from DMI.
device_kind() {
	case "$(dmi sys_vendor)|$(dmi board_name)|$(dmi product_name)" in
	Micro-Star*"|MS-1T91|"*) echo claw8ex ;;
	ASUSTeK*"|RC71L|"*) echo ally ;;
	LENOVO*"|"*"|83L3" | LENOVO*"|"*"|83Q2" | LENOVO*"|"*"|83N6" | LENOVO*"|"*"|83Q3") echo legiongos ;;
	*) echo other ;;
	esac
}

# Saves a set of sysfs values (name=value per line) to $CHECK_OUT/<label>.txt.
# Usage: snap <label> <path>... (globs are expanded by the caller).
snap() {
	label="$1"
	shift
	for p in "$@"; do
		[ -r "$p" ] || continue
		printf '%s=%s\n' "${p#"$GC_ROOT"}" "$(head -c 200 "$p" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
	done >"$CHECK_OUT/$label.txt"
}

# The power, display and controller nodes GameCove's controls touch (for before/after).
power_nodes() {
	r="$GC_ROOT"
	for p in "$r"/sys/class/firmware-attributes/*/attributes/ppt_*/current_value \
		"$r"/sys/class/firmware-attributes/*/attributes/mcu_powersave/current_value \
		"$r"/sys/firmware/acpi/platform_profile "$r"/sys/class/platform-profile/*/profile \
		"$r"/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference \
		"$r"/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor \
		"$r"/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq \
		"$r"/sys/devices/system/cpu/intel_pstate/no_turbo "$r"/sys/devices/system/cpu/intel_pstate/max_perf_pct \
		"$r"/sys/devices/system/cpu/cpufreq/boost "$r"/sys/devices/system/cpu/smt/control \
		"$r"/sys/class/drm/card*/device/power_dpm_force_performance_level \
		"$r"/sys/class/drm/card*/device/tile0/gt0/freq0/min_freq "$r"/sys/class/drm/card*/device/tile0/gt0/freq0/max_freq \
		"$r"/sys/class/power_supply/BAT*/charge_control_end_threshold "$r"/sys/class/power_supply/BAT*/charge_types \
		"$r"/sys/class/power_supply/BAT*/charge_behaviour "$r"/sys/class/power_supply/BAT*/status \
		"$r"/sys/class/power_supply/A*/online "$r"/sys/class/hwmon/hwmon*/pwm1_enable \
		"$r"/sys/class/backlight/*/brightness "$r"/sys/class/leds/*rgb*/multi_intensity \
		"$r"/sys/class/leds/*rgb*/brightness "$r"/sys/power/mem_sleep; do
		[ -e "$p" ] && echo "$p"
	done
}

# diff of two snaps, or nothing
snap_diff() { diff "$CHECK_OUT/$1.txt" "$CHECK_OUT/$2.txt" 2>/dev/null | sed -n 's/^> //p'; }

# The controls CLI (app/scripts/hwtest/controls_cli.gd): the real Controls, no UI.
controls() {
	[ -x "$GC_APP" ] || return 127
	"$GC_APP" --headless -- --controls "$@" 2>/dev/null | grep -E '^(control|get|set|probe|profile|source|error)	'
}

# Charger connected? yes | no | unknown
ac_online() {
	any=0
	for f in "$GC_ROOT"/sys/class/power_supply/*/online; do
		[ -e "$f" ] || continue
		case "$(basename "$(dirname "$f")")" in BAT* | *battery* | hid* | *hidpp*) continue ;; esac
		[ "$(head -n 1 "$f")" = 1 ] && { echo yes; return 0; }
		any=1
	done
	[ "${any:-0}" = 1 ] && echo no || echo unknown
}

# Waits up to $2 seconds until ac_online says $1 (1 s sleeps).
wait_ac() {
	n=0
	while [ "$n" -lt "$2" ]; do
		[ "$(ac_online)" = "$1" ] && return 0
		sleep "${GC_WAIT_STEP:-1}"
		n=$((n + 1))
	done
	return 1
}

# DISPLAY of the running gamescope (its Xwayland), for xprop. "" when there's none.
gamescope_display() {
	[ -n "${GC_GAMESCOPE_DISPLAY:-}" ] && { echo "$GC_GAMESCOPE_DISPLAY"; return 0; }
	for pid in $(pgrep -u "$(id -u)" -f 'gamecove.x86_64|gamescope-session-plus' 2>/dev/null); do
		d="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^DISPLAY=//p' | head -n 1)"
		[ -n "$d" ] && { echo "$d"; return 0; }
	done
	echo ""
}

xprop_root() { # <atom>: value after " = ", or ""
	d="$(gamescope_display)"
	[ -n "$d" ] || return 1
	DISPLAY="$d" "$GC_XPROP" -root "$1" 2>/dev/null | sed -n 's/.* = //p'
}
