#!/bin/sh
# Build a systemd-sysext image of GameCove for SteamOS.
#
# DOCUMENTED, NOT RUN on SteamOS yet. The --tree-only path is exercised by
# packaging/tests/run.sh with fake inputs.
#
# SteamOS's /usr is read-only and wiped on updates; a sysext is a squashfs image
# that systemd-sysext overlays onto /usr (the installer keeps it on /home and links it
# from /etc/extensions; app/scripts/installer/commands.gd says why). Same approach
# as OpenGamepadUI's `make dist-ext`. SteamOS has no gamescope-session-plus (it
# uses Valve's own Steam-only session script), so we bundle it (MIT,
# OpenGamingCollective/gamescope-session) at a pinned commit.
#
#   sh build-sysext.sh --app DIR [--session-src DIR] [--out DIR] [--tree-only]
#
#   --app DIR          exported Godot app: DIR/gamecove.x86_64 and DIR/gamecove.pck
#                      (the contents of the release's gamecove-<version>-x86_64.tar.gz)
#
# Build the gyro fix's HID-BPF object first (sh fixes/claw8ex-gyro/bpf/build-bpf.sh);
# it is copied in with fixes/. .github/workflows/release.yml does both.
#   --session-src DIR  unpacked gamescope-session tree (else downloaded from GitHub)
#   --out DIR          where to write gamecove.raw (default ./dist)
#   --tree-only        stop after building the file tree (no mksquashfs)
#
# Install by hand on SteamOS (as root; the installer does the same):
#   mkdir -p /home/.steamos/offload/gamecove /etc/extensions
#   install -m 0644 dist/gamecove.raw /home/.steamos/offload/gamecove/gamecove.raw
#   ln -sfn /home/.steamos/offload/gamecove/gamecove.raw /etc/extensions/gamecove.raw
#   printf '%s\n' /etc/extensions/gamecove.raw \
#     /etc/systemd/system/sysinit.target.wants/systemd-sysext.service >/etc/atomic-update.conf.d/gamecove.conf
#   systemctl enable systemd-sysext && systemd-sysext refresh && systemd-sysext status
#   systemctl reload polkit 2>/dev/null || true
# Then from desktop or Gaming Mode: gamecove-session-select gamecove
# Remove: rm /etc/extensions/gamecove.raw /etc/atomic-update.conf.d/gamecove.conf \
#   /home/.steamos/offload/gamecove/gamecove.raw && systemd-sysext refresh
#
# Hardware checks still needed on SteamOS: xprop present (else bundle Arch's
# xorg-xprop), Valve's steamosctl accepts gamecove.desktop, SDDM shows it.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SESSION_COMMIT="${SESSION_COMMIT:-08e65a62ed3d7acc6ae17db637091d402a55ae2a}"
# _any: the image holds no libraries tied to a SteamOS release, so don't break on
# every OS update (a VERSION_ID match would). Override for a stricter build.
SYSEXT_ID="${SYSEXT_ID:-_any}"

app=""
session_src=""
out="$PWD/dist"
tree_only=0

die() {
	echo "build-sysext: $*" >&2
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
	--app) app="$2"; shift 2 ;;
	--session-src) session_src="$2"; shift 2 ;;
	--out) out="$2"; shift 2 ;;
	--tree-only) tree_only=1; shift ;;
	*) die "unknown option $1" ;;
	esac
done

[ -n "$app" ] || die "--app DIR is required"
[ -f "$app/gamecove.x86_64" ] && [ -f "$app/gamecove.pck" ] || die "$app must hold gamecove.x86_64 and gamecove.pck"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
tree="$work/gamecove"

if [ -z "$session_src" ]; then
	url="https://github.com/OpenGamingCollective/gamescope-session/archive/$SESSION_COMMIT.tar.gz"
	echo "Downloading gamescope-session $SESSION_COMMIT"
	curl -fsSL "$url" -o "$work/session.tar.gz"
	mkdir -p "$work/session"
	tar -xzf "$work/session.tar.gz" -C "$work/session" --strip-components=1
	session_src="$work/session"
fi
[ -f "$session_src/usr/bin/gamescope-session-plus" ] || die "$session_src is not a gamescope-session tree"

# gamescope-session-plus (bundled, MIT)
mkdir -p "$tree/usr"
cp -a "$session_src/usr/." "$tree/usr/"
mkdir -p "$tree/usr/share/licenses/gamescope-session"
[ -f "$session_src/LICENSE" ] && cp "$session_src/LICENSE" "$tree/usr/share/licenses/gamescope-session/"

