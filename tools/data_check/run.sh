#!/bin/sh
# Live check of every download GameCove makes from its data repo (IHulkSmashI/GameCove-data), against the real
# releases, with signature checks: the app's own code (app/tests/live/data_check.gd: game database, release
# calendar, device photos, firmware list, the signed fix list) and the upscaling helper's (tools/data_check/upscalers_live.py: the signed
# upscaler list, OptiScaler with its extras, the XeSS XMX driver, REFramework, the FSR 4 files, newest and pinned).
# It uses the network, so it's never part of the gates; run it after the data repo's workflows publish, e.g. after
# bumping its gamecove-source.env. Everything goes into a temp folder (a temp HOME too); nothing is installed.
# usage: sh tools/data_check/run.sh [--godot PATH] [gamedb] [calendar] [photos] [firmware] [fixes] [upscalers]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
godot="${GODOT:-godot}"
if [ "${1:-}" = "--godot" ]; then
	godot=$2
	shift 2
fi
work=$(mktemp -d)
trap '[ -n "${KEEP_WORK:-}" ] || rm -rf "$work"' EXIT
gd=""
up=no
[ "$#" -gt 0 ] || set -- gamedb calendar photos firmware fixes upscalers
for c in "$@"; do
	case "$c" in
	upscalers) up=yes ;;
	gamedb | calendar | photos | firmware | fixes) gd="$gd $c" ;;
	*)
		echo "unknown check: $c" >&2
		exit 2
		;;
	esac
done
# a proxy that re-signs TLS (CI sandboxes): the app's HTTPRequests trust its CA too
if [ -z "${GAMECOVE_CA_BUNDLE:-}" ] && [ -n "${SSL_CERT_FILE:-}" ]; then
	GAMECOVE_CA_BUNDLE=$SSL_CERT_FILE
	export GAMECOVE_CA_BUNDLE
fi
mkdir -p "$work/home"
fails=0
if [ -n "$gd" ]; then
	# the cosign the app and installer pin, fetched and sha256 checked by the helper's own code
	HOME="$work/home" python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from gamecove_upscale import mirror; p = mirror.cosign_path(sys.argv[2]); print("cosign:", p); sys.exit(0 if p else 1)' \
		"$repo/packaging/helpers" "$work/home"
	"$godot" --headless --path "$repo/app" --import >/dev/null 2>&1 || true
	# one Godot per check: the game database alone needs a lot of memory to parse
	for c in $gd; do
		code=0
		HOME="$work/home" XDG_DATA_HOME="$work/xdg" \
			"$godot" --headless --path "$repo/app" -s res://tests/live/data_check.gd -- "$work/app" "$c" >"$work/godot-$c.log" 2>&1 || code=$?
		grep -E "^(PASS|FAIL)|SCRIPT ERROR" "$work/godot-$c.log" || true
		if [ "$code" -ne 0 ] || grep -q "SCRIPT ERROR" "$work/godot-$c.log"; then
			echo "FAIL $c: Godot exited $code (log: $work/godot-$c.log)"
			fails=$((fails + 1))
		fi
	done
fi
if [ "$up" = yes ]; then
	HOME="$work/home-helper" python3 -I "$here/upscalers_live.py" "$work/upscalers" || fails=$((fails + 1))
fi
exit "$fails"
