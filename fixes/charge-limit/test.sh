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
# Stub programs: udevadm (never reload the real udev), pgrep (is GameCove running?).
BIN="$(mktemp -d)"
trap 'rm -rf "$ROOT" "$BIN"' EXIT
printf '#!/bin/sh\necho "udevadm $*" >> "%s/udevadm.log"\n' "$BIN" > "$BIN/udevadm"
printf '#!/bin/sh\n[ -f "%s/app-running" ]\n' "$BIN" > "$BIN/pgrep"
chmod +x "$BIN/udevadm" "$BIN/pgrep"
PATH="$BIN:$PATH"
export PATH
# dmi <root> <sys_vendor> <product_name> <board_name>
dmi() {
	mkdir -p "$1/sys/class/dmi/id"
	printf '%s\n' "$2" > "$1/sys/class/dmi/id/sys_vendor"
	printf '%s\n' "$3" > "$1/sys/class/dmi/id/product_name"
	printf '%s\n' "$4" > "$1/sys/class/dmi/id/board_name"
	printf '%s\n' "$2" > "$1/sys/class/dmi/id/board_vendor"
}
dmi "$ROOT" "Micro-Star International Co., Ltd." "Claw 8 AI+ A2VM" "MS-1T91"

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
[ ! -e "$ROOT/etc/udev/rules.d/90-gamecove-charge-limit.rules" ] || fail "threshold mode needs no udev rule"
sh "$FIX" set 80 >/dev/null
sh "$FIX" set release | grep -q '^value=release$' || fail "release in threshold mode is a no-op"
[ "$(cat "$T")" = "80" ] || fail "release keeps the firmware's threshold"
sh "$FIX" remove >/dev/null
rm -rf "$ROOT/sys/class/power_supply/BAT1/charge_control_end_threshold"
set +e; sh "$FIX" set 80 2>/dev/null; code=$?; set -e
[ "$code" = "2" ] || fail "no threshold file -> exit 2 (got $code)"
[ "$(sh "$FIX" status | tr '\n' ' ')" = "applies=no state=n/a " ] || fail "status without the threshold file"

# ---- OneXPlayer: threshold without the Claw's 0 = none ------------------------
R="$(mktemp -d)"
mkdir -p "$R/sys/class/power_supply/BAT0" "$R/sys/class/power_supply/AC0"
echo Battery > "$R/sys/class/power_supply/BAT0/type"
echo 100 > "$R/sys/class/power_supply/BAT0/charge_control_end_threshold"
dmi "$R" "ONE-NETBOOK" "ONEXPLAYER X1 A" "X1A"
export GAMECOVE_ROOT="$R"
T="$R/sys/class/power_supply/BAT0/charge_control_end_threshold"
sh "$FIX" status | grep -q '^mode=threshold$' || fail "oxp: threshold mode"
sh "$FIX" set 80 >/dev/null || fail "oxp: set 80"
[ "$(cat "$T")" = "80" ] || fail "oxp: threshold 80"
sh "$FIX" set 100 >/dev/null || fail "oxp: set 100"
[ "$(cat "$T")" = "100" ] || fail "oxp: no limit writes 100 when the original was 100"
sh "$FIX" remove >/dev/null
rm -rf "$R"

# ---- AYANEO: charge_behaviour only (ayaneo-ec) --------------------------------
R="$(mktemp -d)"
B="$R/sys/class/power_supply/BAT0"
mkdir -p "$B" "$R/sys/class/power_supply/ADP0"
echo Battery > "$B/type"
echo "[auto] inhibit-charge" > "$B/charge_behaviour"
echo 85 > "$B/capacity"
echo Mains > "$R/sys/class/power_supply/ADP0/type"
echo 1 > "$R/sys/class/power_supply/ADP0/online"
dmi "$R" "AYANEO" "AYANEO 3" "AB09"
export GAMECOVE_ROOT="$R"
sh "$FIX" status | grep -q '^mode=behaviour$' || fail "aya: behaviour mode"
sh "$FIX" status | grep -q '^behaviour=auto$' || fail "aya: reads the bracketed behaviour"
sh "$FIX" set 80 | grep -q '^behaviour=inhibit-charge$' || fail "aya: 85 % on the charger holds charging at 80"
[ "$(cat "$B/charge_behaviour")" = "inhibit-charge" ] || fail "aya: inhibit written"
sh "$FIX" status | grep -q '^limit=80$' || fail "aya: limit remembered"
echo 70 > "$B/capacity"
sh "$FIX" set 80 >/dev/null
[ "$(cat "$B/charge_behaviour")" = "auto" ] || fail "aya: below the limit it charges"
echo 90 > "$B/capacity"
echo 0 > "$R/sys/class/power_supply/ADP0/online"
sh "$FIX" set 80 >/dev/null
[ "$(cat "$B/charge_behaviour")" = "auto" ] || fail "aya: unplugged always goes back to auto"
echo 1 > "$R/sys/class/power_supply/ADP0/online"
sh "$FIX" set 100 >/dev/null
[ "$(cat "$B/charge_behaviour")" = "auto" ] || fail "aya: 100 = no limit = auto"
sh "$FIX" set 80 >/dev/null
sh "$FIX" remove >/dev/null || fail "aya: remove"
[ "$(cat "$B/charge_behaviour")" = "auto" ] || fail "aya: remove never leaves charging held"
echo "[auto] inhibit-charge" > "$B/charge_behaviour"   # what the kernel lists again
sh "$FIX" status | grep -q '^installed=no$' || fail "aya: status after remove"

