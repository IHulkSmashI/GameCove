extends RefCounted
## Every power lever below the TDP, with the backends that exist for it, tried in
## this order (prompt-free services first; the root helper only where none offers it):
##
##   steamos-manager (user bus, com.steampowered.SteamOSManager1, MIT):
##       CpuBoost1.CpuBoostState u, CpuScaling1.CpuScalingGovernor s,
##       GpuPerformanceLevel1.GpuPerformanceLevel s / ManualGpuClock u,
##       GpuPowerProfile1.GpuPowerProfile s, PerformanceProfile1.PerformanceProfile s
##       (data/interfaces/com.steampowered.SteamOSManager1.xml)
##   PowerStation (system bus, org.shadowblip.PowerStation, GPL-3.0; anyone may call it):
##       /org/shadowblip/Performance/CPU  org.shadowblip.CPU  BoostEnabled b (AMD "cpb" only),
##       SmtEnabled b ("ht" only), CoresEnabled u, CoresCount u   (src/performance/cpu/cpu_features.rs)
##       .../GPU/cardN  org.shadowblip.GPU.Card  ClockLimitMhzMin/Max d, ClockValueMhzMin/Max d,
##       ManualClock b (AMD: pp_od_clk_voltage + power_dpm_force_performance_level; Intel i915:
##       gt_*_freq_mhz, which xe doesn't have)       (src/performance/gpu/{amd/amdgpu,intel/intelgpu}.rs)
##       .../GPU/cardN  org.shadowblip.GPU.Card.TDP  Boost d, MaxBoost d (watts above TDP: PL2 - PL1 on
##       Intel RAPL, SPPT/FPPT on ASUS / ryzenadj), ThermalThrottleLimitC d (ryzenadj only)
##   power-profiles-daemon / tuned-ppd (system bus, org.freedesktop.UPower.PowerProfiles,
##       ActiveProfile s; polkit lets the active session switch it)
##   gamecove-fix-set power-tune set <key>:<value>  (fixes/power-tune/fix.sh, polkit "yes"): the
##       sysfs files above when no service offers them, firmware-attribute SPPT / FPPT
##       (asus-armoury, lenovo-wmi-other, msi-wmi-platform), xe GPU clocks and power_profile,
##       RAPL PL1 window, thermald, mem_sleep, charge_types.
##
## Every read is a sysfs file under `root` or one busctl call through `runner`, so tests
## swap both. Every write is read back; a lever is "set" only when the read-back agrees.
## Runs on a worker thread (Controls' or Power's): no scene tree here.

const Busctl := preload("res://scripts/device/busctl.gd")

const SM := "com.steampowered.SteamOSManager1"
const SM_PATH := "/com/steampowered/SteamOSManager1"
const SM_IF := "com.steampowered.SteamOSManager1."
const PS := "org.shadowblip.PowerStation"
const PS_CPU := "/org/shadowblip/Performance/CPU"
const PS_CPU_IF := "org.shadowblip.CPU"
const PS_GPU := "/org/shadowblip/Performance/GPU"
const PS_CARD_IF := "org.shadowblip.GPU.Card"
const PS_TDP_IF := "org.shadowblip.GPU.Card.TDP"
const PPD := "org.freedesktop.UPower.PowerProfiles"
const PPD_PATH := "/org/freedesktop/UPower/PowerProfiles"
const FIX_SET := "/usr/libexec/gamecove/gamecove-fix-set"
const FIX_ADMIN := "/usr/libexec/gamecove/gamecove-fix"
const FIX_NAME := "power-tune"
## power-tune keys that need the administrator password (review S3-2: not needed day to day, and
## risky enough that the prompt-free entry point doesn't take them): through gamecove-fix, which
## asks in Desktop Mode; Gaming Mode has no polkit agent, so there the controls say so.
const ADMIN_KEYS := ["smt", "cores", "sleep", "mcu"]
const FW_ATTR_DRIVERS := ["asus-armoury", "lenovo-wmi-other", "msi-wmi-platform"]
const EPP_ORDER := ["performance", "balance_performance", "default", "balance_power", "power"]

var root := ""
var runner: RefCounted
var system_bus: RefCounted
var user_bus: RefCounted
var fix_set := FIX_SET
## Commands run, newest last (tests read it; capped).
var _cache := {}


func _init(sys_root := "", command_runner: RefCounted = null) -> void:
	root = sys_root
	runner = command_runner
	system_bus = Busctl.new(runner, "--system")
	user_bus = Busctl.new(runner, "--user")


## Forget cached discovery (a new detect pass).
func reset() -> void:
	_cache.clear()


# ---- files ---------------------------------------------------------------------------------------

func path(rel: String) -> String:
	return root + rel


## Line by line: sysfs files report a size (4096) that isn't their length, which get_as_text()
## logs as an engine error.
static func read(p: String) -> String:
	if p == "" or not FileAccess.file_exists(p):
		return ""
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return ""
	var lines := PackedStringArray()
	while not f.eof_reached() and lines.size() < 64:
		lines.append(f.get_line())
	return "\n".join(lines).strip_edges()


static func read_int(p: String) -> int:
	var t := read(p)
	return t.to_int() if t.is_valid_int() else -1


## "[a] b c" -> "a"; "a" -> "a".
static func active_word(text: String) -> String:
	var i := text.find("[")
	var j := text.find("]")
	if i >= 0 and j > i:
		return text.substr(i + 1, j - i - 1)
	return text.strip_edges()


## "[a] b c" -> ["a", "b", "c"].
static func words(text: String) -> Array:
	var out := []
	for w in text.replace("[", "").replace("]", "").split(" ", false):
		out.append(w)
	return out


