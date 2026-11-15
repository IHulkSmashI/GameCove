#!/bin/sh
# Tests tools/ci/state-check.sh in throw-away repositories (never this one).
set -u
here=$(cd "$(dirname "$0")" && pwd)
pass=0
fail=0
check() {   # check <what> <expected exit> <actual exit>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL: %s (expected %s, got %s)\n' "$1" "$2" "$3" >&2; fi
}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo/docs/dev" "$repo/app"
cd "$repo" || exit 1
git init -q -b main .
git config user.email test@example.invalid
git config user.name test
echo state > docs/dev/STATE.md
echo code > app/a.gd
git add -A && git commit -q -m first
run() { sh "$here/state-check.sh" main </dev/null >/dev/null 2>&1; echo $?; }
check "nothing changed since main" 0 "$(run)"
git checkout -q -b work
echo more >> app/a.gd
check "an uncommitted change without STATE.md" 2 "$(run)"
git add -A && git commit -q -m work
check "a committed change without STATE.md" 2 "$(run)"
msg=$(sh "$here/state-check.sh" main </dev/null 2>&1 >/dev/null)
case "$msg" in *"docs/dev/STATE.md is behind"*) pass=$((pass + 1)) ;; *) fail=$((fail + 1)); printf 'FAIL: the message names the file (%s)\n' "$msg" >&2 ;; esac
again=$(printf '{"stop_hook_active":true}' | sh "$here/state-check.sh" main >/dev/null 2>&1; echo $?)
check "asked once already in this stop: let it end" 0 "$again"
echo newer >> docs/dev/STATE.md
check "STATE.md edited, not committed yet" 0 "$(run)"
git add -A && git commit -q -m state
check "STATE.md committed with the work" 0 "$(run)"
rm docs/dev/STATE.md
git add -A && git commit -q -m gone
check "a repository without the file says nothing" 0 "$(run)"
cd "$tmp" || exit 1
check "outside a repository says nothing" 0 "$(sh "$here/state-check.sh" </dev/null >/dev/null 2>&1; echo $?)"
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
