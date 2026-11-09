#!/bin/sh
# shellcheck disable=SC2034 # the device variables are read by the checks t_common evals
# ally-mcu-powersave against fake roots (never the real system).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
FIX="$HERE/fix.sh"
T_NAME=ally-mcu-powersave
T_PATH0=$PATH
# shellcheck source=fixes/lib/tests/gcfix-testlib.sh
. "$HERE/../lib/tests/gcfix-testlib.sh"
RULE=/etc/udev/rules.d/60-gamecove-ally-mcu-powersave.rules
N=""
ally() {
	t_dmi "ASUSTeK COMPUTER INC." "ROG Ally RC71L_RC71L" "RC71L"
	mkdir -p "$R/sys/class/firmware-attributes/asus-armoury/attributes/mcu_powersave"
	N="$R/sys/class/firmware-attributes/asus-armoury/attributes/mcu_powersave/current_value"
	echo 0 >"$N"
}
laptop() {
	t_dmi "ASUSTeK COMPUTER INC." "ROG Zephyrus G14 GA403UV" "GA403UV"
	mkdir -p "$R/sys/devices/platform/asus-nb-wmi"
	echo 0 >"$R/sys/devices/platform/asus-nb-wmi/mcu_powersave"
}
t_common "$RULE" ally laptop '[ "$(cat "$N")" = 1 ]' '[ "$(cat "$N")" = 0 ]'
# older kernels: the asus-wmi switch
t_new
t_dmi "ASUSTeK COMPUTER INC." "ROG Ally X RC72LA_RC72LA" "RC72LA"
mkdir -p "$R/sys/devices/platform/asus-nb-wmi"
echo 0 >"$R/sys/devices/platform/asus-nb-wmi/mcu_powersave"
sh "$FIX" install >/dev/null
t_check '[ "$(cat "$R/sys/devices/platform/asus-nb-wmi/mcu_powersave")" = 1 ]' "legacy asus-wmi switch set"
sh "$FIX" remove >/dev/null
t_check '[ "$(cat "$R/sys/devices/platform/asus-nb-wmi/mcu_powersave")" = 0 ]' "legacy switch put back"
t_new
ally
echo 1 >"$N"
t_check '[ "$(t_state)" = os-fixed ]' "already on: os-fixed"
t_new
t_dmi "ASUSTeK COMPUTER INC." "ROG Ally RC71L_RC71L" "RC71L"
t_check '[ "$(t_state)" = not-needed ]' "no MCU switch in this kernel: not-needed"
t_end
