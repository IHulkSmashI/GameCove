#!/bin/sh
# GameCove fix (optional): steamos-manager stops flooding the system log with split-lock lines.
# usage: fix.sh install|remove|status|set on|off
#
# On SteamOS, steamos-manager's root daemon reads the kernel's split-lock trace and hands each hit to
# Valve's crash reporter (steamos-log-submitter). Bazzite ships the daemon but not the reporter, so
# every hit fails and both the hit and the failure land in the journal. Steam's own network threads trip
# it constantly (ClawDeck, measured on a Claw 8 EX on 2026-11-04: about 70,000 lines in the first five
# minutes, about 14 % of a CPU core). The journal is capped, so within minutes it erases every earlier
# boot, including the log of a crash or a sleep that didn't wake.
#
# One systemd drop-in turns off only that module's logging (RUST_LOG=info,steamos_manager::sls=off);
# everything else steamos-manager logs stays. Never needed where the reporter is installed (SteamOS),
# and os-fixed when another drop-in (not ours) already silences the module. Ported from ClawDeck's
# py_modules/clawdeck/quietlog.py (same author).
set -eu
NAME=journal-flood
DEVICES="@"  # fixes/lib/fix-devices.txt, from the trait selectors in app/data/fixes.json
DROPIN_DIR=/etc/systemd/system/steamos-manager.service.d
DROPIN="$DROPIN_DIR/50-gamecove-quiet-split-lock.conf"
FILES="$DROPIN"
RELOAD=""
UNIT_DIRS="/usr/lib/systemd/system /etc/systemd/system /lib/systemd/system"
# shellcheck source=fixes/lib/gcfix.sh
. "$(cd "$(dirname "$0")/../lib" && pwd)/gcfix.sh"

file_text() {
	cat <<EOF
$GC_MARK
# steamos-manager forwards every split-lock hit to steamos-log-submitter, which this system doesn't have;
# the failures flood the journal. Only the forwarding module is silenced.
# Remove with: gamecove-fix $NAME remove
[Service]
Environment=RUST_LOG=info,steamos_manager::sls=off
EOF
}

unit_present() {
	for _u in $UNIT_DIRS; do
		[ -e "$ROOT$_u/$1" ] && return 0
	done
	return 1
}

# The part this fix is for: steamos-manager without Valve's reporter.
hw_present() { unit_present steamos-manager.service && ! unit_present steamos-log-submitter.service; }

# Another drop-in (not ours) already turns the forwarding module's log off.
os_fixed() {
	for _d in /usr/lib/systemd/system/steamos-manager.service.d /etc/systemd/system/steamos-manager.service.d; do
		for _f in "$ROOT$_d"/*.conf; do
			[ -f "$_f" ] || continue
			head -n 1 "$_f" | grep -qxF "$GC_MARK" && continue
			grep -q 'steamos_manager::sls=off' "$_f" && return 0
		done
	done
	return 1
}

# systemd reads the drop-in at the next daemon-reload; steamos-manager picks it up when restarted
# (try-restart: only if it runs). Without systemd (tests) nothing to do.
gc_systemd_reload() {
	command -v systemctl >/dev/null 2>&1 || return 0
	systemctl daemon-reload >/dev/null 2>&1 || return 1
	systemctl try-restart steamos-manager.service >/dev/null 2>&1 || return 1
}
apply_now() { gc_systemd_reload; }
revert_now() { gc_systemd_reload || printf 'warning: steamos-manager keeps the old setting until it restarts\n' >&2; }

gc_main "$@"
