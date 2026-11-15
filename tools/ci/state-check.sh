#!/bin/sh
# Keeps docs/dev/STATE.md current (GPL-3.0, part of GameCove). Claude Code runs this when a session
# is about to stop (.claude/settings.json, the Stop hook): when the branch changes anything since
# main and docs/dev/STATE.md isn't among the changes, it says so and the session writes the update
# before it ends. STATE.md is what the next session, and any chat that is shown the file, starts
# from; a session that ends without it leaves them with yesterday's picture.
#
#   sh tools/ci/state-check.sh [BASE]     exit 0: nothing to say; exit 2: STATE.md needs its update
#
# BASE is what the work is compared with (default origin/main; main when that isn't there).
set -u
STATE="docs/dev/STATE.md"
input=""
[ -t 0 ] || input=$(cat 2>/dev/null || true)
# asked already in this stop: never twice in a row (the session would not be able to end)
case "$input" in *'"stop_hook_active":true'* | *'"stop_hook_active": true'*) exit 0 ;; esac
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$root" || exit 0
[ -f "$STATE" ] || exit 0
base="${1:-}"
if [ -z "$base" ]; then
	if git rev-parse -q --verify origin/main >/dev/null 2>&1; then base=origin/main; else base=main; fi
fi
git rev-parse -q --verify "$base" >/dev/null 2>&1 || exit 0
fork=$(git merge-base "$base" HEAD 2>/dev/null) || exit 0
changed=$( { git diff --name-only "$fork" HEAD; git status --porcelain | cut -c4-; } 2>/dev/null | sort -u)
[ -n "$changed" ] || exit 0
if printf '%s\n' "$changed" | grep -qx "$STATE"; then
	exit 0
fi
n=$(printf '%s\n' "$changed" | grep -c .)
{
	printf '%s\n' "docs/dev/STATE.md is behind: this branch changes $n file(s) since $base and STATE.md isn't one of them."
	printf '%s\n' "Update it now (where we are, what was done, what is left, anything the owner must do), commit it with the work, then stop."
} >&2
exit 2
