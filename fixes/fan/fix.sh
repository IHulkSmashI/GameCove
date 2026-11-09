#!/bin/sh
# GameCove root action: fan presets for handheld fan drivers that have no
# service of their own. Run by packaging/libexec/gamecove-fix through pkexec
# (`set` and `status` also through gamecove-fix-set, without a password).
#
# Drivers (hwmon "name"), first one found wins:
#
#   msi_wmi_platform       MSI Claw. Two fans (pwm1 CPU, pwm2 GPU), each a six-point
#                          table pwmN_auto_point1..6_pwm (0-255, the EC stores percent);
#                          pwmN_enable 1 = follow the table, 2 = MSI's automatic control.
#                          Only duty values are written, never the temperature points.
#   asus_custom_fan_curve  ASUS ROG Ally family (asus-wmi). pwm1 CPU, pwm2 GPU (pwm3 mid
#                          fan where present), eight points pwmN_auto_pointM_temp (deg C)
#                          and _pwm (0-255); pwmN_enable 1 = custom curve, 2 = factory curve.
#   oxp_ec                 OneXPlayer / AOKZOE, oxpec driver (kernel 6.16+). pwm1 0-255;
#                          pwm1_enable 0 = full speed, 1 = manual, 2 = automatic (EC).
#   oxpec                  Same EC, older oxp-sensors driver: pwm1_enable 0 = automatic, 1 = manual.
#   ayaneo_ec              AYANEO, ayaneo-ec driver. pwm1 0-255; pwm1_enable 1 = manual, 2 = automatic.
#   gpdfan                 GPD, gpd-fan driver (6.18+). pwm1 0-255; pwm1_enable 0 = full
#                          speed, 1 = manual, 2 = automatic (EC).
#   zotac_*                ZOTAC Zone, out-of-tree zotac_zone_platform driver. Standard
#                          hwmon ABI assumed (pwm1_enable 1 = manual, 2 = automatic);
#                          UNVERIFIED on hardware, so every write is read back.
#
# Modes: auto (the firmware's own control) everywhere; max (100 %) everywhere;
# quiet only on the two table drivers (msi_wmi_platform, asus_custom_fan_curve),
# because a fixed low duty on a manual-only driver could overheat the chip.
#
#   fix.sh install          record every fan's enable flag and table/duty so it can be put back
#   fix.sh set <mode>       auto | quiet | max
#   fix.sh status           applies=, driver=, modes=, installed=, per-fan values, then state=
#                           (state=on once GameCove has set a preset, off after remove, n/a without a driver)
#   fix.sh remove           put the recorded values back and forget them
#
# Presets (percent per point):
#   msi_wmi_platform       quiet 0 40 40 45 60 75 (ClawDeck's known-good Claw tables), max 100 x 6
#   asus_custom_fan_curve  temperatures 30 40 50 60 70 80 90 100 C; quiet 2 5 17 35 55 75 75 75
#                          (Handheld Daemon's minimum curve up to 50 C, its default curve above), max 100 x 8
# Must match FAN_DRIVERS in app/scripts/device/power.gd.
#
# Only on the handhelds listed in ../lib/handhelds.txt (generated from devices.json):
# MSI and ASUS laptops use the same drivers, so anything else gets applies=no / exit 2.
# If a `set` fails halfway, every fan goes back to the firmware's automatic control.
#
# GAMECOVE_ROOT is a filesystem prefix for tests (empty on a real system).
# Exit codes: 0 done, 1 failed, 2 bad usage or not supported here.
set -eu

ROOT="${GAMECOVE_ROOT:-}"
STATE="$ROOT/var/lib/gamecove/fixes/fan"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fixes/lib/handheld.sh
. "$HERE/../lib/handheld.sh"
SETTING=0

# On any exit: a `set` that didn't finish puts every fan back on automatic,
# then the lock goes.
on_exit() {
	rc=$?
	if [ "$rc" -ne 0 ] && [ "$SETTING" -eq 1 ] && [ -n "${HW:-}" ]; then
		for n in $(fans); do
			write_value "$HW/pwm${n}_enable" "$AUTO" || true
		done
		printf 'fan: set failed, every fan is back on automatic\n' >&2
		log_change "set failed (exit $rc), fans back on automatic" || true
	fi
	fix_unlock
	exit "$rc"
}
trap on_exit EXIT
trap 'exit 1' INT TERM HUP

die() { printf 'fan: %s\n' "$2" >&2; exit "$1"; }

