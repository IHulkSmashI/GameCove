#!/bin/sh
# Runs fix.sh (and the no-password path through gamecove-fix-set) against fake
# /sys/bus/hid trees in a temp folder; never the real system.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
FIX="$HERE/fix.sh"
REPO="$(cd "$HERE/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail() { printf 'FAIL controller-rumble: %s\n' "$1" >&2; exit 1; }
run() { GAMECOVE_ROOT="$R" sh "$FIX" "$@"; }
code() { set +e; "$@" >/dev/null 2>&1; c=$?; set -e; echo "$c"; }

# msi <root> <left> <right>: hid-msi config interface with the rumble attributes,
# plus the gamepad interface (bound to the same driver, no attributes)
msi() {
	d="$1/sys/bus/hid/drivers/hid-msi/0003:0DB0:1901.0004"
	mkdir -p "$d" "$1/sys/bus/hid/drivers/hid-msi/0003:0DB0:1901.0003"
	echo "$2" > "$d/rumble_intensity_left"; echo "$3" > "$d/rumble_intensity_right"
	echo "0-100" > "$d/rumble_intensity_range"
	echo "$d"
}

# ---- no knob: status says n/a, set refuses
R="$T/none"; mkdir -p "$R"
[ "$(run status | tr '\n' ' ')" = "applies=no state=n/a " ] || fail "status without a knob"
[ "$(code run set 50)" = 2 ] || fail "no knob -> exit 2"
[ "$(code run install)" = 2 ] || fail "install without a knob -> exit 2"

# ---- MSI Claw (hid-msi): both motors, read back, original kept for remove
R="$T/msi"; D="$(msi "$R" 100 100)"
run status | grep -qx driver=hid-msi || fail "driver"
run status | grep -qx kind=percent || fail "kind"
run status | grep -qx range=0-100 || fail "range"
run status | grep -qx value=100 || fail "value"
run status | tail -n 1 | grep -qx state=off || fail "state off before any set"
run set 40 | grep -qx value=40 || fail "set 40"
[ "$(cat "$D/rumble_intensity_left")" = 40 ] && [ "$(cat "$D/rumble_intensity_right")" = 40 ] || fail "both motors 40"
run status | tail -n 1 | grep -qx state=on || fail "state on after set"
grep -q "set 40 (hid-msi)" "$R/var/lib/gamecove/fixes/controller-rumble/changes.log" || fail "logged"
# review L4: every change is stored in the controller: the same value is a no-op, and at most 30 real
# changes per ten minutes (any local process can call this without a password)
lines() { wc -l <"$R/var/lib/gamecove/fixes/controller-rumble/changes.log" | tr -d ' '; }
l0=$(lines)
run set 40 | grep -qx value=40 || fail "the same value again"
[ "$(lines)" = "$l0" ] || fail "the same value again writes nothing"
rm -f "$R/run/gamecove/rate-controller-rumble"
i=0
while [ "$i" -lt 15 ]; do
	run set 41 >/dev/null || fail "change $i"
	run set 40 >/dev/null || fail "change $i back"
	i=$((i + 1))
done
[ "$(code run set 41)" = 1 ] || fail "the 31st change in ten minutes is refused"
[ "$(cat "$D/rumble_intensity_left")" = 40 ] || fail "the refused change wrote nothing"
run set 40 >/dev/null || fail "the current value is still accepted (a no-op)"
rm -f "$R/run/gamecove/rate-controller-rumble"
[ ! -e "$R/run/gamecove-controller-rumble.lock" ] || fail "lock released"
run set off >/dev/null || fail "off"
[ "$(cat "$D/rumble_intensity_left")" = 0 ] || fail "off = 0"
for bad in 101 -1 abc 040 1000 low ""; do
	[ "$(code run set "$bad")" = 2 ] || fail "refuses '$bad'"
done
[ "$(cat "$D/rumble_intensity_left")" = 0 ] || fail "refused values leave it alone"
run remove | grep -qx restored || fail "remove"
[ "$(cat "$D/rumble_intensity_left")" = 100 ] && [ "$(cat "$D/rumble_intensity_right")" = 100 ] || fail "original back"
run remove | grep -qx "nothing to undo" || fail "second remove is a no-op"

