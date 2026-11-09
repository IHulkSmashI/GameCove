#!/bin/sh
# GameCove installer bootstrap. Run it in Desktop Mode:
#
#   curl -fsSL https://raw.githubusercontent.com/IHulkSmashI/GameCove/main/packaging/get-gamecove.sh | bash
#
# What it does, and nothing more:
#   1. works out which system this is (Bazzite / Fedora Atomic, SteamOS, other)
#   2. downloads the latest GameCove release from GitHub: the app, the package
#      for this system (RPM or SteamOS sysext) and SHA256SUMS
#   3. checks SHA256SUMS's signature (Sigstore keyless: signed by this repository's release
#      workflow through GitHub OIDC, verified with cosign) and every file against SHA256SUMS
#      (stops on any mismatch)
#   4. unpacks the app into ~/.local/share/gamecove/installer
#   5. adds "GameCove Installer" to the app menu and "Install GameCove" to the desktop
#   6. opens GameCove in installer mode, which explains each step and asks
#      before changing anything
# It needs no root and changes nothing outside your home folder. The installer
# app asks for your admin password (pkexec) only for the steps that need it.
#
# Options: --no-launch (download only), --tag vX.Y.Z (a given release; pre-releases need it
#          while a stable release exists: GitHub's releases/latest skips them),
#          --detect-os (print the system type and stop), --help
# Environment (for tests and forks): GAMECOVE_REPO, GAMECOVE_API, GAMECOVE_TAG,
#   GAMECOVE_HOME, GAMECOVE_ROOT (prefix for /etc/os-release, /run/ostree-booted),
#   CURL, SHA256SUM, COSIGN (a cosign binary; else the system's, else a pinned download),
#   GAMECOVE_ALLOW_UNSIGNED=1 (accept a release without a signature, e.g. one from before
#   signing; the checksums are still checked).
#
# Signature (review S3-3): .github/workflows/release.yml signs SHA256SUMS with
# `cosign sign-blob` using the workflow's GitHub OIDC identity (no key or secret to keep), and
# attaches SHA256SUMS.sigstore.json. This script accepts it only when the certificate says it
# was made by https://github.com/$REPO/.github/workflows/release.yml for a v* tag, issued to
# GitHub Actions, and logged in Rekor. So a changed release file, or a release made any other
# way (a stolen token uploading files by hand), is refused. cosign comes from the system, or
# is downloaded once into ~/.local/share/gamecove/tools/ and checked against the sha256 below.
set -eu

REPO="${GAMECOVE_REPO:-IHulkSmashI/GameCove}"
API="${GAMECOVE_API:-https://api.github.com}"
TAG="${GAMECOVE_TAG:-}"
HOME_DIR="${GAMECOVE_HOME:-$HOME}"
ROOT="${GAMECOVE_ROOT:-}"
CURL="${CURL:-curl}"
SHA256SUM="${SHA256SUM:-sha256sum}"
DATA="$HOME_DIR/.local/share/gamecove"
DEST="$DATA/installer"
LOG="$DATA/installer.log"
APP_ID="io.github.ihulksmashi.GameCoveInstaller"
launch=1
COSIGN_VERSION=v2.5.3
COSIGN_SHA256=783b5d6c74105401c63946c68d9b2a4e1aab3c8abce043e06b8510b02b623ec9
OIDC_ISSUER=https://token.actions.githubusercontent.com

say() {
	printf '==> %s\n' "$*"
	log "$*"
}

log() {
	mkdir -p "$DATA" 2>/dev/null || return 0
	printf '%s bootstrap: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG" 2>/dev/null || true
}

die() {
	printf 'get-gamecove: %s\n' "$*" >&2
	log "error: $*"
	exit 1
}

