#!/bin/sh
# shellcheck disable=SC2034 # the device variables are read by the checks t_common evals
# gpd-fingerprint against fake roots (never the real system).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
FIX="$HERE/fix.sh"
T_NAME=gpd-fingerprint
T_PATH0=$PATH
# shellcheck source=fixes/lib/tests/gcfix-testlib.sh
. "$HERE/../lib/tests/gcfix-testlib.sh"
RULE=/etc/udev/rules.d/60-gamecove-gpd-fingerprint.rules
U=""
win4() {
	t_dmi "GPD" "G1618-04" "Default string"
	t_usb 3-3 2808 9338 remove=0
	U="$R/sys/bus/usb/devices/3-3/remove"
}
other() {
	t_dmi "GPD" "G1618-05" "G1618-05"
	t_usb 3-3 2808 9338 remove=0
}
t_common "$RULE" win4 other '[ "$(cat "$U")" = 1 ]' 'true'
t_new
win4
t_check 'sh "$FIX" install >/dev/null; sh "$FIX" remove 2>&1 | grep -q "after a restart"' "undo says the reader comes back after a restart"
t_new
t_dmi "GPD" "G1619-04" "Default string"
t_usb 1-4 2541 9711 remove=0
t_check '[ "$(t_state)" = off ]' "Win Max 2 reader: needed"
sh "$FIX" install >/dev/null
t_check '[ "$(cat "$R/sys/bus/usb/devices/1-4/remove")" = 1 ]' "Win Max 2 reader taken off the bus"
t_check 'grep -q "ATTR{\[dmi/id\]sys_vendor}==\"GPD\"" "$R$RULE"' "rule is gated on GPD"
# the reader is already gone (Bazzite rule ran) and Bazzite's rule is there
t_new
t_dmi "GPD" "G1618-04" "Default string"
mkdir -p "$R/usr/lib/udev/rules.d"
printf '%s\n' '# Disable FP sensor on the GPD Win 4' 'SUBSYSTEM=="usb", ATTR{idVendor}=="2808", ATTR{idProduct}=="9338", ATTR{remove}="1"' >"$R/usr/lib/udev/rules.d/50-gpd-win-4-fingerprint.rules"
t_check '[ "$(t_state)" = os-fixed ]' "Bazzite's rule: os-fixed"
t_new
t_dmi "GPD" "G1618-04" "Default string"
t_check '[ "$(t_state)" = not-needed ]' "no reader: not-needed"
# A rule for the other model's reader doesn't fix this one (Win Max 2 reader, only the Win 4 rule present)
t_new
t_dmi "GPD" "G1619-04" "Default string"
t_usb 1-4 2541 9711 remove=0
mkdir -p "$R/usr/lib/udev/rules.d"
printf '%s\n' 'SUBSYSTEM=="usb", ATTR{idVendor}=="2808", ATTR{idProduct}=="9338", ATTR{remove}="1"' >"$R/usr/lib/udev/rules.d/50-gpd-win-4-fingerprint.rules"
t_check '[ "$(t_state)" = off ]' "Win 4 rule only, Win Max 2 reader on the bus: still needed"
printf '%s\n' 'SUBSYSTEM=="usb", ATTR{idVendor}=="2541", ATTR{idProduct}=="9711", ATTR{remove}="1"' >"$R/usr/lib/udev/rules.d/50-gpd-wm2-fingerprint.rules"
t_check '[ "$(t_state)" = os-fixed ]' "its own rule there too: os-fixed"
t_end
