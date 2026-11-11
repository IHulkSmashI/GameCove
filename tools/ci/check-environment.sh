#!/bin/sh
# Checks that a deployment environment exists and is protected before a job that signs runs in it.
#
#   sh tools/ci/check-environment.sh release reviewers   the owner approves each run; only chosen refs deploy
#   sh tools/ci/check-environment.sh nightly branches    only chosen branches deploy (no approval)
#
# Why (final review, release): a job that names an environment GitHub doesn't know gets one
# created on the spot, without any protection rule. If "release" were ever deleted or renamed,
# the next tag run would sign and publish without the owner's approval; if "nightly" were, any
# branch could sign the nightly lists. So the workflows ask first (docs/RELEASING.md).
#
# Exit 1: the environment is missing, lacks the protection asked for, or GitHub wouldn't say (anything but
# HTTP 200 and 404: a rate limit, a token that may not read environments, no network): it fails closed, because
# a check that passes without an answer protects nothing. Exit 0: it is protected.
# Environment: GITHUB_REPOSITORY, GITHUB_REPOSITORY_OWNER, GH_TOKEN (optional), GITHUB_API_URL, CURL.
set -eu

name="${1:?environment name}"
need="${2:?reviewers or branches}"
api="${GITHUB_API_URL:-https://api.github.com}"
repo="${GITHUB_REPOSITORY:?}"
owner="${GITHUB_REPOSITORY_OWNER:-${repo%%/*}}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

if [ -n "${GH_TOKEN:-}" ]; then
	code="$("${CURL:-curl}" -sS -o "$tmp" -w '%{http_code}' -H "Accept: application/vnd.github+json" \
		-H "Authorization: Bearer $GH_TOKEN" "$api/repos/$repo/environments/$name" 2>/dev/null)" || code=000
else
	code="$("${CURL:-curl}" -sS -o "$tmp" -w '%{http_code}' -H "Accept: application/vnd.github+json" \
		"$api/repos/$repo/environments/$name" 2>/dev/null)" || code=000
fi

case "$code" in
200) ;;
404)
	echo "::error::the \"$name\" environment doesn't exist in $repo. A job naming it would create it without protection: create it first (docs/RELEASING.md)."
	exit 1
	;;
*)
	echo "::error::couldn't read the \"$name\" environment (HTTP $code), so its protection can't be confirmed; failing rather than signing unchecked. Run again, or see docs/RELEASING.md."
	exit 1
	;;
esac

fail() {
	echo "::error::the \"$name\" environment $1 (docs/RELEASING.md)."
	exit 1
}

# only chosen branches and tags may deploy
jq -e '.deployment_branch_policy != null and
	(.deployment_branch_policy.protected_branches == true or .deployment_branch_policy.custom_branch_policies == true)' \
	"$tmp" >/dev/null || fail "lets every branch and tag deploy; set \"Selected branches and tags\""

case "$need" in
branches) ;;
reviewers)
	jq -e '[.protection_rules[]? | select(.type == "required_reviewers") | .reviewers[]?] | length > 0' "$tmp" >/dev/null ||
		fail "has no required reviewer, so signing wouldn't wait for the owner; add $owner as required reviewer"
	jq -e --arg owner "$owner" '[.protection_rules[]? | select(.type == "required_reviewers") | .reviewers[]?
		| (.reviewer.login // "") | ascii_downcase] | index($owner | ascii_downcase) != null' "$tmp" >/dev/null ||
		fail "doesn't have the owner ($owner) as a required reviewer"
	;;
*)
	echo "check-environment: unknown check $need (reviewers or branches)" >&2
	exit 2
	;;
esac
echo "the \"$name\" environment is protected ($need)"
