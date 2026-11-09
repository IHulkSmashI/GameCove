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
install|remove) echo "detail: $1 dummy" >>"$GAMECOVE_CHANGES_LOG" ;;
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

lines_before="$(wc -l <"$LOG")"
expect_code 0 "status" gf dummy status
contains "$T/out" "installed=yes" "status output passed through"
if [ "$(wc -l <"$LOG")" -eq "$lines_before" ]; then ok; else bad "status must not log"; fi

expect_code 0 "remove" gf dummy remove
contains "$LOG" "action=remove value=- result=ok" "remove logged"

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
expect_code 65 "set entry refuses vrr (boot config)" gfs claw8ex-vrr set on
expect_code 65 "set entry refuses vrr install" gfs claw8ex-vrr install
expect_code 65 "set entry refuses vrr status" gfs claw8ex-vrr status
expect_code 65 "set entry refuses buttons" gfs claw8ex-buttons set on
expect_code 65 "set entry refuses buttons install" gfs claw8ex-buttons install
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
expect_code 0 "set entry: status" gfs fan status
contains "$T/out" "^state=on$" "status passed through"
expect_code 0 "set entry: fan curve" gfs fan set curve:0,40,50,60,80,100
contains "$ROOT/calls" "^fan:set curve:0,40,50,60,80,100$" "fan curve reached fix.sh"
expect_code 66 "set entry: fan curve letters" gfs fan set curve:0,40,x
expect_code 66 "set entry: fan curve empty" gfs fan set curve:
expect_code 66 "set entry: fan curve trailing comma" gfs fan set curve:1,2,
expect_code 66 "set entry: fan curve shell" gfs fan set 'curve:1;reboot'
for v in boost:off smt:on cores:4 epp:balance_power governor:powersave cpumax:70 gpulevel:auto gpumin:600 \
	gpumax:1800 gpuprofile:power_saving sppt:28 fppt:33 platform:low-power tau:8000000 tau:restore \
	thermald:hold thermald:release sleep:deep battery:long-life mcu:off restore; do
	expect_code 0 "set entry: power-tune $v" gfs power-tune set "$v"
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
lacks "$ROOT/calls" "install" "no install reached a fix through the set entry"
lacks "$ROOT/calls" "remove" "no remove reached a fix through the set entry"
# The small file fixes (udev rules, session files): only on / off, never install / remove.
: >"$ROOT/calls"
expect_code 0 "set entry: file fix on" gfs claw-kbd-wakeup set on
expect_code 0 "set entry: file fix off" gfs claw-kbd-wakeup set off
contains "$ROOT/calls" "^claw-kbd-wakeup:set on$" "file fix on reached fix.sh"
contains "$ROOT/calls" "^claw-kbd-wakeup:set off$" "file fix off reached fix.sh"
expect_code 66 "set entry: file fix other value" gfs claw-kbd-wakeup set quiet
expect_code 64 "set entry: file fix install" gfs claw-kbd-wakeup install
expect_code 64 "set entry: file fix remove" gfs claw-kbd-wakeup remove
expect_code 66 "set entry: fan on is not a file fix value" gfs fan set on
# FILE_FIXES = exactly the fix folders built on gcfix.sh
want=$(grep -l 'gcfix.sh"$' "$REPO"/fixes/*/fix.sh | sed 's|.*/fixes/\([^/]*\)/fix.sh|\1|' | sort | tr '\n' ' ')
have=$(sed -n 's/^FILE_FIXES="\(.*\)"$/\1/p' "$FIXSET" | tr ' ' '\n' | sort | tr '\n' ' ')
if [ "$want" = "$have" ]; then ok; else bad "FILE_FIXES in gamecove-fix-set ($have) must list the gcfix fixes ($want)"; fi
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

if [ "$(id -u)" -eq 0 ]; then
	expect_code 1 "session-select refuses root" sel steam
	echo "note: running as root, skipping session-select switch tests" >&2
else
	: >"$T/busctl.log"
	expect_code 0 "switch to steam" sel steam
	contains "$T/steamosctl.log" "^switch-to-game-mode$" "steam uses switch-to-game-mode"
	contains "$T/busctl.log" "^$RESET0$" "switching resets InterceptMode on device 0"
	contains "$T/busctl.log" "^$RESET1$" "switching resets InterceptMode on device 1"
	lacks "$T/busctl.log" "dbus0 " "target devices left alone"
	: >"$T/busctl.log"
	expect_code 64 "unknown target, no reset" sel windows
	lacks "$T/busctl.log" "set-property" "bad usage resets nothing"
	expect_code 0 "switch to gamecove" sel gamecove
	contains "$T/steamosctl.log" "^switch-to-desktop-mode gamecove.desktop$" "gamecove via desktop session"
	expect_code 0 "gamecove default" sel gamecove --default
	contains "$T/steamosctl.log" "^set-default-desktop-session gamecove.desktop$" "default session set"
	contains "$T/steamosctl.log" "^set-default-login-mode desktop$" "login mode desktop"
	expect_code 0 "steam default" sel steam --default
	contains "$T/steamosctl.log" "^set-default-login-mode game$" "login mode game"
	expect_code 0 "gamecove default without switching" sel gamecove --default --no-switch
	contains "$T/steamosctl.log" "^set-default-desktop-session gamecove.desktop$" "no-switch still sets the session"
	contains "$T/steamosctl.log" "^set-default-login-mode desktop$" "no-switch still sets the login mode"
	lacks "$T/steamosctl.log" "switch-to" "no-switch doesn't switch"
	expect_code 0 "steam default without switching" sel steam --default --no-switch
	contains "$T/steamosctl.log" "^set-default-login-mode game$" "steam no-switch login mode"
	lacks "$T/steamosctl.log" "switch-to" "steam no-switch doesn't switch"
	expect_code 64 "no-switch without default" sel gamecove --no-switch
	expect_code 64 "too many args" sel gamecove --default --no-switch extra
	expect_code 0 "desktop" sel desktop
	contains "$T/steamosctl.log" "^switch-to-desktop-mode$" "desktop default"
	expect_code 64 "desktop --default" sel desktop --default
	expect_code 64 "unknown target" sel windows
	expect_code 64 "bad flag" sel steam --now
	expect_code 2 "no steamosctl" env STEAMOSCTL=/nonexistent/steamosctl sh "$SEL" steam
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
	PATH="$PB:/usr/bin:/bin" GAMECOVE_STATE_DIR="$T/gcstate" GAMECOVE_FIX_SET="$T/fix-set" \
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
expect_code 0 "install.sh install" inst "$T/gamecove-0.1.0-1.x86_64.rpm"
contains "$T/install.log" "rpm-ostree install $T/gamecove-0.1.0-1.x86_64.rpm" "rpm-ostree install"
expect_code 0 "install.sh uninstall" inst --uninstall
contains "$T/install.log" "rpm-ostree uninstall gamecove" "rpm-ostree uninstall"
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
GB="$T/ggbin"
SRV="$T/ggsrv"
mkdir -p "$GB" "$SRV"
# Fake curl: serves $SRV/<last path part> ($SRV/latest.json for the API), logs every URL.
cat >"$GB/curl" <<EOF
#!/bin/sh
out=""
url=""
while [ \$# -gt 0 ]; do
	case "\$1" in
	-o) out="\$2"; shift ;;
	-H) shift ;;
	-*) ;;
	*) url="\$1" ;;
	esac
	shift
