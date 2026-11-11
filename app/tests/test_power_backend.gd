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
const HELPER := "pkexec /usr/libexec/gamecove/gamecove-fix-set"
const STATUS := "/usr/libexec/gamecove/gamecove-fix"


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


## fake_runner that also answers `gamecove-fix <name> status` with canned output.
class StatusRunner extends "res://tests/fixtures/power/fake_runner.gd":
	var status_out := {}  # fix name -> status text

	func run(program: String, args: PackedStringArray) -> Dictionary:
		if args.size() == 2 and args[1] == "status" and program.ends_with("/gamecove-fix"):
			calls.append(program + " " + " ".join(args))
			if status_out.has(args[0]):
				return {"code": 0, "out": status_out[args[0]]}
			return {"code": 65, "out": ""}
		return super.run(program, args)


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


## Intel: PL2 = PL1 + 2 W (pl2_offset_w), as Handheld Daemon, PowerControl, PowerStation's Intel
## database and ClawDeck's power.py run it, never past the model's PL2 (boost_max); a boost the user
## picked wins, and is never stored by a TDP write.
func test_intel_pl2_is_pl1_plus_2() -> void:
	var root := _sys("live_boost")
	var p := _power("bus_claw_powerstation.json", _row("msi-claw-8-ex"), root)
	p.runner.props[PS_BOOST_KEY]["data"] = 7.0
	p.load_autotune_opts()
	p.restore()
	ok(p.set_tdp(17.0), "TDP")
	eq(p.runner.props[PS_BOOST_KEY]["data"], 2.0, "PL2 = 17 + 2 W")
	eq(p.boost_w, -1.0, "not remembered as the user's")
	ok(p.set_boost_w(4.0), "the user picks 4 W")
	ok(p.set_tdp(20.0), "TDP again")
	eq(p.runner.props[PS_BOOST_KEY]["data"], 4.0, "the user's boost stays")
	p.free()
	# the model's PL2 caps it: the Atlas 8 allows 40 W sustained and 40 W PL2
	var atlas := _row("acer-predator-atlas-8").duplicate(true)
	atlas["tdp_backends"] = ["powerstation"]
	var q := _power("bus_claw_powerstation.json", atlas, _sys("atlas_pl2"))
	q.plugged = true
	eq(q.boost_for(30.0), 2.0, "30 W: PL2 32 W")
	eq(q.boost_for(39.0), 1.0, "39 W: PL2 at the model's 40 W")
	eq(q.boost_for(40.0), 0.0, "40 W: no boost past the model's PL2")
	q.free()
	# review 4-L2: write_tdp also honours PowerStation's own MaxBoost, as set_boost_w does
	var capped := _power("bus_claw_powerstation.json", _row("msi-claw-8-ex"), root)
	capped.runner.props[PS_BOOST_KEY.replace(" Boost", " MaxBoost")] = {"type": "d", "data": 1.0}
	capped.load_autotune_opts()
	ok(capped.set_tdp(17.0), "TDP")
	ok(float(capped.runner.props[PS_BOOST_KEY]["data"]) <= 1.0, "the boost written stays under the service's own ceiling (1 W)")
	capped.free()
	# review 4-L2: a row with no boost_max is capped at its highest TDP, not left unbounded
	var generic := _row("msi-claw-8-ex").duplicate(true)
	generic["tdp_backends"] = ["powerstation"]
	generic["tdp"] = {"min": 8, "battery_max": 25, "plugged_max": 28}
	generic["pl2_offset_w"] = 2.0
	var g := _power("bus_claw_powerstation.json", generic, _sys("generic_pl2"))
	g.plugged = true
	eq(g.boost_for(20.0), 2.0, "20 W: PL2 22 W")
	eq(g.boost_for(27.0), 1.0, "27 W: PL2 at the row's 28 W")
	eq(g.boost_for(28.0), 0.0, "28 W: PL2 was 30 W")
	g.boost_w = 9.0
	eq(g.boost_for(20.0), 8.0, "a hand-edited boost_w is bounded the same way")
	g.free()
	# rows without the Intel rule leave PowerStation's own boost
	var amd := _row("msi-claw-a8").duplicate(true)
	amd["tdp_backends"] = ["powerstation"]
	var a := _power("bus_claw_powerstation.json", amd, _sys("amd_pl2"))
	eq(a.boost_for(20.0), -1.0, "no PL2 rule on AMD rows")
	a.free()


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
	eq(p.runner.props[PS_BOOST_KEY]["data"], 2.0, "PL2 = PL1 + 2 W on Intel (the user picked none)")
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
	deck.charge_settle_ms = 0
	deck.runner.frozen.append(SM + "BatteryChargeLimit1 MaxChargeLevel")
	ok(not deck.set_charge_limit(80), "steamos-manager charge ignored -> false")
	p.free()
	deck.free()


