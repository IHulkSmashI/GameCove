#!/bin/sh
# GameCove root action: battery charge limit (power_supply charge_control_end_threshold).
# Run by packaging/libexec/gamecove-fix through pkexec. Used only where neither
# steamos-manager nor PowerStation offers a charge limit (the MSI Claw 8 EX).
#
#   fix.sh install       record the current limit so it can be put back
#   fix.sh set <50-100>  set the limit; 100 = no limit (the value recorded at install
#                        when it was the firmware's "none", 0 on the Claw)
#   fix.sh status        print installed=, path=, value=
#   fix.sh remove        put the recorded limit back and forget it
#
# GAMECOVE_ROOT is a filesystem prefix for tests (empty on a real system).
# Exit codes: 0 done, 1 failed, 2 bad usage or not supported here.
set -eu

ROOT="${GAMECOVE_ROOT:-}"
STATE="$ROOT/var/lib/gamecove/fixes/charge-limit"

die() { printf 'charge-limit: %s\n' "$2" >&2; exit "$1"; }

log_change() {
	mkdir -p "$STATE"
	printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$STATE/changes.log"
}

find_threshold() {
	for d in "$ROOT"/sys/class/power_supply/*; do
		[ -f "$d/type" ] || continue
		[ "$(cat "$d/type")" = "Battery" ] || continue
		if [ -f "$d/charge_control_end_threshold" ]; then
			printf '%s\n' "$d/charge_control_end_threshold"
			return 0
		fi
	done
	return 1
}

write_value() {
	# $1 path, $2 value; fails quietly so the caller decides
	printf '%s\n' "$2" 2>/dev/null > "$1"
}

PATH_T="$(find_threshold)" || PATH_T=""

do_install() {
	[ -n "$PATH_T" ] || die 2 "this battery has no charge_control_end_threshold"
	mkdir -p "$STATE"
	if [ ! -f "$STATE/original" ]; then
		cat "$PATH_T" > "$STATE/original"
		log_change "install original=$(cat "$STATE/original")"
	fi
}

do_set() {
	value="${1:-}"
	case "$value" in
		''|*[!0-9]*) die 2 "set needs a whole number 50-100" ;;
	esac
	[ "$value" -ge 50 ] && [ "$value" -le 100 ] || die 2 "set needs a whole number 50-100"
	do_install
	original="$(cat "$STATE/original")"
	if [ "$value" -eq 100 ]; then
		if [ "$original" = "0" ]; then
			write_value "$PATH_T" 0 || die 1 "the kernel refused 0"
		elif ! write_value "$PATH_T" 100; then
			write_value "$PATH_T" 0 || die 1 "the kernel refused 100 and 0"
		fi
		got="$(cat "$PATH_T")"
		[ "$got" = "100" ] || [ "$got" = "0" ] || die 1 "reads $got after setting no limit"
	else
		write_value "$PATH_T" "$value" || die 1 "the kernel refused $value"
		got="$(cat "$PATH_T")"
		[ "$got" = "$value" ] || die 1 "reads $got after setting $value"
	fi
	log_change "set $value (reads $got)"
	printf 'value=%s\n' "$got"
}

do_status() {
	[ -n "$PATH_T" ] || die 2 "this battery has no charge_control_end_threshold"
	if [ -f "$STATE/original" ]; then
		printf 'installed=yes\noriginal=%s\n' "$(cat "$STATE/original")"
	else
		printf 'installed=no\n'
	fi
	printf 'path=%s\nvalue=%s\n' "${PATH_T#"$ROOT"}" "$(cat "$PATH_T")"
}

do_remove() {
	if [ ! -f "$STATE/original" ]; then
		printf 'nothing to undo\n'
		return 0
	fi
	original="$(cat "$STATE/original")"
	if [ -n "$PATH_T" ]; then
		write_value "$PATH_T" "$original" || die 1 "the kernel refused $original"
	fi
	rm -f "$STATE/original"
	log_change "remove restored=$original"
	printf 'value=%s\n' "$original"
}

case "${1:-}" in
	install) do_install; printf 'installed=yes\n' ;;
	set) do_set "${2:-}" ;;
	status) do_status ;;
	remove) do_remove ;;
	*) die 2 "usage: fix.sh install|remove|status|set <50-100>" ;;
esac
