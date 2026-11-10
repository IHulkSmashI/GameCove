extends "res://tests/test_case.gd"
## The power.* controls (providers/power.gd) on fake handhelds, one per backend family
## (fixtures/power_controls/trees.gd): what is offered and why not, ranges, writes through
## steamos-manager / PowerStation / the real root scripts, read-back, failure and restore paths,
## battery saver, resume, per-device memory, and every devices.json row without a crash.

const Trees := preload("res://tests/fixtures/power_controls/trees.gd")
const ControlsScript := preload("res://scripts/controls/controls.gd")
const ProviderScript := preload("res://scripts/controls/providers/power.gd")
const PowerScript := preload("res://scripts/device/power.gd")
const Tx := preload("res://scripts/controls/power/texts.gd")

var _nodes: Array = []


## {"reg", "power", "prov", "runner", "root", "c": {id: control}} for a tree.
func _setup(t: Dictionary, plugged := false) -> Dictionary:
	Trees.make_bin()
	var runner: RefCounted = Trees.runner(t)
	var power: Node = PowerScript.new()
	power.setup(runner, t["row"], t["root"])
	power.config_path = t["root"] + "/power.cfg"
	if plugged:
		var f := FileAccess.open(t["root"] + "/sys/class/power_supply/ADP1/online", FileAccess.WRITE)
		f.store_string("1\n")
		f.close()
	power.detect()
	power.load_autotune_opts()
	var reg: Node = ControlsScript.new()
	reg.sync_mode = true
	var ctx := {"sys_root": t["root"], "runner": runner, "home": t["root"], "device": t["row"], "power": power, "registry": reg}
	reg.setup(ctx)
	var prov: RefCounted = ProviderScript.new()
	prov.cfg_path = t["root"] + "/power_controls.cfg"
	prov.setup(ctx)
	reg.register_provider(prov)
	reg.detect_all()
	_nodes.append(reg)
	_nodes.append(power)
	var by := {}
	for c in reg.list("power"):
		by[c.id] = c
	return {"reg": reg, "power": power, "prov": prov, "runner": runner, "root": t["root"], "c": by}


func _free() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()


func _read(root: String, rel: String) -> String:
	return FileAccess.get_file_as_string(root + rel).strip_edges()


func _avail(e: Dictionary) -> Array:
	var out := []
	for id in e["c"]:
		if e["c"][id].available:
			out.append(id)
	out.sort()
	return out


func _every_reason_set(e: Dictionary, what: String) -> void:
	for id in e["c"]:
		var c = e["c"][id]
		ok(c.available or c.reason != "", "%s: %s has a reason" % [what, id])
		ok(not c.available or c.reason == "", "%s: %s available without a reason" % [what, id])


func _no_root_writes_outside(e: Dictionary) -> void:
	for call in e["runner"].calls:
		ok(not str(call).contains(" /sys/") and not str(call).contains("> /"), "no direct system path in %s" % call)


# ---- Intel xe: MSI Claw 8 EX --------------------------------------------------------------------

func test_claw8ex_offers_what_this_handheld_has() -> void:
	var e := _setup(Trees.new().claw8ex())
	_every_reason_set(e, "claw")
	var c: Dictionary = e["c"]
	for id in ["power.tdp", "power.profile", "power.boost", "power.cpu_boost", "power.epp", "power.governor", "power.cpu_max",
			"power.gpu_min", "power.gpu_max", "power.gpu_profile", "power.charge_limit", "power.fan_mode", "power.fan_curve",
			"power.sleep_mode", "power.battery_saver", "power.autotune_target", "power.autotune_keep", "power.cpu_cores"]:
		ok(c[id].available, "claw offers %s (%s)" % [id, c[id].reason])
	eq(c["power.smt"].reason, Tx.NO_SMT, "no SMT on Panther Lake")
	eq(c["power.sppt"].reason, Tx.FW_IGNORED, "firmware PPT ignored on the EX (ClawDeck §12)")
	eq(c["power.gpu_level"].reason, Tx.AMD_ONLY, "AMD-only")
	eq(c["power.thermal_limit"].reason, Tx.NO_THERMAL, "no Tctl on Intel")
	eq(c["power.mcu_powersave"].reason, Tx.NOT_HERE, "no Ally MCU")
	eq([c["power.tdp"].min_value, c["power.tdp"].max_value], [8.0, 35.0], "TDP range from devices.json")
	eq(c["power.boost"].max_value, 10.0, "boost up to boost_max 45 - 35")
	eq([c["power.gpu_min"].min_value, c["power.gpu_min"].max_value], [100.0, 2300.0], "xe hardware range")
	eq(c["power.cpu_max"].min_value, 40.0, "never under intel_pstate's min_perf_pct")
	eq(c["power.fan_curve"].points, 6, "msi fan table points")
	eq(c["power.cpu_boost"].value, true, "boost read")
	eq(c["power.epp"].value, "balance_performance", "EPP read")
	_free()


func test_claw8ex_writes_through_the_root_verbs_and_reads_back() -> void:
	var e := _setup(Trees.new().claw8ex())
	var reg: Node = e["reg"]
	var root: String = e["root"]
	var failed := []
	reg.control_failed.connect(func(id, v): failed.append([id, v]))
	reg.set_value("power.epp", "power")
	eq(_read(root, "/sys/devices/system/cpu/cpu3/cpufreq/energy_performance_preference"), "power", "EPP on every CPU")
	reg.set_value("power.cpu_boost", false)
	eq(_read(root, "/sys/devices/system/cpu/intel_pstate/no_turbo"), "1", "boost off")
	reg.set_value("power.cpu_max", 10)
	eq(_read(root, "/sys/devices/system/cpu/intel_pstate/max_perf_pct"), "40", "clamped to the device's floor")
	reg.set_value("power.gpu_min", 1000)
	reg.set_value("power.gpu_max", 1800)
	eq([_read(root, "/sys/class/drm/card1/device/tile0/gt0/freq0/min_freq"), _read(root, "/sys/class/drm/card1/device/tile0/gt0/freq0/max_freq")], ["1000", "1800"], "xe window")
	reg.set_value("power.gpu_max", 900)
	eq([_read(root, "/sys/class/drm/card1/device/tile0/gt0/freq0/min_freq"), _read(root, "/sys/class/drm/card1/device/tile0/gt0/freq0/max_freq")], ["900", "900"], "ceiling under the floor brings the floor down first")
	reg.set_value("power.gpu_profile", "power_saving")
	eq(_read(root, "/sys/class/drm/card1/device/tile0/gt0/freq0/power_profile"), "power_saving", "xe power profile")
	reg.set_value("power.sleep_mode", "deep")
	eq(_read(root, "/sys/power/mem_sleep"), "deep", "deep sleep")
	reg.set_value("power.cpu_cores", 2)
	eq(_read(root, "/sys/devices/system/cpu/cpu3/online"), "0", "cores through the helper (PowerStation can't here: no CoresEnabled write)")
	# review S3-2: cores and sleep mode go through the admin helper, the day-to-day ones through the prompt-free one
	var calls: Array = e["runner"].calls
	ok(calls.any(func(x): return str(x).contains("/gamecove-fix power-tune set cores:2")), "cores: gamecove-fix (admin password)")
	ok(calls.any(func(x): return str(x).contains("/gamecove-fix power-tune set sleep:deep")), "sleep: gamecove-fix (admin password)")
	ok(calls.any(func(x): return str(x).contains("/gamecove-fix-set power-tune set epp:")), "EPP: gamecove-fix-set (no password)")
	reg.set_value("power.governor", "performance")
	eq(_read(root, "/sys/devices/system/cpu/cpufreq/policy0/scaling_governor"), "performance", "governor")
	reg.set_value("power.epp", "turbo")
	ok(failed.has(["power.epp", "turbo"]), "a value the CPU doesn't offer fails")
	eq(failed.size(), 1, "nothing else failed: %s" % [failed])
	# restore: GameCove's session runs power-tune set restore at exit
	var r: Dictionary = e["runner"].run("pkexec", PackedStringArray(["/usr/libexec/gamecove/gamecove-fix-set", "power-tune", "set", "restore"]))
	eq(int(r["code"]), 0, "restore ran")
	eq([_read(root, "/sys/devices/system/cpu/cpu3/cpufreq/energy_performance_preference"), _read(root, "/sys/devices/system/cpu/intel_pstate/no_turbo"),
		_read(root, "/sys/class/drm/card1/device/tile0/gt0/freq0/max_freq"), _read(root, "/sys/power/mem_sleep"), _read(root, "/sys/devices/system/cpu/cpu3/online")],
		["balance_performance", "0", "2300", "deep", "0"], "the day-to-day values are back; the two set with the admin password (sleep mode, cores) stay (final review, low)")
	# (`remove` puts those two back as well: fixes/power-tune/test.sh)
	_no_root_writes_outside(e)
	_free()