## Live on a ROG Ally (SteamOS 3.10): MaxChargeLevel reads the old value for
## about a second after set-property, then the new one.
func test_steamos_manager_charge_applies_late() -> void:
	var deck := _power("bus_deck_steamos.json", _row("steam-deck-oled"), _sys("late_charge", false))
	deck.charge_settle_ms = 0
	deck.runner.late_reads[SM + "BatteryChargeLimit1 MaxChargeLevel"] = 3
	ok(deck.set_charge_limit(85), "a late read-back still counts once it arrives")
	eq(deck.state()["charge_limit"], 85, "85 read back")
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


## review S1-2: unplugging (or waking up) never keeps a TDP above the battery limit.
const SM_TDP_KEY := SM + "TdpLimit1 TdpLimit"


func _tdp_key(p: Node) -> String:
	return SM_TDP_KEY if p.backend == "steamos-manager" else PS_TDP_KEY


func _unplug_clamps(id: String, plugged_w: float, battery_w: float) -> void:
	var root := _sys("unplug_" + id)
	_write(root + "/sys/class/power_supply/ADP1/online", "1")
	var p := _power("bus_claw_powerstation.json", _row(id), root)
	p.check_power_source()
	ok(p.plugged, id + ": on the charger")
	var key := _tdp_key(p)
	ok(p.set_tdp(plugged_w), id + ": charger's maximum")
	eq(p.state()["tdp_w"], plugged_w, id + ": %d W on the charger" % plugged_w)
	_write(root + "/sys/class/power_supply/ADP1/online", "0")
	p.check_power_source()
	eq(p.state()["tdp_w"], battery_w, id + ": unplugged with nothing saved for battery: clamped to %d W" % battery_w)
	eq(float(p.runner.props[key]["data"]), battery_w, id + ": written to the hardware")
	# resume: the firmware (or a stale value) comes back above the battery limit
	p.runner.props[key]["data"] = plugged_w
	p.refresh(true)
	eq(float(p.runner.props[key]["data"]), battery_w, id + ": resume never re-applies the charger's value on battery")
	eq(p.state()["tdp_w"], battery_w, id + ": state follows")
	# unplugged while asleep
	_write(root + "/sys/class/power_supply/ADP1/online", "1")
	p.check_power_source()
	eq(p.state()["tdp_w"], plugged_w, id + ": charger's own value back on the charger")
	_write(root + "/sys/class/power_supply/ADP1/online", "0")
	p.refresh(true)
	ok(not p.plugged, id + ": resume notices the charger went while asleep")
	eq(float(p.runner.props[key]["data"]), battery_w, id + ": and clamps")
	p.free()


func test_unplug_clamps_tdp_rog_ally() -> void:
	_unplug_clamps("asus-rog-ally", 30.0, 25.0)


func test_unplug_clamps_tdp_legion_go_s() -> void:
	_unplug_clamps("lenovo-legion-go-s-z1e", 33.0, 30.0)


func test_unplug_clamps_auto_tdp_ceiling() -> void:
	var root := _sys("unplug_auto")
	_write(root + "/sys/class/power_supply/ADP1/online", "1")
	var p := _power("bus_claw_powerstation.json", _row("asus-rog-ally"), root)
	p.check_power_source()
	var key := _tdp_key(p)
	p.autotune_opts["plugged"] = true
	ok(p.set_tdp(30.0), "30 W plugged")
	ok(p.autotune_start("g"), "Auto TDP on the charger (asked for)")
	eq(p.autotune.session.ceiling_tdp, 30, "plugged ceiling")
	_write(root + "/sys/class/power_supply/ADP1/online", "0")
	p.check_power_source()
	ok(p.autotune.session.ceiling_tdp <= 25, "ceiling down to the battery limit")
	ok(p.state()["tdp_w"] <= 25.0, "TDP too")
	p.autotune_stop()
	ok(float(p.runner.props[key]["data"]) <= 25.0, "stopping Auto TDP on battery doesn't put 30 W back")
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
	eq(p.fix_command("fan", "quiet"), PackedStringArray(["pkexec", "/usr/libexec/gamecove/gamecove-fix-set", "fan", "set", "quiet"]), "argv: the no-password entry point")
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


