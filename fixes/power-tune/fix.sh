#!/bin/sh
# GameCove root action: the CPU, GPU and platform power settings a player changes
# often (Power page and quick menu) where no prompt-free service offers them.
# Run by packaging/libexec/gamecove-fix through pkexec; `set` and `status` also
# through gamecove-fix-set, which polkit allows without a password, so EVERY value
# is checked here against what this machine's kernel offers before it is written.
#
# GameCove first uses the services that already exist (steamos-manager on the user
# bus, PowerStation on the system bus: both prompt-free); this is the fallback.
#
#   fix.sh set <key>:<value>
#     boost:on|off            CPU boost (intel_pstate/no_turbo, else cpufreq/boost)
#     smt:on|off              SMT (cpu/smt/control; only where it reads on or off)
#     cores:<n>               logical CPUs online, 2..all (cpu0 always stays on)
#     epp:<word>              energy_performance_preference on every CPU; the word must
#                             be in energy_performance_available_preferences
#     governor:<word>         scaling_governor on every policy; from scaling_available_governors
#     cpumax:<30-100>         CPU frequency ceiling in % (intel_pstate max_perf_pct, else
#                             scaling_max_freq = cpuinfo_max_freq * n / 100, never under cpuinfo_min_freq)
#     gpulevel:auto|low|high|manual    amdgpu power_dpm_force_performance_level
#     gpumin:<MHz> gpumax:<MHz>        GPU clock floor / ceiling: Intel xe (tile0/gt0/freq0),
#                             i915 (gt_*_freq_mhz) or amdgpu (pp_od_clk_voltage, manual level),
#                             always inside the hardware's own range, min <= max kept at every step
#     gpuprofile:<word>       Intel xe power_profile (base | power_saving), as the kernel offers
#     sppt:<W> fppt:<W>       ASUS / Lenovo / MSI firmware attributes ppt_pl2_sppt / ppt_pl3_fppt,
#                             inside the attribute's own min_value..max_value (the maker's limit
#                             for the current power source), never under the sustained limit;
#                             handhelds in ../lib/handhelds.txt only
#     platform:<word>         /sys/firmware/acpi/platform_profile, from platform_profile_choices
#     tau:<us>|tau:restore    RAPL package PL1 time window, 1 s .. the firmware's own value
#     thermald:hold|release   stop / start thermald.service (never disabled): on Intel it puts
#                             the firmware's power limits back every few seconds (ClawDeck,
#                             findings §21). A hold is bounded (review S3-2): a watcher starts
#                             thermald again once no game runs (a game has 60 s to show up,
#                             then two checks 10 s apart without one), so a hold never outlives
#                             the game even when GameCove's own restore doesn't run
#     sleep:s2idle|deep       /sys/power/mem_sleep, from what it offers
#     mcu:on|off              ROG Ally controller MCU power saving in sleep (mcu_powersave); handhelds only;
#                             on only with new enough MCU firmware (../lib/ally-mcu.sh), exit 3 otherwise
#     battery:standard|long-life      charge_types (Lenovo Legion Go: Long Life stops at 80 %);
#                             handhelds only
#     restore                 put back everything this fix changed (GameCove's session runs it
#                             when GameCove exits)
#   fix.sh status            applies=yes, installed=yes|no, one line per value changed, state=on|off
#   fix.sh install           nothing to do (values are recorded at their first change)
#   fix.sh remove            same as `set restore`, then forget
#
# The first change of each value records the value before it in
# /var/lib/gamecove/fixes/power-tune/orig/<key>; restore writes those back.
# GAMECOVE_ROOT is a filesystem prefix for tests (empty on a real system); systemctl
# comes from PATH (tests put a stub first).
# Exit codes: 0 done, 1 the kernel refused or read back something else, 2 bad usage / not here.
set -eu

ROOT="${GAMECOVE_ROOT:-}"
STATE="$ROOT/var/lib/gamecove/fixes/power-tune"
ORIG="$STATE/orig"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fixes/lib/handheld.sh
. "$HERE/../lib/handheld.sh"
# shellcheck source=fixes/lib/ally-mcu.sh
. "$HERE/../lib/ally-mcu.sh"
# every handheld in devices.json, not only the fan / charge-limit ones
# shellcheck disable=SC2034 # read by handheld.sh
HANDHELDS="$HERE/handhelds.txt"
trap fix_unlock EXIT
trap 'exit 1' INT TERM HUP

