#!/bin/sh
# devicetest: GameCove's user journeys on a real handheld (MSI Claw 8 EX, ROG Ally,
# Legion Go S), driven with a virtual gamepad and checked on the real system.
# The headless journeys (app/tests/e2e/suite_journeys.gd) do the same on fake
# handhelds; docs/TESTING.md says which suite covers what, how long each takes and
# what needs the owner.
#
#   sh tools/devicetest/devicetest.sh plan [flags]      what would run, how long, what needs you
#   sh tools/devicetest/devicetest.sh run [flags]       run the suites, write the report
#   sh tools/devicetest/devicetest.sh report            print the last report again
#   sh tools/devicetest/devicetest.sh update            bring ~/src/GameCove to the ref under test
#
# Flags (destructive or long steps are off unless named):
#   --suites a,b             only these (names without the number: build,controls,steam-game,...)
#   --allow-install-build    run the real installer first (it asks for the password itself)
#   --allow-install-game     install, play and uninstall a free Steam game (DT_APPID, default 480)
#   --allow-sleep            sleep and wake the handheld
#   --rtc                    wake by itself after 40 s (rtcwake through pkexec: the password once)
#   --allow-session-switch   print the session switch steps and check the way back
#   --dry-run                run nothing on the system: commands and presses are only written down
#
# Results: ~/gamecove-devicetest/<date>-<device>/ with report.txt (plain PASS/FAIL
# lines and a summary), results.tsv, and evidence/<suite>/ (screenshots, logs,
# read-backs, samples). Every suite puts back what it changed (the game is
# uninstalled, settings are restored, the virtual pad is removed when it ends).
# Nothing here asks for or types a password; the steps that need one (installer,
# rtcwake) say so in `plan` first.
set -eu

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
OUT_BASE="${DT_OUT_BASE:-$HOME/gamecove-devicetest}"
SRC="${DT_SRC:-$HOME/src/GameCove}"
REF="${GAMECOVE_TESTBED_REF:-main}"

usage() { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; }

device_name() {
	v="$(head -n 1 /sys/class/dmi/id/sys_vendor 2>/dev/null || true)"
	b="$(head -n 1 /sys/class/dmi/id/board_name 2>/dev/null || true)"
	p="$(head -n 1 /sys/class/dmi/id/product_name 2>/dev/null || true)"
	case "$v|$b|$p" in
	Micro-Star*"|MS-1T91|"*) echo claw8ex ;;
	ASUSTeK*"|RC71L|"*) echo ally ;;
	LENOVO*) echo legiongos ;;
	*) echo "${DT_DEVICE:-other}" ;;
	esac
}

# suite file -> "name minutes needs" (needs: auto | hands | eyes | password | flag:<flag>)
meta() {
	case "$(basename "$1" .sh | sed 's/^[0-9]*-//')" in
	build) echo "build 1 password-with:--allow-install-build" ;;
	controls) echo "controls 3 auto" ;;
	steam-game) echo "steam-game 10 flag:--allow-install-game" ;;
	optiscaler) echo "optiscaler 4 env:DT_DX12_APPID" ;;
	sleep) echo "sleep 2 flag:--allow-sleep;password-with:--rtc;hands-without:--rtc" ;;
	session) echo "session 1 hands-with:--allow-session-switch" ;;
	recording) echo "recording 1 auto" ;;
	emudeck) echo "emudeck 2 auto(Claw)" ;;
	perf) echo "perf 1 auto" ;;
	input) echo "input 1 auto;eyes" ;;
	*) echo "$(basename "$1" .sh) 1 auto" ;;
	esac
}

selected() { # <suite file>
	[ -z "$SUITES" ] && return 0
	n="$(basename "$1" .sh | sed 's/^[0-9]*-//')"
	case ",$SUITES," in *",$n,"*) return 0 ;; esac
	return 1
}

parse_flags() {
	SUITES=""
	DT_ALLOW=""
	DT_DRY="${DT_DRY:-0}"
	while [ $# -gt 0 ]; do
		case "$1" in
		--suites) SUITES="$2"; shift ;;
		--suites=*) SUITES="${1#*=}" ;;
		--allow-install-build) DT_ALLOW="$DT_ALLOW install-build" ;;
		--allow-install-game) DT_ALLOW="$DT_ALLOW install-game" ;;
		--allow-sleep) DT_ALLOW="$DT_ALLOW sleep" ;;
		--rtc) DT_ALLOW="$DT_ALLOW rtc" ;;
		--allow-session-switch) DT_ALLOW="$DT_ALLOW session-switch" ;;
		--dry-run) DT_DRY=1 ;;
		-h | --help) usage; exit 0 ;;
		*) echo "devicetest: unknown flag $1" >&2; usage >&2; exit 2 ;;
		esac
		shift
	done
	export DT_ALLOW DT_DRY
}

