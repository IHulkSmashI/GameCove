#!/bin/sh
# Tests for GameCove's shell helpers. Everything runs against a fake root in a
# temp folder with fake programs on PATH; nothing touches the real system.
#
#   sh packaging/tests/run.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
FIX="$REPO/packaging/libexec/gamecove-fix"

pass=0
fail=0
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

ok() {
	pass=$((pass + 1))
}

bad() {
	fail=$((fail + 1))
	echo "FAIL: $*" >&2
}

# expect_code <code> <description> <command...>; output goes to $T/out
expect_code() {
	want="$1"
	what="$2"
	shift 2
	"$@" >"$T/out" 2>&1
	got=$?
	if [ "$got" -eq "$want" ]; then ok; else bad "$what: exit $got, want $want ($(cat "$T/out"))"; fi
}

contains() {
	if grep -q -- "$2" "$1" 2>/dev/null; then ok; else bad "$3: '$2' not in $1"; fi
}

lacks() {
	if grep -q -- "$2" "$1" 2>/dev/null; then bad "$3: '$2' found in $1"; else ok; fi
}

# ---------------------------------------------------------------- dispatcher
ROOT="$T/root"
FIXES="$ROOT/usr/lib/gamecove/fixes"
LOG="$ROOT/var/lib/gamecove/changes.log"
mkdir -p "$FIXES/dummy" "$FIXES/broken" "$ROOT/elsewhere/evil"

# dummy fix: records its arguments and the environment it was given
cat >"$FIXES/dummy/fix.sh" <<'EOF'
#!/bin/sh
echo "args:$*" >>"$GAMECOVE_ROOT/calls"
echo "root:$GAMECOVE_ROOT" >>"$GAMECOVE_ROOT/calls"
case "$1" in
status) echo "installed=yes" ;;
install|remove|update) echo "detail: $1 dummy" >>"$GAMECOVE_CHANGES_LOG" ;;
set) [ "$2" = "boom" ] && exit 3 ;;
esac
exit 0
EOF
printf '#!/bin/sh\nexit 7\n' >"$FIXES/broken/fix.sh"
cat >"$ROOT/elsewhere/evil/fix.sh" <<'EOF'
#!/bin/sh
touch "$GAMECOVE_ROOT/pwned"
EOF
ln -s "$ROOT/elsewhere/evil" "$FIXES/linked"
mkdir -p "$FIXES/nofix" "$FIXES/Upper"
printf '#!/bin/sh\nexit 0\n' >"$FIXES/Upper/fix.sh"

gf() {
	GAMECOVE_ROOT="$ROOT" sh "$FIX" "$@"
}

expect_code 64 "no args" gf
expect_code 64 "one arg" gf dummy
expect_code 65 "unknown fix" gf nope install
expect_code 65 "dot-dot" gf .. install
expect_code 65 "traversal" gf ../elsewhere/evil install
expect_code 65 "slash" gf dummy/../dummy install
expect_code 65 "absolute" gf /etc install
expect_code 65 "upper case" gf Upper install
expect_code 65 "leading dash" gf -dummy install
expect_code 65 "folder without fix.sh" gf nofix install
expect_code 65 "symlinked fix folder" gf linked install
if [ ! -e "$ROOT/pwned" ]; then ok; else bad "evil fix ran"; fi
expect_code 64 "bad action" gf dummy explode
expect_code 64 "install with extra arg" gf dummy install extra
expect_code 64 "set without value" gf dummy set
expect_code 66 "value with space" gf dummy set "8 0"
expect_code 66 "value with semicolon" gf dummy set "80;reboot"
expect_code 66 "value with newline" gf dummy set "80
x"
expect_code 66 "value starting with dash" gf dummy set -rf
if [ ! -e "$LOG" ]; then ok; else bad "rejected calls must not log"; fi

expect_code 0 "install" gf dummy install
contains "$ROOT/calls" "args:install" "install passed to fix"
contains "$ROOT/calls" "root:$ROOT" "fake root passed to fix"
contains "$LOG" "fix=dummy action=install value=- result=ok" "install logged"
contains "$LOG" "detail: install dummy" "fix can append detail"
contains "$LOG" "uid=$(id -u)" "uid logged"

expect_code 0 "set" gf dummy set 80
contains "$ROOT/calls" "args:set 80" "value passed to fix"
contains "$LOG" "fix=dummy action=set value=80 result=ok" "set logged"

expect_code 3 "fix failure propagates" gf dummy set boom
contains "$LOG" "action=set value=boom result=fail(3)" "failure logged"
expect_code 7 "broken fix" gf broken install
contains "$LOG" "fix=broken action=install value=- result=fail(7)" "broken logged"
# review problem 9: the very first log line (no changes.log yet) prints no "cannot open" error
rm -f "$LOG" "$LOG.1"
gf dummy set 81 >/dev/null 2>"$T/err1"
lacks "$T/err1" "cannot open" "first log write has no error about the missing log"
lacks "$T/err1" "No such file" "first log write has no error about the missing log"
contains "$LOG" "fix=dummy action=set value=81 result=ok" "first log line written"
# review L1: the log is capped; over the limit it becomes changes.log.1 and a new one starts
rm -f "$LOG.1"
for i in 1 2 3 4 5 6; do GAMECOVE_LOG_MAX=300 gf dummy set "$i" >/dev/null 2>&1; done
if [ -f "$LOG.1" ]; then ok; else bad "log rotated to changes.log.1 once over the cap"; fi
if [ "$(wc -c <"$LOG")" -le 600 ]; then ok; else bad "log stays near the cap ($(wc -c <"$LOG") bytes)"; fi
contains "$LOG" "value=6 result=ok" "newest line kept after rotation"

lines_before="$(wc -l <"$LOG")"
expect_code 0 "status" gf dummy status
contains "$T/out" "installed=yes" "status output passed through"
if [ "$(wc -l <"$LOG")" -eq "$lines_before" ]; then ok; else bad "status must not log"; fi

expect_code 0 "remove" gf dummy remove
contains "$LOG" "action=remove value=- result=ok" "remove logged"

# update (docs/FIXES.md): bring an installed fix to the script's revision; the fix rolls back when it fails
expect_code 0 "update" gf dummy update
contains "$ROOT/calls" "args:update" "update reaches the fix"
contains "$LOG" "fix=dummy action=update value=- result=ok" "update logged"
expect_code 7 "a failed update's code comes back" gf broken update
contains "$LOG" "fix=broken action=update value=- result=fail(7)" "failed update logged"
expect_code 64 "update takes no value" gf dummy update now

expect_code 0 "list" gf --list
contains "$T/out" "^dummy$" "list shows dummy"
contains "$T/out" "^broken$" "list shows broken"
lacks "$T/out" "nofix" "list hides folders without fix.sh"
lacks "$T/out" "Upper" "list hides invalid names"

# Under pkexec the caller's GAMECOVE_ROOT / GAMECOVE_FIXES_DIR are ignored, so
# the fake fixes must not be found (real /usr/lib/gamecove has no "dummy").
: >"$ROOT/calls"
PKEXEC_UID=1000 GAMECOVE_ROOT="$ROOT" GAMECOVE_FIXES_DIR="$FIXES" sh "$FIX" dummy install >"$T/out" 2>&1
code=$?
if [ "$code" -eq 65 ]; then ok; else bad "pkexec must ignore GAMECOVE_ROOT (exit $code)"; fi
if [ ! -s "$ROOT/calls" ]; then ok; else bad "fix ran from caller-chosen path under pkexec"; fi

# Under pkexec GAMECOVE_PATH is cleared too (stub programs can't be slipped in).
if awk '/PKEXEC_UID:-}" \]; then/ { inblk = 1 } inblk && /^fi/ { exit } inblk && /GAMECOVE_PATH=""/ { found = 1 } END { exit !found }' "$FIX"; then
	ok
else
	bad "pkexec block must clear GAMECOVE_PATH"
fi

# ------------------------------------------------- gamecove-fix --remove-all (uninstall, review S2-5)
RA="$T/raroot"
RAF="$RA/usr/lib/gamecove/fixes"
for spec in "charge-limit:installed=yes" "controller-led:state=on" "fan:installed=no" "gpd-fingerprint:state=not-needed" "claw8ex-vrr:installed=yes"; do
	n="${spec%%:*}"
	mkdir -p "$RAF/$n"
	cat >"$RAF/$n/fix.sh" <<FIXEOF
#!/bin/sh
case "\$1" in
status) echo "applies=yes"; echo "${spec#*:}" ;;
remove) echo "$n" >>"\$GAMECOVE_ROOT/removed"; [ "$n" = claw8ex-vrr ] && exit 1 ;;
esac
exit 0
FIXEOF
done
GAMECOVE_ROOT="$RA" sh "$FIX" --remove-all >"$T/out" 2>&1
code=$?
if [ "$code" -eq 1 ]; then ok; else bad "--remove-all reports a failed remove (exit $code)"; fi
contains "$RA/removed" "^charge-limit$" "installed=yes: removed (charge limit back)"
contains "$RA/removed" "^controller-led$" "state=on without installed=: removed (LEDs back)"
lacks "$RA/removed" "^fan$" "installed=no: left alone"
lacks "$RA/removed" "gpd-fingerprint" "not-needed: left alone"
contains "$T/out" "^failed=claw8ex-vrr$" "a failed one is named"
contains "$RA/var/lib/gamecove/changes.log" "fix=charge-limit action=remove value=- result=ok" "logged"
expect_code 64 "--remove-all takes no arguments" sh "$FIX" --remove-all extra

# ------------------------------------------------- gamecove-fix-set (no password)
# polkit runs this one without a password, so it may only `set` (and `status`)
# the low-risk fixes with fixed values, then hand over to gamecove-fix.
FIXSET="$REPO/packaging/libexec/gamecove-fix-set"
for n in fan charge-limit claw8ex-gyro claw8ex-vrr claw8ex-buttons claw-kbd-wakeup power-tune; do
	mkdir -p "$FIXES/$n"
	cat >"$FIXES/$n/fix.sh" <<FIXEOF
