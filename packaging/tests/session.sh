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
lab() { if [ -f "$T/labels" ]; then printf '%s: ' "\$1"; fi; }
case "\$1" in
get-default-desktop-session) lab "Default desktop session"; cat "$ST/desktop" ;;
get-default-login-mode) lab "Default login mode"; cat "$ST/mode" ;;
get-valid-desktop-sessions) printf 'Sessions:\n\n'; for f in "$T/sessions"/*.desktop; do [ -f "\$f" ] && echo "- \${f##*/}"; done ;;
set-default-desktop-session) [ -f "$T/sessions/\$2" ] || exit 1; [ -f "$T/sets-ignored" ] || echo "\$2" >"$ST/desktop" ;;
set-default-login-mode) case "\$2" in game | desktop) ;; *) echo "error: invalid value '\$2'" >&2; exit 2 ;; esac
	[ -f "$T/sets-ignored" ] || echo "\$2" >"$ST/mode" ;;
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
		GAMECOVE_SESSIONS_DIRS="$T/sessions" GAMECOVE_BOOT_ID_FILE="$T/boot_id" \
		GAMECOVE_OSTREE_BOOTED="${OSTREE_BOOTED_TEST:-$T/not-ostree}" OSTREE="$BIN/ostree" RPM_OSTREE="$BIN/rpm-ostree" \
		sh "$SEL" "$@" >"$T/out" 2>&1
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

# --- review H4: on rpm-ostree, "boot into GameCove" waits until the booted deployment has it
# (--apply-live only overlays the running /usr; the next boot could still be an image without it)
cat >"$BIN/ostree" <<EOF
#!/bin/sh
[ "\$*" = "admin --print-current-dir" ] && [ -f "$T/ostree-ok" ] && echo "$T/deploy" && exit 0
exit 1
EOF
cat >"$BIN/rpm-ostree" <<EOF
#!/bin/sh
[ "\$*" = "status --booted --json" ] && cat "$T/rpmostree.json"
EOF
chmod +x "$BIN/ostree" "$BIN/rpm-ostree"
touch "$T/ostree-booted" "$T/ostree-ok"
mkdir -p "$T/deploy/usr"
OSTREE_BOOTED_TEST="$T/ostree-booted"
fresh
sel gamecove --default --no-switch
eqv "$?" 4 "staged only (booted deployment has no gamecove.desktop): not the boot default yet"
eqv "$(cat "$ST/desktop")" plasma.desktop "the boot default is left alone"
eqv "$(cat "$ST/mode")" game "the boot mode is left alone"
has "$T/out" "restart" "says to restart first"
mkdir -p "$T/deploy$T/sessions"
touch "$T/deploy$T/sessions/gamecove.desktop"
sel gamecove --default --no-switch
eqv "$?" 0 "after the reboot into it: the boot default"
eqv "$(cat "$ST/desktop")" gamecove.desktop "boot default set once booted"
rm -f "$T/ostree-ok"
fresh
echo '{"deployments":[{"booted":true,"requested-local-packages":[],"packages":["steam"]}]}' >"$T/rpmostree.json"
sel gamecove --default --no-switch
eqv "$?" 4 "no ostree answer, rpm-ostree's booted deployment lacks gamecove: wait"
echo '{"deployments":[{"booted":true,"requested-local-packages":["gamecove-0.2.0-1.fc43.x86_64"]}]}' >"$T/rpmostree.json"
sel gamecove --default --no-switch
eqv "$?" 0 "rpm-ostree lists gamecove in the booted deployment"
sel gamecove
eqv "$?" 0 "just this time needs no reboot (the live /usr has it)"
unset OSTREE_BOOTED_TEST

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
# review L22: Desktop -> Gaming Mode -> Steam's "Switch to Desktop" again: still the desktop
sel session-start
eqv "$?" 3 "a second unnamed desktop switch this boot is forwarded too"
echo boot-2 >"$T/boot_id"
sel session-start
eqv "$?" 0 "after a reboot GameCove starts normally"
echo boot-1 >"$T/boot_id"
sel steam
sel gamecove
eqv "$(cat "$ST/switched")" gamecove.desktop "explicit gamecove"
sel session-start
eqv "$?" 0 "asked-for GameCove isn't forwarded"
sel desktop
eqv "$(cat "$DATA/left-for-steam" 2>/dev/null)" boot-1 "leaving GameCove for the desktop marks this boot too"
sel session-start
eqv "$?" 3 "after GameCove -> desktop, an unnamed desktop switch goes to the desktop"
sel gamecove
sel session-start
eqv "$?" 0 "only an explicit gamecove clears it"

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
# review L24: missing only this boot (a SteamOS update that didn't merge the sysext): the guard
# stays and puts GameCove back as the default once its session is back
[ -e "$UNITS/gamecove-session-guard.service" ] && [ -f "$DATA/default-suspended" ] && ok || bad "guard stays, remembering GameCove was the default"
env PATH="$BIN:$PATH" HOME="$T/home" XDG_DATA_HOME="$T/home/.local/share" XDG_CONFIG_HOME="$T/home/.config" \
	GAMECOVE_SESSIONS_DIRS="$T/sessions" sh "$DATA/gamecove-session-guard" guard >"$T/out" 2>&1