# bazzite | fedora-atomic | steamos | other, from os-release (and ostree for Fedora).
detect_os() {
	rel=""
	for f in "$ROOT/etc/os-release" "$ROOT/usr/lib/os-release"; do
		if [ -f "$f" ]; then
			rel="$f"
			break
		fi
	done
	[ -n "$rel" ] || {
		echo other
		return
	}
	id="$(sed -n 's/^ID=//p' "$rel" | tr -d '"' | head -n 1)"
	like="$(sed -n 's/^ID_LIKE=//p' "$rel" | tr -d '"' | head -n 1)"
	case "$id" in
	bazzite)
		echo bazzite
		return
		;;
	steamos)
		echo steamos
		return
		;;
	esac
	if [ -e "$ROOT/run/ostree-booted" ]; then
		case " $id $like " in
		*" fedora "*)
			echo fedora-atomic
			return
			;;
		esac
	fi
	echo other
}

while [ $# -gt 0 ]; do
	case "$1" in
	--no-launch) launch=0 ;;
	--tag)
		[ $# -ge 2 ] || die "--tag needs a value"
		TAG="$2"
		shift
		;;
	--detect-os)
		detect_os
		exit 0
		;;
	-h | --help)
		sed -n '2,27p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || true
		exit 0
		;;
	*) die "unknown option $1 (try --help)" ;;
	esac
	shift
done

os="$(detect_os)"
arch="${GAMECOVE_ARCH:-$(uname -m)}"
[ "$arch" = "x86_64" ] || die "GameCove is built for x86_64 handhelds; this is $arch"
for tool in "$CURL" "$SHA256SUM" tar; do
	command -v "$tool" >/dev/null 2>&1 || die "$tool is needed but not installed"
done

case "$os" in
bazzite) say "This is Bazzite. GameCove installs as a system package (rpm-ostree)." ;;
fedora-atomic) say "This is Fedora Atomic. GameCove installs as a system package (rpm-ostree)." ;;
steamos) say "This is SteamOS. GameCove installs as a system extension (sysext)." ;;
*) say "This system isn't Bazzite, Fedora Atomic or SteamOS. You can still try GameCove in a window." ;;
esac

launch_app() {
	bin="$DEST/app/gamecove.x86_64"
	[ -x "$bin" ] || die "the installer app is missing; run this script again"
	if [ "$launch" -ne 1 ]; then
		say "Downloaded. Start the installer from the app menu: GameCove Installer."
		return 0
	fi
	if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
		say "No desktop found. Switch to Desktop Mode and open \"GameCove Installer\" from the app menu."
		return 0
	fi
	say "Opening the GameCove installer"
	log "launch $bin -- --installer"
	nohup "$bin" -- --installer >/dev/null 2>&1 &
}

if [ -n "$TAG" ]; then
	url="$API/repos/$REPO/releases/tags/$TAG"
else
	url="$API/repos/$REPO/releases/latest"
fi

say "Looking up the ${TAG:-latest} GameCove release"
json=""
if ! json="$("$CURL" -fsSL -H "Accept: application/vnd.github+json" "$url" 2>/dev/null)" || [ -z "$json" ]; then
	json=""
	# releases/latest skips pre-releases, so it has nothing while only pre-releases exist
	# (v0.1.0 is one): then the newest release of any kind. A given --tag is never replaced.
	if [ -z "$TAG" ]; then
		url="$API/repos/$REPO/releases?per_page=1"
		json="$("$CURL" -fsSL -H "Accept: application/vnd.github+json" "$url" 2>/dev/null)" || json=""
		[ -n "$json" ] && log "no stable release; using the newest pre-release"
	fi
fi
if [ -z "$json" ]; then
	if [ -x "$DEST/app/gamecove.x86_64" ]; then
		say "Can't reach GitHub; using the copy downloaded before."
		launch_app
		exit 0
	fi
	die "can't reach GitHub ($url). Check the connection and try again."
fi

tag="$(printf '%s\n' "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
[ -n "$tag" ] || die "no release found at $url"
urls="$(printf '%s\n' "$json" | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')"