# ---- AYANEO: nothing may leave charging held once GameCove is gone -------------
RULE="$R/etc/udev/rules.d/90-gamecove-charge-limit.rules"
[ ! -e "$RULE" ] || fail "aya: remove took the udev rule away"
echo 85 > "$B/capacity"
touch "$BIN/app-running"
sh "$FIX" set 80 >/dev/null
[ "$(cat "$B/charge_behaviour")" = "inhibit-charge" ] || fail "aya: held at 80"
[ -f "$RULE" ] || fail "aya: install writes the udev rule"
grep -q 'SUBSYSTEM=="power_supply"' "$RULE" || fail "aya: rule matches power_supply"
grep -q 'ACTION=="add|change"' "$RULE" || fail "aya: rule runs at boot (add) and on changes"
grep -q 'RUN+="/bin/sh /usr/lib/gamecove/fixes/charge-limit/fix.sh guard"' "$RULE" || fail "aya: rule runs the guard"
grep -q 'control --reload' "$BIN/udevadm.log" || fail "aya: udev reloaded"
# GameCove exits: the session's post_client_shutdown runs `set release`
sh "$FIX" set release | grep -q '^behaviour=auto$' || fail "aya: release lets it charge"
[ "$(cat "$B/charge_behaviour")" = "auto" ] || fail "aya: release wrote auto"
sh "$FIX" status | grep -q '^limit=80$' || fail "aya: release keeps the limit for next time"
# GameCove crashed with charging held: the guard (udev) puts it back once it's gone
sh "$FIX" set 80 >/dev/null
rm -f "$BIN/app-running"
sh "$FIX" guard
[ "$(cat "$B/charge_behaviour")" = "auto" ] || fail "aya: guard with GameCove gone -> auto"
# boot: the battery comes up held (firmware kept it); udev's add event runs the guard
echo inhibit-charge > "$B/charge_behaviour"
sh "$FIX" guard
[ "$(cat "$B/charge_behaviour")" = "auto" ] || fail "aya: guard at boot -> auto"
# while GameCove runs the guard keeps the limit working between its own checks
touch "$BIN/app-running"
sh "$FIX" guard
[ "$(cat "$B/charge_behaviour")" = "inhibit-charge" ] || fail "aya: guard with GameCove running holds at the limit"
echo 0 > "$R/sys/class/power_supply/ADP0/online"
sh "$FIX" guard
[ "$(cat "$B/charge_behaviour")" = "auto" ] || fail "aya: guard on unplug -> auto"
lines="$(wc -l < "$R/var/lib/gamecove/fixes/charge-limit/changes.log")"
sh "$FIX" guard
[ "$(wc -l < "$R/var/lib/gamecove/fixes/charge-limit/changes.log")" = "$lines" ] || fail "aya: guard writes nothing when nothing changed"
rm -f "$BIN/app-running"
sh "$FIX" remove >/dev/null
[ ! -e "$RULE" ] || fail "aya: remove deletes the udev rule"
[ ! -e "$R/run/gamecove-charge-limit.lock" ] || fail "aya: lock released"
rm -rf "$R"

# ---- laptops with the same battery drivers are never touched -----------------
R="$(mktemp -d)"
B="$R/sys/class/power_supply/BAT1"
mkdir -p "$B"
echo Battery > "$B/type"
echo 0 > "$B/charge_control_end_threshold"
dmi "$R" "Micro-Star International Co., Ltd." "Stealth 16 AI Studio A1VHG" "MS-15F2"
export GAMECOVE_ROOT="$R"
[ "$(sh "$FIX" status | tr '\n' ' ')" = "applies=no state=n/a " ] || fail "MSI laptop: applies=no"
set +e; sh "$FIX" set 80 2>/dev/null; code=$?; set -e
[ "$code" = "2" ] || fail "MSI laptop: set refused with exit 2 (got $code)"
[ "$(cat "$B/charge_control_end_threshold")" = "0" ] || fail "MSI laptop: nothing written"
set +e; sh "$FIX" guard 2>/dev/null; code=$?; set -e
[ "$code" = "0" ] || fail "MSI laptop: guard does nothing quietly"
rm -rf "$R"
echo "charge-limit: all passed"
