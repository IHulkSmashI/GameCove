#!/bin/sh
# Runs fix.sh against fake sysfs trees in temp folders, with a stub systemctl; never the real system.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
FIX="$HERE/fix.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
w() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }
r() { cat "$1"; }
# expect <code> <what> <args...>
expect() {
	want="$1"; what="$2"; shift 2
	set +e; sh "$FIX" "$@" >"$T/out" 2>&1; got=$?; set -e
	[ "$got" = "$want" ] || fail "$what: exit $got, want $want ($(cat "$T/out"))"
}
dmi() {
	w "$1/sys/class/dmi/id/sys_vendor" "$2"; w "$1/sys/class/dmi/id/product_name" "$3"
	w "$1/sys/class/dmi/id/board_name" "$4"; w "$1/sys/class/dmi/id/board_vendor" "$2"
}

python3 -I "$HERE/tests/gen_handhelds.py" --check || fail "handhelds.txt is stale"

# systemctl stub: thermald state in a file
mkdir -p "$T/bin"
cat > "$T/bin/systemctl" <<'EOF'
#!/bin/sh
f="$GAMECOVE_ROOT/thermald.state"
case "$1 ${2:-}" in
"is-active thermald.service") cat "$f" 2>/dev/null || echo inactive ;;
"stop thermald.service") echo inactive > "$f"; echo "stop" >> "$GAMECOVE_ROOT/systemctl.log"
	# the caller is killed right after thermald stopped (gamecove-fix-set's time limit)
	if [ -f "$GAMECOVE_ROOT/stop-kills-caller" ]; then kill -KILL "$PPID"; fi ;;
"start thermald.service") echo active > "$f"; echo "start" >> "$GAMECOVE_ROOT/systemctl.log" ;;
*) echo "$*" >> "$GAMECOVE_ROOT/systemctl-other.log" ;;
esac
EOF
chmod +x "$T/bin/systemctl"
# pgrep stub: a game runs while $T/game exists (the thermald hold's watcher asks)
cat > "$T/bin/pgrep" <<EOF
#!/bin/sh
echo "pgrep \$*" >> "$T/pgrep.log"
[ -f "$T/game" ]
EOF
chmod +x "$T/bin/pgrep"
: > "$T/game"
GAMECOVE_THERMALD_GRACE_S=0.3 GAMECOVE_THERMALD_CHECK_S=0.2; export GAMECOVE_THERMALD_GRACE_S GAMECOVE_THERMALD_CHECK_S
PATH="$T/bin:$PATH"; export PATH

# ---- Intel handheld (MSI Claw 8 EX): intel_pstate, xe, RAPL, no SMT ------------------------------------------
R="$T/claw"; export GAMECOVE_ROOT="$R"; C="$R/sys/devices/system/cpu"
dmi "$R" "Micro-Star International Co., Ltd." "Claw 8 EX AI+ CG3EM" "MS-1T91"
for n in 0 1 2 3; do
	w "$C/cpu$n/cpufreq/energy_performance_preference" balance_performance
	w "$C/cpu$n/cpufreq/energy_performance_available_preferences" "default performance balance_performance balance_power power"
	[ "$n" = 0 ] || w "$C/cpu$n/online" 1
done
w "$C/cpu0/cpufreq/scaling_governor" powersave
w "$C/cpu0/cpufreq/scaling_available_governors" "performance powersave"
w "$C/intel_pstate/no_turbo" 0
w "$C/intel_pstate/max_perf_pct" 100
w "$C/intel_pstate/min_perf_pct" 40
w "$C/smt/control" notsupported
G="$R/sys/class/drm/card1/device/tile0/gt0/freq0"
w "$R/sys/class/drm/card1/device/uevent" "DRIVER=xe"
w "$G/min_freq" 100; w "$G/max_freq" 2300; w "$G/rpn_freq" 100; w "$G/rp0_freq" 2300
w "$G/power_profile" "[base] power_saving"
P="$R/sys/class/powercap/intel-rapl-mmio:0"
w "$P/name" package-0; w "$P/constraint_0_name" long_term; w "$P/constraint_0_time_window_us" 55967744
w "$P/constraint_1_name" short_term; w "$P/constraint_1_time_window_us" 976
w "$R/sys/power/mem_sleep" "[s2idle] deep"
echo active > "$R/thermald.state"

