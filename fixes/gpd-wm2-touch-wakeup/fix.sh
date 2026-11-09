#!/bin/sh
# GameCove fix (optional): the GPD Win Max 2 wakes up by itself right after going to sleep.
# usage: fix.sh install|remove|status|set on|off
#
# Its I2C touch device (PNP0C50:00) is a wakeup source and fires during sleep, so the Win Max 2
# (2025 model especially) wakes again at once. Switching that device's wakeup off is the fix used in
# aarron-lee/gpd-win-tricks (wm2-suspend-udev.sh, from Cryolitia's NixOS config; noted there as not
# yet widely tested), hence optional. Touch still works while awake; the power button still wakes it.
set -eu
NAME=gpd-wm2-touch-wakeup
DEVICES="gpd-win-max-2"
RULE=/etc/udev/rules.d/60-gamecove-gpd-wm2-touch-wakeup.rules
FILES="$RULE"
RELOAD=udev
# shellcheck source=fixes/lib/gcfix.sh
. "$(cd "$(dirname "$0")/../lib" && pwd)/gcfix.sh"

file_text() {
	cat <<EOF2
$GC_MARK
# The Win Max 2's I2C touch device must not wake it from sleep.
# Remove with: gamecove-fix $NAME remove
ACTION=="add", SUBSYSTEM=="i2c", ATTR{name}=="PNP0C50:00", ATTR{[dmi/id]sys_vendor}=="GPD", ATTR{power/wakeup}="disabled"
EOF2
}

touch_dev() {
	for d in "$ROOT"/sys/bus/i2c/devices/*; do
		[ -f "$d/power/wakeup" ] || continue
		[ "$(cat "$d/name" 2>/dev/null)" = PNP0C50:00 ] || continue
		printf '%s\n' "${d#"$ROOT"}"
	done
}

hw_present() { [ -n "$(touch_dev)" ]; }

os_fixed() {
	gc_rule_elsewhere 'PNP0C50:00' 'power/wakeup' && return 0
	gc_installed && return 1
	t="$(touch_dev)"
	[ -n "$t" ] && [ "$(cat "$ROOT$t/power/wakeup" 2>/dev/null)" = disabled ]
}

apply_now() {
	for t in $(touch_dev); do
		save_value "$t/power/wakeup"
		write_value "$t/power/wakeup" disabled
	done
}

gc_main "$@"