plan() {
	parse_flags "$@"
	total=0
	echo "GameCove device journeys on $(device_name) ($(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | tr -d '"'))"
	echo
	printf '%-12s %5s  %s\n' SUITE MIN "NEEDS"
	for f in "$HERE"/suites/[0-9]*.sh; do
		selected "$f" || continue
		# shellcheck disable=SC2046  # meta prints three words
		set -- $(meta "$f")
		total=$((total + $2))
		printf '%-12s %5s  %s\n' "$1" "$2" "$3"
	done
	echo
	dry=""
	[ "$DT_DRY" = 1 ] && dry=" (dry run)"
	echo "About $total minutes. Flags given: ${DT_ALLOW:-none}$dry"
	echo "Password prompts (grouped, you approve them; nothing types a password):"
	case " $DT_ALLOW " in *" install-build "*) echo "  - the installer (build suite)" ;; esac
	case " $DT_ALLOW " in *" rtc "*) echo "  - rtcwake for the timed wake (sleep suite)" ;; esac
	case " $DT_ALLOW " in *" install-build "* | *" rtc "*) ;; *) echo "  - none" ;; esac
	echo "Hands / eyes: the MANUAL lines in the report (look at a screenshot, press the power button without --rtc)."
}

run_all() {
	parse_flags "$@"
	dev="$(device_name)"
	out="$OUT_BASE/$(date +%Y%m%d-%H%M%S)-$dev"
	mkdir -p "$out/evidence"
	ln -sfn "$out" "$OUT_BASE/last"
	results="$out/results.tsv"
	: >"$results"
	t0="$(date +%s)"
	echo "devicetest: $dev, results in $out"
	for f in "$HERE"/suites/[0-9]*.sh; do
		selected "$f" || continue
		name="$(basename "$f" .sh | sed 's/^[0-9]*-//')"
		s0="$(date +%s)"
		echo "== $name"
		GC_RESULTS="$results" GC_OUT="$out/evidence" CHECK="$name" DT_DIR="$HERE" \
			sh "$f" >"$out/evidence/$name.log" 2>&1 || printf 'FAIL\t%s.suite\tthe suite stopped (exit %s, see evidence/%s.log)\n' "$name" "$?" "$name" >>"$results"
		echo "   $(($(date +%s) - s0)) s"
	done
	write_report "$out" "$(($(date +%s) - t0))"
	cat "$out/report.txt"
	grep -q '^FAIL' "$results" && return 1
	return 0
}

write_report() {
	out="$1"
	secs="$2"
	r="$out/results.tsv"
	{
		echo "GameCove device journeys: $(device_name), $(date '+%Y-%m-%d %H:%M'), ${secs} s"
		echo "build: $(sed -n 's/^version=//p' "$HOME/.local/share/gamecove/install-state" 2>/dev/null | head -n 1)"
		echo
		for k in PASS FAIL WARN SKIP MANUAL; do
			printf '%-7s %s\n' "$k" "$(grep -c "^$k" "$r" || true)"
		done
		echo
		grep -E '^(FAIL|WARN)' "$r" | sed 's/\t/  /g' || true
		echo
		echo "Steps for you (MANUAL):"
		grep '^MANUAL' "$r" | sed 's/\t/  /g' || true
		echo
		echo "Everything:"
		sed 's/\t/  /g' "$r"
		echo
		echo "Evidence: $out/evidence"
	} >"$out/report.txt"
}

update() {
	if [ -d "$SRC/.git" ]; then
		git -C "$SRC" fetch --quiet origin "$REF" && git -C "$SRC" checkout --quiet FETCH_HEAD
		echo "devicetest: $SRC at $(git -C "$SRC" rev-parse --short HEAD) ($REF)"
	else
		echo "devicetest: no git checkout at $SRC (run tools/testbed/gamecove-testbed.sh prepare)" >&2
		return 1
	fi
}

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
plan) plan "$@" ;;
run) run_all "$@" ;;
report) cat "$OUT_BASE/last/report.txt" ;;
update) update ;;
"" | -h | --help) usage ;;
*) echo "devicetest: unknown command $cmd" >&2; usage >&2; exit 2 ;;
esac