expect 0 "boost off" set boost:off
[ "$(r "$C/intel_pstate/no_turbo")" = 1 ] || fail "intel boost off is no_turbo=1"
expect 0 "boost on" set boost:on
[ "$(r "$C/intel_pstate/no_turbo")" = 0 ] || fail "intel boost on"
expect 2 "boost value" set boost:maybe
expect 2 "smt not supported" set smt:off
expect 0 "epp" set epp:balance_power
[ "$(r "$C/cpu3/cpufreq/energy_performance_preference")" = balance_power ] || fail "epp on every CPU"
expect 2 "epp not offered" set epp:turbo
expect 2 "epp injection" set "epp:power;reboot"
expect 0 "governor" set governor:performance
expect 2 "governor not offered" set governor:ondemand
expect 0 "cpumax" set cpumax:70
[ "$(r "$C/intel_pstate/max_perf_pct")" = 70 ] || fail "max_perf_pct 70"
expect 0 "cpumax under min_perf_pct" set cpumax:30
[ "$(r "$C/intel_pstate/max_perf_pct")" = 40 ] || fail "max_perf_pct never under min_perf_pct"
expect 2 "cpumax too low" set cpumax:20
expect 2 "cpumax too high" set cpumax:101
# review M1: "050" passes [ -ge 30 ] but is octal 40 in $((...)): no leading zeros anywhere
expect 2 "cpumax leading zero" set cpumax:050
expect 2 "cores leading zero" set cores:02
expect 2 "tau leading zero" set tau:08000000
expect 2 "gpumax leading zero" set gpumax:02000
expect 0 "cores 2" set cores:2
[ "$(r "$C/cpu1/online") $(r "$C/cpu2/online") $(r "$C/cpu3/online")" = "1 0 0" ] || fail "two CPUs online"
expect 2 "cores 1" set cores:1
expect 2 "cores over total" set cores:5
expect 0 "gpu floor" set gpumin:1000
[ "$(r "$G/min_freq")" = 1000 ] || fail "xe floor"
expect 2 "gpu floor above ceiling" set gpumax:900
expect 2 "gpu over rp0" set gpumax:2400
expect 2 "gpu under rpn" set gpumin:50
expect 0 "gpu ceiling" set gpumax:2000
expect 0 "gpu profile" set gpuprofile:power_saving
[ "$(r "$G/power_profile")" = power_saving ] || fail "xe power profile"
expect 2 "gpu profile not offered" set gpuprofile:turbo
expect 2 "gpulevel on Intel" set gpulevel:high
expect 0 "tau 8 s" set tau:8000000
[ "$(r "$P/constraint_0_time_window_us")" = 8000000 ] || fail "PL1 window"
expect 2 "tau longer than the firmware's" set tau:90000000
expect 2 "tau under 1 s" set tau:500
expect 0 "thermald hold" set thermald:hold
[ "$(r "$R/thermald.state")" = inactive ] || fail "thermald stopped"
expect 0 "sleep deep" set sleep:deep
[ "$(r "$R/sys/power/mem_sleep")" = deep ] || fail "mem_sleep deep"
expect 2 "sleep other" set sleep:hibernate
expect 2 "sppt without attribute" set sppt:20
expect 2 "unknown key" set fan:max
expect 2 "no key" set 15
sh "$FIX" status > "$T/st"
grep -q '^installed=yes$' "$T/st" || fail "status installed"
grep -q '^orig_epp-0=balance_performance$' "$T/st" || fail "status shows the recorded EPP"
grep -q '^thermald=held$' "$T/st" || fail "status shows thermald held"
tail -n 1 "$T/st" | grep -q '^state=on$' || fail "status ends state=on"
expect 0 "restore" set restore
[ "$(r "$C/cpu2/cpufreq/energy_performance_preference")" = balance_performance ] || fail "EPP back"
[ "$(r "$C/intel_pstate/max_perf_pct") $(r "$C/intel_pstate/no_turbo")" = "100 0" ] || fail "CPU ceiling and boost back"
[ "$(r "$C/cpu2/online") $(r "$C/cpu3/online")" = "1 1" ] || fail "cores back online"
[ "$(r "$G/min_freq") $(r "$G/max_freq")" = "100 2300" ] || fail "GPU window back"
[ "$(r "$G/power_profile")" = base ] || fail "GPU profile back"
[ "$(r "$P/constraint_0_time_window_us")" = 55967744 ] || fail "PL1 window back"
[ "$(r "$R/sys/power/mem_sleep")" = s2idle ] || fail "mem_sleep back"
[ "$(r "$R/thermald.state")" = active ] || fail "thermald started again"
[ "$(r "$C/cpu0/cpufreq/scaling_governor")" = powersave ] || fail "governor back"
sh "$FIX" status | grep -q '^installed=no$' || fail "nothing recorded after restore"
expect 0 "restore again is a no-op" set restore
grep -q 'set epp=balance_power' "$R/var/lib/gamecove/fixes/power-tune/changes.log" || fail "changes logged"
# review S3-2: a hold never outlives the game: the watcher starts thermald again once no game runs
echo active > "$R/thermald.state"
PKEXEC_UID=1000 expect 0 "thermald hold during a game" set thermald:hold
[ "$(r "$R/thermald.state")" = inactive ] || fail "thermald stopped for the game"
sleep 1
[ "$(r "$R/thermald.state")" = inactive ] || fail "still held while the game runs"
grep -q "pgrep -u 1000 -f" "$T/pgrep.log" || fail "the watcher looks only at the caller's games"
[ ! -e "$R/var/lib/gamecove/fixes/power-tune/thermald-watch" ] || fail "the watcher PID is not kept under /var/lib (review M3)"
PKEXEC_UID=1000 expect 0 "a second hold replaces the watcher" set thermald:hold
rm -f "$T/game"
n=0; while [ "$(r "$R/thermald.state")" != active ] && [ "$n" -lt 30 ]; do sleep 0.2; n=$((n + 1)); done
[ "$(r "$R/thermald.state")" = active ] || fail "thermald starts again by itself when the game is gone"
[ ! -e "$R/var/lib/gamecove/fixes/power-tune/thermald-held" ] || fail "hold marker cleared"
grep -q "thermald released: no game running" "$R/var/lib/gamecove/fixes/power-tune/changes.log" || fail "the release is logged"
expect 0 "hold at home (no game)" set thermald:hold
n=0; while [ "$(r "$R/thermald.state")" != active ] && [ "$n" -lt 30 ]; do sleep 0.2; n=$((n + 1)); done
[ "$(r "$R/thermald.state")" = active ] || fail "without a game the hold ends after the start-up grace"
: > "$T/game"
# review M20: a library game (Heroic/umu/emulator) runs in a systemd-run user scope that no command line
# names (pgrep finds nothing): its populated app-steam-app scope keeps the hold; another user's doesn't
rm -f "$T/game"
CG="$R/sys/fs/cgroup/user.slice"
w "$CG/user-1000.slice/user@1000.service/app.slice/app-steam-app1234567890-1.scope/cgroup.events" "populated 1
frozen 0"
w "$CG/user-1001.slice/user@1001.service/app.slice/app-steam-app42-1.scope/cgroup.events" "populated 1"
echo active > "$R/thermald.state"
PKEXEC_UID=1000 expect 0 "hold for a library game" set thermald:hold
sleep 1.2
[ "$(r "$R/thermald.state")" = inactive ] || fail "a library game in its scope keeps the hold (review M20)"
w "$CG/user-1000.slice/user@1000.service/app.slice/app-steam-app1234567890-1.scope/cgroup.events" "populated 0
frozen 0"
n=0; while [ "$(r "$R/thermald.state")" != active ] && [ "$n" -lt 30 ]; do sleep 0.2; n=$((n + 1)); done
[ "$(r "$R/thermald.state")" = active ] || fail "an empty scope (game gone) ends the hold; another user's game doesn't count"
rm -rf "$R/sys/fs/cgroup"
: > "$T/game"
# review M3 (proof 9.2 B): a PID left from before a reboot, or one that isn't a watcher, is never killed
sleep 300 & victim=$!
w "$R/var/lib/gamecove/fixes/power-tune/thermald-watch" "$victim"
echo active > "$R/thermald.state"
expect 0 "hold with a stale PID under /var/lib" set thermald:hold
sleep 0.3
kill -0 "$victim" 2>/dev/null || fail "an unrelated process named by the old /var/lib PID file was killed"
[ ! -e "$R/var/lib/gamecove/fixes/power-tune/thermald-watch" ] || fail "the old PID file is dropped"
w "$R/run/gamecove/power-tune-thermald-watch.pid" "$victim"
expect 0 "hold with a PID file naming a non-watcher" set thermald:hold
sleep 0.3
kill -0 "$victim" 2>/dev/null || fail "a process that isn't a watcher was killed"
kill "$victim"
n=0; while [ "$(r "$R/thermald.state")" != active ] && [ "$n" -lt 30 ]; do sleep 0.2; n=$((n + 1)); done
# with systemd running, the watcher is a transient system unit (outside the session's cgroup)
printf '#!/bin/sh\necho "systemd-run $*" >> "%s/systemd-run.log"\n' "$T" > "$T/bin/systemd-run"
chmod +x "$T/bin/systemd-run"
mkdir -p "$R/run/systemd/system"; rm -f "$R/run/gamecove/power-tune-thermald-watch.pid" "$R/systemctl-other.log"
echo active > "$R/thermald.state"
PKEXEC_UID=1000 expect 0 "hold through systemd-run" set thermald:hold
grep -q "^systemd-run --unit=gamecove-thermald-watch --collect --quiet .*power-tune/fix.sh thermald-watch 1000$" "$T/systemd-run.log" || fail "watcher started as a transient unit ($(cat "$T/systemd-run.log"))"
[ ! -e "$R/run/gamecove/power-tune-thermald-watch.pid" ] || fail "no PID file for a unit"
grep -q "^stop gamecove-thermald-watch.service$" "$R/systemctl-other.log" || fail "a previous watcher unit is stopped first"
expect 0 "release after the systemd-run hold" set thermald:release
rm -r "$R/run/systemd"; rm "$T/bin/systemd-run"
# thermald already stopped by someone else: hold changes nothing, release doesn't start it
echo inactive > "$R/thermald.state"; : > "$R/systemctl.log"
expect 0 "hold when inactive" set thermald:hold
expect 0 "release without hold" set thermald:release
[ ! -s "$R/systemctl.log" ] || fail "thermald left alone when GameCove didn't stop it"
# review problem 7: the hold is recorded before thermald stops, so a hold killed right after the stop
# (exit 124 from gamecove-fix-set's time limit) still leaves a marker and a restore starts thermald
echo active > "$R/thermald.state"; : > "$R/stop-kills-caller"
GAMECOVE_THERMALD_WATCH=off expect 137 "hold killed right after thermald stopped" set thermald:hold
rm -f "$R/stop-kills-caller"
[ "$(r "$R/thermald.state")" = inactive ] || fail "p7: thermald was stopped"
[ -e "$R/var/lib/gamecove/fixes/power-tune/thermald-held" ] || fail "p7: the hold is recorded although the run was killed"
expect 0 "release after the killed hold" set thermald:release
[ "$(r "$R/thermald.state")" = active ] || fail "p7: the release starts thermald again"
# a hold that can't stop thermald leaves no marker
printf '#!/bin/sh\ncase "$1 ${2:-}" in "is-active thermald.service") echo active ;; "stop thermald.service") exit 1 ;; esac\n' >"$T/bin/systemctl.fail"
chmod +x "$T/bin/systemctl.fail"; mv "$T/bin/systemctl" "$T/bin/systemctl.ok"; mv "$T/bin/systemctl.fail" "$T/bin/systemctl"
GAMECOVE_THERMALD_WATCH=off expect 1 "hold whose stop fails" set thermald:hold
mv "$T/bin/systemctl.ok" "$T/bin/systemctl"
[ ! -e "$R/var/lib/gamecove/fixes/power-tune/thermald-held" ] || fail "p7: no marker when thermald couldn't be stopped"
# review problem 9: a hold while thermald is already held by us starts a watcher again when the last one died
echo active > "$R/thermald.state"; : > "$T/game"
PKEXEC_UID=1000 expect 0 "hold during a game (watcher)" set thermald:hold
wp="$(cat "$R/run/gamecove/power-tune-thermald-watch.pid")"
kill "$wp"; n=0; while kill -0 "$wp" 2>/dev/null && [ "$n" -lt 30 ]; do sleep 0.1; n=$((n + 1)); done
PKEXEC_UID=1000 expect 0 "hold again with the watcher gone" set thermald:hold
wp2="$(cat "$R/run/gamecove/power-tune-thermald-watch.pid" 2>/dev/null || true)"
[ -n "$wp2" ] && [ "$wp2" != "$wp" ] && kill -0 "$wp2" 2>/dev/null || fail "p9: a new watcher runs for the hold"
rm -f "$T/game"
n=0; while [ "$(r "$R/thermald.state")" != active ] && [ "$n" -lt 30 ]; do sleep 0.2; n=$((n + 1)); done
[ "$(r "$R/thermald.state")" = active ] || fail "p9: the new watcher releases thermald once the game is gone"
# tau restore alone
expect 0 "tau" set tau:8000000
expect 0 "tau restore" set tau:restore
[ "$(r "$P/constraint_0_time_window_us")" = 55967744 ] || fail "tau:restore"
# a refused write fails with exit 1 and nothing half-recorded breaks restore
rm -f "$C/cpu1/cpufreq/energy_performance_preference"; mkdir "$C/cpu1/cpufreq/energy_performance_preference"
expect 1 "refused write" set epp:power
rmdir "$C/cpu1/cpufreq/energy_performance_preference"; w "$C/cpu1/cpufreq/energy_performance_preference" balance_performance
expect 0 "restore after a refused write" set restore
[ "$(r "$C/cpu0/cpufreq/energy_performance_preference")" = balance_performance ] || fail "cpu0 EPP back after a refused write"
[ ! -e "$R/run/gamecove-power-tune.lock" ] || fail "lock released"
# values recorded on another handheld (same drive) are never written here
expect 0 "epp before switching handhelds" set epp:power
dmi "$R" "ASUSTeK COMPUTER INC." "ROG Ally RC71L" "RC71L"
expect 0 "restore on another handheld" set restore
[ "$(r "$C/cpu0/cpufreq/energy_performance_preference")" = power ] || fail "another handheld's values dropped, not written"