CPU="$ROOT/sys/devices/system/cpu"

die() { printf 'power-tune: %s\n' "$2" >&2; exit "$1"; }

log_change() {
	mkdir -p "$STATE"
	printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$STATE/changes.log"
}

rd() { [ -f "$1" ] && tr -d '\n' < "$1" 2>/dev/null || true; }

wr() { printf '%s\n' "$2" 2>/dev/null > "$1"; }

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 9 ]; }

# The active word of "[a] b c" (or the only word).
active() {
	v="$(rd "$1")"
	case "$v" in
		*"["*"]"*) v="${v#*[}"; printf '%s\n' "${v%%]*}" ;;
		*) printf '%s\n' "$v" ;;
	esac
}

# offers <file> <word>: the word is one of the file's words (brackets ignored)
offers() {
	for w in $(rd "$1" | tr -d '[]'); do
		[ "$w" = "$2" ] && return 0
	done
	return 1
}

# remember <key> <how to read it back>: the value before our first change
remember() {
	mkdir -p "$ORIG"
	[ -f "$STATE/device" ] || printf '%s\n' "$(this_device)" > "$STATE/device"
	[ -f "$ORIG/$1" ] || printf '%s\n' "$2" > "$ORIG/$1"
}

# One drive can boot several handhelds: recorded values belong to the one they were read on.
this_device() { handheld_id 2>/dev/null || echo generic; }

# put <file> <value> <key>: record, write, read back (exact)
put() {
	remember "$3" "$(rd "$1")"
	wr "$1" "$2" || die 1 "the kernel refused $2 for $3"
	got="$(rd "$1")"
	[ "$got" = "$2" ] || die 1 "$3 reads $got after writing $2"
}

cpus() {
	for d in "$CPU"/cpu[0-9]*; do
		[ -d "$d" ] && printf '%s\n' "${d##*/cpu}"
	done | sort -n
}

policies() {
	found=0
	for d in "$CPU"/cpufreq/policy[0-9]*; do
		[ -d "$d" ] && { printf '%s\n' "$d"; found=1; }
	done
	if [ "$found" = 0 ]; then
		for n in $(cpus); do
			[ -f "$CPU/cpu$n/cpufreq/scaling_governor" ] && printf '%s\n' "$CPU/cpu$n/cpufreq"
		done
	fi
	return 0
}

# ---- CPU ---------------------------------------------------------------------------------------------------------
# AMD amd-pstate has no global cpufreq/boost: boost is per policy (policyN/boost). Order and paths
# from SimpleDeckyTDP (aarron-lee/SimpleDeckyTDP, py_modules/cpu_utils.py set_cpb_boost).
boost_policies() {
	for p in $(policies); do [ -f "$p/boost" ] && printf '%s\n' "$p"; done
	return 0
}

set_boost() {
	case "$1" in on|off) ;; *) die 2 "boost:on or boost:off" ;; esac
	v=0; [ "$1" = on ] && v=1
	if [ -f "$CPU/intel_pstate/no_turbo" ]; then
		put "$CPU/intel_pstate/no_turbo" "$((1 - v))" boost-intel
	elif [ -n "$(boost_policies)" ]; then
		for p in $(boost_policies); do put "$p/boost" "$v" "boost-${p##*/}"; done
	elif [ -f "$CPU/cpufreq/boost" ]; then
		put "$CPU/cpufreq/boost" "$v" boost
	else
		die 2 "this CPU has no boost switch"
	fi
}

set_smt() {
	case "$1" in on|off) ;; *) die 2 "smt:on or smt:off" ;; esac
	f="$CPU/smt/control"
	case "$(rd "$f")" in on|off) ;; *) die 2 "SMT can't be switched here ($(rd "$f"))" ;; esac
	put "$f" "$1" smt
}

