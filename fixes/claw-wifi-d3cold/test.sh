#!/bin/sh
# shellcheck disable=SC2034 # the device variables are read by the checks t_common evals
# claw-wifi-d3cold against fake roots (never the real system).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
FIX="$HERE/fix.sh"
T_NAME=claw-wifi-d3cold
T_PATH0=$PATH
# shellcheck source=fixes/lib/tests/gcfix-testlib.sh
. "$HERE/../lib/tests/gcfix-testlib.sh"
RULE=/etc/udev/rules.d/60-gamecove-claw-wifi-d3cold.rules
C=""
claw() {
	t_dmi "Micro-Star International Co., Ltd." "Claw 8 AI+ A2VM" "MS-1T52"
	t_pci 0000:2c:00.0 0x8086 0x272b 0x028000 d3cold_allowed=1
	t_pci 0000:00:02.0 0x8086 0x64a0 0x030000 d3cold_allowed=1
	C="$R/sys/bus/pci/devices/0000:2c:00.0/d3cold_allowed"
}
other() {
	t_dmi "Micro-Star International Co., Ltd." "Claw 8 EX AI+ CG3EM" "MS-1T91"
	t_pci 0000:2c:00.0 0x8086 0x272b 0x028000 d3cold_allowed=1
}
t_common "$RULE" claw other '[ "$(cat "$C")" = 0 ]' '[ "$(cat "$C")" = 1 ]'
t_new
claw
sh "$FIX" install >/dev/null
t_check '[ "$(cat "$R/sys/bus/pci/devices/0000:00:02.0/d3cold_allowed")" = 1 ]' "the GPU is never touched"
t_check 'grep -q "ATTR{class}==\"0x028000\"" "$R$RULE"' "rule only matches network controllers"
t_check 'grep -q "MS-1T41|MS-1T42|MS-1T52" "$R$RULE"' "rule is gated on the three Intel Claw boards"
t_new
claw
echo 0 >"$C"
t_check '[ "$(t_state)" = os-fixed ]' "D3cold already off: os-fixed"
t_new
t_dmi "Micro-Star International Co., Ltd." "Claw A1M" "MS-1T41"
t_pci 0000:2c:00.0 0x14c3 0x0616 0x028000 d3cold_allowed=1
t_check '[ "$(t_state)" = not-needed ]' "no Intel Wi-Fi card: not-needed"
t_end