# ---- AMD handheld (ROG Ally): cpufreq boost, SMT, amdgpu, asus-armoury PPT --------------------------------------
R="$T/ally"; export GAMECOVE_ROOT="$R"; C="$R/sys/devices/system/cpu"
dmi "$R" "ASUSTeK COMPUTER INC." "ROG Ally RC71L" "RC71L"
w "$C/cpufreq/boost" 1
w "$C/smt/control" on
for n in 0 1; do
	w "$C/cpufreq/policy$n/cpuinfo_max_freq" 5100000; w "$C/cpufreq/policy$n/cpuinfo_min_freq" 400000
	w "$C/cpufreq/policy$n/scaling_max_freq" 5100000
	w "$C/cpufreq/policy$n/scaling_governor" powersave; w "$C/cpufreq/policy$n/scaling_available_governors" "performance powersave"
	mkdir -p "$C/cpu$n"
done
D="$R/sys/class/drm/card0/device"
w "$D/uevent" "DRIVER=amdgpu"
w "$D/power_dpm_force_performance_level" auto
printf 'OD_SCLK:\n0: 800Mhz\n1: 2700Mhz\nOD_RANGE:\nSCLK:     800Mhz       2700Mhz\n' > "$D/pp_od_clk_voltage"
A="$R/sys/class/firmware-attributes/asus-armoury/attributes"
for a in ppt_pl1_spl:15:7:25 ppt_pl2_sppt:20:15:30 ppt_pl3_fppt:25:15:35; do
	n="${a%%:*}"; rest="${a#*:}"
	w "$A/$n/current_value" "${rest%%:*}"; rest="${rest#*:}"
	w "$A/$n/min_value" "${rest%%:*}"; w "$A/$n/max_value" "${rest#*:}"