set_cores() {
	is_uint "$1" || die 2 "cores needs a number"
	total=0
	for n in $(cpus); do total=$((total + 1)); done
	[ "$total" -ge 2 ] || die 2 "only one CPU here"
	[ "$1" -ge 2 ] && [ "$1" -le "$total" ] || die 2 "cores must be 2..$total"
	if [ ! -f "$ORIG/cores" ]; then
		mkdir -p "$ORIG"
		on=0
		for n in $(cpus); do
			if [ "$n" = 0 ] || [ "$(rd "$CPU/cpu$n/online")" != 0 ]; then on=$((on + 1)); fi
		done
		printf '%s\n' "$on" > "$ORIG/cores"
	fi
	i=0
	for n in $(cpus); do
		i=$((i + 1))
		[ "$n" = 0 ] && continue
		f="$CPU/cpu$n/online"
		[ -f "$f" ] || die 1 "cpu$n can't be switched off"
		want=0; [ "$i" -le "$1" ] && want=1
		[ "$(rd "$f")" = "$want" ] || wr "$f" "$want" || die 1 "cpu$n refused online=$want"
		[ "$(rd "$f")" = "$want" ] || die 1 "cpu$n reads $(rd "$f") after online=$want"
	done
}

set_epp() {
	case "$1" in ''|*[!a-z_]*) die 2 "epp needs a word" ;; esac
	offers "$CPU/cpu0/cpufreq/energy_performance_available_preferences" "$1" || die 2 "this CPU doesn't offer EPP $1"
	n=0
	for c in $(cpus); do
		f="$CPU/cpu$c/cpufreq/energy_performance_preference"
		[ -e "$f" ] || continue
		put "$f" "$1" "epp-$c"
		n=$((n + 1))
	done
	[ "$n" -gt 0 ] || die 2 "no CPU has an energy preference"
}

set_governor() {
	case "$1" in ''|*[!a-z_]*) die 2 "governor needs a word" ;; esac
	n=0
	for p in $(policies); do
		offers "$p/scaling_available_governors" "$1" || die 2 "governor $1 not offered"
		put "$p/scaling_governor" "$1" "gov-${p##*/}"
		n=$((n + 1))
	done
	[ "$n" -gt 0 ] || die 2 "no cpufreq policy here"
}

set_cpumax() {
	is_uint "$1" || die 2 "cpumax needs a percent"
	[ "$1" -ge 30 ] && [ "$1" -le 100 ] || die 2 "cpumax must be 30..100"
	if [ -f "$CPU/intel_pstate/max_perf_pct" ]; then
		lo="$(rd "$CPU/intel_pstate/min_perf_pct")"
		v="$1"
		is_uint "$lo" && [ "$v" -lt "$lo" ] && v="$lo"
		put "$CPU/intel_pstate/max_perf_pct" "$v" cpumax-intel
		return 0
	fi
	n=0
	for p in $(policies); do
		hi="$(rd "$p/cpuinfo_max_freq")"
		lo="$(rd "$p/cpuinfo_min_freq")"
		is_uint "$hi" && is_uint "$lo" || continue
		v=$((hi * $1 / 100))
		[ "$v" -lt "$lo" ] && v="$lo"
		put "$p/scaling_max_freq" "$v" "cpumax-${p##*/}"
		n=$((n + 1))
	done
	[ "$n" -gt 0 ] || die 2 "no CPU frequency limit here"
}

# ---- GPU ---------------------------------------------------------------------------------------------------------
# Prints "<driver> <card dir>" for the first AMD or Intel GPU.
gpu() {
	for c in "$ROOT"/sys/class/drm/card[0-9]*; do
		case "${c##*/}" in *-*) continue ;; esac
		drv="$(sed -n 's/^DRIVER=//p' "$c/device/uevent" 2>/dev/null)"
		case "$drv" in amdgpu|xe|i915) printf '%s %s\n' "$drv" "$c"; return 0 ;; esac
	done
	return 1
}

GPU="$(gpu)" || GPU=""
GDRV="${GPU%% *}"
GDIR="${GPU#* }"

xe_freq() {
	for g in "$GDIR"/device/tile0/gt0/freq0 "$GDIR"/device/tile*/gt*/freq0; do
		[ -f "$g/min_freq" ] && { printf '%s\n' "$g"; return 0; }
	done
	return 1
}

set_gpulevel() {
	case "$1" in auto|low|high|manual) ;; *) die 2 "gpulevel: auto, low, high or manual" ;; esac
	[ "$GDRV" = amdgpu ] || die 2 "GPU performance levels are an AMD setting"
	put "$GDIR/device/power_dpm_force_performance_level" "$1" gpulevel
}

