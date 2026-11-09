#!/bin/sh
# After the installer's Uninstall: nothing of GameCove left that matters. Skips while it's
# still installed. Read-only.
. "$(dirname "$0")/lib.sh"
if exists /usr/lib/gamecove/gamecove.x86_64; then
	skip uninstalled "GameCove is still in /usr (Bazzite: until the restart; run this after it)"
	exit 0
fi
pass package "GameCove gone from /usr"
for f in /etc/extensions/gamecove.raw /var/lib/extensions/gamecove.raw /etc/atomic-update.conf.d/gamecove.conf /home/.steamos/offload/gamecove/gamecove.raw; do
	exists "$f" && fail "left.$(basename "$f")" "still there: $f" || pass "left.$(basename "$f")" "$f gone"
done
if have "$GC_STEAMOSCTL"; then
	desk="$("$GC_STEAMOSCTL" get-default-desktop-session 2>/dev/null)"
	mode="$("$GC_STEAMOSCTL" get-default-login-mode 2>/dev/null)"
	[ "$desk" != gamecove.desktop ] && pass desktop "default desktop session: ${desk:-?}" || fail desktop "default desktop session still gamecove.desktop"
	[ "$mode" = game ] && pass login-mode "boots into Steam Gaming Mode" || warn login-mode "default login mode: ${mode:-?}"
fi
for f in "$GC_HOME/.config/systemd/user/gamecove-session-guard.service" "$GC_HOME/.config/systemd/user/gamecove-apply-choices.service" \
	"$GC_HOME/.local/share/applications/io.github.ihulksmashi.GameCoveSwitch.desktop" \
	"$GC_HOME/.local/share/applications/io.github.ihulksmashi.GameCoveWindow.desktop" \
	"$GC_HOME/.config/autostart/io.github.ihulksmashi.GameCoveFinish.desktop" \
	"$GC_HOME/.config/environment.d/gamecove.conf" "$GC_DATA/pending-choices"; do
	[ -e "$f" ] && fail "user.$(basename "$f")" "left: $f" || pass "user.$(basename "$f")" "gone"
done
if [ -d "$GC_ROOT/var/lib/gamecove/fixes" ]; then
	n="$(find "$GC_ROOT/var/lib/gamecove/fixes" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
	[ "$n" -eq 0 ] && pass fixes "no fix state left" || warn fixes "$n fix state folder(s) left in /var/lib/gamecove/fixes"
fi
for p in "$GC_HOME"/.local/share/Steam/userdata/*/config/localconfig.vdf; do
	[ -f "$p" ] && grep -q gamecove-run "$p" && fail steam-launch "a Steam game's launch options still call gamecove-run"
done
manual boot "Restart: the handheld boots into Steam Gaming Mode; Steam's Switch to Desktop reaches Plasma"