# pick <pattern> [exclude]: the first asset URL whose file name matches
pick() {
	for u in $urls; do
		name="${u##*/}"
		# shellcheck disable=SC2254  # the pattern is meant to glob
		case "$name" in
		$1)
			if [ -n "${2:-}" ]; then
				# shellcheck disable=SC2254
				case "$name" in $2) continue ;; esac
			fi
			echo "$u"
			return 0
			;;
		esac
	done
	return 0
}

app_url="$(pick 'gamecove-*-x86_64.tar.gz')"
sums_url="$(pick 'SHA256SUMS')"
bundle_url="$(pick 'SHA256SUMS.sigstore.json')"
script_url="$(pick 'get-gamecove.sh')"
pkg_url=""
case "$os" in
bazzite | fedora-atomic) pkg_url="$(pick 'gamecove-*.x86_64.rpm' '*.src.rpm')" ;;
steamos) pkg_url="$(pick 'gamecove-*-x86_64.raw')" ;;
esac
[ -n "$app_url" ] || die "release $tag has no app download"
[ -n "$sums_url" ] || die "release $tag has no SHA256SUMS; not installing unchecked files"
if [ "$os" != "other" ] && [ -z "$pkg_url" ]; then
	die "release $tag has no package for $os"
fi

mkdir -p "$DEST"
work="$(mktemp -d "$DEST/.download.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fetch() {
	name="${1##*/}"
	say "Downloading $name"
	"$CURL" -fsSL -o "$work/$name" "$1" || die "download failed: $1"
}

fetch "$sums_url"

# cosign: $COSIGN, the system's, else the pinned release (downloaded once, sha256 checked).
cosign_bin() {
	if [ -n "${COSIGN:-}" ]; then
		echo "$COSIGN"
		return 0
	fi
	if command -v cosign >/dev/null 2>&1; then
		command -v cosign
		return 0
	fi
	c="$DATA/tools/cosign-$COSIGN_VERSION"
	if [ ! -x "$c" ] || [ "$("$SHA256SUM" "$c" | cut -d ' ' -f 1)" != "$COSIGN_SHA256" ]; then
		mkdir -p "$DATA/tools"
		say "Downloading cosign $COSIGN_VERSION (checks the release's signature; once)" >&2
		"$CURL" -fsSL -o "$c.part" "https://github.com/sigstore/cosign/releases/download/$COSIGN_VERSION/cosign-linux-amd64" ||
			die "couldn't download cosign to check the release's signature"
		[ "$("$SHA256SUM" "$c.part" | cut -d ' ' -f 1)" = "$COSIGN_SHA256" ] || {
			rm -f "$c.part"
			die "the cosign download doesn't match its pinned sha256; nothing installed"
		}
		chmod +x "$c.part" && mv -f "$c.part" "$c"
	fi
	echo "$c"
}

signature="none"
if [ -n "$bundle_url" ]; then
	fetch "$bundle_url"
	cos="$(cosign_bin)"
	# the identity: this repository's release workflow, for a v* tag (any case: GitHub URLs aren't case-sensitive)
	ident="(?i)^https://github\.com/$(printf '%s' "$REPO" | sed 's/[.]/\\./g')/\.github/workflows/release\.yml@refs/tags/v"
	if "$cos" verify-blob --bundle "$work/SHA256SUMS.sigstore.json" \
		--certificate-oidc-issuer "$OIDC_ISSUER" --certificate-identity-regexp "$ident" \
		"$work/SHA256SUMS" >"$work/cosign.log" 2>&1; then
		signature="verified"
		say "Signature checked: made by $REPO's release workflow"
	else
		log "cosign: $(tail -n 3 "$work/cosign.log" | tr '\n' ' ')"
		die "release $tag's signature doesn't check out (not made by $REPO's release workflow, or files changed); nothing installed"
	fi
elif [ "${GAMECOVE_ALLOW_UNSIGNED:-}" = 1 ]; then
	say "warning: release $tag isn't signed; going on because GAMECOVE_ALLOW_UNSIGNED=1 (checksums still checked)"
	signature="unsigned"
