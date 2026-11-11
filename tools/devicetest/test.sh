#!/bin/sh
# Tests for the device journeys runner, on any machine: everything runs as a dry
# run against a temp home with stand-ins first on PATH, so nothing of this machine
# is used or changed. Checks: the plan, a full dry run (every suite, every flag)
# writes a report with no failures and records the commands and pad presses it
# would have made, vpad's names and dry run, and the suites' lib on a fixture.
set -eu
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0
check() { # <what> <command...>
	what="$1"
	shift
	if "$@"; then echo "ok   $what"; else echo "FAIL $what"; fails=$((fails + 1)); fi
}

# stand-ins: anything a suite might start
mkdir -p "$T/bin" "$T/home/.local/share/Steam/steamapps/common/Spacewar"
for p in steam pgrep pkill xprop flatpak busctl gpu-screen-recorder rtcwake systemctl; do
	printf '#!/bin/sh\necho "$0 $*" >>"%s/started.log"\nexit 1\n' "$T" >"$T/bin/$p"
	chmod +x "$T/bin/$p"
done
cat >"$T/home/.local/share/Steam/steamapps/appmanifest_480.acf" <<'ACF'
"AppState"
{
	"appid"		"480"
	"StateFlags"		"4"
	"installdir"		"Spacewar"
}
ACF
printf 'version=0.1.0-test\n' >"$T/state"
export PATH="$T/bin:$PATH" HOME="$T/home" DT_OUT_BASE="$T/out" GC_APP="$T/none" DT_DX12_APPID=480

sh "$HERE/devicetest.sh" plan --allow-install-game --allow-sleep --rtc >"$T/plan.txt"
check "plan lists every suite" sh -c "for s in build controls steam-game optiscaler sleep session recording emudeck perf input; do grep -q \"^\$s \" '$T/plan.txt' || exit 1; done"
check "plan announces the password prompt for --rtc" grep -q "rtcwake" "$T/plan.txt"
check "plan with --suites lists only those" sh -c "sh '$HERE/devicetest.sh' plan --suites controls,perf | grep -c '^[a-z-]* *[0-9]' | grep -qx 2"

set +e
sh "$HERE/devicetest.sh" run --dry-run --allow-install-game --allow-sleep --rtc --allow-session-switch >"$T/run.txt" 2>&1
code=$?
set -e
out="$T/out/last"
check "a dry run finishes without failures (exit $code)" test "$code" -eq 0
check "it writes report.txt and results.tsv" test -s "$out/report.txt" -a -s "$out/results.tsv"
check "no FAIL line" sh -c "! grep -q '^FAIL' '$out/results.tsv'"
check "the steam game suite ran its steps" grep -q "steam-game\.\(launch\|exit\)" "$out/results.tsv"
check "the pad presses are written down, not sent" grep -q "vpad: guide" "$out/evidence/steam-game/pad.txt"
check "the commands are written down, not run" grep -q "steam://rungameid/480" "$out/evidence/steam-game/commands.txt"
check "nothing on PATH was started (only read-only lookups: pgrep, flatpak info)" sh -c "! grep -v '/pgrep \\|/flatpak info' '$T/started.log' 2>/dev/null | grep -q ."
check "report has a summary" grep -q "^PASS " "$out/report.txt"
check "report prints again" sh -c "sh '$HERE/devicetest.sh' report | grep -q 'GameCove device journeys'"
check "an unknown flag is refused" sh -c "! sh '$HERE/devicetest.sh' run --nope >/dev/null 2>&1"

check "vpad compiles" python3 -I -m py_compile "$HERE/vpad.py"
check "vpad dry run names every press" sh -c "python3 -I '$HERE/vpad.py' --dry-run seq 'a b guide qam lt up' | grep -c '^vpad:' | grep -qx 6"
check "vpad refuses an unknown name" sh -c "! python3 -I '$HERE/vpad.py' --dry-run seq 'a zz' 2>/dev/null"

# proc_sample on this shell: a number pair
check "proc_sample reads /proc" sh -c "GC_OUT='$T/o' CHECK=t DT_DIR='$HERE' sh -c '. \"$HERE/lib.sh\"; proc_sample \$\$ 1' | grep -Eq '^[0-9.]+ [0-9]+$'"

[ "$fails" -eq 0 ] && echo "devicetest: all tests passed" || { echo "devicetest: $fails failed"; exit 1; }
