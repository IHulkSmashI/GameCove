#!/bin/sh
# gamecove-testbed: get one external Bazzite SSD ready for testing GameCove on
# several handhelds, one device at a time.
#
#   sh gamecove-testbed.sh prepare        once per SSD: tools, repo, terminal link
#   sh gamecove-testbed.sh console        start the browser terminal (127.0.0.1:7681)
#   sh gamecove-testbed.sh status         which device this is and what's installed
#   sh gamecove-testbed.sh report         save logs + self-test for this device
#   sh gamecove-testbed.sh reset [--full] [--yes]
#                                         before moving the SSD to the next device:
#                                         save a report, remove this device's fixes,
#                                         check nothing device-specific is left.
#                                         --full also uninstalls GameCove so the next
#                                         device gets a from-scratch install test.
#
# Run it in Desktop Mode (Konsole). Anything that needs root asks for your
# password through pkexec; this script never stores or types a password.
# Every step is printed and logged to ~/gamecove-tests/testbed.log.
set -eu

TTYD_VERSION=1.7.7
TTYD_SHA256=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55
TTYD_URL="https://github.com/tsl0922/ttyd/releases/download/$TTYD_VERSION/ttyd.x86_64"
REPO_URL="https://github.com/IHulkSmashI/GameCove.git"
PORT=7681

# Overridable for tests.
HOME_DIR="${GAMECOVE_TESTBED_HOME:-$HOME}"
DMI_DIR="${GAMECOVE_TESTBED_DMI:-/sys/class/dmi/id}"
FIX="${GAMECOVE_TESTBED_FIX:-/usr/libexec/gamecove/gamecove-fix}"
PKEXEC="${GAMECOVE_TESTBED_PKEXEC:-pkexec}"
RPM_OSTREE="${GAMECOVE_TESTBED_RPM_OSTREE:-rpm-ostree}"
SELFTEST="${GAMECOVE_TESTBED_SELFTEST:-gamecove-selftest}"

BIN="$HOME_DIR/.local/bin"
TESTS="$HOME_DIR/gamecove-tests"
SRC="$HOME_DIR/src/GameCove"
LOG="$TESTS/testbed.log"

say() { printf '%s\n' "$*"; mkdir -p "$TESTS"; printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"; }
die() { say "error: $*"; exit 1; }

dmi() { tr -d '\n' <"$DMI_DIR/$1" 2>/dev/null || true; }

# A short, file-name-safe device name, e.g. "msi-claw-8-ex-ai" or "asus-rog-ally-rc71l".
device_slug() {
	s="$(dmi sys_vendor) $(dmi product_name)"
	[ "$s" = " " ] && s="unknown-device"
	printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//' | cut -c1-48
}

confirm() {
	[ "${YES:-0}" = 1 ] && return 0
	printf '%s [y/N] ' "$1"
	read -r a || a=""
	[ "$a" = y ] || [ "$a" = Y ]
}

fix_list() { [ -x "$FIX" ] && "$FIX" --list 2>/dev/null || true; }

fix_installed() {
	"$FIX" "$1" status 2>/dev/null | grep -q '^installed=yes$'
}

# --------------------------------------------------------------------- prepare
cmd_prepare() {
	mkdir -p "$BIN" "$TESTS" "$HOME_DIR/src"
	if [ -x "$BIN/ttyd" ] && echo "$TTYD_SHA256  $BIN/ttyd" | sha256sum -c - >/dev/null 2>&1; then
		say "ttyd $TTYD_VERSION already in place"
	else
		say "downloading ttyd $TTYD_VERSION (browser terminal) and checking its sha256"
		tmp="$BIN/.ttyd.part"
		curl -fsSL -o "$tmp" "$TTYD_URL"
		echo "$TTYD_SHA256  $tmp" | sha256sum -c - >/dev/null || { rm -f "$tmp"; die "ttyd download didn't match its checksum"; }
		chmod +x "$tmp" && mv "$tmp" "$BIN/ttyd"
	fi
	if [ -d "$SRC/.git" ]; then
		say "updating the GameCove source in $SRC"
		git -C "$SRC" pull --ff-only -q || say "note: couldn't fast-forward $SRC; left as is"
	else
		say "cloning GameCove into $SRC"
		git clone -q "$REPO_URL" "$SRC"
	fi
	if command -v flatpak >/dev/null 2>&1 && ! flatpak info com.google.Chrome >/dev/null 2>&1 && ! command -v google-chrome >/dev/null 2>&1; then
		say "Chrome isn't installed. Install it from Discover (Google Chrome), sign in, and add the Claude extension."
	fi
	say "ready. Next: sh $0 console, then open Chrome on this handheld and tell Claude 'go'."
}

# --------------------------------------------------------------------- console
cmd_console() {
	[ -x "$BIN/ttyd" ] || die "run 'prepare' first"
	say "terminal link on http://127.0.0.1:$PORT (this handheld only). Leave this window open; Ctrl+C to stop."
	exec "$BIN/ttyd" -i 127.0.0.1 -p "$PORT" -W bash
}

# ---------------------------------------------------------------------- status
cmd_status() {
	say "device: $(dmi sys_vendor) $(dmi product_name) (board $(dmi board_name))"
	if command -v gamecove-session-select >/dev/null 2>&1 || [ -x "$FIX" ]; then
		say "GameCove: installed"
	else
		say "GameCove: not installed"
	fi
	for f in $(fix_list); do
		if fix_installed "$f"; then say "fix $f: installed"; else say "fix $f: not installed"; fi
	done
	if command -v "$RPM_OSTREE" >/dev/null 2>&1; then
		k="$("$RPM_OSTREE" kargs 2>/dev/null || true)"
		case "$k" in
		*edid_firmware* | *firmware_class.path*) say "boot settings: device-specific kernel arguments present: $k" ;;
		*) say "boot settings: no device-specific kernel arguments" ;;
		esac
	fi
}

