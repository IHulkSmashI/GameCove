extends "res://tests/test_case.gd"
## One drive, several handhelds: Handheld Daemon (hhd) as the controller and TDP
## service, per-device settings and their one-time migration, and per-game
## upscaler choices resolved per GPU. Fakes only: fake_hhd.gd for hhd's HTTP
## API, fake busctl runners, files under user://.

const ControllerScript := preload("res://scripts/input/controller.gd")
const PowerScript := preload("res://scripts/device/power.gd")
const LauncherScript := preload("res://scripts/launch/launcher.gd")
const LaunchEnv := preload("res://scripts/launch/launch_env.gd")
const DeviceScript := preload("res://scripts/device/device.gd")
const Hhd := preload("res://scripts/input/hhd.gd")
const PerDevice := preload("res://scripts/device/per_device.gd")
const FakeHhd := preload("res://tests/fixtures/system/fake_hhd.gd")
const SysFake := preload("res://tests/fixtures/system/fake_runner.gd")
const PowerFake := preload("res://tests/fixtures/power/fake_runner.gd")


func _dir(test_name: String) -> String:
	var d := ProjectSettings.globalize_path("user://test_multidevice/" + test_name)
	_rmdir(d)
	DirAccess.make_dir_recursive_absolute(d)
	return d


