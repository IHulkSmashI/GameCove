#!/bin/sh
# shellcheck disable=SC2016,SC2034 # t_check evals its single-quoted checks later, on purpose (RULE is used there)
# overlay-power against fake roots (never the real system).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
FIX="$HERE/fix.sh"
T_NAME=overlay-power
T_PATH0=$PATH
# shellcheck source=fixes/lib/tests/gcfix-testlib.sh
. "$HERE/../lib/tests/gcfix-testlib.sh"
RULE=/etc/tmpfiles.d/gamecove-overlay-power.conf
PKG=/sys/class/powercap/intel-rapl:0/energy_uj
MMIO=/sys/class/powercap/intel-rapl-mmio:0/energy_uj
claw() {
	t_dmi "Micro-Star International Co., Ltd." "Claw 8 EX AI+ CG3EM" "MS-1T91"
	mkdir -p "$R/sys/class/powercap/intel-rapl:0" "$R/sys/class/powercap/intel-rapl-mmio:0" "$R/sys/class/powercap/intel-rapl:0:0"
	echo 123456 >"$R$PKG"
	echo 654321 >"$R$MMIO"
	echo 1 >"$R/sys/class/powercap/intel-rapl:0:0/energy_uj"
	chmod 0400 "$R$PKG" "$R$MMIO" "$R/sys/class/powercap/intel-rapl:0:0/energy_uj"
}
mode() { stat -c %a "$R$1"; }

t_new
claw
t_check '[ "$(t_state)" = off ]' "stock 0400 counters: offered"
t_check 'sh "$FIX" install >/dev/null' "install"
t_check '[ "$(mode "$PKG")" = 444 ] && [ "$(mode "$MMIO")" = 444 ]' "both package counters readable at once"
t_check '[ "$(mode /sys/class/powercap/intel-rapl:0:0/energy_uj)" = 400 ]' "sub-domains untouched"
t_check 'head -n 1 "$R$RULE" | grep -qx "# GameCove fix overlay-power"' "rule carries the marker"
t_check 'grep -qx "z /sys/class/powercap/intel-rapl:0/energy_uj 0444 - - -" "$R$RULE" && grep -qx "z /sys/class/powercap/intel-rapl-mmio:0/energy_uj 0444 - - -" "$R$RULE"' "tmpfiles opens both at boot"
t_check '[ "$(t_state)" = on ]' "state on"
t_check 'sh "$FIX" status | grep -qx os_fixed=no' "open because of us: not os-fixed"
t_check '[ "$(sh "$FIX" install)" = "already installed" ]' "install twice is a no-op"
t_check 'sh "$FIX" remove >/dev/null 2>&1' "remove"
t_check '[ ! -e "$R$RULE" ]' "rule gone"
t_check '[ "$(mode "$PKG")" = 400 ] && [ "$(mode "$MMIO")" = 400 ]' "modes put back"
t_check '[ "$(t_state)" = off ]' "state off"
t_check '[ ! -e "$R/var/lib/gamecove/fixes/overlay-power/modes" ]' "nothing left recorded"

# already readable without us (a kernel or OS that opened them): os-fixed
t_new
claw
chmod 0444 "$R$PKG" "$R$MMIO"
t_check '[ "$(t_state)" = os-fixed ]' "already 0444: os-fixed"
# an OS tmpfiles rule that opens them
t_new
claw
mkdir -p "$R/usr/lib/tmpfiles.d"
echo "z /sys/class/powercap/intel-rapl:0/energy_uj 0444 - - -" >"$R/usr/lib/tmpfiles.d/rapl.conf"
t_check '[ "$(t_state)" = os-fixed ]' "OS tmpfiles rule: os-fixed"
# no RAPL counter (AMD kernel, or none exposed): not needed
t_new
claw
rm -rf "$R/sys/class/powercap"
t_check '[ "$(t_state)" = not-needed ]' "no counter: not needed"
# Intel only: an AMD handheld isn't offered it
t_new
claw
t_dmi "ASUSTeK COMPUTER INC." "ROG Ally RC71L_RC71L" "RC71L"
t_check 'sh "$FIX" status | grep -qx applies=no' "AMD handheld: applies=no"
t_end