## The running app's worker: settings queued while it is busy collapse to the
## newest value, and the caller never waits on busctl.
func test_worker_keeps_only_the_newest_value() -> void:
	var p := _power("bus_claw_powerstation.json", _row("msi-claw-8-ex"), _sys("worker"))
	var gate := Semaphore.new()
	p._thread = Thread.new()
	p._thread.start(p._worker)
	p._queue("hold", func(): gate.wait(); return true)  # keeps the worker busy
	var t0 := Time.get_ticks_msec()
	for w in [10.0, 12.0, 14.0, 16.0]:
		p.request_set("tdp", w)
	ok(Time.get_ticks_msec() - t0 < 50, "request_set returns at once")
	gate.post()
	var waited := 0
	while waited < 2000:
		p._job_mutex.lock()
		var idle: bool = p._job_order.is_empty()
		p._job_mutex.unlock()
		if idle and p.state()["tdp_w"] == 16.0:
			break
		OS.delay_msec(10)
		waited += 10
	var sets: Array = p.runner.calls.filter(func(c): return c.contains("set-property") and c.contains(" TDP d "))
	eq(sets.size(), 1, "one TDP write for four slider steps")
	eq(p.state()["tdp_w"], 16.0, "the newest value won")
	p._exit_tree()
	ok(p._thread == null, "worker stopped")
	p.free()


## `gamecove-fix fan remove` must stick: restore() puts remembered fix values
## back only while the fix's status says installed=yes.
func test_restore_respects_removed_fixes() -> void:
	for installed in ["no", "yes"]:
		var root := _sys("restore_" + installed)
		var fake := StatusRunner.new()
		var src: RefCounted = Fake.from_fixture(fixture("power/bus_claw_powerstation.json"))
		fake.props = src.props
		fake.methods = src.methods
		var status := "applies=yes\ninstalled=%s\nstate=%s\n" % [installed, "on" if installed == "yes" else "off"]
		fake.status_out = {"fan": status, "charge-limit": status}
		var p: Node = PowerScript.new()
		p.setup(fake, _row("msi-claw-8-ex"), root)
		p.config_path = root + "/power.cfg"
		var cfg := ConfigFile.new()
		cfg.set_value("device", "charge_limit", 80)
		cfg.set_value("device", "fan_mode", "quiet")
		cfg.save(p.config_path)
		p.detect()
		eq(p.state()["fan_mode"], "auto", "fixture fan starts on auto")
		p.restore()
		ok(fake.calls.has(STATUS + " fan status"), "fan status read (%s)" % installed)
		ok(fake.calls.has(STATUS + " charge-limit status"), "charge-limit status read (%s)" % installed)
		var root_calls := fake.calls.filter(func(c): return c.begins_with("pkexec"))
		if installed == "no":
			eq(root_calls.size(), 0, "removed fixes are not re-applied")
		else:
			ok(root_calls.has(HELPER + " fan set quiet"), "installed fan re-applied")
			ok(root_calls.has(HELPER + " charge-limit set 80"), "installed charge limit re-applied")
		p.free()


func test_fix_installed_parses_status() -> void:
	var p := _power("bus_claw_powerstation.json", _row("msi-claw-8-ex"), _sys("fixstatus"))
	var fake := StatusRunner.new()
	fake.status_out = {"fan": "applies=yes\ninstalled=yes\nstate=on\n", "charge-limit": "installed=no\nstate=off\n"}
	p.runner = fake
	ok(p.fix_installed("fan"), "installed=yes")
	ok(not p.fix_installed("charge-limit"), "installed=no")
	ok(not p.fix_installed("claw8ex-vrr"), "status failed -> not installed")
	ok(not fake.calls.any(func(c): return c.begins_with("pkexec")), "status needs no pkexec")
	p.free()


