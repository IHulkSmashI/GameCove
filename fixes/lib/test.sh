#!/bin/sh
# Tests for the shared fix libraries (lockdir.sh, ratelimit.sh) in a temp folder; never the real system.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail() { printf 'FAIL lib: %s\n' "$1" >&2; exit 1; }
# shellcheck source=fixes/lib/lockdir.sh
. "$HERE/lockdir.sh"

# a PID that is certainly gone, and one that runs
sh -c 'exit 0' & dead=$!; wait "$dead" || true
sleep 60 & live=$!
trap 'kill "$live" 2>/dev/null || true; rm -rf "$T"' EXIT

# ---- lockdir: a dead holder's lock is taken over, a live holder's is not
L="$T/a.lock"
mkdir "$L"; echo "$dead" >"$L/pid"
lockdir_take "$L" 3 2>/dev/null || fail "a dead holder's lock is taken over"
[ "$(cat "$L/pid")" = "$$" ] || fail "taken over with our PID"
lockdir_drop "$L"
[ ! -e "$L" ] || fail "dropped"
mkdir "$L"; echo "$live" >"$L/pid"
if lockdir_take "$L" 2 2>/dev/null; then fail "a live holder's lock is respected"; fi
[ "$(cat "$L/pid")" = "$live" ] || fail "the live holder keeps its lock"
rm -r "$L"

# ---- review problem 5: waiter A judges the holder dead; waiter B breaks the lock and takes it before A
# acts; A's break must leave B's lock alone (it used to re-read B's PID and remove B's lock)
L="$T/b.lock"
mkdir "$L"; echo "$dead" >"$L/pid"
lockdir_stale "$L" || fail "the dead holder's lock is stale"
judged_a="$_lp"
lockdir_break "$L" "$dead" || fail "B breaks"
mkdir "$L" || fail "B takes the lock"
echo "$live" >"$L/pid"
lockdir_break "$L" "$judged_a" || true
[ -d "$L" ] && [ "$(cat "$L/pid" 2>/dev/null)" = "$live" ] || fail "A's late break removed B's lock"
[ ! -e "$L.break" ] || fail "the breaker's own lock is released"
rm -r "$L"
# a holder between mkdir and writing its PID is not broken by a waiter that judged an old PID
mkdir "$L"
lockdir_break "$L" "$dead" || true
[ -d "$L" ] || fail "a fresh lock without a PID yet is left alone"
rm -r "$L"

# ---- ratelimit: at most <max> changes per window; stamps from the future (a clock stepped back) don't count
# shellcheck source=fixes/lib/ratelimit.sh
. "$HERE/ratelimit.sh"
ROOT="$T/rate"
rate_take t 2 600 || fail "first change"
rate_take t 2 600 || fail "second change"
if rate_take t 2 600; then fail "the third change in the window is refused"; fi
future=$(($(date +%s) + 7200))
mkdir -p "$ROOT/run/gamecove"
printf '%s\n%s\n' "$future" "$future" >"$ROOT/run/gamecove/rate-f"
rate_take f 2 600 || fail "stamps later than now (clock stepped back) don't lock changes out"

echo "lib tests passed"
