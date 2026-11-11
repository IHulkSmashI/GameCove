#!/bin/sh
# GameCove installer bootstrap. Run it in Desktop Mode:
#
#   curl -fsSL https://raw.githubusercontent.com/IHulkSmashI/GameCove/main/packaging/get-gamecove.sh | bash
#
# What it does, and nothing more:
#   1. works out which system this is (Bazzite / Fedora Atomic, SteamOS, other)
#   2. downloads the newest GameCove release from GitHub: the app, the package
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
# Options: --no-launch (download only), --tag vX.Y.Z (a given release; a pre-release needs it
#          once a stable release exists), --detect-os (print the system type and stop), --help
#
# Which release (final review, blocker 2): the newest vX.Y.Z tag in this repository's release
# list. GitHub's releases/latest is never asked: it answers with whatever release is marked
# "latest", and this repository also publishes data releases (upscalers, firmware, device
# photos, the game database) that aren't the app. Only tags that start with v and a digit
# count; a stable release wins over a pre-release, and while only pre-releases exist (v0.1.0
# is one) the newest of those is used.
# Environment (for tests and forks): GAMECOVE_REPO, GAMECOVE_API, GAMECOVE_TAG, GAMECOVE_NOTIFY,
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
NOTIFY="${GAMECOVE_NOTIFY:-notify-send}"
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
	# Started from the app menu ("GameCove Installer", Terminal=false) nobody sees stderr: say
	# it as a desktop notification too. Never from a terminal, never fails the script.
	if [ ! -t 2 ] && command -v "$NOTIFY" >/dev/null 2>&1; then
		"$NOTIFY" -a "GameCove Installer" "GameCove Installer" "$*" >/dev/null 2>&1 || true
	fi
	exit 1
}

# The text --help prints. A function, not a read of "$0": piped into bash there is no file.
usage() {
	cat <<'EOF'
GameCove installer bootstrap. Run it in Desktop Mode:

  curl -fsSL https://raw.githubusercontent.com/IHulkSmashI/GameCove/main/packaging/get-gamecove.sh | bash

It finds this system (Bazzite / Fedora Atomic, SteamOS, other), downloads the newest GameCove
release from GitHub, checks its signature and checksums, unpacks the app into
~/.local/share/gamecove/installer, adds "GameCove Installer" to the app menu and opens the
installer, which explains each step and asks before changing anything. It needs no root and
changes nothing outside your home folder.

Options:
  --no-launch   download only, don't open the installer
  --tag vX.Y.Z  a given release (a pre-release needs it once a stable release exists)
  --detect-os   print the system type and stop
  --help        this text

With options, piped: curl -fsSL <the address above> | bash -s -- --tag v0.1.0
EOF
}

