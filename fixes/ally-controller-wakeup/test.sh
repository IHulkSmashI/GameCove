#!/bin/sh
# shellcheck disable=SC2034 # the device variables are read by the checks t_common evals
# ally-controller-wakeup against fake roots (never the real system).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
FIX="$HERE/fix.sh"
T_NAME=ally-controller-wakeup
T_PATH0=$PATH
# shellcheck source=fixes/lib/tests/gcfix-testlib.sh
. "$HERE/../lib/tests/gcfix-testlib.sh"
RULE=/etc/udev/rules.d/60-gamecove-ally-controller-wakeup.rules
P=""
allyx() {
	t_dmi "ASUSTeK COMPUTER INC." "ROG Xbox Ally X RC73XA_RC73XA" "RC73XA"
	t_usb 1-3 0b05 1b4c power/wakeup=enabled
	t_usb 1-4 0b05 1abe power/wakeup=enabled
	P="$R/sys/bus/usb/devices/1-3/power/wakeup"
}
ally() {
	t_dmi "ASUSTeK COMPUTER INC." "ROG Ally RC71L_RC71L" "RC71L"
	t_usb 1-3 0b05 1b4c power/wakeup=enabled
}
t_common "$RULE" allyx ally '[ "$(cat "$P")" = disabled ]' '[ "$(cat "$P")" = enabled ]'
t_new
allyx
sh "$FIX" install >/dev/null
t_check '[ "$(cat "$R/sys/bus/usb/devices/1-4/power/wakeup")" = enabled ]' "other USB devices untouched"
t_new
allyx
mkdir -p "$R/usr/lib/udev/rules.d"
printf '%s\n' 'ACTION=="add", SUBSYSTEM=="usb", DRIVER=="usb", ATTR{idVendor}=="0b05", ATTR{idProduct}=="1b4c", ATTR{power/wakeup}="disabled"' >"$R/usr/lib/udev/rules.d/50-ally-x-controller.rules"
t_check '[ "$(t_state)" = os-fixed ]' "Bazzite's rule: os-fixed"
t_end