func dirs(rel: String) -> Array:
	var d := DirAccess.open(root + rel)
	if d == null:
		return []
	var names := Array(d.get_directories()) + Array(d.get_files())
	names.sort()
	return names


# ---- root helper ---------------------------------------------------------------------------------

func helper_present() -> bool:
	return FileAccess.file_exists(root + fix_set)


## pkexec gamecove-fix-set power-tune set <key>:<value> (ADMIN_KEYS: gamecove-fix, which asks for
## the administrator password); true on exit 0.
func root_set(key: String, value: String) -> bool:
	if not helper_present():
		return false
	var arg := key + ":" + value if key != "" else value
	var helper := fix_set.get_base_dir().path_join("gamecove-fix") if key in ADMIN_KEYS else fix_set
	var r: Dictionary = runner.run("pkexec", PackedStringArray([helper, FIX_NAME, "set", arg]))
	return int(r.get("code", -1)) == 0


## True in GameCove's gamescope session (no polkit agent: a password can't be asked for).
static func no_password_prompt() -> bool:
	return OS.get_environment("GAMESCOPE_WAYLAND_DISPLAY") != "" or OS.get_environment("XDG_CURRENT_DESKTOP").to_lower() == "gamescope"


# ---- services ------------------------------------------------------------------------------------

func sm_get(iface: String, prop: String) -> Variant:
	return user_bus.get_prop(SM, SM_PATH, SM_IF + iface, prop)


## steamos-manager answers on the user bus (any of its everyday properties).
func sm_present() -> bool:
	for ip in [["GpuPerformanceLevel1", "GpuPerformanceLevel"], ["PerformanceProfile1", "PerformanceProfile"],
			["TdpLimit1", "TdpLimit"], ["CpuScaling1", "CpuScalingGovernor"]]:
		if sm_get(ip[0], ip[1]) != null:
			return true
	return false


func sm_set(iface: String, prop: String, sig: String, value: String) -> bool:
	return user_bus.set_prop(SM, SM_PATH, SM_IF + iface, prop, sig, value)


func ps_get(obj: String, iface: String, prop: String) -> Variant:
	return system_bus.get_prop(PS, obj, iface, prop)


func ps_set(obj: String, iface: String, prop: String, sig: String, value: String) -> bool:
	return system_bus.set_prop(PS, obj, iface, prop, sig, value)


## PowerStation's GPU cards, cached per detect pass.
func ps_cards() -> Array:
	if _cache.has("ps_cards"):
		return _cache["ps_cards"]
	var out := []
	var r: Variant = system_bus.call_method(PS, PS_GPU, "org.shadowblip.GPU", "EnumerateCards")
	if r != null and not r.is_empty() and typeof(r[0]) == TYPE_ARRAY:
		for p in r[0]:
			out.append(str(p))
	_cache["ps_cards"] = out
	return out


## The PowerStation card whose clock range it can read (Intel xe: none), or "".
func ps_clock_card() -> String:
	if _cache.has("ps_clock_card"):
		return _cache["ps_clock_card"]
	var found := ""
	for c in ps_cards():
		var hi: Variant = ps_get(c, PS_CARD_IF, "ClockLimitMhzMax")
		if hi != null and float(hi) > 0.0:
			found = c
			break
	_cache["ps_clock_card"] = found
	return found


## The PowerStation card with a TDP interface, or "".
func ps_tdp_card() -> String:
	if _cache.has("ps_tdp_card"):
		return _cache["ps_tdp_card"]
	var found := ""
	for c in ps_cards():
		if ps_get(c, PS_TDP_IF, "TDP") != null:
			found = c
			break
	_cache["ps_tdp_card"] = found
	return found


# ---- CPU -----------------------------------------------------------------------------------------

const CPU := "/sys/devices/system/cpu"


func cpu_numbers() -> Array:
	var out := []
	for n in dirs(CPU):
		if n.begins_with("cpu") and n.substr(3).is_valid_int():
			out.append(n.substr(3).to_int())
	out.sort()
	return out


## {"via": "intel"|"policy"|"cpufreq", "path"}: the sysfs boost switch. amd-pstate has no global
## cpufreq/boost, only policyN/boost (SimpleDeckyTDP, aarron-lee/SimpleDeckyTDP
## py_modules/cpu_utils.py get_cpb_boost_paths); policy0's stands for all.
func boost_file() -> Dictionary:
	if FileAccess.file_exists(path(CPU + "/intel_pstate/no_turbo")):
		return {"via": "intel", "path": path(CPU + "/intel_pstate/no_turbo")}
	if FileAccess.file_exists(path(CPU + "/cpufreq/policy0/boost")):
		return {"via": "policy", "path": path(CPU + "/cpufreq/policy0/boost")}
	if FileAccess.file_exists(path(CPU + "/cpufreq/boost")):
		return {"via": "cpufreq", "path": path(CPU + "/cpufreq/boost")}
	return {}


## true/false from the file, null when absent.
func boost_sysfs() -> Variant:
	var b := boost_file()
	if b.is_empty():
		return null
	var v := read(b["path"])
	if not v.is_valid_int():
		return null
	return v == "0" if b["via"] == "intel" else v == "1"


func smt_control() -> String:
	return read(path(CPU + "/smt/control"))


func online_count() -> int:
	var n := 0
	for c in cpu_numbers():
		if c == 0 or read(path(CPU + "/cpu%d/online" % c)) != "0":
			n += 1
	return n


func can_offline() -> bool:
	var nums := cpu_numbers()
	return nums.size() >= 2 and FileAccess.file_exists(path(CPU + "/cpu%d/online" % nums[-1]))


func epp_files() -> Array:
	var out := []
	for c in cpu_numbers():
		var p := path(CPU + "/cpu%d/cpufreq/energy_performance_preference" % c)
		if FileAccess.file_exists(p):
			out.append(p)
	return out


