#!/bin/sh
# gamecove-testbed: get handhelds ready for testing GameCove on real hardware, one
# device at a time (an external Bazzite SSD moved between handhelds, or a handheld's
# own SteamOS install). docs/TESTING-HARDWARE.md is the test plan.
#
#   sh gamecove-testbed.sh prepare        once per drive: tools, repo, terminal link
#   sh gamecove-testbed.sh console [--keep]
#                                         start the browser terminal (127.0.0.1:7681 under a
#                                         random path). --keep runs it as a temporary user unit
#                                         so it stays up while you switch to GameCove or Steam
#                                         Gaming Mode and back (still gone at reboot)
#   sh gamecove-testbed.sh console-stop   stop it (reset does this too)
#   sh gamecove-testbed.sh status         which device and OS this is and what's installed
#   sh gamecove-testbed.sh install [tag]  run the real installer (get-gamecove.sh + the
#                                         installer app) for a release, logging everything.
#                                         tag: the argument, else $GAMECOVE_TAG, else the newest
#                                         release including pre-releases (releases/latest skips them)
#   sh gamecove-testbed.sh uninstall      open the installer to uninstall (you pick Uninstall), logged
#   sh gamecove-testbed.sh check [--detach] [name...]
#                                         run the machine checks in checks/ (all when no name);
#                                         results in ~/gamecove-tests/results/<device>/
#   sh gamecove-testbed.sh results        print every check result for this device
#   sh gamecove-testbed.sh note <check.item> pass|fail|warn|skip <text>
#                                         record the owner's answer to a hands-on step
#   sh gamecove-testbed.sh report         one bundle for this device: logs, self-test, check
#                                         results, versions (no secrets); prints where it is
#   sh gamecove-testbed.sh reset [--full] [--yes]
#                                         before moving the drive to the next device:
#                                         save a report, remove this device's fixes,
#                                         check nothing device-specific is left.
#                                         --full also uninstalls GameCove so the next
#                                         device gets a from-scratch install test.
#
# Run it in Desktop Mode (Konsole). Anything that needs root asks for your
# password through pkexec; this script never stores or types a password.
#
# The browser terminal (review S3-1) is a writable shell, so: it listens on
# 127.0.0.1 only, refuses WebSocket connections from any other origin
# (--check-origin: another web page open in Chrome can't drive it), and is
# served under an unguessable random path (ttyd -b /<128-bit token>) that
# `console` prints and keeps in ~/gamecove-tests/console-url (mode 600). No
# password prompt (Claude drives it through the browser and can't type one).
# It runs only while `console` does (or, with --keep, as a transient user unit
# that `console-stop` / `reset` stop): never an installed service, gone at reboot.
# Every step is printed and logged to ~/gamecove-tests/testbed.log.
set -eu

TTYD_VERSION=1.7.7
TTYD_SHA256=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55
TTYD_URL="https://github.com/tsl0922/ttyd/releases/download/$TTYD_VERSION/ttyd.x86_64"
REPO="${GAMECOVE_REPO:-IHulkSmashI/GameCove}"
REPO_URL="https://github.com/$REPO.git"
# The source the checks come from: a branch or tag (use the release tag under test).
REF="${GAMECOVE_TESTBED_REF:-main}"
PORT=7681
CONSOLE_UNIT=gamecove-testbed-console

