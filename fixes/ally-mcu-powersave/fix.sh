#!/bin/sh
# GameCove fix (optional): less battery drain while an ROG Ally sleeps (MCU powersave).
# usage: fix.sh install|remove|status|set on|off
#
# The Ally's controller MCU can power down during sleep ("MCU powersave", asus-wmi mcu_powersave or
# asus-armoury attributes/mcu_powersave). SimpleDeckyTDP turns it on by default on the Ally series
# ("Asus extreme powersave": reduces power consumption during suspend; needs updated MCU firmware,
# Ally 319+ / Ally X 314+). Optional because an old MCU firmware can leave the controller dead after
# waking; update the firmware in Windows / Armoury Crate first. See fixes/README.md.
#
# Never automatic (no "auto" in app/data/fixes.json) and refused unless the MCU firmware is new
# enough: install reads the version over hidraw first (mcu_version.py; kernel hid-asus minimums,
# Ally 319, Ally X 314) and status says "unsupported" with the reason otherwise (review S1-3).
set -eu
NAME=ally-mcu-powersave
DEVICES="@"  # fixes/lib/fix-devices.txt, from the trait selectors in app/data/fixes.json
RULE=/etc/udev/rules.d/60-gamecove-ally-mcu-powersave.rules
FILES="$RULE"
RELOAD=udev
LEGACY=/sys/devices/platform/asus-nb-wmi/mcu_powersave
ARMOURY=/sys/class/firmware-attributes/asus-armoury/attributes/mcu_powersave/current_value
# shellcheck source=fixes/lib/gcfix.sh
. "$(cd "$(dirname "$0")/../lib" && pwd)/gcfix.sh"
# shellcheck source=fixes/lib/ally-mcu.sh
. "$GC_LIB/ally-mcu.sh"

# gcfix: why it can't be applied here now ("" = it can). Strict as root: install checks for real.
blocked() {
	if [ "$(id -u)" -eq 0 ] || [ -n "$ROOT" ]; then
		ally_mcu_blocked strict || true
	else
		ally_mcu_blocked || true
	fi
}

file_text() {
	cat <<EOF2
$GC_MARK
# Lets the ROG Ally's controller MCU power down while the handheld sleeps.
# Remove with: gamecove-fix $NAME remove
$(gc_rule_lines 'ACTION=="add", SUBSYSTEM=="platform", KERNEL=="asus-nb-wmi", TEST=="mcu_powersave", ' 'ATTR{mcu_powersave}="1"')
$(gc_rule_lines 'ACTION=="add", SUBSYSTEM=="firmware-attributes", KERNEL=="asus-armoury", TEST=="attributes/mcu_powersave/current_value", ' 'ATTR{attributes/mcu_powersave/current_value}="1"')
EOF2
}

# The switch this kernel has, as a real path ("" without one).
node() {
	if [ -f "$ROOT$ARMOURY" ]; then echo "$ARMOURY"; elif [ -f "$ROOT$LEGACY" ]; then echo "$LEGACY"; fi
}

hw_present() { [ -n "$(node)" ]; }

# Already on without our rule (Bazzite's own MCU handling, or set in Armoury Crate).
os_fixed() {
	gc_rule_elsewhere 'mcu_powersave' && return 0
	gc_installed && return 1
	n="$(node)"
	[ -n "$n" ] && [ "$(cat "$ROOT$n" 2>/dev/null)" = 1 ]
}

apply_now() {
	n="$(node)"
	[ -n "$n" ] || return 0
	save_value "$n"
	write_value "$n" 1
}

gc_main "$@"
