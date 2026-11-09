#!/bin/sh
# Is GameCove installed the way this OS needs it? Files, package, polkit, logs.
# Read-only. GAMECOVE_EXPECT_TAG=v0.1.0 also checks the release that was installed.
. "$(dirname "$0")/lib.sh"

if ! exists /usr/lib/gamecove/gamecove.x86_64; then
	skip installed "GameCove isn't in /usr (not installed, or staged for the next boot)"
	if have rpm-ostree && rpm-ostree status 2>/dev/null | grep -q gamecove; then
		info staged "rpm-ostree has GameCove in a deployment: restart to finish"
	fi
	exit 0
fi
pass installed "/usr/lib/gamecove/gamecove.x86_64 present"
for f in /usr/lib/gamecove/gamecove.pck /usr/bin/gamecove-session-select /usr/bin/gamecove-selftest \
	/usr/libexec/gamecove/gamecove-fix /usr/libexec/gamecove/gamecove-fix-set /usr/libexec/gamecove/gamecove-session-client \
	/usr/libexec/gamecove/gamecove-apply-choices /usr/share/wayland-sessions/gamecove.desktop \
	/usr/share/gamescope-session-plus/sessions.d/gamecove /usr/share/polkit-1/actions/io.github.ihulksmashi.gamecove.policy; do
	if exists "$f"; then pass "file.$(basename "$f")" "$f"; else fail "file.$(basename "$f")" "missing: $f"; fi
done
exists /usr/bin/gamescope-session-plus && pass session-plus "gamescope-session-plus present" ||
	fail session-plus "gamescope-session-plus missing (bundled in the sysext / a package dependency)"
exists /usr/lib/systemd/user/gamescope-session-plus@.service && pass session-unit "gamescope-session-plus@.service present" ||
	fail session-unit "gamescope-session-plus@.service missing"
have xprop && pass xprop "xprop present (gamescope atoms)" || fail xprop "xprop missing: GameCove can't talk to gamescope"

case "$(os_id)" in
steamos)
	link="$GC_ROOT/etc/extensions/gamecove.raw"
	if [ -L "$link" ]; then
		tgt="$(readlink "$link")"
		pass sysext.link "/etc/extensions/gamecove.raw -> $tgt"
		case "$tgt" in /home/.steamos/offload/gamecove/*) pass sysext.store "image on /home (survives updates, not in the small /var)" ;;
		*) warn sysext.store "image at $tgt" ;; esac
		owner="$(stat -c %U "$GC_ROOT$tgt" 2>/dev/null)"
		[ "$owner" = root ] && pass sysext.owner "image root-owned" || fail sysext.owner "image owned by ${owner:-?}: must be root (it carries the polkit policy)"
	elif exists /var/lib/extensions/gamecove.raw; then
		warn sysext.link "image in /var/lib/extensions (older installer): lost at the next SteamOS update"
	else
		fail sysext.link "no gamecove.raw in /etc/extensions or /var/lib/extensions"
	fi
	keep="$GC_ROOT/etc/atomic-update.conf.d/gamecove.conf"
	if grep -qx /etc/extensions/gamecove.raw "$keep" 2>/dev/null &&
		grep -qx /etc/systemd/system/sysinit.target.wants/systemd-sysext.service "$keep"; then
		pass sysext.keep "keep list holds the link and systemd-sysext's enable link"
	else
		fail sysext.keep "keep list $keep missing or incomplete"
	fi
	[ "$("$GC_SYSTEMCTL" is-enabled systemd-sysext.service 2>/dev/null)" = enabled ] &&
		pass sysext.enabled "systemd-sysext.service enabled" || fail sysext.enabled "systemd-sysext.service not enabled: GameCove is gone after a restart"
	if have systemd-sysext; then
		systemd-sysext status >"$CHECK_OUT/sysext-status.txt" 2>&1
		grep -q gamecove "$CHECK_OUT/sysext-status.txt" && pass sysext.merged "merged into /usr" || fail sysext.merged "not merged (systemd-sysext status)"
	fi
	if have steamos-readonly; then
		ro="$(steamos-readonly status 2>/dev/null | head -n 1)"
		[ "$ro" = enabled ] && pass readonly "steamos-readonly still enabled (GameCove never turns it off)" ||
			warn readonly "steamos-readonly is '$ro' (GameCove doesn't need it off)"
	fi
	have rpm-ostree && fail no-rpm-ostree "rpm-ostree on SteamOS?" || pass no-rpm-ostree "no rpm-ostree (expected on SteamOS)"
	;;
bazzite | *)
	if have rpm-ostree; then
		rpm-ostree status >"$CHECK_OUT/rpm-ostree-status.txt" 2>&1
		grep -q "gamecove" "$CHECK_OUT/rpm-ostree-status.txt" && pass layered "GameCove layered (rpm-ostree status)" ||
			warn layered "rpm-ostree status doesn't list gamecove (installed another way?)"
	fi
	;;
esac

if have pkaction; then
	for a in io.github.ihulksmashi.gamecove.fix-set io.github.ihulksmashi.gamecove.fix; do
		if pkaction --action-id "$a" --verbose >"$CHECK_OUT/$a.txt" 2>&1; then
			pass "polkit.$a" "loaded"
		else
			fail "polkit.$a" "not loaded: restart once (polkit picks the policy up at boot)"
		fi
	done
	grep -q "implicit active:.*yes" "$CHECK_OUT/io.github.ihulksmashi.gamecove.fix-set.txt" 2>/dev/null &&
		pass polkit.fix-set-free "fix-set is prompt-free for the active session" || warn polkit.fix-set-free "fix-set isn't 'yes' for the active session"
fi
if [ -n "${GAMECOVE_EXPECT_TAG:-}" ]; then
	got="$(sed -n 's/^TAG=//p' "$GC_DATA/installer/release.env" 2>/dev/null)"
	[ "$got" = "$GAMECOVE_EXPECT_TAG" ] && pass release "installed release $got" || fail release "release.env says '${got:-none}', expected $GAMECOVE_EXPECT_TAG"
fi
sig="$(sed -n 's/^SIGNATURE=//p' "$GC_DATA/installer/release.env" 2>/dev/null)"
[ -n "$sig" ] && { [ "$sig" = verified ] && pass signature "release signature verified" || warn signature "release signature: $sig"; }
if [ -f "$GC_DATA/installer.log" ]; then
	cp "$GC_DATA/installer.log" "$CHECK_OUT/installer.log"
	n="$(grep -c -i -E 'failed|error' "$GC_DATA/installer.log")"
	[ "$n" -eq 0 ] && pass installer-log "installer.log has no failures" || warn installer-log "installer.log has $n failed/error lines (see installer.log)"
fi