func _rmdir(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.include_hidden = true
	for f in d.get_files():
		DirAccess.remove_absolute(path + "/" + f)
	for sub in d.get_directories():
		_rmdir(path + "/" + sub)
	DirAccess.remove_absolute(path)


func _row(id: String) -> Dictionary:
	for d in DeviceScript.load_table():
		if d.get("id", "") == id:
			return d
	return {}


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


# ---- hhd client ------------------------------------------------------------------

func test_hhd_reads_capabilities() -> void:
	var st := FakeHhd.ally_state()
	eq(Hhd.controller_key(st), "rog_ally")
	eq(Hhd.capabilities(st), {"guide_qam": true, "intercept": false, "paddles": "mode", "gyro": true,
		"rumble": true, "rgb": true, "per_game": true})
	var gos := FakeHhd.legion_go_s_state()
	var caps := Hhd.capabilities(gos)
	eq(caps["paddles"], "", "Xbox Elite output: no paddles_as")
	ok(caps["gyro"], "imu switch")
	ok(not caps["rgb"] and not caps["rumble"], "no LEDs or limits in this state")
	eq(Hhd.capabilities({}), {"guide_qam": false, "intercept": false, "paddles": "", "gyro": false,
		"rumble": false, "rgb": false, "per_game": false}, "nothing from an empty state")


func test_hhd_tdp_paths() -> void:
	var a := Hhd.tdp_info(FakeHhd.ally_state())
	eq([a["driver"], a["value"], a["enabled"]], ["asus", 15.0, true])
	eq(Hhd.tdp_patch(a, 20), {"tdp": {"asus": {"tdp_v2": {"mode": "custom", "custom": {"tdp": 20}}}}})
	var l := Hhd.tdp_info(FakeHhd.legion_go_s_state())
	eq([l["driver"], l["value"], l["mode"]], ["lenovo", -1.0, "performance"], "a preset mode has no known watts")
	eq(Hhd.tdp_patch(l, 12), {"tdp": {"lenovo": {"tdp": {"mode": "custom", "custom": {"tdp": 12}}}}})
	var smu := Hhd.tdp_info({"tdp": {"qam": {"tdp": 18}}, "hhd": {"settings": {"tdp_enable": false}}})
	eq([smu["driver"], smu["value"], smu["enabled"]], ["smu", 18.0, false])
	eq(Hhd.tdp_patch(smu, 9), {"tdp": {"qam": {"tdp": 9}}})
	eq(Hhd.tdp_info({"controllers": {}}), {}, "no TDP plugin")


func test_hhd_token_and_errors() -> void:
	var d := _dir("token")
	var fake := FakeHhd.new(FakeHhd.ally_state())
	fake.token = "abc123"
	var h := Hhd.new()
	h.transport = fake
	h.root = d
	h.home = d + "/home"
	eq(h.get_state(), null, "401 without the token")
	_write(d + "/tmp/hhd/token", "abc123\n")
	ok(h.get_state() is Dictionary, "token from /tmp/hhd/token")
	eq(h.version(), 5)
	fake.down = true
	eq(h.version(), 0, "no daemon")
	eq(Hhd.solid_rgb(Color.from_hsv(0.5, 1.0, 1.0), 0.4), {"mode": "solid", "solid": {"hue": 180, "saturation": 100, "brightness": 40}})


# ---- Controller on hhd -------------------------------------------------------------

func _hhd_ctl(test_name: String, st: Dictionary) -> Array:
	var fake := FakeHhd.new(st)
	var c: Node = ControllerScript.new()
	c.device_id = "asus-rog-ally"
	c.setup(SysFake.new(), _dir(test_name), fake)
	c.refresh()
	return [c, fake]


func test_controller_picks_hhd_without_inputplumber() -> void:
	var t := _hhd_ctl("ctl_hhd", FakeHhd.ally_state())
	var c: Node = t[0]
	var st: Dictionary = c.state()
	eq(st["backend"], "hhd")
	eq(st["capabilities"]["rgb"], true, "RGB through hhd")
	eq(st["capabilities"]["paddles"], "mode")
	eq(st["capabilities"]["intercept"], false)
	eq(st["gyro_modes"], ["off", "on"])
	eq(st["profile"]["gyro"], "on")
	eq(st["paddle_mode"], "steam_input")
	eq(st["rgb"], {"hue": 30, "saturation": 100, "brightness": 50})
	eq(st["rumble"], true, "default limits: vibration on")
	eq(st["supported"]["led"], true)
	c.free()


func test_controller_hhd_setters() -> void:
	var t := _hhd_ctl("ctl_hhd_set", FakeHhd.ally_state())
	var c: Node = t[0]
	var fake: RefCounted = t[1]
	var applied: Array = []
	c.applied.connect(func(s, okk): applied.append([s, okk]))
	c.set_gyro_mode("off")
	eq(fake.state["controllers"]["rog_ally"]["imu"], false, "gyro off in hhd")
	eq(c.state()["profile"]["gyro"], "off")
	c.set_paddle_mode("disabled")
	eq(fake.state["controllers"]["rog_ally"]["controller_mode"]["dualsense"]["paddles_as"], "disabled")
	c.set_rumble(false)
	eq(fake.state["controllers"]["rog_ally"]["limits"]["mode"], "manual")
	eq(int(fake.state["controllers"]["rog_ally"]["limits"]["manual"]["vibration"]), 0)
	eq(c.state()["rumble"], false)
	ok(c.set_led(Color.from_hsv(0.0, 1.0, 1.0), 1.0), "LED queued")
	eq(c.state()["rgb"], {"hue": 0, "saturation": 100, "brightness": 100})
	c.set_paddle("LeftPaddle1", "South")
	eq(applied, [["gyro", true], ["paddle", true], ["rumble", true], ["led", true], ["paddle", false]],
		"per-paddle remap isn't an hhd feature")
	c.free()


func test_controller_hhd_per_game() -> void:
	var t := _hhd_ctl("ctl_hhd_game", FakeHhd.ally_state())
	var c: Node = t[0]
	var fake: RefCounted = t[1]
	c.set_gyro_mode("off")
	c.set_game_profile("steam:1", true)
	ok(c.has_game_profile("steam:1"), "saved")
	ok(c.game_profile_path("steam:1").ends_with("/asus-rog-ally/steam_3A1.hhd.json"), "per device, hhd file: " + c.game_profile_path("steam:1"))
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(c.game_profile_path("steam:1")))
	ok(not saved.has("tdp") and not saved.has("hhd"), "only controller and LEDs are kept")
	c.set_gyro_mode("on")
	c.start_game("steam:1")
	eq(fake.state["controllers"]["rog_ally"]["imu"], false, "the game's layout")
	c.end_game()
	eq(fake.state["controllers"]["rog_ally"]["imu"], true, "everyday layout back")
	c.free()


func test_hhd_keyboard_shortcuts() -> void:
	var k := InputEventKey.new()
	k.pressed = true
	k.ctrl_pressed = true
	k.keycode = KEY_1
	eq(ControllerScript.hhd_key_action(k), "home", "Ctrl+1 (hhd's Steam menu)")
	k.keycode = KEY_2
	eq(ControllerScript.hhd_key_action(k), "quick_menu", "Ctrl+2 (hhd's QAM)")
	k.ctrl_pressed = false
	eq(ControllerScript.hhd_key_action(k), "", "plain 2")


func test_controller_none_when_nothing_answers() -> void:
	var c: Node = ControllerScript.new()
	c.setup(SysFake.new(), _dir("ctl_none"))
	c.refresh()
	eq(c.state()["backend"], "none")
	ok(not c.state()["capabilities"].values().any(func(v): return v is bool and v), "nothing offered")
	ok(not c.set_led(Color.RED, 1.0), "no LEDs")
	c.free()


