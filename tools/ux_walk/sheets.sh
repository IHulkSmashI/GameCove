#!/usr/bin/env bash
# Pad-only contact sheets (GPL-3.0, part of GameCove): the user journeys of
# app/tests/e2e/suite_journeys.gd played on the real app with a real renderer,
# one picture after every press, laid out as numbered contact sheets a person
# can read on a phone (docs/CONTROLLER-UX.md, docs/TESTING.md).
#
#   tools/ux_walk/sheets.sh [OUT_DIR] [part of a test name] [SIZES] [SUITES]
#
#   OUT_DIR  where the pictures and sheets go (default /tmp/gamecove-ux-walk)
#   test     only the journeys whose name has this part ("first_boot"); "" = all
#   SIZES    comma list of screens (default 1920x1200,1280x800)
#   SUITES   comma list of e2e suites (default journeys)
#
# GODOT=/path/to/godot overrides the binary; SETUP= the fake handheld
# (default claw8ex-bazzite); COLS= pictures per row (default 3) and ROWS= rows
# per sheet (default 3). Needs xvfb-run and ImageMagick's montage.
# Out: OUT_DIR/<size>/<setup>/<suite>__<test>/NNNN_<press>.png (every press)
#      OUT_DIR/<size>/sheets/<suite>__<test>-NN.png (the contact sheets)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="${1:-/tmp/gamecove-ux-walk}"
only="${2:-}"
sizes="${3:-1920x1200,1280x800}"
suites="${4:-journeys}"
godot="${GODOT:-godot}"
setup="${SETUP:-claw8ex-bazzite}"
cols="${COLS:-3}"
rows="${ROWS:-3}"

for tool in xvfb-run montage python3; do
	command -v "$tool" >/dev/null 2>&1 || { echo "sheets.sh: $tool is not installed" >&2; exit 2; }
done
case "$cols$rows" in *[!0-9]* | "") echo "sheets.sh: COLS and ROWS are numbers" >&2; exit 2 ;; esac

mkdir -p "$out"
out="$(cd "$out" && pwd)"
failed=0
IFS=',' read -r -a size_list <<<"$sizes"
for size in "${size_list[@]}"; do
	case "$size" in
	*[!0-9x]* | *x*x* | x* | *x | "") echo "sheets.sh: a size is WIDTHxHEIGHT, got '$size'" >&2; exit 2 ;;
	esac
	w="${size%x*}"
	h="${size#*x}"
	shots="$out/$size"
	rm -rf "$shots"
	mkdir -p "$shots/sheets"
	args=(--godot "$godot" --setups "$setup" --suites "$suites" --shots "$shots" --shots-size "$size" --timeout 3600)
	[[ -n "$only" ]] && args+=(--test "$only")
	# a journey that fails still leaves its pictures: they show where it went wrong
	python3 -I "$repo/app/tests/e2e/run.py" "${args[@]}" || failed=1
	# a tile a third of a 1080-wide phone screen held sideways stays readable: tiles keep the screen's shape
	tile_w=$((1920 / cols))
	tile_h=$((tile_w * h / w))
	found=0
	for dir in "$shots/$setup"/*/; do
		[[ -d "$dir" ]] || continue
		name="$(basename "$dir")"
		pics=("$dir"*.png)
		[[ -e "${pics[0]}" ]] || continue
		found=1
		# the caption under each picture: its number and what was pressed ("0007 Down")
		montage -label '%[t]' "${pics[@]}" -tile "${cols}x${rows}" -geometry "${tile_w}x${tile_h}+6+6" \
			-background '#0f1218' -fill '#e8eaf0' -pointsize 30 "$shots/sheets/$name-%02d.png"
		# montage writes one sheet without the number when everything fits on it
		[[ -e "$shots/sheets/$name-%02d.png" ]] && mv "$shots/sheets/$name-%02d.png" "$shots/sheets/$name-00.png"
		sed_name="${name//_/ }"
		echo "sheets.sh: $size $sed_name: ${#pics[@]} presses, sheets in $shots/sheets"
	done
	if [[ "$found" == 0 ]]; then
		echo "sheets.sh: no pictures at $size (no journey matched '$only', or the run broke before its first press)" >&2
		failed=1
	fi
done
exit "$failed"
