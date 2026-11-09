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
case "$1" in
is-active) cat "$f" 2>/dev/null || echo inactive ;;
stop) echo inactive > "$f"; echo "stop" >> "$GAMECOVE_ROOT/systemctl.log" ;;
start) echo active > "$f"; echo "start" >> "$GAMECOVE_ROOT/systemctl.log" ;;
esac
EOF
chmod +x "$T/bin/systemctl"
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
# thermald already stopped by someone else: hold changes nothing, release doesn't start it
echo inactive > "$R/thermald.state"; : > "$R/systemctl.log"
expect 0 "hold when inactive" set thermald:hold
expect 0 "release without hold" set thermald:release
[ ! -s "$R/systemctl.log" ] || fail "thermald left alone when GameCove didn't stop it"
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
expect 0 "cpumax amd" set cpumax:50
[ "$(r "$C/cpufreq/policy1/scaling_max_freq")" = 2550000 ] || fail "scaling_max_freq 50 %"
expect 0 "gpu level high" set gpulevel:high
expect 2 "gpu level other" set gpulevel:turbo
expect 0 "amd gpu floor" set gpumin:1200
[ "$(r "$D/power_dpm_force_performance_level")" = manual ] || fail "amd clocks need the manual level"
expect 2 "amd gpu over range" set gpumax:3000
expect 0 "sppt" set sppt:28
[ "$(r "$A/ppt_pl2_sppt/current_value")" = 28 ] || fail "sppt written"
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
# the same attributes on a laptop are never written
dmi "$R" "ASUSTeK COMPUTER INC." "ROG Zephyrus G14" "GA403UV"
expect 2 "laptop sppt refused" set sppt:25
[ "$(r "$A/ppt_pl2_sppt/current_value")" = 20 ] || fail "laptop untouched"

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
