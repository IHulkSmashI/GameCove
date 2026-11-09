#!/bin/sh
# shellcheck disable=SC2034 # the device variables are read by the checks t_common evals
# ally-fingerprint-drain against fake roots (never the real system).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
FIX="$HERE/fix.sh"
T_NAME=ally-fingerprint-drain
T_PATH0=$PATH
# shellcheck source=fixes/lib/tests/gcfix-testlib.sh
. "$HERE/../lib/tests/gcfix-testlib.sh"
RULE=/etc/udev/rules.d/60-gamecove-ally-fingerprint-drain.rules
F=""
ally() {
	t_dmi "ASUSTeK COMPUTER INC." "ROG Ally RC71L_RC71L" "RC71L"
	t_usb 3-2 1c7a 0588 power/control=on
	F="$R/sys/bus/usb/devices/3-2/power/control"
}
xally() {
	t_dmi "ASUSTeK COMPUTER INC." "ROG Xbox Ally RC73YA_RC73YA" "RC73YA"
	t_usb 3-2 1c7a 0588 power/control=on
}
t_common "$RULE" ally xally '[ "$(cat "$F")" = auto ]' '[ "$(cat "$F")" = on ]'
t_new
ally
mkdir -p "$R/usr/lib/udev/rules.d"
printf '%s\n' 'ACTION=="add", SUBSYSTEM=="usb", TEST=="power/control", ATTR{idVendor}=="1c7a", ATTR{idProduct}=="0588", ATTR{power/control}="auto"' >"$R/usr/lib/udev/rules.d/50-ally-fingerprint.rules"
t_check '[ "$(t_state)" = os-fixed ]' "Bazzite's rule: os-fixed"
t_end
