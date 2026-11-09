#!/bin/sh
# Runs fix.sh (and the no-password path through gamecove-fix-set) against fake
# LED trees in a temp folder; never the real system.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
FIX="$HERE/fix.sh"
REPO="$(cd "$HERE/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail() { printf 'FAIL controller-led: %s\n' "$1" >&2; exit 1; }

# node <root> <name> <index> <intensity> <max> <brightness> [attr=value ...]
node() {
	d="$1/sys/class/leds/$2"
	mkdir -p "$d"
	echo "$3" > "$d/multi_index"; echo "$4" > "$d/multi_intensity"
	echo "$5" > "$d/max_brightness"; echo "$6" > "$d/brightness"
	shift 6
	for kv in "$@"; do echo "${kv#*=}" > "$d/${kv%%=*}"; done
}
run() { GAMECOVE_ROOT="$R" sh "$FIX" "$@"; }

# ---- no node: refuses, status says n/a
R="$T/none"; mkdir -p "$R"
[ "$(run status | tr '\n' ' ')" = "applies=no state=n/a " ] || fail "status without nodes"
set +e; run set all,ff0000,50 2>/dev/null; c=$?; set -e
[ "$c" = 2 ] || fail "no node -> exit 2 (got $c)"

# ---- ROG Ally, 12 channels, plus an unrelated LED that must stay untouched
R="$T/ally"
node "$R" ally:rgb:joystick_rings "red green blue red green blue red green blue red green blue" "0 0 0 0 0 0 0 0 0 0 0 0" 255 0
node "$R" input3::capslock "red" "0" 1 0
run set all,ff8000,50 >/dev/null || fail "set ally"
A="$R/sys/class/leds/ally:rgb:joystick_rings"
[ "$(cat "$A/multi_intensity")" = "255 128 0 255 128 0 255 128 0 255 128 0" ] || fail "ally 4 zones ($(cat "$A/multi_intensity"))"
[ "$(cat "$A/brightness")" = "128" ] || fail "ally brightness 50% of 255"
[ "$(cat "$R/sys/class/leds/input3::capslock/brightness")" = "0" ] || fail "other LEDs untouched"
run status | grep -qx 'led0_rgb=ff8000' || fail "status colour"
run status | grep -qx 'led0_brightness=50' || fail "status brightness"
run status | tail -n 1 | grep -qx 'state=on' || fail "state on after set"
run set off >/dev/null || fail "off"
[ "$(cat "$A/brightness")" = "0" ] || fail "off = brightness 0"
run remove >/dev/null || fail "remove"
[ "$(cat "$A/multi_intensity")" = "0 0 0 0 0 0 0 0 0 0 0 0" ] || fail "remove puts the colour back"
run status | tail -n 1 | grep -qx 'state=off' || fail "state off after remove"
grep -q 'set all,ff8000,50' "$R/var/lib/gamecove/fixes/controller-led/changes.log" || fail "changes logged"

# ---- bad values
for bad in "all,FF0000,50" "all,ff00,50" "all,ff0000,101" "x,ff0000,50" "all,ff0000,50,bad-name" "all,ff0000" "all,ff0000,50,monocolor,500"; do
	set +e; run set "$bad" 2>/dev/null; c=$?; set -e
	[ "$c" = 2 ] || fail "'$bad' refused with 2 (got $c)"
done

# ---- Legion Go ring (hid-lenovo-go): profile, mode, enabled, effects, 0-100 channels
R="$T/legion"
node "$R" go:rgb:joystick_rings "red green blue" "100 100 100" 100 50 multi_max_intensity="100 100 100" \
	effect=monocolor effect_index="monocolor breathe chroma rainbow" enabled=false enabled_index="true false" \
	mode=dynamic mode_index="dynamic custom" profile=0 profile_range=1-3 speed=50 speed_range=0-100