else
	die "release $tag has no signature (SHA256SUMS.sigstore.json); not installing. GAMECOVE_ALLOW_UNSIGNED=1 accepts it anyway"
fi

for u in $app_url $pkg_url $script_url; do
	fetch "$u"
done

# Every file must have a line in SHA256SUMS and match it.
verify() {
	name="$1"
	want="$(awk -v n="$name" '{ f = $2; sub(/^\*/, "", f); if (f == n) { print $1; exit } }' "$work/SHA256SUMS")"
	[ -n "$want" ] || die "$name isn't listed in SHA256SUMS; not using it"
	got="$("$SHA256SUM" "$work/$name" | cut -d ' ' -f 1)"
	[ "$got" = "$want" ] || die "$name doesn't match its checksum (download damaged or changed); nothing installed"
	log "sha256 ok $name $got"
}

for u in $app_url $pkg_url $script_url; do
	verify "${u##*/}"
done
say "Checksums match"

app_file="${app_url##*/}"
rm -rf "$work/app"
mkdir -p "$work/app"
tar -xzf "$work/$app_file" -C "$work/app"
[ -f "$work/app/gamecove.x86_64" ] && [ -f "$work/app/gamecove.pck" ] || die "$app_file doesn't hold gamecove.x86_64 and gamecove.pck"
chmod +x "$work/app/gamecove.x86_64"
rm -rf "$DEST/app.old"
[ -d "$DEST/app" ] && mv "$DEST/app" "$DEST/app.old"
mv "$work/app" "$DEST/app"
rm -rf "$DEST/app.old"

package=""
if [ -n "$pkg_url" ]; then
	mkdir -p "$DEST/packages"
	rm -f "$DEST/packages/"*
	package="$DEST/packages/${pkg_url##*/}"
	mv "$work/${pkg_url##*/}" "$package"
fi
if [ -n "$script_url" ]; then
	mv "$work/get-gamecove.sh" "$DEST/get-gamecove.sh"
	chmod +x "$DEST/get-gamecove.sh"
fi

{
	echo "TAG=$tag"
	echo "VERSION=${tag#v}"
	echo "OS=$os"
	echo "PACKAGE=$package"
	echo "APP=$DEST/app/gamecove.x86_64"
	echo "REPO=$REPO"
	echo "SIGNATURE=$signature"
} >"$DEST/release.env"
log "release $tag for $os in $DEST"

# App menu entry (re-run: change options, repair, update, uninstall) and a
# desktop shortcut. Prefer the downloaded copy of this script (it looks for
# updates first); fall back to starting the app directly.
if [ -f "$DEST/get-gamecove.sh" ]; then
	exec_line="sh \"$DEST/get-gamecove.sh\""
else
	exec_line="\"$DEST/app/gamecove.x86_64\" -- --installer"
fi
apps="$HOME_DIR/.local/share/applications"
mkdir -p "$apps"
write_entry() {
	cat >"$1" <<EOF
[Desktop Entry]
Type=Application
Name=$2
Comment=Install, change, repair or remove GameCove
Exec=$exec_line
Icon=applications-games
Terminal=false
Categories=Game;Settings;
Keywords=gamecove;handheld;launcher;
EOF
}
write_entry "$apps/$APP_ID.desktop" "GameCove Installer"

desktop_dir=""
if command -v xdg-user-dir >/dev/null 2>&1; then
	desktop_dir="$(HOME="$HOME_DIR" xdg-user-dir DESKTOP 2>/dev/null || true)"
fi
[ -n "$desktop_dir" ] || desktop_dir="$HOME_DIR/Desktop"
if [ -d "$desktop_dir" ]; then
	shortcut="$desktop_dir/Install GameCove.desktop"
	write_entry "$shortcut" "Install GameCove"
	chmod +x "$shortcut"
	# GNOME wants desktop launchers marked trusted; KDE only needs +x.
	if command -v gio >/dev/null 2>&1; then
		gio set "$shortcut" metadata::trusted true >/dev/null 2>&1 || true
	fi
fi

launch_app
