extends RefCounted
## Fake sysfs trees and D-Bus answers for the power controls, one per backend family, written
## into a temp folder under user:// (never the real system). Each tree() returns
## {"root": path, "props": busctl props, "methods": busctl methods, "row": devices.json row}.
## The root helper is the real fixes/power-tune and fixes/fan scripts, run by runner() with
## GAMECOVE_ROOT set to the tree, so the tests cover the GDScript side and the root side together.
##
##   claw8ex   MSI Claw 8 EX: Intel Panther Lake, xe GPU, PowerStation TDP (RAPL), no SMT, msi fan
##             tables, charge threshold, mem_sleep s2idle/deep, RAPL window, thermald running
##   a1m       MSI Claw A1M: Intel Meteor Lake, i915 (PowerStation clocks), SMT, steamos-manager TDP
##   ally      ROG Ally: AMD, amd-pstate per-policy boost, PowerStation CPU (cpb, ht) and GPU clocks,
##             Tctl, asus-armoury PPT + MCU power saving, PPD, asus fan curve, amdgpu level
##   deck      Steam Deck: steamos-manager for everything, no root helper
##   legion    Legion Go S: lenovo-wmi-other-0 PPT (custom mode), charge_types Long Life
##   bare      nothing: no services, no helper, no CPU controls

const SM := "--user get-property com.steampowered.SteamOSManager1 /com/steampowered/SteamOSManager1 com.steampowered.SteamOSManager1."
const PS := "--system get-property org.shadowblip.PowerStation "
const PS_CPU := PS + "/org/shadowblip/Performance/CPU org.shadowblip.CPU "
const PS_ENUM := "--system call org.shadowblip.PowerStation /org/shadowblip/Performance/GPU org.shadowblip.GPU EnumerateCards"
const PPD := "--system get-property org.freedesktop.UPower.PowerProfiles /org/freedesktop/UPower/PowerProfiles org.freedesktop.UPower.PowerProfiles "
const CPU := "/sys/devices/system/cpu"

var root := ""


static func row(id: String) -> Dictionary:
	for d in load("res://scripts/device/device.gd").load_table():
		if d["id"] == id:
			return d
	return {}


func w(rel: String, text: String) -> void:
	var p := root + rel
	DirAccess.make_dir_recursive_absolute(p.get_base_dir())
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(text + "\n")
	f.close()