# Overridable for tests.
HOME_DIR="${GAMECOVE_TESTBED_HOME:-$HOME}"
DMI_DIR="${GAMECOVE_TESTBED_DMI:-/sys/class/dmi/id}"
OS_RELEASE="${GAMECOVE_TESTBED_OS_RELEASE:-/etc/os-release}"
FIX="${GAMECOVE_TESTBED_FIX:-/usr/libexec/gamecove/gamecove-fix}"
PKEXEC="${GAMECOVE_TESTBED_PKEXEC:-pkexec}"
RPM_OSTREE="${GAMECOVE_TESTBED_RPM_OSTREE:-rpm-ostree}"
SELFTEST="${GAMECOVE_TESTBED_SELFTEST:-gamecove-selftest}"
CURL="${GAMECOVE_TESTBED_CURL:-curl}"
API="${GAMECOVE_API:-https://api.github.com}"
RAW="${GAMECOVE_TESTBED_RAW:-https://raw.githubusercontent.com}"
SYSTEMD_RUN="${GAMECOVE_TESTBED_SYSTEMD_RUN:-systemd-run}"
SYSTEMCTL="${GAMECOVE_TESTBED_SYSTEMCTL:-systemctl}"
SYSEXT="${GAMECOVE_TESTBED_SYSEXT:-systemd-sysext}"
READONLY="${GAMECOVE_TESTBED_READONLY:-steamos-readonly}"
GET_SCRIPT="${GAMECOVE_TESTBED_GET:-}"     # a local get-gamecove.sh instead of the tag's
ETC="${GAMECOVE_TESTBED_ETC:-/etc}"

BIN="$HOME_DIR/.local/bin"
TESTS="$HOME_DIR/gamecove-tests"
SRC="$HOME_DIR/src/GameCove"
LOG="$TESTS/testbed.log"
GC_DATA="$HOME_DIR/.local/share/gamecove"
# The checks: next to this script (the repo copy), else in the prepared source.
CHECKS="${GAMECOVE_TESTBED_CHECKS:-}"
if [ -z "$CHECKS" ]; then
	CHECKS="$(cd "$(dirname "$0")" && pwd)/checks"
	[ -f "$CHECKS/lib.sh" ] || CHECKS="$SRC/tools/testbed/checks"
fi
INSTALLER_APP="$GC_DATA/installer/app/gamecove.x86_64"