## EPP words this CPU takes, in power order (performance first); "default" left out.
func epp_choices() -> Array:
	var avail := words(read(path(CPU + "/cpu0/cpufreq/energy_performance_available_preferences")))
	var out := []
	for w in EPP_ORDER:
		if w in avail and w != "default":
			out.append(w)
	return out


func epp_now() -> String:
	var f := epp_files()
	return read(f[0]) if not f.is_empty() else ""


func governor_dir() -> String:
	for p in [CPU + "/cpufreq/policy0", CPU + "/cpu0/cpufreq"]:
		if FileAccess.file_exists(path(p + "/scaling_governor")):
			return path(p)
	return ""


func governor_choices() -> Array:
	var d := governor_dir()
	return words(read(d + "/scaling_available_governors")) if d != "" else []


## {"via": "intel"|"cpufreq", "pct"}: the CPU frequency ceiling now, {} when none.
func cpu_max() -> Dictionary:
	var ip := path(CPU + "/intel_pstate/max_perf_pct")
	if FileAccess.file_exists(ip):
		return {"via": "intel", "pct": read_int(ip), "min": maxi(30, read_int(path(CPU + "/intel_pstate/min_perf_pct")))}
	for p in [CPU + "/cpufreq/policy0", CPU + "/cpu0/cpufreq"]:
		var hi := read_int(path(p + "/cpuinfo_max_freq"))
		var cur := read_int(path(p + "/scaling_max_freq"))
		var lo := read_int(path(p + "/cpuinfo_min_freq"))
		if hi > 0 and cur > 0:
			return {"via": "cpufreq", "pct": int(roundf(cur * 100.0 / hi)), "min": maxi(30, int(ceilf(lo * 100.0 / hi)))}
	return {}


# ---- GPU -----------------------------------------------------------------------------------------

## {"driver": "amdgpu"|"xe"|"i915", "card": "/sys/class/drm/cardN" with root}, {} when none.
func gpu() -> Dictionary:
	if _cache.has("gpu"):
		return _cache["gpu"]
	var out := {}
	for n in dirs("/sys/class/drm"):
		if not (n.begins_with("card") and n.substr(4).is_valid_int()):
			continue
		var drv := ""
		for line in read(path("/sys/class/drm/%s/device/uevent" % n)).split("\n"):
			if line.begins_with("DRIVER="):
				drv = line.substr(7)
		if drv in ["amdgpu", "xe", "i915"]:
			out = {"driver": drv, "card": path("/sys/class/drm/" + n)}
			break
	_cache["gpu"] = out
	return out


## Intel xe frequency folder (graphics GT, never the media GT), "" when none.
func xe_freq() -> String:
	var g := gpu()
	if g.get("driver", "") != "xe":
		return ""
	var dev: String = g["card"] + "/device"
	if FileAccess.file_exists(dev + "/tile0/gt0/freq0/min_freq"):
		return dev + "/tile0/gt0/freq0"
	return ""


## GPU clock range and window now: {"via": "powerstation"|"xe"|"i915"|"amdgpu", "lo", "hi",
## "min", "max", "card"?}; {} when nothing can set it.
func gpu_clocks() -> Dictionary:
	var g := gpu()
	var drv: String = g.get("driver", "")
	var ps := ps_clock_card()
	if ps != "":
		var lo: Variant = ps_get(ps, PS_CARD_IF, "ClockLimitMhzMin")
		var hi: Variant = ps_get(ps, PS_CARD_IF, "ClockLimitMhzMax")
		var mn: Variant = ps_get(ps, PS_CARD_IF, "ClockValueMhzMin")
		var mx: Variant = ps_get(ps, PS_CARD_IF, "ClockValueMhzMax")
		if lo != null and hi != null and mn != null and mx != null and float(hi) > float(lo):
			return {"via": "powerstation", "card": ps, "lo": int(lo), "hi": int(hi), "min": int(mn), "max": int(mx)}
	if not helper_present():
		return {}
	match drv:
		"xe":
			var f := xe_freq()
			if f != "" and read_int(f + "/rp0_freq") > 0:
				return {"via": "xe", "lo": read_int(f + "/rpn_freq"), "hi": read_int(f + "/rp0_freq"),
					"min": read_int(f + "/min_freq"), "max": read_int(f + "/max_freq"), "rpe": read_int(f + "/rpe_freq")}
		"i915":
			var c: String = g["card"]
			if read_int(c + "/gt_RP0_freq_mhz") > 0:
				return {"via": "i915", "lo": read_int(c + "/gt_RPn_freq_mhz"), "hi": read_int(c + "/gt_RP0_freq_mhz"),
					"min": read_int(c + "/gt_min_freq_mhz"), "max": read_int(c + "/gt_max_freq_mhz"), "rpe": read_int(c + "/gt_RPe_freq_mhz")}
		"amdgpu":
			var od := parse_od(read(g["card"] + "/device/pp_od_clk_voltage"))
			if not od.is_empty():
				od["via"] = "amdgpu"
				return od
	return {}


## amdgpu pp_od_clk_voltage -> {"lo", "hi", "min", "max"} or {}.
static func parse_od(text: String) -> Dictionary:
	var out := {}
	for line in text.split("\n"):
		var parts := line.strip_edges().replace("Mhz", "").replace("MHz", "").split(" ", false)
		if parts.size() >= 3 and parts[0] == "SCLK:":
			out["lo"] = parts[1].to_int()
			out["hi"] = parts[2].to_int()
		elif parts.size() >= 2 and parts[0] == "0:":
			out["min"] = parts[1].to_int()
		elif parts.size() >= 2 and parts[0] == "1:":
			out["max"] = parts[1].to_int()
	if not (out.has("lo") and out.has("hi")):
		return {}
	out["min"] = out.get("min", out["lo"])
	out["max"] = out.get("max", out["hi"])
	return out