eqv "$(cat "$ST/mode")" game "guard again while still missing: nothing changes"
sel gamecove
eqv "$?" 1 "gamecove refuses when its session isn't installed"
touch "$T/sessions/gamecove.desktop"
env PATH="$BIN:$PATH" HOME="$T/home" XDG_DATA_HOME="$T/home/.local/share" XDG_CONFIG_HOME="$T/home/.config" \
	GAMECOVE_SESSIONS_DIRS="$T/sessions" GAMECOVE_OSTREE_BOOTED="$T/not-ostree" sh "$DATA/gamecove-session-guard" guard >"$T/out" 2>&1
eqv "$(cat "$ST/desktop")" gamecove.desktop "GameCove back: boot default again"
eqv "$(cat "$ST/mode")" desktop "GameCove back: boot mode desktop again"
eqv "$(cat "$DATA/prev-desktop-session")" plasma.desktop "previous desktop remembered again"
[ ! -e "$DATA/default-suspended" ] && ok || bad "suspended mark cleared"
sel restore
[ ! -e "$UNITS/gamecove-session-guard.service" ] && [ ! -e "$DATA/default-suspended" ] && ok || bad "restore removes the guard for good"

# --- review M9: steamosctl output as SteamOS 3.10 prints it (steamos-manager 26.4.1, ROG Ally), a
# labelled variant, and a set that doesn't take
SM2="$T/sm2bin"
mkdir -p "$SM2"
cat >"$SM2/steamosctl" <<'EOF'
#!/bin/sh
case "$1" in
get-default-desktop-session) echo "plasma.desktop" ;;
get-default-login-mode) echo "game" ;;
get-valid-desktop-sessions) printf 'Sessions:\n\n- plasma.desktop\n- plasmax11.desktop\n' ;;
get-fan-control-state) echo "Fan control state: BIOS" ;;
get-max-charge-level) echo "Max charge level: 100" ;;
esac
echo "$*" >>"$SM2LOG"
EOF
chmod +x "$SM2/steamosctl"
rm -rf "$T/ally"
mkdir -p "$T/ally/sessions"
touch "$T/ally/sessions/plasma.desktop" "$T/ally/sessions/plasmax11.desktop"
ally() {
	: >"$T/sm2.log"
	env PATH="$BIN:$PATH" HOME="$T/ally" SM2LOG="$T/sm2.log" STEAMOSCTL="$SM2/steamosctl" \
		GAMECOVE_SESSIONS_DIRS="$T/ally/nothing" sh "$SEL" "$@" >"$T/out" 2>&1
}
ally desktop
has "$T/sm2.log" "^switch-to-desktop-mode plasma.desktop$" "real SteamOS output: the desktop is plasma.desktop"
mkdir -p "$T/ally/.local/share/gamecove"
echo bogus.desktop >"$T/ally/.local/share/gamecove/prev-desktop-session"
ally desktop
has "$T/sm2.log" "^switch-to-desktop-mode plasma.desktop$" "real SteamOS output: the valid-session list is read"
ally restore
eqv "$?" 0 "real SteamOS output: restore with nothing of ours to undo"
hasnt "$T/sm2.log" "^set-" "real SteamOS output: nothing set when nothing names GameCove"
fresh
touch "$T/labels"
sel gamecove --default --no-switch
eqv "$?" 0 "labelled getters: --default reads back"
eqv "$(cat "$DATA/prev-desktop-session")" plasma.desktop "labelled getter: previous session saved bare"
eqv "$(cat "$DATA/prev-login-mode")" game "labelled getter: previous mode saved bare"
sel restore
eqv "$?" 0 "labelled getters: restore"
eqv "$(cat "$ST/desktop")" plasma.desktop "labelled getters: restore really sets Plasma"
eqv "$(cat "$ST/mode")" game "labelled getters: restore really sets game"
rm -f "$T/labels"
fresh
sel gamecove --default --no-switch
touch "$T/sets-ignored"
sel restore
eqv "$?" 1 "a set that doesn't take fails restore"
has "$T/out" "didn't take" "says which set didn't take"
[ -f "$DATA/prev-desktop-session" ] && [ -e "$UNITS/gamecove-session-guard.service" ] && ok || bad "failed restore keeps what to restore and the guard"
fresh
touch "$T/sets-ignored"
sel gamecove --default --no-switch
[ "$?" -ne 0 ] && ok || bad "--default fails when steamosctl doesn't take it (apply-choices keeps it pending)"
rm -f "$T/sets-ignored"