#!/bin/sh
echo "$n:\$*" >>"\$GAMECOVE_ROOT/calls"
[ "\$1" = status ] && echo "installed=yes" && echo "state=on"
exit 0
FIXEOF
done
gfs() {
	GAMECOVE_ROOT="$ROOT" sh "$FIXSET" "$@"
}
: >"$ROOT/calls"
expect_code 64 "set entry: no args" gfs
expect_code 64 "set entry: one arg" gfs fan
expect_code 64 "set entry refuses install" gfs fan install
expect_code 64 "set entry refuses remove" gfs fan remove
expect_code 64 "set entry refuses gyro install" gfs claw8ex-gyro install
expect_code 64 "set entry refuses gyro remove" gfs claw8ex-gyro remove
expect_code 64 "set entry refuses charge install" gfs charge-limit install
expect_code 64 "set entry refuses other actions" gfs fan explode
expect_code 66 "set entry refuses vrr on (boot config: refresh only)" gfs claw8ex-vrr set on
expect_code 64 "set entry refuses vrr install" gfs claw8ex-vrr install
expect_code 64 "set entry refuses vrr remove" gfs claw8ex-vrr remove
expect_code 66 "set entry refuses buttons on" gfs claw8ex-buttons set on
expect_code 64 "set entry refuses buttons install" gfs claw8ex-buttons install
expect_code 65 "set entry refuses other fixes" gfs dummy set 80
expect_code 65 "set entry refuses traversal" gfs ../fan set quiet
expect_code 65 "set entry refuses --list" gfs --list x
expect_code 66 "set entry: fan value" gfs fan set turbo
expect_code 66 "set entry: charge below 50" gfs charge-limit set 40
expect_code 66 "set entry: charge above 100" gfs charge-limit set 101
expect_code 66 "set entry: charge not a number" gfs charge-limit set 8x
expect_code 66 "set entry: gyro old two-token form" gfs claw8ex-gyro set accel
expect_code 64 "set entry: gyro with extra arg" gfs claw8ex-gyro set accel on
expect_code 66 "set entry: gyro install as value" gfs claw8ex-gyro set install
expect_code 64 "set entry: set with extra arg" gfs fan set quiet extra
if [ ! -s "$ROOT/calls" ]; then ok; else bad "refused set-entry calls must not run a fix ($(cat "$ROOT/calls"))"; fi
expect_code 0 "set entry: fan quiet" gfs fan set quiet
contains "$ROOT/calls" "^fan:set quiet$" "fan set reached fix.sh"
contains "$LOG" "fix=fan action=set value=quiet result=ok" "set entry logs through the dispatcher"
expect_code 0 "set entry: charge 80" gfs charge-limit set 80
expect_code 0 "set entry: charge 100" gfs charge-limit set 100
expect_code 0 "set entry: charge release" gfs charge-limit set release
contains "$ROOT/calls" "^charge-limit:set release$" "charge release reached fix.sh"
expect_code 66 "set entry: fan release" gfs fan set release
contains "$ROOT/calls" "^charge-limit:set 100$" "charge set reached fix.sh"
expect_code 0 "set entry: gyro accel-on" gfs claw8ex-gyro set accel-on
expect_code 0 "set entry: gyro accel-off" gfs claw8ex-gyro set accel-off
contains "$ROOT/calls" "^claw8ex-gyro:set accel-off$" "gyro set reached fix.sh"
# review S1-4: rebuilding the InputPlumber override after an OS update needs no password
expect_code 0 "set entry: buttons refresh" gfs claw8ex-buttons set refresh
expect_code 0 "set entry: gyro refresh" gfs claw8ex-gyro set refresh
contains "$ROOT/calls" "^claw8ex-buttons:set refresh$" "buttons refresh reached fix.sh"
# after a SteamOS update the VRR fix's grub line comes back without a password; nothing else of it does
expect_code 0 "set entry: vrr refresh" gfs claw8ex-vrr set refresh
contains "$ROOT/calls" "^claw8ex-vrr:set refresh$" "vrr refresh reached fix.sh"
expect_code 66 "set entry: vrr install as value" gfs claw8ex-vrr set install
expect_code 66 "set entry: vrr remove as value" gfs claw8ex-vrr set remove
expect_code 0 "set entry: status" gfs fan status
contains "$T/out" "^state=on$" "status passed through"
expect_code 0 "set entry: fan curve" gfs fan set curve:0,40,50,60,80,100
contains "$ROOT/calls" "^fan:set curve:0,40,50,60,80,100$" "fan curve reached fix.sh"
# review L2: the session's `timeout pkexec` can't stop a root child, so the set entry bounds the fix itself
cp "$FIXES/charge-limit/fix.sh" "$T/charge-limit.fix.sh"
printf '#!/bin/sh\nsleep 30\n' >"$FIXES/charge-limit/fix.sh"
t0=$(date +%s)
GAMECOVE_FIX_SET_TIMEOUT=1 expect_code 124 "set entry: a fix that hangs is stopped" gfs charge-limit set 80
if [ $(($(date +%s) - t0)) -le 8 ]; then ok; else bad "set entry: hung fix stopped within the bound"; fi
cp "$T/charge-limit.fix.sh" "$FIXES/charge-limit/fix.sh"
expect_code 66 "set entry: fan curve letters" gfs fan set curve:0,40,x
expect_code 66 "set entry: fan curve empty" gfs fan set curve:
expect_code 66 "set entry: fan curve trailing comma" gfs fan set curve:1,2,
expect_code 66 "set entry: fan curve shell" gfs fan set 'curve:1;reboot'
expect_code 66 "set entry: fan curve leading zero (review M1)" gfs fan set curve:0,040,040,045,060,075
expect_code 66 "set entry: fan curve leading zero first" gfs fan set curve:00,40,40,45,60,75
for v in boost:off epp:balance_power governor:powersave cpumax:70 gpulevel:auto gpumin:600 \
	gpumax:1800 gpuprofile:power_saving sppt:28 fppt:33 platform:low-power tau:8000000 tau:restore \
	thermald:hold thermald:release battery:long-life restore; do
	expect_code 0 "set entry: power-tune $v" gfs power-tune set "$v"
done
# review S3-2: not day-to-day, or risky: the administrator password (gamecove-fix)
for v in smt:on cores:4 sleep:deep mcu:on mcu:off; do
	expect_code 66 "set entry refuses power-tune $v" gfs power-tune set "$v"
done
contains "$ROOT/calls" "^power-tune:set epp:balance_power$" "power-tune set reached fix.sh"
expect_code 66 "set entry: power-tune unknown key" gfs power-tune set fan:max
expect_code 66 "set entry: power-tune no key" gfs power-tune set 15
expect_code 66 "set entry: power-tune empty value" gfs power-tune set epp:
expect_code 66 "set entry: power-tune bad chars" gfs power-tune set 'epp:a b'
expect_code 66 "set entry: power-tune path" gfs power-tune set epp:../x
expect_code 66 "set entry: power-tune upper case" gfs power-tune set epp:POWER
expect_code 64 "set entry refuses power-tune install" gfs power-tune install
expect_code 64 "set entry refuses power-tune remove" gfs power-tune remove
# the fix lifecycle adds no prompt-free door: retiring or updating a fix is install / remove work (admin password)
expect_code 64 "set entry refuses update" gfs claw8ex-buttons update
expect_code 66 "set entry refuses set update" gfs claw8ex-buttons set update
expect_code 66 "set entry refuses set retire" gfs claw8ex-buttons set retire
expect_code 65 "set entry refuses a file fix update" gfs claw-kbd-wakeup update
lacks "$ROOT/calls" "install" "no install reached a fix through the set entry"
lacks "$ROOT/calls" "remove" "no remove reached a fix through the set entry"
# review S3-2: the small file fixes (udev rules, session files) need the administrator password now
: >"$ROOT/calls"
expect_code 65 "set entry refuses a file fix on" gfs claw-kbd-wakeup set on
expect_code 65 "set entry refuses a file fix off" gfs claw-kbd-wakeup set off
expect_code 65 "set entry refuses a file fix status" gfs claw-kbd-wakeup status
expect_code 66 "set entry: fan on is not a value" gfs fan set on
if [ ! -s "$ROOT/calls" ]; then ok; else bad "refused file-fix calls must not run a fix"; fi
# the policy text names exactly the power-tune keys the set entry takes, and none it refuses
keys=$(sed -n 's/.*power-tune:\([a-z]*\):\*.*/\1/p; s/.*| power-tune:\([a-z]*\):\*.*/\1/p' "$FIXSET" | tr ' |\\' '\n\n\n' | grep -o 'power-tune:[a-z]*' | sed 's/power-tune://' | sort -u)
[ -z "$keys" ] && keys=$(grep -o 'power-tune:[a-z]*:\*' "$FIXSET" | sed 's/power-tune:\([a-z]*\):\*/\1/' | sort -u)
POLICY="$REPO/packaging/polkit/io.github.ihulksmashi.gamecove.policy"
for k in $keys; do
	if grep -q "\b$k\b" "$POLICY"; then ok; else bad "policy text doesn't mention power-tune $k, which gamecove-fix-set allows"; fi
done
for k in smt cores sleep mcu; do
	if printf '%s\n' "$keys" | grep -qx "$k"; then bad "gamecove-fix-set must not take power-tune $k"; else ok; fi
done
# Under pkexec it hands over to the installed dispatcher; the caller's paths are ignored.
: >"$ROOT/calls"
PKEXEC_UID=1000 GAMECOVE_ROOT="$ROOT" GAMECOVE_FIXES_DIR="$FIXES" sh "$FIXSET" fan set quiet >"$T/out" 2>&1
code=$?
if [ "$code" -ne 0 ]; then ok; else bad "set entry under pkexec must not use the caller's fixes"; fi
if [ ! -s "$ROOT/calls" ]; then ok; else bad "set entry ran a caller-chosen fix under pkexec"; fi
rm -rf "$FIXES/fan" "$FIXES/charge-limit" "$FIXES/claw8ex-gyro" "$FIXES/claw8ex-vrr" "$FIXES/claw8ex-buttons" "$FIXES/claw-kbd-wakeup"

# ------------------------------------------------------------ session-select
BIN="$T/bin"
mkdir -p "$BIN"
cat >"$BIN/steamosctl" <<EOF
#!/bin/sh
echo "\$*" >>"$T/steamosctl.log"
EOF
chmod +x "$BIN/steamosctl"
# fake busctl: two composite devices and a target device in InputPlumber's tree
cat >"$BIN/busctl" <<EOF
#!/bin/sh
echo "\$*" >>"$T/busctl.log"
case "\$*" in
*" tree "*) printf '%s\\n' /org/shadowblip/InputPlumber /org/shadowblip/InputPlumber/CompositeDevice0 \\
	/org/shadowblip/InputPlumber/CompositeDevice1 /org/shadowblip/InputPlumber/devices/target/dbus0 ;;
esac
EOF
chmod +x "$BIN/busctl"
SEL="$REPO/session/gamecove-session-select"
RESET0="--system --timeout=2 set-property org.shadowblip.InputPlumber /org/shadowblip/InputPlumber/CompositeDevice0 org.shadowblip.Input.CompositeDevice InterceptMode u 0"
RESET1="--system --timeout=2 set-property org.shadowblip.InputPlumber /org/shadowblip/InputPlumber/CompositeDevice1 org.shadowblip.Input.CompositeDevice InterceptMode u 0"

sel() {
	: >"$T/steamosctl.log"
	PATH="$BIN:$PATH" sh "$SEL" "$@"
}

# switching, saved defaults, restore, guard, bounce and the crash-loop guard:
# packaging/tests/session.sh (runs as root too, with a fake id)
if sh "$REPO/packaging/tests/session.sh" >"$T/out" 2>&1; then ok; else bad "session.sh: $(grep FAIL "$T/out" | head -20)"; fi
: >"$T/busctl.log"
if [ "$(id -u)" -ne 0 ]; then
	expect_code 0 "switch to steam resets InterceptMode" env XDG_DATA_HOME="$T/xdg" PATH="$BIN:$PATH" sh "$SEL" steam
	contains "$T/busctl.log" "^$RESET0$" "switching resets InterceptMode on device 0"
	contains "$T/busctl.log" "^$RESET1$" "switching resets InterceptMode on device 1"
	lacks "$T/busctl.log" "dbus0 " "target devices left alone"
	: >"$T/busctl.log"
	expect_code 64 "unknown target, no reset" sel windows
	lacks "$T/busctl.log" "set-property" "bad usage resets nothing"
fi

# ------------------------------------------------------------ session-client
CB="$T/clientbin"
mkdir -p "$CB"
cat >"$CB/steam" <<EOF
#!/bin/sh
echo "steam \$*" >>"$T/client.log"
EOF
cat >"$CB/pgrep" <<EOF
#!/bin/sh
[ -f "$T/steam-running" ]
EOF
cat >"$CB/gamecove.x86_64" <<EOF
#!/bin/sh
echo "app \$*" >>"$T/client.log"
EOF
chmod +x "$CB/steam" "$CB/pgrep" "$CB/gamecove.x86_64"
cp "$BIN/busctl" "$CB/busctl"
CLIENT="$REPO/session/gamecove-session-client"

client() {
	: >"$T/client.log"
	PATH="$CB:$PATH" GAMECOVE_BIN="$CB/gamecove.x86_64" GAMECOVE_STEAM_MODE="$1" sh "$CLIENT"
	sleep 0.3 # Steam is started in the background
}