## Set the GPU floor and/or ceiling (MHz; -1 = leave). Order keeps min <= max at every step.
## True when the read-back matches.
func set_gpu_clocks(min_mhz: int, max_mhz: int) -> bool:
	var c := gpu_clocks()
	if c.is_empty():
		return false
	var lo: int = c["lo"]
	var hi: int = c["hi"]
	var nmin: int = clampi(min_mhz, lo, hi) if min_mhz >= 0 else int(c["min"])
	var nmax: int = clampi(max_mhz, lo, hi) if max_mhz >= 0 else int(c["max"])
	if nmin > nmax:
		nmin = nmax  # the floor follows the ceiling down (ClawDeck power.py set_gpu_window)
	var steps := []
	if nmax >= int(c["max"]):
		steps = [["max", nmax], ["min", nmin]]
	else:
		steps = [["min", nmin], ["max", nmax]]
	var ok := true
	if c["via"] == "powerstation":
		if not bool(ps_get(c["card"], PS_CARD_IF, "ManualClock")):
			ps_set(c["card"], PS_CARD_IF, "ManualClock", "b", "true")
		for s in steps:
			var prop := "ClockValueMhzMin" if s[0] == "min" else "ClockValueMhzMax"
			if int(c[s[0]]) != s[1]:
				ok = ps_set(c["card"], PS_CARD_IF, prop, "d", str(s[1])) and ok
	else:
		for s in steps:
			if int(c[s[0]]) != s[1]:
				ok = root_set("gpu" + s[0], str(s[1])) and ok
	if not ok:
		return false
	if c["via"] == "amdgpu":
		return true  # the clock table can't be read back as written; the helper checked the range
	var after := gpu_clocks()
	return not after.is_empty() and int(after["min"]) == nmin and int(after["max"]) == nmax


## Hand the GPU clocks back to the driver (PowerStation: ManualClock off; else the helper's
## recorded values).
func reset_gpu_clocks() -> bool:
	var c := gpu_clocks()
	if c.is_empty():
		return false
	if c["via"] == "powerstation":
		ps_set(c["card"], PS_CARD_IF, "ClockValueMhzMin", "d", str(c["lo"]))
		ps_set(c["card"], PS_CARD_IF, "ClockValueMhzMax", "d", str(c["hi"]))
		return ps_set(c["card"], PS_CARD_IF, "ManualClock", "b", "false")
	return set_gpu_clocks(int(c["lo"]), int(c["hi"]))


## xe power_profile: {"active", "offered": [...]} or {}.
func xe_profile() -> Dictionary:
	var f := xe_freq()
	if f == "" or not FileAccess.file_exists(f + "/power_profile"):
		return {}
	var t := read(f + "/power_profile")
	return {"active": active_word(t), "offered": words(t)}


func amd_level_file() -> String:
	var g := gpu()
	if g.get("driver", "") != "amdgpu":
		return ""
	var p: String = g["card"] + "/device/power_dpm_force_performance_level"
	return p if FileAccess.file_exists(p) else ""


# ---- platform ------------------------------------------------------------------------------------

func platform_profile() -> Dictionary:
	var p := path("/sys/firmware/acpi/platform_profile")
	if not FileAccess.file_exists(p):
		return {}
	return {"active": read(p), "offered": words(read(path("/sys/firmware/acpi/platform_profile_choices")))}


## {"path": attribute dir, "driver", "value", "min", "max"} for the first of `names` (ppt_pl2_sppt...),
## {} when none. Class folders may carry an instance suffix: Lenovo's is "lenovo-wmi-other-0"
## (SimpleDeckyTDP py_modules/devices/lenovo.py); older asus-armoury names FPPT "ppt_fppt"
## (SimpleDeckyTDP py_modules/devices/rog_ally.py).
func fw_attr(names: Variant) -> Dictionary:
	var list: Array = names if names is Array else [names]
	var classes := dirs("/sys/class/firmware-attributes")
	for name in list:
		for drv in FW_ATTR_DRIVERS:
			for c in classes:
				if not str(c).begins_with(drv):
					continue
				var a: String = path("/sys/class/firmware-attributes/%s/attributes/%s" % [c, name])
				if FileAccess.file_exists(a + "/current_value"):
					return {"path": a, "driver": drv, "value": read_int(a + "/current_value"),
						"min": read_int(a + "/min_value"), "max": read_int(a + "/max_value")}
	return {}


## ROG Ally MCU power saving in sleep: the file, "" when none (asus-armoury, else asus-nb-wmi).
func mcu_file() -> String:
	var a := fw_attr("mcu_powersave")
	if not a.is_empty():
		return a["path"] + "/current_value"
	var legacy := path("/sys/devices/platform/asus-nb-wmi/mcu_powersave")
	return legacy if FileAccess.file_exists(legacy) else ""


## Why MCU power saving can't be turned on here ("" = it may): the controller MCU firmware version
## the root helper read and cached (fixes/lib/ally-mcu.sh) is older than the kernel's minimum, or
## couldn't be read. Not cached yet: "" (turning it on checks first and refuses old firmware).
func mcu_blocked() -> String:
	var t := FileAccess.get_file_as_string(path("/var/lib/gamecove/ally-mcu-version"))
	if t == "":
		return ""
	var kv := {}
	for line in t.split("\n", false):
		var i := line.find("=")
		if i > 0:
			kv[line.substr(0, i)] = line.substr(i + 1).strip_edges()
	var v := str(kv.get("version", ""))
	var lo := str(kv.get("min", ""))
	if not v.is_valid_int() or not lo.is_valid_int():
		return "Not available: the controller firmware version couldn't be read. Update it in Armoury Crate (Windows) first."
	if v.to_int() < lo.to_int():
		return "Not available: controller firmware %s is older than %s and may not wake after sleep. Update it in Armoury Crate (Windows) first." % [v, lo]
	return ""