done
w "$R/sys/firmware/acpi/platform_profile" balanced
w "$R/sys/firmware/acpi/platform_profile_choices" "quiet balanced performance"

expect 0 "amd boost off" set boost:off
[ "$(r "$C/cpufreq/boost")" = 0 ] || fail "cpufreq boost 0"
expect 0 "smt off" set smt:off
[ "$(r "$C/smt/control")" = off ] || fail "smt off"
expect 2 "cpumax amd leading zero (octal 40 %)" set cpumax:050
[ "$(r "$C/cpufreq/policy1/scaling_max_freq")" = 5100000 ] || fail "nothing written for cpumax:050"
expect 0 "cpumax amd" set cpumax:50
[ "$(r "$C/cpufreq/policy1/scaling_max_freq")" = 2550000 ] || fail "scaling_max_freq 50 %"
expect 0 "gpu level high" set gpulevel:high
expect 2 "gpu level other" set gpulevel:turbo
expect 0 "amd gpu floor" set gpumin:1200
[ "$(r "$D/power_dpm_force_performance_level")" = manual ] || fail "amd clocks need the manual level"
expect 2 "amd gpu over range" set gpumax:3000
expect 0 "sppt" set sppt:28
[ "$(r "$A/ppt_pl2_sppt/current_value")" = 28 ] || fail "sppt written"
# the handheld check (lib/handheld.sh) once clobbered fix.sh's $key: "board_name=28" (end-to-end suite)
[ "$(cat "$T/out")" = "sppt=28" ] || fail "sppt reports its own key, got: $(cat "$T/out")"
expect 2 "sppt over the firmware max" set sppt:31
expect 2 "sppt under spl" set sppt:14
expect 2 "fppt under sppt" set fppt:27
expect 0 "fppt" set fppt:33
expect 0 "platform" set platform:performance
expect 2 "platform not offered" set platform:turbo
expect 2 "battery mode without charge_types" set battery:long-life
expect 0 "restore ally" set restore
[ "$(r "$C/cpufreq/boost") $(r "$C/smt/control")" = "1 on" ] || fail "boost and SMT back"
[ "$(r "$A/ppt_pl2_sppt/current_value") $(r "$A/ppt_pl3_fppt/current_value")" = "20 25" ] || fail "PPT back"
[ "$(r "$C/cpufreq/policy0/scaling_max_freq")" = 5100000 ] || fail "scaling_max_freq back"
[ "$(r "$D/power_dpm_force_performance_level")" = auto ] || fail "GPU level back"
[ "$(r "$R/sys/firmware/acpi/platform_profile")" = balanced ] || fail "platform profile back"
# ASUS order (hhd asus driver): thermal profile first, then the PPT values
expect 0 "ally sppt for order" set sppt:28
expect 0 "ally platform for order" set platform:performance
mv "$A/ppt_pl2_sppt/current_value" "$T/cv"; mkdir "$A/ppt_pl2_sppt/current_value"
mv "$R/sys/firmware/acpi/platform_profile" "$T/pp"; mkdir "$R/sys/firmware/acpi/platform_profile"
expect 1 "ally restore order probe" set restore
grep -q "could not put back: platform sppt" "$T/out" || fail "ally: platform before sppt ($(cat "$T/out"))"
rmdir "$A/ppt_pl2_sppt/current_value" "$R/sys/firmware/acpi/platform_profile"; mv "$T/cv" "$A/ppt_pl2_sppt/current_value"; mv "$T/pp" "$R/sys/firmware/acpi/platform_profile"
expect 0 "ally restore after probe" set restore
# the same attributes on a laptop are never written
dmi "$R" "ASUSTeK COMPUTER INC." "ROG Zephyrus G14" "GA403UV"
expect 2 "laptop sppt refused" set sppt:25
[ "$(r "$A/ppt_pl2_sppt/current_value")" = 20 ] || fail "laptop untouched"

