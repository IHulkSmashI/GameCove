#!/bin/sh
# GameCove at rest: CPU and memory of the running app over 30 s (nothing pressed).
# Near zero is the promise: under DT_IDLE_CPU_MAX (default 2 %) at Home, and the
# 30-steam-game suite checks it behind a running game.
. "$(dirname "$0")/../lib.sh"

gc="$(gamecove_pid)"
if [ -z "$gc" ]; then
	[ "$DT_DRY" = 1 ] && { skip idle "dry run"; exit 0; }
	skip idle "GameCove isn't running (start its session)"
	exit 0
fi
s="$(proc_sample "$gc" 30)"
echo "$s" >"$CHECK_OUT/idle.txt"
cpu="${s% *}"
rss="${s#* }"
awk -v c="$cpu" -v lim="${DT_IDLE_CPU_MAX:-2}" 'BEGIN { exit !(c >= 0 && c <= lim) }' &&
	pass idle "GameCove at Home: ${cpu}% CPU, ${rss} MiB" ||
	fail idle "GameCove at Home: ${cpu}% CPU (over ${DT_IDLE_CPU_MAX:-2}%), ${rss} MiB"
