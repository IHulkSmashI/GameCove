#!/bin/sh
# GameCove fix: the ROG Ally's battery drains while it is switched off.
# usage: fix.sh install|remove|status|set on|off
#
# The Ally's fingerprint reader (USB 1c7a:0588) stays powered unless USB autosuspend is on for it,
# which drains the battery even with the device off. Bazzite ships a rule that turns autosuspend on
# for it (50-ally-fingerprint.rules), so there it reports os-fixed; this brings it to SteamOS and
# others. See fixes/README.md.
set -eu
NAME=ally-fingerprint-drain
DEVICES="asus-rog-ally asus-rog-ally-x"
RULE=/etc/udev/rules.d/60-gamecove-ally-fingerprint-drain.rules
FILES="$RULE"
RELOAD=udev
# shellcheck source=fixes/lib/gcfix.sh
. "$(cd "$(dirname "$0")/../lib" && pwd)/gcfix.sh"

file_text() {
	cat <<EOF
$GC_MARK
# Lets the ROG Ally's fingerprint reader power down, so the battery doesn't drain while it's off.
# Remove with: gamecove-fix $NAME remove
ACTION=="add", SUBSYSTEM=="usb", TEST=="power/control", ATTR{idVendor}=="1c7a", ATTR{idProduct}=="0588", ATTR{[dmi/id]sys_vendor}=="ASUSTeK COMPUTER INC.", ATTR{power/control}="auto"
EOF
}

readers() {
	for d in "$ROOT"/sys/bus/usb/devices/*; do
		[ -f "$d/idVendor" ] && [ -f "$d/power/control" ] || continue
		[ "$(cat "$d/idVendor" 2>/dev/null):$(cat "$d/idProduct" 2>/dev/null)" = 1c7a:0588 ] || continue
		printf '%s\n' "${d#"$ROOT"}"
	done
}

hw_present() { [ -n "$(readers)" ]; }

os_fixed() { gc_rule_elsewhere '1c7a' '0588' 'power/control'; }

apply_now() {
	for r in $(readers); do
		save_value "$r/power/control"
		write_value "$r/power/control" auto
	done
}

gc_main "$@"