func test_claw8ex_fan_curve_is_never_quieter_than_quiet() -> void:
	var e := _setup(Trees.new().claw8ex())
	var reg: Node = e["reg"]
	var root: String = e["root"]
	reg.set_value("power.fan_curve", [0, 10, 50, 40, 90, 100])
	var h := "/sys/class/hwmon/hwmon5/"
	var got := []
	for i in 6:
		got.append(_read(root, h + "pwm2_auto_point%d_pwm" % (i + 1)))
	eq(got, ["0", "102", "128", "128", "230", "255"], "lifted to Quiet (40 %) and never falling")
	eq(_read(root, h + "pwm1_enable"), "1", "table mode")
	eq(e["c"]["power.fan_curve"].value, [0.0, 40.0, 50.0, 50.0, 90.0, 100.0], "the control keeps the safe curve it sent, not what was asked")
	eq(e["c"]["power.fan_curve"].coerce([0, 0, 0, 0, 0, 0]), [0.0, 40.0, 40.0, 45.0, 60.0, 100.0], "a profile or import gets the same safe curve")
	eq(e["c"]["power.fan_curve"].coerce([0, 0, 0]), null, "wrong point count refused")
	reg.detect_all()
	eq(e["c"]["power.fan_curve"].value, [0.0, 40.0, 50.0, 50.0, 90.0, 100.0], "read back from the EC table")
	eq(e["c"]["power.fan_mode"].value, "custom", "fan preset reads custom")
	reg.set_value("power.fan_mode", "auto")
	eq(_read(root, h + "pwm1_enable"), "2", "auto hands it back")
	_free()


# ---- the real Claw 8 EX on Bazzite 45 (kernel 7.2.15-ogc1.1, BIOS E1T91IMS.10E), read live ----

## claw8ex() plus what the device showed: steamos-manager answers FanControlState 0 (its
## jupiter-fan-control switch, meaningless here) and MaxChargeLevel 0 (EC limit never set),
## the EC's own fan tables (60-84 %), and GPU performance level auto with a manual clock.
func _claw_live(helper: bool, max_charge := 0) -> Dictionary:
	var trees := Trees.new()
	var t: Dictionary = trees.claw8ex()
	var sm := Trees.SM
	t["props"][sm + "FanControl1 FanControlState"] = Trees.p("u", 0)
	if max_charge >= -1:
		t["props"][sm + "BatteryChargeLimit1 MaxChargeLevel"] = Trees.p("i", max_charge)
	else:   # steamos-manager without the Claw's charge config: a D-Bus error
		t["props"].erase(sm + "BatteryChargeLimit1 MaxChargeLevel")
	t["props"][sm + "BatteryChargeLimit1 SuggestedMinimumLimit"] = Trees.p("i", 10)
	var h := "/sys/class/hwmon/hwmon5/"
	var duty := [153, 163, 173, 188, 204, 214]
	var temp := [47, 50, 57, 64, 71, 78]
	for n in [1, 2]:
		for i in 6:
			trees.w(h + "pwm%d_auto_point%d_pwm" % [n, i + 1], str(duty[i]))
			trees.w(h + "pwm%d_auto_point%d_temp" % [n, i + 1], str(temp[i]))
	trees.w(h + "fan1_input", "2900")
	trees.w(h + "fan2_input", "2900")
	for u in ["ucsi-source-psy-USBC000:001", "ucsi-source-psy-USBC000:002"]:
		trees.w("/sys/class/power_supply/%s/type" % u, "USB")
		trees.w("/sys/class/power_supply/%s/online" % u, "0")
	if not helper:
		DirAccess.remove_absolute(t["root"] + "/usr/libexec/gamecove/gamecove-fix-set")
		DirAccess.remove_absolute(t["root"] + "/usr/libexec/gamecove/gamecove-fix")
	return t


func test_claw_live_fan_tables_win_over_steamos_manager() -> void:
	var e := _setup(_claw_live(true))
	var c: Dictionary = e["c"]
	var root: String = e["root"]
	var h := "/sys/class/hwmon/hwmon5/"
	ok(c["power.fan_curve"].available, "fan curve offered (%s)" % c["power.fan_curve"].reason)
	eq(c["power.fan_mode"].options.map(func(o): return o["value"]), ["quiet", "auto", "max"], "the EC's presets, not steamos-manager's")
	eq(c["power.fan_mode"].value, "auto", "pwm1/2_enable 2 is MSI's automatic control")
	eq(c["power.fan_curve"].value, [60.0, 64.0, 68.0, 74.0, 80.0, 84.0], "the EC's own table, 0-255 shown as percent")
	e["reg"].set_value("power.fan_curve", [50.0, 55.0, 60.0, 70.0, 85.0, 100.0])
	for n in [1, 2]:
		var got := []
		for i in 6:
			got.append(_read(root, h + "pwm%d_auto_point%d_pwm" % [n, i + 1]))
		eq(got, ["128", "140", "153", "179", "217", "255"], "fan %d gets the curve" % n)
		eq(_read(root, h + "pwm%d_enable" % n), "1", "fan %d follows its table" % n)
		eq(_read(root, h + "pwm%d_auto_point1_temp" % n), "47", "temperatures never written")
	ok(not e["runner"].calls.any(func(x): return str(x).contains("FanControlState")), "steamos-manager's fan switch never set")
	_free()


func test_claw_live_charge_limit_through_steamos_manager() -> void:
	var e := _setup(_claw_live(false))
	var c: Dictionary = e["c"]
	ok(c["power.charge_limit"].available, "charge limit without the root helper (%s)" % c["power.charge_limit"].reason)
	eq(c["power.charge_limit"].value, 100.0, "the EC's unset 0 reads as no limit")
	e["reg"].set_value("power.charge_limit", 80)
	eq(c["power.charge_limit"].value, 80.0, "80 read back")
	var sets: Array = e["runner"].calls.filter(func(x): return str(x).contains("set-property") and str(x).contains("MaxChargeLevel"))
	eq(sets.size(), 1, "one prompt-free steamos-manager write: %s" % [sets])
	ok(not e["power"].set_charge_limit(40), "never under 50 % (steamos-manager suggests 10)")
	ok(e["power"].set_charge_limit(100), "no limit")
	ok(e["runner"].calls.any(func(x): return str(x).ends_with("MaxChargeLevel i 100")), "no limit is written as 100, never 0")
	ok(not e["runner"].calls.any(func(x): return str(x).ends_with("MaxChargeLevel i 0")), "0 never written")
	_free()


func test_claw_live_without_the_helper_says_so() -> void:
	var e := _setup(_claw_live(false, -2))
	var c: Dictionary = e["c"]
	for id in ["power.charge_limit", "power.fan_mode", "power.fan_curve", "power.gpu_profile"]:
		eq(c[id].reason, Tx.NO_HELPER, id + ": the hardware has it, only the root helper can write it")
	eq(e["power"].state()["fan_modes"], [], "no steamos-manager fan switch on a Claw")
	_free()


func test_claw_live_gpu_profile_with_the_helper() -> void:
	var e := _setup(_claw_live(true))
	var c: Dictionary = e["c"]
	ok(c["power.gpu_profile"].available, "xe power_profile (%s)" % c["power.gpu_profile"].reason)
	eq(c["power.gpu_profile"].value, "base")
	e["reg"].set_value("power.gpu_profile", "power_saving")
	eq(_read(e["root"], "/sys/class/drm/card1/device/tile0/gt0/freq0/power_profile"), "power_saving")
	_free()


## steamos-manager's Intel GPU driver as it behaves: ManualGpuClock reads min_freq and a
## write in the "auto" level is only remembered (src/gpu.rs set_clocks); "manual" applies it.
class SmIntelGpu extends "res://tests/fixtures/power/fake_runner.gd":
	const K := "--user get-property com.steampowered.SteamOSManager1 /com/steampowered/SteamOSManager1 com.steampowered.SteamOSManager1.GpuPerformanceLevel1 "
	var saved := -1

	func run(program: String, args: PackedStringArray) -> Dictionary:
		var a := Array(args)
		if program == "busctl" and "set-property" in a and "ManualGpuClock" in a:
			calls.append("busctl " + " ".join(PackedStringArray(a.filter(func(x): return not str(x).begins_with("--timeout=")))))
			saved = int(a[-1])
			if str(props[K + "GpuPerformanceLevel"]["data"]) == "manual":
				props[K + "ManualGpuClock"]["data"] = saved
			return {"code": 0, "out": ""}
		var r := super.run(program, args)
		if program == "busctl" and "set-property" in a and "GpuPerformanceLevel" in a and str(a[-1]) == "manual" and saved >= 0:
			props[K + "ManualGpuClock"]["data"] = saved
		return r


