#!/bin/sh
# Sleep and wake (needs --allow-sleep): the hardware checks' suspend check, which
# sleeps the handheld and compares the values, InputPlumber devices and network
# before and after. --rtc wakes it by itself after 40 s (rtcwake through pkexec:
# the password once, announced in the plan); without it, press the power button.
. "$(dirname "$0")/../lib.sh"

allowed sleep || { skip all "needs --allow-sleep (the handheld sleeps for a moment)"; exit 0; }
if [ "$DT_DRY" = 1 ]; then
	skip suspend "dry run"
	exit 0
fi
allowed rtc && export GC_RTC=1
allowed rtc || manual wake "Press the power button to wake the handheld when the screen goes off"
CHECK=suspend GC_RESULTS="$CHECK_OUT/suspend.tsv" sh "$DT_DIR/../testbed/checks/45-suspend.sh"
sed 's/^\([A-Z]*\)\tsuspend\./\1\t'"$CHECK"'./' "$CHECK_OUT/suspend.tsv" >>"$GC_RESULTS"