# GameCove
install -Dm0755 "$app/gamecove.x86_64" "$tree/usr/lib/gamecove/gamecove.x86_64"
install -Dm0644 "$app/gamecove.pck" "$tree/usr/lib/gamecove/gamecove.pck"
mkdir -p "$tree/usr/lib/gamecove/fixes"
if [ -d "$REPO/fixes" ]; then
	cp -a "$REPO/fixes/." "$tree/usr/lib/gamecove/fixes/"
	find "$tree/usr/lib/gamecove/fixes" -name test.sh -exec rm -f {} +
	find "$tree/usr/lib/gamecove/fixes" -depth -type d -name tests -exec rm -rf {} +
fi
[ -f "$tree/usr/lib/gamecove/fixes/claw8ex-gyro/bpf/MSI__Claw-ISH-IMU.bpf.o" ] ||
	echo "build-sysext: warning: no gyro HID-BPF object; run fixes/claw8ex-gyro/bpf/build-bpf.sh first or the gyro fix won't install" >&2
install -Dm0755 "$REPO/packaging/libexec/gamecove-fix" "$tree/usr/libexec/gamecove/gamecove-fix"
install -Dm0755 "$REPO/packaging/libexec/gamecove-fix-set" "$tree/usr/libexec/gamecove/gamecove-fix-set"
install -Dm0755 "$REPO/session/gamecove-session-client" "$tree/usr/libexec/gamecove/gamecove-session-client"
install -Dm0755 "$REPO/packaging/libexec/gamecove-apply-choices" "$tree/usr/libexec/gamecove/gamecove-apply-choices"
install -Dm0755 "$REPO/packaging/get-gamecove.sh" "$tree/usr/libexec/gamecove/get-gamecove.sh"
# per-game launch wrapper and upscaling helper (perf controls)
install -Dm0755 "$REPO/packaging/libexec/gamecove-run" "$tree/usr/libexec/gamecove/gamecove-run"
install -Dm0755 "$REPO/packaging/libexec/reaper" "$tree/usr/libexec/gamecove/reaper"
install -Dm0755 "$REPO/packaging/libexec/gamecove-upscale" "$tree/usr/libexec/gamecove/gamecove-upscale"
mkdir -p "$tree/usr/lib/gamecove/helpers"
cp -a "$REPO/packaging/helpers/gamecove_upscale" "$tree/usr/lib/gamecove/helpers/"
find "$tree/usr/lib/gamecove/helpers" -depth -type d -name __pycache__ -exec rm -rf {} +
install -Dm0644 "$REPO/packaging/installer/io.github.ihulksmashi.GameCoveInstaller.desktop" \
	"$tree/usr/share/applications/io.github.ihulksmashi.GameCoveInstaller.desktop"
install -Dm0755 "$REPO/session/gamecove-session-select" "$tree/usr/bin/gamecove-session-select"
install -Dm0755 "$REPO/packaging/bin/gamecove-selftest" "$tree/usr/bin/gamecove-selftest"
install -Dm0644 "$REPO/session/gamescope-session-plus/sessions.d/gamecove" "$tree/usr/share/gamescope-session-plus/sessions.d/gamecove"
install -Dm0644 "$REPO/session/wayland-sessions/gamecove.desktop" "$tree/usr/share/wayland-sessions/gamecove.desktop"
install -Dm0644 "$REPO/session/systemd/gamescope-session-plus@gamecove.service.d/10-gamecove.conf" \
	"$tree/usr/lib/systemd/user/gamescope-session-plus@gamecove.service.d/10-gamecove.conf"
install -Dm0644 "$REPO/packaging/polkit/io.github.ihulksmashi.gamecove.policy" \
	"$tree/usr/share/polkit-1/actions/io.github.ihulksmashi.gamecove.policy"
# licence and notice texts: every file packaging/licenses.list names (review H8)
while read -r src dest; do
	case "$src" in '' | '#'*) continue ;; esac
	install -Dm0644 "$REPO/$src" "$tree/usr/share/licenses/gamecove/$dest"
done <"$REPO/packaging/licenses.list"

# Tells systemd-sysext which OS this extension is for.
mkdir -p "$tree/usr/lib/extension-release.d"
{
	echo "ID=$SYSEXT_ID"
	[ -n "${SYSEXT_VERSION_ID:-}" ] && echo "VERSION_ID=$SYSEXT_VERSION_ID"
	echo "ARCHITECTURE=x86-64"
} >"$tree/usr/lib/extension-release.d/extension-release.gamecove"

mkdir -p "$out"
if [ "$tree_only" -eq 1 ]; then
	rm -rf "$out/gamecove"
	cp -a "$tree" "$out/gamecove"
	echo "Tree written to $out/gamecove"
	exit 0
fi

command -v mksquashfs >/dev/null 2>&1 || die "mksquashfs (squashfs-tools) is required"
rm -f "$out/gamecove.raw"
mksquashfs "$tree" "$out/gamecove.raw" -all-root -noappend -quiet
echo "Built $out/gamecove.raw"