# gpu_clock min|max <MHz>
gpu_clock() {
	is_uint "$2" || die 2 "gpu$1 needs MHz"
	case "$GDRV" in
		xe)
			g="$(xe_freq)" || die 2 "no xe frequency controls"
			lo="$(rd "$g/rpn_freq")"; hi="$(rd "$g/rp0_freq")"
			minf="$g/min_freq"; maxf="$g/max_freq" ;;
		i915)
			lo="$(rd "$GDIR/gt_RPn_freq_mhz")"; hi="$(rd "$GDIR/gt_RP0_freq_mhz")"
			minf="$GDIR/gt_min_freq_mhz"; maxf="$GDIR/gt_max_freq_mhz" ;;
		amdgpu) amd_clock "$1" "$2"; return 0 ;;
		*) die 2 "no GPU clock controls here" ;;
	esac
	is_uint "$lo" && is_uint "$hi" && [ "$hi" -gt 0 ] || die 2 "the GPU doesn't report its clock range"
	[ "$2" -ge "$lo" ] && [ "$2" -le "$hi" ] || die 2 "gpu$1 must be $lo..$hi MHz"
	if [ "$1" = min ]; then
		[ "$2" -le "$(rd "$maxf")" ] || die 2 "the floor can't go over the ceiling ($(rd "$maxf") MHz)"
		put "$minf" "$2" gpumin
	else
		[ "$2" -ge "$(rd "$minf")" ] || die 2 "the ceiling can't go under the floor ($(rd "$minf") MHz)"
		put "$maxf" "$2" gpumax
	fi
}

# amdgpu: OD_SCLK "0: 800Mhz" / "1: 2700Mhz", OD_RANGE "SCLK: 200Mhz 2700Mhz"; needs level manual.
amd_clock() {
	od="$GDIR/device/pp_od_clk_voltage"
	lvl="$GDIR/device/power_dpm_force_performance_level"
	[ -f "$od" ] || die 2 "this GPU has no clock table (pp_od_clk_voltage)"
	range="$(sed -n 's/^SCLK: *\([0-9]*\)[Mm]hz *\([0-9]*\)[Mm]hz.*/\1 \2/p' "$od" | head -n 1)"
	lo="${range% *}"; hi="${range#* }"
	is_uint "$lo" && is_uint "$hi" || die 2 "the GPU doesn't report its clock range"
	[ "$2" -ge "$lo" ] && [ "$2" -le "$hi" ] || die 2 "gpu$1 must be $lo..$hi MHz"
	cur_min="$(sed -n 's/^0: *\([0-9]*\)[Mm]hz.*/\1/p' "$od" | head -n 1)"
	cur_max="$(sed -n 's/^1: *\([0-9]*\)[Mm]hz.*/\1/p' "$od" | head -n 1)"
	if [ "$1" = min ] && is_uint "$cur_max"; then [ "$2" -le "$cur_max" ] || die 2 "the floor can't go over the ceiling"; fi
	if [ "$1" = max ] && is_uint "$cur_min"; then [ "$2" -ge "$cur_min" ] || die 2 "the ceiling can't go under the floor"; fi
	remember "amd-od-$1" "${cur_min:-}${cur_max:+ $cur_max}"
	[ "$(rd "$lvl")" = manual ] || put "$lvl" manual gpulevel
	idx=0; [ "$1" = max ] && idx=1
	wr "$od" "s $idx $2" || die 1 "the GPU refused $2 MHz"
	wr "$od" "c" || die 1 "the GPU refused to commit the clock table"
}

set_gpuprofile() {
	case "$1" in ''|*[!a-z_]*) die 2 "gpuprofile needs a word" ;; esac
	[ "$GDRV" = xe ] || die 2 "GPU power profiles are an Intel xe setting"
	g="$(xe_freq)" || die 2 "no xe frequency controls"
	offers "$g/power_profile" "$1" || die 2 "this GPU doesn't offer $1"
	remember gpuprofile "$(active "$g/power_profile")"
	wr "$g/power_profile" "$1" || die 1 "the GPU refused $1"
	[ "$(active "$g/power_profile")" = "$1" ] || die 1 "power_profile reads $(active "$g/power_profile")"
}