done
echo "\$url" >>"$T/curl.log"
[ -f "$T/offline" ] && exit 6
case "\$url" in
*/releases/latest) f="$SRV/latest.json" ;;
*/releases/tags/*) f="$SRV/tag.json" ;;
*) f="$SRV/\${url##*/}" ;;
esac
[ -f "\$f" ] || exit 22
if [ -n "\$out" ]; then cp "\$f" "\$out"; else cat "\$f"; fi
EOF
cat >"$GB/badsum" <<'EOF'
#!/bin/sh
echo "0000000000000000000000000000000000000000000000000000000000000000  $1"
EOF
chmod +x "$GB/curl" "$GB/badsum"
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
{
	echo '{'
	echo '  "tag_name": "v0.2.0",'
	echo '  "assets": ['
	for a in gamecove-0.2.0-1.fc43.src.rpm gamecove-0.2.0-1.fc43.x86_64.rpm gamecove-0.2.0-x86_64.raw \
		gamecove-0.2.0-x86_64.tar.gz get-gamecove.sh SHA256SUMS; do
		echo "    { \"name\": \"$a\", \"browser_download_url\": \"https://example.test/dl/$a\" },"
	done
	echo '  ]'
	echo '}'
} >"$SRV/latest.json"
cp "$SRV/latest.json" "$SRV/tag.json"
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
	env PATH="$GB:$PATH" GAMECOVE_HOME="$T/gghome" GAMECOVE_ROOT="$root" GAMECOVE_ARCH=x86_64 \
		GAMECOVE_API=https://api.example.test "$@" sh "$GG" --no-launch
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
contains "$T/curl.log" "^https://api.example.test/repos/IHulkSmashI/GameCove/releases/latest$" "latest release API"
if [ -x "$GI/get-gamecove.sh" ]; then ok; else bad "bootstrap keeps a checked copy of itself"; fi
GE="$T/gghome/.local/share/applications/io.github.ihulksmashi.GameCoveInstaller.desktop"
contains "$GE" "^Name=GameCove Installer$" "installer app entry"
contains "$GE" "^Exec=sh \"$GI/get-gamecove.sh\"$" "entry re-runs the bootstrap"
if [ -x "$T/gghome/Desktop/Install GameCove.desktop" ]; then ok; else bad "desktop shortcut"; fi
contains "$T/gghome/.local/share/gamecove/installer.log" "sha256 ok gamecove-0.2.0-x86_64.tar.gz" "checksums logged"
if [ -z "$(find "$GI" -name '.download.*')" ]; then ok; else bad "download folder cleaned up"; fi
expect_code 0 "bootstrap on SteamOS" gg "$R_DECK"
if [ -f "$GI/packages/gamecove-0.2.0-x86_64.raw" ] && [ ! -e "$GI/packages/gamecove-0.2.0-1.fc43.x86_64.rpm" ]; then ok; else bad "sysext replaces the RPM on SteamOS"; fi
contains "$GI/release.env" "^OS=steamos$" "steamos release env"
expect_code 0 "bootstrap elsewhere (app only)" gg "$R_ARCH"
contains "$GI/release.env" "^PACKAGE=$" "no package on other systems"
expect_code 0 "bootstrap with a tag" gg "$R_BAZ" GAMECOVE_TAG=v0.2.0
contains "$T/curl.log" "/releases/tags/v0.2.0$" "tag API"
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
expect_code 0 "bootstrap again" gg "$R_BAZ"
touch "$T/offline"
: >"$T/launch.log"
expect_code 0 "bootstrap offline uses the cached app" env PATH="$GB:$PATH" GAMECOVE_HOME="$T/gghome" GAMECOVE_ROOT="$R_BAZ" \
	GAMECOVE_ARCH=x86_64 DISPLAY=:9 sh "$GG"