## RAPL package PL1 time window file (MMIO first, as PowerStation and thermald do), "" when none.
func rapl_window() -> String:
	for prefix in ["intel-rapl-mmio:", "intel-rapl:"]:
		for n in dirs("/sys/class/powercap"):
			if not n.begins_with(prefix) or n.count(":") != 1:
				continue
			var d := path("/sys/class/powercap/" + n)
			if not read(d + "/name").begins_with("package"):
				continue
			for i in range(4):
				if read(d + "/constraint_%d_name" % i) == "long_term" and FileAccess.file_exists(d + "/constraint_%d_time_window_us" % i):
					return d + "/constraint_%d_time_window_us" % i
	return ""


func mem_sleep() -> Dictionary:
	var p := path("/sys/power/mem_sleep")
	if not FileAccess.file_exists(p):
		return {}
	var t := read(p)
	return {"active": active_word(t), "offered": words(t)}


## Battery charge_types (Lenovo: Standard / Long_Life): {"path", "active", "offered"} or {}.
func charge_types() -> Dictionary:
	for n in dirs("/sys/class/power_supply"):
		var d := path("/sys/class/power_supply/" + n)
		if read(d + "/type") == "Battery" and FileAccess.file_exists(d + "/charge_types"):
			var t := read(d + "/charge_types")
			return {"path": d + "/charge_types", "active": active_word(t), "offered": words(t)}
	return {}


## Package temperature (°C) file: x86_pkg_temp zone, k10temp Tctl, coretemp package; "" when none.
func pkg_temp_file() -> String:
	for n in dirs("/sys/class/thermal"):
		var d := path("/sys/class/thermal/" + n)
		if read(d + "/type") == "x86_pkg_temp":
			return d + "/temp"
	for n in dirs("/sys/class/hwmon"):
		var d := path("/sys/class/hwmon/" + n)
		var name := read(d + "/name")
		if name in ["k10temp", "coretemp"]:
			for i in range(1, 8):
				var label := read(d + "/temp%d_label" % i)
				if label in ["Tctl", "Package id 0"] or (label == "" and i == 1 and FileAccess.file_exists(d + "/temp1_input")):
					return d + "/temp%d_input" % i
	return ""


## The power-tune fix's "thermald is held" mark (it stopped thermald and hasn't started it again).
func thermald_held_mark() -> bool:
	return FileAccess.file_exists(path("/var/lib/gamecove/fixes/power-tune/thermald-held"))


func thermald_active() -> bool:
	var r: Dictionary = runner.run("systemctl", PackedStringArray(["is-active", "thermald.service"]))
	return str(r.get("out", "")).strip_edges() == "active"


## Power-profiles-daemon (or tuned-ppd): {"active", "offered"} or {}.
func ppd() -> Dictionary:
	var a: Variant = system_bus.get_prop(PPD, PPD_PATH, PPD, "ActiveProfile")
	if a == null:
		return {}
	var offered := []
	var raw: Variant = system_bus.get_prop(PPD, PPD_PATH, PPD, "Profiles")
	if raw is Array:
		for p in raw:
			if p is Dictionary and p.has("Profile"):
				var v: Variant = p["Profile"]
				offered.append(str(v.get("data", "")) if v is Dictionary else str(v))
	if offered.is_empty():
		offered = ["power-saver", "balanced", "performance"]
	return {"active": str(a), "offered": offered}


# ---- reads and writes with their backend chains --------------------------------------------------
# Each pair: what is there now (null / "" / -1 when unknown) and a write that is true only after
# the read-back agrees. `*_via()` names the backend that will be used, "" when none can.

## CPU boost: steamos-manager CpuBoost1, PowerStation (AMD "cpb" only), the sysfs switch via the helper.
func boost_via() -> String:
	if sm_get("CpuBoost1", "CpuBoostState") != null:
		return "steamos-manager"
	var feats: Variant = ps_get(PS_CPU, PS_CPU_IF, "Features")
	var b := boost_file()
	if feats is Array and "cpb" in feats and b.get("via", "") == "cpufreq":
		return "powerstation"
	if not b.is_empty() and helper_present():
		return "sysfs"
	return ""


## The kernel's switch is the truth wherever it exists (intel_pstate/no_turbo, cpufreq
## boost): PowerStation's BoostEnabled read false on the Claw 8 EX with turbo on.
func get_boost() -> Variant:
	var truth: Variant = boost_sysfs()
	if truth != null and boost_via() != "":
		return truth
	match boost_via():
		"steamos-manager":
			var v: Variant = sm_get("CpuBoost1", "CpuBoostState")
			return int(v) == 1 if v != null else null
		"powerstation":
			var v: Variant = ps_get(PS_CPU, PS_CPU_IF, "BoostEnabled")
			return bool(v) if v != null else null
		"sysfs":
			return boost_sysfs()
	return null


func set_boost(on: bool) -> bool:
	match boost_via():
		"steamos-manager":
			if not sm_set("CpuBoost1", "CpuBoostState", "u", "1" if on else "0"):
				return false
		"powerstation":
			if not ps_set(PS_CPU, PS_CPU_IF, "BoostEnabled", "b", "true" if on else "false"):
				return false
		"sysfs":
			if not root_set("boost", "on" if on else "off"):
				return false
		_:
			return false
	return get_boost() == on


