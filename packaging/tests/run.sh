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
for n in fan charge-limit claw8ex-gyro claw8ex-vrr claw8ex-buttons; do
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
lacks "$ROOT/calls" "install" "no install reached a fix through the set entry"
lacks "$ROOT/calls" "remove" "no remove reached a fix through the set entry"
# Under pkexec it hands over to the installed dispatcher; the caller's paths are ignored.
: >"$ROOT/calls"
PKEXEC_UID=1000 GAMECOVE_ROOT="$ROOT" GAMECOVE_FIXES_DIR="$FIXES" sh "$FIXSET" fan set quiet >"$T/out" 2>&1
code=$?
if [ "$code" -ne 0 ]; then ok; else bad "set entry under pkexec must not use the caller's fixes"; fi
if [ ! -s "$ROOT/calls" ]; then ok; else bad "set entry ran a caller-chosen fix under pkexec"; fi
rm -rf "$FIXES/fan" "$FIXES/charge-limit" "$FIXES/claw8ex-gyro" "$FIXES/claw8ex-vrr" "$FIXES/claw8ex-buttons"

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
for f in usr/bin/gamescope-session-plus usr/bin/gamecove-session-select \
	usr/lib/gamecove/gamecove.x86_64 usr/lib/gamecove/gamecove.pck \
	usr/libexec/gamecove/gamecove-fix usr/libexec/gamecove/gamecove-fix-set usr/libexec/gamecove/gamecove-session-client \
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
contains "$SPEC" "^License:        GPL-3.0-or-later AND GPL-2.0-only AND GPL-2.0-or-later$" "spec License tag"
contains "$SPEC" "packaging/libexec/gamecove-fix-set" "spec installs the set entry point"
contains "$SPEC" "^%{_libexecdir}/gamecove/gamecove-fix-set$" "spec lists the set entry point"
contains "$SPEC" "build-bpf.sh" "spec builds the gyro program"
contains "$SPEC" "LICENSES/GPL-2.0-only.txt" "spec ships the GPL-2.0 text"
uhb_spec="$(sed -n 's/^%global uhb_commit //p' "$SPEC")"
uhb_script="$(sed -n 's/.*UHB_PIN:-\([0-9a-f]*\)}.*/\1/p' "$REPO/fixes/claw8ex-gyro/bpf/build-bpf.sh")"
if [ -n "$uhb_spec" ] && [ "$uhb_spec" = "$uhb_script" ]; then ok; else bad "udev-hid-bpf pin differs: spec '$uhb_spec', build-bpf.sh '$uhb_script'"; fi
if grep -q "GPL-3.0-only" "$SPEC" "$REPO/README.md" "$REPO/CREDITS.md"; then bad "GPL-3.0-only mentioned; GameCove is GPL-3.0-or-later"; else ok; fi

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
		"$REPO/session/gamecove-session-client" "$REPO/session/gamecove-session-select"; do
		if "$SHELLCHECK" -S warning -s sh "$f" >"$T/out" 2>&1; then ok; else bad "shellcheck $f: $(cat "$T/out")"; fi
	done
	f="$REPO/session/gamescope-session-plus/sessions.d/gamecove"
	if "$SHELLCHECK" -S warning -s bash "$f" >"$T/out" 2>&1; then ok; else bad "shellcheck $f: $(cat "$T/out")"; fi
	for f in "$REPO"/fixes/*/fix.sh "$REPO"/fixes/*/test.sh "$REPO"/fixes/*/tests/*.sh "$REPO"/fixes/lib/*.sh \
		"$REPO"/fixes/*/bpf/*.sh; do
		[ -f "$f" ] || continue
		# -x from the repo root so "# shellcheck source=fixes/..." paths resolve
		if (cd "$REPO" && "$SHELLCHECK" -S warning -x -s sh "$f") >"$T/out" 2>&1; then ok; else bad "shellcheck $f: $(cat "$T/out")"; fi
	done
fi

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