func test_claw_live_gpu_clock_switches_to_manual() -> void:
	var t := _claw_live(false)
	var sm := Trees.SM
	t["props"][sm + "GpuPerformanceLevel1 GpuPerformanceLevel"] = Trees.p("s", "auto")
	t["props"][sm + "GpuPerformanceLevel1 AvailableGpuPerformanceLevels"] = Trees.p("as", ["auto", "manual"])
	t["props"][sm + "GpuPerformanceLevel1 ManualGpuClock"] = Trees.p("u", 1000)
	t["props"][sm + "GpuPerformanceLevel1 ManualGpuClockMin"] = Trees.p("u", 1000)
	t["props"][sm + "GpuPerformanceLevel1 ManualGpuClockMax"] = Trees.p("u", 2300)
	var e := _setup(t)
	var r: RefCounted = SmIntelGpu.new()
	r.props = e["runner"].props
	r.methods = e["runner"].methods
	e["power"].be.runner = r
	e["prov"].be.runner = r
	e["prov"].be.user_bus.runner = r
	e["prov"].be.system_bus.runner = r
	var c: Dictionary = e["c"]
	ok(c["power.gpu_clock"].available, "gpu_clock through steamos-manager (%s)" % c["power.gpu_clock"].reason)
	ok(c["power.gpu_clock"].write(1050), "1050 applies")
	eq(c["power.gpu_clock"].read(), 1050.0, "read back")
	eq(str(r.props[sm + "GpuPerformanceLevel1 GpuPerformanceLevel"]["data"]), "manual", "switched to manual first")
	_free()


## PowerStation's CPU object as it behaves: CoreN.Online writes cpuN/online; CoresEnabled
## halves the count when SmtEnabled is false (cpu_features.rs set_cores_enabled).
class PsCores extends "res://tests/fixtures/power/fake_runner.gd":
	var root := ""

	func run(program: String, args: PackedStringArray) -> Dictionary:
		var a := Array(args).filter(func(x): return not str(x).begins_with("--timeout="))
		if program == "busctl" and a.size() >= 8 and a[1] == "set-property" and a[2] == "org.shadowblip.PowerStation":
			calls.append("busctl " + " ".join(PackedStringArray(a)))
			if a[4] == "org.shadowblip.CPU.Core" and a[5] == "Online":
				var n := int(str(a[3]).get_slice("/Core", 1))
				if n != 0:
					var f := FileAccess.open(root + "/sys/devices/system/cpu/cpu%d/online" % n, FileAccess.WRITE)
					f.store_string("1\n" if a[7] == "true" else "0\n")
					f.close()
				return {"code": 0, "out": ""}
			if a[5] == "CoresEnabled":
				var want := mini(int(a[7]), 7)   # SmtEnabled false: half of 14
				for c in range(1, 14):
					var f := FileAccess.open(root + "/sys/devices/system/cpu/cpu%d/online" % c, FileAccess.WRITE)
					f.store_string("1\n" if c < want else "0\n")
					f.close()
				return {"code": 0, "out": ""}
		return super.run(program, args)


func _swap_runner(e: Dictionary, r: RefCounted) -> void:
	r.props = e["runner"].props
	r.methods = e["runner"].methods
	r.exec_handler = e["runner"].exec_handler
	for be in [e["power"].be, e["prov"].be]:
		be.runner = r
		be.user_bus.runner = r
		be.system_bus.runner = r
	e["power"].runner = r
	e["power"].user_bus.runner = r
	e["power"].system_bus.runner = r
	e["runner"] = r


func test_claw_live_cores_exact_count_and_restore() -> void:
	var t := _claw_live(false)
	var trees := Trees.new()
	trees.root = t["root"]
	for i in range(4, 14):
		trees.w(Trees.CPU + "/cpu%d/online" % i, "1")
		trees.w(Trees.CPU + "/cpu%d/cpufreq/energy_performance_preference" % i, "balance_performance")
	t["props"][Trees.PS_CPU + "CoresCount"] = Trees.p("u", 14)
	t["props"][Trees.PS_CPU + "CoresEnabled"] = Trees.p("u", 14)
	t["props"][Trees.PS_CPU + "SmtEnabled"] = Trees.p("b", false)
	t["props"][Trees.PS_CPU + "BoostEnabled"] = Trees.p("b", false)
	var e := _setup(t)
	var r: RefCounted = PsCores.new()
	r.root = t["root"]
	_swap_runner(e, r)
	var c: Dictionary = e["c"]
	e["reg"].detect_all()
	ok(c["power.cpu_cores"].available, "cores (%s)" % c["power.cpu_cores"].reason)
	eq(c["power.cpu_cores"].max_value, 14.0)
	eq(c["power.cpu_cores"].read(), 14.0)
	ok(c["power.cpu_cores"].write(13), "13")
	eq(e["prov"].be.online_cpus(), range(13), "exactly cpus 0-12")
	ok(c["power.cpu_cores"].write(14), "back to 14")
	eq(e["prov"].be.online_cpus(), range(14), "every CPU back")
	ok(c["power.cpu_cores"].write(1), "a floor of 2")
	eq(e["prov"].be.online_cpus(), [0, 1], "never fewer than 2, cpu0 stays")
	ok(not r.calls.any(func(x): return x.contains("CoresEnabled")), "PowerStation's CoresEnabled maths never used")
	ok(not r.calls.any(func(x): return x.contains("/Core0 ")), "cpu0 never touched")
	c["power.cpu_cores"].write(14)
	# a service's boost flag never outranks the kernel's: PowerStation said false with turbo on
	r.props[Trees.SM + "CpuBoost1 CpuBoostState"] = Trees.p("u", 0)
	eq(e["prov"].be.get_boost(), true, "turbo on: intel_pstate/no_turbo 0 is the truth")
	_free()


func test_profile_can_go_back_to_custom() -> void:
	var e := _setup(Trees.new().claw8ex())
	var c: Dictionary = e["c"]
	e["reg"].set_value("power.tdp", 20)
	e["reg"].detect_all()
	eq(c["power.profile"].value, "custom", "20 W is no preset")
	ok("custom" in c["power.profile"].options.map(func(o): return o["value"]), "custom offered")
	ok(c["power.profile"].write("battery"), "battery")
	eq(e["power"].state()["tdp_w"], 12.0)
	ok(c["power.profile"].write("custom"), "custom again (the probe's put-back)")
	eq(c["power.profile"].read(), "custom")
	eq(e["power"].state()["tdp_w"], 20.0, "the user's own 20 W back")
	_free()


# ---- the real ROG Ally (RC71L) on SteamOS 3.10 (kernel 7.2.4-valve1-1-neptune, BIOS RC71L.342) ----

## ally() as the device showed it: steamos-manager only (no PowerStation), MaxChargeLevel -1
## and charge_control_end_threshold 0 (no limit set), FanControl1 answering 0, an empty
## GpuPowerProfile1 list, GpuPerformanceLevel1 auto with ManualGpuClock 800 (800-2700), and
## asus-wmi's own hwmon next to asus_custom_fan_curve.
func _ally_live(helper: bool) -> Dictionary:
	var trees := Trees.new()
	var t: Dictionary = trees.ally()
	for k in t["props"].keys():
		if str(k).begins_with(Trees.PS):
			t["props"].erase(k)
	t["methods"] = {}
	var sm := Trees.SM
	t["props"][sm + "BatteryChargeLimit1 MaxChargeLevel"] = Trees.p("i", -1)
	t["props"][sm + "BatteryChargeLimit1 SuggestedMinimumLimit"] = Trees.p("i", 10)
	t["props"][sm + "FanControl1 FanControlState"] = Trees.p("u", 0)
	t["props"][sm + "GpuPowerProfile1 GpuPowerProfile"] = Trees.p("s", "")
	t["props"][sm + "GpuPowerProfile1 AvailableGpuPowerProfiles"] = Trees.p("as", [])
	t["props"][sm + "GpuPerformanceLevel1 GpuPerformanceLevel"] = Trees.p("s", "auto")
	t["props"][sm + "GpuPerformanceLevel1 AvailableGpuPerformanceLevels"] = Trees.p("as", ["auto", "low", "high", "manual", "profile_peak"])
	t["props"][sm + "GpuPerformanceLevel1 ManualGpuClock"] = Trees.p("u", 800)
	t["props"][sm + "GpuPerformanceLevel1 ManualGpuClockMin"] = Trees.p("u", 800)
	t["props"][sm + "GpuPerformanceLevel1 ManualGpuClockMax"] = Trees.p("u", 2700)
	trees.w("/sys/class/power_supply/BAT1/charge_control_end_threshold", "0")
	trees.w("/sys/class/hwmon/hwmon5/name", "asus")
	trees.w("/sys/class/hwmon/hwmon5/pwm1_enable", "2")
	trees.w("/sys/class/hwmon/hwmon5/pwm2_enable", "2")
	if not helper:
		DirAccess.remove_absolute(t["root"] + "/usr/libexec/gamecove/gamecove-fix-set")
		DirAccess.remove_absolute(t["root"] + "/usr/libexec/gamecove/gamecove-fix")
	return t