func test_controller_layouts_per_device() -> void:
	var home := _dir("ctl_layouts")
	var root := home + "/.config/inputplumber/profiles/gamecove"
	_write(root + "/default.yaml", "{\"version\": 1}\n")
	_write(root + "/steam_1.yaml", "{\"version\": 1}\n")
	var c: Node = ControllerScript.new()
	c.device_id = "msi-claw-8-ex"
	c.setup(SysFake.new(), home)
	eq(c.default_profile_path(), root + "/msi-claw-8-ex/default.yaml")
	ok(FileAccess.file_exists(root + "/msi-claw-8-ex/default.yaml"), "old layout moved to the device that started first")
	ok(FileAccess.file_exists(root + "/msi-claw-8-ex/steam_1.yaml"), "per-game layout too")
	ok(not FileAccess.file_exists(root + "/default.yaml"), "moved, not copied")
	c.set_device("asus-rog-ally")
	ok(not c.has_game_profile("steam:1"), "the Ally doesn't get the Claw's layouts")
	eq(c.default_profile_path(), root + "/asus-rog-ally/default.yaml")
	c.free()


# ---- Power on hhd ------------------------------------------------------------------

func _hhd_power(test_name: String, st: Dictionary, row_id := "asus-rog-ally") -> Array:
	var root := _dir(test_name)
	var fake := FakeHhd.new(st)
	var p: Node = PowerScript.new()
	p.setup(PowerFake.from_fixture(fixture("power/bus_claw_powerstation.json")), _row(row_id), root, fake)
	p.config_path = root + "/power.cfg"
	p.detect()
	return [p, fake]


func test_power_defers_to_hhd() -> void:
	var t := _hhd_power("pw_hhd", FakeHhd.ally_state())
	var p: Node = t[0]
	var fake: RefCounted = t[1]
	var s: Dictionary = p.state()
	eq(s["backend"], "hhd", "hhd manages TDP: no PowerStation behind its back")
	eq(s["tdp_w"], 15.0)
	eq(s["supported"]["fan"], false, "fan curves stay hhd's")
	eq(s["supported"]["charge_limit"], false, "charge limit stays hhd's")
	ok(p.set_tdp(20.0), "TDP through hhd")
	eq(int(fake.state["tdp"]["asus"]["tdp_v2"]["custom"]["tdp"]), 20)
	ok(not p.runner.calls.any(func(c): return "set-property org.shadowblip.PowerStation" in c), "PowerStation never written")
	fake.clamp_tdp = 22
	ok(not p.set_tdp(25.0), "hhd kept a lower value: not confirmed")
	p.free()


func test_power_hhd_preset_mode_switches_to_custom() -> void:
	var t := _hhd_power("pw_hhd_lgs", FakeHhd.legion_go_s_state(), "lenovo-legion-go-s-z1e")
	var p: Node = t[0]
	var fake: RefCounted = t[1]
	eq(p.state()["backend"], "hhd")
	ok(p.set_profile("battery"), "a profile writes custom watts")
	eq(fake.state["tdp"]["lenovo"]["tdp"]["mode"], "custom")
	p.free()


func test_power_ignores_hhd_without_tdp() -> void:
	var t := _hhd_power("pw_hhd_off", FakeHhd.ally_state(false), "msi-claw-8-ex")
	var p: Node = t[0]
	eq(p.state()["backend"], "powerstation", "hhd's TDP plugin off: the usual services")
	p.free()


# ---- per-device power settings ----------------------------------------------------------

func test_power_settings_per_device_and_migration() -> void:
	var root := _dir("pw_cfg")
	var cfg_path := root + "/power.cfg"
	var old := ConfigFile.new()
	old.set_value("profile", "battery", "custom")
	old.set_value("custom_w", "battery", 31.0)
	old.set_value("device", "charge_limit", 80)
	old.save(cfg_path)
	var claw: Node = PowerScript.new()
	claw.setup(PowerFake.from_fixture(fixture("power/bus_claw_powerstation.json")), _row("msi-claw-8-ex"), root)
	claw.config_path = cfg_path
	eq(claw._recall("profile", "battery", ""), "custom", "old values belong to the device that reads them first")
	var cfg := ConfigFile.new()
	cfg.load(cfg_path)
	ok(not cfg.has_section("profile") and not cfg.has_section("device"), "old sections gone")
	eq(cfg.get_value("custom_w@msi-claw-8-ex", "battery"), 31.0)
	eq(cfg.get_value("device@msi-claw-8-ex", "charge_limit"), 80)
	var ally: Node = PowerScript.new()
	ally.setup(PowerFake.from_fixture(fixture("power/bus_claw_powerstation.json")), _row("asus-rog-ally"), root)
	ally.config_path = cfg_path
	eq(ally._recall("custom_w", "battery", -1.0), -1.0, "31 W from the Claw never reaches the Ally")
	eq(ally._recall("device", "charge_limit", -1), -1, "nor its charge limit")
	ally._remember("profile", "battery", "battery")
	eq(claw._recall("profile", "battery", ""), "custom", "the Claw keeps its own")
	claw.free()
	ally.free()