expect_code 0 "client silent" client silent
contains "$T/client.log" "^steam -silent$" "steam started silently"
contains "$T/client.log" "^app --display-driver x11 --rendering-driver opengl3 --fullscreen$" "app on X11"
expect_code 0 "client gamepadui" client gamepadui
contains "$T/client.log" "^steam -silent -gamepadui -steamos3 -steampal -steamdeck$" "gamepadui flags"
expect_code 0 "client off" client off
lacks "$T/client.log" "^steam" "no steam when off"
touch "$T/steam-running"
expect_code 0 "client steam already running" client silent
lacks "$T/client.log" "^steam" "steam not started twice"
rm -f "$T/steam-running"
expect_code 1 "client missing binary" env PATH="$CB:$PATH" GAMECOVE_BIN=/nonexistent GAMECOVE_STEAM_MODE=off sh "$CLIENT"
# the app is not exec'd: after it exits (a crash here) the client hands the
# controller back and passes the app's exit code on
cat >"$T/crash.x86_64" <<EOF
#!/bin/sh
echo "app \$*" >>"$T/client.log"
exit 3
EOF
chmod +x "$T/crash.x86_64"
: >"$T/busctl.log"
expect_code 3 "client passes the app's exit code" env PATH="$CB:$PATH" GAMECOVE_BIN="$T/crash.x86_64" GAMECOVE_STEAM_MODE=off sh "$CLIENT"
contains "$T/busctl.log" "^$RESET0$" "client resets InterceptMode after the app exits"
contains "$T/busctl.log" "^$RESET1$" "client resets every composite device"
lacks "$REPO/session/gamecove-session-client" '^exec "\$GAMECOVE_BIN"' "client does not exec the app"

# -------------------------------------------------------- session file syntax
if bash -n "$REPO/session/gamescope-session-plus/sessions.d/gamecove"; then ok; else bad "sessions.d/gamecove syntax"; fi
# shellcheck disable=SC2016  # expanded by the inner bash
if bash -c 'set -a; . "$1"; [ "$CLIENTCMD" = /usr/libexec/gamecove/gamecove-session-client ] && [ "$GAMECOVE_STEAM_MODE" = silent ]' _ \
	"$REPO/session/gamescope-session-plus/sessions.d/gamecove"; then ok; else bad "session file sets CLIENTCMD"; fi
contains "$REPO/session/wayland-sessions/gamecove.desktop" "^Exec=gamescope-session-plus gamecove$" "desktop Exec"
# post_client_shutdown: InterceptMode 0 everywhere, charge limit released through
# the no-password set entry (only when the fix keeps a limit), then Steam closed
PB="$T/postbin"
mkdir -p "$PB" "$T/gcstate/fixes/charge-limit"
cp "$BIN/busctl" "$PB/busctl"
printf '#!/bin/sh\necho "pkexec $*" >>"%s/post.log"\n' "$T" >"$PB/pkexec"
printf '#!/bin/sh\nshift\nexec "$@"\n' >"$PB/timeout"
printf '#!/bin/sh\nexit 0\n' >"$T/fix-set"
chmod +x "$PB/pkexec" "$PB/timeout" "$T/fix-set"
post() {
	: >"$T/busctl.log"
	: >"$T/post.log"
	# shellcheck disable=SC2016  # expanded by the inner bash
	PATH="$PB:/usr/bin:/bin" GAMECOVE_STATE_DIR="$T/gcstate" GAMECOVE_FIX_SET="$T/fix-set" GAMECOVE_ROOT_WAIT_S="${ROOT_WAIT:-10}" \
		bash -c 'set -a; . "$1"; post_client_shutdown' _ "$REPO/session/gamescope-session-plus/sessions.d/gamecove"
}
expect_code 0 "post_client_shutdown without a charge limit" post
contains "$T/busctl.log" "^$RESET0$" "session end resets InterceptMode on device 0"
contains "$T/busctl.log" "^$RESET1$" "session end resets InterceptMode on device 1"
lacks "$T/post.log" "pkexec" "no charge limit kept: no pkexec"
echo 80 >"$T/gcstate/fixes/charge-limit/limit"
expect_code 0 "post_client_shutdown with a charge limit" post
contains "$T/post.log" "^pkexec $T/fix-set charge-limit set release$" "session end releases the charge limit"
lacks "$T/post.log" "power-tune" "nothing recorded by power-tune: no restore"
mkdir -p "$T/gcstate/fixes/power-tune/orig"
expect_code 0 "post_client_shutdown with power-tune values" post
contains "$T/post.log" "^pkexec $T/fix-set power-tune set restore$" "session end restores power-tune values"
rmdir "$T/gcstate/fixes/power-tune/orig"
: >"$T/gcstate/fixes/power-tune/thermald-held"
expect_code 0 "post_client_shutdown with thermald held" post
contains "$T/post.log" "^pkexec $T/fix-set power-tune set restore$" "session end starts thermald again"
# low (review): a root restore that hangs must not hold up the session's end (timeout only killed pkexec)
cp "$PB/pkexec" "$T/pkexec.keep"
printf '#!/bin/sh\necho "pkexec $*" >>"%s/post.log"\nsleep 20\n' "$T" >"$PB/pkexec"
rm -f "$PB/timeout"
started="$(date +%s)"
ROOT_WAIT=1 post
if [ $(($(date +%s) - started)) -lt 6 ]; then ok; else bad "session end waited $(($(date +%s) - started)) s on a hung root restore"; fi
contains "$T/post.log" "^pkexec $T/fix-set charge-limit set release$" "the restore was still started"
cp "$T/pkexec.keep" "$PB/pkexec"
printf '#!/bin/sh\nshift\nexec "$@"\n' >"$PB/timeout"
chmod +x "$PB/pkexec" "$PB/timeout"
# final review, session: a root restore that FAILS (in a session script running under set -e) must not skip
# the next one, nor leave the session waiting for the whole limit
printf '#!/bin/sh\necho "pkexec $*" >>"%s/post.log"\nexit 126\n' "$T" >"$PB/pkexec"
mkdir -p "$T/gcstate/fixes/power-tune/orig"
: >"$T/busctl.log"
: >"$T/post.log"
started="$(date +%s)"
# shellcheck disable=SC2016  # expanded by the inner bash
PATH="$PB:/usr/bin:/bin" GAMECOVE_STATE_DIR="$T/gcstate" GAMECOVE_FIX_SET="$T/fix-set" GAMECOVE_ROOT_WAIT_S=20 \
	bash -c 'set -a; . "$1"; set -e; root_restores' _ "$REPO/session/gamescope-session-plus/sessions.d/gamecove"
if [ $(($(date +%s) - started)) -lt 10 ]; then ok; else bad "session end waited the whole limit on a failed root restore"; fi
contains "$T/post.log" "^pkexec $T/fix-set charge-limit set release$" "the release was tried"
contains "$T/post.log" "^pkexec $T/fix-set power-tune set restore$" "a failed charge-limit release doesn't skip the power restore (session end)"
rmdir "$T/gcstate/fixes/power-tune/orig"
cp "$T/pkexec.keep" "$PB/pkexec"
chmod +x "$PB/pkexec"
if grep -q "3 app crashes in 2 minutes" "$REPO/session/gamescope-session-plus/sessions.d/gamecove"; then bad "sessions.d/gamecove still describes the old crash guard"; else ok; fi
# busctl --list tree can hang on a stuck bus: every call has a timeout
for f in "$REPO/session/gamecove-session-client" "$REPO/session/gamecove-session-select" "$REPO/session/gamescope-session-plus/sessions.d/gamecove"; do
	if grep -n 'busctl --' "$f" | grep -v -- '--timeout=' | grep -q .; then bad "busctl without --timeout in $f"; else ok; fi
done

# ------------------------------------------------------------------ install.sh
IB="$T/installbin"
mkdir -p "$IB"
cat >"$IB/rpm-ostree" <<EOF
#!/bin/sh
echo "rpm-ostree \$*" >>"$T/install.log"
EOF
chmod +x "$IB/rpm-ostree"
touch "$T/gamecove-0.1.0-1.x86_64.rpm" "$T/image-info.json"
inst() {
	PATH="$IB:$PATH" ASSUME_YES=1 IMAGE_INFO="$T/image-info.json" sh "$REPO/packaging/install.sh" "$@"
}
# final review, session: the root autologin guard goes into /etc on Bazzite too (from the deployment
# rpm-ostree staged, since nothing is live before the reboot); a root step that fails stops the install
printf '#!/bin/sh\necho "pkexec $1 $2 <script> $4 $5" >>"%s/install.log"\nexec "$@"\n' "$T" >"$IB/pkexec"
chmod +x "$IB/pkexec"
IR="$T/instroot"
mkdir -p "$IR/ostree/deploy/default/deploy/abc.0/usr/lib/gamecove/session" "$IR/etc"
cp "$REPO/session/gamecove-autologin-guard" "$IR/ostree/deploy/default/deploy/abc.0/usr/lib/gamecove/session/"
cp "$REPO/session/systemd/gamecove-autologin-guard.service" "$IR/ostree/deploy/default/deploy/abc.0/usr/lib/gamecove/session/"
expect_code 0 "install.sh install" env GAMECOVE_ROOT="$IR" PATH="$IB:$PATH" ASSUME_YES=1 IMAGE_INFO="$T/image-info.json" sh "$REPO/packaging/install.sh" "$T/gamecove-0.1.0-1.x86_64.rpm"
contains "$T/install.log" "rpm-ostree install $T/gamecove-0.1.0-1.x86_64.rpm" "rpm-ostree install"
if cmp -s "$REPO/session/gamecove-autologin-guard" "$IR/etc/gamecove/autologin-guard" && [ -x "$IR/etc/gamecove/autologin-guard" ] &&
	[ -f "$IR/etc/systemd/system/gamecove-autologin-guard.service" ] && [ -L "$IR/etc/systemd/system/multi-user.target.wants/gamecove-autologin-guard.service" ]; then ok; else bad "install.sh must put the autologin guard and its enabled unit into /etc"; fi
expect_code 1 "install.sh stops when the guard can't be installed" env GAMECOVE_ROOT="$T/no-such-root" PATH="$IB:$PATH" ASSUME_YES=1 IMAGE_INFO="$T/image-info.json" sh "$REPO/packaging/install.sh" "$T/gamecove-0.1.0-1.x86_64.rpm"
contains "$T/out" "Couldn't install the guard" "says so"
# review H4: --uninstall puts the boot default back and undoes every fix first, and stops if either fails
cat >"$IB/select" <<EOF
#!/bin/sh
echo "select \$*" >>"$T/install.log"
exit \$(cat "$T/select-code" 2>/dev/null || echo 0)
EOF
cat >"$IB/pkexec" <<EOF
#!/bin/sh
echo "pkexec \$*" >>"$T/install.log"
exit \$(cat "$T/pkexec-code" 2>/dev/null || echo 0)
EOF
printf '#!/bin/sh\n' >"$IB/fixhelper"
chmod +x "$IB/select" "$IB/pkexec" "$IB/fixhelper"
uninst() {
	: >"$T/install.log"
	PATH="$IB:$PATH" ASSUME_YES=1 IMAGE_INFO="$T/image-info.json" SESSION_SELECT="$IB/select" GUARD_COPY="$T/no-guard" \
		FIX_HELPER="$IB/fixhelper" PKEXEC="$IB/pkexec" sh "$REPO/packaging/install.sh" --uninstall
}
expect_code 0 "install.sh uninstall" uninst
contains "$T/install.log" "rpm-ostree uninstall gamecove" "rpm-ostree uninstall"
contains "$T/install.log" "^select restore$" "uninstall restores the boot default"
contains "$T/install.log" "^pkexec $IB/fixhelper --remove-all$" "uninstall undoes every fix"
if [ "$(head -n 1 "$T/install.log")" = "select restore" ] && [ "$(tail -n 1 "$T/install.log")" = "rpm-ostree uninstall gamecove" ]; then ok; else bad "restore and fixes before the package goes: $(cat "$T/install.log")"; fi
# the guard in /etc goes with a proper uninstall (the boot default is back by then)
printf '#!/bin/sh\necho "pkexec $1" >>"%s/install.log"\nexec "$@"\n' "$T" >"$IB/pkexec.real"
cp "$IB/pkexec" "$IB/pkexec.fake" && cp "$IB/pkexec.real" "$IB/pkexec" && chmod +x "$IB/pkexec"
: >"$T/install.log"
GAMECOVE_ROOT="$IR" PATH="$IB:$PATH" ASSUME_YES=1 IMAGE_INFO="$T/image-info.json" SESSION_SELECT="$IB/select" GUARD_COPY="$T/no-guard" \
	FIX_HELPER="$IB/fixhelper" PKEXEC="$IB/pkexec" sh "$REPO/packaging/install.sh" --uninstall >"$T/out" 2>&1
