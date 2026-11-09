#!/bin/sh
# Sessions: steamos-manager sees GameCove, defaults before/after "Boot into GameCove",
# the login guard, which session runs now. Read-only (switching is the owner's step).
. "$(dirname "$0")/lib.sh"

if ! have "$GC_STEAMOSCTL"; then
	fail steamosctl "steamosctl (steamos-manager) missing: GameCove can't switch sessions"
	exit 0
fi
sessions="$("$GC_STEAMOSCTL" get-valid-desktop-sessions 2>&1)"
printf '%s\n' "$sessions" >"$CHECK_OUT/valid-desktop-sessions.txt"
if printf '%s\n' "$sessions" | grep -qx -- '- gamecove.desktop'; then
	pass valid "steamos-manager lists gamecove.desktop"
elif exists /usr/share/wayland-sessions/gamecove.desktop; then
	fail valid "gamecove.desktop installed but steamos-manager doesn't list it (old steamos-manager without SessionManagement1?)"
else
	skip valid "GameCove isn't installed"
fi
mode="$("$GC_STEAMOSCTL" get-default-login-mode 2>/dev/null)"
desk="$("$GC_STEAMOSCTL" get-default-desktop-session 2>/dev/null)"
info defaults "login mode '${mode:-?}', default desktop session '${desk:-?}'"
prev="$(head -n 1 "$GC_DATA/prev-desktop-session" 2>/dev/null)"
if [ "$desk" = gamecove.desktop ]; then
	[ -n "$prev" ] && pass saved-desktop "boots into GameCove; the real desktop ($prev) is saved" ||
		fail saved-desktop "GameCove is the default desktop session but nothing saved the real one"
	[ -f "$GC_HOME/.config/systemd/user/gamecove-session-guard.service" ] && pass guard "login guard installed" ||
		fail guard "no gamecove-session-guard.service: an uninstall could leave the default pointing at a missing session"
fi
active="$("$GC_SYSTEMCTL" --user list-units --state=active --no-legend --plain 'gamescope-session*' 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
info running "${active:-no gamescope session (Desktop Mode)}"
case "$active" in *gamescope-session-plus@gamecove*) pass in-gamecove "GameCove's session is running" ;; esac
if [ -f "$GC_DATA/crash-starts" ]; then
	warn crashes "crash-starts has $(wc -l <"$GC_DATA/crash-starts") entr(ies): GameCove crashed recently"
fi
manual switch.to-gamecove "From Desktop Mode: 'GameCove' (app entry or 'gamecove-session-select gamecove'): GameCove appears within ~10 s, no black screen"
manual switch.to-desktop "Quick menu > Switch to Desktop Mode: lands in Plasma, not back in GameCove"
manual switch.to-steam "Quick menu > Steam Gaming Mode, then Steam's own 'Switch to Desktop': Plasma (not GameCove)"
manual switch.back "From Steam Gaming Mode back to GameCove (GameCove app entry in Steam or the power menu)"
