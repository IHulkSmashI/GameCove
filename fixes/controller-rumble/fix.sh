#!/bin/sh
# GameCove root action: rumble (vibration) strength kept in the handheld
# controller's own firmware, through its kernel HID driver's sysfs attributes.
# Run by packaging/libexec/gamecove-fix (and, without a password, through
# gamecove-fix-set: `set` and `status` only). The app's side is
# app/scripts/controls/input/rumble.gd.
#
# Knobs (one per handheld; root-only to write, anyone may read):
#   hid-msi        /sys/bus/hid/drivers/hid-msi/<hid dev>/rumble_intensity_left and
#                  rumble_intensity_right, 0-100 (rumble_intensity_range says "0-100").
#                  MSI Claw controllers with firmware 1.66+ / 2.17+ (claw_features_supported
#                  in drivers/hid/hid-msi.c). Every store is written to the controller's
#                  flash (CLAW_COMMAND_TYPE_SYNC_TO_ROM), so a value that is already set
#                  is never written again.
#   hid-lenovo-go  /sys/bus/hid/drivers/hid-lenovo-go/<hid dev>/rumble_intensity, one of
#                  off low medium high (rumble_intensity_index); both Legion Go
#                  controllers (Documentation/ABI/testing/sysfs-driver-hid-lenovo-go).
# Nothing else is touched.
#
#   fix.sh set <0-100>|off        hid-msi: both motors; off = 0
#   fix.sh set off|low|medium|high hid-lenovo-go
#   fix.sh status    applies=yes|no, driver=, kind=percent|levels, value=, range=lo-hi
#                    or levels=a,b,c, state=on (GameCove changed it; remove puts it back)|off
#   fix.sh install   remember the current values (the first set does it too)
#   fix.sh remove    put the remembered values back and forget them
#
# Every value written is read back; if the controller refuses one, the values from
# before the set go back and the run fails.
# GAMECOVE_ROOT is a filesystem prefix for tests (empty on a real system).
# Exit codes: 0 done, 1 failed, 2 bad usage or no rumble knob here.
set -eu

ROOT="${GAMECOVE_ROOT:-}"
STATE="$ROOT/var/lib/gamecove/fixes/controller-rumble"
DRIVERS="$ROOT/sys/bus/hid/drivers"

die() { printf 'controller-rumble: %s\n' "$2" >&2; exit "$1"; }

log_change() {
	mkdir -p "$STATE"
	printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$STATE/changes.log"
}

rd() { cat "$1" 2>/dev/null | tr -d '\n' || true; }
wr() { printf '%s\n' "$2" 2>/dev/null > "$1"; }

