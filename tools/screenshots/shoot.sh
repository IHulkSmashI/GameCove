#!/usr/bin/env bash
# Render GameCove screens with fake data to PNGs (needs xvfb-run and Godot 4.7).
#   tools/screenshots/shoot.sh [OUT_DIR] [WIDTHxHEIGHT] [only,these,shots]
# GODOT=/path/to/godot overrides the binary. Shot names: see shoot.gd.
# SHOOT_SCRIPT=shoot_device.gd renders the device pages instead (shot names in that file).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="${1:-/tmp/gamecove-shots}"
res="${2:-1280x800}"
only="${3:-}"
godot="${GODOT:-godot}"
w="${res%x*}"
h="${res#*x}"
args=(--out "$out")
[[ -n "$only" ]] && args+=(--only "$only")
[[ "$res" != "1280x800" ]] && args+=(--suffix "_$w")
"$godot" --headless --path "$repo/app" --import >/dev/null 2>&1 || true
xvfb-run -a -s "-screen 0 ${w}x${h}x24" \
	"$godot" --path "$repo/app" --rendering-driver opengl3 --resolution "$res" --position 0,0 \
	-s "$here/${SHOOT_SCRIPT:-shoot.gd}" -- "${args[@]}"