sleep 0.3
contains "$T/launch.log" "^app -- --installer$" "installer launched with user args"
rm -f "$T/offline"
rm -rf "$T/gghome"
expect_code 1 "bootstrap offline without a cache" env PATH="$GB:$PATH" GAMECOVE_HOME="$T/gghome" GAMECOVE_ROOT="$R_BAZ" \
	GAMECOVE_ARCH=x86_64 CURL=false sh "$GG" --no-launch

# ------------------------------------------------------- sysext tree (offline)
APP="$T/app"
SS="$T/gs-session"
mkdir -p "$APP" "$SS/usr/bin" "$SS/usr/share/gamescope-session-plus"
echo bin >"$APP/gamecove.x86_64"
echo pck >"$APP/gamecove.pck"
printf '#!/bin/sh\n' >"$SS/usr/bin/gamescope-session-plus"
echo MIT >"$SS/LICENSE"
expect_code 0 "sysext tree" sh "$REPO/packaging/sysext/build-sysext.sh" --app "$APP" --session-src "$SS" --out "$T/dist" --tree-only
TREE="$T/dist/gamecove"
for f in usr/bin/gamescope-session-plus usr/bin/gamecove-session-select usr/bin/gamecove-selftest \
	usr/lib/gamecove/gamecove.x86_64 usr/lib/gamecove/gamecove.pck \
	usr/libexec/gamecove/gamecove-fix usr/libexec/gamecove/gamecove-fix-set usr/libexec/gamecove/gamecove-session-client \
	usr/libexec/gamecove/gamecove-apply-choices usr/libexec/gamecove/get-gamecove.sh \
	usr/share/applications/io.github.ihulksmashi.GameCoveInstaller.desktop \
	usr/share/licenses/gamecove/LICENSE usr/share/licenses/gamecove/GPL-2.0-only.txt usr/share/licenses/gamecove/LICENSE.ClawLab-MIT \
	usr/share/gamescope-session-plus/sessions.d/gamecove usr/share/wayland-sessions/gamecove.desktop \
	usr/share/polkit-1/actions/io.github.ihulksmashi.gamecove.policy \
	usr/lib/systemd/user/gamescope-session-plus@gamecove.service.d/10-gamecove.conf; do
	if [ -e "$TREE/$f" ]; then ok; else bad "sysext tree missing $f"; fi