func test_ally_live_charge_fan_and_gpu_profile() -> void:
	var e := _setup(_ally_live(true))
	var c: Dictionary = e["c"]
	ok(c["power.charge_limit"].available, "charge limit through steamos-manager (%s)" % c["power.charge_limit"].reason)
	eq(c["power.charge_limit"].value, 100.0, "MaxChargeLevel -1 = no limit set")
	e["reg"].set_value("power.charge_limit", 80)
	eq(c["power.charge_limit"].value, 80.0)
	ok(not e["runner"].calls.any(func(x): return str(x).contains("charge-limit")), "no root helper for it")
	ok(c["power.fan_curve"].available, "asus curve (%s)" % c["power.fan_curve"].reason)
	eq(c["power.fan_curve"].points, 8)
	eq(c["power.fan_mode"].options.map(func(o): return o["value"]), ["quiet", "auto", "max"], "the fan fix, not steamos-manager's switch")
	eq(c["power.gpu_profile"].reason, Tx.SM_NO_GPU_PROFILES, "an empty list is steamos-manager's answer, not a missing GPU")
	_free()


## Round 2: on the Ally steamos-manager's GPU profile property didn't answer (no driver
## configured); it still runs (GPU level works), so the reason names it, not a missing GPU.
func test_ally_live_gpu_profile_reason_when_steamos_manager_errors() -> void:
	var t := _ally_live(true)
	t["props"].erase(Trees.SM + "GpuPowerProfile1 GpuPowerProfile")
	t["props"].erase(Trees.SM + "GpuPowerProfile1 AvailableGpuPowerProfiles")
	var e := _setup(t)
	eq(e["c"]["power.gpu_profile"].reason, Tx.SM_NO_GPU_PROFILES)
	_free()


## Round 2: battery care agreed with no one; it is now an 80 % limit through the same
## backend as power.charge_limit (steamos-manager on the Ally).
func test_ally_live_long_life_is_an_80_percent_limit() -> void:
	var e := _setup(_ally_live(false))
	var c: Dictionary = e["c"]
	ok(c["power.battery_long_life"].available, "battery care (%s)" % c["power.battery_long_life"].reason)
	eq(c["power.battery_long_life"].value, false, "no limit set")
	e["reg"].set_value("power.battery_long_life", true)
	e["reg"].detect_all()
	eq(c["power.charge_limit"].value, 80.0, "an 80 % limit")
	eq(c["power.battery_long_life"].value, true)
	e["reg"].set_value("power.battery_long_life", false)
	e["reg"].detect_all()
	eq(c["power.charge_limit"].value, 100.0, "off: charges to full")
	_free()


func test_ally_live_without_the_helper() -> void:
	var e := _setup(_ally_live(false))
	var c: Dictionary = e["c"]
	ok(c["power.charge_limit"].available, "steamos-manager needs no helper")
	eq(c["power.fan_curve"].reason, Tx.NO_HELPER)
	eq(c["power.fan_mode"].reason, Tx.NO_HELPER)
	_free()


## Battery saver off puts back the exact profile, watts and firmware limits (the Ally's
## PPTs stayed at 10/15/15 W after a probe).
func test_ally_battery_saver_puts_custom_watts_and_ppts_back() -> void:
	var e := _setup(_ally_live(true), true)
	var reg: Node = e["reg"]
	var c: Dictionary = e["c"]
	var a := "/sys/class/firmware-attributes/asus-armoury/attributes/"
	var spl := FileAccess.open(e["root"] + a + "ppt_pl1_spl/current_value", FileAccess.WRITE)
	spl.store_string("30\n")
	spl.close()
	for f in ["ppt_pl2_sppt", "ppt_pl3_fppt"]:
		var mx := FileAccess.open(e["root"] + a + f + "/max_value", FileAccess.WRITE)
		mx.store_string("35\n")
		mx.close()
	reg.set_value("power.tdp", 30)
	reg.detect_all()
	reg.set_value("power.sppt", 30)
	reg.set_value("power.fppt", 30)
	eq(e["power"].state()["profile"], "custom", "30 W on the charger is custom")
	eq([_read(e["root"], a + "ppt_pl2_sppt/current_value"), _read(e["root"], a + "ppt_pl3_fppt/current_value")], ["30", "30"])
	reg.set_value("power.battery_saver", true)
	eq(e["power"].state()["profile"], "battery")
	# the firmware lowers the boost limits with the SPL (what the Ally did)
	for f in ["ppt_pl2_sppt", "ppt_pl3_fppt"]:
		var w := FileAccess.open(e["root"] + a + f + "/current_value", FileAccess.WRITE)
		w.store_string("15\n")
		w.close()
	reg.set_value("power.battery_saver", false)
	eq(e["power"].state()["tdp_w"], 30.0, "30 W back")
	eq(e["power"].state()["profile"], "custom", "custom back")
	eq([_read(e["root"], a + "ppt_pl2_sppt/current_value"), _read(e["root"], a + "ppt_pl3_fppt/current_value")], ["30", "30"], "PPTs back")
	_free()


## Round 2 (Ally, steamos-manager's amdgpu level auto, ManualGpuClock 800): the probe's
## put-back is clock first (switching to manual), then the level back to auto; afterwards
## the control reads 800 again and the level is auto.
func test_ally_live_gpu_clock_put_back_order() -> void:
	var e := _setup(_ally_live(true))
	var r: RefCounted = SmIntelGpu.new()
	_swap_runner(e, r)
	var c: Dictionary = e["c"]
	var sm := Trees.SM + "GpuPerformanceLevel1 "
	# the helper's amdgpu min/max own the clocks here: use steamos-manager's path directly
	var be: RefCounted = e["prov"].be
	ok(be.set_sm_manual_clock(850), "probe 850 (switches to manual)")
	eq(str(r.props[sm + "GpuPerformanceLevel"]["data"]), "manual")
	ok(be.set_sm_manual_clock(800), "put-back 800 while manual")
	ok(be.set_gpu_level("auto"), "then the level back to auto")
	eq(int(be.sm_manual_clock()["value"]), 800, "800 again")
	eq(str(r.props[sm + "GpuPerformanceLevel"]["data"]), "auto", "auto again")
	ok(c.has("power.gpu_clock"), "")
	_free()


## steamos-manager's Intel driver on xe as it behaves (src/gpu.rs): "manual" writes
## min_freq = max_freq = the clock, "auto" writes RPe..RPa, ManualGpuClock reads min_freq; a
## clock set in auto is only remembered. PowerStation's card keeps ManualClock and clock values.
class SmXe extends "res://tests/fixtures/power/fake_runner.gd":
	const K := "--user get-property com.steampowered.SteamOSManager1 /com/steampowered/SteamOSManager1 com.steampowered.SteamOSManager1.GpuPerformanceLevel1 "
	var freq := ""
	var saved := -1

	func _w(f: String, v: int) -> void:
		var h := FileAccess.open(freq + f, FileAccess.WRITE)
		h.store_string(str(v) + "\n")
		h.close()

	func _r(f: String) -> int:
		return FileAccess.get_file_as_string(freq + f).strip_edges().to_int()

	func run(program: String, args: PackedStringArray) -> Dictionary:
		var a := Array(args).filter(func(x): return not str(x).begins_with("--timeout=") and x != "--json=short")
		if program == "busctl" and a.size() >= 6 and str(a[4]).ends_with("GpuPerformanceLevel1"):
			if a[1] == "get-property" and a[5] == "ManualGpuClock":
				calls.append("busctl " + " ".join(PackedStringArray(a)))
				return {"code": 0, "out": JSON.stringify({"type": "u", "data": _r("min_freq")})}
			if a[1] == "set-property" and a[5] == "ManualGpuClock":
				calls.append("busctl " + " ".join(PackedStringArray(a)))
				saved = int(a[7])
				if str(props[K + "GpuPerformanceLevel"]["data"]) == "manual":
					_w("max_freq", saved)
					_w("min_freq", saved)
				return {"code": 0, "out": ""}
			if a[1] == "set-property" and a[5] == "GpuPerformanceLevel":
				var r := super.run(program, args)
				if a[7] == "manual":
					var f := saved if saved > 0 else int((_r("rpe_freq") + _r("rpa_freq")) / 2)
					_w("max_freq", f)
					_w("min_freq", f)
				else:
					_w("min_freq", _r("rpe_freq"))
					_w("max_freq", _r("rpa_freq"))
				return r
		return super.run(program, args)