say() { printf '%s\n' "$*"; mkdir -p "$TESTS"; printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"; }
die() { say "error: $*"; exit 1; }

dmi() { tr -d '\n' 2>/dev/null <"$DMI_DIR/$1" || true; }

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

os_field() { sed -n "s/^$1=//p" "$OS_RELEASE" 2>/dev/null | tr -d '"' | head -n 1; }
os_id() { i="$(os_field ID)"; printf '%s' "${i:-unknown}"; }

# Writes "$ <command>" and everything it prints (stdout and stderr) to the log as well as
# the screen; returns the command's exit code.
run_logged() {
	rl_log="$1"
	shift
	printf '$ %s\n' "$*" >>"$rl_log"
	rl_rc="$rl_log.rc"
	{
		rc=0
		"$@" || rc=$?
		echo "$rc" >"$rl_rc"
	} 2>&1 | tee -a "$rl_log"
	rc="$(cat "$rl_rc" 2>/dev/null || echo 1)"
	rm -f "$rl_rc"
	return "$rc"
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
		say "updating the GameCove source in $SRC ($REF)"
		git -C "$SRC" fetch -q --tags origin 2>/dev/null || true
		git -C "$SRC" checkout -q "$REF" 2>/dev/null || say "note: couldn't check out $REF in $SRC"
		git -C "$SRC" pull --ff-only -q 2>/dev/null || true
	elif command -v git >/dev/null 2>&1; then
		say "cloning GameCove ($REF) into $SRC"
		git clone -q "$REPO_URL" "$SRC"
		git -C "$SRC" checkout -q "$REF" || die "no branch or tag $REF in $REPO"
	else
		# SteamOS may not have git: the same tree as a tarball
		say "git isn't installed; downloading GameCove ($REF) as a tarball into $SRC"
		mkdir -p "$SRC"
		"$CURL" -fsSL "https://codeload.github.com/$REPO/tar.gz/$REF" | tar -xz -C "$SRC" --strip-components=1 ||
			die "couldn't download the GameCove source ($REF)"
	fi
	say "this is $(os_field PRETTY_NAME) on $(dmi sys_vendor) $(dmi product_name)"
	if command -v flatpak >/dev/null 2>&1 && ! flatpak info com.google.Chrome >/dev/null 2>&1 && ! command -v google-chrome >/dev/null 2>&1; then
		say "Chrome isn't installed. Install it from Discover (Google Chrome, a Flatpak on Bazzite and SteamOS), sign in, and add the Claude extension."
	fi
	say "ready. Next: sh $0 console --keep, then open Chrome on this handheld and tell Claude 'go'."
}

# --------------------------------------------------------------------- console
PIDFILE="$TESTS/ttyd.pid"
URLFILE="$TESTS/console-url"

# 32 hex digits (128 bits) from the kernel's random source.
random_token() {
	od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}

cmd_console() {
	keep=0
	for a in "$@"; do
		case "$a" in
		--keep) keep=1 ;;
		*) die "unknown option: $a" ;;
		esac
	done
	[ -x "$BIN/ttyd" ] || die "run 'prepare' first"
	stop_console
	token="$(random_token)"
	[ "${#token}" -eq 32 ] || die "couldn't make a random path"
	url="http://127.0.0.1:$PORT/$token/"
	mkdir -p "$TESTS"
	(umask 077 && printf '%s\n' "$url" >"$URLFILE")
	if [ "$keep" = 1 ]; then
		# A transient user unit: outlives this window and a switch between GameCove, Steam
		# Gaming Mode and the desktop (the user manager stays while the next session logs in),
		# never written to disk, gone at reboot. Same ttyd options.
		envs=""
		for v in DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS PATH; do
			eval "val=\${$v:-}"
			[ -n "$val" ] && envs="$envs --setenv=$v"
		done
		# shellcheck disable=SC2086  # envs is a list of options
		"$SYSTEMD_RUN" --user --quiet --collect --unit="$CONSOLE_UNIT" $envs \
			--working-directory="$HOME_DIR" \
			"$BIN/ttyd" -i 127.0.0.1 -p "$PORT" -b "/$token" --check-origin -W bash ||
			die "couldn't start the browser terminal as a user unit"
		echo "unit:$CONSOLE_UNIT" >"$PIDFILE"
		say "browser terminal started and kept running across session switches (this handheld only; the link is also in $URLFILE). Stop it with: sh $0 console-stop"
		printf 'open: %s\n' "$url"   # printed, not logged
		return 0
	fi
	echo "$$" >"$PIDFILE"
	say "browser terminal started (this handheld only; the link is also in $URLFILE). Leave this window open; Ctrl+C to stop."
	printf 'open: %s\n' "$url"   # printed, not logged
	exec "$BIN/ttyd" -i 127.0.0.1 -p "$PORT" -b "/$token" --check-origin -W bash
}

# Stops a browser terminal `console` started (only a process that is ttyd).
stop_console() {
	[ -f "$PIDFILE" ] || { rm -f "$URLFILE"; return 0; }
	pid="$(cat "$PIDFILE" 2>/dev/null || true)"
	case "$pid" in
	unit:*)
		"$SYSTEMCTL" --user stop "$CONSOLE_UNIT" >/dev/null 2>&1 || true
		say "browser terminal stopped"
		pid=""
		;;
	"" | *[!0-9]*) pid="" ;;
	esac
	if [ -n "$pid" ] && [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = ttyd ]; then
		kill "$pid" 2>/dev/null || true
		say "browser terminal stopped"
	fi
	rm -f "$PIDFILE" "$URLFILE"
}

