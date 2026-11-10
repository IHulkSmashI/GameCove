#!/bin/sh
# GameCove performance sample on the handheld (GPL-3.0).
#
# What a running GameCove costs over N seconds, read from /proc from outside: CPU time,
# context switches (wake-ups) per thread, RSS, threads, write syscalls, child processes.
# Run it once with home in front, once with a game in front (start the game, then run this
# over SSH or from the desktop's terminal), once with the quick menu open over the game:
#
#   sh tools/perf/device-sample.sh 60            # the newest gamecove.x86_64
#   sh tools/perf/device-sample.sh 60 <pid>
#
# GPU: GameCove draws nothing behind a game; to check, compare the GPU's busy time with
# GameCove running and stopped while the same game runs (AMD: gpu_busy_percent below;
# Intel: `sudo intel_gpu_top -l` or `sudo perf stat -e power/energy-gpu/ -a sleep 60`).
set -eu

secs="${1:-60}"
pid="${2:-$(pgrep -n -x gamecove.x86_64 || true)}"
[ -n "$pid" ] && [ -d "/proc/$pid" ] || { echo "GameCove isn't running (pass its pid)" >&2; exit 1; }
hz="$(getconf CLK_TCK)"

cpu() { awk '{ sub(/.*\) /, ""); print $12 + $13 }' "/proc/$pid/stat"; }
writes() { awk '/^syscw:/ { print $2 }' "/proc/$pid/io" 2>/dev/null || echo 0; }
threads() {
	for t in /proc/"$pid"/task/*; do
		printf '%s %s %s\n' "${t##*/}" \
			"$(awk '/ctxt_switches/ { s += $2 } END { print s + 0 }' "$t/status")" \
			"$(tr ' ' '_' <"$t/comm")"
	done | sort
}
gpu() { cat /sys/class/drm/card*/device/gpu_busy_percent 2>/dev/null | head -n 1 || true; }

a_cpu="$(cpu)"; a_w="$(writes)"; threads >/tmp/gamecove-perf-a.$$
g0="$(gpu)"
sleep "$secs"
b_cpu="$(cpu)"; b_w="$(writes)"; threads >/tmp/gamecove-perf-b.$$
g1="$(gpu)"

echo "GameCove pid $pid over ${secs}s"
awk -v a="$a_cpu" -v b="$b_cpu" -v hz="$hz" -v s="$secs" 'BEGIN { printf "CPU: %.2f %% of one core (%.1f ms/s)\n", 100 * (b - a) / hz / s, 1000 * (b - a) / hz / s }'
awk -v a="$a_w" -v b="$b_w" -v s="$secs" 'BEGIN { printf "write syscalls: %.1f/min\n", (b - a) * 60 / s }'
grep -E '^(VmRSS|Threads):' "/proc/$pid/status"
echo "wake-ups per second by thread (context switches):"
join /tmp/gamecove-perf-a.$$ /tmp/gamecove-perf-b.$$ | awk -v s="$secs" '{ d = ($4 - $2) / s; t += d; if (d >= 0.5) printf "  %-8s %-20s %8.1f\n", $1, $3, d } END { printf "  total %.1f\n", t }'
echo "child processes:"
pgrep -a -P "$pid" || echo "  none"
[ -n "$g0" ] && echo "GPU busy (AMD, instant): $g0 % -> $g1 %"
rm -f /tmp/gamecove-perf-a.$$ /tmp/gamecove-perf-b.$$
