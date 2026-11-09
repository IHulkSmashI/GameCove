extends RefCounted
## What each control must have done to the system, checked against the fake
## hardware (sysfs files under the fixture, D-Bus properties, gamescope root
## atoms, the commands that ran). `check(t, id, value)` returns "" when the
## system shows `value`, else what it shows instead. Controls without an entry
## are covered by the fresh read (suite_settings.gd) only.

const Matrix := preload("res://tests/devicematrix/matrix.gd")
const SM := "com.steampowered.SteamOSManager1"
const PS := "org.shadowblip.PowerStation"
## Controls whose state is a running process or the provider's own memory, not
## something a fresh provider can read back from the system (checked by effect).
const NO_FRESH_READ := ["system.keep_awake"]


## Same value, allowing for float noise and int/float.
static func same(c: Object, a: Variant, b: Variant) -> bool:
	if (a is float or a is int) and (b is float or b is int):
		return absf(float(a) - float(b)) < 0.51 * maxf(0.0001, c.step if c.kind == "slider" else 0.01)
	if a is String and b is String and a.is_valid_html_color() and b.is_valid_html_color():
		return Color.html(a).is_equal_approx(Color.html(b))
	if a is Array and b is Array and a.size() == b.size():
		for i in a.size():
			if absf(float(a[i]) - float(b[i])) > 0.51:
				return false
		return true
	return a == b


static func _cpus(w: RefCounted, rel: String) -> Array:
	var out := []
	for d in DirAccess.get_directories_at(w.root + "/sys/devices/system/cpu"):
		if d.begins_with("cpu") and d.substr(3).is_valid_int():
			var f := "/sys/devices/system/cpu/%s/%s" % [d, rel]
			if FileAccess.file_exists(w.root + f):
				out.append(w.read(f))
	return out


static func _active(text: String) -> String:
	var i := text.find("[")
	var j := text.find("]")
	return text.substr(i + 1, j - i - 1) if i >= 0 and j > i else text.strip_edges()


static func _fw_attr(w: RefCounted, attr: String) -> String:
	for fw in DirAccess.get_directories_at(w.root + "/sys/class/firmware-attributes"):
		var f := "/sys/class/firmware-attributes/%s/attributes/%s/current_value" % [fw, attr]
		if FileAccess.file_exists(w.root + f):
			return w.read(f)
	return ""