# ---------------------------------------------------------------------- status
cmd_status() {
	say "device: $(dmi sys_vendor) $(dmi product_name) (board $(dmi board_name))"
	say "system: $(os_field PRETTY_NAME) (ID=$(os_id), VERSION_ID=$(os_field VERSION_ID))"
	if [ -f "$GC_DATA/installer/release.env" ]; then
		say "downloaded release: $(sed -n 's/^TAG=//p' "$GC_DATA/installer/release.env") for $(sed -n 's/^OS=//p' "$GC_DATA/installer/release.env"), signature $(sed -n 's/^SIGNATURE=//p' "$GC_DATA/installer/release.env")"
	fi
	if command -v gamecove-session-select >/dev/null 2>&1 || [ -x "$FIX" ]; then
		say "GameCove: installed"
	else
		say "GameCove: not installed"
	fi
	case "$(os_id)" in
	steamos)
		if command -v "$READONLY" >/dev/null 2>&1; then
			say "steamos-readonly: $("$READONLY" status 2>/dev/null | head -n 1) (GameCove never changes it)"
		fi
		if [ -L "$ETC/extensions/gamecove.raw" ]; then
			say "sysext: $ETC/extensions/gamecove.raw -> $(readlink "$ETC/extensions/gamecove.raw")"
		elif [ -e /var/lib/extensions/gamecove.raw ]; then
			say "sysext: /var/lib/extensions/gamecove.raw (an older GameCove's place: lost at the next SteamOS update; reinstall)"
		fi
		[ -f "$ETC/atomic-update.conf.d/gamecove.conf" ] && say "kept across SteamOS updates: $(tr '\n' ' ' <"$ETC/atomic-update.conf.d/gamecove.conf")"
		if command -v "$SYSEXT" >/dev/null 2>&1; then
			if "$SYSEXT" status 2>/dev/null | grep -q gamecove; then say "sysext merged: yes"; else say "sysext merged: no"; fi
		fi
		;;
	esac
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

# --------------------------------------------------------------------- install
# The release to install: the argument, $GAMECOVE_TAG, else the newest release including
# pre-releases (the GitHub API's releases/latest skips pre-releases, so ask the list).
resolve_tag() {
	t="${1:-${GAMECOVE_TAG:-}}"
	if [ -z "$t" ]; then
		t="$("$CURL" -fsSL -H "Accept: application/vnd.github+json" "$API/repos/$REPO/releases?per_page=1" 2>/dev/null |
			sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)" || t=""
	fi
	case "$t" in
	v[0-9]*) printf '%s' "$t" ;;
	"") die "no GameCove release found; give the tag: install v0.1.0" ;;
	*) die "not a release tag: $t (expected vX.Y.Z)" ;;
	esac
}

run_installer_app() { # <log>
	[ -x "$INSTALLER_APP" ] || die "the installer app isn't there ($INSTALLER_APP); run install first"
	if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
		die "no desktop here: run this from Konsole (or a console started there) in Desktop Mode"
	fi
	run_logged "$1" "$INSTALLER_APP" -- --installer || say "note: the installer app exited with an error (see the log)"
	if [ -f "$GC_DATA/installer.log" ]; then
		{
			echo "---- installer.log (last 200 lines)"
			tail -n 200 "$GC_DATA/installer.log"
		} >>"$1"
	fi
}

cmd_install() {
	tag="$(resolve_tag "${1:-}")"
	mkdir -p "$TESTS"
	log="$TESTS/install-$(date +%Y%m%d-%H%M%S)-$(device_slug).log"
	say "== install GameCove $tag on $(os_field PRETTY_NAME); everything goes to $log"
	script="$GET_SCRIPT"
	if [ -z "$script" ]; then
		script="$TESTS/get-gamecove-$tag.sh"
		if ! "$CURL" -fsSL -o "$script" "$RAW/$REPO/$tag/packaging/get-gamecove.sh"; then
			[ -f "$SRC/packaging/get-gamecove.sh" ] || die "couldn't download get-gamecove.sh for $tag"
			say "note: couldn't download get-gamecove.sh for $tag; using the copy in $SRC"
			script="$SRC/packaging/get-gamecove.sh"
		fi
	fi
	# get-gamecove.sh checks the release's Sigstore signature and every checksum itself.
	run_logged "$log" env GAMECOVE_TAG="$tag" GAMECOVE_REPO="$REPO" sh "$script" --tag "$tag" --no-launch ||
		die "the download step failed; see $log"
	say "the installer opens now: go through it (Easy or Custom, as Claude asks); approve the password prompts yourself"
	run_installer_app "$log"
	cmd_status >>"$log" 2>&1 || true
	say "install log: $log"
}