# ---- firmware power limits ---------------------------------------------------------------------------------------
# fw_attr <name>...: the first firmware attribute dir with that name. Lenovo's class device is
# "lenovo-wmi-other-0" (SimpleDeckyTDP py_modules/devices/lenovo.py LENOVO_WMI_PATH); older asus-armoury
# calls FPPT "ppt_fppt" (SimpleDeckyTDP py_modules/devices/rog_ally.py ASUS_ARMORY_FAST_WMI_PATH).
fw_attr() {
	for n in "$@"; do
		for d in "$ROOT"/sys/class/firmware-attributes/asus-armoury* "$ROOT"/sys/class/firmware-attributes/lenovo-wmi-other* \
			"$ROOT"/sys/class/firmware-attributes/msi-wmi-platform*; do
			a="$d/attributes/$n"
			[ -f "$a/current_value" ] && { printf '%s\n' "$a"; return 0; }
		done
	done
	return 1
}

# ppt_cap sppt|fppt: the most watts this handheld's row allows ("" when it has none)
ppt_cap() {
	_pid="$(handheld_id)" || return 0
	while IFS='	' read -r _rid _s _f; do
		[ "$_rid" = "$_pid" ] || continue
		case "$1" in sppt) printf '%s\n' "${_s#sppt=}" ;; *) printf '%s\n' "${_f#fppt=}" ;; esac
		return 0
	done < "$HERE/ppt-limits.txt"
}

# set_ppt sppt|fppt <W>
set_ppt() {
	is_uint "$2" || die 2 "$1 needs watts"
	handheld_ok || die 2 "power limits are only set on the handhelds GameCove knows"
	if [ "$1" = fppt ]; then a="$(fw_attr ppt_pl3_fppt ppt_fppt)" || die 2 "no FPPT firmware attribute here"
	else a="$(fw_attr ppt_pl2_sppt)" || die 2 "no SPPT firmware attribute here"; fi
	name="${a##*/}"
	# Lenovo takes power limits only in its "custom" mode (SimpleDeckyTDP lenovo.py set_tdp; steamos-manager
	# does the same before TdpLimit): switch to it first, recorded so restore puts the old mode back
	case "$a" in
		*/lenovo-wmi-other*)
			pp="$ROOT/sys/firmware/acpi/platform_profile"
			if [ "$(rd "$pp")" != custom ]; then
				offers "$ROOT/sys/firmware/acpi/platform_profile_choices" custom || die 2 "this firmware has no custom mode"
				put "$pp" custom platform
			fi ;;
	esac
	lo="$(rd "$a/min_value")"; hi="$(rd "$a/max_value")"
	is_uint "$lo" && is_uint "$hi" && [ "$hi" -gt 0 ] || die 2 "$name doesn't say its range"
	spl=""; s="$(fw_attr ppt_pl1_spl)" && spl="$(rd "$s/current_value")"
	is_uint "$spl" && [ "$spl" -gt "$lo" ] && lo="$spl"
	if [ "$1" = fppt ] && s="$(fw_attr ppt_pl2_sppt)"; then
		v="$(rd "$s/current_value")"; is_uint "$v" && [ "$v" -gt "$lo" ] && lo="$v"
	fi
	# never past the safe boost limit devices.json documents for this handheld (ppt-limits.txt)
	cap="$(ppt_cap "$1")"
	is_uint "$cap" && [ "$cap" -gt 0 ] && [ "$cap" -lt "$hi" ] && hi="$cap"
	[ "$2" -ge "$lo" ] && [ "$2" -le "$hi" ] || die 2 "$1 must be $lo..$hi W here"
	put "$a/current_value" "$2" "$1"
}

set_platform() {
	case "$1" in ''|*[!a-z-]*) die 2 "platform needs a word" ;; esac
	f="$ROOT/sys/firmware/acpi/platform_profile"
	offers "$ROOT/sys/firmware/acpi/platform_profile_choices" "$1" || die 2 "platform profile $1 not offered"
	put "$f" "$1" platform
}

rapl_window() {
	for d in "$ROOT"/sys/class/powercap/intel-rapl-mmio:[0-9] "$ROOT"/sys/class/powercap/intel-rapl:[0-9]; do
		case "$(rd "$d/name")" in package*) ;; *) continue ;; esac
		for c in "$d"/constraint_[0-9]_name; do
			[ "$(rd "$c")" = long_term ] || continue
			f="${c%_name}_time_window_us"
			[ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
		done
	done
	return 1
}

