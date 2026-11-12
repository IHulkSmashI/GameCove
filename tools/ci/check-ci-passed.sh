#!/bin/sh
# The release gate: CI (ci.yml) has to have passed on a commit before it is tagged and before it is signed.
#
#   sh tools/ci/check-ci-passed.sh <sha>
#
# Looks at the newest ci.yml run for exactly that commit that was a push to main (a run on another branch, a manual
# run or a pull_request run for the same sha is a different thing: a green staging run must not hide a red main one,
# and a pull_request run can pass or fail on its own) and needs it to be finished with the conclusion "success". A
# newer run still queued or in progress blocks: its answer isn't known yet, and an older green run must not stand in
# for it. Exit 0: green. Exit 1: red, running, missing or the answer couldn't be read (it fails closed).
# Environment: GH_REPO (owner/name), GH_TOKEN for gh, or CI_RUNS_JSON = a file with the API's answer (tests).
set -eu
sha="${1:?commit sha}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
if [ -n "${CI_RUNS_JSON:-}" ]; then
	cp "$CI_RUNS_JSON" "$tmp"
else
	gh api "repos/${GH_REPO:?}/actions/workflows/ci.yml/runs?head_sha=$sha&event=push&per_page=100" >"$tmp"
fi
res="$(jq -r --arg sha "$sha" '[.workflow_runs[] | select(.head_sha == $sha and .event == "push" and .head_branch == "main")]
	| sort_by(.created_at) | last | if . == null then "none" elif .status != "completed" then "still running (" + (.status // "?") + ")" else (.conclusion // "none") end' "$tmp")"
if [ "$res" != "success" ]; then
	echo "CI on $sha is \"$res\" (needs success): fix it or re-run CI on this commit, then try again" >&2
	exit 1
fi
echo "CI passed on $sha"
