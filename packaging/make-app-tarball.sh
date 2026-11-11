#!/bin/sh
# The release's app tarball (Source1 of packaging/rpm/gamecove.spec, --app of packaging/sysext/build-sysext.sh):
# gamecove.x86_64 and gamecove.pck at the top level, plus licenses/ with every file packaging/licenses.list names
# (review H8: a GPL-3.0 binary with Godot, the OFL fonts and an MIT addon inside must carry their texts).
# With <export dir>/bin/cabinet.dll there (tools/cabinet-lzms/build.sh, the release workflow's cabinet job) the
# tarball also carries bin/cabinet.dll, the LZMS cabinet.dll FSR 4 on XMX needs, and its LGPL source next to it
# (bin/cabinet-lzms-source.tar.gz). REQUIRE_CABINET=1 (release builds) fails without it, or when it isn't the
# reviewed build (tools/cabinet-lzms/cabinet.sha256).
# With <export dir>/bin/fsr4-xmx there (tools/upscalers/fetch_fsr4.py) it carries nitec's FSR 4.1.2 XMX files and
# their set.json too, unmodified; they must be the pinned set (data/versions.json "fsr4_xmx", checked here file by
# file). REQUIRE_FSR4=1 (release builds) fails without them.
#   sh packaging/make-app-tarball.sh <export dir> <out.tar.gz>
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
[ $# -eq 2 ] || {
	echo "usage: make-app-tarball.sh <export dir> <out.tar.gz>" >&2
	exit 64
}
app=$1
out=$2
for f in gamecove.x86_64 gamecove.pck; do
	[ -s "$app/$f" ] || {
		echo "make-app-tarball: $app/$f missing" >&2
		exit 1
	}
done
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -p "$app/gamecove.x86_64" "$app/gamecove.pck" "$stage/"
mkdir "$stage/licenses"
while read -r src dest; do
	case "$src" in '' | '#'*) continue ;; esac
	install -m0644 "$REPO/$src" "$stage/licenses/$dest"
done <"$REPO/packaging/licenses.list"
parts="gamecove.x86_64 gamecove.pck licenses"
if [ -s "$app/bin/cabinet.dll" ]; then
	want=$(sed -n 's/^\([0-9a-f]\{64\}\)  cabinet\.dll$/\1/p' "$REPO/tools/cabinet-lzms/cabinet.sha256")
	have=$(sha256sum "$app/bin/cabinet.dll" | cut -d' ' -f1)
	if [ "$have" != "$want" ]; then
		echo "make-app-tarball: $app/bin/cabinet.dll is $have, not the reviewed build ($want)" >&2
		[ "${REQUIRE_CABINET:-0}" = 1 ] && exit 1
	fi
	mkdir "$stage/bin"
	install -m0644 "$app/bin/cabinet.dll" "$stage/bin/cabinet.dll"
	# the source the LGPL asks to go with the binary: the folder as tracked, without build output
	tar -czf "$stage/bin/cabinet-lzms-source.tar.gz" -C "$REPO/tools" --exclude=cabinet-lzms/out \
		--sort=name --owner=0 --group=0 --numeric-owner --mtime='2026-01-01 00:00Z' cabinet-lzms
	parts="$parts bin"
elif [ "${REQUIRE_CABINET:-0}" = 1 ]; then
	echo "make-app-tarball: $app/bin/cabinet.dll missing (run tools/cabinet-lzms/build.sh and copy out/cabinet.dll there)" >&2
	exit 1
fi
if [ -d "$app/bin/fsr4-xmx" ]; then
	python3 -I "$REPO/tools/upscalers/fetch_fsr4.py" --check "$app/bin/fsr4-xmx" || {
		echo "make-app-tarball: $app/bin/fsr4-xmx isn't the pinned FSR 4.1.2 XMX set" >&2
		exit 1
	}
	mkdir -p "$stage/bin/fsr4-xmx"
	cp -p "$app/bin/fsr4-xmx"/* "$stage/bin/fsr4-xmx/"
	chmod 0644 "$stage/bin/fsr4-xmx"/*
	case " $parts " in *" bin "*) ;; *) parts="$parts bin" ;; esac
elif [ "${REQUIRE_FSR4:-0}" = 1 ]; then
	echo "make-app-tarball: $app/bin/fsr4-xmx missing (python3 tools/upscalers/fetch_fsr4.py $app/bin/fsr4-xmx)" >&2
	exit 1
fi
# One install: every upscaler file we may redistribute (tools/upscalers/fetch_bundle.py), so nothing is downloaded
# when a game is first set up. They must be exactly the pinned files. REQUIRE_UPSCALERS=1 (release builds) fails
# without them.
if [ -d "$app/bin/upscalers" ]; then
	python3 -I "$REPO/tools/upscalers/fetch_bundle.py" --check "$app/bin/upscalers" || {
		echo "make-app-tarball: $app/bin/upscalers isn't the pinned set of upscaler files" >&2
		exit 1
	}
	mkdir -p "$stage/bin/upscalers"
	for f in "$app/bin/upscalers"/*; do
		[ -f "$f" ] && install -m0644 "$f" "$stage/bin/upscalers/"
	done
	case " $parts " in *" bin "*) ;; *) parts="$parts bin" ;; esac
elif [ "${REQUIRE_UPSCALERS:-0}" = 1 ]; then
	echo "make-app-tarball: $app/bin/upscalers missing (python3 tools/upscalers/fetch_bundle.py $app/bin/upscalers --fsr4 $app/bin/fsr4-xmx)" >&2
	exit 1
fi
# shellcheck disable=SC2086 # a fixed word list
tar -czf "$out" -C "$stage" $parts