## Auto TDP start/stop and refresh go through the worker; start then stop queued
## while it is busy leaves only the stop.
func test_autotune_and_refresh_requests_use_the_worker() -> void:
	var p := _power("bus_claw_powerstation.json", _row("msi-claw-8-ex"), _sys("autotune_req"))
	ok(p.set_profile("performance"), "user picks 25 W")
	var gate := Semaphore.new()
	p._thread = Thread.new()
	p._thread.start(p._worker)
	p._queue("hold", func(): gate.wait(); return true)
	var before: int = p.runner.calls.size()
	p.request_autotune(true)
	p.request_refresh()
	eq(p.runner.calls.size(), before, "nothing ran on the caller's thread")
	p.request_autotune(false)
	p.autotune_feed(30.0, 10.0)  # a late sample after the stop request is dropped
	gate.post()
	var waited := 0
	while waited < 2000:
		p._job_mutex.lock()
		var idle: bool = p._job_order.is_empty()
		p._job_mutex.unlock()
		if idle and p.runner.calls.size() > before:
			break
		OS.delay_msec(10)
		waited += 10
	OS.delay_msec(50)
	ok(not p._autotune_on, "stop was the newest: autotune never started")
	eq(p.state()["tdp_w"], 25.0, "TDP untouched")
	ok(p.runner.calls.size() > before, "refresh ran on the worker")
	p._exit_tree()
	p.request_autotune(true)  # no worker: runs here
	ok(p._autotune_on, "start without a worker runs at once")
	p.request_autotune(false)
	ok(not p._autotune_on, "stop without a worker runs at once")
	eq(p.state()["tdp_w"], 25.0, "user's TDP back")
	p.free()


## A fresh fake root with one manual-duty fan hwmon (oxp_ec, ayaneo_ec, ...).
func _sys_manual_fan(test_name: String, hw_name: String, enable: String) -> String:
	var root := _sys(test_name)
	var h := root + "/sys/class/hwmon/hwmon5/"
	for f in DirAccess.get_files_at(h):
		DirAccess.remove_absolute(h + f)
	_write(h + "name", hw_name)
	_write(h + "pwm1_enable", enable)
	_write(h + "pwm1", "90")
	return root


func test_fan_drivers_for_other_makers() -> void:
	for case in [["onexplayer-onexfly-f1", "oxp_ec", "2"], ["ayaneo-2s", "ayaneo_ec", "2"], ["gpd-win-4", "gpdfan", "2"], ["zotac-zone", "zotac_zone_platform", "2"]]:
		var root := _sys_manual_fan("fan_" + case[1], case[1], case[2])
		var row := _row(case[0])
		eq(row.get("fan_via"), "fix", case[0] + ": devices.json drives the fan through the fix")
		var p := _power("bus_claw_powerstation.json", row, root)
		eq(p.state()["supported"]["fan"], true, case[1] + ": fan supported")
		eq(p.state()["fan_modes"], ["auto", "max"], case[1] + ": no quiet on a one-duty driver")
		eq(p.state()["fan_mode"], "auto", case[1] + ": enable 2 reads as auto")
		var h := root + "/sys/class/hwmon/hwmon5/"
		p.runner.exec_handler = func(argv: PackedStringArray) -> int:
			if argv[4] == "max":
				_write(h + "pwm1_enable", "1")
				_write(h + "pwm1", "255")
			else:
				_write(h + "pwm1_enable", "2")
			return 0
		ok(p.set_fan_mode("max"), case[1] + ": max")
		eq(p.state()["fan_mode"], "max", case[1] + ": manual 255 reads as max")
		ok(not p.set_fan_mode("quiet"), case[1] + ": quiet refused before any root action")
		ok(not p.runner.calls.has(HELPER + " fan set quiet"), case[1] + ": no pkexec for quiet")
		p.free()


func test_old_oxp_driver_auto_is_zero() -> void:
	var root := _sys_manual_fan("fan_oxpec", "oxpec", "0")
	var p := _power("bus_claw_powerstation.json", _row("aokzoe-a1"), root)
	eq(p.state()["fan_mode"], "auto", "oxp-sensors: enable 0 is the EC's own control")
	p.free()
	var root2 := _sys_manual_fan("fan_oxp_full", "oxp_ec", "0")
	var q := _power("bus_claw_powerstation.json", _row("aokzoe-a1"), root2)
	eq(q.state()["fan_mode"], "max", "oxpec 6.16+: enable 0 is full speed")
	q.free()


