#!/bin/sh
# GameCove root action: fan presets for the MSI platform driver (hwmon "msi_wmi_platform").
# Run by packaging/libexec/gamecove-fix through pkexec.
#
# The driver gives two fans (pwm1 CPU, pwm2 GPU), each with a six-point table
# pwmN_auto_point1..6_pwm (0-255; the EC stores percent) and pwmN_enable:
# 1 = follow the tables, 2 = MSI's automatic control (factory tables).
# Only the duty values are written, never the temperature points.
#
#   fix.sh install          record every fan's enable and table so it can be put back
#   fix.sh set <mode>       auto | quiet | max
#   fix.sh status           print applies=, installed=, each fan's enable and table, then state=
#                           (state=on once GameCove has set a preset, off after remove, n/a without the driver)
#   fix.sh remove           put the recorded tables and enable back and forget them
#
# Presets (EC percent per point), ClawDeck's known-good Claw tables:
#   quiet  0 40 40 45 60 75   (off at idle, gentle ramp)
#   max    100 x 6
# Must match FAN_TABLES in app/scripts/device/power.gd.
#
# GAMECOVE_ROOT is a filesystem prefix for tests (empty on a real system).
# Exit codes: 0 done, 1 failed, 2 bad usage or not supported here.
set -eu

ROOT="${GAMECOVE_ROOT:-}"
STATE="$ROOT/var/lib/gamecove/fixes/fan"
POINTS="1 2 3 4 5 6"

die() { printf 'fan: %s\n' "$2" >&2; exit "$1"; }

log_change() {
	mkdir -p "$STATE"
	printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$STATE/changes.log"
}

find_hwmon() {
	for h in "$ROOT"/sys/class/hwmon/*; do
		[ -f "$h/name" ] || continue
		if [ "$(cat "$h/name")" = "msi_wmi_platform" ] && [ -f "$h/pwm1_enable" ]; then
			printf '%s\n' "$h"
			return 0
		fi
	done
	return 1
}

HW="$(find_hwmon)" || HW=""

fans() {
	for n in 1 2; do
		[ -f "$HW/pwm${n}_enable" ] && printf '%s\n' "$n"
	done
	return 0
}

to_pwm() { echo $((($1 * 255 + 50) / 100)); }

write_value() {
	printf '%s\n' "$2" 2>/dev/null > "$1"
}

need_hw() {
	[ -n "$HW" ] || die 2 "no msi_wmi_platform fan control on this kernel"
}

do_install() {
	need_hw
	mkdir -p "$STATE"
	[ -f "$STATE/original" ] && return 0
	: > "$STATE/original.tmp"
	for n in $(fans); do
		for i in $POINTS; do
			printf 'pwm%s_auto_point%s_pwm=%s\n' "$n" "$i" "$(cat "$HW/pwm${n}_auto_point${i}_pwm")" >> "$STATE/original.tmp"
		done
		printf 'pwm%s_enable=%s\n' "$n" "$(cat "$HW/pwm${n}_enable")" >> "$STATE/original.tmp"
	done
	mv "$STATE/original.tmp" "$STATE/original"
	log_change "install"
}

table_for() {
	case "$1" in
		quiet) echo "0 40 40 45 60 75" ;;
		max) echo "100 100 100 100 100 100" ;;
		*) return 1 ;;
	esac
}

do_set() {
	mode="${1:-}"
	case "$mode" in
		auto|quiet|max) ;;
		*) die 2 "set needs auto, quiet or max" ;;
	esac
	do_install
	for n in $(fans); do
		if [ "$mode" = "auto" ]; then
			write_value "$HW/pwm${n}_enable" 2 || die 1 "fan $n refused automatic mode"
			[ "$(cat "$HW/pwm${n}_enable")" = "2" ] || die 1 "fan $n did not switch to automatic"
			continue
		fi
		i=1
		for d in $(table_for "$mode"); do
			want="$(to_pwm "$d")"
			write_value "$HW/pwm${n}_auto_point${i}_pwm" "$want" || die 1 "fan $n point $i refused $want"
			i=$((i + 1))
		done
		write_value "$HW/pwm${n}_enable" 1 || die 1 "fan $n refused table mode"
		[ "$(cat "$HW/pwm${n}_enable")" = "1" ] || die 1 "fan $n did not switch to table mode"
	done
	log_change "set $mode"
	printf 'mode=%s\n' "$mode"
}

do_status() {
	if [ -z "$HW" ]; then
		printf 'applies=no\nstate=n/a\n'
		return 0
	fi
	echo "applies=yes"
	if [ -f "$STATE/original" ]; then echo "installed=yes"; else echo "installed=no"; fi
	for n in $(fans); do
		line=""
		for i in $POINTS; do
			line="$line $(cat "$HW/pwm${n}_auto_point${i}_pwm")"
		done
		printf 'pwm%s_enable=%s\npwm%s_table=%s\n' "$n" "$(cat "$HW/pwm${n}_enable")" "$n" "${line# }"
	done
	if [ -f "$STATE/original" ]; then echo "state=on"; else echo "state=off"; fi
}

do_remove() {
	if [ ! -f "$STATE/original" ]; then
		echo "nothing to undo"
		return 0
	fi
	need_hw
	# tables first, then the enable flags (the order the file was written in)
	while IFS='=' read -r key value; do
		case "$key" in
			pwm[12]_auto_point[1-6]_pwm|pwm[12]_enable) ;;
			*) continue ;;
		esac
		case "$value" in
			''|*[!0-9]*) continue ;;
		esac
		write_value "$HW/$key" "$value" || die 1 "could not restore $key"
	done < "$STATE/original"
	rm -f "$STATE/original"
	log_change "remove"
	echo "restored"
}

case "${1:-}" in
	install) do_install; echo "installed=yes" ;;
	set) do_set "${2:-}" ;;
	status) do_status ;;
	remove) do_remove ;;
	*) die 2 "usage: fix.sh install|remove|status|set auto|quiet|max" ;;
esac
