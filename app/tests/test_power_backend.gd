extends "res://tests/test_case.gd"
## Power service against fake busctl output and a fake sysfs. Nothing here
## touches the real system: commands go to fake_runner.gd, files to user://.

const PowerScript := preload("res://scripts/device/power.gd")
const DeviceScript := preload("res://scripts/device/device.gd")
const Busctl := preload("res://scripts/device/busctl.gd")
const Fake := preload("res://tests/fixtures/power/fake_runner.gd")

const PS_CARD := "/org/shadowblip/Performance/GPU/card1"
const PS_TDP_KEY := "--system get-property org.shadowblip.PowerStation " + PS_CARD + " org.shadowblip.GPU.Card.TDP TDP"
const PS_BOOST_KEY := "--system get-property org.shadowblip.PowerStation " + PS_CARD + " org.shadowblip.GPU.Card.TDP Boost"
const SM := "--user get-property com.steampowered.SteamOSManager1 /com/steampowered/SteamOSManager1 com.steampowered.SteamOSManager1."
const HELPER := "pkexec /usr/libexec/gamecove/gamecove-fix"


func _row(id: String) -> Dictionary:
	for d in DeviceScript.load_table():
		if d.get("id", "") == id:
			return d
	return {}


## A fresh copy of the fake Claw sysfs under user://, so tests can write to it.
func _sys(test_name: String, with_helper := true) -> String:
	var dst := ProjectSettings.globalize_path("user://test_power/" + test_name)
	_rmdir(dst)
	_copy(fixture("power/sys_claw"), dst)
	if not with_helper:
		DirAccess.remove_absolute(dst + "/usr/libexec/gamecove/gamecove-fix")
	return dst


func _copy(src: String, dst: String) -> void:
	DirAccess.make_dir_recursive_absolute(dst)
	var d := DirAccess.open(src)
	for f in d.get_files():
		DirAccess.copy_absolute(src + "/" + f, dst + "/" + f)
	for sub in d.get_directories():
		_copy(src + "/" + sub, dst + "/" + sub)


func _rmdir(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(path + "/" + f)
	for sub in d.get_directories():
		_rmdir(path + "/" + sub)
	DirAccess.remove_absolute(path)


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text + "\n")
	f.close()


func _power(bus_fixture: String, row: Dictionary, root: String) -> Node:
	var p: Node = PowerScript.new()
	p.setup(Fake.from_fixture(fixture("power/" + bus_fixture)), row, root)
	p.config_path = root + "/power.cfg"
	p.detect()
	return p


func test_claw_uses_powerstation_and_fixes() -> void:
	var root := _sys("claw_detect")
	var p := _power("bus_claw_powerstation.json", _row("msi-claw-8-ex"), root)
	var s: Dictionary = p.state()
	eq(s["backend"], "powerstation", "steamos-manager skipped on the Claw 8 EX")
	eq(s["tdp_w"], 25.0, "TDP from PowerStation")
	eq(s["tdp_min"], 8.0, "range from devices.json when PowerStation says 0")
	eq(s["tdp_max"], 35.0, "battery max")
	eq(s["profile"], "performance", "25 W is the performance profile")
	eq(s["charge_limit"], 100, "kernel 0 reads as no limit")
	eq(s["fan_mode"], "auto", "pwm enable 2 is auto")
	eq(s["fan_modes"], ["quiet", "auto", "max"], "fix fan modes")
	eq(s["supported"], {"tdp": true, "profiles": true, "charge_limit": true, "fan": true}, "all supported")
	for k in ["backend", "tdp_w", "tdp_min", "tdp_max", "profile", "profiles", "charge_limit", "fan_mode", "fan_modes", "supported"]:
		ok(s.has(k), "contract key " + k)
	p.free()


func test_default_order_prefers_steamos_manager() -> void:
	var row := _row("msi-claw-8-ex").duplicate()
	row.erase("tdp_backends")
	var p := _power("bus_claw_powerstation.json", row, _sys("order"))
	eq(p.backend, "steamos-manager", "steamos-manager first when the row doesn't say otherwise")
	p.free()


func test_deck_uses_steamos_manager_for_everything() -> void:
	var root := _sys("deck", false)
	var p := _power("bus_deck_steamos.json", _row("steam-deck-oled"), root)
	var s: Dictionary = p.state()
	eq(s["backend"], "steamos-manager", "backend")
	eq(s["tdp_w"], 15.0, "TdpLimit")
	eq(s["charge_limit"], 100, "MaxChargeLevel")
	eq(s["fan_modes"], ["auto", "firmware"], "FanControl1 modes")
	ok(p.set_charge_limit(80), "charge limit through steamos-manager")
	eq(p.state()["charge_limit"], 80, "charge read back")
	ok(p.set_fan_mode("firmware"), "fan to BIOS control")
	ok(p.runner.calls.has("busctl --user set-property com.steampowered.SteamOSManager1 /com/steampowered/SteamOSManager1 com.steampowered.SteamOSManager1.FanControl1 FanControlState u 0"), "FanControlState 0")
	ok(not p.set_charge_limit(40), "under SuggestedMinimumLimit refused")
	p.free()