# review M2 (proof 9.2 A): restore never stops halfway. cores:N then smt:off; at restore the kernel won't
# online an SMT sibling (a fake file can't refuse a write, so the node is made unusable). Every other key
# still comes back, SMT comes back BEFORE the cores (so on real hardware the siblings can come online),
# thermald is released, and the failure names what is left.
R="$T/m2"; export GAMECOVE_ROOT="$R"; C="$R/sys/devices/system/cpu"
dmi "$R" "Micro-Star International Co., Ltd." "Claw 8 EX AI+ CG3EM" "MS-1T91"
for n in 0 1 2 3; do w "$C/cpu$n/online" 1; done
w "$C/smt/control" on; w "$C/intel_pstate/max_perf_pct" 100; w "$C/intel_pstate/min_perf_pct" 10; w "$C/intel_pstate/no_turbo" 0
echo active > "$R/thermald.state"
GAMECOVE_THERMALD_WATCH=off expect 0 "m2 cores" set cores:2
expect 0 "m2 cpumax" set cpumax:30
expect 0 "m2 smt off" set smt:off
expect 0 "m2 boost off" set boost:off
GAMECOVE_THERMALD_WATCH=off expect 0 "m2 thermald hold" set thermald:hold
rm "$C/cpu3/online"; mkdir "$C/cpu3/online"
expect 1 "m2 restore with a CPU that won't come online" set restore
grep -q "could not put back: cores" "$T/out" || fail "m2: the failure names the key left ($(cat "$T/out"))"
[ "$(r "$C/intel_pstate/max_perf_pct") $(r "$C/intel_pstate/no_turbo")" = "100 0" ] || fail "m2: keys after cores still come back"
[ "$(r "$C/smt/control")" = on ] || fail "m2: SMT back"
[ "$(r "$C/cpu2/online")" = 1 ] || fail "m2: the CPUs that can come online do"
[ "$(r "$R/thermald.state")" = active ] || fail "m2: thermald released even though a key failed"
[ "$(ls "$R/var/lib/gamecove/fixes/power-tune/orig")" = cores ] || fail "m2: only the failed key stays recorded"
rmdir "$C/cpu3/online"; w "$C/cpu3/online" 0
expect 0 "m2 restore again once the CPU can come online" set restore
[ "$(r "$C/cpu3/online")" = 1 ] || fail "m2: cores back on the second restore"
# order: SMT before cores (the failure list is in the order keys were tried)
expect 0 "m2 cores again" set cores:2
expect 0 "m2 smt again" set smt:off
rm "$C/cpu3/online"; mkdir "$C/cpu3/online"; rm "$C/smt/control"; mkdir "$C/smt/control"
expect 1 "m2 both refused" set restore
grep -q "could not put back: smt cores" "$T/out" || fail "m2: smt is restored before cores ($(cat "$T/out"))"
rmdir "$C/cpu3/online" "$C/smt/control"

