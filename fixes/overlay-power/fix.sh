#!/bin/sh
# GameCove fix (optional): real watts in the performance overlay on Intel handhelds.
# usage: fix.sh install|remove|status|set on|off
#
# The overlay (mangoapp / MangoHud, and GameCove's own power reading) runs as the desktop user and reads
# the chip's RAPL package energy counter (energy_uj) for CPU watts. Since 2020 Linux makes it root-only
# (0400, the PLATYPUS power side channel, CVE-2020-8694), so on a stock Intel handheld the overlay shows
# 0.0 W. This makes the package counters readable by everyone (0444) at once and at every boot, through a
# systemd-tmpfiles rule: mangoapp checks the counter once when Game Mode starts, so the rule has to open it
# before the session. remove deletes the rule and puts each counter's mode back (0400). On the Claw 8 EX
# the package domain covers CPU and graphics together (xe has no separate GPU power sensor there).
# Ported from ClawDeck's py_modules/clawdeck/telemetry.py (same author). Its other finding, the Claw 8
# EX battery reporting current_now about 100 times too high, is handled where GameCove reads it
# (perf/sources.gd battery_watts, device.gd battery).
#
# The trade-off is the reason the kernel closed it: any local program can then sample the power counter.
# Optional for that reason, never automatic.
set -eu
NAME=overlay-power
DEVICES="@"  # fixes/lib/fix-devices.txt, from the trait selectors in app/data/fixes.json
RULE=/etc/tmpfiles.d/gamecove-overlay-power.conf
FILES="$RULE"
RELOAD=""
POWERCAP=/sys/class/powercap
# package domains only: core / uncore / dram sub-domains are not what the overlay shows
DOMAINS="intel-rapl:0 intel-rapl-mmio:0"
# shellcheck source=fixes/lib/gcfix.sh
. "$(cd "$(dirname "$0")/../lib" && pwd)/gcfix.sh"

file_text() {
	cat <<EOF
$GC_MARK
# Watts in the performance overlay: the RAPL package energy counters readable by everyone from boot.
# Remove with: gamecove-fix $NAME remove
EOF
	for _d in $DOMAINS; do
		printf 'z %s/%s/energy_uj 0444 - - -\n' "$POWERCAP" "$_d"
	done
}

# The package counters on this machine (real paths), one per line.
counters() {
	for _d in $DOMAINS; do
		[ -e "$ROOT$POWERCAP/$_d/energy_uj" ] && printf '%s\n' "$POWERCAP/$_d/energy_uj"
	done
	return 0
}

mode_of() { stat -c %a "$ROOT$1" 2>/dev/null; }

hw_present() { [ -n "$(counters)" ]; }

# The system opens them itself: another tmpfiles rule (not ours) for energy_uj with a world-readable mode,
# or, without GameCove's rule, every counter already readable by everyone.
os_fixed() {
	for _t in /usr/lib/tmpfiles.d /etc/tmpfiles.d /run/tmpfiles.d; do
		for _f in "$ROOT$_t"/*.conf; do
			[ -f "$_f" ] || continue
			head -n 1 "$_f" | grep -qxF "$GC_MARK" && continue
			grep -Eq '^[zZ][[:space:]]+[^[:space:]]*intel-rapl[^[:space:]]*energy_uj[[:space:]]+0?[0-7][0-7][4-7]' "$_f" && return 0
		done
	done
	gc_installed && return 1
	_n=0
	for _c in $(counters); do
		_m=$(mode_of "$_c")
		[ -n "$_m" ] || return 1
		[ $((0$_m & 4)) -ne 0 ] || return 1
		_n=$((_n + 1))
	done
	[ "$_n" -gt 0 ]
}

apply_now() {
	mkdir -p "$STATE"
	_rc=0
	for _c in $(counters); do
		grep -q "^$_c=" "$STATE/modes" 2>/dev/null || printf '%s=%s\n' "$_c" "$(mode_of "$_c")" >>"$STATE/modes"
		chmod 0444 "$ROOT$_c" 2>/dev/null || _rc=1
	done
	return "$_rc"
}

revert_now() {
	for _c in $(counters); do
		_m=$(sed -n "s|^$_c=||p" "$STATE/modes" 2>/dev/null | head -n 1)
		chmod "0${_m:-400}" "$ROOT$_c" 2>/dev/null || printf 'warning: %s keeps its mode until the next boot\n' "$_c" >&2
	done
	rm -f "$STATE/modes"
}

gc_main "$@"