func test_asus_fan_curve_tables() -> void:
	var root := _sys("fan_asus")
	var h := root + "/sys/class/hwmon/hwmon5/"
	for f in DirAccess.get_files_at(h):
		DirAccess.remove_absolute(h + f)
	_write(h + "name", "asus_custom_fan_curve")
	var quiet: Array = PowerScript.FAN_DRIVERS["asus_custom_fan_curve"]["tables"]["quiet"]
	for n in [1, 2]:
		_write(h + "pwm%d_enable" % n, "1")
		for i in range(8):
			_write(h + "pwm%d_auto_point%d_pwm" % [n, i + 1], str(int((int(quiet[i]) * 255 + 50) / 100)))
	var p := _power("bus_claw_powerstation.json", _row("asus-rog-ally"), root)
	eq(p.state()["fan_modes"], ["quiet", "auto", "max"], "ASUS has quiet")
	eq(p.state()["fan_mode"], "quiet", "eight-point table read as quiet")
	p.free()


func test_ayaneo_charge_behaviour() -> void:
	var root := _sys("charge_aya")
	var bat := root + "/sys/class/power_supply/BAT1/"
	DirAccess.remove_absolute(bat + "charge_control_end_threshold")
	_write(bat + "charge_behaviour", "[auto] inhibit-charge")
	_write(bat + "capacity", "85")
	var state_dir := root + PowerScript.CHARGE_STATE_DIR
	var row := _row("ayaneo-2s")
	eq(row.get("charge_limit_via"), "sysfs", "AYANEO row says sysfs")
	var p := _power("bus_claw_powerstation.json", row, root)
	eq(p.state()["supported"]["charge_limit"], true, "behaviour battery offers a limit")
	eq(p.state()["charge_limit"], 100, "no limit before the fix ran")
	p.runner.exec_handler = func(argv: PackedStringArray) -> int:
		if argv[2] != "charge-limit":
			return 2
		DirAccess.make_dir_recursive_absolute(state_dir)
		_write(state_dir + "/original", "auto")
		_write(state_dir + "/limit", argv[4])
		var cap := DeviceScript.read_text(bat + "capacity").to_int()
		var on := DeviceScript.ac_online(root)
		_write(bat + "charge_behaviour", "auto [inhibit-charge]" if on and cap >= int(argv[4]) and int(argv[4]) < 100 else "[auto] inhibit-charge")
		return 0
	_write(root + "/sys/class/power_supply/ADP1/online", "1")
	p.plugged = true
	ok(p.set_charge_limit(80), "limit 80 through the fix")
	eq(p.state()["charge_limit"], 80, "limit read back from the fix's state")
	ok("inhibit-charge]" in DeviceScript.read_text(bat + "charge_behaviour"), "85 % on the charger: charging held")
	p.runner.calls.clear()
	ok(not p.hold_charge(), "nothing crossed: no root action")
	eq(p.runner.calls.size(), 0, "one sysfs read only")
	_write(root + "/sys/class/power_supply/ADP1/online", "0")
	p.check_power_source()
	ok(p.runner.calls.has(HELPER + " charge-limit set 80"), "unplugging re-runs the fix")
	ok(DeviceScript.read_text(bat + "charge_behaviour").begins_with("[auto]"), "unplugged: back to auto")
	p.free()


func test_unknown_device_never_exceeds_the_service_max() -> void:
	# A CPU-table row for an unknown handheld says 5..28 W; the service allows 4..15 W.
	var row := {"id": "unknown", "tier": "generic", "support": "generic", "tdp": {"min": 5, "battery_max": 28, "plugged_max": 30},
		"tdp_backends": ["steamos-manager"], "fan": null, "charge_limit": false}
	var p := _power("bus_deck_steamos.json", row, _sys("unknown_clamp", false))
	eq(p.backend, "steamos-manager", "backend")
	ok(p.state()["tdp_max"] <= 15.0, "battery max clamped to the service (%s)" % p.state()["tdp_max"])
	ok(p._range["plugged_max"] <= 15.0, "plugged max clamped too")
	ok(p.state()["tdp_min"] >= 5.0, "own min kept when it is above the service's")
	ok(p.set_tdp(40.0), "a too-high request is clamped, not refused")
	ok(p.state()["tdp_w"] <= 15.0, "never above the service's max (%s)" % p.state()["tdp_w"])
	ok(PowerScript.profile_watts(p.device, "performance", true) <= 15.0, "profiles inside the clamped range")
	p.free()
	# a specific, tested row keeps its own range
	var q := _power("bus_claw_powerstation.json", _row("msi-claw-8-ex"), _sys("specific_keep"))
	eq(q.state()["tdp_max"], 35.0, "specific row keeps devices.json's range")
	q.free()