cmd_uninstall() {
	mkdir -p "$TESTS"
	log="$TESTS/uninstall-$(date +%Y%m%d-%H%M%S)-$(device_slug).log"
	say "== uninstall: the installer opens; choose Uninstall (Claude says which options). Log: $log"
	run_installer_app "$log"
	cmd_status >>"$log" 2>&1 || true
	say "uninstall log: $log"
}

# ----------------------------------------------------------------------- check
results_dir() { echo "$TESTS/results/$(device_slug)"; }

# check [--detach] [name...]: names match the part after the number (install, controls,
# suspend...). --detach runs them in the background (setsid), so a check that sleeps the
# handheld or waits for the owner survives the browser terminal reconnecting.
cmd_check() {
	detach=0
	names=""
	for a in "$@"; do
		case "$a" in
		--detach) detach=1 ;;
		-*) die "unknown option: $a" ;;
		*) names="$names $a" ;;
		esac
	done
	[ -f "$CHECKS/lib.sh" ] || die "no checks in $CHECKS (run prepare)"
	res="$(results_dir)"
	mkdir -p "$res/out"
	if [ "$detach" = 1 ]; then
		# shellcheck disable=SC2086  # names is a word list
		setsid nohup sh "$0" check $names >>"$res/detached.log" 2>&1 </dev/null &
		say "checks running in the background ($names); progress: $res/detached.log, then: sh $0 results"
		return 0
	fi
	ran=0
	for f in "$CHECKS"/[0-9]*.sh; do
		[ -f "$f" ] || continue
		name="$(basename "$f" .sh | sed 's/^[0-9]*-//')"
		if [ -n "$names" ]; then
			case " $names " in *" $name "*) ;; *) continue ;; esac
		elif grep -q '^# testbed: by-name-only' "$f"; then
			say "-- check $name: skipped (hands-on; run: check $name)"
			continue
		fi
		ran=$((ran + 1))
		out="$res/$name.tsv"
		: >"$out"
		say "-- check $name"
		rc=0
		GC_RESULTS="$out" GC_OUT="$res/out" GC_HOME="$HOME_DIR" CHECK="$name" sh "$f" 2>"$res/out/$name.stderr" || rc=$?
		[ "$rc" -eq 0 ] || printf 'FAIL\t%s.script\tthe check stopped with exit code %s (see out/%s.stderr)\n' "$name" "$rc" "$name" >>"$out"
		summarize "$out"
	done
	[ "$ran" -gt 0 ] || die "no check named:$names"
	say "results: $res (sh $0 results prints them all)"
}

count() { grep -c "^$1" "$2" || true; }

summarize() { # <tsv>: counts, then every line that needs attention
	p="$(count PASS "$1")"; f="$(count FAIL "$1")"; w="$(count WARN "$1")"
	m="$(count MANUAL "$1")"; k="$(count SKIP "$1")"
	say "   pass $p, fail $f, warn $w, skip $k, manual $m"
	grep -E '^(FAIL|WARN|MANUAL)' "$1" | sed 's/^/   /' || true
}