func test_no_service_supports_nothing() -> void:
	var p := _power("bus_none.json", {}, _sys("none", false))
	var s: Dictionary = p.state()
	eq(s["backend"], "none", "backend none")
	eq(s["supported"], {"tdp": false, "profiles": false, "charge_limit": false, "fan": false}, "nothing supported")
	ok(not p.set_tdp(15.0), "set_tdp false")
	ok(not p.set_profile("balanced"), "set_profile false")
	ok(not p.set_fan_mode("quiet"), "set_fan_mode false")
	p.free()


func test_set_tdp_reads_back_and_sets_boost() -> void:
	var p := _power("bus_claw_powerstation.json", _row("msi-claw-8-ex"), _sys("set_tdp"))
	ok(p.set_tdp(17.0), "set_tdp true after read-back")
	eq(p.state()["tdp_w"], 17.0, "tdp_w")
	eq(p.state()["profile"], "balanced", "17 W is balanced")
	ok(p.runner.calls.has("busctl --system set-property org.shadowblip.PowerStation " + PS_CARD + " org.shadowblip.GPU.Card.TDP TDP d 17.0"), "TDP command")
	eq(p.runner.props[PS_BOOST_KEY]["data"], 2.0, "PL2 = TDP + 2 W")
	ok(p.set_tdp(99.0), "too high is clamped")
	eq(p.state()["tdp_w"], 35.0, "clamped to battery max")
	p.free()


func test_read_back_failure_returns_false() -> void:
	var p := _power("bus_claw_powerstation.json", _row("msi-claw-8-ex"), _sys("readback"))
	var seen := []
	p.changed.connect(func(st): seen.append(st))
	p.runner.frozen.append(PS_TDP_KEY)
	ok(not p.set_tdp(20.0), "write ignored -> false")
	ok(not p.set_profile("battery"), "profile write ignored -> false")
	eq(p.state()["tdp_w"], 25.0, "state keeps the real value")
	eq(seen.size(), 0, "no changed signal on failure")
	var deck := _power("bus_deck_steamos.json", _row("steam-deck-oled"), _sys("readback_deck", false))
	deck.runner.frozen.append(SM + "BatteryChargeLimit1 MaxChargeLevel")
	ok(not deck.set_charge_limit(80), "steamos-manager charge ignored -> false")
	p.free()
	deck.free()


func test_profile_watts_per_device() -> void:
	var claw := _row("msi-claw-8-ex")
	eq(PowerScript.profile_watts(claw, "battery", false), 12.0, "Claw battery")
	eq(PowerScript.profile_watts(claw, "balanced", false), 17.0, "Claw balanced")
	eq(PowerScript.profile_watts(claw, "performance", false), 25.0, "Claw performance")
	var deck := _row("steam-deck-lcd")
	eq(PowerScript.profile_watts(deck, "battery", false), 7.0, "Deck battery spread")
	eq(PowerScript.profile_watts(deck, "balanced", false), 10.0, "Deck balanced spread")
	eq(PowerScript.profile_watts(deck, "performance", true), 15.0, "Deck performance")
	eq(PowerScript.profile_watts({"tdp": {"min": 8, "battery_max": 20}, "profiles": {"performance": 25}}, "performance", false), 20.0, "clamped to battery max")
	eq(PowerScript.profile_watts(claw, "turbo", false), -1.0, "unknown profile")
	for d in DeviceScript.load_table():
		var t: Dictionary = d.get("tdp", {})
		for prof in ["battery", "balanced", "performance"]:
			var w := PowerScript.profile_watts(d, prof, false)
			ok(w >= float(t["min"]) and w <= float(t["battery_max"]), "%s %s inside range" % [d["id"], prof])


func test_profile_remembered_per_power_source() -> void:
	var root := _sys("sources")
	var p := _power("bus_claw_powerstation.json", _row("msi-claw-8-ex"), root)
	ok(p.set_tdp(14.0), "custom TDP on battery")
	eq(p.state()["profile"], "custom", "14 W is custom")
	_write(root + "/sys/class/power_supply/ADP1/online", "1")
	p.check_power_source()
	ok(p.plugged, "charger seen")
	ok(p.set_profile("performance"), "performance while plugged")
	_write(root + "/sys/class/power_supply/ADP1/online", "0")
	p.check_power_source()
	eq(p.state()["tdp_w"], 14.0, "battery's custom 14 W back")
	eq(p.state()["profile"], "custom", "custom back")
	_write(root + "/sys/class/power_supply/ADP1/online", "1")
	p.check_power_source()
	eq(p.state()["profile"], "performance", "plugged profile back")
	eq(p.state()["tdp_w"], 25.0, "plugged watts back")
	p.free()