# amd-pstate: boost per policy, no global switch
R="$T/pstate"; export GAMECOVE_ROOT="$R"; C="$R/sys/devices/system/cpu"
dmi "$R" "ASUSTeK COMPUTER INC." "ROG Ally X RC72LA" "RC72LA"
for n in 0 1; do w "$C/cpufreq/policy$n/boost" 1; w "$C/cpufreq/policy$n/scaling_governor" powersave; mkdir -p "$C/cpu$n"; done
expect 0 "pstate boost off" set boost:off
[ "$(r "$C/cpufreq/policy0/boost") $(r "$C/cpufreq/policy1/boost")" = "0 0" ] || fail "per-policy boost off"
# older asus-armoury: ppt_fppt; MCU power saving
A="$R/sys/class/firmware-attributes/asus-armoury/attributes"
w "$A/ppt_pl1_spl/current_value" 17; w "$A/ppt_pl1_spl/min_value" 7; w "$A/ppt_pl1_spl/max_value" 25
w "$A/ppt_fppt/current_value" 30; w "$A/ppt_fppt/min_value" 15; w "$A/ppt_fppt/max_value" 35
w "$A/mcu_powersave/current_value" 1
expect 0 "fppt under its older name" set fppt:32
[ "$(r "$A/ppt_fppt/current_value")" = 32 ] || fail "ppt_fppt written"
expect 0 "mcu off" set mcu:off
[ "$(r "$A/mcu_powersave/current_value")" = 0 ] || fail "mcu_powersave 0"
expect 2 "mcu other" set mcu:maybe
# review S1-3: on only with new enough MCU firmware; off always
printf 'model=ally\nversion=318\nmin=319\n' >"$T/mcu-old"
printf 'model=ally\nversion=319\nmin=319\n' >"$T/mcu-ok"
printf 'error=no ROG Ally controller MCU found\n' >"$T/mcu-err"
GAMECOVE_TEST_MCU_INFO="$T/mcu-old" expect 3 "mcu on refused with MCU firmware 318" set mcu:on
grep -q "older than 319" "$T/out" || fail "reason names the firmware ($(cat "$T/out"))"
[ "$(r "$A/mcu_powersave/current_value")" = 0 ] || fail "nothing written for old firmware"
GAMECOVE_TEST_MCU_INFO="$T/mcu-err" expect 3 "mcu on refused when the version can't be read" set mcu:on
expect 3 "mcu on refused without any version" set mcu:on
GAMECOVE_TEST_MCU_INFO="$T/mcu-ok" expect 0 "mcu on with MCU firmware 319" set mcu:on
[ "$(r "$A/mcu_powersave/current_value")" = 1 ] || fail "mcu_powersave 1"
GAMECOVE_TEST_MCU_INFO="$T/mcu-old" expect 0 "mcu off always allowed" set mcu:off
expect 0 "restore pstate" set restore
[ "$(r "$C/cpufreq/policy1/boost") $(r "$A/ppt_fppt/current_value") $(r "$A/mcu_powersave/current_value")" = "1 30 1" ] || fail "per-policy boost, FPPT and MCU back"