cmd_results() {
	res="$(results_dir)"
	[ -d "$res" ] || die "no results yet: run check"
	for t in "$res"/*.tsv; do
		[ -f "$t" ] || continue
		say "== $(basename "$t" .tsv)"
		sed 's/^/   /' "$t"
	done
}

# note <check.item> <pass|fail|warn|skip> <what was seen>: the owner's answer to a MANUAL step
# (Claude writes what he says), kept with the results.
cmd_note() {
	[ $# -ge 3 ] || die "usage: note <check.item> pass|fail|warn|skip <what you saw>"
	item="$1"; st="$2"; shift 2
	case "$st" in pass | fail | warn | skip) ;; *) die "status must be pass, fail, warn or skip" ;; esac
	case "$item" in *[!A-Za-z0-9._-]*) die "item: letters, digits, . _ - only" ;; esac
	res="$(results_dir)"
	mkdir -p "$res"
	printf '%s\t%s\t%s\n' "$(echo "$st" | tr '[:lower:]' '[:upper:]')" "$item" "$(printf '%s' "$*" | tr '\t\n' '  ')" >>"$res/manual.tsv"
	say "noted $item: $st"
}

# ---------------------------------------------------------------------- report
# Nothing personal or secret leaves the handheld in a report: serials and MAC addresses are
# never collected, and as a safety net home paths, user and host names, Steam ids, IP and
# MAC addresses and anything token- or password-like are replaced in every text file.
redact() {
	user="$(id -un 2>/dev/null || true)"
	host="$(cat /proc/sys/kernel/hostname 2>/dev/null || true)"
	# a default name (deck, bazzite, steamdeck...) says nothing and would mangle words like "Steam Deck"
	case "$user" in deck | bazzite | gamer | user | root | "" | ?) user="" ;; esac
	case "$host" in steamdeck | bazzite | localhost | fedora | "" | ?) host="" ;; esac
	sed -e 's|\(http://127\.0\.0\.1:[0-9]*/\)[0-9a-f]\{32\}|\1<console>|g' \
		-e 's/7656119[0-9]\{10\}/<steamid>/g' \
		-e 's/\([Tt]oken\|[Ss]ecret\|[Pp]assword\|[Pp]asswd\|[Aa]uthorization\|[Cc]ookie\|[Aa]pi[_-]\{0,1\}[Kk]ey\|[Cc]ode\)\([^:=]\{0,20\}[:=][[:space:]]*\)[^[:space:],"]*/\1\2<redacted>/g' \
		-e 's/\([0-9a-fA-F]\{2\}:\)\{5\}[0-9a-fA-F]\{2\}/<mac>/g' \
		-e 's/\(^\|[^0-9.]\)\(127\.0\.0\.1\)\([^0-9.]\|$\)/\1<loopback>\3/g' \
		-e 's/\(^\|[^0-9.]\)\([0-9]\{1,3\}\.\)\{3\}[0-9]\{1,3\}\([^0-9.]\|$\)/\1<ip>\3/g' \
		-e 's|/var/home/[^/[:space:]"]*|/var/home/<user>|g' -e 's|/home/[^/[:space:]"]*|/home/<user>|g' |
		if [ -n "$user$host" ]; then
			sed -e "${user:+s/\\b$user\\b/<user>/g}" -e "${host:+s/\\b$host\\b/<host>/g}"
		else
			cat
		fi
}