## Review 2, low 23: the boost was written after a raised TDP, so TDP + the old, larger boost
## passed the new total for a moment. A smaller boost now goes in first.
func test_smaller_boost_goes_in_before_a_raised_tdp() -> void:
	var p := _power("bus_claw_powerstation.json", _row("msi-claw-8-ex"), _sys("boost_order"))
	p.runner.props[PS_BOOST_KEY]["data"] = 8.0
	ok(p.set_boost_w(2.0), "the user picks 2 W")
	p.runner.props[PS_BOOST_KEY]["data"] = 8.0   # the firmware put its own larger boost back
	p.runner.calls.clear()
	ok(p.set_tdp(25.0), "TDP up")
	var tdp_i := -1
	var boost_i := -1
	for i in p.runner.calls.size():
		var c: String = p.runner.calls[i]
		if c.contains("TDP TDP d") and tdp_i < 0:
			tdp_i = i
		if c.contains("TDP Boost d") and boost_i < 0:
			boost_i = i
	ok(boost_i >= 0 and tdp_i >= 0 and boost_i < tdp_i, "boost lowered before the TDP went up (%d, %d)" % [boost_i, tdp_i])
	ok(p.set_boost_w(6.0), "a larger boost")
	p.runner.props[PS_BOOST_KEY]["data"] = 1.0
	p.runner.calls.clear()
	ok(p.set_tdp(15.0), "TDP")
	tdp_i = -1
	boost_i = -1
	for i in p.runner.calls.size():
		var c: String = p.runner.calls[i]
		if c.contains("TDP TDP d") and tdp_i < 0:
			tdp_i = i
		if c.contains("TDP Boost d") and boost_i < 0:
			boost_i = i
	ok(tdp_i >= 0 and (boost_i < 0 or boost_i > tdp_i), "a larger boost goes in after the TDP")
	p.free()


# ---- the maker's limits on every path, stricter firmware limits win (item 9) ---------------------------

func _fw_spl(root: String, lo: int, hi: int) -> void:
	var a := root + "/sys/class/firmware-attributes/msi-wmi-platform/attributes/ppt_pl1_spl"
	DirAccess.make_dir_recursive_absolute(a)
	_write(a + "/min_value", str(lo))
	_write(a + "/max_value", str(hi))
	_write(a + "/current_value", str(lo))


func test_firmware_limits_stricter_than_the_maker_win() -> void:
	var root := _sys("fw_strict")
	_fw_spl(root, 10, 30)
	var p := _power("bus_claw_powerstation.json", _row("msi-claw-8-ex"), root)
	eq(p.state()["tdp_min"], 10.0, "firmware minimum 10 W over the row's 8 W")
	eq(p.state()["tdp_max"], 30.0, "firmware maximum 30 W under the row's 35 W")
	ok(p.set_tdp(35.0), "slider past it")
	eq(p.state()["tdp_w"], 30.0, "slider clamped to the firmware's 30 W")
	ok(p.set_tdp(4.0), "slider under it")
	eq(p.state()["tdp_w"], 10.0, "and to its 10 W")
	p.free()


func test_maker_limits_win_over_a_wider_firmware_range() -> void:
	var root := _sys("fw_wide")
	_fw_spl(root, 5, 60)
	var p := _power("bus_claw_powerstation.json", _row("msi-claw-8-ex"), root)
	eq(p.state()["tdp_min"], 8.0, "MSI's 8 W, not the firmware's 5")
	eq(p.state()["tdp_max"], 35.0, "MSI's 35 W, not the firmware's 60")
	p.free()


