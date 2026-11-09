#!/bin/sh
# GameCove fix: Intel AX210 Wi-Fi crashes after sleep (GPD Win 5, handhelds with an AX210).
# usage: fix.sh install|remove|status|set on|off
#
# The AX210 tries to enter D3cold during sleep, the iwlwifi driver doesn't handle it and the card
# stays dead, sometimes even across a restart (Bazzite issue 5867, GPD Win 5 and AYANEO Air).
# Bazzite ships this rule since 2026-09 (50-intel-ax200-ax210-disable-d3cold-state.rules), so there
# it reports os-fixed; this brings the same rule to SteamOS and other systems. See fixes/README.md.
set -eu
NAME=ax210-d3cold
DEVICES="@"  # fixes/lib/fix-devices.txt, from the trait selectors in app/data/fixes.json
RULE=/etc/udev/rules.d/60-gamecove-ax210-d3cold.rules
FILES="$RULE"
RELOAD=udev
# shellcheck source=fixes/lib/gcfix.sh
. "$(cd "$(dirname "$0")/../lib" && pwd)/gcfix.sh"

file_text() {
	cat <<EOF
$GC_MARK
# Keeps the Intel AX210 Wi-Fi card out of D3cold: the driver can't wake it from there after sleep.
# Remove with: gamecove-fix $NAME remove
$(gc_rule_lines 'ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x8086", ATTR{device}=="0x2725", ' 'ATTR{d3cold_allowed}="0"')
EOF
}

cards() {
	for d in "$ROOT"/sys/bus/pci/devices/*; do
		[ -f "$d/d3cold_allowed" ] || continue
		[ "$(cat "$d/vendor" 2>/dev/null)" = 0x8086 ] || continue
		[ "$(cat "$d/device" 2>/dev/null)" = 0x2725 ] || continue
		printf '%s\n' "${d#"$ROOT"}"
	done
}

hw_present() { [ -n "$(cards)" ]; }

os_fixed() { gc_rule_elsewhere '0x2725' 'd3cold_allowed'; }

apply_now() {
	for c in $(cards); do
		save_value "$c/d3cold_allowed"
		write_value "$c/d3cold_allowed" 0
	done
}

gc_main "$@"
