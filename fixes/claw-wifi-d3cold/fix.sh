#!/bin/sh
# GameCove fix (optional): Wi-Fi doesn't come back after sleep on the Intel MSI Claws.
# usage: fix.sh install|remove|status|set on|off
#
# On the Claw A1M (and reported on the Lunar Lake Claws) the Intel Wi-Fi card can drop into the
# deepest PCIe power state (D3cold) during sleep and not come back, so Wi-Fi is gone until a restart.
# Keeping the card out of D3cold fixes it (SteamOS issues 2742 / 2703, the same cure Bazzite already
# ships for the Intel AX210). Costs a little battery while asleep, so it's optional. See fixes/README.md.
set -eu
NAME=claw-wifi-d3cold
DEVICES="@"  # fixes/lib/fix-devices.txt, from the trait selectors in app/data/fixes.json
RULE=/etc/udev/rules.d/60-gamecove-claw-wifi-d3cold.rules
FILES="$RULE"
RELOAD=udev
# shellcheck source=fixes/lib/gcfix.sh
. "$(cd "$(dirname "$0")/../lib" && pwd)/gcfix.sh"

file_text() {
	cat <<EOF
$GC_MARK
# Keeps the Claw's Intel Wi-Fi card out of D3cold, so it comes back after sleep.
# Remove with: gamecove-fix $NAME remove
$(gc_rule_lines 'ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x8086", ATTR{class}=="0x028000", ' 'ATTR{d3cold_allowed}="0"')
EOF
}

# Intel network controllers (class 0x0280xx) with a d3cold switch, as real paths.
wifi_cards() {
	for d in "$ROOT"/sys/bus/pci/devices/*; do
		[ -f "$d/d3cold_allowed" ] || continue
		[ "$(cat "$d/vendor" 2>/dev/null)" = 0x8086 ] || continue
		case "$(cat "$d/class" 2>/dev/null)" in 0x0280*) ;; *) continue ;; esac
		printf '%s\n' "${d#"$ROOT"}"
	done
}

hw_present() { [ -n "$(wifi_cards)" ]; }

# Fixed by the system: its own rule, or D3cold already off for every card without ours.
os_fixed() {
	gc_rule_elsewhere 'd3cold_allowed' '0x028000' 'MS-1T' && return 0
	gc_installed && return 1
	cards="$(wifi_cards)"
	[ -n "$cards" ] || return 1
	for c in $cards; do
		[ "$(cat "$ROOT$c/d3cold_allowed" 2>/dev/null)" = 0 ] || return 1
	done
	return 0
}

apply_now() {
	for c in $(wifi_cards); do
		save_value "$c/d3cold_allowed"
		write_value "$c/d3cold_allowed" 0
	done
}

gc_main "$@"
