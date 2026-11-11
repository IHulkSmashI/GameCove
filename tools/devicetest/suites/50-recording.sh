#!/bin/sh
# Recording, the way the quick menu's Record does it: GPU Screen Recorder (the
# Flatpak or a host install) records 5 s of the screen to the evidence folder and
# is stopped with SIGINT; the clip must be there and not empty.
. "$(dirname "$0")/../lib.sh"

clip="$CHECK_OUT/clip.mp4"
if have gpu-screen-recorder; then
	set -- gpu-screen-recorder
elif "$DT_FLATPAK" info com.dec05eba.gpu_screen_recorder >/dev/null 2>&1; then
	set -- "$DT_FLATPAK" run --command=gpu-screen-recorder com.dec05eba.gpu_screen_recorder
else
	[ "$DT_DRY" = 1 ] && { skip record "dry run"; exit 0; }
	skip record "GPU Screen Recorder isn't installed (Settings > Media offers it)"
	exit 0
fi
if [ "$DT_DRY" = 1 ]; then
	run "$@" -w screen -c mp4 -f 30 -o "$clip"
	skip record "dry run"
	exit 0
fi
d="$(gamescope_display)"
DISPLAY="${d:-${DISPLAY:-:0}}" "$@" -w screen -c mp4 -k h264 -f 30 -q very_high -cursor no -o "$clip" >"$CHECK_OUT/recorder.log" 2>&1 &
rec=$!
sleep 6
kill -INT "$rec" 2>/dev/null
n=0
while kill -0 "$rec" 2>/dev/null && [ "$n" -lt 20 ]; do sleep 0.5; n=$((n + 1)); done
kill -0 "$rec" 2>/dev/null && kill -TERM "$rec" 2>/dev/null
size="$(wc -c <"$clip" 2>/dev/null || echo 0)"
if [ "${size:-0}" -gt 10000 ]; then pass record "a 5 s clip, $size bytes (clip.mp4)"; else fail record "no clip (recorder.log)"; fi