static func wipe(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(path + "/" + f)
	for sub in d.get_directories():
		wipe(path + "/" + sub)
	DirAccess.remove_absolute(path)


func _begin(name: String) -> void:
	root = ProjectSettings.globalize_path("user://test_power_controls/" + name)
	wipe(root)
	DirAccess.make_dir_recursive_absolute(root)


func dmi(vendor: String, product: String, board: String) -> void:
	w("/sys/class/dmi/id/sys_vendor", vendor)
	w("/sys/class/dmi/id/product_name", product)
	w("/sys/class/dmi/id/board_name", board)
	w("/sys/class/dmi/id/board_vendor", vendor)


func helper() -> void:
	w("/usr/libexec/gamecove/gamecove-fix-set", "#!/bin/sh")
	w("/usr/libexec/gamecove/gamecove-fix", "#!/bin/sh")


func battery(capacity := 60, ac := false) -> void:
	w("/sys/class/power_supply/BAT1/type", "Battery")
	w("/sys/class/power_supply/BAT1/capacity", str(capacity))
	w("/sys/class/power_supply/ADP1/type", "Mains")
	w("/sys/class/power_supply/ADP1/online", "1" if ac else "0")


func intel_cpu(n: int, smt: String) -> void:
	for i in n:
		w(CPU + "/cpu%d/cpufreq/energy_performance_preference" % i, "balance_performance")
		w(CPU + "/cpu%d/cpufreq/energy_performance_available_preferences" % i, "default performance balance_performance balance_power power")
		if i > 0:
			w(CPU + "/cpu%d/online" % i, "1")
	w(CPU + "/cpufreq/policy0/scaling_governor", "powersave")
	w(CPU + "/cpufreq/policy0/scaling_available_governors", "performance powersave")
	w(CPU + "/intel_pstate/no_turbo", "0")
	w(CPU + "/intel_pstate/max_perf_pct", "100")
	w(CPU + "/intel_pstate/min_perf_pct", "40")
	w(CPU + "/smt/control", smt)


func amd_cpu(n: int) -> void:
	for i in n:
		w(CPU + "/cpu%d/cpufreq/energy_performance_preference" % i, "balance_performance")
		w(CPU + "/cpu%d/cpufreq/energy_performance_available_preferences" % i, "default performance balance_performance balance_power power")
		if i > 0:
			w(CPU + "/cpu%d/online" % i, "1")
		w(CPU + "/cpufreq/policy%d/boost" % i, "1")
		w(CPU + "/cpufreq/policy%d/cpuinfo_max_freq" % i, "5100000")
		w(CPU + "/cpufreq/policy%d/cpuinfo_min_freq" % i, "400000")
		w(CPU + "/cpufreq/policy%d/scaling_max_freq" % i, "5100000")
		w(CPU + "/cpufreq/policy%d/scaling_governor" % i, "powersave")
		w(CPU + "/cpufreq/policy%d/scaling_available_governors" % i, "performance powersave")
	w(CPU + "/smt/control", "on")


func msi_fan() -> void:
	var h := "/sys/class/hwmon/hwmon5/"
	w(h + "name", "msi_wmi_platform")
	var duty := [0, 102, 128, 153, 179, 204]
	for n in [1, 2]:
		w(h + "pwm%d_enable" % n, "2")
		for i in 6:
			w(h + "pwm%d_auto_point%d_pwm" % [n, i + 1], str(duty[i]))
			w(h + "pwm%d_auto_point%d_temp" % [n, i + 1], str(40000 + i * 10000))


func asus_fan() -> void:
	var h := "/sys/class/hwmon/hwmon6/"
	w(h + "name", "asus_custom_fan_curve")
	for n in [1, 2]:
		w(h + "pwm%d_enable" % n, "2")
		for i in 8:
			w(h + "pwm%d_auto_point%d_pwm" % [n, i + 1], str(20 * (i + 1)))
			w(h + "pwm%d_auto_point%d_temp" % [n, i + 1], str(30 + 10 * i))


func fw_attr(cls: String, name: String, value: int, lo: int, hi: int) -> void:
	var a := "/sys/class/firmware-attributes/%s/attributes/%s/" % [cls, name]
	w(a + "current_value", str(value))
	w(a + "min_value", str(lo))
	w(a + "max_value", str(hi))


static func p(t: String, data: Variant) -> Dictionary:
	return {"type": t, "data": data}


func claw8ex() -> Dictionary:
	_begin("claw8ex")
	dmi("Micro-Star International Co., Ltd.", "Claw 8 EX AI+ CG3EM", "MS-1T91")
	helper()
	battery()
	intel_cpu(4, "notsupported")
	w("/sys/class/drm/card1/device/uevent", "DRIVER=xe\nPCI_ID=8086:B080")
	var g := "/sys/class/drm/card1/device/tile0/gt0/freq0/"
	for kv in [["min_freq", "100"], ["max_freq", "2300"], ["rpn_freq", "100"], ["rp0_freq", "2300"], ["rpe_freq", "1000"], ["cur_freq", "800"]]:
		w(g + kv[0], kv[1])
	w(g + "power_profile", "[base] power_saving")
	var r := "/sys/class/powercap/intel-rapl-mmio:0/"
	w(r + "name", "package-0")
	w(r + "constraint_0_name", "long_term")
	w(r + "constraint_0_time_window_us", "55967744")
	w(r + "constraint_1_name", "short_term")
	w("/sys/power/mem_sleep", "[s2idle] deep")
	w("/sys/class/power_supply/BAT1/charge_control_end_threshold", "0")
	w("/sys/class/thermal/thermal_zone3/type", "x86_pkg_temp")
	w("/sys/class/thermal/thermal_zone3/temp", "60000")
	fw_attr("msi-wmi-platform", "ppt_pl1_spl", 25, 8, 35)
	fw_attr("msi-wmi-platform", "ppt_pl2_sppt", 37, 9, 45)
	msi_fan()
	var card := "/org/shadowblip/Performance/GPU/card1"
	return {"root": root, "row": row("msi-claw-8-ex"), "props": {
		PS + card + " org.shadowblip.GPU.Card.TDP TDP": p("d", 25.0),
		PS + card + " org.shadowblip.GPU.Card.TDP MinTdp": p("d", 0.0),
		PS + card + " org.shadowblip.GPU.Card.TDP MaxTdp": p("d", 0.0),
		PS + card + " org.shadowblip.GPU.Card.TDP Boost": p("d", 12.0),
		PS + card + " org.shadowblip.GPU.Card.TDP MaxBoost": p("d", 0.0),
		PS_CPU + "Features": p("as", ["fpu", "sse"]),
	}, "methods": {PS_ENUM: p("ao", [[card]])}}


func a1m() -> Dictionary:
	_begin("a1m")
	dmi("Micro-Star International Co., Ltd.", "Claw A1M", "MS-1T41")
	helper()
	battery()
	intel_cpu(4, "on")
	w("/sys/class/drm/card0/device/uevent", "DRIVER=i915\nPCI_ID=8086:7D55")
	var c := "/sys/class/drm/card0/"
	for kv in [["gt_min_freq_mhz", "300"], ["gt_max_freq_mhz", "2250"], ["gt_RPn_freq_mhz", "300"], ["gt_RP0_freq_mhz", "2250"], ["gt_RPe_freq_mhz", "1000"]]:
		w(c + kv[0], kv[1])
	var card := "/org/shadowblip/Performance/GPU/card0"
	return {"root": root, "row": row("msi-claw-a1m"), "props": {
		SM + "TdpLimit1 TdpLimit": p("u", 25), SM + "TdpLimit1 TdpLimitMin": p("u", 8), SM + "TdpLimit1 TdpLimitMax": p("u", 43),
		PS + card + " org.shadowblip.GPU.Card ClockLimitMhzMin": p("d", 300.0),
		PS + card + " org.shadowblip.GPU.Card ClockLimitMhzMax": p("d", 2250.0),
		PS + card + " org.shadowblip.GPU.Card ClockValueMhzMin": p("d", 300.0),
		PS + card + " org.shadowblip.GPU.Card ClockValueMhzMax": p("d", 2250.0),
		PS + card + " org.shadowblip.GPU.Card ManualClock": p("b", false),
		PS_CPU + "Features": p("as", ["ht"]), PS_CPU + "SmtEnabled": p("b", true),
		PS_CPU + "CoresEnabled": p("u", 4), PS_CPU + "CoresCount": p("u", 4),
	}, "methods": {PS_ENUM: p("ao", [[card]])}}


func ally() -> Dictionary:
	_begin("ally")
	dmi("ASUSTeK COMPUTER INC.", "ROG Ally RC71L_RC71L", "RC71L")
	helper()
	battery()
	amd_cpu(4)
	w("/sys/class/drm/card0/device/uevent", "DRIVER=amdgpu\nPCI_ID=1002:15BF")
	w("/sys/class/drm/card0/device/power_dpm_force_performance_level", "auto")
	w("/sys/class/drm/card0/device/pp_od_clk_voltage", "OD_SCLK:\n0: 800Mhz\n1: 2700Mhz\nOD_RANGE:\nSCLK:     800Mhz       2700Mhz")
	fw_attr("asus-armoury", "ppt_pl1_spl", 15, 7, 25)
	fw_attr("asus-armoury", "ppt_pl2_sppt", 20, 15, 30)
	fw_attr("asus-armoury", "ppt_pl3_fppt", 25, 15, 35)
	w("/sys/class/firmware-attributes/asus-armoury/attributes/mcu_powersave/current_value", "1")
	w("/sys/firmware/acpi/platform_profile", "balanced")
	w("/sys/firmware/acpi/platform_profile_choices", "quiet balanced performance")
	w("/sys/class/power_supply/BAT1/charge_control_end_threshold", "100")
	w("/sys/class/hwmon/hwmon2/name", "k10temp")
	w("/sys/class/hwmon/hwmon2/temp1_label", "Tctl")
	w("/sys/class/hwmon/hwmon2/temp1_input", "55000")
	asus_fan()
	var card := "/org/shadowblip/Performance/GPU/card0"
	var out := {"root": root, "row": row("asus-rog-ally"), "props": {
		SM + "TdpLimit1 TdpLimit": p("u", 15), SM + "TdpLimit1 TdpLimitMin": p("u", 5), SM + "TdpLimit1 TdpLimitMax": p("u", 30),
		SM + "BatteryChargeLimit1 MaxChargeLevel": p("i", 100), SM + "BatteryChargeLimit1 SuggestedMinimumLimit": p("i", 50),
		PS_CPU + "Features": p("as", ["cpb", "ht"]), PS_CPU + "SmtEnabled": p("b", true),
		PS_CPU + "CoresEnabled": p("u", 4), PS_CPU + "CoresCount": p("u", 4),
		PS + card + " org.shadowblip.GPU.Card ClockLimitMhzMin": p("d", 800.0),
		PS + card + " org.shadowblip.GPU.Card ClockLimitMhzMax": p("d", 2700.0),
		PS + card + " org.shadowblip.GPU.Card ClockValueMhzMin": p("d", 800.0),
		PS + card + " org.shadowblip.GPU.Card ClockValueMhzMax": p("d", 2700.0),
		PS + card + " org.shadowblip.GPU.Card ManualClock": p("b", false),
		PS + card + " org.shadowblip.GPU.Card.TDP TDP": p("d", 15.0),
		PS + card + " org.shadowblip.GPU.Card.TDP ThermalThrottleLimitC": p("d", 95.0),
		PPD + "ActiveProfile": p("s", "balanced"),
		PPD + "Profiles": p("aa{sv}", [{"Profile": p("s", "power-saver")}, {"Profile": p("s", "balanced")}, {"Profile": p("s", "performance")}]),
	}, "methods": {PS_ENUM: p("ao", [[card]])}}
	return out


func deck() -> Dictionary:
	_begin("deck")
	dmi("Valve", "Galileo", "Galileo")
	battery()
	amd_cpu(4)
	w("/sys/class/drm/card0/device/uevent", "DRIVER=amdgpu\nPCI_ID=1002:1435")
	return {"root": root, "row": row("steam-deck-oled"), "props": {
		SM + "TdpLimit1 TdpLimit": p("u", 15), SM + "TdpLimit1 TdpLimitMin": p("u", 3), SM + "TdpLimit1 TdpLimitMax": p("u", 15),
		SM + "BatteryChargeLimit1 MaxChargeLevel": p("i", 100), SM + "BatteryChargeLimit1 SuggestedMinimumLimit": p("i", 50),
		SM + "FanControl1 FanControlState": p("u", 1),
		SM + "CpuBoost1 CpuBoostState": p("u", 1),
		SM + "CpuScaling1 CpuScalingGovernor": p("s", "schedutil"),
		SM + "CpuScaling1 AvailableCpuScalingGovernors": p("as", ["schedutil", "powersave", "performance"]),
		SM + "GpuPerformanceLevel1 GpuPerformanceLevel": p("s", "auto"),
		SM + "GpuPerformanceLevel1 AvailableGpuPerformanceLevels": p("as", ["auto", "low", "high", "manual", "peak_performance"]),
		SM + "GpuPerformanceLevel1 ManualGpuClock": p("u", 1000),
		SM + "GpuPerformanceLevel1 ManualGpuClockMin": p("u", 200),
		SM + "GpuPerformanceLevel1 ManualGpuClockMax": p("u", 1600),
		SM + "GpuPowerProfile1 GpuPowerProfile": p("s", "3d_full_screen"),
		SM + "GpuPowerProfile1 AvailableGpuPowerProfiles": p("as", ["3d_full_screen", "video", "vr", "compute", "custom", "capped", "uncapped"]),
		SM + "PerformanceProfile1 PerformanceProfile": p("s", "balanced"),
		SM + "PerformanceProfile1 AvailablePerformanceProfiles": p("as", ["low-power", "balanced", "performance"]),
	}, "methods": {}}


func legion() -> Dictionary:
	_begin("legion")
	dmi("LENOVO", "83L3", "83L3")
	helper()
	battery()
	amd_cpu(4)
	fw_attr("lenovo-wmi-other-0", "ppt_pl1_spl", 15, 5, 30)
	fw_attr("lenovo-wmi-other-0", "ppt_pl2_sppt", 20, 5, 35)
	fw_attr("lenovo-wmi-other-0", "ppt_pl3_fppt", 25, 5, 41)
	w("/sys/firmware/acpi/platform_profile", "balanced")
	w("/sys/firmware/acpi/platform_profile_choices", "low-power balanced performance custom")
	w("/sys/class/power_supply/BAT1/charge_types", "[Standard] Long_Life")
	return {"root": root, "row": row("lenovo-legion-go-s-z2go"), "props": {
		SM + "TdpLimit1 TdpLimit": p("u", 15), SM + "TdpLimit1 TdpLimitMin": p("u", 5), SM + "TdpLimit1 TdpLimitMax": p("u", 33),
	}, "methods": {}}


func bare() -> Dictionary:
	_begin("bare")
	dmi("Some Maker", "Some Handheld", "X1")
	return {"root": root, "row": {}, "props": {}, "methods": {}}


## A fake runner on this tree whose pkexec runs the real root scripts against it, and whose
## systemctl reports thermald from <root>/thermald.state.
static func runner(t: Dictionary) -> RefCounted:
	var r: RefCounted = load("res://tests/fixtures/power/fake_runner.gd").new()
	r.props = t["props"].duplicate(true)
	r.methods = t["methods"].duplicate(true)
	var tree_root: String = t["root"]
	var repo := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	r.exec_handler = func(argv: PackedStringArray) -> Dictionary:
		if argv[0] == "systemctl":
			var st := FileAccess.get_file_as_string(tree_root + "/thermald.state").strip_edges()
			if argv[1] == "is-active":
				return {"code": 0 if st == "active" else 3, "out": st if st != "" else "inactive"}
			var f := FileAccess.open(tree_root + "/thermald.state", FileAccess.WRITE)
			f.store_string("inactive" if argv[1] == "stop" else "active")
			return {"code": 0, "out": ""}
		if argv[0] == "pkexec" and argv.size() >= 5 and (argv[1].ends_with("gamecove-fix-set") or argv[1].ends_with("gamecove-fix")):
			var out := []
			var bin := ProjectSettings.globalize_path("user://test_power_controls/bin")
			var code := OS.execute("env", PackedStringArray(["GAMECOVE_ROOT=" + tree_root, "PATH=" + bin + ":/usr/bin:/bin",
				"GAMECOVE_THERMALD_WATCH=off",
				"sh", repo.path_join("fixes/%s/fix.sh" % argv[2]), argv[3], argv[4]]), out, true)
			return {"code": code, "out": out[0] if out.size() > 0 else ""}
		return {"code": 0, "out": ""}
	return r


## A systemctl stub for the root scripts (thermald hold/release), state in <root>/thermald.state.
static func make_bin() -> void:
	var bin := ProjectSettings.globalize_path("user://test_power_controls/bin")
	DirAccess.make_dir_recursive_absolute(bin)
	var f := FileAccess.open(bin + "/systemctl", FileAccess.WRITE)
	f.store_string("#!/bin/sh\nf=\"$GAMECOVE_ROOT/thermald.state\"\ncase \"$1\" in\nis-active) cat \"$f\" 2>/dev/null || echo inactive ;;\nstop) echo inactive > \"$f\" ;;\nstart) echo active > \"$f\" ;;\nesac\n")
	f.close()
	OS.execute("chmod", PackedStringArray(["+x", bin + "/systemctl"]))