log_change() {
	mkdir -p "$STATE"
	printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$STATE/changes.log"
}

# Prints "<hwmon dir> <driver>" for the first supported fan driver (handhelds only).
find_hwmon() {
	handheld_ok || return 1
	for h in "$ROOT"/sys/class/hwmon/*; do
		[ -f "$h/name" ] || continue
		n="$(cat "$h/name")"
		case "$n" in
			msi_wmi_platform|asus_custom_fan_curve|oxp_ec|oxpec|ayaneo_ec|gpdfan|zotac_*) ;;
			*) continue ;;
		esac
		[ -f "$h/pwm1_enable" ] || continue
		printf '%s %s\n' "$h" "$n"
		return 0
	done
	return 1
}

FOUND="$(find_hwmon)" || FOUND=""
HW="${FOUND% *}"
DRIVER="${FOUND##* }"
[ -n "$FOUND" ] || { HW=""; DRIVER=""; }

# kind: table (duty tables + enable) or manual (one duty + enable)
case "$DRIVER" in
	msi_wmi_platform) KIND=table; POINTS="1 2 3 4 5 6"; AUTO=2; CUSTOM=1; MODES="quiet auto max" ;;
	asus_custom_fan_curve) KIND=table; POINTS="1 2 3 4 5 6 7 8"; AUTO=2; CUSTOM=1; MODES="quiet auto max" ;;
	oxp_ec|ayaneo_ec|gpdfan|zotac_*) KIND=manual; POINTS=""; AUTO=2; CUSTOM=1; MODES="auto max" ;;
	oxpec) KIND=manual; POINTS=""; AUTO=0; CUSTOM=1; MODES="auto max" ;;
	*) KIND=""; POINTS=""; AUTO=""; CUSTOM=""; MODES="" ;;
esac

fans() {
	for n in 1 2 3; do
		[ -f "$HW/pwm${n}_enable" ] && printf '%s\n' "$n"
	done
	return 0
}

to_pwm() { echo $((($1 * 255 + 50) / 100)); }

write_value() {
	printf '%s\n' "$2" 2>/dev/null > "$1"
}

read_value() {
	cat "$1" 2>/dev/null || echo "?"
}

need_hw() {
	[ -n "$HW" ] || die 2 "no supported fan driver on this kernel"
}

do_install() {
	need_hw
	mkdir -p "$STATE"
	[ -f "$STATE/original" ] && return 0
	: > "$STATE/original.tmp"
	printf 'driver=%s\n' "$DRIVER" >> "$STATE/original.tmp"
	for n in $(fans); do
		if [ "$KIND" = table ]; then
			for i in $POINTS; do
				if [ -f "$HW/pwm${n}_auto_point${i}_temp" ] && [ "$DRIVER" = asus_custom_fan_curve ]; then
					printf 'pwm%s_auto_point%s_temp=%s\n' "$n" "$i" "$(cat "$HW/pwm${n}_auto_point${i}_temp")" >> "$STATE/original.tmp"
				fi
				printf 'pwm%s_auto_point%s_pwm=%s\n' "$n" "$i" "$(cat "$HW/pwm${n}_auto_point${i}_pwm")" >> "$STATE/original.tmp"
			done
		elif [ -f "$HW/pwm$n" ]; then
			# some drivers can't read pwm in automatic mode; then there is nothing to restore
			v="$(cat "$HW/pwm$n" 2>/dev/null || true)"
			case "$v" in ''|*[!0-9]*) ;; *) printf 'pwm%s=%s\n' "$n" "$v" >> "$STATE/original.tmp" ;; esac
		fi
		printf 'pwm%s_enable=%s\n' "$n" "$(cat "$HW/pwm${n}_enable")" >> "$STATE/original.tmp"
	done
	mv "$STATE/original.tmp" "$STATE/original"
	log_change "install driver=$DRIVER"
}

table_for() {
	case "$DRIVER:$1" in
		msi_wmi_platform:quiet) echo "0 40 40 45 60 75" ;;
		msi_wmi_platform:max) echo "100 100 100 100 100 100" ;;
		asus_custom_fan_curve:quiet) echo "2 5 17 35 55 75 75 75" ;;
		asus_custom_fan_curve:max) echo "100 100 100 100 100 100 100 100" ;;
		*) return 1 ;;
	esac
}

ASUS_TEMPS="30 40 50 60 70 80 90 100"

set_enable() {
	# $1 fan, $2 value; checked by reading back
	write_value "$HW/pwm$1_enable" "$2" || die 1 "fan $1 refused mode $2"
	[ "$(read_value "$HW/pwm$1_enable")" = "$2" ] || die 1 "fan $1 did not switch to mode $2"
}

do_set() {
	mode="${1:-}"
	case "$mode" in
		auto|quiet|max) ;;
		*) die 2 "set needs auto, quiet or max" ;;
	esac
	need_hw
	case " $MODES " in
		*" $mode "*) ;;
		*) die 2 "$DRIVER has no $mode mode (it offers: $MODES)" ;;
	esac
	fix_lock fan
	do_install
	SETTING=1
	for n in $(fans); do
		if [ "$mode" = "auto" ]; then
			set_enable "$n" "$AUTO"
			continue
		fi
		if [ "$KIND" = manual ]; then
			# max: manual mode first (some drivers reset the duty on the switch), then full duty
			set_enable "$n" "$CUSTOM"
			write_value "$HW/pwm$n" 255 || die 1 "fan $n refused full duty"
			got="$(read_value "$HW/pwm$n")"
			[ "$got" = "255" ] || die 1 "fan $n reads $got after full duty"
			continue
		fi
		i=1
		set -- $ASUS_TEMPS
		for d in $(table_for "$mode"); do
			if [ "$DRIVER" = asus_custom_fan_curve ]; then
				write_value "$HW/pwm${n}_auto_point${i}_temp" "$1" || die 1 "fan $n point $i refused $1 C"
				shift
			fi
			want="$(to_pwm "$d")"
			write_value "$HW/pwm${n}_auto_point${i}_pwm" "$want" || die 1 "fan $n point $i refused $want"
			i=$((i + 1))
		done
		set_enable "$n" "$CUSTOM"
	done
	SETTING=0
	log_change "set $mode driver=$DRIVER"
	printf 'mode=%s\n' "$mode"
}

do_status() {
	# another handheld's saved state (same drive) is not this one's
	ORIG="$(state_file "$STATE" original)"
	if [ -z "$HW" ]; then
		printf 'applies=no\nstate=n/a\n'
		return 0
	fi
	echo "applies=yes"
	printf 'driver=%s\nmodes=%s\n' "$DRIVER" "$(echo "$MODES" | tr ' ' ',')"
	if [ -f "$ORIG" ]; then echo "installed=yes"; else echo "installed=no"; fi
	for n in $(fans); do
		printf 'pwm%s_enable=%s\n' "$n" "$(read_value "$HW/pwm${n}_enable")"
		if [ "$KIND" = table ]; then
			line=""
			for i in $POINTS; do
				line="$line $(read_value "$HW/pwm${n}_auto_point${i}_pwm")"
			done
			printf 'pwm%s_table=%s\n' "$n" "${line# }"
		elif [ -f "$HW/pwm$n" ]; then
			printf 'pwm%s=%s\n' "$n" "$(read_value "$HW/pwm$n")"
		fi
	done
	if [ -f "$ORIG" ]; then echo "state=on"; else echo "state=off"; fi
}

do_remove() {
	if [ ! -f "$STATE/original" ]; then
		echo "nothing to undo"
		return 0
	fi
	need_hw
	fix_lock fan
	# values first, then the enable flags (the order the file was written in)
	while IFS='=' read -r key value; do
		case "$key" in
			pwm[123]_auto_point[1-8]_pwm|pwm[123]_auto_point[1-8]_temp|pwm[123]|pwm[123]_enable) ;;
			*) continue ;;
		esac
		case "$value" in
			''|*[!0-9]*) continue ;;
		esac
		[ -f "$HW/$key" ] || continue
		write_value "$HW/$key" "$value" || die 1 "could not restore $key"
	done < "$STATE/original"
	rm -f "$STATE/original"
	log_change "remove"
	echo "restored"
}

# Saved state from before per-device state: this handheld's if it was read from the same fan driver.
fan_legacy_ok() { grep -qx "driver=$DRIVER" "$STATE/original" 2>/dev/null; }

case "${1:-}" in
	install | set | remove) ! can_write_state || state_switch "$STATE" fan_legacy_ok ;;
esac
case "${1:-}" in
	install) fix_lock fan; do_install; echo "installed=yes" ;;
	set) do_set "${2:-}" ;;
	status) do_status ;;
	remove) do_remove ;;
	*) die 2 "usage: fix.sh install|remove|status|set auto|quiet|max" ;;
esac