if [ ! -e "$IR/etc/gamecove" ] && [ ! -e "$IR/etc/systemd/system/gamecove-autologin-guard.service" ] && [ ! -L "$IR/etc/systemd/system/multi-user.target.wants/gamecove-autologin-guard.service" ]; then ok; else bad "install.sh --uninstall must remove the autologin guard from /etc"; fi
[ "$(tail -n 1 "$T/install.log")" = "rpm-ostree uninstall gamecove" ] && ok || bad "the layer still goes last: $(cat "$T/install.log")"
# and so does the display file every gamescope session reads (rotation / refresh unlock would stay in Steam Gaming Mode)
mkdir -p "$T/icfg/environment.d"
echo "ORIENTATION=left" >"$T/icfg/environment.d/80-gamecove-display.conf"
echo "X=1" >"$T/icfg/environment.d/90-mine.conf"
XDG_CONFIG_HOME="$T/icfg" GAMECOVE_ROOT="$IR" PATH="$IB:$PATH" ASSUME_YES=1 IMAGE_INFO="$T/image-info.json" SESSION_SELECT="$IB/select" GUARD_COPY="$T/no-guard" \
	FIX_HELPER="$IB/fixhelper" PKEXEC="$IB/pkexec" sh "$REPO/packaging/install.sh" --uninstall >"$T/out" 2>&1
[ ! -e "$T/icfg/environment.d/80-gamecove-display.conf" ] && [ -f "$T/icfg/environment.d/90-mine.conf" ] && ok || bad "install.sh --uninstall must remove 80-gamecove-display.conf and nothing else there"
cp "$IB/pkexec.fake" "$IB/pkexec"
echo 1 >"$T/select-code"
expect_code 1 "install.sh uninstall stops when restore fails" uninst
lacks "$T/install.log" "rpm-ostree uninstall" "package kept when the boot default couldn't go back"
rm -f "$T/select-code"
echo 126 >"$T/pkexec-code"
expect_code 1 "install.sh uninstall stops when the fixes can't be undone" uninst
lacks "$T/install.log" "rpm-ostree uninstall" "package kept when the fixes couldn't be undone"
rm -f "$T/pkexec-code"
expect_code 64 "install.sh missing rpm" inst "$T/none.rpm"
expect_code 1 "install.sh says no" sh -c "echo n | PATH='$IB:$PATH' IMAGE_INFO='$T/image-info.json' sh '$REPO/packaging/install.sh' '$T/gamecove-0.1.0-1.x86_64.rpm'"

# ------------------------------------------------------------ apply-choices
AC="$REPO/packaging/libexec/gamecove-apply-choices"
AB="$T/acbin"
AH="$T/achome"
mkdir -p "$AB" "$AH"
cat >"$AB/gamecove-session-select" <<EOF
#!/bin/sh
echo "select \$*" >>"$T/ac.log"
exit \${SELECT_CODE:-0}
EOF
cat >"$AB/pkexec" <<EOF
#!/bin/sh
echo "pkexec \$*" >>"$T/ac.log"
EOF
cat >"$AB/systemctl" <<EOF
#!/bin/sh
[ -f "$T/steam-mode-on" ] && echo "gamescope-session-plus@steam.service loaded active running Steam"
exit 0
EOF
chmod +x "$AB/gamecove-session-select" "$AB/pkexec" "$AB/systemctl"
ac() {
	: >"$T/ac.log"
	env GAMECOVE_PENDING="$AH/pending" GAMECOVE_INSTALLER_LOG="$AH/installer.log" \
		GAMECOVE_SESSION_SELECT="$AB/gamecove-session-select" GAMECOVE_FIX_SET=/usr/libexec/gamecove/gamecove-fix-set \
		PKEXEC="$AB/pkexec" SYSTEMCTL="$AB/systemctl" "$@" sh "$AC"
}
expect_code 0 "apply-choices without a pending file" ac
if [ ! -s "$T/ac.log" ]; then ok; else bad "nothing to apply must run nothing"; fi
# shellcheck disable=SC2016  # the $(...) must stay literal: it must never run
printf 'STARTUP=gamecove\nCHARGE_LIMIT=80\nEVIL=$(touch %s/pwned)\n' "$T" >"$AH/pending"
expect_code 0 "apply-choices before the package is live" ac GAMECOVE_SESSION_SELECT=/nonexistent/select
if [ -f "$AH/pending" ]; then ok; else bad "pending file must stay until the package is live"; fi
expect_code 0 "apply-choices gamecove" ac
contains "$T/ac.log" "^select gamecove --default --no-switch$" "default session set without switching"
contains "$T/ac.log" "^pkexec /usr/libexec/gamecove/gamecove-fix-set charge-limit set 80$" "charge limit through the no-password entry"
if [ ! -e "$AH/pending" ]; then ok; else bad "pending file removed once applied"; fi
if [ ! -e "$T/pwned" ]; then ok; else bad "pending file must never be sourced"; fi
contains "$AH/installer.log" "all installer choices applied" "apply-choices logs"
printf 'STARTUP=steam\nCHARGE_LIMIT=30\nFIXES=claw8ex-vrr,claw8ex-gyro\n' >"$AH/pending"
expect_code 0 "apply-choices steam" ac
contains "$T/ac.log" "^select steam --default --no-switch$" "steam stays default"
lacks "$T/ac.log" "charge-limit" "out-of-range charge limit ignored"
if [ "$(cat "$AH/pending")" = "FIXES=claw8ex-vrr,claw8ex-gyro" ]; then ok; else bad "fixes kept for Desktop Mode: $(cat "$AH/pending")"; fi
printf 'STARTUP=gamecove\n' >"$AH/pending"
expect_code 1 "apply-choices keeps the file when steamosctl fails" ac SELECT_CODE=3
if [ -f "$AH/pending" ]; then ok; else bad "failed apply keeps the pending file"; fi
printf 'STARTUP=gamecove\nSWITCH_NOW=1\n' >"$AH/pending"
expect_code 0 "apply-choices no switch outside Gaming Mode" ac
lacks "$T/ac.log" "^select gamecove$" "no switch from the desktop"
printf 'STARTUP=gamecove\nSWITCH_NOW=1\n' >"$AH/pending"
touch "$T/steam-mode-on"
expect_code 0 "apply-choices switches from Steam Gaming Mode" ac
contains "$T/ac.log" "^select gamecove$" "switched to GameCove now"
rm -f "$T/steam-mode-on"

# --------------------------------------------------- get-gamecove.sh bootstrap
GG="$REPO/packaging/get-gamecove.sh"
# review L29: curl | bash safety: nothing runs until the last line calls main
if [ "$(tail -n 1 "$GG")" = 'main "$@"' ] && grep -q '^main() {$' "$GG"; then ok; else bad "get-gamecove.sh must run everything from main on its last line"; fi
GB="$T/ggbin"
SRV="$T/ggsrv"
mkdir -p "$GB" "$SRV"
# Fake curl: serves $SRV/<last path part>, logs every URL. The API is modelled on the real
# repository (final review, blocker 2): releases/latest answers with a DATA release ("upscalers",
# not a pre-release, so GitHub marks it latest), the app release is only in the release list
# ($SRV/releases?per_page=100) and under releases/tags/<tag> ($SRV/tag.json).
cat >"$GB/curl" <<EOF
#!/bin/sh
out=""
url=""
fmt=""
while [ \$# -gt 0 ]; do
	case "\$1" in
	-o) out="\$2"; shift ;;
	-H) shift ;;
	-w) fmt="\$2"; shift ;;
	-*) ;;
	*) url="\$1" ;;
	esac
	shift
done
echo "\$url" >>"$T/curl.log"
# -w '\\n%{http_code}': the answer, then the status (000 when unreachable), like curl
code() { [ -n "\$fmt" ] && printf '\n%s' "\$1"; return 0; }
if [ -f "$T/offline" ]; then code 000; exit 6; fi
case "\$url" in
*/releases/latest | */releases/tags/* | */releases\?*)
	if [ -f "$T/api-status" ]; then [ -n "\$fmt" ] || exit 22; echo '{"message": "API rate limit exceeded"}'; code "\$(cat "$T/api-status")"; exit 0; fi ;;
esac
case "\$url" in
*/releases/latest) f="$SRV/latest.json" ;;
*/releases/tags/*) f="$SRV/tag.json" ;;
*) f="$SRV/\${url##*/}" ;;
esac
if [ ! -f "\$f" ]; then
	[ -n "\$fmt" ] || exit 22
	echo '{"message": "Not Found"}'
	code 404
	exit 0
fi
if [ -n "\$out" ]; then cp "\$f" "\$out"; else cat "\$f"; fi
code 200
EOF
cat >"$GB/badsum" <<'EOF'
#!/bin/sh
echo "0000000000000000000000000000000000000000000000000000000000000000  $1"
EOF
# fake cosign: logs its arguments; fails while $T/cosign-fail exists
cat >"$GB/cosign" <<EOF
#!/bin/sh
echo "\$*" >>"$T/cosign.log"
[ ! -f "$T/cosign-fail" ]
EOF
printf '#!/bin/sh\necho "$*" >>"%s/notify.log"\n' "$T" >"$GB/notify"
chmod +x "$GB/curl" "$GB/badsum" "$GB/cosign" "$GB/notify"
mkdir -p "$T/ggapp"
printf '#!/bin/sh\necho "app $*" >>"%s/launch.log"\n' "$T" >"$T/ggapp/gamecove.x86_64"
echo pck >"$T/ggapp/gamecove.pck"
tar -czf "$SRV/gamecove-0.2.0-x86_64.tar.gz" -C "$T/ggapp" gamecove.x86_64 gamecove.pck
echo rpm >"$SRV/gamecove-0.2.0-1.fc43.x86_64.rpm"
echo srpm >"$SRV/gamecove-0.2.0-1.fc43.src.rpm"
echo raw >"$SRV/gamecove-0.2.0-x86_64.raw"
cp "$GG" "$SRV/get-gamecove.sh"
(cd "$SRV" && sha256sum gamecove-0.2.0-x86_64.tar.gz gamecove-0.2.0-1.fc43.x86_64.rpm gamecove-0.2.0-1.fc43.src.rpm \
	gamecove-0.2.0-x86_64.raw get-gamecove.sh >SHA256SUMS)
