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
#              at the level by itself. 100 = no limit. The Claw reads 0 until a limit
#              is set: msi-wmi-platform (OGC kernel, "Add charge_threshold support")
#              reads the EC byte 0xd7 without its enable bit 7 and writes value|0x80,
#              so writing 0 would turn ON a 0 % limit (a battery that never charges).
#              0 is therefore never written: "no limit" is always 100, also on remove.
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
#   fix.sh set release   behaviour mode: let it charge (auto) now, keep the limit for
#                        next time; GameCove's session runs it when GameCove exits.
#                        Threshold mode: nothing to do (the firmware keeps the limit).
#   fix.sh guard         run by udev on every power_supply add/change (boot included):
#                        behaviour mode only; holds charging only while GameCove runs
#                        and the battery is at the limit on the charger, else auto.
#                        So a crash, Steam's session or the desktop never find a
#                        battery that won't charge. Writes only when the value differs.
#
# Behaviour mode's install also writes /etc/udev/rules.d/90-gamecove-charge-limit.rules
# (runs `guard`); remove takes it away.
#
# Only on the handhelds listed in ../lib/handhelds.txt (generated from devices.json):
# laptops share these battery drivers, so anything else gets applies=no / exit 2.
#
# GAMECOVE_ROOT is a filesystem prefix for tests (empty on a real system).
# Exit codes: 0 done, 1 failed, 2 bad usage or not supported here.
set -eu

ROOT="${GAMECOVE_ROOT:-}"
STATE="$ROOT/var/lib/gamecove/fixes/charge-limit"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fixes/lib/handheld.sh
. "$HERE/../lib/handheld.sh"
trap fix_unlock EXIT
trap 'exit 1' INT TERM HUP
RULE="$ROOT/etc/udev/rules.d/90-gamecove-charge-limit.rules"
# where the fix is installed (the rule calls it from there)
FIX_PATH=/usr/lib/gamecove/fixes/charge-limit/fix.sh
APP_BIN=/usr/lib/gamecove/gamecove.x86_64

die() { printf 'charge-limit: %s\n' "$2" >&2; exit "$1"; }

log_change() {
	mkdir -p "$STATE"
	printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$STATE/changes.log"
}

# Prints "<mode> <file>" for the first battery with a control we can use (handhelds only).
find_control() {
	handheld_ok || return 1
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
	if [ "$MODE" = behaviour ] && [ ! -f "$RULE" ]; then
		install_rule
	fi
}

install_rule() {
	mkdir -p "$(dirname "$RULE")"
	cat > "$RULE.tmp" <<RULEEOF
# GameCove charge-limit fix (AYANEO charge_behaviour): never leave charging held
# when GameCove isn't running. Removed by: gamecove-fix charge-limit remove
ACTION=="add|change", SUBSYSTEM=="power_supply", RUN+="/bin/sh $FIX_PATH guard"
RULEEOF
	mv "$RULE.tmp" "$RULE"
	udevadm control --reload >/dev/null 2>&1 || true
	log_change "udev rule written"
}

app_running() {
	pgrep -f "$APP_BIN" >/dev/null 2>&1
}

# behaviour mode: what charge_behaviour should be for this limit right now
behaviour_for() {
	want=auto
	if [ "$1" -lt 100 ] && [ "$(ac_online)" = "1" ] && [ "$(capacity)" -ge "$1" ]; then
		want=inhibit-charge
	fi
	printf '%s\n' "$want"
}

do_guard() {
	[ "$MODE" = behaviour ] || return 0
	want=auto
	if [ -f "$STATE/original" ] && [ -f "$STATE/limit" ] && app_running; then
		limit="$(cat "$STATE/limit")"
		case "$limit" in ''|*[!0-9]*) limit=100 ;; esac
		want="$(behaviour_for "$limit")"
	fi
	[ "$(behaviour_now)" = "$want" ] && return 0
	write_value "$PATH_T" "$want" || die 1 "the kernel refused $want"
	log_change "guard $want"
}

do_release() {
	[ "$MODE" = behaviour ] || { printf 'value=release\n'; return 0; }
	if [ "$(behaviour_now)" != auto ]; then
		write_value "$PATH_T" auto || die 1 "the kernel refused auto"
		log_change "release (auto)"
	fi
	printf 'value=release\nbehaviour=%s\n' "$(behaviour_now)"
}

