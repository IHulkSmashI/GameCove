#!/bin/sh
# Install GameCove on Bazzite (Fedora Atomic) from a GameCove RPM.
#
#   sh install.sh ./gamecove-0.1.0-1.fc43.x86_64.rpm     install
#   sh install.sh --uninstall                             remove
#
# Tested on hardware: MSI Claw 8 EX AI+ (Bazzite) and ASUS ROG Ally (SteamOS) (GameCove's
# installer runs the same rpm-ostree steps). Every step is printed before it runs and asks first.
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
PKEXEC="${PKEXEC:-pkexec}"
# Prefix for /etc, /usr and /ostree (tests).
ROOT="${GAMECOVE_ROOT:-}"

# The root autologin guard into /etc (session/gamecove-autologin-guard says why): if the layer
# is ever removed with a bare `rpm-ostree uninstall gamecove` while GameCove is the boot
# default, the login screen would stop at a password prompt. The same steps as the installer
# app's (app/scripts/installer/commands.gd GUARD_INSTALL): from /usr when the package is live,
# else from the deployment rpm-ostree just staged. "$1" is the prefix.
GUARD_INSTALL='set -e
src="$1/usr/lib/gamecove/session"
if [ ! -f "$src/gamecove-autologin-guard" ]; then
	for d in "$1"/ostree/deploy/*/deploy/*/usr/lib/gamecove/session; do
		if [ -f "$d/gamecove-autologin-guard" ]; then src="$d"; fi
	done
fi
install -D -m 0755 "$src/gamecove-autologin-guard" "$1/etc/gamecove/autologin-guard"
install -D -m 0644 "$src/gamecove-autologin-guard.service" "$1/etc/systemd/system/gamecove-autologin-guard.service"
mkdir -p "$1/etc/systemd/system/multi-user.target.wants"
ln -sfn /etc/systemd/system/gamecove-autologin-guard.service "$1/etc/systemd/system/multi-user.target.wants/gamecove-autologin-guard.service"
systemctl daemon-reload >/dev/null 2>&1 || true'
GUARD_REMOVE='rm -f "$1/etc/systemd/system/multi-user.target.wants/gamecove-autologin-guard.service" "$1/etc/systemd/system/gamecove-autologin-guard.service" "$1/etc/gamecove/autologin-guard"
rmdir "$1/etc/gamecove" 2>/dev/null || true'

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
	say "Step 1/4: boot into Steam Gaming Mode again (or the desktop, if that was the default)"
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
	say "Step 2/4: undo every device fix and setting GameCove applied"
	if [ -x "$FIX_HELPER" ]; then
		echo "    This asks for your password."
		run "$PKEXEC" "$FIX_HELPER" --remove-all || {
			echo "    Couldn't undo the fixes; GameCove was not removed. Try again."
			exit 1
		}
	else
		echo "    No fix helper installed; nothing to undo."
	fi
	say "Step 3/4: remove the GameCove layer"
	echo "    Your current image stays bootable until you reboot."
	if [ -e "$ROOT/etc/gamecove/autologin-guard" ] || [ -e "$ROOT/etc/systemd/system/gamecove-autologin-guard.service" ]; then
		echo "    First the login-screen guard GameCove kept in /etc (the boot default is back, so it has nothing left to do)."
		echo "    \$ $PKEXEC sh -c <remove /etc/gamecove/autologin-guard and its unit>"
		"$PKEXEC" sh -c "$GUARD_REMOVE" sh "$ROOT" || echo "    Couldn't remove it; it does nothing without GameCove and can stay."
	fi
	# Display settings GameCove wrote for the session (rotation, refresh-rate unlock, HDR): every
	# gamescope session reads this file, Steam Gaming Mode too, so it goes with GameCove.
	display_conf="${XDG_CONFIG_HOME:-$HOME/.config}/environment.d/80-gamecove-display.conf"
	if [ -f "$display_conf" ]; then
		run rm -f "$display_conf"
	fi
	run "$RPM_OSTREE" uninstall gamecove
	say "Step 4/4: reboot to finish"
	echo "    Run: systemctl reboot"
	exit 0
fi

rpm="${1:-}"
if [ -z "$rpm" ] || [ ! -f "$rpm" ]; then
	echo "usage: sh install.sh ./gamecove-<version>.x86_64.rpm | --uninstall" >&2
	exit 64
fi

say "Step 1/4: layer the GameCove package onto the system"
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

say "Step 2/4: keep the login screen safe"
echo "    A small root unit in /etc (gamecove-autologin-guard) that runs before the login screen:"
echo "    if GameCove is ever the boot default and its files are gone (the layer removed by hand),"
echo "    it points autologin back at Steam Gaming Mode instead of leaving a password prompt."
echo "    This asks for your password."
echo "    \$ $PKEXEC sh -c <copy gamecove-autologin-guard and its unit into /etc>"
"$PKEXEC" sh -c "$GUARD_INSTALL" sh "$ROOT" || {
	echo "    Couldn't install the guard. GameCove is layered, but don't make it the boot default"
	echo "    until this step works: run this script again."
	exit 1
}

say "Step 3/4: reboot into the new image"
echo "    Run: systemctl reboot"
echo "    Your previous image stays in the boot menu if anything goes wrong."

say "Step 4/4: try GameCove"
echo "    After the reboot, from Steam Gaming Mode or the desktop, run:"
echo "      gamecove-session-select gamecove            (just this time)"
echo "      gamecove-session-select gamecove --default  (every boot)"
echo "    Back to Steam any time:  gamecove-session-select steam"
echo "    If GameCove crashes or fails to start 3 times in a row, the session"
echo "    falls back to Steam Gaming Mode for the rest of that boot."