# One folder (and a .tar.gz of it) per device run: versions, status, every check result,
# the owner's notes, logs, self-test, install logs. `sh $0 report` prints the path, and
# report/INDEX.txt lists what's inside so Claude can read it back through the console.
cmd_report() {
	dir="$TESTS/report-$(date +%Y%m%d-%H%M)-$(device_slug)"
	raw="$dir.raw"
	rm -rf "$raw" "$dir"
	mkdir -p "$raw/checks" "$raw/logs"
	cmd_status >"$raw/status.txt" 2>&1 || true
	{
		echo "testbed $(git -C "$(dirname "$0")" rev-parse --short HEAD 2>/dev/null || echo unknown)"
		echo "device $(dmi sys_vendor) | $(dmi product_name) | board $(dmi board_name) | bios $(dmi bios_version)"
		echo "os $(os_field PRETTY_NAME) (VERSION_ID=$(os_field VERSION_ID))"
		echo "kernel $(uname -r 2>/dev/null)"
		[ -f "$GC_DATA/installer/release.env" ] && sed -n 's/^\(TAG\|OS\|SIGNATURE\)=/release_\1 /p' "$GC_DATA/installer/release.env"
		[ -f "$GC_DATA/install-state.json" ] && grep -o '"version"[^,]*' "$GC_DATA/install-state.json" | head -n 1
	} >"$raw/versions.txt" 2>/dev/null
	res="$(results_dir)"
	if [ -d "$res" ]; then
		cp "$res"/*.tsv "$raw/checks/" 2>/dev/null || true
		[ -f "$res/out/env/env.txt" ] && cat "$res/out/env/env.txt" >>"$raw/versions.txt"
		if [ -d "$res/out" ]; then
			# command output and read-backs, text only, size-capped
			(cd "$res/out" && find . -type f -size -2M) | while IFS= read -r f; do
				mkdir -p "$raw/checks/out/$(dirname "$f")"
				cp "$res/out/$f" "$raw/checks/out/$f" 2>/dev/null || true
			done
		fi
		{
			for t in "$res"/*.tsv; do
				[ -f "$t" ] || continue
				printf '%-14s pass %3s  fail %3s  warn %3s  skip %3s  manual %3s\n' "$(basename "$t" .tsv)" \
					"$(count PASS "$t")" "$(count FAIL "$t")" "$(count WARN "$t")" \
					"$(count SKIP "$t")" "$(count MANUAL "$t")"
			done
			echo
			grep -h -E '^(FAIL|WARN)' "$res"/*.tsv 2>/dev/null || true
		} >"$raw/summary.txt"
	fi
	for f in "$GC_DATA/"*.log /var/lib/gamecove/changes.log "$HOME_DIR/.local/share/godot/app_userdata/GameCove/logs/godot.log" \
		"$TESTS"/install-*.log "$TESTS"/uninstall-*.log "$LOG"; do
		[ -f "$f" ] && tail -n 3000 "$f" >"$raw/logs/$(basename "$f")" 2>/dev/null || true
	done
	if command -v "$SELFTEST" >/dev/null 2>&1; then
		say "running the self-test (automatic checks only)"
		"$SELFTEST" --no-network >"$raw/selftest.txt" 2>&1 || true
	fi
	journalctl --user -b --no-pager -n 2000 2>/dev/null | grep -i -E 'gamecove|gamescope|inputplumber|hhd|steamos-manager' | tail -n 600 >"$raw/logs/journal-user.txt" 2>/dev/null || true
	journalctl -b --no-pager -n 4000 2>/dev/null | grep -i -E 'gamecove|inputplumber|hhd|systemd-sysext|polkit' | tail -n 600 >"$raw/logs/journal-system.txt" 2>/dev/null || true
	# copy through the redaction; never anything that isn't text
	(cd "$raw" && find . -type f) | while IFS= read -r f; do
		mkdir -p "$dir/$(dirname "$f")"
		if grep -Iq . "$raw/$f" 2>/dev/null || [ ! -s "$raw/$f" ]; then
			redact <"$raw/$f" >"$dir/$f"
		fi
	done
	rm -rf "$raw"
	(cd "$dir" && find . -type f | sort | sed 's|^\./||') >"$dir/INDEX.txt"
	tar -czf "$dir.tar.gz" -C "$TESTS" "$(basename "$dir")" 2>/dev/null || true
	say "report saved in $dir (and $dir.tar.gz); start with $dir/summary.txt"
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
	stop_console
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
			if [ -x "$INSTALLER_APP" ]; then
				cmd_uninstall
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
console) shift; cmd_console "$@" ;;
console-stop) stop_console ;;
status) cmd_status ;;
install) shift; cmd_install "$@" ;;
check) shift; cmd_check "$@" ;;
results) cmd_results ;;
note) shift; cmd_note "$@" ;;
uninstall) cmd_uninstall ;;
report) cmd_report ;;
reset) shift; cmd_reset "$@" ;;
*)
	sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
	exit 64
	;;
esac