set_tau() {
	f="$(rapl_window)" || die 2 "no RAPL time window here"
	if [ "$1" = restore ]; then
		[ -f "$ORIG/tau" ] || return 0
		wr "$f" "$(cat "$ORIG/tau")" || die 1 "the firmware refused its own time window"
		rm -f "$ORIG/tau"
		return 0
	fi
	is_uint "$1" || die 2 "tau needs microseconds"
	remember tau "$(rd "$f")"
	fw="$(cat "$ORIG/tau")"
	is_uint "$fw" || die 1 "the firmware's time window is unreadable"
	[ "$1" -ge 1000000 ] && [ "$1" -le "$fw" ] || die 2 "tau must be 1000000..$fw us"
	wr "$f" "$1" || die 1 "the firmware refused $1 us"
	# the firmware rounds to its own steps: within a quarter is taken
	got="$(rd "$f")"
	is_uint "$got" || die 1 "the time window is unreadable after the write"
	d=$((got - $1)); [ "$d" -lt 0 ] && d=$((0 - d))
	[ "$d" -le $(($1 / 4)) ] || die 1 "the time window reads $got us after $1"
}

# A running game of the caller (Steam's reaper, or a GameCove launch's app-steam-app<id> scope).
GAME_PATTERN='SteamLaunch AppId=|app-steam-app[0-9]'
game_running() {
	if [ -n "${1:-}" ]; then
		pgrep -u "$1" -f "$GAME_PATTERN" >/dev/null 2>&1
	else
		pgrep -f "$GAME_PATTERN" >/dev/null 2>&1
	fi
}

# The watcher behind a hold: runs detached as root until thermald is running again.
thermald_watch() {
	uid="${1:-}"
	case "$uid" in *[!0-9]*) uid="" ;; esac
	sleep "${GAMECOVE_THERMALD_GRACE_S:-60}"
	gone=0
	while [ -f "$STATE/thermald-held" ]; do
		if game_running "$uid"; then gone=0; else gone=$((gone + 1)); fi
		[ "$gone" -ge 2 ] && break
		sleep "${GAMECOVE_THERMALD_CHECK_S:-10}"
	done
	if [ -f "$STATE/thermald-held" ]; then
		fix_lock power-tune
		if systemctl start thermald.service; then
			rm -f "$STATE/thermald-held"
			log_change "thermald released: no game running"
		fi
		fix_unlock
	fi
	[ "$(cat "$STATE/thermald-watch" 2>/dev/null)" = "$$" ] && rm -f "$STATE/thermald-watch"
	return 0
}

start_watch() {
	# tests of other parts (a fake root) may switch it off; never on a real system
	[ -n "$ROOT" ] && [ "${GAMECOVE_THERMALD_WATCH:-}" = off ] && return 0
	w="$STATE/thermald-watch"
	# one watcher, for the latest hold (and its caller)
	if [ -f "$w" ]; then
		old="$(cat "$w" 2>/dev/null)"
		case "$old" in "" | *[!0-9]*) ;; *) kill "$old" 2>/dev/null || true ;; esac
	fi
	if command -v setsid >/dev/null 2>&1; then
		setsid sh "$HERE/fix.sh" thermald-watch "${PKEXEC_UID:-}" </dev/null >/dev/null 2>&1 &
	else
		nohup sh "$HERE/fix.sh" thermald-watch "${PKEXEC_UID:-}" </dev/null >/dev/null 2>&1 &
	fi
	echo "$!" >"$w"
}

set_thermald() {
	case "$1" in
		hold)
			[ "$(systemctl is-active thermald.service 2>/dev/null || true)" = active ] || return 0
			systemctl stop thermald.service || die 1 "could not stop thermald"
			mkdir -p "$STATE"; : > "$STATE/thermald-held"
			start_watch
			;;
		release)
			[ -f "$STATE/thermald-held" ] || return 0
			systemctl start thermald.service || die 1 "could not start thermald"
			rm -f "$STATE/thermald-held"
			;;
		*) die 2 "thermald:hold or thermald:release" ;;
	esac
}

