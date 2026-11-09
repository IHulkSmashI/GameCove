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
# The AMD Claw A8 has the Claw controller but not an Intel CPU: not in the trait set.
other() {
	t_dmi "Micro-Star International Co., Ltd." "Claw A8 BZ2EM" "MS-1T8K"
	t_pci 0000:2c:00.0 0x8086 0x272b 0x028000 d3cold_allowed=1
}
t_common "$RULE" claw other '[ "$(cat "$C")" = 0 ]' '[ "$(cat "$C")" = 1 ]'
t_new
claw
sh "$FIX" install >/dev/null
t_check '[ "$(cat "$R/sys/bus/pci/devices/0000:00:02.0/d3cold_allowed")" = 1 ]' "the GPU is never touched"
t_check 'grep -q "ATTR{class}==\"0x028000\"" "$R$RULE"' "rule only matches network controllers"
for b in MS-1T41 MS-1T42 MS-1T52 MS-1T91; do
	t_check "grep -q 'board_name}==\"$b\"' \"\$R\$RULE\"" "rule matches Intel Claw board $b"
done
t_check '! grep -q "MS-1T8K" "$R$RULE"' "rule never matches the AMD Claw A8"
t_check '[ "$(grep -c "d3cold_allowed" "$R$RULE")" = 4 ]' "one line per Intel Claw board"
t_new
claw
echo 0 >"$C"
t_check '[ "$(t_state)" = os-fixed ]' "D3cold already off: os-fixed"
t_new
t_dmi "Micro-Star International Co., Ltd." "Claw A1M" "MS-1T41"
t_pci 0000:2c:00.0 0x14c3 0x0616 0x028000 d3cold_allowed=1
t_check '[ "$(t_state)" = not-needed ]' "no Intel Wi-Fi card: not-needed"
t_end
