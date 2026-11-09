#!/bin/sh
# GameCove root action: handheld RGB lights through the kernel LED class.
# Run by packaging/libexec/gamecove-fix (and, without a password, through
# gamecove-fix-set: `set` and `status` only). The app's side is
# app/scripts/controls/input/leds.gd.
#
# Nodes: /sys/class/leds/<name> for <name> matching *:rgb:joystick_rings,
# multicolor:chassis or *:rgb:spectra_zone_*, that have multi_index,
# multi_intensity and max_brightness (multicolor LED class). Drivers: hid-asus
# (ally:), hid-lenovo-go (go:), hid-lenovo-go-s (go_s:), hid-msi (msi_claw:),
# ayaneo-platform (ayaneo:, multicolor:chassis), ayn-ec (ayn:), zotac-zone-platform
# (zotac:rgb:spectra_zone_0/1). Optional attributes written when present:
# enabled (true|false), effect (one of effect_index), speed (inside speed_range),
# led_mode (AYN: 1 = manual colour), profile/mode (Legion Go rings). Nothing else
# is touched.
#
# Device handling copied from HueSync (github.com/honjow/HueSync, tested on these
# handhelds), py_modules/devices/legion_go2.py: the go ring only lights with
# enabled=true and mode=custom; profile must be set (3) before anything else because
# the driver's initial profile isn't a valid user profile; write order profile,
# mode, speed, multi_intensity, brightness, effect, enabled; colours scale by
# multi_max_intensity (the ring is 0-100, not 0-255). py_modules/devices/asus_ally.py:
# the Ally's multi_index may list 12 channels (4 zones x RGB); each zone gets the colour.
# hid-asus-ally (OGC patch 0155) lists "rgb rgb rgb rgb" instead: one packed 0xRRGGBB
# intensity per zone; every zone gets the colour.
#
#   fix.sh set <zone>,<rrggbb>,<percent>[,<effect>[,<speed percent>]]
#                     zone: all, or the node's index in name order (0..9)
#   fix.sh set off    every node dark: enabled=false where it exists (brightness kept),
#                     else brightness 0
#   fix.sh status     applies=, leds=, per node ledN=name ledN_rgb=rrggbb
#                     ledN_brightness=percent ledN_effect= ..., state=on|off
#   fix.sh install    remember every node's current values (first set does it too)
#   fix.sh remove     put the remembered values back and forget them
#
# Every written value is read back; if a node refuses one, that node gets its
# values from before the set back and the run fails.
# GAMECOVE_ROOT is a filesystem prefix for tests (empty on a real system).
# Exit codes: 0 done, 1 failed, 2 bad usage or no RGB node here.
set -eu

ROOT="${GAMECOVE_ROOT:-}"
STATE="$ROOT/var/lib/gamecove/fixes/controller-led"
# shellcheck source=fixes/lib/logcap.sh
. "$(cd "$(dirname "$0")/../lib" && pwd)/logcap.sh"
LEDS="$ROOT/sys/class/leds"

die() { printf 'controller-led: %s\n' "$2" >&2; exit "$1"; }

log_change() {
	mkdir -p "$STATE"
	log_cap "$STATE/changes.log"
	printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$STATE/changes.log"
}

nodes() {
	[ -d "$LEDS" ] || return 0
	for d in "$LEDS"/*; do
		n="${d##*/}"
		case "$n" in
			*:rgb:joystick_rings|multicolor:chassis|*:rgb:spectra_zone_[0-9]) ;;
			*) continue ;;
		esac
		[ -f "$d/multi_index" ] && [ -f "$d/multi_intensity" ] && [ -f "$d/max_brightness" ] || continue
		printf '%s\n' "$n"
	done | LC_ALL=C sort
}

rd() { cat "$1" 2>/dev/null | tr -d '\n' || true; }
wr() { printf '%s\n' "$2" 2>/dev/null > "$1"; }

# chan_max <node dir> <position>: the channel's maximum (multi_max_intensity, else 255)
chan_max() {
	m="$(rd "$1/multi_max_intensity" | cut -d' ' -f"$2")"
	case "$m" in ''|*[!0-9]*|0) echo 255 ;; *) echo "$m" ;; esac
}

# rgb_line <node dir> <rrggbb>: multi_intensity values in multi_index order
rgb_line() {
	hex="$2"
	r=$(printf '%d' "0x$(printf '%s' "$hex" | cut -c1-2)")
	g=$(printf '%d' "0x$(printf '%s' "$hex" | cut -c3-4)")
	b=$(printf '%d' "0x$(printf '%s' "$hex" | cut -c5-6)")
	out=""
	i=1
	for c in $(rd "$1/multi_index"); do
		case "$c" in
			red) v=$r ;;
			green) v=$g ;;
			blue) v=$b ;;
			rgb) v=$(((r << 16) | (g << 8) | b)) ;;   # hid-asus Ally zone: packed 0xRRGGBB
			*) v=0 ;;
		esac
		mx="$(chan_max "$1" "$i")"
		[ "$c" = rgb ] || [ "$mx" -eq 255 ] || v=$(((v * mx + 127) / 255))
		out="$out $v"
		i=$((i + 1))
	done
	printf '%s\n' "${out# }"
}