# GitHub API GET: sets body (the answer) and status (the HTTP code; 000 when unreachable).
api_get() { # <url>
	out="$("$CURL" -sSL -H "Accept: application/vnd.github+json" -w '\n%{http_code}' "$1" 2>/dev/null)" || true
	status="$(printf '%s\n' "$out" | tail -n 1 | tr -cd '0-9')"
	[ -n "$status" ] || status=000
	body="$(printf '%s\n' "$out" | sed '$d')"
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

# Everything below runs from main, called on the last line (review L29): piped into bash,
# a download cut short defines a function that never runs instead of running half a script.
main() {
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
		usage
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

# The handheld's real photo into the app's cache while we're online anyway, so it
# shows the first time GameCove opens in Game Mode, even offline. The app does
# the work (same rules as in the app: the "Show maker photos" setting, one image,
# size cap, type checked); the installer wizard does the same when it opens, so
# this is only for the runs that don't open it. Never fails the bootstrap.
prefetch_photo() {
	log "photo prefetch $1 --headless -- --prefetch-photo"
	if command -v timeout >/dev/null 2>&1; then
		timeout 45 "$1" --headless -- --prefetch-photo >/dev/null 2>&1 || true
	else
		"$1" --headless -- --prefetch-photo >/dev/null 2>&1 || true
	fi
}

launch_app() {
	bin="$DEST/app/gamecove.x86_64"
	[ -x "$bin" ] || die "the installer app is missing; run this script again"
	if [ "$launch" -ne 1 ]; then
		prefetch_photo "$bin"
		say "Downloaded. Start the installer from the app menu: GameCove Installer."
		return 0
	fi
	if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
		prefetch_photo "$bin"
		say "No desktop found. Switch to Desktop Mode and open \"GameCove Installer\" from the app menu."
		return 0
	fi
	say "Opening the GameCove installer"
	log "launch $bin -- --installer"
	nohup "$bin" -- --installer >/dev/null 2>&1 &
}

# version_lt <a> <b>: tag a (vX.Y.Z[-pre]) is older than b; numeric parts first, then a pre-release is older than
# the same version without one, pre-release labels compared the SemVer way: dot-separated, numbers as numbers
# (rc.9 < rc.10; review 2, low 20), a number before a word, fewer parts first. Anything unparsable is never "older".
version_lt() {
	awk -v a="${1#v}" -v b="${2#v}" 'BEGIN {
		pa = index(a, "-"); pb = index(b, "-")
		ra = pa ? substr(a, pa + 1) : ""; rb = pb ? substr(b, pb + 1) : ""
		if (pa) a = substr(a, 1, pa - 1)
		if (pb) b = substr(b, 1, pb - 1)
		if (a !~ /^[0-9]+(\.[0-9]+)*$/ || b !~ /^[0-9]+(\.[0-9]+)*$/) exit 1
		na = split(a, x, "."); nb = split(b, y, ".")
		n = na > nb ? na : nb
		for (i = 1; i <= n; i++) {
			if ((x[i] + 0) < (y[i] + 0)) exit 0
			if ((x[i] + 0) > (y[i] + 0)) exit 1
		}
		if (ra != "" && rb == "") exit 0
		if (ra == "" || rb == "") exit 1
		ma = split(ra, p, "."); mb = split(rb, q, ".")
		m = ma < mb ? ma : mb
		for (i = 1; i <= m; i++) {
			da = p[i] ~ /^[0-9]+$/; db = q[i] ~ /^[0-9]+$/
			if (da && db) {
				if ((p[i] + 0) < (q[i] + 0)) exit 0
				if ((p[i] + 0) > (q[i] + 0)) exit 1
			} else if (da != db) {
				exit !da
			} else {
				if (p[i] < q[i]) exit 0
				if (p[i] > q[i]) exit 1
			}
		}
		exit !(ma < mb)
	}'
}

# releases: GitHub's answer (one release, or the release list) on stdin, as lines
#   R <tag> <draft> <prerelease>     one per release, in the order GitHub gave them
#   U <url>                          that release's downloads (browser_download_url)
# Read as JSON, not by pattern: a release's notes can hold any text, and GitHub sends the
# answer on one line to some clients. Splitting on the quote character gives the text between
# strings and the strings in turn; a piece ending in an odd number of backslashes ended at an
# escaped quote, so the string goes on. Names and addresses with anything but plain URL
# characters are dropped (they are used unquoted further down).
releases() {
	awk '
	function odd(s,   n) { n = 0; while (n < length(s) && substr(s, length(s) - n, 1) == "\\") n++; return n % 2 }
	function value(k, v) {
		if (depth == base) {
			if (k == "tag_name") tag = v
			else if (k == "draft") draft = v
			else if (k == "prerelease") pre = v
		} else if (depth == base + 2 && k == "browser_download_url" && v ~ /^https:\/\/[A-Za-z0-9._~%+\/:-]+$/) {
			urls = urls "U " v "\n"
		}
	}
	function outside(seg,   k, c, rest) {
		for (k = 1; k <= length(seg); k++) {
			c = substr(seg, k, 1)
			if (c == ":") {
				key = last; want = 1
				rest = substr(seg, k + 1)
				if (rest ~ /^[ \t\r]*true/) value(key, "true")
				else if (rest ~ /^[ \t\r]*false/) value(key, "false")
			} else if (c == "{" || c == "[") {
				if (!base) base = (c == "[") ? 2 : 1
				depth++; want = 0
				if (c == "{" && depth == base) { tag = ""; draft = "false"; pre = "false"; urls = "" }
			} else if (c == "}" || c == "]") {
				if (c == "}" && depth == base && tag ~ /^[A-Za-z0-9._+-]+$/) printf "R %s %s %s\n%s", tag, draft, pre, urls
				depth--; want = 0
			} else if (c == ",") {
				want = 0
			}
		}
	}
	{
		n = split($0, f, "\"")
		i = 1
		while (i <= n) {
			outside(f[i]); i++
			if (i > n) break
			s = f[i]
			while (odd(s) && i < n) { i++; s = s "\"" f[i] }
			if (want) { value(key, s); want = 0 } else last = s
			i++
		}
	}'
}

# No release to download (GitHub unreachable or answering with an error, or no app release in
# the list): open the copy downloaded before when there is one, so "GameCove Installer" in the
# app menu still changes, repairs and removes an install. Otherwise stop with the reason.
no_release() { # <what to say with a copy> <why, without one>
	if [ -x "$DEST/app/gamecove.x86_64" ]; then
		say "$1; using the copy downloaded before."
		launch_app
		exit 0
	fi
	die "$2"
}

if [ -n "$TAG" ]; then
	url="$API/repos/$REPO/releases/tags/$TAG"
else
	url="$API/repos/$REPO/releases?per_page=100"
fi

say "Looking up the ${TAG:-newest} GameCove release"
api_get "$url"
if [ "$status" = 000 ]; then
	no_release "Can't reach GitHub" "can't reach GitHub ($url). Check the connection and try again."
elif [ "$status" != 200 ] || [ -z "$body" ]; then
	log "GitHub answered HTTP $status for $url"
	if [ -n "$TAG" ] && [ "$status" = 404 ]; then
		die "there is no GameCove release $TAG ($url)"
	fi
	no_release "GitHub answered HTTP $status" "GitHub answered HTTP $status for $url. Try again in a while."
fi
rels="$(printf '%s\n' "$body" | releases)"

# The release to use. A given --tag: exactly that one, never another. Otherwise the highest
# version among the vX... tags that aren't drafts; stable first, and only without any stable
# release the highest pre-release. A timeout, a 5xx or a rate limit never gets here (review
# M7), so an error can't swap a stable release for a pre-release.
tag=""
if [ -n "$TAG" ]; then
	tag="$(printf '%s\n' "$rels" | awk -v t="$TAG" '$1 == "R" && $2 == t { print $2; exit }')"
	[ -n "$tag" ] || die "no release found at $url"
else
	best_stable=""
	best_pre=""
	for line in $(printf '%s\n' "$rels" | awk '$1 == "R" && $3 != "true" && $2 ~ /^v[0-9]/ { print $2 ":" $4 }'); do
		t="${line%%:*}"
		if [ "${line##*:}" = true ]; then
			if [ -z "$best_pre" ] || version_lt "$best_pre" "$t"; then best_pre="$t"; fi
		else
			if [ -z "$best_stable" ] || version_lt "$best_stable" "$t"; then best_stable="$t"; fi
		fi
	done
	if [ -n "$best_stable" ]; then
		tag="$best_stable"
	elif [ -n "$best_pre" ]; then
		tag="$best_pre"
		say "No stable GameCove release yet; using the newest pre-release $tag"
	else
		no_release "GitHub lists no GameCove release" "no GameCove release found at $url. --tag vX.Y.Z picks one by name."
	fi
fi
# review problem 9: the lookup never moves an install backwards (an older, validly signed release served as newest,
# by a replayed or stale API answer); a given --tag or GAMECOVE_ALLOW_DOWNGRADE=1 may. The installed copy opens instead.
have_tag="$(sed -n 's/^TAG=//p' "$DEST/release.env" 2>/dev/null | head -n 1)"
if [ -z "$TAG" ] && [ -n "$have_tag" ] && [ "${GAMECOVE_ALLOW_DOWNGRADE:-}" != 1 ] && version_lt "$tag" "$have_tag"; then
	no_release "The newest release GitHub lists ($tag) is older than the installed $have_tag: not going back (--tag $tag or GAMECOVE_ALLOW_DOWNGRADE=1 does it on purpose)" \
		"the newest release GitHub lists ($tag) is older than the installed $have_tag; not going back. --tag $tag (or GAMECOVE_ALLOW_DOWNGRADE=1) does it on purpose"
fi
urls="$(printf '%s\n' "$rels" | awk -v t="$tag" '$1 == "R" { on = ($2 == t) } $1 == "U" && on { print $2 }')"

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
	# the identity: this repository's release workflow, run for exactly this tag (review M5: an older, genuinely signed
	# release can't be swapped in under a newer tag), any case (GitHub URLs aren't case-sensitive)
	ident="(?i)^https://github\.com/$(printf '%s' "$REPO" | sed 's/[.]/\\./g')/\.github/workflows/release\.yml@refs/tags/$(printf '%s' "$tag" | sed 's/[][\\.*^$+?(){}|]/\\&/g')\$"
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
}

main "$@"