echo '{"bundle": "fake"}' >"$SRV/SHA256SUMS.sigstore.json"
{
	echo '{'
	echo '  "tag_name": "v0.2.0",'
	echo '  "assets": ['
	for a in gamecove-0.2.0-1.fc43.src.rpm gamecove-0.2.0-1.fc43.x86_64.rpm gamecove-0.2.0-x86_64.raw \
		gamecove-0.2.0-x86_64.tar.gz get-gamecove.sh SHA256SUMS SHA256SUMS.sigstore.json; do
		echo "    { \"name\": \"$a\", \"browser_download_url\": \"https://example.test/dl/$a\" },"
	done
	echo '  ]'
	echo '}'
} >"$SRV/tag.json"
# what GitHub's releases/latest really answers here: a data release, never the app
cat >"$SRV/latest.json" <<'EOF'
{
  "tag_name": "upscalers",
  "draft": false,
  "prerelease": false,
  "body": "notes that try to look like a release: \"tag_name\": \"v9.9.9\", \"prerelease\": false } ] and a backslash \\",
  "assets": [
    { "name": "index.json", "uploader": { "login": "bot", "browser_download_url": "https://example.test/dl/not-an-asset" }, "browser_download_url": "https://example.test/dl/index.json" },
    { "name": "gamecove-9.9.9-x86_64.tar.gz", "browser_download_url": "https://example.test/dl/gamecove-9.9.9-x86_64.tar.gz" }
  ]
}
EOF
LIST="$SRV/releases?per_page=100"
# mklist <draft> <prerelease> [more releases, each ending with a comma]: the release list, newest first as GitHub
# sends it: the data release, then the app release from tag.json with these flags
mklist() {
	{
		echo '['
		cat "$SRV/latest.json"
		echo ','
		printf '%s' "${3:-}"
		sed "s/^  \"tag_name\": \"v0.2.0\",\$/  \"tag_name\": \"v0.2.0\", \"draft\": $1, \"prerelease\": $2,/" "$SRV/tag.json"
		echo ']'
	} >"$LIST"
}
mklist false false
osroot() {
	d="$T/os-$1"
	mkdir -p "$d/etc" "$d/run"
	printf '%s\n' "$2" >"$d/etc/os-release"
	[ -n "${3:-}" ] && touch "$d/run/ostree-booted"
	echo "$d"
}
R_BAZ="$(osroot bazzite 'ID=bazzite
ID_LIKE="fedora"' 1)"
R_FED="$(osroot fedora 'ID=fedora
VARIANT_ID=silverblue' 1)"
R_FEDWS="$(osroot fedora-ws 'ID=fedora
VARIANT_ID=workstation')"
R_DECK="$(osroot steamos 'ID=steamos
ID_LIKE=arch')"
R_ARCH="$(osroot arch 'ID=arch')"
gg() {
	root="$1"
	shift
	: >"$T/curl.log"
	: >"$T/cosign.log"
	env PATH="$GB:$PATH" GAMECOVE_HOME="$T/gghome" GAMECOVE_ROOT="$root" GAMECOVE_ARCH=x86_64 \
		GAMECOVE_API=https://api.example.test COSIGN="$GB/cosign" GAMECOVE_NOTIFY="$GB/notify" "$@" sh "$GG" --no-launch
}
for pair in "$R_BAZ:bazzite" "$R_FED:fedora-atomic" "$R_FEDWS:other" "$R_DECK:steamos" "$R_ARCH:other" "$T/os-none:other"; do
	got="$(GAMECOVE_ROOT="${pair%%:*}" sh "$GG" --detect-os)"
	if [ "$got" = "${pair##*:}" ]; then ok; else bad "detect-os ${pair%%:*}: got $got, want ${pair##*:}"; fi
done
GI="$T/gghome/.local/share/gamecove/installer"
mkdir -p "$T/gghome/Desktop"
expect_code 0 "bootstrap on Bazzite" gg "$R_BAZ"
if [ -x "$GI/app/gamecove.x86_64" ] && [ -f "$GI/app/gamecove.pck" ]; then ok; else bad "app unpacked"; fi
if [ -f "$GI/packages/gamecove-0.2.0-1.fc43.x86_64.rpm" ]; then ok; else bad "RPM downloaded"; fi
if [ ! -e "$GI/packages/gamecove-0.2.0-1.fc43.src.rpm" ]; then ok; else bad "source RPM must not be picked"; fi
lacks "$T/curl.log" "x86_64.raw" "no sysext on Bazzite"
contains "$GI/release.env" "^TAG=v0.2.0$" "release tag"
contains "$GI/release.env" "^OS=bazzite$" "release os"
contains "$GI/release.env" "^PACKAGE=$GI/packages/gamecove-0.2.0-1.fc43.x86_64.rpm$" "release package"
contains "$T/curl.log" "^https://api.example.test/repos/IHulkSmashI/GameCove/releases?per_page=100$" "asks the release list"
lacks "$T/curl.log" "/releases/latest" "never asks releases/latest (it answers with a data release)"
lacks "$T/curl.log" "9.9.9\|not-an-asset\|index.json" "nothing of the data release is downloaded"
if [ -x "$GI/get-gamecove.sh" ]; then ok; else bad "bootstrap keeps a checked copy of itself"; fi
GE="$T/gghome/.local/share/applications/io.github.ihulksmashi.GameCoveInstaller.desktop"
contains "$GE" "^Name=GameCove Installer$" "installer app entry"
contains "$GE" "^Exec=sh \"$GI/get-gamecove.sh\"$" "entry re-runs the bootstrap"
if [ -x "$T/gghome/Desktop/Install GameCove.desktop" ]; then ok; else bad "desktop shortcut"; fi
contains "$T/gghome/.local/share/gamecove/installer.log" "sha256 ok gamecove-0.2.0-x86_64.tar.gz" "checksums logged"
contains "$T/launch.log" "^app --headless -- --prefetch-photo$" "device photo fetched into the cache without opening the installer"
if [ -z "$(find "$GI" -name '.download.*')" ]; then ok; else bad "download folder cleaned up"; fi
expect_code 0 "bootstrap on SteamOS" gg "$R_DECK"
if [ -f "$GI/packages/gamecove-0.2.0-x86_64.raw" ] && [ ! -e "$GI/packages/gamecove-0.2.0-1.fc43.x86_64.rpm" ]; then ok; else bad "sysext replaces the RPM on SteamOS"; fi
contains "$GI/release.env" "^OS=steamos$" "steamos release env"
expect_code 0 "bootstrap elsewhere (app only)" gg "$R_ARCH"
contains "$GI/release.env" "^PACKAGE=$" "no package on other systems"
expect_code 0 "bootstrap with a tag" gg "$R_BAZ" GAMECOVE_TAG=v0.2.0
contains "$T/curl.log" "/releases/tags/v0.2.0$" "tag API"
# final review, blocker 2: v0.1.0 is a pre-release while a data release is GitHub's "latest": the app release is
# still found (and said to be a pre-release); the old lookup took "upscalers" and stopped with "no app download"
mklist false true
expect_code 0 "bootstrap with only a pre-release, a data release being latest" gg "$R_DECK"
contains "$T/out" "using the newest pre-release v0.2.0" "says a pre-release is used"
lacks "$T/out" "upscalers" "the data release is never picked"
contains "$GI/release.env" "^TAG=v0.2.0$" "pre-release picked"
lacks "$T/curl.log" "/releases/latest" "pre-release: releases/latest still isn't asked"
# the same list the way GitHub sends it to clients that aren't curl: all on one line
tr -d '\n' <"$LIST" >"$T/list.min" && cp "$T/list.min" "$LIST"
expect_code 0 "bootstrap from a one-line release list" gg "$R_DECK"
contains "$GI/release.env" "^TAG=v0.2.0$" "one-line list: release picked"
# the highest version wins whatever the list order; a stable release beats a newer pre-release; drafts and tags
# that aren't vX... never count (v0.1.9 has no downloads, so picking it would fail)
old='{ "tag_name": "v0.1.9", "draft": false, "prerelease": true, "assets": [] },'
mklist false true "$old"
expect_code 0 "the highest pre-release, not the first listed" gg "$R_DECK"
contains "$GI/release.env" "^TAG=v0.2.0$" "v0.2.0 over v0.1.9"
mklist false false '{ "tag_name": "v0.3.0-rc.1", "draft": false, "prerelease": true, "assets": [] },'
expect_code 0 "a stable release beats a newer pre-release" gg "$R_DECK"
contains "$GI/release.env" "^TAG=v0.2.0$" "stable picked"
lacks "$T/out" "pre-release" "and not called a pre-release"
mklist false false '{ "tag_name": "v0.9.0", "draft": true, "prerelease": false, "assets": [] }, { "tag_name": "version-7", "draft": false, "prerelease": false, "assets": [] },'
expect_code 0 "drafts and other tags are skipped" gg "$R_DECK"
contains "$GI/release.env" "^TAG=v0.2.0$" "v0.2.0, not the draft"
# no app release in the list at all: the installed copy opens (the app menu entry keeps working) ...
printf '[\n%s\n]\n' "$(cat "$SRV/latest.json")" >"$LIST"
: >"$T/launch.log"
expect_code 0 "no app release listed: the installed copy is used" gg "$R_DECK"
contains "$T/out" "GitHub lists no GameCove release; using the copy downloaded before" "says so"
contains "$T/launch.log" "prefetch-photo" "the installed app is what runs"
# ... and so does a rate limit or a 5xx; nothing is downloaded
for st in 403 500; do
	echo "$st" >"$T/api-status"
	expect_code 0 "HTTP $st with an installed copy" gg "$R_DECK"
	contains "$T/out" "GitHub answered HTTP $st; using the copy downloaded before" "HTTP $st: says what GitHub answered"
	lacks "$T/curl.log" "example.test/dl/" "HTTP $st: nothing downloaded"
done
rm -f "$T/api-status"
mklist false true
mv "$SRV/tag.json" "$SRV/tag.off"
: >"$T/notify.log"
expect_code 1 "a given tag that doesn't exist" gg "$R_DECK" GAMECOVE_TAG=v9.9.9
lacks "$T/curl.log" "per_page" "a given tag is never replaced by another release"
contains "$T/out" "no GameCove release v9.9.9" "says the tag doesn't exist"
contains "$T/notify.log" "no GameCove release v9.9.9" "an error away from a terminal is also a desktop notification"
mv "$SRV/tag.off" "$SRV/tag.json"
# without an installed copy the same failures stop with the reason (review M7: an error never installs anything)
rm -rf "$T/gghome"
mkdir -p "$T/gghome"
for st in 403 500; do
	echo "$st" >"$T/api-status"
	expect_code 1 "bootstrap stops on HTTP $st" gg "$R_DECK"
	lacks "$T/curl.log" "example.test/dl/" "HTTP $st: nothing downloaded"
	contains "$T/out" "HTTP $st" "says what GitHub answered"
done
rm -f "$T/api-status"
printf '[\n%s\n]\n' "$(cat "$SRV/latest.json")" >"$LIST"
expect_code 1 "no app release listed and nothing installed" gg "$R_DECK"
contains "$T/out" "no GameCove release found" "says why"
mklist false false
# --help also when piped into a shell (there is no file to read then)
if sh -s -- --help <"$GG" 2>/dev/null | grep -q -- "--no-launch"; then ok; else bad "get-gamecove.sh --help prints nothing when piped"; fi
rm -rf "$T/gghome"
mkdir -p "$T/gghome"
expect_code 1 "bootstrap refuses a bad checksum" gg "$R_BAZ" SHA256SUM="$GB/badsum"
contains "$T/out" "doesn't match its checksum" "checksum error said"
if [ ! -e "$GI/app" ] && [ ! -e "$GI/release.env" ]; then ok; else bad "nothing installed after a bad checksum"; fi
mv "$SRV/SHA256SUMS" "$SRV/SHA256SUMS.off"
expect_code 1 "bootstrap refuses without SHA256SUMS" gg "$R_BAZ"
mv "$SRV/SHA256SUMS.off" "$SRV/SHA256SUMS"
cp "$SRV/SHA256SUMS" "$SRV/SUMS.keep"
grep -v "x86_64.rpm" "$SRV/SUMS.keep" >"$SRV/SHA256SUMS"
expect_code 1 "bootstrap refuses a file missing from SHA256SUMS" gg "$R_BAZ"
mv "$SRV/SUMS.keep" "$SRV/SHA256SUMS"
expect_code 1 "bootstrap needs x86_64" gg "$R_BAZ" GAMECOVE_ARCH=aarch64
# review S3-3: SHA256SUMS must carry a Sigstore signature from this repository's release workflow
rm -rf "$T/gghome"
mkdir -p "$T/gghome"
expect_code 0 "signed release accepted" gg "$R_BAZ"
contains "$T/cosign.log" "^verify-blob --bundle .*SHA256SUMS.sigstore.json --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-identity-regexp " "cosign checks the bundle and the GitHub OIDC issuer"
contains "$T/cosign.log" 'IHulkSmashI/GameCove/\\.github/workflows/release\\.yml@refs/tags/v0\\.2\\.0\$ ' "identity: this repo's release workflow for exactly this tag (review M5)"
contains "$GI/release.env" "^SIGNATURE=verified$" "recorded for the installer"
rm -rf "$T/gghome"
mkdir -p "$T/gghome"
touch "$T/cosign-fail"
expect_code 1 "a bad signature is refused" gg "$R_BAZ"
contains "$T/out" "signature doesn't check out" "said why"
if [ ! -e "$GI/app" ] && [ ! -e "$GI/release.env" ]; then ok; else bad "nothing installed after a bad signature"; fi
rm -f "$T/cosign-fail"
mv "$SRV/SHA256SUMS.sigstore.json" "$SRV/bundle.off"
cp "$SRV/tag.json" "$SRV/tag.keep"
grep -v "sigstore.json" "$SRV/tag.keep" >"$SRV/tag.json"
mklist false false
expect_code 1 "an unsigned release is refused" gg "$R_BAZ"
contains "$T/out" "has no signature" "said why"
expect_code 0 "unsigned accepted only when asked" gg "$R_BAZ" GAMECOVE_ALLOW_UNSIGNED=1
contains "$GI/release.env" "^SIGNATURE=unsigned$" "and recorded as unsigned"
mv "$SRV/bundle.off" "$SRV/SHA256SUMS.sigstore.json"
mv "$SRV/tag.keep" "$SRV/tag.json"
mklist false false
# no cosign anywhere: the pinned release is downloaded and its sha256 checked (a fake one here: refused)
printf 'not cosign\n' >"$SRV/cosign-linux-amd64"
mkdir -p "$T/ggbin2"
cp "$GB/curl" "$T/ggbin2/curl"
if command -v cosign >/dev/null 2>&1; then
	echo "note: a real cosign is installed here, skipped the pinned-download test" >&2
