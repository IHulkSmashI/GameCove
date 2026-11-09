#!/bin/sh
# gamecove-selftest's automatic checks (read-only; --write only with GC_SELFTEST_WRITE=1).
. "$(dirname "$0")/lib.sh"
have "$GC_SELFTEST" || { skip run "gamecove-selftest isn't installed"; exit 0; }
set -- --no-network
[ "${GC_SELFTEST_WRITE:-0}" = 1 ] && set -- "$@" --write
"$GC_SELFTEST" "$@" >"$CHECK_OUT/selftest.txt" 2>&1
rc=$?
sum="$(grep -o 'ok=[0-9]* warn=[0-9]* fail=[0-9]*' "$CHECK_OUT/selftest.txt" | tail -n 1)"
[ "$rc" -eq 0 ] && pass run "self-test passed ($sum)" || fail run "self-test reported failures ($sum)"
grep '^\[fail\]' "$CHECK_OUT/selftest.txt" | head -n 20 | while IFS= read -r l; do fail item "${l#\[fail\] }"; done
grep '^\[warn\]' "$CHECK_OUT/selftest.txt" | head -n 20 | while IFS= read -r l; do warn item "${l#\[warn\] }"; done
manual buttons "Run 'gamecove-selftest --interactive' yourself and press each button it names (Claude reads the report)"