func test_per_device_keys() -> void:
	eq(PerDevice.key("MSI Claw/8"), "msi-claw-8")
	eq(PerDevice.key(""), "unknown")
	eq(PerDevice.section("profile", "asus-rog-ally"), "profile@asus-rog-ally")


# ---- launch settings across GPUs ----------------------------------------------------------

func test_upscaler_resolves_per_gpu() -> void:
	var proton := {"flavour": "ge", "major": 10, "name": "GE-Proton10-20"}
	var xess := {"upscaler": "xess", "frame_gen": false, "low_latency": false}
	var on_ally := LaunchEnv.compose(xess, {"gpu_family": "amd-rdna3", "xmx": false}, proton, {})
	eq(on_ally["upscaler"], LaunchEnv.resolve_upscaler("auto", "amd-rdna3", false, proton), "XeSS picked on the Claw: Auto on the Ally")
	ok(on_ally["notes"].any(func(n): return "XeSS was picked on an Intel handheld" in n), "with a note")
	var on_claw := LaunchEnv.compose(xess, {"gpu_family": "intel-xe3", "xmx": true}, proton, {"xess_xmx": true})
	eq(on_claw["upscaler"], "xess", "still XeSS on the Claw")
	var auto := {"upscaler": "auto"}
	eq(LaunchEnv.compose(auto, {"gpu_family": "intel-xe3", "xmx": true}, proton, {"xess_xmx": true})["upscaler"], "xess", "auto: XeSS on Intel Xe with XMX")
	eq(LaunchEnv.compose(auto, {"gpu_family": "intel-xe3", "xmx": true}, proton, {"xess_xmx": false})["upscaler"], "off", "auto on Intel without the XMX driver: off")
	eq(LaunchEnv.choice_for_gpu("fsr", ""), ["off", "Unknown GPU: upscaler off."])
	eq(LaunchEnv.choice_for_gpu("fsr", "intel-xe3")[0], "fsr", "FSR on Intel stays (routed to XeSS when XMX is ready)")


func test_measured_fps_per_device() -> void:
	var d := _dir("launch_fps")
	_write(d + "/launch.json", JSON.stringify({"version": 1, "games": {}, "measured": {"steam:1": 52}}))
	var l: Node = LauncherScript.new()
	l.settings_path = d + "/launch.json"
	l.device_profile = _row("msi-claw-8-ex")
	eq(l.base_fps("steam:1"), 52, "old measurement belongs to the device that loads it first")
	l.record_base_fps("steam:2", 61)
	l.device_profile = _row("asus-rog-ally")
	eq(l.base_fps("steam:1"), -1, "the Ally hasn't measured it")
	l.record_base_fps("steam:1", 38)
	l.reload()
	l.device_profile = _row("msi-claw-8-ex")
	eq(l.base_fps("steam:1"), 52, "kept per device on disk")
	eq(l.base_fps("steam:2"), 61)
	l.free()


# ---- gamecove-selftest's app part --------------------------------------------------------------

func test_device_selftest_lines() -> void:
	var d := _dir("selftest")
	_write(d + "/sys/class/dmi/id/sys_vendor", "ASUSTeK COMPUTER INC.\n")
	_write(d + "/sys/class/dmi/id/board_name", "RC71L\n")
	_write(d + "/sys/class/dmi/id/product_name", "ROG Ally RC71L_RC71L\n")
	_write(d + "/sys/class/dmi/id/product_serial", "SERIAL-SHOULD-NOT-SHOW\n")
	var dev: Node = DeviceScript.new()
	dev.root = d
	dev.detect()
	var lines: Array = dev.selftest_lines()
	ok("selftest.device.id=asus-rog-ally" in lines, "device id line")
	ok(lines.all(func(l): return str(l).begins_with("selftest.") and "=" in str(l)), "key=value lines")
	ok(not lines.any(func(l): return "SERIAL" in str(l)), "no serial number")
	dev.free()
