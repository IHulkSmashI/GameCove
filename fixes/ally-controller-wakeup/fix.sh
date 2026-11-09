#!/bin/sh
# GameCove fix: a nudge of the sticks wakes the ROG Ally X / Xbox Ally / Xbox Ally X from sleep.
# usage: fix.sh install|remove|status|set on|off
#
# Their built-in controller (USB 0b05:1b4c) is a wakeup source, so stick movement while the device
# is going to sleep, or in a bag, wakes it again. Bazzite ships a rule that switches that off
# (50-ally-x-controller.rules), so there it reports os-fixed; this brings it to SteamOS and others.
# The power button still wakes it. See fixes/README.md.
set -eu
NAME=ally-controller-wakeup
DEVICES="@"  # fixes/lib/fix-devices.txt, from the trait selectors in app/data/fixes.json
RULE=/etc/udev/rules.d/60-gamecove-ally-controller-wakeup.rules
FILES="$RULE"
RELOAD=udev
# shellcheck source=fixes/lib/gcfix.sh
. "$(cd "$(dirname "$0")/../lib" && pwd)/gcfix.sh"

file_text() {
	cat <<EOF
$GC_MARK
# The built-in controller (0b05:1b4c: Ally X, Xbox Ally, X, X20) must not wake it from sleep (stick bumps).
# Remove with: gamecove-fix $NAME remove
$(gc_rule_lines 'ACTION=="add", SUBSYSTEM=="usb", DRIVER=="usb", ATTR{idVendor}=="0b05", ATTR{idProduct}=="1b4c", ' 'ATTR{power/wakeup}="disabled"')
EOF
}

pads() {
	for d in "$ROOT"/sys/bus/usb/devices/*; do
		[ -f "$d/idVendor" ] && [ -f "$d/power/wakeup" ] || continue
		[ "$(cat "$d/idVendor" 2>/dev/null):$(cat "$d/idProduct" 2>/dev/null)" = 0b05:1b4c ] || continue
		printf '%s\n' "${d#"$ROOT"}"
	done
}

hw_present() { [ -n "$(pads)" ]; }

os_fixed() { gc_rule_elsewhere '1b4c' 'power/wakeup'; }

apply_now() {
	for p in $(pads); do
		save_value "$p/power/wakeup"
		write_value "$p/power/wakeup" disabled
	done
}

gc_main "$@"