# Lenovo: firmware attributes under lenovo-wmi-other-0, and only in the custom platform mode
R="$T/lgo"; export GAMECOVE_ROOT="$R"
dmi "$R" "LENOVO" "83E1" "LNVNB161216"
L="$R/sys/class/firmware-attributes/lenovo-wmi-other-0/attributes"
w "$L/ppt_pl1_spl/current_value" 15; w "$L/ppt_pl1_spl/min_value" 5; w "$L/ppt_pl1_spl/max_value" 30
w "$L/ppt_pl2_sppt/current_value" 20; w "$L/ppt_pl2_sppt/min_value" 5; w "$L/ppt_pl2_sppt/max_value" 35
w "$R/sys/firmware/acpi/platform_profile" balanced
w "$R/sys/firmware/acpi/platform_profile_choices" "low-power balanced performance custom"
expect 2 "lenovo sppt over hhd's 32 W for the Legion Go (ppt-limits.txt)" set sppt:33
expect 0 "lenovo sppt" set sppt:25
[ "$(r "$L/ppt_pl2_sppt/current_value") $(r "$R/sys/firmware/acpi/platform_profile")" = "25 custom" ] || fail "lenovo sppt in custom mode"
expect 0 "restore lenovo" set restore
[ "$(r "$L/ppt_pl2_sppt/current_value") $(r "$R/sys/firmware/acpi/platform_profile")" = "20 balanced" ] || fail "lenovo sppt and mode back"
# review L5: Lenovo takes PPT only in custom (hhd): the limit goes back while still custom, the profile last
expect 0 "lenovo sppt for order" set sppt:25
mv "$L/ppt_pl2_sppt/current_value" "$T/cv"; mkdir "$L/ppt_pl2_sppt/current_value"
mv "$R/sys/firmware/acpi/platform_profile" "$T/pp"; mkdir "$R/sys/firmware/acpi/platform_profile"
expect 1 "lenovo restore order probe" set restore
grep -q "could not put back: sppt platform" "$T/out" || fail "lenovo: sppt before platform ($(cat "$T/out"))"
rmdir "$L/ppt_pl2_sppt/current_value" "$R/sys/firmware/acpi/platform_profile"; mv "$T/cv" "$L/ppt_pl2_sppt/current_value"; mv "$T/pp" "$R/sys/firmware/acpi/platform_profile"
expect 0 "lenovo restore after probe" set restore
[ "$(r "$L/ppt_pl2_sppt/current_value") $(r "$R/sys/firmware/acpi/platform_profile")" = "20 balanced" ] || fail "lenovo back after the probe"

