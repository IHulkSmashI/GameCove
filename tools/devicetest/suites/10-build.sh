#!/bin/sh
# The build under test: which GameCove is installed, and (devicetest.sh run
# --allow-install-build) the testbed's real installer for the tag in
# $GAMECOVE_EXPECT_TAG first. The installer asks for the password itself
# (announced in the plan); nothing here types one.
. "$(dirname "$0")/../lib.sh"

if allowed install-build; then
	tb="$DT_DIR/../testbed/gamecove-testbed.sh"
	info install "running the real installer (it asks for your password; Claude can't type it)"
	if run sh "$tb" install ${GAMECOVE_EXPECT_TAG:+"$GAMECOVE_EXPECT_TAG"} >"$CHECK_OUT/install.log" 2>&1; then
		pass install "installer finished (log: install.log)"
	else
		fail install "the installer stopped (log: install.log)"
	fi
fi
if [ "$DT_DRY" != 1 ] && [ ! -x "$GC_APP" ]; then
	fail installed "GameCove isn't installed ($GC_APP missing): run with --allow-install-build"
	exit 0
fi
v="$(controls version 2>/dev/null | head -n 1)"
[ -z "$v" ] && v="$(sed -n 's/^version=//p' "$GC_DATA/install-state" 2>/dev/null | head -n 1)"
info version "${v:-unknown}"
if [ -n "${GAMECOVE_EXPECT_TAG:-}" ]; then
	case "$v" in
	*"${GAMECOVE_EXPECT_TAG#v}"*) pass tag "installed build is $GAMECOVE_EXPECT_TAG" ;;
	*) [ "$DT_DRY" = 1 ] && skip tag "dry run" || fail tag "installed build '$v' isn't $GAMECOVE_EXPECT_TAG" ;;
	esac
fi