set_threshold() {
	value="$1"
	original="$(cat "$STATE/original")"
	if [ "$value" -eq 100 ]; then
		# 100 = charge to full; never 0 (see the top: 0 is a 0 % limit on MSI's EC)
		write_value "$PATH_T" 100 || die 1 "the kernel refused 100 (original $original)"
		got="$(cat "$PATH_T")"
		[ "$got" = "100" ] || die 1 "reads $got after setting no limit"
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
	cap="$(capacity)"
	want="$(behaviour_for "$value")"
	write_value "$PATH_T" "$want" || die 1 "the kernel refused $want"
	got="$(behaviour_now)"
	[ "$got" = "$want" ] || die 1 "reads $got after setting $want"
	log_change "set $value (capacity $cap, $got)"
	printf 'value=%s\nbehaviour=%s\n' "$value" "$got"
}

do_set() {
	value="${1:-}"
	if [ "$value" = release ]; then
		[ -n "$PATH_T" ] || die 2 "this battery has no charge limit control"
		fix_lock charge-limit
		do_release
		return 0
	fi
	case "$value" in
		''|*[!0-9]*) die 2 "set needs a whole number 50-100" ;;
	esac
	[ "$value" -ge 50 ] && [ "$value" -le 100 ] || die 2 "set needs a whole number 50-100"
	fix_lock charge-limit
	do_install
	if [ "$MODE" = behaviour ]; then
		set_behaviour "$value"
	else
		set_threshold "$value"
	fi
}

do_status() {
	# another handheld's saved state (same drive) is not this one's
	ORIG="$(state_file "$STATE" original)"
	LIMIT="$(state_file "$STATE" limit)"
	if [ -z "$PATH_T" ]; then
		printf 'applies=no\nstate=n/a\n'
		return 0
	fi
	printf 'applies=yes\nmode=%s\n' "$MODE"
	if [ -f "$ORIG" ]; then
		printf 'installed=yes\noriginal=%s\n' "$(cat "$ORIG")"
	else
		printf 'installed=no\n'
	fi
	if [ "$MODE" = behaviour ]; then
		limit=100
		[ -f "$ORIG" ] && [ -f "$LIMIT" ] && limit="$(cat "$LIMIT")"
		printf 'path=%s\nvalue=%s\nlimit=%s\nbehaviour=%s\ncapacity=%s\nac=%s\n' "${PATH_T#"$ROOT"}" "$limit" "$limit" \
			"$(behaviour_now)" "$(capacity)" "$(ac_online)"
	else
		printf 'path=%s\nvalue=%s\n' "${PATH_T#"$ROOT"}" "$(cat "$PATH_T")"
	fi
	if [ -f "$ORIG" ]; then printf 'state=on\n'; else printf 'state=off\n'; fi
}

do_remove() {
	if [ -f "$RULE" ]; then
		rm -f "$RULE"
		udevadm control --reload >/dev/null 2>&1 || true
		log_change "udev rule removed"
	fi
	if [ ! -f "$STATE/original" ]; then
		printf 'nothing to undo\n'
		return 0
	fi
	fix_lock charge-limit
	original="$(cat "$STATE/original")"
	if [ -n "$PATH_T" ]; then
		if [ "$MODE" = behaviour ]; then
			# never leave a battery that won't charge behind
			write_value "$PATH_T" auto || die 1 "the kernel refused auto"
			original=auto
		else
			# a recorded 0 (the Claw's "never set") or anything not 50-100 goes back as 100,
			# no limit: writing 0 would set a 0 % limit
			case "$original" in
				5[0-9] | [6-9][0-9] | 100) ;;
				*) original=100 ;;
			esac
			write_value "$PATH_T" "$original" || die 1 "the kernel refused $original"
		fi
	fi
	rm -f "$STATE/original" "$STATE/limit"
	log_change "remove restored=$original"
	printf 'value=%s\n' "$original"
}

case "${1:-}" in
	install | set | remove | guard) ! can_write_state || state_switch "$STATE" ;;
esac
case "${1:-}" in
	install) [ -n "$PATH_T" ] || die 2 "this battery has no charge limit control"; fix_lock charge-limit; do_install; printf 'installed=yes\n' ;;
	set) do_set "${2:-}" ;;
	status) do_status ;;
	remove) do_remove ;;
	guard) do_guard ;;
	*) die 2 "usage: fix.sh install|remove|status|guard|set <50-100>|set release" ;;
esac
