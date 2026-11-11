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
# A handheld without the reader trait (Legion Go), even with the same USB id plugged in.
other() {
	t_dmi "LENOVO" "83E1" "LNVNB161216"
	t_usb 3-2 1c7a 0588 power/control=on
}
t_common "$RULE" ally other '[ "$(cat "$F")" = auto ]' '[ "$(cat "$F")" = on ]'
# Siblings by trait: the Xbox Ally X20 (sys_vendor "ASUS") is offered it, and the rule matches its DMI.
t_new
t_dmi "ASUS" "ROG Xbox Ally X20 RC74XA" "RC74XA"
t_usb 3-2 1c7a 0588 power/control=on
t_check 'sh "$FIX" status | grep -qx "applies=yes"' "Xbox Ally X20 (power-button reader trait): applies"
sh "$FIX" install >/dev/null
t_check 'grep -q "ATTR{\[dmi/id\]sys_vendor}==\"ASUS\", ATTR{\[dmi/id\]board_name}==\"RC74XA\"" "$R$RULE"' "rule matches the X20's DMI"
t_check 'grep -q "board_name}==\"RC71L\"" "$R$RULE"' "rule still matches the first Ally"
t_check '! grep -q "LENOVO" "$R$RULE"' "rule never matches a handheld without the trait"
t_new
ally
mkdir -p "$R/usr/lib/udev/rules.d"
printf '%s\n' 'ACTION=="add", SUBSYSTEM=="usb", TEST=="power/control", ATTR{idVendor}=="1c7a", ATTR{idProduct}=="0588", ATTR{power/control}="auto"' >"$R/usr/lib/udev/rules.d/50-ally-fingerprint.rules"
t_check '[ "$(t_state)" = os-fixed ]' "Bazzite's rule: os-fixed"
# No rule we can read, but the reader already powers down by itself (SteamOS 3.8+ is reported to fix it, mechanism
# unpublished): the behaviour on the device decides, not a version string
t_new
ally
printf 'auto\n' >"$F"
t_check '[ "$(t_state)" = os-fixed ]' "reader already at auto without our rule: os-fixed"
t_check 'sh "$FIX" install | grep -q "not needed"' "install stands down"
t_check '[ ! -e "$R$RULE" ]' "no rule written"
# our own rule is what keeps it at auto: never reported as the system's (it would be retired, then needed again)
t_new
ally
sh "$FIX" install >/dev/null
t_check 'sh "$FIX" status | grep -qx os_fixed=no' "installed and at auto because of us: not os-fixed"
t_check '[ "$(t_state)" = on ]' "state on"
t_end