set_sleep() {
	case "$1" in s2idle|deep) ;; *) die 2 "sleep:s2idle or sleep:deep" ;; esac
	f="$ROOT/sys/power/mem_sleep"
	offers "$f" "$1" || die 2 "this machine doesn't offer $1"
	remember sleep "$(active "$f")"
	wr "$f" "$1" || die 1 "the kernel refused $1"
	[ "$(active "$f")" = "$1" ] || die 1 "mem_sleep reads $(active "$f")"
}

# ROG Ally controller MCU power saving while asleep (less battery drain in sleep; some firmware
# then misses the wake-up press). asus-armoury attribute, else the older asus-nb-wmi file
# (SimpleDeckyTDP py_modules/devices/rog_ally.py set_mcu_powersave).
mcu_file() {
	a="$(fw_attr mcu_powersave)" && { printf '%s\n' "$a/current_value"; return 0; }
	f="$ROOT/sys/devices/platform/asus-nb-wmi/mcu_powersave"
	[ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
	return 1
}

set_mcu() {
	case "$1" in on) v=1 ;; off) v=0 ;; *) die 2 "mcu:on or mcu:off" ;; esac
	handheld_ok || die 2 "MCU power saving is only set on the handhelds GameCove knows"
	f="$(mcu_file)" || die 2 "no MCU power saving switch here"
	if [ "$v" = 1 ]; then
		# only with new enough MCU firmware (review S1-3); off is always allowed
		why="$(ally_mcu_blocked strict)" && die 3 "$why"
	fi
	put "$f" "$v" mcu
}

battery_types() {
	for d in "$ROOT"/sys/class/power_supply/*; do
		[ "$(rd "$d/type")" = Battery ] && [ -f "$d/charge_types" ] && { printf '%s\n' "$d/charge_types"; return 0; }
	done
	return 1
}

set_battery() {
	case "$1" in standard) w=Standard ;; long-life) w=Long_Life ;; *) die 2 "battery:standard or battery:long-life" ;; esac
	handheld_ok || die 2 "battery modes are only set on the handhelds GameCove knows"
	f="$(battery_types)" || die 2 "this battery has no charge modes"
	offers "$f" "$w" || die 2 "this battery doesn't offer $w"
	remember battery "$(active "$f")"
	wr "$f" "$w" || die 1 "the battery refused $w"
	[ "$(active "$f")" = "$w" ] || die 1 "charge_types reads $(active "$f")"
}

# ---- restore -----------------------------------------------------------------------------------------------------
# Writes back one recorded value (key = file in $ORIG). Unknown keys are left in place.
restore_key() {
	k="$1"; v="$(cat "$ORIG/$k")"
	case "$k" in
		boost-intel) wr "$CPU/intel_pstate/no_turbo" "$v" ;;
		boost) wr "$CPU/cpufreq/boost" "$v" ;;
		smt) wr "$CPU/smt/control" "$v" ;;
		cores) set_cores "$v" ;;
		epp-*) wr "$CPU/cpu${k#epp-}/cpufreq/energy_performance_preference" "$v" ;;
		gov-*) for p in $(policies); do if [ "gov-${p##*/}" = "$k" ]; then wr "$p/scaling_governor" "$v" || return 1; fi; done ;;
		cpumax-intel) wr "$CPU/intel_pstate/max_perf_pct" "$v" ;;
		cpumax-*) for p in $(policies); do if [ "cpumax-${p##*/}" = "$k" ]; then wr "$p/scaling_max_freq" "$v" || return 1; fi; done ;;
		gpulevel) wr "$GDIR/device/power_dpm_force_performance_level" "$v" ;;
		gpumin|gpumax)
			if [ "$GDRV" = xe ]; then g="$(xe_freq)" && wr "$g/${k#gpu}_freq" "$v"
			else wr "$GDIR/gt_${k#gpu}_freq_mhz" "$v"; fi ;;
		amd-od-min|amd-od-max) [ -f "$GDIR/device/pp_od_clk_voltage" ] && wr "$GDIR/device/pp_od_clk_voltage" r && wr "$GDIR/device/pp_od_clk_voltage" c ;;
		gpuprofile) g="$(xe_freq)" && wr "$g/power_profile" "$v" ;;
		sppt) a="$(fw_attr ppt_pl2_sppt)" && wr "$a/current_value" "$v" ;;
		fppt) a="$(fw_attr ppt_pl3_fppt ppt_fppt)" && wr "$a/current_value" "$v" ;;
		boost-policy*) wr "$CPU/cpufreq/${k#boost-}/boost" "$v" ;;
		mcu) f="$(mcu_file)" && wr "$f" "$v" ;;
		platform) wr "$ROOT/sys/firmware/acpi/platform_profile" "$v" ;;
		tau) f="$(rapl_window)" && wr "$f" "$v" ;;
		sleep) wr "$ROOT/sys/power/mem_sleep" "$v" ;;
		battery) f="$(battery_types)" && wr "$f" "$v" ;;
		*) return 0 ;;
	esac
}

