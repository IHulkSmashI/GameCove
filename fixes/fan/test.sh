#!/bin/sh
# Runs fix.sh against a fake sysfs (app/tests/fixtures/power/sys_claw); never the real system.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
FIX="$HERE/fix.sh"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
cp -R "$HERE/../../app/tests/fixtures/power/sys_claw/." "$ROOT/"
H="$ROOT/sys/class/hwmon/hwmon5"
export GAMECOVE_ROOT="$ROOT"
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
table() { echo "$(cat "$H/pwm$1_auto_point1_pwm") $(cat "$H/pwm$1_auto_point2_pwm") $(cat "$H/pwm$1_auto_point3_pwm") $(cat "$H/pwm$1_auto_point4_pwm") $(cat "$H/pwm$1_auto_point5_pwm") $(cat "$H/pwm$1_auto_point6_pwm")"; }

sh "$FIX" status | grep -q '^installed=no$' || fail "status before install"
sh "$FIX" status | tail -n 1 | grep -q '^state=off$' || fail "status ends state=off before install"
sh "$FIX" set quiet >/dev/null || fail "set quiet"
sh "$FIX" status | tail -n 1 | grep -q '^state=on$' || fail "status ends state=on after set"
for n in 1 2; do
	[ "$(table $n)" = "0 102 102 115 153 191" ] || fail "fan $n quiet table ($(table $n))"
	[ "$(cat "$H/pwm${n}_enable")" = "1" ] || fail "fan $n table mode"
	[ "$(cat "$H/pwm${n}_auto_point3_temp")" = "70000" ] || fail "temperatures untouched"
done
sh "$FIX" set max >/dev/null || fail "set max"
[ "$(table 2)" = "255 255 255 255 255 255" ] || fail "max table"
sh "$FIX" set auto >/dev/null || fail "set auto"
[ "$(cat "$H/pwm1_enable")" = "2" ] || fail "auto enable=2"
if sh "$FIX" set turbo 2>/dev/null; then fail "unknown mode refused"; fi
sh "$FIX" set quiet >/dev/null
sh "$FIX" remove >/dev/null || fail "remove"
for n in 1 2; do
	[ "$(table $n)" = "0 102 128 153 179 204" ] || fail "fan $n original table back ($(table $n))"
	[ "$(cat "$H/pwm${n}_enable")" = "2" ] || fail "fan $n original enable back"
done
sh "$FIX" status | grep -q '^installed=no$' || fail "status after remove"
sh "$FIX" status | tail -n 1 | grep -q '^state=off$' || fail "remove sticks: state=off"
grep -q 'set quiet' "$ROOT/var/lib/gamecove/fixes/fan/changes.log" || fail "changes logged"
echo msi_other > "$H/name"
set +e; sh "$FIX" set quiet 2>/dev/null; code=$?; set -e
[ "$code" = "2" ] || fail "no fan driver -> exit 2 (got $code)"
[ "$(sh "$FIX" status | tr '\n' ' ')" = "applies=no state=n/a " ] || fail "status without the driver"
echo "fan: all passed"
