extends "res://tests/test_case.gd"
## Regression tests for the pre-release review's state, persistence and hardware-state
## findings (H2, H3, H5, H6, M16-M19, M25 and the low ones). Built on the review's
## proof scripts (proof_power.gd, proof_switch.gd) with the power_controls fixture trees.

const Trees := preload("res://tests/fixtures/power_controls/trees.gd")
const ControlsScript := preload("res://scripts/controls/controls.gd")
const ProviderScript := preload("res://scripts/controls/providers/power.gd")
const PowerScript := preload("res://scripts/device/power.gd")
const ProfilesScript := preload("res://scripts/controls/profiles.gd")
const SettingsFile := preload("res://scripts/system/settings_file.gd")

const CARD := "/org/shadowblip/Performance/GPU/card1"

var _nodes: Array = []


## {"reg", "power", "prov", "runner", "root", "row"}; `t` may carry "props" from an earlier run.
func _setup(t: Dictionary, row_override := {}) -> Dictionary:
	SettingsFile.reset_for_tests()
	Trees.make_bin()
	var runner: RefCounted = Trees.runner(t)
	var row: Dictionary = t["row"] if row_override.is_empty() else row_override
	var power: Node = PowerScript.new()
	power.setup(runner, row, t["root"])
	power.config_path = t["root"] + "/power.cfg"
	power.charge_settle_ms = 0
	power.detect()
	power.load_autotune_opts()
	power.restore()
	var reg: Node = ControlsScript.new()
	reg.sync_mode = true
	var ctx := {"sys_root": t["root"], "runner": runner, "home": t["root"], "device": row, "power": power, "registry": reg}
	reg.setup(ctx)
	var prov: RefCounted = ProviderScript.new()
	prov.cfg_path = t["root"] + "/power_controls.cfg"
	prov.setup(ctx)
	reg.register_provider(prov)
	reg.detect_all()
	_nodes.append(reg)
	_nodes.append(power)
	return {"reg": reg, "power": power, "prov": prov, "runner": runner, "root": t["root"], "row": row}


func _free() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()


func _wr(p: String, v: String) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(v + "\n")
	f.close()


func _ps(e: Dictionary, prop: String) -> float:
	return float(e["runner"].props[Trees.PS + CARD + " org.shadowblip.GPU.Card.TDP " + prop]["data"])


# ---- H6: PowerStation boost re-clamped for every TDP write ----------------------------------------

func test_h6_boost_never_exceeds_boost_max_after_plugging_in() -> void:
	for id in ["acer-predator-atlas-8", "gpd-win-5", "onexplayer-super-x"]:
		var t: Dictionary = Trees.new().claw8ex()
		var row := Trees.row(id)
		var e := _setup(t, row)
		var cap := float(row["tdp"]["boost_max"])
		var b: RefCounted = e["reg"].control("power.boost")
		ok(b.available, "%s: boost offered" % id)
		e["reg"].set_value("power.boost", b.max_value)   # the slider's top, on battery
		_wr(t["root"] + "/sys/class/power_supply/ADP1/online", "1")
		e["power"].check_power_source()
		e["reg"].detect_all()
		e["reg"].set_value("power.tdp", float(row["tdp"]["plugged_max"]))
		var tdp := _ps(e, "TDP")
		eq(tdp, float(row["tdp"]["plugged_max"]), "%s: TDP at the charger's max" % id)
		ok(tdp + _ps(e, "Boost") <= cap + 0.01, "%s: TDP %.0f + boost %.0f within boost_max %.0f" % [id, tdp, _ps(e, "Boost"), cap])
		# a hand-edited / stale boost_w is clamped too
		e["power"]._remember("device", "boost_w", 60.0)
		e["power"].load_autotune_opts()
		ok(e["power"].boost_w <= cap - float(row["tdp"]["min"]) + 0.01, "%s: boost_w=60 clamped on load (%.0f)" % [id, e["power"].boost_w])
		e["power"].set_tdp(float(row["tdp"]["plugged_max"]))
		ok(_ps(e, "TDP") + _ps(e, "Boost") <= cap + 0.01, "%s: hand-edited boost within boost_max (boost %.0f)" % [id, _ps(e, "Boost")])
		_free()


# ---- H5: fan preset and fan curve no longer overwrite each other ---------------------------------

func _duty(root: String) -> Array:
	var out := []
	for i in 6:
		var raw := FileAccess.get_file_as_string(root + "/sys/class/hwmon/hwmon5/pwm1_auto_point%d_pwm" % (i + 1)).strip_edges()
		out.append(roundi(int(raw) * 100.0 / 255.0))
	return out


## Proof A: Quiet once, later a 60-100 % curve, then the charger: the fans went back to Quiet.
func test_h5_curve_survives_plugging_in() -> void:
	var t: Dictionary = Trees.new().claw8ex()
	var e := _setup(t)
	e["reg"].set_value("power.fan_mode", "quiet")
	e["reg"].set_value("power.fan_curve", [60, 70, 80, 90, 100, 100])
	eq(_duty(t["root"]), [60, 70, 80, 90, 100, 100], "curve written")
	eq(e["power"]._recall("device", "fan_mode", ""), "custom", "the curve is what's remembered")
	_wr(t["root"] + "/sys/class/power_supply/ADP1/online", "1")
	e["power"].check_power_source()
	eq(_duty(t["root"]), [60, 70, 80, 90, 100, 100], "still the curve after plugging in")
	_free()


## Proof B1: an old curve, then Max: resume / the next start put the old curve back.
func test_h5_preset_picked_after_a_curve_stays() -> void:
	var t: Dictionary = Trees.new().claw8ex()
	var e := _setup(t)
	e["reg"].set_value("power.fan_curve", [0, 40, 40, 45, 60, 75])
	e["reg"].set_value("power.fan_mode", "max")
	ok(not e["prov"].saved_device_values().has("power.fan_curve"), "saved curve dropped when a preset is picked")
	e["power"].refresh(true)
	eq(_duty(t["root"]), [100, 100, 100, 100, 100, 100], "max after resume")
	eq(e["reg"].control("power.fan_mode").value, "max", "control still max")
	var props: Dictionary = e["runner"].props
	_free()
	var e2 := _setup({"root": t["root"], "row": t["row"], "props": props, "methods": t["methods"]})
	e2["prov"]._on_detected()
	eq(_duty(t["root"]), [100, 100, 100, 100, 100, 100], "max after the next start")
	_free()


# ---- M18: a saved "Battery care" no longer overrides the charge-limit slider ---------------------

## Proof G: Battery care on then off, later the slider at 80 %: the next start / resume wrote 100.
func test_m18_battery_care_does_not_override_the_slider() -> void:
	var t: Dictionary = Trees.new().ally()
	var key := Trees.SM + "BatteryChargeLimit1 MaxChargeLevel"
	var e := _setup(t)
	e["reg"].set_value("power.battery_long_life", true)
	e["reg"].set_value("power.battery_long_life", false)
	e["reg"].set_value("power.charge_limit", 80)
	eq(int(e["runner"].props[key]["data"]), 80, "slider 80 %")
	ok(not e["prov"].saved_device_values().has("power.battery_long_life"), "battery care through the limit isn't saved on its own")
	e["power"].refresh(true)
	eq(int(e["runner"].props[key]["data"]), 80, "still 80 % after resume")
	var props: Dictionary = e["runner"].props
	_free()
	var e2 := _setup({"root": t["root"], "row": t["row"], "props": props, "methods": t["methods"]})
	e2["prov"]._on_detected()
	eq(int(e2["runner"].props[key]["data"]), 80, "still 80 % at the next start")
	_free()