else
	expect_code 1 "a cosign download that isn't the pinned one is refused" env PATH="$T/ggbin2:/usr/bin:/bin" GAMECOVE_HOME="$T/gghome" \
		GAMECOVE_ROOT="$R_BAZ" GAMECOVE_ARCH=x86_64 GAMECOVE_API=https://api.example.test sh "$GG" --no-launch
	contains "$T/out" "doesn't match its pinned sha256" "said why"
	contains "$T/curl.log" "sigstore/cosign/releases/download/v2.5.3/cosign-linux-amd64" "the pinned cosign release"
fi
expect_code 0 "bootstrap again" gg "$R_BAZ"
# review problem 9: "latest" never installs an older release over a newer one; --tag (GAMECOVE_TAG) may
cp "$GI/release.env" "$T/release.env.keep"
sed 's/^TAG=.*/TAG=v0.10.0/' "$T/release.env.keep" >"$GI/release.env"
: >"$T/launch.log"
expect_code 0 "an older newest release isn't installed over a newer one; the installed copy opens" gg "$R_BAZ"
contains "$T/out" "older than the installed v0.10.0" "said why"
lacks "$T/curl.log" "example.test/dl/" "nothing of the older release is downloaded"
contains "$T/launch.log" "prefetch-photo" "the installed copy runs instead"
contains "$GI/release.env" "^TAG=v0.10.0$" "the newer install is left alone"
expect_code 0 "an older release on purpose (--tag)" gg "$R_BAZ" GAMECOVE_TAG=v0.2.0
sed 's/^TAG=.*/TAG=v0.2.0-rc.1/' "$T/release.env.keep" >"$GI/release.env"
expect_code 0 "the final release over its own pre-release" gg "$R_BAZ"
contains "$GI/release.env" "^TAG=v0.2.0$" "updated"
sed -n '/^version_lt() {$/,/^}$/p' "$GG" >"$T/version_lt.sh"
for pair in "v0.2.0 v0.10.0 0" "v0.10.0 v0.2.0 1" "v1.2.0 v1.2.0 1" "v1.2.0-rc.1 v1.2.0 0" "v1.2.0 v1.2.0-rc.1 1" \
	"v1.2.0-rc.1 v1.2.0-rc.2 0" "v1.2 v1.2.1 0" "vX v1.0.0 1" \
	"v1.2.0-rc.9 v1.2.0-rc.10 0" "v1.2.0-rc.10 v1.2.0-rc.9 1" "v1.2.0-rc.2 v1.2.0-rc.2 1" "v1.2.0-alpha v1.2.0-beta 0" \
	"v1.2.0-1 v1.2.0-alpha 0" "v1.2.0-alpha v1.2.0-1 1" "v1.2.0-rc v1.2.0-rc.1 0"; do
	set -- $pair
	got="$(sh -c '. "$1"; version_lt "$2" "$3"; echo $?' sh "$T/version_lt.sh" "$1" "$2" 2>/dev/null)"
	[ "$got" = "$3" ] && ok || bad "version_lt $1 $2: $got, want $3"
done
touch "$T/offline"
: >"$T/launch.log"
expect_code 0 "bootstrap offline uses the cached app" env PATH="$GB:$PATH" GAMECOVE_HOME="$T/gghome" GAMECOVE_ROOT="$R_BAZ" \
	GAMECOVE_ARCH=x86_64 DISPLAY=:9 sh "$GG"
sleep 0.3
contains "$T/launch.log" "^app -- --installer$" "installer launched with user args"
lacks "$T/launch.log" "prefetch-photo" "the installer fetches the photo itself when it opens"
rm -f "$T/offline"
rm -rf "$T/gghome"
expect_code 1 "bootstrap offline without a cache" env PATH="$GB:$PATH" GAMECOVE_HOME="$T/gghome" GAMECOVE_ROOT="$R_BAZ" \
	GAMECOVE_ARCH=x86_64 CURL=false sh "$GG" --no-launch

# ------------------------------------------------------- sysext tree (offline)
APP="$T/app"
SS="$T/gs-session"
mkdir -p "$APP" "$SS/usr/bin" "$SS/usr/share/gamescope-session-plus" "$SS/usr/lib/systemd/user" \
	"$SS/usr/share/gamescope/scripts/50-custom"
echo bin >"$APP/gamecove.x86_64"
echo pck >"$APP/gamecove.pck"
# upstream gamescope-session's usr/ at the pinned commit, file for file
printf '#!/bin/sh\n' >"$SS/usr/bin/gamescope-session-plus"
chmod +x "$SS/usr/bin/gamescope-session-plus"
printf '#!/bin/sh\n' >"$SS/usr/bin/export-gpu"
printf '#!/bin/bash\n' >"$SS/usr/share/gamescope-session-plus/gamescope-session-plus"
echo quirks >"$SS/usr/share/gamescope-session-plus/device-quirks"
printf '[Unit]\nPartOf=gamescope-session.target\n' >"$SS/usr/lib/systemd/user/gamescope-session-plus@.service"
printf '[Unit]\nDescription=Gamescope Session\n' >"$SS/usr/lib/systemd/user/gamescope-session.target"
echo lua >"$SS/usr/share/gamescope/scripts/50-custom/50-disable-explicit-sync.lua"
echo MIT >"$SS/LICENSE"
# review M6: the session files are checked against pinned sha256s; the fake tree gets its own list
(cd "$SS" && sha256sum usr/bin/gamescope-session-plus usr/share/gamescope-session-plus/gamescope-session-plus \
	usr/share/gamescope-session-plus/device-quirks usr/lib/systemd/user/gamescope-session-plus@.service LICENSE) >"$T/gs.sums"
expect_code 1 "sysext refuses a session tree that doesn't match the pinned sha256s" sh "$REPO/packaging/sysext/build-sysext.sh" \
	--app "$APP" --session-src "$SS" --out "$T/dist-pinned" --tree-only
contains "$T/out" "doesn't match its pinned sha256" "said which file"
if [ ! -e "$T/dist-pinned/gamecove" ]; then ok; else bad "no tree from an unverified session"; fi
cp "$SS/usr/share/gamescope-session-plus/device-quirks" "$T/quirks.keep"
echo tampered >"$SS/usr/share/gamescope-session-plus/device-quirks"
expect_code 1 "sysext refuses a changed session file" env SESSION_SUMS="$T/gs.sums" sh "$REPO/packaging/sysext/build-sysext.sh" \
	--app "$APP" --session-src "$SS" --out "$T/dist-bad" --tree-only
contains "$T/out" "device-quirks doesn't match its pinned sha256" "names the changed file"
cp "$T/quirks.keep" "$SS/usr/share/gamescope-session-plus/device-quirks"
grep -v " LICENSE$" "$T/gs.sums" >"$T/gs-nolic.sums"
expect_code 1 "sysext refuses a list without LICENSE" env SESSION_SUMS="$T/gs-nolic.sums" sh "$REPO/packaging/sysext/build-sysext.sh" \
	--app "$APP" --session-src "$SS" --out "$T/dist-nolic" --tree-only
# the shipped list: exactly the files build-sysext.sh takes, plus LICENSE, each with a sha256
PIN="$REPO/packaging/sysext/gamescope-session.sha256"
want="LICENSE usr/bin/gamescope-session-plus usr/lib/systemd/user/gamescope-session-plus@.service usr/share/gamescope-session-plus/device-quirks usr/share/gamescope-session-plus/gamescope-session-plus"
got="$(awk '$1 !~ /^#/ && NF == 2 && $1 ~ /^[0-9a-f]+$/ && length($1) == 64 { print $2 }' "$PIN" | sort | tr '\n' ' ' | sed 's/ $//')"
[ "$got" = "$want" ] && ok || bad "gamescope-session.sha256 must pin exactly the session files and LICENSE ($got)"
grep -q "^# 08e65a62ed3d7acc6ae17db637091d402a55ae2a\| 08e65a62ed3d7acc6ae17db637091d402a55ae2a " "$PIN" && \
	grep -q "SESSION_COMMIT:-08e65a62ed3d7acc6ae17db637091d402a55ae2a" "$REPO/packaging/sysext/build-sysext.sh" && ok || bad "gamescope-session.sha256 must name the commit build-sysext.sh pins"
# fetched by git at the commit (a local repository here, never the network), and checked
GR="$T/gs-git"
git init -q "$GR" && cp -a "$SS/." "$GR/" && git -C "$GR" add -A && \
	git -C "$GR" -c user.name=t -c user.email=t@example.invalid commit -q -m session && ok || bad "fake session repository"
gc="$(git -C "$GR" rev-parse HEAD)"
expect_code 0 "sysext fetches the session by git at the commit" env SESSION_REPO="file://$GR" SESSION_COMMIT="$gc" SESSION_SUMS="$T/gs.sums" \
	sh "$REPO/packaging/sysext/build-sysext.sh" --app "$APP" --out "$T/dist-git" --tree-only
if [ -x "$T/dist-git/gamecove/usr/bin/gamescope-session-plus" ]; then ok; else bad "session files from the git fetch"; fi
expect_code 1 "sysext refuses a commit the repository doesn't have" env SESSION_REPO="file://$GR" SESSION_COMMIT="0123456789abcdef0123456789abcdef01234567" \
	SESSION_SUMS="$T/gs.sums" sh "$REPO/packaging/sysext/build-sysext.sh" --app "$APP" --out "$T/dist-git2" --tree-only
expect_code 0 "sysext tree" env SESSION_SUMS="$T/gs.sums" sh "$REPO/packaging/sysext/build-sysext.sh" --app "$APP" --session-src "$SS" --out "$T/dist" --tree-only
TREE="$T/dist/gamecove"
for f in usr/bin/gamescope-session-plus usr/bin/gamecove-session-select usr/bin/gamecove-selftest \
	usr/lib/gamecove/gamecove.x86_64 usr/lib/gamecove/gamecove.pck \
	usr/libexec/gamecove/gamecove-fix usr/libexec/gamecove/gamecove-fix-set usr/libexec/gamecove/gamecove-session-client \
	usr/libexec/gamecove/gamecove-apply-choices usr/libexec/gamecove/get-gamecove.sh \
	usr/share/applications/io.github.ihulksmashi.GameCoveInstaller.desktop \
	usr/share/licenses/gamecove/LICENSE usr/share/licenses/gamecove/GPL-2.0-only.txt usr/share/licenses/gamecove/LICENSE.ClawLab-MIT \
	usr/share/gamescope-session-plus/sessions.d/gamecove usr/share/wayland-sessions/gamecove.desktop \
	usr/share/polkit-1/actions/io.github.ihulksmashi.gamecove.policy \
	usr/lib/systemd/user/gamescope-session-plus@gamecove.service.d/10-gamecove.conf \
	usr/lib/gamecove/session/gamecove-autologin-guard usr/lib/gamecove/session/gamecove-autologin-guard.service; do
	if [ -e "$TREE/$f" ]; then ok; else bad "sysext tree missing $f"; fi
