#!/bin/sh
# Desktop Mode must always be reachable (review S1-1): gamecove-session-select's
# saved defaults, restore, the login guard, the Steam "switch to desktop" bounce,
# and the session client's crash-loop guard. Fake steamosctl with state on disk.
#
#   sh packaging/tests/session.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SEL="$REPO/session/gamecove-session-select"
CLIENT="$REPO/session/gamecove-session-client"

pass=0
fail=0
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
ok() { pass=$((pass + 1)); }
bad() {
	fail=$((fail + 1))
	echo "FAIL: $*" >&2
}
eqv() { # <got> <want> <what>
	if [ "$1" = "$2" ]; then ok; else bad "$3: got '$1', want '$2'"; fi
}
has() { if grep -q -- "$2" "$1" 2>/dev/null; then ok; else bad "$3: '$2' not in $1"; fi; }
hasnt() { if grep -q -- "$2" "$1" 2>/dev/null; then bad "$3: '$2' in $1"; else ok; fi; }

BIN="$T/bin"
ST="$T/sm" # steamos-manager state
mkdir -p "$BIN" "$ST" "$T/sessions" "$T/home"
# a user, even when the tests run as root
printf '#!/bin/sh\n[ "$1" = "-u" ] && echo 1000 || /usr/bin/id "$@"\n' >"$BIN/id"
cat >"$BIN/steamosctl" <<EOF
#!/bin/sh
echo "\$*" >>"$T/steamosctl.log"
case "\$1" in
get-default-desktop-session) cat "$ST/desktop" ;;
get-default-login-mode) cat "$ST/mode" ;;
get-valid-desktop-sessions) printf 'Sessions:\n\n'; for f in "$T/sessions"/*.desktop; do [ -f "\$f" ] && echo "- \${f##*/}"; done ;;
set-default-desktop-session) [ -f "$T/sessions/\$2" ] || exit 1; echo "\$2" >"$ST/desktop" ;;
set-default-login-mode) echo "\$2" >"$ST/mode" ;;
switch-to-desktop-mode) echo "\${2:-DEFAULT}" >"$ST/switched" ;;
switch-to-game-mode) echo game >"$ST/switched" ;;
esac
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' >"$BIN/systemctl"
printf '#!/bin/sh\nexit 0\n' >"$BIN/busctl"
chmod +x "$BIN"/*
touch "$T/sessions/plasma.desktop" "$T/sessions/gamecove.desktop" "$T/sessions/gamescope-session-ogui-steam.desktop"
echo boot-1 >"$T/boot_id"
DATA="$T/home/.local/share/gamecove"
UNITS="$T/home/.config/systemd/user"

sel() {
	: >"$T/steamosctl.log"
	rm -f "$ST/switched"
	env PATH="$BIN:$PATH" HOME="$T/home" XDG_DATA_HOME="$T/home/.local/share" XDG_CONFIG_HOME="$T/home/.config" \
		GAMECOVE_SESSIONS_DIRS="$T/sessions" GAMECOVE_BOOT_ID_FILE="$T/boot_id" sh "$SEL" "$@" >"$T/out" 2>&1
}
fresh() {
	echo plasma.desktop >"$ST/desktop"
	echo game >"$ST/mode"
	rm -rf "${T:?}/home"
	mkdir -p "$T/home"
}

# --- root is refused (the real id)
env PATH="/usr/bin:/bin" sh -c "[ \"\$(id -u)\" -eq 0 ]" && {
	env HOME="$T/home" STEAMOSCTL="$BIN/steamosctl" sh "$SEL" steam >/dev/null 2>&1
	eqv "$?" 1 "root refused"
}

# --- --default saves what was there and installs the guard
fresh
sel gamecove --default --no-switch
eqv "$?" 0 "gamecove --default"
eqv "$(cat "$ST/desktop")" gamecove.desktop "GameCove is the default desktop session (boot)"
eqv "$(cat "$ST/mode")" desktop "boot mode desktop"
eqv "$(cat "$DATA/prev-desktop-session")" plasma.desktop "previous desktop session saved"
eqv "$(cat "$DATA/prev-login-mode")" game "previous login mode saved"
[ -x "$DATA/gamecove-session-guard" ] && ok || bad "guard copy kept in the data folder"
[ -L "$UNITS/default.target.wants/gamecove-session-guard.service" ] && ok || bad "guard unit enabled"
has "$UNITS/gamecove-session-guard.service" "guard$" "unit runs guard"
[ ! -e "$ST/switched" ] && ok || bad "--no-switch doesn't switch"

# a second --default must not save GameCove as the previous session
sel gamecove --default --no-switch
eqv "$(cat "$DATA/prev-desktop-session")" plasma.desktop "previous session survives a second --default"
eqv "$(cat "$DATA/prev-login-mode")" game "previous mode survives a second --default"

# --- every desktop path names the real desktop
sel desktop
eqv "$(cat "$ST/switched")" plasma.desktop "desktop names Plasma, not the default (GameCove)"
rm -f "$DATA/prev-desktop-session"
sel desktop
eqv "$(cat "$ST/switched")" plasma.desktop "desktop finds Plasma without the saved file"
echo plasma.desktop >"$DATA/prev-desktop-session"
sel desktop --default
eqv "$?" 64 "desktop --default refused"

# --- Steam's "Switch to Desktop" (no session named) lands in GameCove: forwarded
sel steam
eqv "$(cat "$ST/switched")" game "steam switches to game mode"
eqv "$(cat "$DATA/left-for-steam")" boot-1 "marker with this boot's id"
sel session-start
eqv "$?" 3 "session start after leaving for Steam is forwarded"
eqv "$(cat "$ST/switched")" plasma.desktop "forwarded to Plasma"
sel session-start
eqv "$?" 0 "only once: the next start is GameCove"
sel steam
echo boot-2 >"$T/boot_id"
sel session-start
eqv "$?" 0 "after a reboot GameCove starts normally"
echo boot-1 >"$T/boot_id"
sel steam
sel gamecove
eqv "$(cat "$ST/switched")" gamecove.desktop "explicit gamecove"
sel session-start
eqv "$?" 0 "asked-for GameCove isn't forwarded"
sel steam
sel desktop
sel session-start
eqv "$?" 0 "desktop clears the marker too"

# --- restore (uninstall, TTY): previous desktop session and boot mode back
sel restore
eqv "$?" 0 "restore"
eqv "$(cat "$ST/desktop")" plasma.desktop "desktop default back to Plasma"
eqv "$(cat "$ST/mode")" game "boot back to Steam Gaming Mode"
[ ! -e "$UNITS/gamecove-session-guard.service" ] && [ ! -e "$DATA/gamecove-session-guard" ] && ok || bad "restore removes the guard"
[ ! -e "$DATA/prev-desktop-session" ] && ok || bad "restore forgets the saved session"

# previous boot mode desktop comes back as desktop
fresh
echo desktop >"$ST/mode"
sel gamecove --default --no-switch
sel restore
eqv "$(cat "$ST/desktop")" plasma.desktop "restore: Plasma"
eqv "$(cat "$ST/mode")" desktop "restore: previous boot mode desktop"

# steam --default undoes the desktop default as well
fresh
sel gamecove --default --no-switch
sel steam --default --no-switch
eqv "$(cat "$ST/desktop")" plasma.desktop "steam --default: desktop default back to Plasma"
eqv "$(cat "$ST/mode")" game "steam --default: game mode"

# --- guard: package removed / rolled back (gamecove.desktop missing)
fresh
sel gamecove --default --no-switch
sel guard
eqv "$(cat "$ST/desktop")" gamecove.desktop "guard leaves an installed GameCove alone"
rm "$T/sessions/gamecove.desktop"
: >"$T/steamosctl.log"
env PATH="$BIN:$PATH" HOME="$T/home" XDG_DATA_HOME="$T/home/.local/share" XDG_CONFIG_HOME="$T/home/.config" \
	GAMECOVE_SESSIONS_DIRS="$T/sessions" sh "$DATA/gamecove-session-guard" guard >"$T/out" 2>&1
eqv "$?" 0 "guard copy runs without the package"
eqv "$(cat "$ST/desktop")" plasma.desktop "guard: default desktop no longer names the missing file"
eqv "$(cat "$ST/mode")" game "guard: boot back to Steam Gaming Mode"
[ ! -e "$UNITS/gamecove-session-guard.service" ] && ok || bad "guard removes itself when done"
sel gamecove
eqv "$?" 1 "gamecove refuses when its session isn't installed"
touch "$T/sessions/gamecove.desktop"

# no steamosctl: guard/session-start are no-ops, switches explain
env PATH="$BIN:$PATH" HOME="$T/home" STEAMOSCTL=/nonexistent sh "$SEL" guard
eqv "$?" 0 "guard without steamosctl"
env PATH="$BIN:$PATH" HOME="$T/home" STEAMOSCTL=/nonexistent sh "$SEL" steam >/dev/null 2>&1
eqv "$?" 2 "steam without steamosctl"

# --- session client: crash-loop guard (3 unclean exits in a row) and the bounce
CB="$T/cbin"
mkdir -p "$CB"
cat >"$CB/gamecove.x86_64" <<EOF
#!/bin/sh
echo app >>"$T/client.log"
exit \$(cat "$T/app-code")
EOF
cat >"$CB/select" <<EOF
#!/bin/sh
echo "select \$*" >>"$T/client.log"
[ "\$1" = session-start ] && exit \$(cat "$T/bounce" 2>/dev/null || echo 0)
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' >"$CB/steam"
printf '#!/bin/sh\nexit 1\n' >"$CB/pgrep"
chmod +x "$CB"/*
client() {
	: >"$T/client.log"
	env PATH="$CB:$BIN:$PATH" HOME="$T/home" XDG_DATA_HOME="$T/home/.local/share" GAMECOVE_BIN="$CB/gamecove.x86_64" \
		GAMECOVE_SESSION_SELECT="$CB/select" GAMECOVE_STEAM_MODE=off sh "$CLIENT" >/dev/null 2>&1
}
fresh
echo 139 >"$T/app-code"
client
client
hasnt "$T/client.log" "select steam" "two crashes: keep trying"
eqv "$(cat "$DATA/crash-count")" 2 "two unclean exits counted"
client
has "$T/client.log" "^select steam$" "third crash in a row: switch to Steam Gaming Mode"
[ -f "$DATA/crash-fallback" ] && ok || bad "fallback recorded for the next start"
eqv "$(sed -n 2p "$DATA/crash-fallback")" crashes "fallback says why"
[ ! -e "$DATA/crash-count" ] && ok || bad "counter reset after falling back"
client
hasnt "$T/client.log" "select steam" "counting starts over"
echo 0 >"$T/app-code"
client
[ ! -e "$DATA/crash-count" ] && ok || bad "a clean exit clears the count"
# review M4: crashes count however long apart they are and however long each run lasted
echo 139 >"$T/app-code"
mkdir -p "$DATA"
echo 2 >"$DATA/crash-count"
touch -d '1 day ago' "$DATA/crash-count" 2>/dev/null || true
client
has "$T/client.log" "^select steam$" "slow crashes (a day apart) still trip the guard"
printf '#!/bin/sh\nsleep 2.5\nexit 139\n' >"$CB/slowcrash"
chmod +x "$CB/slowcrash"
slow() { # an app that crashes after 2.5 s
	: >"$T/client.log"
	env PATH="$CB:$BIN:$PATH" HOME="$T/home" XDG_DATA_HOME="$T/home/.local/share" GAMECOVE_BIN="$CB/slowcrash" \
		GAMECOVE_SESSION_SELECT="$CB/select" GAMECOVE_STEAM_MODE=off "$@" sh "$CLIENT" >/dev/null 2>&1
}
echo 2 >"$DATA/crash-count"
slow
has "$T/client.log" "^select steam$" "a crash after some uptime counts too (no time window)"
echo 2 >"$DATA/crash-count"
slow GAMECOVE_HEALTHY_S=1
hasnt "$T/client.log" "select steam" "a run that stayed up the healthy time starts the count over"
eqv "$(cat "$DATA/crash-count")" 1 "only the crash after the healthy run counts"
# the count can't be saved: fall back at once instead of never reaching the limit
rm -rf "$DATA"
mkdir -p "$DATA/crash-count.tmp" # a directory: the temp file can't be written, even as root
client
has "$T/client.log" "^select steam$" "unsaved crash count: switch away at once"
eqv "$(sed -n 2p "$DATA/crash-fallback")" unsaved "fallback says the count couldn't be saved"
rm -rf "$DATA"
# a missing binary counts as an unclean exit
: >"$T/client.log"
for i in 1 2 3; do
	env PATH="$CB:$BIN:$PATH" HOME="$T/home" XDG_DATA_HOME="$T/home/.local/share" GAMECOVE_BIN="$T/nonexistent$i" \
		GAMECOVE_SESSION_SELECT="$CB/select" GAMECOVE_STEAM_MODE=off sh "$CLIENT" >/dev/null 2>&1
done
has "$T/client.log" "^select steam$" "a missing binary three times: switch away"
eqv "$(sed -n 2p "$DATA/crash-fallback")" missing "fallback says the binary is missing"
rm -rf "$DATA"
echo 139 >"$T/app-code"
# no Steam: the desktop instead
rm "$CB/steam"
client
client
client
has "$T/client.log" "^select desktop$" "no Steam: fall back to the desktop"
# bounce: the app never starts
echo 3 >"$T/bounce"
client
hasnt "$T/client.log" "^app$" "forwarded session doesn't start the app"

# --- review S2-4: Steam starts only after the app wrote the Steam settings that waited
echo 0 >"$T/bounce"
RUNDIR="$T/run"
mkdir -p "$RUNDIR"
cat >"$CB/slowapp" <<EOF
#!/bin/sh
sleep 0.5
echo "settings written" >>"$T/order.log"
: >"$RUNDIR/gamecove-steam-ready"
sleep 0.5
exit 0
EOF
cat >"$CB/steam" <<EOF
#!/bin/sh
echo "steam \$*" >>"$T/order.log"
EOF
chmod +x "$CB/slowapp" "$CB/steam"
: >"$T/order.log"
: >"$RUNDIR/gamecove-steam-ready" # a stale one from the last session must not count
env PATH="$CB:$BIN:$PATH" HOME="$T/home" XDG_RUNTIME_DIR="$RUNDIR" GAMECOVE_BIN="$CB/slowapp" \
	GAMECOVE_SESSION_SELECT="$CB/select" GAMECOVE_STEAM_MODE=silent sh "$CLIENT" >/dev/null 2>&1
sleep 0.3
eqv "$(head -n 1 "$T/order.log")" "settings written" "Steam waits for the app's Steam settings"
has "$T/order.log" "^steam -silent$" "then Steam starts"
: >"$T/order.log"
printf '#!/bin/sh\nsleep 1\n' >"$CB/mute"
chmod +x "$CB/mute"
env PATH="$CB:$BIN:$PATH" HOME="$T/home" XDG_RUNTIME_DIR="$RUNDIR" GAMECOVE_BIN="$CB/mute" GAMECOVE_STEAM_WAIT_S=0 \
	GAMECOVE_SESSION_SELECT="$CB/select" GAMECOVE_STEAM_MODE=silent sh "$CLIENT" >/dev/null 2>&1
sleep 0.3
has "$T/order.log" "^steam -silent$" "an app that never says ready doesn't keep Steam away (timeout)"

# --- traits: ZOTAC Zone board G1A1W, which Linux's orientation quirk misses (G0A1W only)
SD="$REPO/session/gamescope-session-plus/sessions.d/gamecove"
orient() { # <vendor> <board> [preset]
	mkdir -p "$T/dmi"
	echo "$1" >"$T/dmi/sys_vendor"
	echo "$2" >"$T/dmi/board_name"
	env -i GAMECOVE_DMI="$T/dmi" ORIENTATION="${3:-}" HOME="$T/home" bash -c 'set -a; . "$1"; printf "%s" "$ORIENTATION"' _ "$SD"
}
eqv "$(orient ZOTAC G1A1W)" left "Zone G1A1W: the session turns the panel left"
eqv "$(orient ZOTAC G0A1W)" "" "Zone G0A1W: the kernel's quirk does it, nothing from us"
eqv "$(orient ZOTAC G1A1W right)" right "a user's ORIENTATION wins"
eqv "$(orient "Micro-Star International Co., Ltd." MS-1T91)" "" "other handhelds untouched"

echo "session: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