func test_every_path_is_clamped_to_the_limits() -> void:
	var root := _sys("clamp_paths")
	_fw_spl(root, 8, 30)
	var row := _row("msi-claw-8-ex").duplicate(true)
	row["profiles"] = {"battery": 12, "balanced": 17, "performance": 33}   # a preset past the firmware's 30 W
	var p := _power("bus_claw_powerstation.json", row, root)
	ok(p.set_profile("performance"), "preset")
	eq(p.state()["tdp_w"], 30.0, "preset clamped (33 -> 30 W)")
	ok(p.write_tdp(50.0), "Auto TDP / the temperature guard write directly")
	eq(p.state()["tdp_w"], 30.0, "a direct write clamped too")
	ok(p.write_tdp(2.0), "and under the minimum")
	eq(p.state()["tdp_w"], 8.0, "to the minimum")
	ok(p.set_tdp(99.0), "a per-game or imported profile's value goes through set_tdp")
	eq(p.state()["tdp_w"], 30.0, "clamped")
	p._user_tdp = 45.0   # a ceiling remembered from before a firmware update
	ok(p.autotune_start("game"), "Auto TDP starts")
	ok(p.autotune.session.ceiling_tdp <= 30, "its ceiling is inside the limits (%s)" % p.autotune.session.ceiling_tdp)
	p.autotune_stop()
	ok(p.set_boost_w(20.0), "boost")
	ok(float(p.runner.props[PS_BOOST_KEY]["data"]) + p.state()["tdp_w"] <= 45.0, "TDP + boost never past the model's PL2 (45 W)")
	p.free()


func test_unknown_and_family_rows_get_conservative_limits() -> void:
	var doc := {"devices": DeviceScript.load_table(), "cpus": JSON.parse_string(FileAccess.get_file_as_string("res://data/devices.json"))["cpus"]}
	# an unlisted handheld with a Ryzen AI Max (the chip table says 45 W / 80 W)
	var unknown := DeviceScript.resolve(doc, {"sys_vendor": "Nobody", "product_name": "Mystery", "board_name": "X"}, "AMD RYZEN AI MAX+ 395 w/ Radeon 8060S", {})
	eq(unknown["id"], "unknown", "no row")
	ok(float(unknown["tdp"]["plugged_max"]) <= 25.0 and float(unknown["tdp"]["battery_max"]) <= 20.0, "conservative: %s" % unknown["tdp"])
	ok(str(unknown["tdp"].get("source", "")).contains("conservative"), "its source says so")
	# an unlisted GPD with the same chip: the family row is filled from the CPU, conservatively
	var fam := DeviceScript.resolve(doc, {"sys_vendor": "GPD", "product_name": "G9999-01", "board_name": "G9999-01"}, "AMD RYZEN AI MAX+ 395 w/ Radeon 8060S", {})
	eq(fam["id"], "gpd-family", "family row")
	ok(float(fam["tdp"]["plugged_max"]) <= 25.0, "family row not above the conservative limits: %s" % fam["tdp"])
	ok(DeviceScript.row_problems(fam).is_empty(), "still a valid row: %s" % [DeviceScript.row_problems(fam)])


## Final review, session: leaving GameCove re-applied GameCove's own profile; the TDP, boost and
## fan mode the handheld had before GameCove were never noted or put back.
func _boot(root: String, id: String) -> void:
	DirAccess.make_dir_recursive_absolute(root + "/proc/sys/kernel/random")
	_write(root + "/proc/sys/kernel/random/boot_id", id)


func test_values_from_before_gamecove_are_noted_and_put_back() -> void:
	var root := _sys("before")
	_boot(root, "boot-a")
	var p := _power("bus_claw_powerstation.json", _row("msi-claw-8-ex"), root)
	ok(p.record_before(), "noted at start")
	var rec: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(root + "/power_before.json"))
	eq([rec["boot"], rec["backend"], rec["tdp_w"], rec["boost_w"]], ["boot-a", "powerstation", 25.0, 12.0], "the live TDP and boost, for this boot")
	# GameCove's own values on top: 17 W and a 5 W boost the user picked
	ok(p.set_tdp(17.0) and p.set_boost_w(5.0), "GameCove's values")
	ok(not p.record_before(), "a restart in the same boot keeps the first record (what is live now is ours)")
	eq(JSON.parse_string(FileAccess.get_file_as_string(root + "/power_before.json"))["tdp_w"], 25.0, "unchanged")
	p.runner.calls.clear()
	ok(p.restore_before(), "put back on leaving")
	eq(p.runner.props[PS_TDP_KEY]["data"], 25.0, "TDP as before GameCove")
	eq(p.runner.props[PS_BOOST_KEY]["data"], 12.0, "boost as before GameCove")
	ok(not FileAccess.file_exists(root + "/power_before.json"), "and forgotten")
	eq(p.boost_w, 5.0, "GameCove's own boost is still the user's choice")
	var text := FileAccess.get_file_as_string(root + "/power.cfg")
	ok(text.contains("battery=\"balanced\"") and text.contains("boost_w=5.0"), "power.cfg keeps GameCove's own profile (17 W, balanced) and boost; the restore isn't remembered as a pick: " + text)
	ok(not p.restore_before(), "nothing left to put back")
	p.free()