done
contains "$TREE/usr/lib/extension-release.d/extension-release.gamecove" "^ID=_any$" "extension-release ID"
# review H10: a sysext overlays /usr, so it must never hold a file SteamOS already has. These exist on
# SteamOS 3.10 (gamescope 3.16.30, owned by the gamescope package; checked on a ROG Ally):
for f in usr/lib/systemd/user/gamescope-session.target usr/share/wayland-sessions/gamescope-wayland.desktop \
	usr/lib/systemd/user/gamescope-session.service usr/lib/systemd/user/gamescope-session.service.d \
	usr/lib/systemd/user/gamescope-session.service.wants usr/lib/systemd/user/gamescope-mangoapp.service \
	usr/lib/systemd/user/ibus-gamescope.service usr/lib/systemd/user/xdg-desktop-portal-gamescope.service \
	usr/share/gamescope usr/bin/export-gpu; do
	if [ ! -e "$TREE/$f" ]; then ok; else bad "sysext would shadow SteamOS's $f"; fi
done
# ...and nothing outside the allow-list: GameCove's own folders, licences, and the named files
(cd "$TREE" && find . \( -type f -o -type l \) | sed 's|^\./||' | sort) >"$T/sysext-files"
while IFS= read -r f; do
	case "$f" in
	usr/lib/gamecove/* | usr/libexec/gamecove/* | usr/share/licenses/*) ;;
	usr/bin/gamescope-session-plus | usr/share/gamescope-session-plus/gamescope-session-plus | \
		usr/share/gamescope-session-plus/device-quirks | usr/lib/systemd/user/gamescope-session-plus@.service) ;;
	usr/bin/gamecove-session-select | usr/bin/gamecove-selftest | usr/share/gamescope-session-plus/sessions.d/gamecove | \
		usr/share/wayland-sessions/gamecove.desktop | usr/share/applications/io.github.ihulksmashi.GameCoveInstaller.desktop | \
		usr/share/polkit-1/actions/io.github.ihulksmashi.gamecove.policy | \
		usr/lib/systemd/user/gamescope-session-plus@gamecove.service.d/10-gamecove.conf | \
		usr/lib/extension-release.d/extension-release.gamecove) ;;
	*) echo "$f" >>"$T/sysext-extra" ;;
	esac
done <"$T/sysext-files"
if [ ! -s "$T/sysext-extra" ]; then ok; else bad "sysext holds files outside the allow-list: $(cat "$T/sysext-extra")"; fi
for f in usr/share/gamescope-session-plus/gamescope-session-plus usr/share/gamescope-session-plus/device-quirks \
	usr/lib/systemd/user/gamescope-session-plus@.service; do
	if [ -e "$TREE/$f" ]; then ok; else bad "sysext tree missing upstream $f"; fi
done
if [ -x "$TREE/usr/bin/gamescope-session-plus" ]; then ok; else bad "gamescope-session-plus must stay executable"; fi
if [ ! -e "$TREE/etc" ] && [ ! -e "$TREE/var" ]; then ok; else bad "sysext must only hold /usr"; fi
if [ -z "$(find "$TREE" -name test.sh -o -type d -name tests)" ]; then ok; else bad "fix tests must not ship"; fi
if [ -f "$TREE/usr/lib/gamecove/fixes/lib/claw8ex-common.sh" ]; then ok; else bad "shared fix code must ship"; fi
if [ -x "$TREE/usr/libexec/gamecove/gamecove-fix-set" ]; then ok; else bad "set entry point must be executable"; fi

# ------------------------------------------------------------------ polkit XML
POL="$REPO/packaging/polkit/io.github.ihulksmashi.gamecove.policy"
if python3 -c "import sys, xml.dom.minidom; xml.dom.minidom.parse(sys.argv[1])" "$POL" 2>"$T/out"; then ok; else bad "policy XML: $(cat "$T/out")"; fi
# Two actions: no password only for the set entry point; the full helper always asks.
python3 -I - "$POL" >"$T/out" 2>&1 <<'PY'
import sys, xml.dom.minidom
doc = xml.dom.minidom.parse(sys.argv[1])
acts = {}
for a in doc.getElementsByTagName("action"):
    d = a.getElementsByTagName("defaults")[0]
    def get(t):
        return d.getElementsByTagName(t)[0].firstChild.data.strip()
    paths = [n.firstChild.data.strip() for n in a.getElementsByTagName("annotate")
             if n.getAttribute("key") == "org.freedesktop.policykit.exec.path"]
    acts[a.getAttribute("id")] = (get("allow_any"), get("allow_inactive"), get("allow_active"), paths)
want = {
    # review S3-2: the prompt-free action is for the active local session only
    "io.github.ihulksmashi.gamecove.fix-set": ("no", "no", "yes", ["/usr/libexec/gamecove/gamecove-fix-set"]),
    "io.github.ihulksmashi.gamecove.fix": ("auth_admin", "auth_admin", "auth_admin_keep", ["/usr/libexec/gamecove/gamecove-fix"]),
}
assert acts == want, acts
PY
code=$?
if [ "$code" -eq 0 ]; then ok; else bad "policy actions: $(cat "$T/out")"; fi
if [ "$(grep -c "<allow_active>yes</allow_active>" "$POL")" -eq 1 ]; then ok; else bad "only one action may skip the password"; fi

# ------------------------------------------------------------------ RPM spec
SPEC="$REPO/packaging/rpm/gamecove.spec"
contains "$SPEC" "^License:        GPL-3.0-or-later AND GPL-3.0-only AND GPL-2.0-only AND GPL-2.0-or-later AND MIT AND OFL-1.1 AND CC0-1.0 AND " "spec License tag (GameCove, the bundled MIT / OFL / CC0 parts, review L36)"
contains "$SPEC" "packaging/libexec/gamecove-fix-set" "spec installs the set entry point"
contains "$SPEC" "^%{_libexecdir}/gamecove/gamecove-fix-set$" "spec lists the set entry point"
contains "$SPEC" "build-bpf.sh" "spec builds the gyro program"
contains "$SPEC" "^%{_libexecdir}/gamecove/gamecove-apply-choices$" "spec lists the installer's apply helper"
contains "$SPEC" "^%{_libexecdir}/gamecove/get-gamecove.sh$" "spec lists the bootstrap"
contains "$SPEC" "done < packaging/licenses.list" "spec ships every licence text (GPL-2.0, OFL, Godot, ...)"
uhb_spec="$(sed -n 's/^%global uhb_commit //p' "$SPEC")"
uhb_script="$(sed -n 's/.*UHB_PIN:-\([0-9a-f]*\)}.*/\1/p' "$REPO/fixes/claw8ex-gyro/bpf/build-bpf.sh")"
if [ -n "$uhb_spec" ] && [ "$uhb_spec" = "$uhb_script" ]; then ok; else bad "udev-hid-bpf pin differs: spec '$uhb_spec', build-bpf.sh '$uhb_script'"; fi
# GameCove itself is GPL-3.0-or-later; GPL-3.0-only may appear only for the bundled Heroic icon.
if grep -h "GPL-3.0-only" "$REPO/README.md" "$REPO/CREDITS.md" | grep -v -e "Heroic" -e "Bottles" | grep -q .; then bad "GPL-3.0-only mentioned for something other than the Heroic or Bottles icon; GameCove is GPL-3.0-or-later"; else ok; fi
contains "$SPEC" "^License:.*GPL-3.0-or-later" "spec licence is GPL-3.0-or-later"
# %install holds commands only; a %files-style path line there breaks rpmbuild
if awk '/^%install/{f=1;next} /^%files/{f=0} f && /^%\{_/' "$SPEC" | grep -q .; then bad "spec: file-list lines inside %install: $(awk '/^%install/{f=1;next} /^%files/{f=0} f && /^%\{_/' "$SPEC" | head -3)"; else ok; fi
# every helper the spec installs is listed in %files
for h in $(sed -n 's|^install -Dpm0755 packaging/libexec/\([^ ]*\) .*|\1|p' "$SPEC"); do
	contains "$SPEC" "^%{_libexecdir}/gamecove/$h$" "spec %files lists $h"
done

# ------------------------------------------- devices.json "fixes" = fix folders
if python3 -I - "$REPO" >"$T/out" 2>&1 <<'PY'
import json, os, sys
repo = sys.argv[1]
bad = []
for d in json.load(open(os.path.join(repo, "app/data/devices.json")))["devices"]:
    for f in d.get("fixes", []):
        if not os.path.isfile(os.path.join(repo, "fixes", f, "fix.sh")):
            bad.append("%s: %s" % (d["id"], f))
assert not bad, bad
PY
then ok; else bad "devices.json fixes must name folders in fixes/: $(cat "$T/out")"; fi