# an unchanged value is not written again (each write goes to the controller's flash)
R="$T/msi_same"; D="$(msi "$R" 60 60)"
touch -d 2000-01-01 "$D/rumble_intensity_left" "$D/rumble_intensity_right"
run set 60 >/dev/null || fail "same value"
[ "$(find "$D" \( -name rumble_intensity_left -o -name rumble_intensity_right \) -newermt 2000-01-02 | wc -l)" = 0 ] || fail "an unchanged value is not rewritten"

# a controller that refuses a value: the values from before go back, exit 1.
# Root ignores file modes, so this part runs as nobody when the test runs as root.
R="$T/msi_refuse"; D="$(msi "$R" 70 70)"
chmod 444 "$D/rumble_intensity_right"
as_user=""
if [ "$(id -u)" = 0 ]; then
	command -v setpriv >/dev/null 2>&1 && as_user="setpriv --reuid=65534 --regid=65534 --clear-groups"
	chmod -R a+rwX "$T"; chmod 444 "$D/rumble_intensity_right"; chmod 755 "$T"
fi
if [ "$(id -u)" != 0 ] || [ -n "$as_user" ]; then
	set +e; GAMECOVE_ROOT="$R" $as_user sh "$FIX" set 30 >/dev/null 2>&1; c=$?; set -e
	[ "$c" = 1 ] || fail "refused write -> exit 1 (got $c)"
	[ "$(cat "$D/rumble_intensity_left")" = 70 ] || fail "left restored after the right refused"
fi

# ---- Legion Go (hid-lenovo-go): words
R="$T/go"; G="$R/sys/bus/hid/drivers/hid-lenovo-go/0003:17EF:61EB.0002"
mkdir -p "$G"; echo high > "$G/rumble_intensity"; echo "off low medium high " > "$G/rumble_intensity_index"
run status | grep -qx kind=levels || fail "go kind"
run status | grep -qx levels=off,low,medium,high || fail "go levels"
run set low | grep -qx value=low || fail "go low"
[ "$(cat "$G/rumble_intensity")" = low ] || fail "go written"
for bad in 50 unknown loud; do
	[ "$(code run set "$bad")" = 2 ] || fail "go refuses '$bad'"
done
run remove >/dev/null
[ "$(cat "$G/rumble_intensity")" = high ] || fail "go original back"

# ---- the app's path: gamecove-fix-set -> gamecove-fix -> fix.sh
R="$T/disp"; D="$(msi "$R" 100 100)"
FIXES="$T/fixes"; mkdir -p "$FIXES"; cp -R "$HERE" "$FIXES/controller-rumble"; cp -R "$HERE/../lib" "$FIXES/lib"
disp() { GAMECOVE_ROOT="$R" GAMECOVE_FIXES_DIR="$FIXES" sh "$@"; }
GFS="$REPO/packaging/libexec/gamecove-fix-set"
disp "$GFS" controller-rumble set 80 >/dev/null 2>&1 || fail "set through gamecove-fix-set"
[ "$(cat "$D/rumble_intensity_left")" = 80 ] || fail "applied through the dispatcher"
grep -q "fix=controller-rumble action=set value=80 result=ok" "$R/var/lib/gamecove/changes.log" || fail "logged by the dispatcher"
disp "$GFS" controller-rumble set off >/dev/null 2>&1 || fail "off through gamecove-fix-set"
disp "$GFS" controller-rumble status | grep -qx applies=yes || fail "status through gamecove-fix-set"
for bad in 101 08 "../x" "1;id" HIGH; do
	[ "$(code disp "$GFS" controller-rumble set "$bad")" = 66 ] || fail "gamecove-fix-set refuses '$bad'"
done
[ "$(code disp "$GFS" controller-rumble remove)" != 0 ] || fail "gamecove-fix-set refuses remove"
echo "controller-rumble: ok"