func test_before_record_from_another_boot_is_never_applied() -> void:
	var root := _sys("before_boot")
	_boot(root, "boot-a")
	var p := _power("bus_claw_powerstation.json", _row("msi-claw-8-ex"), root)
	ok(p.record_before(), "noted")
	ok(p.set_tdp(17.0), "ours")
	_boot(root, "boot-b")
	p.runner.calls.clear()
	ok(not p.restore_before(), "another boot: stale values aren't written")
	eq(p.runner.props[PS_TDP_KEY]["data"], 17.0, "TDP untouched")
	ok(not FileAccess.file_exists(root + "/power_before.json"), "the stale record is dropped")
	ok(p.record_before(), "and a new boot notes its own")
	eq(JSON.parse_string(FileAccess.get_file_as_string(root + "/power_before.json"))["boot"], "boot-b", "for this boot")
	p.free()


func test_fan_mode_from_before_gamecove_goes_back_without_being_remembered() -> void:
	var root := _sys("before_fan")
	_boot(root, "boot-a")
	var p := _power("bus_claw_powerstation.json", _row("msi-claw-8-ex"), root)
	var h := root + "/sys/class/hwmon/hwmon5/"
	p.runner.exec_handler = func(argv: PackedStringArray) -> Variant:
		if argv.size() == 3 and argv[2] == "status":
			return {"code": 0, "out": "installed=yes\n"}
		if argv.size() < 5 or argv[2] != "fan":
			return 0
		for n in [1, 2]:
			if argv[4] == "auto":
				_write(h + "pwm%d_enable" % n, "2")
				continue
			var table: Array = PowerScript.FAN_TABLES[argv[4]]
			for i in range(6):
				_write(h + "pwm%d_auto_point%d_pwm" % [n, i + 1], str(int((int(table[i]) * 255 + 50) / 100)))
			_write(h + "pwm%d_enable" % n, "1")
		return 0
	var was: String = p.state()["fan_mode"]
	ok(was != "" and was != "quiet", "the fan mode before GameCove: " + was)
	ok(p.record_before(), "noted")
	ok(p.set_fan_mode("quiet"), "GameCove's fan mode")
	ok(p.restore_before(), "put back")
	eq(p.read_fan_sysfs(), was, "the hardware is in the mode from before")
	ok(FileAccess.get_file_as_string(root + "/power.cfg").contains("fan_mode=\"quiet\""), "GameCove still remembers quiet as the user's choice")
	p.free()


func test_leaving_stops_every_writer_until_cancelled() -> void:
	var root := _sys("leaving")
	_boot(root, "boot-a")
	var p := _power("bus_claw_powerstation.json", _row("msi-claw-8-ex"), root)
	ok(p.set_tdp(17.0), "a TDP of ours")
	ok(p.autotune_start("steam:1"), "Auto TDP running")
	ok(p.prepare_leave(), "a session switch begins")
	ok(not p._autotune_on, "Auto TDP stopped first")
	p.runner.calls.clear()
	p.request_feed(30.0, 12.0)
	p.source_tick()
	p._thermald_held = true
	eq(p.guard_check(), -1, "the thermal guard doesn't step")
	ok(not p.hold_charge(), "no charge hold")
	p._thermald_checked = false
	p._hold_thermald()
	eq(p.runner.calls.filter(func(c): return c.contains("set-property") or c.begins_with("pkexec")), [], "nothing writes while leaving")
	ok(p.cancel_leave(), "the switch didn't happen")
	ok(not p.leaving, "writing again")
	eq(p.runner.props[PS_TDP_KEY]["data"], 17.0, "with our own value in place")
	ok(not p.cancel_leave(), "only once")
	p.free()


func test_restore_baseline_run_ends_with_the_values_from_before() -> void:
	var profiles := FileAccess.get_file_as_string("res://scripts/controls/profiles.gd")
	ok(profiles.contains("power.request_restore_before(quit)"), "--restore-baseline must end with Power.restore_before()")
	var power := FileAccess.get_file_as_string("res://scripts/device/power.gd")
	ok(power.find("record_before()   # before restore()") < power.find("\trestore()\n\t# always:"), "the record is taken before restore() writes GameCove's values")
