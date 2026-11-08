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
	say "Step 1/2: remove the GameCove layer"
	echo "    rpm-ostree builds a new system image without GameCove."
	echo "    Your current image stays bootable until you reboot."
	ask "Remove GameCove?"
	run "$RPM_OSTREE" uninstall gamecove
	say "Step 2/2: reboot to finish"
	echo "    Before rebooting, make sure you're not set to boot into GameCove:"
	echo "      steamosctl set-default-login-mode game"
	echo "    Then: systemctl reboot"
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
echo "    If GameCove fails to start 5 times in a row, the session falls back"
echo "    to Steam Gaming Mode by itself."
