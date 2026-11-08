#!/bin/sh
# GameCove root action: battery charge limit. Run by packaging/libexec/gamecove-fix
# through pkexec (`set` and `status` also through gamecove-fix-set, without a
# password). Used only where neither steamos-manager nor PowerStation offers a
# charge limit: the MSI Claw 8 EX and the rows of devices.json marked
# charge_limit_via "sysfs" (OneXPlayer with the oxpec driver, AYANEO with ayaneo-ec).
#
# Two kinds of battery controls, picked by what the battery has:
#
#   threshold  charge_control_end_threshold (MSI Claw, OneXPlayer): the firmware stops
#              at the level by itself. 100 = no limit (the value recorded at install
#              when it was the firmware's "none", 0 on the Claw).
#   behaviour  only charge_behaviour with "inhibit-charge" (AYANEO's ayaneo-ec driver):
#              the firmware can't stop at a level, so `set N` remembers N and holds
#              charging (inhibit-charge) only while the charger is in and the battery
#              is at N % or more; otherwise it lets it charge (auto). GameCove runs
#              `set N` again when the charger or the level crosses that line, so
#              unplugging always goes back to auto and another session never finds
#              a battery that won't charge.
#
#   fix.sh install       record the current setting so it can be put back
#   fix.sh set <50-100>  set the limit
#   fix.sh status        print applies=, mode=, installed=, path=, value=, then state=
#                        (behaviour mode also limit=, behaviour=, capacity=, ac=)
#                        (state=on once GameCove has set a limit, off after remove, n/a without a control)
#   fix.sh remove        put the recorded setting back and forget it
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

# Prints "<mode> <file>" for the first battery with a control we can use.
find_control() {
	for d in "$ROOT"/sys/class/power_supply/*; do
		[ -f "$d/type" ] || continue
		[ "$(cat "$d/type")" = "Battery" ] || continue
		if [ -f "$d/charge_control_end_threshold" ]; then
			printf 'threshold %s\n' "$d/charge_control_end_threshold"
			return 0
		fi
		# the kernel lists every behaviour it accepts ("[auto] inhibit-charge"); once we
		# manage it, $STATE/limit keeps the choice even if a firmware lists less
		if [ -f "$d/charge_behaviour" ] && { grep -q 'inhibit-charge' "$d/charge_behaviour" || [ -f "$STATE/limit" ]; }; then
			printf 'behaviour %s\n' "$d/charge_behaviour"
			return 0
		fi
	done
	return 1
}

write_value() {
	# $1 path, $2 value; fails quietly so the caller decides
	printf '%s\n' "$2" 2>/dev/null > "$1"
}

FOUND="$(find_control)" || FOUND=""
MODE="${FOUND%% *}"
PATH_T="${FOUND#* }"
[ -n "$FOUND" ] || { MODE=""; PATH_T=""; }

# The current charge_behaviour: the word in [brackets], or the only word.
behaviour_now() {
	v="$(cat "$PATH_T")"
	case "$v" in
		*"["*"]"*) v="${v#*[}"; printf '%s\n' "${v%%]*}" ;;
		*) printf '%s\n' "$v" ;;
	esac
}

capacity() {
	c="$(cat "$(dirname "$PATH_T")/capacity" 2>/dev/null || echo -1)"
	case "$c" in ''|*[!0-9]*) echo -1 ;; *) echo "$c" ;; esac
}

ac_online() {
	for d in "$ROOT"/sys/class/power_supply/*; do
		[ -f "$d/type" ] || continue
		case "$(cat "$d/type")" in Mains|USB) ;; *) continue ;; esac
		[ "$(cat "$d/online" 2>/dev/null || echo 0)" = "1" ] && { echo 1; return 0; }
	done
	echo 0
}

do_install() {
	[ -n "$PATH_T" ] || die 2 "this battery has no charge limit control"
	mkdir -p "$STATE"
	if [ ! -f "$STATE/original" ]; then
		if [ "$MODE" = behaviour ]; then
			behaviour_now > "$STATE/original"
		else
			cat "$PATH_T" > "$STATE/original"
		fi
		log_change "install mode=$MODE original=$(cat "$STATE/original")"
	fi
}

set_threshold() {
	value="$1"
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

set_behaviour() {
	value="$1"
	printf '%s\n' "$value" > "$STATE/limit"
	want=auto
	cap="$(capacity)"
	if [ "$value" -lt 100 ] && [ "$(ac_online)" = "1" ] && [ "$cap" -ge "$value" ]; then
		want=inhibit-charge
	fi
	write_value "$PATH_T" "$want" || die 1 "the kernel refused $want"
	got="$(behaviour_now)"
	[ "$got" = "$want" ] || die 1 "reads $got after setting $want"
	log_change "set $value (capacity $cap, $got)"
	printf 'value=%s\nbehaviour=%s\n' "$value" "$got"
}

do_set() {
	value="${1:-}"
	case "$value" in
		''|*[!0-9]*) die 2 "set needs a whole number 50-100" ;;
	esac
	[ "$value" -ge 50 ] && [ "$value" -le 100 ] || die 2 "set needs a whole number 50-100"
	do_install
	if [ "$MODE" = behaviour ]; then
		set_behaviour "$value"
	else
		set_threshold "$value"
	fi
}

do_status() {
	if [ -z "$PATH_T" ]; then
		printf 'applies=no\nstate=n/a\n'
		return 0
	fi
	printf 'applies=yes\nmode=%s\n' "$MODE"
	if [ -f "$STATE/original" ]; then
		printf 'installed=yes\noriginal=%s\n' "$(cat "$STATE/original")"
	else
		printf 'installed=no\n'
	fi
	if [ "$MODE" = behaviour ]; then
		limit=100
		[ -f "$STATE/original" ] && [ -f "$STATE/limit" ] && limit="$(cat "$STATE/limit")"
		printf 'path=%s\nvalue=%s\nlimit=%s\nbehaviour=%s\ncapacity=%s\nac=%s\n' "${PATH_T#"$ROOT"}" "$limit" "$limit" \
			"$(behaviour_now)" "$(capacity)" "$(ac_online)"
	else
		printf 'path=%s\nvalue=%s\n' "${PATH_T#"$ROOT"}" "$(cat "$PATH_T")"
	fi
	if [ -f "$STATE/original" ]; then printf 'state=on\n'; else printf 'state=off\n'; fi
}

do_remove() {
	if [ ! -f "$STATE/original" ]; then
		printf 'nothing to undo\n'
		return 0
	fi
	original="$(cat "$STATE/original")"
	if [ -n "$PATH_T" ]; then
		if [ "$MODE" = behaviour ]; then
			# never leave a battery that won't charge behind
			write_value "$PATH_T" auto || die 1 "the kernel refused auto"
			original=auto
		else
			write_value "$PATH_T" "$original" || die 1 "the kernel refused $original"
		fi
	fi
	rm -f "$STATE/original" "$STATE/limit"
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