do_restore() {
	left=0
	if [ -f "$STATE/device" ] && [ "$(cat "$STATE/device")" != "$(this_device)" ]; then
		# read on another handheld (same drive): never written here
		rm -rf "$ORIG"
		log_change "dropped values recorded on $(cat "$STATE/device")"
	fi
	rm -f "$STATE/device"
	if [ -d "$ORIG" ]; then
		# floors before ceilings come back in the order that keeps min <= max: ceilings first
		for f in "$ORIG/gpumax" "$ORIG/gpumin" "$ORIG"/*; do
			[ -f "$f" ] || continue
			k="${f##*/}"
			if restore_key "$k"; then rm -f "$ORIG/$k"; else left=1; printf 'power-tune: could not put back %s\n' "$k" >&2; fi
			[ "$left" = 0 ] || [ -f "$STATE/device" ] || printf '%s\n' "$(this_device)" > "$STATE/device"
		done
		rmdir "$ORIG" 2>/dev/null || true
	fi
	set_thermald release || left=1
	log_change "restore (left=$left)"
	[ "$left" = 0 ] || die 1 "some values could not be put back; run restore again"
}

do_set() {
	arg="${1:-}"
	[ -n "$arg" ] || die 2 "set needs <key>:<value> or restore"
	fix_lock power-tune
	if [ "$arg" = restore ]; then do_restore; printf 'restored\n'; return 0; fi
	key="${arg%%:*}"; val="${arg#*:}"
	[ "$key" != "$arg" ] || die 2 "set needs <key>:<value>"
	case "$key" in
		boost) set_boost "$val" ;;
		smt) set_smt "$val" ;;
		cores) set_cores "$val" ;;
		epp) set_epp "$val" ;;
		governor) set_governor "$val" ;;
		cpumax) set_cpumax "$val" ;;
		gpulevel) set_gpulevel "$val" ;;
		gpumin) gpu_clock min "$val" ;;
		gpumax) gpu_clock max "$val" ;;
		gpuprofile) set_gpuprofile "$val" ;;
		sppt|fppt) set_ppt "$key" "$val" ;;
		platform) set_platform "$val" ;;
		tau) set_tau "$val" ;;
		thermald) set_thermald "$val" ;;
		sleep) set_sleep "$val" ;;
		battery) set_battery "$val" ;;
		mcu) set_mcu "$val" ;;
		*) die 2 "unknown setting $key" ;;
	esac
	log_change "set $key=$val"
	printf '%s=%s\n' "$key" "$val"
}

do_status() {
	printf 'applies=yes\n'
	if [ -d "$ORIG" ] || [ -f "$STATE/thermald-held" ]; then
		printf 'installed=yes\n'
		if [ -d "$ORIG" ]; then
			for f in "$ORIG"/*; do [ -f "$f" ] && printf 'orig_%s=%s\n' "${f##*/}" "$(cat "$f")"; done
		fi
		[ -f "$STATE/thermald-held" ] && printf 'thermald=held\n'
		printf 'state=on\n'
	else
		printf 'installed=no\nstate=off\n'
	fi
}

case "${1:-}" in
	install) printf 'installed=yes\n' ;;
	set) do_set "${2:-}" ;;
	status) do_status ;;
	remove) fix_lock power-tune; do_restore; rm -rf "$ORIG"; printf 'restored\n' ;;
	# internal: the hold's watcher (start_watch); gamecove-fix never passes this action
	thermald-watch) trap - EXIT; thermald_watch "${2:-}" ;;
	*) die 2 "usage: fix.sh install|remove|status|set <key>:<value>|set restore" ;;
esac