# ---- Lenovo Legion Go S: charge_types (Long Life = 80 %), i915-style GPU clocks -------------------------------
R="$T/legion"; export GAMECOVE_ROOT="$R"
dmi "$R" "LENOVO" "83L3" "83L3"
w "$R/sys/class/power_supply/BAT0/type" Battery
w "$R/sys/class/power_supply/BAT0/charge_types" "[Standard] Long_Life"
expect 0 "long life" set battery:long-life
[ "$(r "$R/sys/class/power_supply/BAT0/charge_types")" = Long_Life ] || fail "charge_types Long_Life"
expect 2 "battery other" set battery:fast
expect 0 "restore legion" set restore
[ "$(r "$R/sys/class/power_supply/BAT0/charge_types")" = Standard ] || fail "charge_types back"
# i915 (MSI Claw A1M)
R="$T/a1m"; export GAMECOVE_ROOT="$R"
dmi "$R" "Micro-Star International Co., Ltd." "Claw A1M" "MS-1T41"
I="$R/sys/class/drm/card0"
w "$I/device/uevent" "DRIVER=i915"
w "$I/gt_min_freq_mhz" 300; w "$I/gt_max_freq_mhz" 2250; w "$I/gt_RPn_freq_mhz" 300; w "$I/gt_RP0_freq_mhz" 2250
expect 0 "i915 ceiling" set gpumax:1800
[ "$(r "$I/gt_max_freq_mhz")" = 1800 ] || fail "i915 ceiling"
expect 2 "i915 floor over ceiling" set gpumin:1900
expect 0 "restore i915" set restore
[ "$(r "$I/gt_max_freq_mhz")" = 2250 ] || fail "i915 ceiling back"
echo "power-tune: all passed"