## SMT: PowerStation (CPUs with "ht"), else the helper. "" when the CPU can't switch it.
func smt_via() -> String:
	if not smt_control() in ["on", "off"]:
		return ""
	var feats: Variant = ps_get(PS_CPU, PS_CPU_IF, "Features")
	if feats is Array and "ht" in feats:
		return "powerstation"
	return "sysfs" if helper_present() else ""


func get_smt() -> Variant:
	var c := smt_control()
	return c == "on" if c in ["on", "off"] else null


func set_smt(on: bool) -> bool:
	match smt_via():
		"powerstation":
			if not ps_set(PS_CPU, PS_CPU_IF, "SmtEnabled", "b", "true" if on else "false"):
				return false
		"sysfs":
			if not root_set("smt", "on" if on else "off"):
				return false
		_:
			return false
	return get_smt() == on


## Logical CPUs online: PowerStation's per-core Online (prompt-free), else the helper.
## Never PowerStation's CoresEnabled: with SmtEnabled false (which it also reports on CPUs
## without SMT, like Panther Lake) it caps the count at half the threads and walks cores by
## core_id (PowerStation src/performance/cpu/cpu_features.rs set_cores_enabled), so on the
## Claw 8 EX 13 read back 8 and 14 left cpus 7-13 offline.
const PS_CORE_IF := "org.shadowblip.CPU.Core"
const MIN_CORES := 2


func cores_via() -> String:
	if not can_offline():
		return ""
	if ps_get(PS_CPU, PS_CPU_IF, "CoresCount") != null:
		return "powerstation"
	return "sysfs" if helper_present() else ""


## CPU numbers online now (cpu0 always), from sysfs: the truth for every path.
func online_cpus() -> Array:
	var out := []
	for c in cpu_numbers():
		if c == 0 or read(path(CPU + "/cpu%d/online" % c)) != "0":
			out.append(c)
	return out


## Exactly n CPUs online, the lowest-numbered ones (cpu0 never goes off, never fewer
## than MIN_CORES). Read back from sysfs; if it isn't exactly that, the CPUs that were
## online before are put back at once and it fails.
func set_cores(n: int) -> bool:
	var nums := cpu_numbers()
	n = clampi(n, MIN_CORES, nums.size())
	var before := online_cpus()
	var want := nums.slice(0, n)
	match cores_via():
		"powerstation":
			if not _ps_online(want):
				_ps_online(before)
				return false
		"sysfs":
			if not root_set("cores", str(n)):
				return false
		_:
			return false
	if online_cpus() == want:
		return true
	if cores_via() == "powerstation":
		_ps_online(before)
	return false


## Each CPU on or off through PowerStation's CoreN Online so that exactly `on` are online;
## CPUs are switched on before any goes off.
func _ps_online(on: Array) -> bool:
	var ok := true
	var nums := cpu_numbers()
	for c in nums:
		if c != 0 and c in on and not c in online_cpus():
			ok = ps_set(PS_CPU + "/Core%d" % c, PS_CORE_IF, "Online", "b", "true") and ok
	var now := online_cpus()
	for i in range(nums.size() - 1, -1, -1):
		var c: int = nums[i]
		if c != 0 and not c in on and c in now:
			ok = ps_set(PS_CPU + "/Core%d" % c, PS_CORE_IF, "Online", "b", "false") and ok
	return ok


func get_cores() -> int:
	return online_count()


func set_epp(word: String) -> bool:
	if epp_files().is_empty() or not word in epp_choices() or not root_set("epp", word):
		return false
	return epp_now() == word


## Governor: steamos-manager CpuScaling1, else the helper.
func governor_via() -> String:
	if sm_get("CpuScaling1", "CpuScalingGovernor") != null:
		return "steamos-manager"
	return "sysfs" if governor_dir() != "" and helper_present() else ""


func get_governor() -> String:
	if governor_via() == "steamos-manager":
		var v: Variant = sm_get("CpuScaling1", "CpuScalingGovernor")
		return str(v) if v != null else ""
	var d := governor_dir()
	return read(d + "/scaling_governor") if d != "" else ""


func governor_options() -> Array:
	if governor_via() == "steamos-manager":
		var v: Variant = sm_get("CpuScaling1", "AvailableCpuScalingGovernors")
		if v is Array:
			return v
	return governor_choices()


func set_governor(word: String) -> bool:
	if not word in governor_options():
		return false
	var ok := false
	if governor_via() == "steamos-manager":
		ok = sm_set("CpuScaling1", "CpuScalingGovernor", "s", word)
	elif governor_via() == "sysfs":
		ok = root_set("governor", word)
	return ok and get_governor() == word


func set_cpu_max(pct: int) -> bool:
	var c := cpu_max()
	if c.is_empty() or not helper_present():
		return false
	pct = clampi(pct, int(c["min"]), 100)
	if not root_set("cpumax", str(pct)):
		return false
	var after := cpu_max()
	return absi(int(after.get("pct", -1)) - pct) <= 1


## GPU power profile: xe power_profile (helper) or steamos-manager GpuPowerProfile1.
func gpu_profile_info() -> Dictionary:
	var x := xe_profile()
	if not x.is_empty() and helper_present():
		x["via"] = "xe"
		return x
	var a: Variant = sm_get("GpuPowerProfile1", "GpuPowerProfile")
	var o: Variant = sm_get("GpuPowerProfile1", "AvailableGpuPowerProfiles")
	if a != null and o is Array and not o.is_empty():
		return {"via": "steamos-manager", "active": str(a), "offered": o}
	return {}


func set_gpu_profile(word: String) -> bool:
	var info := gpu_profile_info()
	if info.is_empty() or not word in info["offered"]:
		return false
	var ok := root_set("gpuprofile", word) if info["via"] == "xe" else sm_set("GpuPowerProfile1", "GpuPowerProfile", "s", word)
	return ok and str(gpu_profile_info().get("active", "")) == word


