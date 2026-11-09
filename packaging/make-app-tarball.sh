#!/bin/sh
# The release's app tarball (Source1 of packaging/rpm/gamecove.spec, --app of packaging/sysext/build-sysext.sh):
# gamecove.x86_64 and gamecove.pck at the top level, plus licenses/ with every file packaging/licenses.list names
# (review H8: a GPL-3.0 binary with Godot, the OFL fonts and an MIT addon inside must carry their texts).
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
tar -czf "$out" -C "$stage" gamecove.x86_64 gamecove.pck licenses
