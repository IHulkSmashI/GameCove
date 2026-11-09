#!/bin/sh
# shellcheck disable=SC2034 # the device variables are read by the checks t_common evals
# claw-kbd-wakeup against fake roots (never the real system).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
FIX="$HERE/fix.sh"
T_NAME=claw-kbd-wakeup
T_PATH0=$PATH
# shellcheck source=fixes/lib/tests/gcfix-testlib.sh
. "$HERE/../lib/tests/gcfix-testlib.sh"
RULE=/etc/udev/rules.d/60-gamecove-claw-kbd-wakeup.rules
W=""

claw() {
	t_dmi "Micro-Star International Co., Ltd." "Claw A1M" "MS-1T41"
	t_serio serio0 atkbd enabled
	t_serio serio1 psmouse enabled
	W="$R/sys/bus/serio/devices/serio0/power/wakeup"
}
laptop() {
	t_dmi "Micro-Star International Co., Ltd." "Stealth 16 AI Studio A1VHG" "MS-15F2"
	t_serio serio0 atkbd enabled
}
t_common "$RULE" claw laptop '[ "$(cat "$W")" = disabled ]' '[ "$(cat "$W")" = enabled ]'

# the mouse port is never touched; the rule matches MSI Claw boards only
t_new
claw
sh "$FIX" install >/dev/null
t_check '[ "$(cat "$R/sys/bus/serio/devices/serio1/power/wakeup")" = enabled ]' "only the atkbd port"
t_check 'grep -q "ATTR{\[dmi/id\]board_name}==\"MS-1T\*\"" "$R$RULE"' "rule is gated on MSI Claw boards"
t_check 'grep -q "ATTR{\[dmi/id\]board_vendor}==\"Micro-Star International Co., Ltd.\"" "$R$RULE"' "rule is gated on MSI"
t_check 'grep -q "DRIVERS==\"atkbd\"" "$R$RULE"' "rule is for the keyboard only"
# every Claw row applies, the 8 EX included (board id only)
for b in MS-1T91 MS-1T52 MS-1T42 MS-1T8K MS-1T99; do
	t_new
	t_dmi "Micro-Star International Co., Ltd." "Claw" "$b"
	t_serio serio0 atkbd enabled
	t_check 'sh "$FIX" status | grep -qx applies=yes' "$b applies"
done
# kernel quirk / hhd already switched it off: os-fixed
t_new
claw
echo disabled >"$W"
t_check '[ "$(t_state)" = os-fixed ]' "wakeup already off without our rule: os-fixed"
# no i8042 keyboard: not needed
t_new
t_dmi "Micro-Star International Co., Ltd." "Claw A1M" "MS-1T41"
t_check '[ "$(t_state)" = not-needed ]' "no keyboard port: not-needed"
t_check 'sh "$FIX" install | grep -q "not needed"' "no keyboard port: install is a no-op"
t_end