## The Claw's xe GPU as found in round 3: level auto, min_freq 900 / max 2300 (RPe 850),
## PowerStation card1 ManualClock false with clock values 900/2300.
func _claw_gpu_raw() -> Dictionary:
	var t := Trees.new()
	var tree: Dictionary = t.claw8ex()
	var g := "/sys/class/drm/card1/device/tile0/gt0/freq0/"
	for kv in [["min_freq", "900"], ["max_freq", "2300"], ["rpe_freq", "850"], ["rpa_freq", "2300"]]:
		t.w(g + kv[0], kv[1])
	var sm := Trees.SM + "GpuPerformanceLevel1 "
	tree["props"][sm + "GpuPerformanceLevel"] = Trees.p("s", "auto")
	tree["props"][sm + "AvailableGpuPerformanceLevels"] = Trees.p("as", ["auto", "manual"])
	tree["props"][sm + "ManualGpuClockMin"] = Trees.p("u", 100)
	tree["props"][sm + "ManualGpuClockMax"] = Trees.p("u", 2300)
	var card := Trees.PS + "/org/shadowblip/Performance/GPU/card1 org.shadowblip.GPU.Card "
	tree["props"][card + "ManualClock"] = Trees.p("b", false)
	tree["props"][card + "ClockValueMhzMin"] = Trees.p("d", 900.0)
	tree["props"][card + "ClockValueMhzMax"] = Trees.p("d", 2300.0)
	var e := _setup(tree)
	var r: RefCounted = SmXe.new()
	r.freq = tree["root"] + g
	_swap_runner(e, r)
	return e


## Round 3: gpu_clock 900 -> 950 -> put back left min_freq 850 and ManualClock on. The probe's
## raw snapshot puts the level, xe min/max_freq and PowerStation's state back exactly.
func test_claw_gpu_probe_restores_the_raw_state() -> void:
	var e := _claw_gpu_raw()
	var be: RefCounted = e["prov"].be
	var root: String = e["root"]
	var g := "/sys/class/drm/card1/device/tile0/gt0/freq0/"
	var card := Trees.PS + "/org/shadowblip/Performance/GPU/card1 org.shadowblip.GPU.Card "
	var snap: Dictionary = e["prov"].probe_snapshot()
	eq(snap["gpu"]["xe"], [900, 2300], "captured")
	ok(be.set_sm_manual_clock(950), "probe 950")
	eq(_read(root, g + "min_freq"), "950")
	e["runner"].props[card + "ManualClock"]["data"] = true   # something switched PowerStation's manual on
	ok(be.set_sm_manual_clock(900), "put back 900")
	e["runner"].props[Trees.SM + "GpuPerformanceLevel1 GpuPerformanceLevel"]["data"] = "manual"
	ok(e["prov"].probe_restore(snap), "raw restore")
	eq(str(e["runner"].props[Trees.SM + "GpuPerformanceLevel1 GpuPerformanceLevel"]["data"]), "auto", "level auto")
	eq([_read(root, g + "min_freq"), _read(root, g + "max_freq")], ["900", "2300"], "min/max exactly as found")
	eq(e["runner"].props[card + "ManualClock"]["data"], false, "PowerStation ManualClock off again")
	_free()


## Going back to level auto by itself restores the pre-manual window and ManualClock.
func test_claw_gpu_auto_returns_the_pre_manual_window() -> void:
	var e := _claw_gpu_raw()
	var be: RefCounted = e["prov"].be
	var root: String = e["root"]
	var g := "/sys/class/drm/card1/device/tile0/gt0/freq0/"
	var card := Trees.PS + "/org/shadowblip/Performance/GPU/card1 org.shadowblip.GPU.Card "
	ok(be.set_sm_manual_clock(950), "manual 950")
	e["runner"].props[card + "ManualClock"]["data"] = true
	ok(be.set_gpu_level("auto"), "auto")
	eq([_read(root, g + "min_freq"), _read(root, g + "max_freq")], ["900", "2300"], "900/2300, not steamos-manager's 850")
	eq(e["runner"].props[card + "ManualClock"]["data"], false, "ManualClock off")
	_free()


func test_claw8ex_boost_and_thermald_hold_with_the_guard() -> void:
	var t := Trees.new().claw8ex()
	var f := FileAccess.open(t["root"] + "/thermald.state", FileAccess.WRITE)
	f.store_string("active")
	f.close()
	var e := _setup(t)
	var power: Node = e["power"]
	e["reg"].set_value("power.tdp", 17)
	eq(_read(e["root"], "/thermald.state"), "inactive", "thermald held after the first TDP write (ClawDeck §21)")
	ok(DirAccess.dir_exists_absolute(e["root"] + "/var/lib/gamecove/fixes/power-tune") and FileAccess.file_exists(e["root"] + "/var/lib/gamecove/fixes/power-tune/thermald-held"), "recorded for the session's restore")
	e["reg"].set_value("power.boost", 20)
	var key := Trees.PS + "/org/shadowblip/Performance/GPU/card1 org.shadowblip.GPU.Card.TDP Boost"
	eq(float(e["runner"].props[key]["data"]), 10.0, "boost clamped to boost_max - TDP")
	e["reg"].set_value("power.tdp", 20)
	eq(float(e["runner"].props[key]["data"]), 10.0, "the user's boost stays across TDP writes")
	# guard: hot package steps 2 W, never below the floor
	var tf := FileAccess.open(e["root"] + "/sys/class/thermal/thermal_zone3/temp", FileAccess.WRITE)
	tf.store_string("97000")
	tf.close()
	eq(power.guard_check(), 18, "over 95 C: -2 W")
	eq(power.state()["tdp_w"], 18.0, "applied")
	var r: Dictionary = e["runner"].run("pkexec", PackedStringArray(["/usr/libexec/gamecove/gamecove-fix-set", "power-tune", "set", "restore"]))
	ok(int(r["code"]) == 0 and _read(e["root"], "/thermald.state") == "active", "restore starts thermald again")
	_free()


# ---- Intel i915: MSI Claw A1M -------------------------------------------------------------------

func test_a1m_gpu_clocks_and_smt_through_powerstation() -> void:
	var e := _setup(Trees.new().a1m())
	_every_reason_set(e, "a1m")
	var c: Dictionary = e["c"]
	ok(c["power.smt"].available and c["power.gpu_min"].available, "SMT and GPU clocks")
	e["reg"].set_value("power.gpu_max", 1500)
	var card := Trees.PS + "/org/shadowblip/Performance/GPU/card0 org.shadowblip.GPU.Card "
	eq(float(e["runner"].props[card + "ClockValueMhzMax"]["data"]), 1500.0, "PowerStation clock (prompt-free)")
	eq(e["runner"].props[card + "ManualClock"]["data"], true, "manual clocks switched on first")
	ok(not e["runner"].calls.any(func(x): return x.contains("gpumax")), "no root helper for i915 clocks")
	e["runner"].props[Trees.PS_CPU + "SmtEnabled"]["data"] = true
	var smt_calls := []
	e["reg"].set_value("power.smt", false)
	for x in e["runner"].calls:
		if x.contains("SmtEnabled"):
			smt_calls.append(x)
	ok(smt_calls.any(func(x): return x.contains("set-property")), "SMT through PowerStation")
	_free()


# ---- AMD: ROG Ally ------------------------------------------------------------------------------