static func check(t: Object, id: String, v: Variant) -> String:
	var w: RefCounted = t.w
	var power: Node = w.autoload("Power")
	var f := func(x: Variant) -> String: return str(int(round(float(x)))) if (x is float or x is int) else str(x)
	match id:
		"power.tdp":
			match power.backend:
				"powerstation":
					if FileAccess.file_exists(w.root + "/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw"):
						var pl1 = w.read("/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw").to_float() / 1e6
						return "" if absf(pl1 - float(v)) < 0.01 else "RAPL PL1 is %s W" % pl1
				"steamos-manager":
					var spl = _fw_attr(w, "ppt_pl1_spl")
					return "" if spl == f.call(v) else "firmware SPL is %s W" % spl
			return ""
		"power.boost":
			var r := "/sys/class/powercap/intel-rapl-mmio:0/"
			if FileAccess.file_exists(w.root + r + "constraint_1_power_limit_uw"):
				var b = (w.read(r + "constraint_1_power_limit_uw").to_float() - w.read(r + "constraint_0_power_limit_uw").to_float()) / 1e6
				return "" if absf(b - float(v)) < 0.01 else "RAPL PL2 - PL1 is %s W" % b
		"power.sppt":
			return "" if _fw_attr(w, "ppt_pl2_sppt") == f.call(v) else "firmware SPPT is %s" % _fw_attr(w, "ppt_pl2_sppt")
		"power.fppt":
			return "" if _fw_attr(w, "ppt_pl3_fppt") == f.call(v) else "firmware FPPT is %s" % _fw_attr(w, "ppt_pl3_fppt")
		"power.epp":
			var all = _cpus(w, "cpufreq/energy_performance_preference")
			return "" if not all.is_empty() and all.all(func(x): return x == str(v)) else "CPUs have EPP %s" % [all]
		"power.governor":
			var g = _cpus(w, "cpufreq/scaling_governor")
			return "" if g.all(func(x): return x == str(v)) else "CPUs have governor %s" % [g]
		"power.platform_profile":
			var pp = w.read("/sys/firmware/acpi/platform_profile")
			return "" if pp == str(v) else "platform_profile is %s" % pp
		"power.power_mode":
			var m: Variant = w.fake.prop("org.freedesktop.UPower.PowerProfiles", "/org/freedesktop/UPower/PowerProfiles",
				"org.freedesktop.UPower.PowerProfiles", "ActiveProfile")
			return "" if str(m) == str(v) else "tuned-ppd ActiveProfile is %s" % m
		"power.cpu_boost":
			if FileAccess.file_exists(w.root + "/sys/devices/system/cpu/intel_pstate/no_turbo"):
				var nt = w.read("/sys/devices/system/cpu/intel_pstate/no_turbo")
				return "" if nt == ("0" if v else "1") else "intel_pstate/no_turbo is %s" % nt
			var bf = w.read("/sys/devices/system/cpu/cpufreq/boost")
			return "" if bf == ("1" if v else "0") else "cpufreq/boost is %s" % bf
		"power.smt":
			var sc = w.read("/sys/devices/system/cpu/smt/control")
			return "" if sc == ("on" if v else "off") else "smt/control is %s" % sc
		"power.cpu_cores":
			var n = 1 + _cpus(w, "online").filter(func(x): return x == "1").size()
			return "" if n == int(v) else "%d CPUs online" % n
		"power.cpu_max":
			if FileAccess.file_exists(w.root + "/sys/devices/system/cpu/intel_pstate/max_perf_pct"):
				var mp = w.read("/sys/devices/system/cpu/intel_pstate/max_perf_pct")
				return "" if mp == f.call(v) else "intel_pstate/max_perf_pct is %s" % mp
		"power.gpu_min", "power.gpu_max":
			var fq := "/sys/class/drm/card0/device/tile0/gt0/freq0/" + ("min_freq" if id == "power.gpu_min" else "max_freq")
			if FileAccess.file_exists(w.root + fq):
				return "" if w.read(fq) == f.call(v) else "xe %s is %s" % [fq.get_file(), w.read(fq)]
		"power.gpu_profile":
			var pf := "/sys/class/drm/card0/device/tile0/gt0/freq0/power_profile"
			if FileAccess.file_exists(w.root + pf):
				return "" if _active(w.read(pf)) == str(v) else "xe power_profile is %s" % w.read(pf)
			var gp: Variant = w.fake.prop(SM, "/com/steampowered/SteamOSManager1", SM + ".GpuPowerProfile1", "GpuPowerProfile")
			return "" if str(gp) == str(v) else "steamos-manager GpuPowerProfile is %s" % gp
		"power.gpu_level":
			for c in ["card0", "card1"]:
				var lf := "/sys/class/drm/%s/device/power_dpm_force_performance_level" % c
				if FileAccess.file_exists(w.root + lf):
					var want := "profile_peak" if str(v) == "peak_performance" else str(v)
					return "" if w.read(lf) == want else "power_dpm_force_performance_level is %s" % w.read(lf)
		"power.charge_limit":
			for bat in ["BAT0", "BAT1"]:
				var cf := "/sys/class/power_supply/%s/charge_control_end_threshold" % bat
				if FileAccess.file_exists(w.root + cf):
					return "" if w.read(cf) == f.call(v) else "battery stops at %s %%" % w.read(cf)
		"power.battery_long_life":
			for bat in ["BAT0", "BAT1"]:
				var tf := "/sys/class/power_supply/%s/charge_types" % bat
				if FileAccess.file_exists(w.root + tf):
					var want := "Long_Life" if v else "Standard"
					return "" if _active(w.read(tf)) == want else "charge_types is %s" % w.read(tf)
		"power.sleep_mode":
			var ms = _active(w.read("/sys/power/mem_sleep"))
			return "" if ms == str(v) else "mem_sleep is %s" % w.read("/sys/power/mem_sleep")
		"power.mcu_powersave":
			var mf = w.read("/sys/devices/platform/asus-nb-wmi/mcu_powersave")
			return "" if mf == ("1" if v else "0") else "mcu_powersave is %s" % mf
		"display.fps_limit":
			return "" if t.atom("GAMESCOPE_FPS_LIMIT") == f.call(v) else "GAMESCOPE_FPS_LIMIT is %s" % t.atom("GAMESCOPE_FPS_LIMIT")
		"display.vrr":
			return "" if t.atom("GAMESCOPE_VRR_ENABLED") == ("1" if v else "0") else "GAMESCOPE_VRR_ENABLED is %s" % t.atom("GAMESCOPE_VRR_ENABLED")
		"display.allow_tearing":
			return "" if t.atom("GAMESCOPE_ALLOW_TEARING") == ("1" if v else "0") else "GAMESCOPE_ALLOW_TEARING is %s" % t.atom("GAMESCOPE_ALLOW_TEARING")
		"display.sharpness":
			return "" if t.atom("GAMESCOPE_SHARPNESS") == str(20 - int(v)) else "GAMESCOPE_SHARPNESS is %s" % t.atom("GAMESCOPE_SHARPNESS")
		"display.upscale_filter":
			return "" if t.atom("GAMESCOPE_NEW_SCALING_FILTER") == f.call(v) else "GAMESCOPE_NEW_SCALING_FILTER is %s" % t.atom("GAMESCOPE_NEW_SCALING_FILTER")
		"display.upscale_scaler":
			return "" if t.atom("GAMESCOPE_NEW_SCALING_SCALER") == f.call(v) else "GAMESCOPE_NEW_SCALING_SCALER is %s" % t.atom("GAMESCOPE_NEW_SCALING_SCALER")
		"display.brightness":
			var bl := ""
			for d in DirAccess.get_directories_at(w.root + "/sys/class/backlight"):
				bl = d
			var mx: float = w.read("/sys/class/backlight/%s/max_brightness" % bl).to_float()
			var raw: float = w.read("/sys/class/backlight/%s/brightness" % bl).to_float()
			var pct := roundf(raw * 100.0 / mx)
			return "" if absf(pct - maxf(float(v), 5.0)) <= 1.0 else "backlight is %s %% (%s / %s)" % [pct, raw, mx]
		"audio.volume":
			var vol: float = w.fake.audio["vol"][w.fake.audio["sink"]] * 100.0
			return "" if absf(vol - float(v)) < 0.6 else "the default sink is at %s %%" % vol
		"audio.mute":
			var m: bool = w.fake.audio["mute"][w.fake.audio["sink"]]
			return "" if m == bool(v) else "the default sink mute is %s" % m
		"audio.mic_mute":
			var mm: bool = w.fake.audio["mute"][w.fake.audio["source"]]
			return "" if mm == bool(v) else "the default source mute is %s" % mm
		"audio.output":
			var name: String = w.fake.audio["sinks"][w.fake.audio["sink"]]
			return "" if name == str(v) else "the default sink is %s" % name
		"network.wifi":
			var on: bool = w.fake.radios["wifi"] and not w.fake.radios["wlan_soft"]
			return "" if on == bool(v) else "Wi-Fi radio is %s" % on
	return ""