done
contains "$TREE/usr/lib/extension-release.d/extension-release.gamecove" "^ID=_any$" "extension-release ID"
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
    "io.github.ihulksmashi.gamecove.fix-set": ("auth_admin", "auth_admin", "yes", ["/usr/libexec/gamecove/gamecove-fix-set"]),
    "io.github.ihulksmashi.gamecove.fix": ("auth_admin", "auth_admin", "auth_admin_keep", ["/usr/libexec/gamecove/gamecove-fix"]),
}
assert acts == want, acts
PY
code=$?
if [ "$code" -eq 0 ]; then ok; else bad "policy actions: $(cat "$T/out")"; fi
if [ "$(grep -c "<allow_active>yes</allow_active>" "$POL")" -eq 1 ]; then ok; else bad "only one action may skip the password"; fi

# ------------------------------------------------------------------ RPM spec
SPEC="$REPO/packaging/rpm/gamecove.spec"
contains "$SPEC" "^License:        GPL-3.0-or-later AND GPL-3.0-only AND GPL-2.0-only AND GPL-2.0-or-later$" "spec License tag"
contains "$SPEC" "packaging/libexec/gamecove-fix-set" "spec installs the set entry point"
contains "$SPEC" "^%{_libexecdir}/gamecove/gamecove-fix-set$" "spec lists the set entry point"
contains "$SPEC" "build-bpf.sh" "spec builds the gyro program"
contains "$SPEC" "^%{_libexecdir}/gamecove/gamecove-apply-choices$" "spec lists the installer's apply helper"
contains "$SPEC" "^%{_libexecdir}/gamecove/get-gamecove.sh$" "spec lists the bootstrap"
contains "$SPEC" "LICENSES/GPL-2.0-only.txt" "spec ships the GPL-2.0 text"
uhb_spec="$(sed -n 's/^%global uhb_commit //p' "$SPEC")"
uhb_script="$(sed -n 's/.*UHB_PIN:-\([0-9a-f]*\)}.*/\1/p' "$REPO/fixes/claw8ex-gyro/bpf/build-bpf.sh")"
if [ -n "$uhb_spec" ] && [ "$uhb_spec" = "$uhb_script" ]; then ok; else bad "udev-hid-bpf pin differs: spec '$uhb_spec', build-bpf.sh '$uhb_script'"; fi
# GameCove itself is GPL-3.0-or-later; GPL-3.0-only may appear only for the bundled Heroic icon.
if grep -h "GPL-3.0-only" "$REPO/README.md" "$REPO/CREDITS.md" | grep -v -e "Heroic" -e "Bottles" | grep -q .; then bad "GPL-3.0-only mentioned for something other than the Heroic or Bottles icon; GameCove is GPL-3.0-or-later"; else ok; fi
contains "$SPEC" "^License:.*GPL-3.0-or-later" "spec licence is GPL-3.0-or-later"

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
form = yaml.safe_load(open(os.path.join(gh, "ISSUE_TEMPLATE/bug_report.yml"), encoding="utf-8"))
opts = [b for b in form["body"] if b.get("id") == "maker"][0]["attributes"]["options"]
if opts != makers + ["Other"]:
    bad.append("bug_report.yml makers %s != devices.json makers %s + Other" % (opts, makers))
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
		"$REPO/packaging/bin/gamecove-selftest" "$REPO/packaging/tests/selftest.sh"; do
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

# ------------------------------------------------------- gamecove-selftest (fake root and commands)
if sh "$REPO/packaging/tests/selftest.sh" >"$T/out" 2>&1; then ok; else bad "selftest: $(tail -20 "$T/out")"; fi

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
