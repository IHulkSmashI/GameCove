#!/bin/sh
# shellcheck disable=SC2034 # the device variables are read by the checks t_common evals
# gpd-wm2-touch-wakeup against fake roots (never the real system).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
FIX="$HERE/fix.sh"
T_NAME=gpd-wm2-touch-wakeup
T_PATH0=$PATH
# shellcheck source=fixes/lib/tests/gcfix-testlib.sh
. "$HERE/../lib/tests/gcfix-testlib.sh"
RULE=/etc/udev/rules.d/60-gamecove-gpd-wm2-touch-wakeup.rules
W=""
wm2() {
	t_dmi "GPD" "G1619-05" "Default string"
	mkdir -p "$R/sys/bus/i2c/devices/i2c-PNP0C50:00/power" "$R/sys/bus/i2c/devices/i2c-PNP0C50:01/power"
	echo PNP0C50:00 >"$R/sys/bus/i2c/devices/i2c-PNP0C50:00/name"
	echo PNP0C50:01 >"$R/sys/bus/i2c/devices/i2c-PNP0C50:01/name"
	echo enabled >"$R/sys/bus/i2c/devices/i2c-PNP0C50:00/power/wakeup"
	echo enabled >"$R/sys/bus/i2c/devices/i2c-PNP0C50:01/power/wakeup"
	W="$R/sys/bus/i2c/devices/i2c-PNP0C50:00/power/wakeup"
}
win4() { t_dmi "GPD" "G1618-04" "Default string"; }
t_common "$RULE" wm2 win4 '[ "$(cat "$W")" = disabled ]' '[ "$(cat "$W")" = enabled ]'
t_new
wm2
sh "$FIX" install >/dev/null
t_check '[ "$(cat "$R/sys/bus/i2c/devices/i2c-PNP0C50:01/power/wakeup")" = enabled ]' "only PNP0C50:00"
t_end