func test_ally_offers_what_this_handheld_has() -> void:
	var e := _setup(Trees.new().ally())
	_every_reason_set(e, "ally")
	var c: Dictionary = e["c"]
	for id in ["power.tdp", "power.sppt", "power.fppt", "power.power_mode", "power.cpu_boost", "power.smt", "power.cpu_cores",
			"power.epp", "power.gpu_level", "power.gpu_min", "power.gpu_max", "power.thermal_limit", "power.charge_limit",
			"power.fan_mode", "power.fan_curve", "power.mcu_powersave"]:
		ok(c[id].available, "ally offers %s (%s)" % [id, c[id].reason])
	eq(c["power.platform_profile"].reason, Tx.PPD_OWNS, "PPD owns the firmware mode")
	eq(c["power.gpu_profile"].reason, Tx.SM_NO_GPU_PROFILES, "no xe; steamos-manager runs but has none")
	eq(c["power.sleep_mode"].reason, Tx.NOT_HERE, "no mem_sleep file")
	# hhd's ASUS rule at SPL 15 W: SPPT <= min(35, 15 x 1.2) = 18, FPPT <= min(35, 15 x 1.4) = 21
	eq([c["power.sppt"].min_value, c["power.sppt"].max_value], [15.0, 18.0], "SPPT: not under SPL, hhd's ASUS ceiling")
	eq([c["power.fppt"].min_value, c["power.fppt"].max_value], [20.0, 21.0], "FPPT: not under SPPT, hhd's ASUS ceiling")
	eq(c["power.thermal_limit"].max_value, 95.0, "never above the firmware's Tctl")
	eq(c["power.fan_curve"].points, 8, "asus curve points")
	_free()


func test_ally_mcu_powersave_needs_new_enough_firmware() -> void:
	# review S1-3: never offered with an old (or unreadable) controller MCU firmware
	var t := Trees.new().ally()
	var mcu: String = t["root"] + "/sys/class/firmware-attributes/asus-armoury/attributes/mcu_powersave/current_value"
	var f := FileAccess.open(mcu, FileAccess.WRITE)
	f.store_string("0\n")
	f.close()
	DirAccess.make_dir_recursive_absolute(str(t["root"]) + "/var/lib/gamecove")
	f = FileAccess.open(t["root"] + "/var/lib/gamecove/ally-mcu-version", FileAccess.WRITE)
	f.store_string("model=ally\nversion=318\nmin=319\n")
	f.close()
	var e := _setup(t)
	var c: Dictionary = e["c"]
	ok(not c["power.mcu_powersave"].available, "old firmware: not available")
	ok(c["power.mcu_powersave"].reason.contains("318") and c["power.mcu_powersave"].reason.contains("319"), "reason names both versions")
	_free()
	f = FileAccess.open(t["root"] + "/var/lib/gamecove/ally-mcu-version", FileAccess.WRITE)
	f.store_string("error=couldn't ask the MCU\n")
	f.close()
	e = _setup(t)
	ok(not e["c"]["power.mcu_powersave"].available, "unreadable version: not available")
	_free()
	f = FileAccess.open(t["root"] + "/var/lib/gamecove/ally-mcu-version", FileAccess.WRITE)
	f.store_string("model=ally\nversion=319\nmin=319\n")
	f.close()
	e = _setup(t)
	ok(e["c"]["power.mcu_powersave"].available, "319: available")
	_free()


func test_admin_only_levers_say_so_in_gaming_mode() -> void:
	# review S3-2: SMT, cores, sleep mode and MCU power saving need the admin password; Gaming Mode can't ask
	var t := Trees.new().claw8ex()
	Trees.make_bin()
	var runner: RefCounted = Trees.runner(t)
	var reg: Node = ControlsScript.new()
	reg.sync_mode = true
	var ctx := {"sys_root": t["root"], "runner": runner, "home": t["root"], "device": t["row"], "registry": reg, "password_prompt": false}
	reg.setup(ctx)
	var prov: RefCounted = ProviderScript.new()
	prov.cfg_path = t["root"] + "/power_controls.cfg"
	prov.setup(ctx)
	reg.register_provider(prov)
	reg.detect_all()
	_nodes.append(reg)
	var c: Object = reg.control("power.sleep_mode")
	ok(not c.available and c.reason == Tx.NEEDS_ADMIN, "sleep mode: admin password, Desktop Mode (%s)" % c.reason)
	c = reg.control("power.cpu_cores")
	ok(not c.available and c.reason == Tx.NEEDS_ADMIN, "cores through sysfs: admin password (%s)" % c.reason)
	ok(reg.control("power.epp").available, "EPP stays prompt-free")
	_free()


func test_ally_writes_each_backend() -> void:
	var e := _setup(Trees.new().ally())
	var reg: Node = e["reg"]
	var root: String = e["root"]
	reg.set_value("power.sppt", 28)
	eq(_read(root, "/sys/class/firmware-attributes/asus-armoury/attributes/ppt_pl2_sppt/current_value"), "18", "SPPT clamped to 1.2 x SPL")
	reg.set_value("power.fppt", 50)
	eq(_read(root, "/sys/class/firmware-attributes/asus-armoury/attributes/ppt_pl3_fppt/current_value"), "21", "FPPT clamped to 1.4 x SPL")
	# SPL raised since detect (the TDP moved): the ceiling follows it at write time
	var spl := FileAccess.open(root + "/sys/class/firmware-attributes/asus-armoury/attributes/ppt_pl1_spl/current_value", FileAccess.WRITE)
	spl.store_string("25\n")
	spl.close()
	ok(e["prov"].ppt_ceiling("sppt", 25.0) == 30.0 and e["prov"].ppt_ceiling("fppt", 25.0) == 35.0, "25 W: SPPT 30, FPPT 35 (hhd)")
	ok(e["prov"].ppt_ceiling("fppt", 30.0) == 35.0, "never past 35 W on the Ally")
	reg.set_value("power.cpu_boost", false)
	var cpb_key := Trees.PS_CPU + "BoostEnabled"
	ok(e["runner"].calls.any(func(x): return x.contains("set-property") and x.contains("BoostEnabled")) or _read(root, "/sys/devices/system/cpu/cpufreq/policy0/boost") == "0", "CPU boost off (PowerStation or per-policy)")
	reg.set_value("power.power_mode", "power-saver")
	eq(str(e["runner"].props[Trees.PPD + "ActiveProfile"]["data"]), "power-saver", "PPD")
	reg.set_value("power.gpu_level", "high")
	eq(_read(root, "/sys/class/drm/card0/device/power_dpm_force_performance_level"), "high", "amdgpu level via helper")
	reg.set_value("power.thermal_limit", 110)
	var tkey := Trees.PS + "/org/shadowblip/Performance/GPU/card0 org.shadowblip.GPU.Card.TDP ThermalThrottleLimitC"
	eq(float(e["runner"].props[tkey]["data"]), 95.0, "Tctl never above the firmware's")
	reg.set_value("power.thermal_limit", 80)
	eq(float(e["runner"].props[tkey]["data"]), 80.0, "Tctl lowered")
	reg.set_value("power.mcu_powersave", false)
	eq(_read(root, "/sys/class/firmware-attributes/asus-armoury/attributes/mcu_powersave/current_value"), "0", "MCU power saving off")
	var pr: RefCounted = PsCores.new()
	pr.root = root
	_swap_runner(e, pr)
	reg.set_value("power.cpu_cores", 1)
	eq(e["prov"].be.online_cpus(), [0, 1], "never fewer than 2 cores, through PowerStation's per-core Online")
	reg.set_value("power.fan_curve", [0, 0, 0, 0, 0, 0, 0, 0])
	eq(_read(root, "/sys/class/hwmon/hwmon6/pwm1_auto_point8_pwm"), "255", "a silent curve becomes Quiet (full speed at the hottest point, review L6)")
	ok(not cpb_key.is_empty(), "")
	_free()


func test_ally_thermal_ceiling_stays_after_a_lower_limit() -> void:
	var t := Trees.new().ally()
	var e := _setup(t)
	e["reg"].set_value("power.thermal_limit", 80)
	_free()
	var runner_props: Dictionary = t["props"]
	runner_props[Trees.PS + "/org/shadowblip/Performance/GPU/card0 org.shadowblip.GPU.Card.TDP ThermalThrottleLimitC"] = Trees.p("d", 80.0)
	var e2 := _setup(t)
	eq(e2["c"]["power.thermal_limit"].max_value, 95.0, "the first-seen firmware limit is kept per handheld")
	_free()


# ---- Bazzite: steamos-manager and tuned-ppd both run ---------------------------------------------