## AMD GPU performance level: steamos-manager GpuPerformanceLevel1, else the helper.
func gpu_level_info() -> Dictionary:
	var a: Variant = sm_get("GpuPerformanceLevel1", "GpuPerformanceLevel")
	var o: Variant = sm_get("GpuPerformanceLevel1", "AvailableGpuPerformanceLevels")
	if a != null and o is Array and not o.is_empty():
		return {"via": "steamos-manager", "active": str(a), "offered": o}
	var f := amd_level_file()
	if f != "" and helper_present():
		return {"via": "sysfs", "active": read(f), "offered": ["auto", "low", "high", "manual"]}
	return {}


func set_gpu_level(word: String) -> bool:
	var info := gpu_level_info()
	if info.is_empty() or not word in info["offered"]:
		return false
	var ok := sm_set("GpuPerformanceLevel1", "GpuPerformanceLevel", "s", word) if info["via"] == "steamos-manager" else root_set("gpulevel", word)
	ok = ok and str(gpu_level_info().get("active", "")) == word
	if ok and word == "auto" and not _pre_manual.is_empty():
		# steamos-manager's auto writes its own window (RPe..RPa) and leaves PowerStation's
		# ManualClock alone: put back exactly what was there before manual (the Claw kept
		# ManualClock true and min_freq 850 instead of 900)
		gpu_raw_restore(_pre_manual, false)
		_pre_manual = {}
	return ok


# ---- raw GPU clock state (controls probe, leaving manual) -------------------------------

## What was there before GameCove switched the GPU to manual (gpu_raw_state()).
var _pre_manual := {}


## The raw clock state, every place one can live: steamos-manager's level, xe's
## tile0/gt0/freq0 min/max_freq, and each PowerStation card's ManualClock and
## ClockValueMhzMin/Max (PowerStation answers these even where ClockLimit* errors, the xe
## Claw). Missing parts are left out.
func gpu_raw_state() -> Dictionary:
	var out := {}
	var lvl: Variant = sm_get("GpuPerformanceLevel1", "GpuPerformanceLevel")
	if lvl != null:
		out["level"] = str(lvl)
	var f := xe_freq()
	if f != "":
		out["xe"] = [read_int(f + "/min_freq"), read_int(f + "/max_freq")]
	var cards := []
	for c in ps_cards():
		var man: Variant = ps_get(c, PS_CARD_IF, "ManualClock")
		if man == null:
			continue
		cards.append({"card": c, "manual": bool(man), "min": ps_get(c, PS_CARD_IF, "ClockValueMhzMin"),
			"max": ps_get(c, PS_CARD_IF, "ClockValueMhzMax")})
	if not cards.is_empty():
		out["ps"] = cards
	return out


## Puts a gpu_raw_state() back: the level first (steamos-manager rewrites min/max when it
## changes it), then xe min/max_freq (the root helper, else PowerStation's clock values),
## then each PowerStation card's values and ManualClock last. True when everything that
## can be read back matches.
func gpu_raw_restore(st: Dictionary, with_level := true) -> bool:
	if with_level and st.has("level") and str(sm_get("GpuPerformanceLevel1", "GpuPerformanceLevel")) != str(st["level"]):
		sm_set("GpuPerformanceLevel1", "GpuPerformanceLevel", "s", str(st["level"]))
	var ok := true
	var f := xe_freq()
	if st.has("xe") and f != "":
		var want: Array = st["xe"]
		var now := [read_int(f + "/min_freq"), read_int(f + "/max_freq")]
		if now != want:
			if helper_present():
				# order keeps min <= max at every step
				var steps := [["gpumax", want[1]], ["gpumin", want[0]]] if int(want[1]) >= now[1] else [["gpumin", want[0]], ["gpumax", want[1]]]
				for s2 in steps:
					root_set(s2[0], str(s2[1]))
			else:
				for c in st.get("ps", []):
					ps_set(c["card"], PS_CARD_IF, "ClockValueMhzMax", "d", str(want[1]))
					ps_set(c["card"], PS_CARD_IF, "ClockValueMhzMin", "d", str(want[0]))
			ok = [read_int(f + "/min_freq"), read_int(f + "/max_freq")] == want and ok
	for c in st.get("ps", []):
		if c["min"] != null and ps_get(c["card"], PS_CARD_IF, "ClockValueMhzMin") != c["min"]:
			ps_set(c["card"], PS_CARD_IF, "ClockValueMhzMin", "d", str(c["min"]))
		if c["max"] != null and ps_get(c["card"], PS_CARD_IF, "ClockValueMhzMax") != c["max"]:
			ps_set(c["card"], PS_CARD_IF, "ClockValueMhzMax", "d", str(c["max"]))
		if bool(ps_get(c["card"], PS_CARD_IF, "ManualClock")) != bool(c["manual"]):
			ps_set(c["card"], PS_CARD_IF, "ManualClock", "b", "true" if c["manual"] else "false")
		ok = bool(ps_get(c["card"], PS_CARD_IF, "ManualClock")) == bool(c["manual"]) and ok
	return ok


## steamos-manager's fixed manual GPU clock (Steam Deck), {} when it has none.
func sm_manual_clock() -> Dictionary:
	var v: Variant = sm_get("GpuPerformanceLevel1", "ManualGpuClock")
	var lo: Variant = sm_get("GpuPerformanceLevel1", "ManualGpuClockMin")
	var hi: Variant = sm_get("GpuPerformanceLevel1", "ManualGpuClockMax")
	if v == null or lo == null or hi == null or int(hi) <= int(lo):
		return {}
	return {"value": int(v), "lo": int(lo), "hi": int(hi)}