# hex_of <node dir>: first red/green/blue values as rrggbb
hex_of() {
	# shellcheck disable=SC2046  # one argument per intensity value on purpose
	set -- "$1" $(rd "$1/multi_intensity")
	d="$1"
	shift
	r=0; g=0; b=0
	i=1
	for c in $(rd "$d/multi_index"); do
		v="${1:-0}"
		[ $# -gt 0 ] && shift
		mx="$(chan_max "$d" "$i")"
		i=$((i + 1))
		if [ "$c" = rgb ]; then
			printf '%02x%02x%02x\n' $(((v >> 16) & 255)) $(((v >> 8) & 255)) $((v & 255))
			return 0
		fi
		[ "$mx" -eq 255 ] || v=$(((v * 255 + mx / 2) / mx))
		case "$c" in
			red) r=$v ;;
			green) g=$v ;;
			blue) b=$v ;;
		esac
	done
	printf '%02x%02x%02x\n' "$r" "$g" "$b"
}

# snapshot <node dir>: key=value lines of what we may change
snapshot() {
	for a in multi_intensity brightness enabled effect speed led_mode profile mode; do
		[ -f "$1/$a" ] && printf '%s=%s\n' "$a" "$(rd "$1/$a")"
	done
	return 0
}

# restore <node dir> <snapshot file>
restore() {
	# colour and effect first, brightness/enabled last (some drivers apply on brightness)
	for a in led_mode profile mode effect speed multi_intensity enabled brightness; do
		v="$(sed -n "s/^$a=//p" "$2" | head -n 1)"
		[ -n "$v" ] && [ -f "$1/$a" ] && wr "$1/$a" "$v" || true
	done
	return 0
}

do_install() {
	mkdir -p "$STATE"
	[ -f "$STATE/original" ] && return 0
	: > "$STATE/original.tmp"
	for n in $(nodes); do
		snapshot "$LEDS/$n" | sed "s|^|$n	|" >> "$STATE/original.tmp"
	done
	mv "$STATE/original.tmp" "$STATE/original"
}

# set_node <node> <rrggbb> <percent> <effect> <speed percent>
set_node() {
	d="$LEDS/$1"
	before="$(mktemp)"
	snapshot "$d" > "$before"
	if ! set_node_inner "$d" "$2" "$3" "$4" "$5"; then
		restore "$d" "$before"
		rm -f "$before"
		return 1
	fi
	rm -f "$before"
}

set_node_inner() {
	d="$1"; hex="$2"; pct="$3"; eff="$4"; spd="$5"
	if [ -n "$eff" ]; then
		[ -f "$d/effect" ] || { echo "$(basename "$d"): no effects" >&2; return 1; }
		case " $(rd "$d/effect_index") " in
			*" $eff "*) ;;
			*) echo "$(basename "$d"): no effect $eff" >&2; return 1 ;;
		esac
	fi
	[ -f "$d/led_mode" ] && { wr "$d/led_mode" 1 || true; }
	if [ -f "$d/profile" ]; then
		case "$(rd "$d/profile")" in
			1|2|3) ;;
			*) wr "$d/profile" 3 || return 1 ;;
		esac
	fi
	if [ -f "$d/mode" ] && [ -f "$d/mode_index" ]; then
		case " $(rd "$d/mode_index") " in
			*" custom "*) [ "$(rd "$d/mode")" = custom ] || { wr "$d/mode" custom || return 1; } ;;
		esac
	fi
	if [ -n "$spd" ] && [ -f "$d/speed" ] && [ -f "$d/speed_range" ]; then
		lo="$(rd "$d/speed_range" | cut -d- -f1)"; hi="$(rd "$d/speed_range" | cut -d- -f2)"
		case "$lo$hi" in ''|*[!0-9]*) return 1 ;; esac
		s=$((lo + (hi - lo) * spd / 100))
		wr "$d/speed" "$s" || return 1
		[ "$(rd "$d/speed")" = "$s" ] || return 1
	fi
	line="$(rgb_line "$d" "$hex")"
	wr "$d/multi_intensity" "$line" || return 1
	[ "$(rd "$d/multi_intensity")" = "$line" ] || return 1
	max="$(rd "$d/max_brightness")"
	case "$max" in ''|*[!0-9]*) return 1 ;; esac
	bri=$(((max * pct + 50) / 100))
	wr "$d/brightness" "$bri" || return 1
	[ "$(rd "$d/brightness")" = "$bri" ] || return 1
	if [ -n "$eff" ]; then
		wr "$d/effect" "$eff" || return 1
		[ "$(rd "$d/effect")" = "$eff" ] || return 1
	fi
	if [ -f "$d/enabled" ]; then
		if [ "$pct" -gt 0 ]; then wr "$d/enabled" true || return 1; else wr "$d/enabled" false || true; fi
	fi
	return 0
}