# knob: prints "<driver> <hid device dir>" for the first controller with a knob
knob() {
	for d in "$DRIVERS"/hid-msi/*:*; do
		[ -f "$d/rumble_intensity_left" ] && [ -f "$d/rumble_intensity_right" ] || continue
		printf 'hid-msi %s\n' "$d"
		return 0
	done
	for d in "$DRIVERS"/hid-lenovo-go/*:*; do
		[ -f "$d/rumble_intensity" ] || continue
		printf 'hid-lenovo-go %s\n' "$d"
		return 0
	done
	return 0
}

attrs_of() {
	case "$1" in
		hid-msi) echo "rumble_intensity_left rumble_intensity_right" ;;
		hid-lenovo-go) echo "rumble_intensity" ;;
	esac
}

# range_of <dir>: sets LO and HI from rumble_intensity_range (0 and 100 when unreadable)
range_of() {
	r="$(rd "$1/rumble_intensity_range")"
	LO="${r%%-*}"; HI="${r##*-}"
	case "$LO$HI" in ''|*[!0-9]*) LO=0; HI=100 ;; esac
}

# levels_of <dir>: the offered words (without "unknown")
levels_of() {
	lv=""
	for w in $(rd "$1/rumble_intensity_index"); do
		case "$w" in unknown) ;; *[!a-z]*) ;; *) lv="$lv $w" ;; esac
	done
	[ -n "$lv" ] || lv=" off low medium high"
	echo "${lv# }"
}

# snapshot <driver> <dir>: attr=value lines
snapshot() {
	for a in $(attrs_of "$1"); do
		printf '%s=%s\n' "$a" "$(rd "$2/$a")"
	done
}

# restore <dir> <snapshot file>: writes back only what differs
restore() {
	while IFS='=' read -r a v; do
		[ -n "$a" ] && [ -n "$v" ] && [ -f "$1/$a" ] || continue
		[ "$(rd "$1/$a")" = "$v" ] || wr "$1/$a" "$v" || true
	done < "$2"
	return 0
}

do_install() {
	mkdir -p "$STATE"
	[ -f "$STATE/original" ] && return 0
	snapshot "$1" "$2" > "$STATE/original.tmp"
	mv "$STATE/original.tmp" "$STATE/original"
}

# put <dir> <attr> <value>: write unless already set, then read back
put() {
	[ "$(rd "$1/$2")" = "$3" ] && return 0
	wr "$1/$2" "$3" || return 1
	[ "$(rd "$1/$2")" = "$3" ]
}

do_set() {
	k="$(knob)"
	[ -n "$k" ] || die 2 "no rumble strength setting on this kernel"
	drv="${k%% *}"; dir="${k#* }"
	v="$1"
	case "$drv" in
		hid-msi)
			[ "$v" = off ] && v=0
			case "$v" in ''|*[!0-9]*|0?*) die 2 "hid-msi takes 0-100 or off" ;; esac
			[ "${#v}" -le 3 ] || die 2 "hid-msi takes 0-100 or off"
			range_of "$dir"
			[ "$v" -ge "$LO" ] && [ "$v" -le "$HI" ] || die 2 "outside $LO-$HI"
			;;
		hid-lenovo-go)
			case " $(levels_of "$dir") " in
				*" $v "*) ;;
				*) die 2 "hid-lenovo-go takes one of: $(levels_of "$dir")" ;;
			esac
			;;
	esac
	do_install "$drv" "$dir"
	before="$(mktemp)"
	snapshot "$drv" "$dir" > "$before"
	for a in $(attrs_of "$drv"); do
		if ! put "$dir" "$a" "$v"; then
			restore "$dir" "$before"
			rm -f "$before"
			die 1 "the controller refused $a=$v (its previous values are back)"
		fi
	done
	rm -f "$before"
	log_change "set $v ($drv)"
	echo "value=$v"
}

do_status() {
	k="$(knob)"
	if [ -z "$k" ]; then
		printf 'applies=no\nstate=n/a\n'
		return 0
	fi
	drv="${k%% *}"; dir="${k#* }"
	echo "applies=yes"
	echo "driver=$drv"
	case "$drv" in
		hid-msi)
			echo "kind=percent"
			echo "value=$(rd "$dir/rumble_intensity_left")"
			echo "value_right=$(rd "$dir/rumble_intensity_right")"
			range_of "$dir"
			echo "range=$LO-$HI"
			;;
		hid-lenovo-go)
			echo "kind=levels"
			echo "value=$(rd "$dir/rumble_intensity")"
			echo "levels=$(levels_of "$dir" | tr ' ' ',')"
			;;
	esac
	if [ -f "$STATE/original" ]; then echo "state=on"; else echo "state=off"; fi
}

do_remove() {
	[ -f "$STATE/original" ] || { echo "nothing to undo"; return 0; }
	k="$(knob)"
	if [ -n "$k" ]; then
		restore "${k#* }" "$STATE/original"
	fi
	rm -f "$STATE/original"
	log_change "remove"
	echo "restored"
}

case "${1:-}" in
	install)
		k="$(knob)"
		[ -n "$k" ] || die 2 "no rumble strength setting on this kernel"
		do_install "${k%% *}" "${k#* }"
		echo "installed=yes"
		;;
	set) [ $# -eq 2 ] || die 2 "usage: fix.sh set <0-100>|off|low|medium|high"; do_set "$2" ;;
	status) do_status ;;
	remove) do_remove ;;
	*) die 2 "usage: fix.sh install|remove|status|set <0-100>|off|low|medium|high" ;;
esac
