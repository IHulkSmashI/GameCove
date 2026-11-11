#!/bin/sh
# GameCove fix: the fingerprint reader breaks sleep on the GPD Win 4 and Win Max 2.
# usage: fix.sh install|remove|status|set on|off
#
# Their USB fingerprint readers (Win 4: 2808:9338, Win Max 2: 2541:9711) have no Linux driver and
# keep suspend from working reliably. Taking the reader off the USB bus at boot fixes sleep (Bazzite's
# 50-gpd-win-4-fingerprint.rules / 50-gpd-wm2-fingerprint.rules, aarron-lee/gpd-win-tricks).
# Bazzite ships the rules (os-fixed there); this brings them to SteamOS and other systems.
# The reader does nothing on Linux, so nothing is lost. Undo brings it back after a restart.
set -eu
NAME=gpd-fingerprint
DEVICES="@"  # fixes/lib/fix-devices.txt, from the trait selectors in app/data/fixes.json
RULE=/etc/udev/rules.d/60-gamecove-gpd-fingerprint.rules
FILES="$RULE"
RELOAD=udev
# shellcheck source=fixes/lib/gcfix.sh
. "$(cd "$(dirname "$0")/../lib" && pwd)/gcfix.sh"

file_text() {
	cat <<EOF
$GC_MARK
# Takes the GPD fingerprint reader (no Linux driver) off the USB bus so sleep works.
# Remove with: gamecove-fix $NAME remove (the reader comes back after a restart)
$(gc_rule_lines 'SUBSYSTEM=="usb", ATTR{idVendor}=="2808", ATTR{idProduct}=="9338", ' 'ATTR{remove}="1"')
$(gc_rule_lines 'SUBSYSTEM=="usb", ATTR{idVendor}=="2541", ATTR{idProduct}=="9711", ' 'ATTR{remove}="1"')
EOF
}

readers() {
	for d in "$ROOT"/sys/bus/usb/devices/*; do
		[ -f "$d/idVendor" ] || continue
		case "$(cat "$d/idVendor" 2>/dev/null):$(cat "$d/idProduct" 2>/dev/null)" in
		2808:9338 | 2541:9711) printf '%s\n' "${d#"$ROOT"}" ;;
		esac
	done
}

hw_present() { [ -n "$(readers)" ]; }

# The system does it (Bazzite's 50-gpd-win-4-fingerprint.rules and 50-gpd-wm2-fingerprint.rules): with a reader on
# the bus, a rule for that reader's own id (one for the other model doesn't help); with none left on the bus, a rule
# for either id took it off.
os_fixed() {
	_ids=""
	for _r in $(readers); do
		_ids="$_ids $(cat "$ROOT$_r/idVendor" 2>/dev/null):$(cat "$ROOT$_r/idProduct" 2>/dev/null)"
	done
	if [ -z "$_ids" ]; then
		gc_rule_elsewhere '2808' '9338' 'remove' || gc_rule_elsewhere '2541' '9711' 'remove'
		return
	fi
	for _i in $_ids; do
		gc_rule_elsewhere "${_i%%:*}" "${_i#*:}" 'remove' || return 1
	done
	return 0
}

apply_now() {
	for r in $(readers); do
		[ -f "$ROOT$r/remove" ] && write_value "$r/remove" 1
	done
	return 0
}

# A removed USB device only comes back when the bus is scanned again: at the next boot.
revert_now() {
	printf 'the fingerprint reader comes back after a restart\n' >&2
}

gc_main "$@"