L="$R/sys/class/leds/go:rgb:joystick_rings"
run set all,ff8000,80,chroma,30 >/dev/null || fail "set legion"
[ "$(cat "$L/profile")" = 3 ] || fail "profile 3 first"
[ "$(cat "$L/mode")" = custom ] || fail "custom mode"
[ "$(cat "$L/effect")" = chroma ] || fail "effect"
[ "$(cat "$L/speed")" = 30 ] || fail "speed"
[ "$(cat "$L/enabled")" = true ] || fail "enabled"
[ "$(cat "$L/multi_intensity")" = "100 50 0" ] || fail "scaled channels ($(cat "$L/multi_intensity"))"
[ "$(cat "$L/brightness")" = 80 ] || fail "brightness 80 of 100"
run status | grep -qx 'led0_rgb=ff8000' || fail "status scales back ($(run status | grep led0_rgb))"
set +e; run set all,ff8000,80,frostfire 2>/dev/null; c=$?; set -e
[ "$c" = 1 ] || fail "effect the node lacks -> 1 (got $c)"
[ "$(cat "$L/effect")" = chroma ] || fail "refused effect leaves the node as it was"
run set all,000000,0 >/dev/null || fail "brightness 0"
[ "$(cat "$L/enabled")" = false ] || fail "0% disables"
run remove >/dev/null
[ "$(cat "$L/mode")" = dynamic ] && [ "$(cat "$L/profile")" = 0 ] && [ "$(cat "$L/enabled")" = false ] || fail "remove restores mode/profile/enabled"

# ---- a refused write mid-way restores that node
R="$T/broken"
node "$R" zotac:rgb:spectra_zone_0 "red green blue" "1 2 3" 255 255
node "$R" zotac:rgb:spectra_zone_1 "red green blue" "4 5 6" 255 255
Z1="$R/sys/class/leds/zotac:rgb:spectra_zone_1"
rm "$Z1/brightness"; mkdir "$Z1/brightness"
set +e; run set 1,ffffff,100 2>/dev/null; c=$?; set -e
[ "$c" = 1 ] || fail "refused write -> 1 (got $c)"
[ "$(cat "$Z1/multi_intensity")" = "4 5 6" ] || fail "zone 1 colour restored"
run set 0,ffffff,100 >/dev/null || fail "zone 0 alone"
[ "$(cat "$R/sys/class/leds/zotac:rgb:spectra_zone_0/multi_intensity")" = "255 255 255" ] || fail "zone 0 set"
set +e; run set 7,ffffff,100 2>/dev/null; c=$?; set -e
[ "$c" = 2 ] || fail "missing zone -> 2"

# ---- the app's path: gamecove-fix-set -> gamecove-fix -> fix.sh
R="$T/disp"
node "$R" ayaneo:rgb:joystick_rings "red green blue" "0 0 0" 255 0
FIXES="$T/fixes"; mkdir -p "$FIXES"; cp -R "$HERE" "$FIXES/controller-led"; cp -R "$HERE/../lib" "$FIXES/lib"
disp() { GAMECOVE_ROOT="$R" GAMECOVE_FIXES_DIR="$FIXES" sh "$@"; }
GFS="$REPO/packaging/libexec/gamecove-fix-set"
disp "$GFS" controller-led set all,00ff00,100 >/dev/null 2>&1 || fail "set through gamecove-fix-set"
[ "$(cat "$R/sys/class/leds/ayaneo:rgb:joystick_rings/multi_intensity")" = "0 255 0" ] || fail "applied through the dispatcher"
grep -q "fix=controller-led action=set value=all,00ff00,100 result=ok" "$R/var/lib/gamecove/changes.log" || fail "logged by the dispatcher"
disp "$GFS" controller-led set off >/dev/null 2>&1 || fail "off through gamecove-fix-set"
disp "$GFS" controller-led status | grep -qx applies=yes || fail "status through gamecove-fix-set"
set +e
disp "$GFS" controller-led set "all,00FF00,100" >/dev/null 2>&1; c1=$?
disp "$GFS" controller-led set "../x" >/dev/null 2>&1; c2=$?
disp "$GFS" controller-led remove >/dev/null 2>&1; c3=$?
set -e
[ "$c1" = 66 ] || fail "upper-case refused by gamecove-fix-set (got $c1)"
[ "$c2" = 66 ] || fail "path refused by gamecove-fix-set (got $c2)"
[ "$c3" != 0 ] || fail "gamecove-fix-set refuses remove"
echo "controller-led: ok"
