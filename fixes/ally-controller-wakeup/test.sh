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
# The Xbox Ally X20 shares the controller (0b05:1b4c) and has sys_vendor "ASUS": it gets the fix too.
t_new
t_dmi "ASUS" "ROG Xbox Ally X20 RC74XA" "RC74XA"
t_usb 1-3 0b05 1b4c power/wakeup=enabled
t_check 'sh "$FIX" status | grep -qx "applies=yes"' "Xbox Ally X20: applies"
sh "$FIX" install >/dev/null
t_check '[ "$(cat "$R/sys/bus/usb/devices/1-3/power/wakeup")" = disabled ]' "Xbox Ally X20: controller no longer wakes it"
t_check 'grep -q "sys_vendor}==\"ASUS\", ATTR{\[dmi/id\]board_name}==\"RC74XA\"" "$R$RULE"' "rule matches the X20's DMI"
t_check '! grep -q "RC71L" "$R$RULE"' "rule doesn't match the first Ally (other controller)"
t_new
allyx
mkdir -p "$R/usr/lib/udev/rules.d"
printf '%s\n' 'ACTION=="add", SUBSYSTEM=="usb", DRIVER=="usb", ATTR{idVendor}=="0b05", ATTR{idProduct}=="1b4c", ATTR{power/wakeup}="disabled"' >"$R/usr/lib/udev/rules.d/50-ally-x-controller.rules"
t_check '[ "$(t_state)" = os-fixed ]' "Bazzite's rule: os-fixed"
# No rule we can read, but the controller already can't wake it: the behaviour decides
t_new
allyx
printf 'disabled\n' >"$R/sys/bus/usb/devices/1-3/power/wakeup"
t_check '[ "$(t_state)" = os-fixed ]' "wakeup already disabled without our rule: os-fixed"
t_new
allyx
sh "$FIX" install >/dev/null
t_check 'sh "$FIX" status | grep -qx os_fixed=no' "disabled by our own rule: not os-fixed"
t_end