## steamos-manager applies ManualGpuClock only in the "manual" performance level: in
## "auto" its Intel driver just remembers it (src/gpu.rs IntelGpuPerformanceLevelDriver::
## set_clocks) and ManualGpuClock keeps reading min_freq, so a write in auto never read
## back (the Claw 8 EX: 1000 -> 1050 read 1000). A fixed clock therefore switches to
## manual first; if the clock doesn't read back, the level and clock from before go back.
func set_sm_manual_clock(mhz: int) -> bool:
	var c := sm_manual_clock()
	if c.is_empty():
		return false
	mhz = clampi(mhz, c["lo"], c["hi"])
	var lvl := gpu_level_info()
	var was := str(lvl.get("active", ""))
	if lvl.get("via", "") == "steamos-manager" and was != "manual" and "manual" in lvl.get("offered", []):
		if _pre_manual.is_empty():
			_pre_manual = gpu_raw_state()
		if not sm_set("GpuPerformanceLevel1", "GpuPerformanceLevel", "s", "manual"):
			_pre_manual = {}
			return false
	if sm_set("GpuPerformanceLevel1", "ManualGpuClock", "u", str(mhz)) and int(sm_manual_clock().get("value", -1)) == mhz:
		return true
	if was != "" and str(gpu_level_info().get("active", "")) != was:
		if was == "auto" and not _pre_manual.is_empty():
			gpu_raw_restore(_pre_manual)
			_pre_manual = {}
		else:
			sm_set("GpuPerformanceLevel1", "GpuPerformanceLevel", "s", was)
	return false


## Firmware platform profile: steamos-manager PerformanceProfile1, else the helper.
func platform_info() -> Dictionary:
	var a: Variant = sm_get("PerformanceProfile1", "PerformanceProfile")
	var o: Variant = sm_get("PerformanceProfile1", "AvailablePerformanceProfiles")
	if a != null and o is Array and not o.is_empty():
		return {"via": "steamos-manager", "active": str(a), "offered": o}
	var p := platform_profile()
	if not p.is_empty() and helper_present():
		p["via"] = "sysfs"
		return p
	return {}


func set_platform(word: String) -> bool:
	var info := platform_info()
	if info.is_empty() or not word in info["offered"]:
		return false
	var ok := sm_set("PerformanceProfile1", "PerformanceProfile", "s", word) if info["via"] == "steamos-manager" else root_set("platform", word)
	return ok and str(platform_info().get("active", "")) == word


func set_ppd(word: String) -> bool:
	var info := ppd()
	if info.is_empty() or not word in info["offered"]:
		return false
	if not system_bus.set_prop(PPD, PPD_PATH, PPD, "ActiveProfile", "s", word):
		return false
	return str(ppd().get("active", "")) == word


## SPPT ("sppt") or FPPT ("fppt") firmware attribute: {"value", "min", "max", "driver"} or {}.
func ppt_info(which: String) -> Dictionary:
	if not helper_present():
		return {}
	return fw_attr(["ppt_pl3_fppt", "ppt_fppt"] if which == "fppt" else ["ppt_pl2_sppt"])


func set_ppt(which: String, watts: int) -> bool:
	if ppt_info(which).is_empty() or not root_set(which, str(watts)):
		return false
	return int(ppt_info(which).get("value", -1)) == watts


## PowerStation's Tctl limit (ryzenadj only): °C or -1.
func thermal_limit() -> float:
	var c := ps_tdp_card()
	if c == "":
		return -1.0
	var v: Variant = ps_get(c, PS_TDP_IF, "ThermalThrottleLimitC")
	return float(v) if v != null and float(v) > 0.0 else -1.0


func set_thermal_limit(c_deg: float) -> bool:
	var c := ps_tdp_card()
	if c == "" or not ps_set(c, PS_TDP_IF, "ThermalThrottleLimitC", "d", "%.1f" % c_deg):
		return false
	return absf(thermal_limit() - c_deg) < 0.5


## PowerStation boost watts (PL2 - PL1 / SPPT above SPL): {"value", "max"} or {}.
func ps_boost() -> Dictionary:
	var c := ps_tdp_card()
	if c == "":
		return {}
	var v: Variant = ps_get(c, PS_TDP_IF, "Boost")
	if v == null:
		return {}
	var mx: Variant = ps_get(c, PS_TDP_IF, "MaxBoost")
	return {"value": float(v), "max": float(mx) if mx != null else -1.0}


func set_ps_boost(watts: float) -> bool:
	var c := ps_tdp_card()
	if c == "" or not ps_set(c, PS_TDP_IF, "Boost", "d", "%.1f" % watts):
		return false
	return absf(float(ps_boost().get("value", -99.0)) - watts) < 0.5


func tau_us() -> int:
	var f := rapl_window()
	return read_int(f) if f != "" else -1


func set_tau(us: int) -> bool:
	if rapl_window() == "" or not root_set("tau", str(us)):
		return false
	var got := tau_us()
	return got > 0 and absi(got - us) <= us / 4


func restore_tau() -> bool:
	return rapl_window() != "" and root_set("tau", "restore")


func set_mem_sleep(word: String) -> bool:
	var m := mem_sleep()
	if m.is_empty() or not word in m["offered"] or not root_set("sleep", word):
		return false
	return str(mem_sleep().get("active", "")) == word


func set_mcu(on: bool) -> bool:
	var f := mcu_file()
	if f == "" or not root_set("mcu", "on" if on else "off"):
		return false
	return read(f) == ("1" if on else "0")


func set_battery_mode(long_life: bool) -> bool:
	var c := charge_types()
	if c.is_empty() or not root_set("battery", "long-life" if long_life else "standard"):
		return false
	return str(charge_types().get("active", "")) == ("Long_Life" if long_life else "Standard")
