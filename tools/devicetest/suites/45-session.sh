#!/bin/sh
# Session switch and back. Read-only part: which session runs, what's the default,
# that GameCove's session is offered (the hardware checks' session check). The
# switch itself is the owner's (the quick menu's Device tab: Switch to Steam, then
# back from Steam's power menu to GameCove); --allow-session-switch prints the steps
# and checks afterwards that GameCove's session came back with the controller ours.
. "$(dirname "$0")/../lib.sh"

if [ "$DT_DRY" = 1 ]; then
	skip session "dry run"
	exit 0
fi
CHECK=session GC_RESULTS="$CHECK_OUT/session.tsv" sh "$DT_DIR/../testbed/checks/20-session.sh"
sed 's/^\([A-Z]*\)\tsession\./\1\t'"$CHECK"'./' "$CHECK_OUT/session.tsv" >>"$GC_RESULTS"
if allowed session-switch; then
	manual switch "Quick menu > Device > Switch to Steam (A twice); then Steam's power menu > Switch to GameCove; then: devicetest.sh run --suites session"
fi
if [ -n "$(gamecove_pid)" ]; then
	pass gamecove "GameCove's session is running"
	modes="$("$GC_BUSCTL" --system get-property org.shadowblip.InputPlumber /org/shadowblip/InputPlumber/CompositeDevice0 org.shadowblip.Input.CompositeDevice InterceptMode 2>/dev/null)"
	info intercept "InputPlumber InterceptMode: ${modes:-unknown}"
else
	info gamecove "GameCove's session isn't running now"
fi