# ------------------------- fixes/lib/handhelds.txt is generated from devices.json
if python3 -I "$REPO/tools/fixes/gen_handhelds.py" --check >"$T/out" 2>&1; then ok; else bad "$(cat "$T/out")"; fi
# every fixes/<id>/ has a valid fix.json (metadata, undo, probe, tests, lifecycle rule, watch), and
# app/data/fixes.json, the README table and docs/FIXES.md's catalogue are what they build (docs/FIXES.md)
if python3 -I "$REPO/tools/fixes/build.py" --check >"$T/out" 2>&1; then ok; else bad "fix definitions: $(cat "$T/out")"; fi
for d in "$REPO"/fixes/*/; do
	n="$(basename "$d")"
	[ -f "$d/fix.sh" ] || continue
	if [ -f "$d/fix.json" ]; then ok; else bad "fixes/$n has no fix.json"; fi
done
# the nightly audit, dry: two nights from recorded answers, the signing job's check, and the issues it would file
if python3 -I "$REPO/tools/fixes/make_fixtures.py" "$T/audit-n1" >"$T/out" 2>&1 \
	&& python3 -I "$REPO/tools/fixes/audit.py" --fixtures "$T/audit-n1" --out "$T/audit-d1" --date 2026-11-09 --serial 1 >>"$T/out" 2>&1 \
	&& python3 -I "$REPO/tools/fixes/make_fixtures.py" "$T/audit-n2" --night 2 >>"$T/out" 2>&1 \
	&& python3 -I "$REPO/tools/fixes/audit.py" --fixtures "$T/audit-n2" --out "$T/audit-d2" --previous "$T/audit-d1/audit-state.json" --date 2026-11-10 --serial 2 >>"$T/out" 2>&1 \
	&& python3 -I "$REPO/tools/fixes/check_dist.py" "$T/audit-d2" >>"$T/out" 2>&1; then ok; else bad "fix audit dry run: $(cat "$T/out")"; fi
python3 -I "$REPO/tools/fixes/file_issues.py" "$T/audit-d2/issues.json" --dry-run >"$T/out" 2>&1 || true
contains "$T/out" "issue create --title Fix audit: onexfly-touch --label fix-audit" "the audit files one issue per fix with a change"
contains "$T/out" "issue create --title Fix audit summary --label fix-audit" "and a summary"
python3 -I "$REPO/tools/fixes/file_issues.py" "$T/audit-d1/issues.json" --dry-run >"$T/out" 2>&1 || true
contains "$T/out" "nothing to report" "a night without changes files nothing"
# the fixes release is built and signed in IHulkSmashI/GameCove-data (its tests/check_workflows.py); here only the issues
[ ! -e "$REPO/.github/workflows/fixes.yml" ] && ok || bad "fixes.yml publishes data: it belongs in IHulkSmashI/GameCove-data"
contains "$REPO/.github/workflows/fix-audit.yml" "cosign verify-blob --bundle dist/issues.json.sigstore.json" "fix-audit.yml files issues only from a verified issues.json"
contains "$REPO/app/scripts/device/fix_data.gd" "const URL := DataRepo.FIXES_URL" "fix_data.gd downloads from the data repo"
contains "$REPO/app/scripts/device/fix_data.gd" "const SIGNER_IDENTITY := DataRepo.FIXES_SIGNER" "and pins its fixes.yml"
# ------------------- traits, fix / quirk / matrix selectors (tools/traits/traits.py)
if python3 -I "$REPO/tools/traits/traits.py" check >"$T/out" 2>&1; then ok; else bad "traits: $(cat "$T/out")"; fi
python3 -I "$REPO/tools/traits/traits.py" trait controller:asus-ally-x >"$T/out" 2>&1
contains "$T/out" "asus-rog-xbox-ally-x20" "trait report lists every model sharing the controller"
python3 -I "$REPO/tools/traits/traits.py" model msi-claw-8-ai-plus >"$T/out" 2>&1
contains "$T/out" "claw8ex-vrr  *auto  *because panel csw-pn8007qb1-2" "model report says why a fix applies"
contains "$REPO/fixes/lib/handhelds.txt" "^msi-claw-8-ex	board_name=MS-1T91$" "Claw 8 EX in the handheld list"
lacks "$REPO/fixes/lib/handhelds.txt" "^steam-deck" "Steam Deck uses steamos-manager, not these fixes"

# ------------------------------- fan drivers: power.gd, fan fix and allowlist agree
if python3 -I - "$REPO" >"$T/out" 2>&1 <<'PY'
import json, os, re, sys
repo = sys.argv[1]
gd = open(os.path.join(repo, "app/scripts/device/power.gd")).read()
fix = open(os.path.join(repo, "fixes/fan/fix.sh")).read()
fixset = open(os.path.join(repo, "packaging/libexec/gamecove-fix-set")).read()
block = gd[gd.index("const FAN_DRIVERS"):gd.index("const CHARGE_STATE_DIR")]
drivers = re.findall(r'^\t"([a-z_]+)": \{', block, re.M)
bad = []
for d in drivers:
    names = re.search(r'"%s": \{"hwmon": \[([^\]]*)\]' % d, block).group(1)
    first = re.findall(r'"([a-z_]+)"', names)[0]
    if first not in fix and not (first.startswith("zotac") and "zotac_*" in fix):
        bad.append("fix.sh lacks driver " + first)
for mode in set(re.findall(r'"(quiet|auto|max)"', block)):
    if "fan:" + mode not in fixset:
        bad.append("gamecove-fix-set does not allow fan " + mode)
rows = json.load(open(os.path.join(repo, "app/data/devices.json")))["devices"]
for r in rows:
    if r.get("fan_via") == "fix" and r.get("fan") not in drivers:
        bad.append("%s: fan_via fix but power.gd can't drive %s" % (r["id"], r.get("fan")))
    if r.get("charge_limit") and r.get("charge_limit_via") not in ("steamos-manager", "fix", "sysfs"):
        bad.append("%s: charge_limit_via %s" % (r["id"], r.get("charge_limit_via")))
assert not bad, bad
PY
then ok; else bad "fan drivers out of step: $(cat "$T/out")"; fi

# ------------------------------------- workflows and community templates parse
if python3 -c "import yaml" 2>/dev/null; then
	if python3 -I - "$REPO" >"$T/out" 2>&1 <<'PY'
import glob, json, os, sys, yaml
repo = sys.argv[1]
gh = os.path.join(repo, ".github")
bad = []
for f in sorted(glob.glob(os.path.join(gh, "**", "*.yml"), recursive=True)):
    try:
        doc = yaml.safe_load(open(f, encoding="utf-8"))
    except yaml.YAMLError as e:
        bad.append("%s: %s" % (f, e))
        continue
    rel = os.path.relpath(f, gh)
    if rel.startswith("ISSUE_TEMPLATE/") and not rel.endswith("config.yml"):
        if not (isinstance(doc, dict) and doc.get("name") and doc.get("description") and isinstance(doc.get("body"), list)):
            bad.append(rel + ": issue forms need name, description and body")
    if rel.startswith("DISCUSSION_TEMPLATE/") and not (isinstance(doc, dict) and isinstance(doc.get("body"), list)):
        bad.append(rel + ": discussion forms need a body")
    if isinstance(doc, dict) and isinstance(doc.get("body"), list):
        ids = [b.get("id") for b in doc["body"] if b.get("id")]
        if len(ids) != len(set(ids)):
            bad.append(rel + ": duplicate ids")
makers = sorted({d["maker"] for d in json.load(open(os.path.join(repo, "app/data/devices.json")))["devices"]})
for name in ("bug_report.yml", "game_report.yml"):   # the game report form (one per game) too
    form = yaml.safe_load(open(os.path.join(gh, "ISSUE_TEMPLATE", name), encoding="utf-8"))
    opts = [b for b in form["body"] if b.get("id") == "maker"][0]["attributes"]["options"]
    if opts != makers + ["Other"]:
        bad.append("%s makers %s != devices.json makers %s + Other" % (name, opts, makers))
game = yaml.safe_load(open(os.path.join(gh, "ISSUE_TEMPLATE", "game_report.yml"), encoding="utf-8"))
for need in ("game", "store", "model", "os", "upscaler", "fg", "verdict"):
    if need not in [b.get("id") for b in game["body"]]:
        bad.append("game_report.yml has no " + need)
assert not bad, bad
PY
	then ok; else bad "YAML under .github: $(cat "$T/out")"; fi
else
	echo "note: python3 yaml module missing, skipped YAML checks" >&2
fi

# ------------------------------------------------------------------ shellcheck
SHELLCHECK="$(command -v shellcheck || true)"
if [ -z "$SHELLCHECK" ]; then
	bad "shellcheck not found (pip install shellcheck-py)"
else
	for f in "$REPO/packaging/libexec/gamecove-fix" "$REPO/packaging/libexec/gamecove-fix-set" "$REPO/packaging/install.sh" \
		"$REPO/packaging/sysext/build-sysext.sh" "$REPO/packaging/tests/run.sh" \
		"$REPO/session/gamecove-session-client" "$REPO/session/gamecove-session-select" \
		"$REPO/packaging/get-gamecove.sh" "$REPO/packaging/libexec/gamecove-apply-choices" \
		"$REPO/packaging/libexec/reaper" \
		"$REPO/packaging/bin/gamecove-selftest" "$REPO/packaging/tests/selftest.sh" "$REPO/packaging/tests/session.sh" "$REPO/session/gamecove-autologin-guard" "$REPO/packaging/tests/wrapper.sh"; do
		if "$SHELLCHECK" -S warning -s sh "$f" >"$T/out" 2>&1; then ok; else bad "shellcheck $f: $(cat "$T/out")"; fi
	done
	f="$REPO/session/gamescope-session-plus/sessions.d/gamecove"
	if "$SHELLCHECK" -S warning -s bash "$f" >"$T/out" 2>&1; then ok; else bad "shellcheck $f: $(cat "$T/out")"; fi
	for f in "$REPO"/fixes/*/fix.sh "$REPO"/fixes/*/test.sh "$REPO"/fixes/*/tests/*.sh "$REPO"/fixes/lib/*.sh \
		"$REPO"/fixes/*/bpf/*.sh "$REPO"/fixes/*/*-hook.sh; do
		[ -f "$f" ] || continue
		# -x from the repo root so "# shellcheck source=fixes/..." paths resolve
		if (cd "$REPO" && "$SHELLCHECK" -S warning -x -s sh "$f") >"$T/out" 2>&1; then ok; else bad "shellcheck $f: $(cat "$T/out")"; fi
	done
fi

# ------------------------------------------------------- reaper (stream app-id wrapper)
REAPER="$REPO/packaging/libexec/reaper"
expect_code 64 "reaper without a command" sh "$REAPER" SteamLaunch AppId=5
expect_code 3 "reaper passes the exit status" "$REAPER" SteamLaunch AppId=5 -- sh -c 'exit 3'
"$REAPER" SteamLaunch AppId=1234 -- sh -c 'cat /proc/$PPID/comm; tr "\0" " " </proc/$PPID/cmdline' >"$T/reaper" 2>&1
contains "$T/reaper" "^reaper$" "gamescope sees a parent named reaper"
contains "$T/reaper" "SteamLaunch AppId=1234 --" "gamescope reads SteamLaunch AppId= from its command line"
"$REAPER" SteamLaunch AppId=1 -- sh -c 'trap "echo got-term; exit 0" TERM; while :; do sleep 0.1; done' >"$T/reaper2" 2>&1 &
rp=$!
sleep 0.5
kill -TERM "$rp"
wait "$rp"
contains "$T/reaper2" "got-term" "reaper passes TERM on to the program"

# ------------------------------------------------------- gamecove-run (launch wrapper)
if sh "$REPO/packaging/tests/wrapper.sh" >"$T/out" 2>&1; then ok; else bad "wrapper.sh: $(grep FAIL "$T/out" | head -20)"; fi
if "$SHELLCHECK" -S warning -s bash "$REPO/packaging/libexec/gamecove-run" >"$T/out" 2>&1; then ok; else bad "shellcheck gamecove-run: $(cat "$T/out")"; fi

# ------------------------------------------------------- gamecove-selftest (fake root and commands)
if sh "$REPO/packaging/tests/selftest.sh" >"$T/out" 2>&1; then ok; else bad "selftest: $(tail -20 "$T/out")"; fi

# ------------------------------------------------------- release, licences, supply chain, privacy (packaging/tests/release.sh)
if sh "$REPO/packaging/tests/release.sh" >"$T/out" 2>&1; then ok; else bad "release.sh: $(grep FAIL "$T/out" | head -30)"; fi
if [ -n "$SHELLCHECK" ] && "$SHELLCHECK" -S warning -s sh "$REPO/packaging/tests/release.sh" >"$T/out" 2>&1; then ok; else bad "shellcheck release.sh: $(cat "$T/out")"; fi

# ------------------------------------------------------- raw assets the app reads with FileAccess must ship raw
for f in "$REPO"/app/assets/brand/*.svg "$REPO"/app/assets/device_photos/*.webp; do
	[ -f "$f" ] || continue
	grep -q 'importer="keep"' "$f.import" 2>/dev/null && ok || bad "$f.import must use importer=keep (the app reads the raw file; a texture import leaves it out of exports)"
done

# ------------------------------------------------------- release workflow signs what the installer verifies
W="$REPO/.github/workflows/release.yml"
grep -q "cosign sign-blob --yes --bundle dist/SHA256SUMS.sigstore.json dist/SHA256SUMS" "$W" && ok || bad "release.yml must sign SHA256SUMS into SHA256SUMS.sigstore.json (get-gamecove.sh refuses unsigned releases)"
grep -q "id-token: write" "$W" && ok || bad "release.yml's release job needs id-token: write for keyless signing"
inst_ident="$(sed -n 's/^[[:space:]]*ident="\(.*\)"$/\1/p' "$REPO/packaging/get-gamecove.sh")"
wf_ident="$(sed -n 's/^[[:space:]]*ident="\(.*\)"$/\1/p' "$W")"
[ -n "$inst_ident" ] && [ "$inst_ident" = "$wf_ident" ] && ok || bad "release.yml checks a different signer identity than get-gamecove.sh ($wf_ident vs $inst_ident)"
ver="$(sed -n 's/^Version:[[:space:]]*//p' "$REPO/packaging/rpm/gamecove.spec")"
[ -s "$REPO/packaging/release-notes/v$ver.md" ] && ok || bad "packaging/release-notes/v$ver.md missing (the release workflow publishes it)"

# ------------------------------------------------------- fixes' own tests
found=0
for t in "$REPO"/fixes/*/test.sh; do
	[ -f "$t" ] || continue
	found=1
	if sh "$t" >"$T/out" 2>&1; then ok; else bad "$t: $(tail -20 "$T/out")"; fi
done
[ "$found" -eq 1 ] || echo "note: no fixes/*/test.sh found, skipped" >&2

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
