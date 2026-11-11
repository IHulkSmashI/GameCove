#!/bin/sh
# Install GameCove on Bazzite (Fedora Atomic) from a GameCove RPM.
#
#   sh install.sh ./gamecove-0.1.0-1.fc43.x86_64.rpm     install
#   sh install.sh --uninstall                             remove
#
# UNTESTED on hardware. Every step is printed before it runs and asks first.
# Nothing here edits files by hand: rpm-ostree layers the package onto the
# system image and can take it off again, and steamos-manager switches sessions.
set -eu

# Overridable for tests (packaging/tests/run.sh points these at fakes).
RPM_OSTREE="${RPM_OSTREE:-rpm-ostree}"
IMAGE_INFO="${IMAGE_INFO:-/usr/share/ublue-os/image-info.json}"
ASSUME_YES="${ASSUME_YES:-0}"
SESSION_SELECT="${SESSION_SELECT:-/usr/bin/gamecove-session-select}"
GUARD_COPY="${GUARD_COPY:-${XDG_DATA_HOME:-$HOME/.local/share}/gamecove/gamecove-session-guard}"
FIX_HELPER="${FIX_HELPER:-/usr/libexec/gamecove/gamecove-fix}"
UPSCALE_HELPER="${UPSCALE_HELPER:-/usr/libexec/gamecove/gamecove-upscale}"
PKEXEC="${PKEXEC:-pkexec}"

say() {
	printf '\n==> %s\n' "$*"
}

ask() {
	[ "$ASSUME_YES" = "1" ] && return 0
	printf '%s [y/N] ' "$1"
	read -r answer || answer=""
	case "$answer" in
	y | Y | yes) return 0 ;;
	*) echo "Stopped. Nothing else was changed."; exit 1 ;;
	esac
}

run() {
	echo "    \$ $*"
	"$@"
}

# Step 0: make sure this is Bazzite (or another rpm-ostree system).
say "Checking this is Bazzite / Fedora Atomic"
if [ ! -f "$IMAGE_INFO" ]; then
	echo "    $IMAGE_INFO not found: this doesn't look like Bazzite."
	echo "    On other Fedora Atomic images this script may still work."
	ask "Continue anyway?"
fi
if ! command -v "$RPM_OSTREE" >/dev/null 2>&1; then
	echo "    rpm-ostree not found. On plain Fedora use: sudo dnf install ./gamecove-*.rpm"
	exit 1
fi

if [ "${1:-}" = "--uninstall" ]; then
	# Review H4: the boot default and every fix go back first, while GameCove's tools are still
	# here. If either fails, stop: removing the package anyway could leave the login screen
	# pointing at a session that no longer exists, or kernel arguments and rules nobody can undo.
	echo "    Removing GameCove: the boot default goes back, every device fix is undone,"
	echo "    then rpm-ostree builds a new system image without GameCove."
	ask "Remove GameCove?"
	say "Step 1/5: boot into Steam Gaming Mode again (or the desktop, if that was the default)"
	select=""
	for s in "$GUARD_COPY" "$SESSION_SELECT"; do
		if [ -f "$s" ]; then
			select="$s"
			break
		fi
	done
	if [ -n "$select" ]; then
		run sh "$select" restore || {
			echo "    Couldn't put the boot default back; GameCove was not removed."
			echo "    Try again, or from a TTY: gamecove-session-select restore (docs/SESSION.md)."
			exit 1
		}
	else
		echo "    GameCove never was the boot default here; nothing to do."
	fi
	say "Step 2/5: undo every device fix and setting GameCove applied"
	if [ -x "$FIX_HELPER" ]; then
		echo "    This asks for your password."
		run "$PKEXEC" "$FIX_HELPER" --remove-all || {
			echo "    Couldn't undo the fixes; GameCove was not removed. Try again."
			exit 1
		}
	else
		echo "    No fix helper installed; nothing to undo."
	fi
	# One install, one clean uninstall: every game gets back exactly the files it shipped with, the XeSS XMX driver
	# and lsfg-vk we installed come out, and our folder of upscaler files is deleted. Runs as you, not as root.
	say "Step 3/5: take our upscaler files out of your games"
	if [ -x "$UPSCALE_HELPER" ]; then
		run "$UPSCALE_HELPER" purge --home "$HOME" || echo "    Some games couldn't be put back by themselves: use Steam's \"Verify integrity of game files\" for those."
	else
		echo "    No upscaling helper installed; nothing to undo."
	fi
	say "Step 4/5: remove the GameCove layer"
	echo "    Your current image stays bootable until you reboot."
	run "$RPM_OSTREE" uninstall gamecove
	say "Step 5/5: reboot to finish"
	echo "    Run: systemctl reboot"
	exit 0
fi

rpm="${1:-}"
if [ -z "$rpm" ] || [ ! -f "$rpm" ]; then
	echo "usage: sh install.sh ./gamecove-<version>.x86_64.rpm | --uninstall" >&2
	exit 64
fi

say "Step 1/3: layer the GameCove package onto the system"
echo "    Bazzite's /usr is read-only; rpm-ostree adds GameCove to a new image."
echo "    It installs: the app (/usr/lib/gamecove), the session (gamescope-session-plus"
echo "    'gamecove', listed as 'GameCove' at login), gamecove-session-select, and"
echo "    the root-fix helper with its polkit rules. No fix is applied on install."
echo "    Charge limit, fan preset and the gyro's accelerometer toggle can then be"
echo "    changed from GameCove without a password; installing or removing a fix"
echo "    (firmware, kernel arguments, services) always asks for your password."
echo "    It may also pull in xprop if the image doesn't have it."
ask "Install $rpm?"
run "$RPM_OSTREE" install "$rpm"

say "Step 2/3: reboot into the new image"
echo "    Run: systemctl reboot"
echo "    Your previous image stays in the boot menu if anything goes wrong."

say "Step 3/3: try GameCove"
echo "    After the reboot, from Steam Gaming Mode or the desktop, run:"
echo "      gamecove-session-select gamecove            (just this time)"
echo "      gamecove-session-select gamecove --default  (every boot)"
echo "    Back to Steam any time:  gamecove-session-select steam"
echo "    If GameCove crashes or fails to start 3 times in a row, the session"
echo "    falls back to Steam Gaming Mode for the rest of that boot."