# --- review H4: SDDM shows its login screen when the autologin session file is missing; the root
# guard (copied into /etc by the SteamOS installer) points autologin back at Steam before that
AG="$REPO/session/gamecove-autologin-guard"
AR="$T/agroot"
rm -rf "$AR"
mkdir -p "$AR/etc/sddm.conf.d" "$AR/usr/share/wayland-sessions"
touch "$AR/usr/share/wayland-sessions/gamescope-wayland.desktop" "$AR/usr/share/wayland-sessions/plasma.desktop"
printf '[Autologin]\nSession=gamecove.desktop\n' >"$AR/etc/sddm.conf.d/zz-holo-autologin.conf"
printf '[Autologin]\nSession=gamecove.desktop\n' >"$AR/etc/sddm.conf.d/zzt-holo-temp-login.conf"
printf '[Autologin]\nUser=deck\n' >"$AR/etc/sddm.conf.d/steamos.conf"
touch "$AR/usr/share/wayland-sessions/gamecove.desktop"
GAMECOVE_ROOT="$AR" sh "$AG" 2>/dev/null
eqv "$?" 0 "autologin guard runs"
has "$AR/etc/sddm.conf.d/zz-holo-autologin.conf" "^Session=gamecove.desktop$" "GameCove there: autologin left alone"
rm "$AR/usr/share/wayland-sessions/gamecove.desktop"
GAMECOVE_ROOT="$AR" sh "$AG" 2>/dev/null
has "$AR/etc/sddm.conf.d/zz-holo-autologin.conf" "^Session=gamescope-wayland.desktop$" "GameCove gone: autologin starts Steam Gaming Mode"
has "$AR/etc/sddm.conf.d/zzt-holo-temp-login.conf" "^Session=gamescope-wayland.desktop$" "the temporary autologin too"
has "$AR/etc/sddm.conf.d/zz-holo-autologin.conf" "^\[Autologin\]$" "the rest of the file kept"
eqv "$(cat "$AR/etc/sddm.conf.d/steamos.conf")" "$(printf '[Autologin]\nUser=deck')" "other files untouched"
printf '[Autologin]\nSession=plasma.desktop\n' >"$AR/etc/sddm.conf.d/zz-holo-autologin.conf"
GAMECOVE_ROOT="$AR" sh "$AG" 2>/dev/null
has "$AR/etc/sddm.conf.d/zz-holo-autologin.conf" "^Session=plasma.desktop$" "only ever rewrites GameCove's entry"
rm "$AR/usr/share/wayland-sessions/gamescope-wayland.desktop"
printf '[Autologin]\nSession=gamecove\n' >"$AR/etc/sddm.conf.d/zz-holo-autologin.conf"
GAMECOVE_ROOT="$AR" sh "$AG" 2>/dev/null
has "$AR/etc/sddm.conf.d/zz-holo-autologin.conf" "^Session=plasma.desktop$" "no Steam session: the desktop"

# no steamosctl: guard/session-start are no-ops, switches explain
env PATH="$BIN:$PATH" HOME="$T/home" STEAMOSCTL=/nonexistent sh "$SEL" guard
eqv "$?" 0 "guard without steamosctl"
env PATH="$BIN:$PATH" HOME="$T/home" STEAMOSCTL=/nonexistent sh "$SEL" steam >/dev/null 2>&1
eqv "$?" 2 "steam without steamosctl"