# ---------------------------------------------------------------------- report
cmd_report() {
	dir="$TESTS/$(date +%Y%m%d-%H%M)-$(device_slug)"
	mkdir -p "$dir"
	cmd_status >"$dir/status.txt" 2>&1 || true
	for f in "$HOME_DIR/.local/share/gamecove/"*.log /var/lib/gamecove/changes.log; do
		[ -f "$f" ] && cp "$f" "$dir/" 2>/dev/null || true
	done
	if command -v "$SELFTEST" >/dev/null 2>&1; then
		say "running the self-test (automatic checks only; run it with --interactive yourself for the button tests)"
		"$SELFTEST" >"$dir/selftest.txt" 2>&1 || true
	fi
	journalctl --user -b --no-pager -n 400 2>/dev/null | grep -i -E 'gamecove|gamescope|inputplumber|hhd' >"$dir/journal-user.txt" 2>/dev/null || true
	say "report saved in $dir"
}

# ----------------------------------------------------------------------- reset
cmd_reset() {
	full=0
	for a in "$@"; do
		case "$a" in
		--full) full=1 ;;
		--yes) YES=1 ;;
		*) die "unknown option: $a" ;;
		esac
	done
	say "== reset on $(device_slug)"
	cmd_report
	removed=0
	for f in $(fix_list); do
		case "$f" in
		fan | charge-limit) continue ;; # settings, not boot changes; GameCove stores them per device
		esac
		if fix_installed "$f"; then
			if confirm "Remove the $f fix from this install (it's specific to this device)?"; then
				say "removing $f (asks for your password)"
				"$PKEXEC" "$FIX" "$f" remove || die "removing $f failed; see the message above, then run reset again"
				removed=$((removed + 1))
			fi
		fi
	done
	[ "$removed" -gt 0 ] && say "$removed fix(es) removed"
	if [ "$full" = 1 ]; then
		if confirm "Uninstall GameCove completely so the next device gets a fresh install test?"; then
			if [ -x "$HOME_DIR/.local/share/gamecove/installer/gamecove.x86_64" ]; then
				say "running the GameCove installer's uninstall"
				"$HOME_DIR/.local/share/gamecove/installer/gamecove.x86_64" -- --installer --uninstall || say "note: installer uninstall reported a problem"
			elif command -v "$RPM_OSTREE" >/dev/null 2>&1; then
				say "removing the GameCove package (asks for your password)"
				"$PKEXEC" "$RPM_OSTREE" uninstall gamecove || say "note: rpm-ostree uninstall reported a problem"
			fi
		fi
	fi
	left=0
	for f in $(fix_list); do
		case "$f" in fan | charge-limit) continue ;; esac
		if fix_installed "$f"; then say "still installed: $f"; left=1; fi
	done
	if command -v "$RPM_OSTREE" >/dev/null 2>&1; then
		case "$("$RPM_OSTREE" kargs 2>/dev/null || true)" in
		*edid_firmware*) say "still present: an EDID override kernel argument"; left=1 ;;
		esac
	fi
	if [ "$left" = 0 ]; then
		say "clean. If a fix was removed, restart once here, then shut down and move the SSD to the next handheld."
	else
		say "not clean yet: see above. Fix it before moving the SSD."
		exit 2
	fi
}

case "${1:-}" in
prepare) cmd_prepare ;;
console) cmd_console ;;
status) cmd_status ;;
report) cmd_report ;;
reset) shift; cmd_reset "$@" ;;
*)
	sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
	exit 64
	;;
esac