do_set() {
	spec="${1:-}"
	all="$(nodes)"
	[ -n "$all" ] || die 2 "no RGB LED node on this kernel"
	if [ "$spec" = off ]; then
		do_install
		for n in $all; do
			d="$LEDS/$n"
			# off is enabled=false where the node has it, so the brightness the user set
			# survives (hid-msi, hid-lenovo-go); brightness 0 only where there is no switch
			if [ -f "$d/enabled" ] && wr "$d/enabled" false && [ "$(rd "$d/enabled")" = false ]; then
				continue
			fi
			wr "$d/brightness" 0 || die 1 "$n refused brightness 0"
		done
		log_change "set off"
		echo "state=off"
		return 0
	fi
	old_ifs="$IFS"; IFS=,
	# shellcheck disable=SC2086  # split on commas on purpose
	set -- $spec
	IFS="$old_ifs"
	[ $# -ge 3 ] && [ $# -le 5 ] || die 2 "set needs <zone>,<rrggbb>,<percent>[,<effect>[,<speed>]]"
	zone="$1"; hex="$2"; pct="$3"; eff="${4:-}"; spd="${5:-}"
	case "$zone" in all|[0-9]) ;; *) die 2 "zone must be all or 0-9" ;; esac
	case "$hex" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) die 2 "colour must be rrggbb (lower case)" ;; esac
	# no leading zeros: $((...)) would read "077" as octal (review M1)
	case "$pct" in ''|*[!0-9]*|0?*) die 2 "percent must be 0-100" ;; esac
	[ "$pct" -le 100 ] || die 2 "percent must be 0-100"
	case "$eff" in ''|*[!a-z]*) [ -z "$eff" ] || die 2 "bad effect name" ;; esac
	case "$spd" in ''|*[!0-9]*|0?*) [ -z "$spd" ] || die 2 "speed must be 0-100" ;; esac
	[ -z "$spd" ] || [ "$spd" -le 100 ] || die 2 "speed must be 0-100"
	targets=""
	i=0
	for n in $all; do
		if [ "$zone" = all ] || [ "$zone" = "$i" ]; then targets="$targets $n"; fi
		i=$((i + 1))
	done
	[ -n "$targets" ] || die 2 "no zone $zone here"
	do_install
	for n in $targets; do
		set_node "$n" "$hex" "$pct" "$eff" "$spd" || die 1 "$n refused $spec (its previous values are back)"
	done
	log_change "set $spec"
	echo "state=on"
}

do_status() {
	all="$(nodes)"
	if [ -z "$all" ]; then
		printf 'applies=no\nstate=n/a\n'
		return 0
	fi
	echo "applies=yes"
	echo "leds=$(echo $all | tr ' ' ',')"
	i=0
	for n in $all; do
		d="$LEDS/$n"
		max="$(rd "$d/max_brightness")"
		bri="$(rd "$d/brightness")"
		case "$max$bri" in ''|*[!0-9]*) pct=0 ;; *) pct=$(((bri * 100 + max / 2) / max)) ;; esac
		printf 'led%s=%s\nled%s_rgb=%s\nled%s_brightness=%s\n' "$i" "$n" "$i" "$(hex_of "$d")" "$i" "$pct"
		[ -f "$d/effect" ] && printf 'led%s_effect=%s\nled%s_effects=%s\n' "$i" "$(rd "$d/effect")" "$i" "$(rd "$d/effect_index" | tr ' ' ',')"
		i=$((i + 1))
	done
	if [ -f "$STATE/original" ]; then echo "state=on"; else echo "state=off"; fi
}

do_remove() {
	[ -f "$STATE/original" ] || { echo "nothing to undo"; return 0; }
	for n in $(cut -f1 "$STATE/original" | LC_ALL=C sort -u); do
		[ -d "$LEDS/$n" ] || continue
		tmp="$(mktemp)"
		grep "^$n	" "$STATE/original" | cut -f2- > "$tmp"
		restore "$LEDS/$n" "$tmp"
		rm -f "$tmp"
	done
	rm -f "$STATE/original"
	log_change "remove"
	echo "restored"
}

case "${1:-}" in
	install) [ -n "$(nodes)" ] || die 2 "no RGB LED node on this kernel"; do_install; echo "installed=yes" ;;
	set) [ $# -eq 2 ] || die 2 "usage: fix.sh set <spec>|off"; do_set "$2" ;;
	status) do_status ;;
	remove) do_remove ;;
	*) die 2 "usage: fix.sh install|remove|status|set <zone>,<rrggbb>,<percent>[,<effect>[,<speed>]]|off" ;;
esac