# --- review H2: a switch logs the session out (post_client_shutdown never runs), so leaving GameCove's
# session first puts the everyday values back, releases the charge limit / power-tune values and
# closes Steam, each bounded
LB="$T/leavebin"
mkdir -p "$LB" "$T/lstate/fixes/charge-limit" "$T/lstate/fixes/power-tune/orig"
echo 80 >"$T/lstate/fixes/charge-limit/limit"
printf '#!/bin/sh\necho "app $*" >>"%s/leave.log"\n' "$T" >"$LB/gamecove.x86_64"
printf '#!/bin/sh\necho "pkexec $*" >>"%s/leave.log"\n[ -f "%s/pkexec-hangs" ] && sleep 20\nexit 0\n' "$T" "$T" >"$LB/pkexec"
printf '#!/bin/sh\nexit 0\n' >"$LB/fix-set"
printf '#!/bin/sh\necho "steam $*" >>"%s/leave.log"\n' "$T" >"$LB/steam"
printf '#!/bin/sh\nexit 0\n' >"$LB/pgrep" # Steam runs
cat >"$LB/steamosctl" <<EOF
#!/bin/sh
case "\$1" in switch-*) echo "steamosctl \$*" >>"$T/leave.log" ;; *) exec "$BIN/steamosctl" "\$@" ;; esac
EOF
chmod +x "$LB"/*
leave() { # [env...] -- <target>
	: >"$T/leave.log"
	env PATH="$LB:$BIN:$PATH" HOME="$T/home" XDG_DATA_HOME="$T/home/.local/share" XDG_CONFIG_HOME="$T/home/.config" \
		GAMECOVE_SESSIONS_DIRS="$T/sessions" GAMECOVE_BOOT_ID_FILE="$T/boot_id" GAMECOVE_OSTREE_BOOTED="$T/not-ostree" \
		STEAMOSCTL="$LB/steamosctl" GAMECOVE_BIN="$LB/gamecove.x86_64" GAMECOVE_FIX_SET="$LB/fix-set" PKEXEC="$LB/pkexec" \
		GAMECOVE_STATE_DIR="$T/lstate" GAMECOVE_ROOT_WAIT_S=1 "$@" >"$T/out" 2>&1
}
fresh
leave GAMECOVE_SESSION=1 sh "$SEL" steam
eqv "$(cat "$T/leave.log")" "$(printf '%s\n' "app --headless -- --restore-baseline" \
	"pkexec $LB/fix-set charge-limit set release" "pkexec $LB/fix-set power-tune set restore" \
	"steam -shutdown" "steamosctl switch-to-game-mode")" "leaving for Steam: baseline, root restores, Steam closed, then the switch"
leave GAMECOVE_SESSION=1 sh "$SEL" desktop
has "$T/leave.log" "^app --headless -- --restore-baseline$" "leaving for the desktop restores the baseline too"
eqv "$(tail -n 1 "$T/leave.log")" "steamosctl switch-to-desktop-mode plasma.desktop" "and switches last"
leave sh "$SEL" steam
eqv "$(cat "$T/leave.log")" "steamosctl switch-to-game-mode" "outside GameCove's session (desktop, Steam): only the switch"
touch "$T/pkexec-hangs"
started="$(date +%s)"
leave GAMECOVE_SESSION=1 sh "$SEL" steam
[ $(($(date +%s) - started)) -lt 8 ] && ok || bad "a hung root restore holds the switch up only briefly"
has "$T/leave.log" "^steamosctl switch-to-game-mode$" "the switch still happens"
rm -f "$T/pkexec-hangs"
rm "$LB/gamecove.x86_64"
leave GAMECOVE_SESSION=1 sh "$SEL" steam
has "$T/leave.log" "^steamosctl switch-to-game-mode$" "no GameCove binary: the rest still runs"
hasnt "$T/leave.log" "^app " "no binary, no baseline run"

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
printf '#!/bin/sh\n[ -z "${GAMECOVE_HEARTBEAT:-}" ] || echo "1 ui" >"$GAMECOVE_HEARTBEAT"\nsleep 2.5\nexit 139\n' >"$CB/slowcrash"
chmod +x "$CB/slowcrash"
slow() { # an app that crashes after 2.5 s
	: >"$T/client.log"
	env PATH="$CB:$BIN:$PATH" HOME="$T/home" XDG_DATA_HOME="$T/home/.local/share" GAMECOVE_BIN="$CB/slowcrash" \
		XDG_RUNTIME_DIR="$T/srun" GAMECOVE_STEAM_WAIT_S=0 GAMECOVE_SESSION_SELECT="$CB/select" GAMECOVE_STEAM_MODE=off "$@" sh "$CLIENT" >/dev/null 2>&1
}
mkdir -p "$T/srun"
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

# --- review H1: a hung GameCove (alive, but never ready or its heartbeat stopped) is killed and counted
HR="$T/hrun"
mkdir -p "$HR"
printf '#!/bin/sh\nexec sleep 30\n' >"$CB/hang"
printf '#!/bin/sh\necho "1 ui" >"$GAMECOVE_HEARTBEAT"\nexec sleep 30\n' >"$CB/stale"
printf '#!/bin/sh\necho "1 game" >"$GAMECOVE_HEARTBEAT"\nsleep 4\nexit 0\n' >"$CB/ingame"
printf '#!/bin/sh\ni=0\nwhile [ $i -lt 8 ]; do i=$((i+1)); echo "$i ui" >"$GAMECOVE_HEARTBEAT"; sleep 0.5; done\nexit 0\n' >"$CB/alive"
printf '#!/bin/sh\n: >"$XDG_RUNTIME_DIR/gamecove-steam-ready"\nsleep 4\nexit 0\n' >"$CB/oldapp"
chmod +x "$CB/hang" "$CB/stale" "$CB/ingame" "$CB/alive" "$CB/oldapp"
watch() { # <app> [env...]: prints the client's exit code; never waits more than 20 s
	a="$1"
	shift
	: >"$T/client.log"
	env PATH="$CB:$BIN:$PATH" HOME="$T/home" XDG_DATA_HOME="$T/home/.local/share" XDG_RUNTIME_DIR="$HR" \
		GAMECOVE_BIN="$CB/$a" GAMECOVE_SESSION_SELECT="$CB/select" GAMECOVE_STEAM_MODE=off GAMECOVE_STEAM_WAIT_S=0 \
		GAMECOVE_READY_TIMEOUT_S=2 GAMECOVE_HEARTBEAT_STALE_S=2 "$@" timeout 20 sh "$CLIENT" >/dev/null 2>&1
	echo "$?"
}
fresh
rm -rf "$DATA"
started="$(date +%s)"
code="$(watch hang)"
[ "$code" -ne 0 ] && [ "$code" -ne 124 ] && ok || bad "an app that never gets ready is stopped by the client (exit $code)"
[ $(($(date +%s) - started)) -lt 15 ] && ok || bad "readiness timeout ends a hung start quickly"
eqv "$(cat "$DATA/crash-count" 2>/dev/null)" 1 "a hang at start counts as an unclean exit"
code="$(watch stale)"
[ "$code" -ne 0 ] && [ "$code" -ne 124 ] && ok || bad "a stale heartbeat stops the app (exit $code)"
eqv "$(cat "$DATA/crash-count" 2>/dev/null)" 2 "a stale heartbeat counts as an unclean exit"
watch hang >/dev/null
has "$T/client.log" "^select steam$" "three hangs in a row: switch to Steam Gaming Mode"
eqv "$(sed -n 2p "$DATA/crash-fallback")" hung "fallback says it was hung"
rm -rf "$DATA"
eqv "$(watch ingame)" 0 "an unchanging heartbeat during a game is never a hang (long loads)"
eqv "$(watch alive)" 0 "a beating app runs on"
[ ! -e "$DATA/crash-count" ] && ok || bad "healthy runs count nothing"
# review 2, problem 4: the ready file comes early (Library autoload); a hang before the first
# beat (building the main scene) is a hang, and its healthy time clears nothing
mkdir -p "$DATA"
echo 2 >"$DATA/crash-count"
code="$(watch oldapp GAMECOVE_HEALTHY_S=1)"
[ "$code" -ne 0 ] && [ "$code" -ne 124 ] && ok || bad "ready file but no heartbeat: stopped as not ready (exit $code)"
has "$T/client.log" "^select steam$" "and counted (third in a row): the count wasn't cleared"
rm -rf "$DATA"
[ ! -e "$HR/gamecove-heartbeat" ] && ok || bad "heartbeat file removed when the app is gone"

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
