#!/bin/sh
# shellcheck disable=SC2034 # the device variables are read by the checks t_common evals
# ax210-d3cold against fake roots (never the real system).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
FIX="$HERE/fix.sh"
T_NAME=ax210-d3cold
T_PATH0=$PATH
# shellcheck source=fixes/lib/tests/gcfix-testlib.sh
. "$HERE/../lib/tests/gcfix-testlib.sh"
RULE=/etc/udev/rules.d/60-gamecove-ax210-d3cold.rules
C=""
win5() {
	t_dmi "GPD" "G1618-05" "G1618-05"
	t_pci 0000:c4:00.0 0x8086 0x2725 0x028000 d3cold_allowed=1
	C="$R/sys/bus/pci/devices/0000:c4:00.0/d3cold_allowed"
}
laptop() {
	t_dmi "Dell Inc." "XPS 13 9310" "0F0F0F"
	t_pci 0000:c4:00.0 0x8086 0x2725 0x028000 d3cold_allowed=1
}
t_common "$RULE" win5 laptop '[ "$(cat "$C")" = 0 ]' '[ "$(cat "$C")" = 1 ]'
# Bazzite's own rule (verbatim): os-fixed
t_new
win5
mkdir -p "$R/usr/lib/udev/rules.d"
cat >"$R/usr/lib/udev/rules.d/50-intel-ax200-ax210-disable-d3cold-state.rules" <<'R'
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x8086", ATTR{device}=="0x2725", ATTR{d3cold_allowed}="0"
R
t_check '[ "$(t_state)" = os-fixed ]' "Bazzite's rule: os-fixed"
# any listed handheld may use it; one without an AX210 doesn't need it
t_new
t_dmi "AYANEO" "AYANEO 3" "AB09"
t_pci 0000:c4:00.0 0x14c3 0x0616 0x028000 d3cold_allowed=1
t_check 'sh "$FIX" status | grep -qx applies=yes' "any handheld: applies"
t_check '[ "$(t_state)" = not-needed ]' "no AX210: not-needed"
# No rule we can read, but the card already stays out of D3cold: the behaviour decides
t_new
win5
for d in "$R"/sys/bus/pci/devices/*; do [ "$(cat "$d/device")" = 0x2725 ] && printf '0\n' >"$d/d3cold_allowed"; done
t_check '[ "$(t_state)" = os-fixed ]' "d3cold_allowed already 0 without our rule: os-fixed"
t_new
win5
sh "$FIX" install >/dev/null
t_check 'sh "$FIX" status | grep -qx os_fixed=no' "0 because of our own rule: not os-fixed"
t_end
