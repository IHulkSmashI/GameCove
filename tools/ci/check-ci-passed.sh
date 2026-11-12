#!/bin/sh
# The release gate: CI (ci.yml) has to have passed on a commit before it is tagged and before it is signed.
#
#   sh tools/ci/check-ci-passed.sh <sha>
#
# Looks at the newest completed ci.yml run for exactly that commit (pushes and manual runs; a pull_request run
# for the same sha is a different thing, it runs on a merge of the PR into main and can pass or fail on its own,
# so it never counts either way) and needs its conclusion to be "success". Exit 0: green. Exit 1: red, missing
# or the answer couldn't be read (it fails closed).
# Environment: GH_REPO (owner/name), GH_TOKEN for gh, or CI_RUNS_JSON = a file with the API's answer (tests).
set -eu
sha="${1:?commit sha}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
if [ -n "${CI_RUNS_JSON:-}" ]; then
	cp "$CI_RUNS_JSON" "$tmp"
else
	gh api "repos/${GH_REPO:?}/actions/workflows/ci.yml/runs?head_sha=$sha&status=completed&per_page=50" >"$tmp"
fi
res="$(jq -r --arg sha "$sha" '[.workflow_runs[] | select(.head_sha == $sha and .event != "pull_request" and .event != "pull_request_target")]
	| sort_by(.created_at) | last | .conclusion // "none"' "$tmp")"
if [ "$res" != "success" ]; then
	echo "CI on $sha is \"$res\" (needs success): fix it or re-run CI on this commit, then try again" >&2
	exit 1
fi
echo "CI passed on $sha"
