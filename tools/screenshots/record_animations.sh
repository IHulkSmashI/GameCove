#!/usr/bin/env bash
# Record GameCove's animations to MP4 and GIF clips (fake library, painted art,
# no network). Needs xvfb-run, ffmpeg and Godot 4.7.
#   tools/screenshots/record_animations.sh [OUT_DIR] [clip,clip] [WIDTHxHEIGHT]
# Clips: launch, launch_page, screens, moments, boot, boot_code (see record_animations.gd).
# Godot's Movie Maker renders every frame at a fixed 30 fps step, so the clips
# show the real timings however slow the machine is. GODOT=/path/to/godot.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="${1:-/tmp/gamecove-anim}"
only="${2:-}"
res="${3:-1280x800}"
godot="${GODOT:-godot}"
w="${res%x*}"
h="${res#*x}"
frames="$out/frames"
rm -rf "$frames"
mkdir -p "$frames"
args=()
[[ -n "$only" ]] && args+=(--only "$only")
"$godot" --headless --path "$repo/app" --import >/dev/null 2>&1 || true
xvfb-run -a -s "-screen 0 ${w}x${h}x24" \
	"$godot" --path "$repo/app" --rendering-driver opengl3 --resolution "$res" --position 0,0 \
	--write-movie "$frames/f.png" --fixed-fps 30 \
	-s "$here/record_animations.gd" -- "${args[@]}" 2>&1 | tee "$out/log.txt" | grep -E "^CLIP|SCRIPT ERROR" || true
grep -E "^CLIP" "$out/log.txt" | while read -r _ name first last; do
	n=$((last - first))
	ffmpeg -nostdin -y -loglevel error -framerate 30 -start_number "$first" -i "$frames/f%08d.png" -frames:v "$n" \
		-c:v libx264 -pix_fmt yuv420p -crf 20 -movflags +faststart "$out/$name.mp4"
	ffmpeg -nostdin -y -loglevel error -i "$out/$name.mp4" \
		-vf "fps=30,scale=640:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" \
		"$out/$name.gif"
	echo "wrote $out/$name.mp4 and .gif ($n frames)"
done