## Bazzite 44 runs steamos-manager (PerformanceProfile1) and tuned-ppd, whose profiles set the same
## firmware platform profile (tuned's acpi plugin). One owner per setting (docs/CONTROLS.md
## "Integration rules"): Power mode; the platform profile greys out whichever path it would use,
## or a profile applying both (power_mode 90, then platform 89) fights itself. Found by the
## end-to-end suite on the Claw 8 EX / Legion Go S Bazzite setups.
func test_power_mode_owns_the_firmware_mode_with_steamos_manager() -> void:
	var t: Dictionary = Trees.new().deck()
	t["props"][Trees.PPD + "ActiveProfile"] = {"type": "s", "data": "balanced"}
	t["props"][Trees.PPD + "Profiles"] = {"type": "aa{sv}", "data": [{"Profile": {"type": "s", "data": "power-saver"}},
		{"Profile": {"type": "s", "data": "balanced"}}, {"Profile": {"type": "s", "data": "performance"}}]}
	var e := _setup(t)
	var c: Dictionary = e["c"]
	ok(c["power.power_mode"].available, "Power mode through tuned-ppd")
	eq(c["power.platform_profile"].reason, Tx.PPD_OWNS, "the platform profile is Power mode's, even through steamos-manager")
	ok(not e["reg"].control("power.platform_profile").write("low-power"), "and can't be written behind its back")
	_free()


# ---- Steam Deck: steamos-manager only -----------------------------------------------------------

func test_deck_uses_steamos_manager_and_no_helper() -> void:
	var e := _setup(Trees.new().deck())
	_every_reason_set(e, "deck")
	var c: Dictionary = e["c"]
	for id in ["power.tdp", "power.cpu_boost", "power.governor", "power.gpu_level", "power.gpu_clock", "power.gpu_profile",
			"power.platform_profile", "power.charge_limit", "power.fan_mode"]:
		ok(c[id].available, "deck offers %s (%s)" % [id, c[id].reason])
	for id in ["power.epp", "power.cpu_max", "power.sppt"]:
		ok(not c[id].available, "deck: %s needs the helper or isn't there" % id)
	eq(c["power.epp"].reason, Tx.NO_HELPER, "plain reason: install the system part")
	e["reg"].set_value("power.gpu_level", "manual")
	e["reg"].set_value("power.gpu_clock", 1700)
	eq(int(e["runner"].props[Trees.SM + "GpuPerformanceLevel1 ManualGpuClock"]["data"]), 1600, "clamped to ManualGpuClockMax")
	e["reg"].set_value("power.cpu_boost", false)
	eq(int(e["runner"].props[Trees.SM + "CpuBoost1 CpuBoostState"]["data"]), 0, "CpuBoost1")
	e["reg"].set_value("power.platform_profile", "low-power")
	eq(str(e["runner"].props[Trees.SM + "PerformanceProfile1 PerformanceProfile"]["data"]), "low-power", "PerformanceProfile1")
	ok(not e["runner"].calls.any(func(x): return x.begins_with("pkexec")), "nothing needed root")
	_free()


func test_deck_refused_service_write_fails_and_keeps_the_value() -> void:
	var e := _setup(Trees.new().deck())
	e["runner"].frozen.append(Trees.SM + "CpuScaling1 CpuScalingGovernor")
	var failed := []
	e["reg"].control_failed.connect(func(id, _v): failed.append(id))
	e["reg"].set_value("power.governor", "performance")
	eq(failed, ["power.governor"], "read-back differs: failed")
	eq(e["c"]["power.governor"].value, "schedutil", "value unchanged")
	_free()


# ---- Lenovo: Legion Go S ------------------------------------------------------------------------

func test_legion_ppt_in_custom_mode_and_battery_care() -> void:
	var e := _setup(Trees.new().legion())
	var c: Dictionary = e["c"]
	ok(c["power.sppt"].available and c["power.battery_long_life"].available, "offered")
	# hhd's Legion Go S rule at SPL 15 W: SPPT <= SPL + 3 = 18 (under the firmware's 35 W)
	eq(c["power.sppt"].max_value, 18.0, "SPPT ceiling SPL + 3 (hhd gos)")
	# FPPT <= min(41, 15 x 53/40) = 19, under the firmware's current SPPT of 20: nothing safe to offer yet
	ok(not c["power.fppt"].available, "FPPT waits until SPPT is inside the safe range")
	e["reg"].set_value("power.sppt", 25)
	eq([_read(e["root"], "/sys/class/firmware-attributes/lenovo-wmi-other-0/attributes/ppt_pl2_sppt/current_value"), _read(e["root"], "/sys/firmware/acpi/platform_profile")],
		["18", "custom"], "custom mode first (SimpleDeckyTDP lenovo.py), clamped to the safe ceiling")
	e["reg"].detect_all()
	ok(c["power.fppt"].available and c["power.fppt"].min_value == 18.0 and c["power.fppt"].max_value == 19.0, "then FPPT 18..19 W")
	e["reg"].set_value("power.battery_long_life", true)
	eq(_read(e["root"], "/sys/class/power_supply/BAT1/charge_types"), "Long_Life", "Long Life")
	_free()


func test_hhd_owns_fan_charge_and_ppt() -> void:
	var e := _setup(Trees.new().legion())
	e["power"].backend = "hhd"
	e["reg"].detect_all()
	for id in ["power.sppt", "power.charge_limit", "power.fan_mode", "power.fan_curve"]:
		var c = e["c"][id]
		ok(not c.available, "%s off under hhd" % id)
	eq(e["c"]["power.sppt"].reason, Tx.HHD_OWNS, "says why")
	_free()


# ---- nothing at all -----------------------------------------------------------------------------

func test_bare_system_offers_nothing_and_says_why() -> void:
	var e := _setup(Trees.new().bare())
	_every_reason_set(e, "bare")
	var avail := _avail(e)
	ok(avail.all(func(id): return id in ["power.battery_saver"]) or avail.is_empty(), "nothing usable: %s" % [avail])
	eq(e["c"]["power.tdp"].reason, Tx.NO_TDP, "no TDP service")
	var before: int = e["runner"].calls.size()
	for id in e["c"]:
		e["reg"].set_value(id, e["c"][id].default_value if e["c"][id].default_value != null else 1)
	ok(not e["runner"].calls.slice(before).any(func(x): return x.begins_with("pkexec") or x.contains("set-property")), "no writes attempted")
	_free()


# ---- battery saver, resume, memory, power source ------------------------------------------------

func test_battery_saver_applies_the_lowest_and_puts_back() -> void:
	var e := _setup(Trees.new().claw8ex())
	var reg: Node = e["reg"]
	reg.set_value("power.tdp", 25)
	reg.set_value("power.epp", "balance_performance")
	reg.set_value("power.battery_saver", true)
	var st: Dictionary = e["power"].state()
	eq(st["profile"], "battery", "battery profile")
	eq(_read(e["root"], "/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference"), "power", "EPP power")
	eq(_read(e["root"], "/sys/devices/system/cpu/intel_pstate/no_turbo"), "1", "boost off")
	eq(_read(e["root"], "/sys/class/drm/card1/device/tile0/gt0/freq0/power_profile"), "power_saving", "GPU efficiency")
	reg.set_value("power.battery_saver", false)
	eq(e["power"].state()["tdp_w"], 25.0, "TDP back")
	eq(_read(e["root"], "/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference"), "balance_performance", "EPP back")
	eq(_read(e["root"], "/sys/devices/system/cpu/intel_pstate/no_turbo"), "0", "boost back")
	_free()


## Battery saver lived only in memory: after GameCove started again it read
## Off while the handheld still had the saver's TDP, EPP and boost, and the
## values from before it were gone, so nothing could put them back. It's
## remembered per handheld now, with what it replaced. Found by the
## end-to-end suite (a fresh read of the system disagreed).
func test_battery_saver_survives_a_restart_and_still_puts_back() -> void:
	var t: Dictionary = Trees.new().claw8ex()
	var e := _setup(t)
	e["reg"].set_value("power.tdp", 25)
	e["reg"].set_value("power.epp", "balance_performance")
	e["reg"].set_value("power.battery_saver", true)
	eq(_read(e["root"], "/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference"), "power", "saver on: EPP power")
	# GameCove quits and starts again: the hardware keeps what the saver set
	t["props"] = e["runner"].props.duplicate(true)
	var e2 := _setup(t)
	eq(e2["c"]["power.battery_saver"].value, true, "still on after a restart")
	e2["reg"].set_value("power.battery_saver", false)
	eq(e2["power"].state()["tdp_w"], 25.0, "off puts the TDP from before it back")
	eq(_read(e2["root"], "/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference"), "balance_performance", "and the EPP")
	eq(_read(e2["root"], "/sys/devices/system/cpu/intel_pstate/no_turbo"), "0", "and boost")
	var e3 := _setup(t)
	eq(e3["c"]["power.battery_saver"].value, false, "off is remembered too")
	# on again, restart, and Profiles applies the everyday TDP right after the first
	# detection: the saver's values are put back on top (queued after Profiles')
	e3["reg"].set_value("power.battery_saver", true)
	t["props"] = e3["runner"].props.duplicate(true)
	var e4 := _setup(t)
	e4["reg"].apply({"power.tdp": 25})
	e4["prov"]._reassert_saver()
	eq(e4["power"].state()["profile"], "battery", "the saver wins over the everyday profile after a restart")
	_free()


