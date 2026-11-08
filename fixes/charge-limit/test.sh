#!/bin/sh
# Runs fix.sh against a fake sysfs (app/tests/fixtures/power/sys_claw); never the real system.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
FIX="$HERE/fix.sh"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
cp -R "$HERE/../../app/tests/fixtures/power/sys_claw/." "$ROOT/"
T="$ROOT/sys/class/power_supply/BAT1/charge_control_end_threshold"
export GAMECOVE_ROOT="$ROOT"
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

sh "$FIX" status | grep -q '^installed=no$' || fail "status before install"
sh "$FIX" status | tail -n 1 | grep -q '^state=off$' || fail "status ends state=off before install"
sh "$FIX" set 80 >/dev/null || fail "set 80"
sh "$FIX" status | tail -n 1 | grep -q '^state=on$' || fail "status ends state=on after set"
[ "$(cat "$T")" = "80" ] || fail "threshold is 80"
sh "$FIX" status | grep -q '^original=0$' || fail "original recorded"
sh "$FIX" set 100 >/dev/null || fail "set 100"
[ "$(cat "$T")" = "0" ] || fail "no limit writes the Claw's 0"
if sh "$FIX" set 49 2>/dev/null; then fail "49 refused"; fi
if sh "$FIX" set "80; reboot" 2>/dev/null; then fail "junk refused"; fi
if sh "$FIX" bogus 2>/dev/null; then fail "unknown action refused"; fi
sh "$FIX" set 90 >/dev/null
sh "$FIX" remove >/dev/null || fail "remove"
[ "$(cat "$T")" = "0" ] || fail "remove puts 0 back"
sh "$FIX" status | grep -q '^installed=no$' || fail "status after remove"
sh "$FIX" status | tail -n 1 | grep -q '^state=off$' || fail "remove sticks: state=off"
grep -q 'set 80' "$ROOT/var/lib/gamecove/fixes/charge-limit/changes.log" || fail "changes logged"
sh "$FIX" remove | grep -q 'nothing to undo' || fail "second remove is a no-op"
rm -rf "$ROOT/sys/class/power_supply/BAT1/charge_control_end_threshold"
set +e; sh "$FIX" set 80 2>/dev/null; code=$?; set -e
[ "$code" = "2" ] || fail "no threshold file -> exit 2 (got $code)"
[ "$(sh "$FIX" status | tr '\n' ' ')" = "applies=no state=n/a " ] || fail "status without the threshold file"
echo "charge-limit: all passed"
