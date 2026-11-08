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

# ------------------------------------------------------------ session-select
BIN="$T/bin"
mkdir -p "$BIN"
cat >"$BIN/steamosctl" <<EOF
#!/bin/sh
echo "\$*" >>"$T/steamosctl.log"
EOF
chmod +x "$BIN/steamosctl"
SEL="$REPO/session/gamecove-session-select"

sel() {
	: >"$T/steamosctl.log"
	PATH="$BIN:$PATH" sh "$SEL" "$@"
}

if [ "$(id -u)" -eq 0 ]; then
	expect_code 1 "session-select refuses root" sel steam
	echo "note: running as root, skipping session-select switch tests" >&2
else
	expect_code 0 "switch to steam" sel steam
	contains "$T/steamosctl.log" "^switch-to-game-mode$" "steam uses switch-to-game-mode"
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

# -------------------------------------------------------- session file syntax
if bash -n "$REPO/session/gamescope-session-plus/sessions.d/gamecove"; then ok; else bad "sessions.d/gamecove syntax"; fi
# shellcheck disable=SC2016  # expanded by the inner bash
if bash -c 'set -a; . "$1"; [ "$CLIENTCMD" = /usr/libexec/gamecove/gamecove-session-client ] && [ "$GAMECOVE_STEAM_MODE" = silent ]' _ \
	"$REPO/session/gamescope-session-plus/sessions.d/gamecove"; then ok; else bad "session file sets CLIENTCMD"; fi
contains "$REPO/session/wayland-sessions/gamecove.desktop" "^Exec=gamescope-session-plus gamecove$" "desktop Exec"

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
	usr/libexec/gamecove/gamecove-fix usr/libexec/gamecove/gamecove-session-client \
	usr/share/gamescope-session-plus/sessions.d/gamecove usr/share/wayland-sessions/gamecove.desktop \
	usr/share/polkit-1/actions/io.github.ihulksmashi.gamecove.policy \
	usr/lib/systemd/user/gamescope-session-plus@gamecove.service.d/10-gamecove.conf; do
	if [ -e "$TREE/$f" ]; then ok; else bad "sysext tree missing $f"; fi
done
contains "$TREE/usr/lib/extension-release.d/extension-release.gamecove" "^ID=_any$" "extension-release ID"
if [ ! -e "$TREE/etc" ] && [ ! -e "$TREE/var" ]; then ok; else bad "sysext must only hold /usr"; fi
if [ -z "$(find "$TREE" -name test.sh -o -type d -name tests)" ]; then ok; else bad "fix tests must not ship"; fi
if [ -f "$TREE/usr/lib/gamecove/fixes/lib/claw8ex-common.sh" ]; then ok; else bad "shared fix code must ship"; fi

# ------------------------------------------------------------------ polkit XML
POL="$REPO/packaging/polkit/io.github.ihulksmashi.gamecove.policy"
if python3 -c "import sys, xml.dom.minidom; xml.dom.minidom.parse(sys.argv[1])" "$POL" 2>"$T/out"; then ok; else bad "policy XML: $(cat "$T/out")"; fi
contains "$POL" "<allow_active>yes</allow_active>" "active session allowed"
contains "$POL" "<allow_inactive>auth_admin</allow_inactive>" "inactive needs admin"
contains "$POL" "<allow_any>auth_admin</allow_any>" "any needs admin"
contains "$POL" "/usr/libexec/gamecove/gamecove-fix" "exec path"

# ------------------------------------------------------------------ shellcheck
SHELLCHECK="$(command -v shellcheck || true)"
if [ -z "$SHELLCHECK" ]; then
	bad "shellcheck not found (pip install shellcheck-py)"
else
	for f in "$REPO/packaging/libexec/gamecove-fix" "$REPO/packaging/install.sh" \
		"$REPO/packaging/sysext/build-sysext.sh" "$REPO/packaging/tests/run.sh" \
		"$REPO/session/gamecove-session-client" "$REPO/session/gamecove-session-select"; do
		if "$SHELLCHECK" -s sh "$f" >"$T/out" 2>&1; then ok; else bad "shellcheck $f: $(cat "$T/out")"; fi
	done
	f="$REPO/session/gamescope-session-plus/sessions.d/gamecove"
	if "$SHELLCHECK" -s bash "$f" >"$T/out" 2>&1; then ok; else bad "shellcheck $f: $(cat "$T/out")"; fi
	for f in "$REPO"/fixes/*/fix.sh "$REPO"/fixes/*/test.sh "$REPO"/fixes/lib/*.sh; do
		[ -f "$f" ] || continue
		# -x from the repo root so "# shellcheck source=fixes/..." paths resolve
		if (cd "$REPO" && "$SHELLCHECK" -x -s sh "$f") >"$T/out" 2>&1; then ok; else bad "shellcheck $f: $(cat "$T/out")"; fi
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