func test_charge_limit_through_root_action() -> void:
	var root := _sys("charge")
	var p := _power("bus_claw_powerstation.json", _row("msi-claw-8-ex"), root)
	var threshold := root + "/sys/class/power_supply/BAT1/charge_control_end_threshold"
	p.runner.exec_handler = func(argv: PackedStringArray) -> int:
		if argv.size() == 5 and argv[2] == "charge-limit":
			_write(threshold, "0" if argv[4] == "100" else argv[4])
		return 0
	ok(p.set_charge_limit(80), "set 80")
	ok(p.runner.calls.has(HELPER + " charge-limit set 80"), "pkexec command")
	eq(p.state()["charge_limit"], 80, "read back from sysfs")
	ok(p.set_charge_limit(100), "no limit")
	eq(DeviceScript.read_text(threshold), "0", "Claw's 0 = none")
	var before: int = p.runner.calls.size()
	ok(not p.set_charge_limit(40), "40 refused")
	ok(not p.set_charge_limit(101), "101 refused")
	eq(p.runner.calls.size(), before, "nothing run for bad values")
	p.runner.exec_handler = func(_argv: PackedStringArray) -> int: return 0
	ok(not p.set_charge_limit(90), "helper said ok but sysfs unchanged -> false")
	p.runner.exec_handler = func(_argv: PackedStringArray) -> int: return 126
	ok(not p.set_charge_limit(90), "pkexec cancelled -> false")
	p.free()


func test_fan_through_root_action() -> void:
	var root := _sys("fan")
	var p := _power("bus_claw_powerstation.json", _row("msi-claw-8-ex"), root)
	var h := root + "/sys/class/hwmon/hwmon5/"
	p.runner.exec_handler = func(argv: PackedStringArray) -> int:
		if argv[2] != "fan":
			return 2
		for n in [1, 2]:
			if argv[4] == "auto":
				_write(h + "pwm%d_enable" % n, "2")
				continue
			var table: Array = PowerScript.FAN_TABLES[argv[4]]
			for i in range(6):
				_write(h + "pwm%d_auto_point%d_pwm" % [n, i + 1], str(int((int(table[i]) * 255 + 50) / 100)))
			_write(h + "pwm%d_enable" % n, "1")
		return 0
	ok(p.set_fan_mode("quiet"), "quiet")
	ok(p.runner.calls.has(HELPER + " fan set quiet"), "pkexec command")
	eq(p.state()["fan_mode"], "quiet", "read back quiet")
	ok(p.set_fan_mode("max"), "max")
	eq(p.read_fan_sysfs(), "max", "tables read as max")
	ok(p.set_fan_mode("auto"), "auto")
	ok(not p.set_fan_mode("turbo"), "unknown mode refused")
	eq(p.fix_command("fan", "quiet"), PackedStringArray(["pkexec", "/usr/libexec/gamecove/gamecove-fix", "fan", "set", "quiet"]), "argv")
	p.free()


func test_no_helper_means_no_fan_or_charge() -> void:
	var p := _power("bus_claw_powerstation.json", _row("msi-claw-8-ex"), _sys("nohelper", false))
	eq(p.state()["supported"]["fan"], false, "fan needs the helper")
	eq(p.state()["supported"]["charge_limit"], false, "charge needs the helper")
	p.free()


func test_unknown_device_takes_range_from_service() -> void:
	var p := _power("bus_deck_steamos.json", {}, _sys("unknown", false))
	eq(p.backend, "steamos-manager", "unknown device still gets TDP")
	eq(p.state()["tdp_max"], 15.0, "range from TdpLimitMax")
	eq(PowerScript.profile_watts(p.device, "performance", false), 15.0, "profiles spread over that range")
	p.free()
	var q := _power("bus_claw_powerstation.json", {"tdp_backends": ["powerstation"]}, _sys("unknown_ps", false))
	eq(q.backend, "none", "PowerStation without any range is not trusted")
	q.free()


func test_busctl_parsing() -> void:
	var fake := Fake.new()
	var bus := Busctl.new(fake, "--system")
	eq(bus.get_prop("a.b", "/a", "a.b.C", "X"), null, "missing -> null")
	fake.props["--system get-property a.b /a a.b.C X"] = {"type": "as", "data": ["x", "y"]}
	eq(bus.get_prop("a.b", "/a", "a.b.C", "X"), ["x", "y"], "array property")
	fake.methods["--system call a.b /a a.b.C M"] = {"type": "b", "data": [false]}
	eq(bus.call_method("a.b", "/a", "a.b.C", "M"), [false], "method out args")


func test_autotune_drives_power() -> void:
	var p := _power("bus_claw_powerstation.json", _row("msi-claw-8-ex"), _sys("autotune"))
	ok(p.set_profile("performance"), "user picks 25 W")
	ok(p.autotune_start(), "autotune starts")
	for i in 200:
		var w: float = p.state()["tdp_w"]
		p.autotune_feed(minf(60.0, 60.0 * w / 12.0), minf(w, 12.0))
	ok(p.state()["tdp_w"] <= 13.0, "lowered for a light game (%s W)" % p.state()["tdp_w"])
	p.autotune_stop()
	eq(p.state()["tdp_w"], 25.0, "user's TDP back after the game")
	eq(p.state()["profile"], "performance", "profile untouched by autotune")
	p.free()
