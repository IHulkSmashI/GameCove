#!/bin/sh
# Build a systemd-sysext image of GameCove for SteamOS.
#
# Not run on a SteamOS handheld yet: GameCove's hardware testing so far (MSI Claw 8 EX AI+
# and ASUS ROG Ally) was on Bazzite. The Release workflow builds the image and checks its
# contents; the --tree-only path is exercised by packaging/tests/run.sh with fake inputs.
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
#   --session-src DIR  gamescope-session tree (else fetched with git at SESSION_COMMIT); its files must
#                      match gamescope-session.sha256 (or SESSION_SUMS)
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
SESSION_REPO="${SESSION_REPO:-https://github.com/OpenGamingCollective/gamescope-session.git}"
# sha256 of each file taken from the session tree (review M6); a different SESSION_COMMIT needs its own list
SESSION_SUMS="${SESSION_SUMS:-$HERE/gamescope-session.sha256}"
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
	# by git at the exact commit (GitHub's archive tarballs aren't byte-stable, so they can't be pinned)
	echo "Fetching gamescope-session $SESSION_COMMIT"
	git init -q "$work/session"
	git -C "$work/session" fetch -q --depth 1 "$SESSION_REPO" "$SESSION_COMMIT" || die "couldn't fetch $SESSION_REPO at $SESSION_COMMIT"
	git -C "$work/session" -c advice.detachedHead=false checkout -q FETCH_HEAD
	[ "$(git -C "$work/session" rev-parse HEAD)" = "$SESSION_COMMIT" ] || die "$SESSION_REPO gave another commit than $SESSION_COMMIT"
	session_src="$work/session"
fi
[ -f "$session_src/usr/bin/gamescope-session-plus" ] || die "$session_src is not a gamescope-session tree"

# gamescope-session-plus (bundled, MIT): only the files GameCove's session needs (review H10).
# A sysext overlays /usr, so anything else from upstream's usr/ would shadow SteamOS's own:
# its usr/lib/systemd/user/gamescope-session.target (a bare Description=) over Valve's, owned
# by the gamescope package; usr/share/gamescope/scripts/50-custom/50-disable-explicit-sync.lua
# would change Valve's Steam session too; usr/bin/export-gpu isn't used by the session.
SESSION_FILES="usr/bin/gamescope-session-plus
usr/share/gamescope-session-plus/gamescope-session-plus
usr/share/gamescope-session-plus/device-quirks
usr/lib/systemd/user/gamescope-session-plus@.service"
# every file taken, and LICENSE, must match SESSION_SUMS (review M6)
[ -f "$SESSION_SUMS" ] || die "no checksum list $SESSION_SUMS"
for f in $SESSION_FILES LICENSE; do
	want="$(awk -v n="$f" '$1 !~ /^#/ && $2 == n { print $1; exit }' "$SESSION_SUMS")"
	case "$want" in
	[0-9a-f]*) [ "${#want}" -eq 64 ] || die "$SESSION_SUMS: bad sha256 for $f" ;;
	*) die "$SESSION_SUMS has no sha256 for $f" ;;
	esac
	[ -f "$session_src/$f" ] || die "$session_src has no $f"
	[ "$(sha256sum "$session_src/$f" | cut -d ' ' -f 1)" = "$want" ] || die "$f doesn't match its pinned sha256 (gamescope-session $SESSION_COMMIT); not building"
done
for f in $SESSION_FILES; do
	install -D -m "$(if [ -x "$session_src/$f" ]; then echo 0755; else echo 0644; fi)" "$session_src/$f" "$tree/$f"
done
mkdir -p "$tree/usr/share/licenses/gamescope-session"
cp "$session_src/LICENSE" "$tree/usr/share/licenses/gamescope-session/"

# GameCove
install -Dm0755 "$app/gamecove.x86_64" "$tree/usr/lib/gamecove/gamecove.x86_64"
install -Dm0644 "$app/gamecove.pck" "$tree/usr/lib/gamecove/gamecove.pck"
# the LZMS cabinet.dll for FSR 4 on XMX and its source, when the app tarball carries them (release builds do)
if [ -s "$app/bin/cabinet.dll" ]; then
	install -Dm0644 "$app/bin/cabinet.dll" "$tree/usr/lib/gamecove/bin/cabinet.dll"
	[ -s "$app/bin/cabinet-lzms-source.tar.gz" ] && install -Dm0644 "$app/bin/cabinet-lzms-source.tar.gz" "$tree/usr/lib/gamecove/bin/cabinet-lzms-source.tar.gz"
else
	echo "build-sysext: warning: no bin/cabinet.dll in the app folder; FSR 4 on XMX won't be offered (tools/cabinet-lzms/build.sh)" >&2
fi
# nitec's FSR 4.1.2 XMX files with their set.json, unmodified (release builds carry them in the app tarball)
if [ -d "$app/bin/upscalers" ]; then
	mkdir -p "$tree/usr/lib/gamecove/bin/upscalers"
	install -m0644 "$app/bin/upscalers"/* "$tree/usr/lib/gamecove/bin/upscalers/"
else
	echo "build-sysext: warning: no bin/upscalers in the app folder; upscaler files will be downloaded on first use" >&2
fi
if [ -d "$app/bin/fsr4-xmx" ]; then
	mkdir -p "$tree/usr/lib/gamecove/bin/fsr4-xmx"
	install -m0644 "$app/bin/fsr4-xmx"/* "$tree/usr/lib/gamecove/bin/fsr4-xmx/"
else
	echo "build-sysext: warning: no bin/fsr4-xmx in the app folder; FSR 4 on XMX files will be downloaded on first use" >&2
fi
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
# the root autologin guard: the installer copies both into /etc (review H4), never enabled from here
install -Dm0755 "$REPO/session/gamecove-autologin-guard" "$tree/usr/lib/gamecove/session/gamecove-autologin-guard"
install -Dm0644 "$REPO/session/systemd/gamecove-autologin-guard.service" "$tree/usr/lib/gamecove/session/gamecove-autologin-guard.service"
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
