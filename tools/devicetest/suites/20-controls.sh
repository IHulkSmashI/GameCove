#!/bin/sh
# TDP, fan, charge limit, brightness and volume through GameCove's real Controls on
# the real system: each set, read back from sysfs / D-Bus, and put back (the
# hardware checks' controls check, limited to these). Before/after snapshots too.
. "$(dirname "$0")/../lib.sh"

ids="power.tdp power.fan_mode power.charge_limit display.brightness audio.volume"
if [ "$DT_DRY" = 1 ]; then
	for id in $ids; do skip "probe.$id" "dry run"; done
	exit 0
fi
GC_PROBE="$ids" CHECK=controls GC_OUT="$GC_OUT" GC_RESULTS="$CHECK_OUT/controls.tsv" \
	sh "$DT_DIR/../testbed/checks/30-controls.sh"
# the controls check's results, as this suite's (MANUAL look/feel lines are the testbed's)
sed -n 's/^\(PASS\|FAIL\|WARN\|SKIP\|INFO\)\tcontrols\.\(probe\.[^\t]*\|restored\|list\)\t/\1\t'"$CHECK"'.\2\t/p' \
	"$CHECK_OUT/controls.tsv" >>"$GC_RESULTS"
grep -q 'controls.restored' "$CHECK_OUT/controls.tsv" || fail restored "the controls check didn't finish"