func test_battery_saver_turns_on_at_the_level_and_off_on_the_charger() -> void:
	var e := _setup(Trees.new().claw8ex())
	e["reg"].set_value("power.battery_saver_at", 20)
	e["prov"]._wrote("power.battery_saver_at", 20)
	e["power"].battery_level.emit(25, false)
	ok(e["c"]["power.battery_saver"].value != true, "above the level: off")
	e["power"].battery_level.emit(20, false)
	eq(e["c"]["power.battery_saver"].value, true, "at the level: on")
	e["power"].source_changed.emit(true)
	eq(e["c"]["power.battery_saver"].value, false, "plugged in: off again")
	_free()


func test_resume_puts_back_what_the_firmware_reset() -> void:
	var e := _setup(Trees.new().claw8ex())
	e["reg"].set_value("power.epp", "balance_power")
	var f := FileAccess.open(e["root"] + "/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference", FileAccess.WRITE)
	f.store_string("performance\n")
	f.close()
	# no detect in between: the control still holds balance_power, the hardware doesn't
	e["power"].resumed.emit()
	eq(_read(e["root"], "/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference"), "balance_power", "re-applied after sleep")
	_free()


func test_power_refresh_after_resume_rewrites_a_reset_tdp() -> void:
	var e := _setup(Trees.new().claw8ex())
	var power: Node = e["power"]
	e["reg"].set_value("power.tdp", 15)
	var key := Trees.PS + "/org/shadowblip/Performance/GPU/card1 org.shadowblip.GPU.Card.TDP TDP"
	e["runner"].props[key]["data"] = 30.0  # the firmware came back at its own limit
	var resumed := [false]
	power.resumed.connect(func(): resumed[0] = true)
	power.refresh()
	ok(not resumed[0], "a plain refresh (after a control's own write) doesn't claim a resume")
	power.refresh(true)
	eq(float(e["runner"].props[key]["data"]), 15.0, "our TDP back (SimpleDeckyTDP / PowerTools resume)")
	ok(resumed[0], "resumed emitted")
	_free()


func test_device_settings_come_back_at_start_per_handheld() -> void:
	var t := Trees.new().claw8ex()
	var e := _setup(t)
	e["reg"].set_value("power.sleep_mode", "deep")
	_free()
	var f := FileAccess.open(t["root"] + "/sys/power/mem_sleep", FileAccess.WRITE)
	f.store_string("[s2idle] deep\n")
	f.close()
	var e2 := _setup(t)
	e2["reg"].detected.emit()
	eq(_read(t["root"], "/sys/power/mem_sleep"), "deep", "put back at start")
	var cfg := ConfigFile.new()
	cfg.load(t["root"] + "/power_controls.cfg")
	eq(cfg.get_value("set@msi-claw-8-ex", "power.sleep_mode", ""), "deep", "kept under this handheld's id")
	_free()


func test_tdp_range_follows_the_power_source() -> void:
	var e := _setup(Trees.new().a1m())
	eq(e["c"]["power.tdp"].max_value, 35.0, "battery max")
	var f := FileAccess.open(e["root"] + "/sys/class/power_supply/ADP1/online", FileAccess.WRITE)
	f.store_string("1\n")
	f.close()
	e["power"].check_power_source()
	e["power"].source_changed.emit(true)
	eq(e["c"]["power.tdp"].max_value, 43.0, "plugged max after source_changed")
	ok(e["power"].state()["plugged"], "state says plugged")
	_free()


func test_manual_lever_change_pauses_auto_tdp() -> void:
	var e := _setup(Trees.new().claw8ex())
	var power: Node = e["power"]
	e["reg"].set_value("power.tdp", 20)
	ok(power.autotune_start("g"), "Auto TDP on")
	e["reg"].set_value("power.epp", "power")
	ok(power.autotune.session.paused, "a manual EPP change pauses it for the game")
	power.autotune_stop()
	_free()


func test_autotune_options_through_controls() -> void:
	var e := _setup(Trees.new().claw8ex())
	e["reg"].set_value("power.autotune_target", 60)
	e["reg"].set_value("power.autotune_keep", 30)
	e["reg"].set_value("power.autotune_plugged", true)
	eq([e["power"].autotune_opts["target"], e["power"].autotune_opts["keep_pct"], e["power"].autotune_opts["plugged"]], [60, 15.0, true], "saved and clamped")
	e["reg"].set_value("power.autotune_target", 55)
	eq(e["power"].autotune_opts["target"], 60, "not a listed target: refused")
	_free()


func test_autotune_levers_restore_on_stop() -> void:
	var e := _setup(Trees.new().claw8ex())
	var power: Node = e["power"]
	var lev: RefCounted = power.levers
	ok(lev.boost_ok() and lev.gpu_floor_ok() and lev.cpu_ceiling_ok() and lev.tau_ok(), "every lever exists on the EX")
	eq(lev.gpu_limits(), [1000, 2300], "efficient clock and ceiling")
	ok(lev.gpu_floor(1100) and lev.boost(false) and lev.epp("power") and lev.gpu_profile("power_saving"), "moved")
	ok(lev.set_tau(8000000), "window short")
	eq(_read(e["root"], "/sys/class/powercap/intel-rapl-mmio:0/constraint_0_time_window_us"), "8000000", "tau written")
	# the kernel always lists both words, the active one in brackets; a plain file can't, so say it again
	var f := FileAccess.open(e["root"] + "/sys/class/drm/card1/device/tile0/gt0/freq0/power_profile", FileAccess.WRITE)
	f.store_string("base [power_saving]\n")
	f.close()
	ok(lev.restore(), "levers restored")
	ok(lev.restore_tau(), "window restored")
	eq([_read(e["root"], "/sys/class/drm/card1/device/tile0/gt0/freq0/min_freq"), _read(e["root"], "/sys/devices/system/cpu/intel_pstate/no_turbo"),
		_read(e["root"], "/sys/devices/system/cpu/cpu1/cpufreq/energy_performance_preference"), _read(e["root"], "/sys/class/drm/card1/device/tile0/gt0/freq0/power_profile"),
		_read(e["root"], "/sys/class/powercap/intel-rapl-mmio:0/constraint_0_time_window_us")],
		["100", "0", "balance_performance", "base", "55967744"], "all back")
	_free()


# ---- every devices.json row ---------------------------------------------------------------------

func test_every_device_row_detects_without_a_crash_and_stays_in_range() -> void:
	var trees := Trees.new()
	for r in load("res://scripts/device/device.gd").load_table():
		var t := trees.claw8ex()  # Intel tree with every lever; the row decides ranges and quirks
		t["row"] = r
		var e := _setup(t)
		_every_reason_set(e, r["id"])
		var tdp = e["c"]["power.tdp"]
		if tdp.available:
			var rt: Dictionary = r.get("tdp", {})
			ok(tdp.min_value >= float(rt.get("min", 0)) and tdp.max_value <= float(rt.get("plugged_max", 999)), "%s: TDP range inside devices.json" % r["id"])
			e["reg"].set_value("power.tdp", 999)
			ok(e["power"].state()["tdp_w"] <= float(rt.get("plugged_max", 999)), "%s: a huge TDP is clamped" % r["id"])
		var boost = e["c"]["power.boost"]
		if boost.available and r.get("tdp", {}).has("boost_max"):
			ok(boost.max_value <= float(r["tdp"]["boost_max"]) - float(r["tdp"]["min"]), "%s: boost inside boost_max" % r["id"])
		_free()


## Battery care on the Claw / Ally sets the charge limit to 80 % through the same
## backend; the charge limit control kept showing the old value (95 %). They
## declare each other in `affects`. Found by the end-to-end suite.
func test_battery_care_and_charge_limit_affect_each_other() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/controls/providers/power.gd")
	ok(src.contains('_make("power.battery_long_life", "toggle", {"affects": ["power.charge_limit"]'), "battery care re-reads the charge limit")
	ok(src.contains('_make("power.charge_limit", "slider", {"affects": ["power.battery_long_life"]'), "and the other way round")
