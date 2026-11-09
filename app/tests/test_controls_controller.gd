extends "res://tests/test_case.gd"
## Controller Controls (providers/controller.gd) on fake InputPlumber, hhd and
## sysfs LED trees, one handheld at a time.

const Provider := preload("res://scripts/controls/providers/controller.gd")
const ControlsScript := preload("res://scripts/controls/controls.gd")
const Fakes := preload("res://tests/fixtures/controller/fakes.gd")
const DeviceScript := preload("res://scripts/device/device.gd")
const IpEdit := preload("res://scripts/controls/input/ip_edit.gd")

const CLAW_CAPS := ["Gamepad:Button:South", "Gamepad:Button:East", "Gamepad:Button:North", "Gamepad:Button:West",
	"Gamepad:Button:Guide", "Gamepad:Button:QuickAccess", "Gamepad:Button:LeftPaddle1", "Gamepad:Button:RightPaddle1",
	"Gamepad:Axis:LeftStick", "Gamepad:Axis:RightStick", "Gamepad:Trigger:LeftTrigger", "Gamepad:Trigger:RightTrigger",
	"Gyroscope:Center", "Accelerometer:Center"]
const LEGION_CAPS := ["Gamepad:Button:South", "Gamepad:Button:East", "Gamepad:Button:Guide", "Gamepad:Button:QuickAccess",
	"Gamepad:Button:LeftPaddle1", "Gamepad:Button:LeftPaddle2", "Gamepad:Button:RightPaddle1", "Gamepad:Button:RightPaddle2",
	"Gamepad:Axis:RightStick", "Gyroscope:Left", "Gyroscope:Right",
	"Touchpad:CenterPad:Touch:Motion", "Touchpad:CenterPad:Touch:Button:Press"]


func _row(id: String) -> Dictionary:
	for r in DeviceScript.load_table():
		if r.get("id") == id:
			return r
	return {}


func _root(test_name: String) -> String:
	var d := ProjectSettings.globalize_path("user://test_ctl_controller/" + test_name)
	_rmdir(d)
	DirAccess.make_dir_recursive_absolute(d + "/home")
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


## [registry, fakes]; detect_all done.
func _setup(f: RefCounted, row: Dictionary) -> Node:
	var reg: Node = ControlsScript.new()
	reg.sync_mode = true
	var c: Dictionary = f.ctx(row)
	reg.setup(c)
	var p := Provider.new()
	p.setup(c)
	reg.register_provider(p)
	reg.detect_all()
	return reg


func _c(reg: Node, id: String) -> RefCounted:
	var c: RefCounted = reg.control(id)
	ok(c != null, "control %s exists" % id)
	return c


func _w(reg: Node, id: String, v: Variant) -> bool:
	var c := _c(reg, id)
	return c != null and c.write(v)


func _avail(reg: Node, id: String) -> bool:
	var c := _c(reg, id)
	return c != null and c.available


func _reason(reg: Node, id: String) -> String:
	var c := _c(reg, id)
	return c.reason if c != null else "?"


func _value(reg: Node, id: String) -> Variant:
	var c := _c(reg, id)
	c.detect()
	return c.read()


func _opt_values(reg: Node, id: String) -> Array:
	return _c(reg, id).options.map(func(o): return o["value"])


# ---- MSI Claw 8 EX on InputPlumber -------------------------------------------------------

func _claw(test_name: String) -> Array:
	var f: RefCounted = Fakes.new(_root(test_name))
	f.with_ip("MSI Claw 8 EX", CLAW_CAPS)
	Fakes.write(f.sys_root + "/usr/share/inputplumber/devices/50-msi_claw8_ex_ai_cg3em.yaml",
		"version: 1\nkind: CompositeDevice\nname: MSI Claw 8 EX\ntarget_devices:\n  - xbox-elite\n  - mouse\n  - keyboard\n")
	return [_setup(f, _row("msi-claw-8-ex")), f]


func test_claw_controls_and_reasons() -> void:
	var t := _claw("claw_reasons")
	var reg: Node = t[0]
	for id in ["controller.gyro", "controller.emulation", "controller.paddle.LeftPaddle1", "controller.paddle.RightPaddle1",
			"controller.nintendo_layout", "controller.desktop_mode", "controller.desktop_speed", "controller.rumble",
			"controller.rumble_test", "controller.reset_layout"]:
		ok(_avail(reg, id), id + " available on the Claw with InputPlumber (" + _reason(reg, id) + ")")
	eq(_reason(reg, "controller.gyro_source"), "This handheld has one gyro")
	eq(_reason(reg, "controller.gyro_aim"), Provider.R_GYRO_AIM)
	eq(_reason(reg, "controller.trackpad"), Provider.R_NO_PAD)
	eq(_reason(reg, "controller.rumble_strength"), "InputPlumber can only turn rumble on or off")
	eq(_reason(reg, "controller.deadzone_left_stick"), Provider.R_DEADZONE_IP)
	eq(_reason(reg, "controller.paddles_as"), "With InputPlumber each back button is set on its own")
	eq(_reason(reg, "controller.led_effect"), Provider.R_RGB_BACKEND, "Claw has RGB but no driver here")
	eq(_reason(reg, "controller.gyro_accel"), Provider.R_GYRO_FIX)
	eq(_c(reg, "controller.paddle.LeftPaddle1").title, "Back button M2", "label from the button profile")
	for c in reg.list("controller"):
		ok(c.available or c.reason != "", c.id + " has a reason when unavailable")
	reg.free()


func test_claw_gyro_off_drops_the_source_and_saves() -> void:
	var t := _claw("claw_gyro")
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	eq(_value(reg, "controller.gyro"), true)
	ok(_w(reg, "controller.gyro", false), "gyro off")
	var m: Array = f.profile["mapping"]
	eq(m.size(), 1)
	eq(m[0]["source_event"], {"gyroscope": {"name": "Center"}})
	eq(m[0]["target_events"], [])
	eq(_value(reg, "controller.gyro"), false)
	var saved: String = f.sys_root + "/home/.config/inputplumber/profiles/gamecove/msi-claw-8-ex/default.yaml"
	ok(FileAccess.file_exists(saved), "everyday layout saved where the Controller service loads it")
	ok("GameCove Gyro Off Center" in FileAccess.get_file_as_string(saved), "with the gyro mapping")
	ok(_w(reg, "controller.gyro", true), "gyro on")
	eq((f.profile["mapping"] as Array).size(), 0)
	eq(_value(reg, "controller.gyro"), true)
	reg.free()


func test_claw_legacy_gyro_mapping_is_replaced() -> void:
	var t := _claw("claw_legacy")
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	f.profile["mapping"] = [{"name": "GameCove Gyro Mouse", "source_event": {"gamepad": {"gyro": {"name": "Gyro1"}}},
		"target_events": [{"mouse": {"motion": {}}}]}]
	eq(_value(reg, "controller.gyro"), true, "the old form is ignored by InputPlumber: gyro passes")
	ok(_w(reg, "controller.gyro", true), "on")
	eq((f.profile["mapping"] as Array).size(), 0, "legacy mapping gone")
	reg.free()


func test_claw_paddles_and_buttons() -> void:
	var t := _claw("claw_paddles")
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	ok(_w(reg, "controller.paddle.LeftPaddle1", "South"), "M2 -> A")
	eq(_value(reg, "controller.paddle.LeftPaddle1"), "South")
	ok(_w(reg, "controller.paddle.RightPaddle1", "disabled"), "M1 off")
	eq(_value(reg, "controller.paddle.RightPaddle1"), "disabled")
	ok(_w(reg, "controller.paddle.RightPaddle1", "mouse:Left"), "M1 -> click")
	eq(_value(reg, "controller.paddle.RightPaddle1"), "mouse:Left")
	ok(_w(reg, "controller.paddle.RightPaddle1", "KeyEsc"), "M1 -> Esc")
	ok(not _w(reg, "controller.paddle.RightPaddle1", "rm -rf"), "junk refused by coerce")
	ok(_w(reg, "controller.paddle.LeftPaddle1", ""), "back to itself")
	eq(_value(reg, "controller.paddle.LeftPaddle1"), "")
	eq((f.profile["mapping"] as Array).size(), 1, "only the Esc mapping left")
	reg.free()


func test_claw_load_failure_and_bad_readback() -> void:
	var t := _claw("claw_fail")
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	f.refuse_load = true
	ok(not _w(reg, "controller.nintendo_layout", true), "InputPlumber refused")
	eq((f.profile["mapping"] as Array).size(), 0, "nothing changed")
	ok(not FileAccess.file_exists(f.sys_root + "/home/.config/inputplumber/profiles/gamecove/msi-claw-8-ex/default.yaml"), "nothing saved")
	f.refuse_load = false
	ok(_w(reg, "controller.paddle.LeftPaddle1", "South"), "a good change")
	f.ignore_load = true
	var loads_before: int = f.loads.size()
	ok(not _w(reg, "controller.nintendo_layout", true), "accepted but not applied: reported as failed")
	eq(f.loads.size(), loads_before + 2, "then the previous profile is sent back")
	eq(IpEdit.button_target(JSON.parse_string(f.loads[f.loads.size() - 1]), "LeftPaddle1"), "South", "previous profile restored")
	reg.free()


func test_claw_nintendo_desktop_emulation_reset() -> void:
	var t := _claw("claw_misc")
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	ok(_w(reg, "controller.nintendo_layout", true), "swap")
	eq(_value(reg, "controller.nintendo_layout"), true)
	eq(IpEdit.button_target(f.profile, "South"), "", "swap mappings don't read as remaps")
	ok(_w(reg, "controller.desktop_speed", 1500.0), "speed stored while off")
	ok(_w(reg, "controller.desktop_mode", true), "mouse mode")
	eq(IpEdit.desktop_speed(f.profile), 1500)
	ok("mouse" in f.profile["target_devices"] and "xbox-elite" in f.profile["target_devices"], "mouse target added, gamepad kept")
	ok(_w(reg, "controller.desktop_speed", 2000.0), "speed while on")
	eq(IpEdit.desktop_speed(f.profile), 2000)
	eq(_value(reg, "controller.emulation"), "default")
	ok(_w(reg, "controller.emulation", "ds5-edge"), "DualSense Edge")
	eq(f.profile["target_devices"][0], "ds5-edge")
	ok("mouse" in f.profile["target_devices"], "non-gamepad targets kept")
	eq(_value(reg, "controller.emulation"), "ds5-edge")
	ok(not _w(reg, "controller.emulation", "steam-controller-9000"), "unknown type refused")
	ok(_w(reg, "controller.emulation", "default"), "back to the device config's targets")
	eq(f.profile["target_devices"], ["xbox-elite", "mouse", "keyboard"])
	eq(_value(reg, "controller.emulation"), "default")
	ok(_w(reg, "controller.reset_layout", true), "reset")
	ok(not (f.profile["mapping"] as Array).any(func(m): return str(m["name"]).begins_with("GameCove")), "no GameCove mappings left")
	reg.free()


## The live Claw: OpenGamepadUI had set TargetDevices deck-uhid ("Valve Steam Deck
## Controller") + mouse + keyboard with SetTargetDevices; the device config's own targets
## are xbox-elite, mouse, keyboard. GameCove read "default", and a probe's put-back to
## "default" replaced the user's Steam Deck controller with an Xbox Elite pad.
func test_claw_live_emulation_reads_and_restores_the_live_targets() -> void:
	var f: RefCounted = Fakes.new(_root("claw_live_emulation"))
	f.with_ip("MSI Claw 8 EX", CLAW_CAPS)
	Fakes.write(f.sys_root + "/usr/share/inputplumber/devices/50-msi_claw8_ex_ai_cg3em.yaml",
		"version: 1\nkind: CompositeDevice\nname: MSI Claw 8 EX\ntarget_devices:\n  - xbox-elite\n  - mouse\n  - keyboard\n")
	var live := {"targets": ["deck-uhid", "mouse", "keyboard"]}
	var names := {"deck-uhid": "Valve Steam Deck Controller", "xbox-elite": "Microsoft X-Box One Elite pad",
		"xbox-series": "Microsoft Xbox Series S|X Controller", "mouse": "InputPlumber Mouse", "keyboard": "InputPlumber Keyboard"}
	var inner: Callable = f.runner.handler
	f.runner.handler = func(cmd: String) -> Variant:
		var r: Variant = inner.call(cmd)
		if cmd.ends_with("org.freedesktop.DBus.ObjectManager GetManagedObjects") and r is Dictionary:
			var j: Dictionary = JSON.parse_string(r["out"])
			var objs: Dictionary = j["data"][0]
			var paths := []
			for i in live["targets"].size():
				var tp := "/org/shadowblip/InputPlumber/devices/target/%s%d" % [live["targets"][i], i]
				paths.append(tp)
				objs[tp] = {"org.shadowblip.Input.Target": {"Name": {"type": "s", "data": names.get(live["targets"][i], "")},
					"DeviceType": {"type": "s", "data": live["targets"][i]}}}
			objs[Fakes.DEV][Fakes.DEV_IFACE]["TargetDevices"] = {"type": "as", "data": paths}
			return {"code": 0, "out": JSON.stringify(j)}
		if cmd.contains(" LoadProfileFromYaml s ") and r is Dictionary and int(r["code"]) == 0:
			var p: Variant = JSON.parse_string(cmd.get_slice(" LoadProfileFromYaml s ", 1))
			if p is Dictionary and p.get("target_devices") is Array:
				live["targets"] = (p["target_devices"] as Array).duplicate()
		return r
	var reg := _setup(f, _row("msi-claw-8-ex"))
	eq(_value(reg, "controller.emulation"), "deck", "deck-uhid is the Steam Deck choice, not default")
	ok(_w(reg, "controller.emulation", "xbox-series"), "probe: Xbox Series")
	eq(live["targets"], ["xbox-series", "mouse", "keyboard"])
	ok(_w(reg, "controller.emulation", "deck"), "put back")
	eq(live["targets"], ["deck-uhid", "mouse", "keyboard"], "the exact list that was there")
	eq(_value(reg, "controller.emulation"), "deck")
	ok(_w(reg, "controller.emulation", "default"), "default")
	eq(live["targets"], ["xbox-elite", "mouse", "keyboard"], "the device config's own")
	eq(_value(reg, "controller.emulation"), "default", "default only when equal to the config's targets")
	reg.free()


func test_claw_rumble() -> void:
	var t := _claw("claw_rumble")
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	eq(_value(reg, "controller.rumble"), true)
	ok(_w(reg, "controller.rumble", false), "off")
	eq(f.rumble, false)
	ok(_w(reg, "controller.rumble_test", true), "buzz")
	eq(f.buzzes, 1)
	reg.free()


func test_claw_gyro_fix_states() -> void:
	var f: RefCounted = Fakes.new(_root("claw_fix"))
	f.with_ip("MSI Claw 8 EX", CLAW_CAPS.filter(func(c): return not str(c).begins_with("Gyroscope")))
	var reg := _setup(f, _row("msi-claw-8-ex"))
	eq(_reason(reg, "controller.gyro"), Provider.R_GYRO_FIX, "no gyro until the fix")
	reg.free()
	var o: String = f.sys_root + "/etc/inputplumber/devices.d/50-msi_claw8_ex_ai_cg3em.yaml"
	Fakes.write(o, "  - group: imu\n    iio:\n      - name: gyro_3d")
	f.ip_caps = CLAW_CAPS
	reg = _setup(f, _row("msi-claw-8-ex"))
	ok(_avail(reg, "controller.gyro_accel"), "accelerometer switch once the fix is in")
	eq(_value(reg, "controller.gyro_accel"), false)
	ok(_w(reg, "controller.gyro_accel", true), "on")
	ok("accel_3d" in FileAccess.get_file_as_string(o), "through gamecove-fix-set")
	ok(f.pkexec_calls[0].ends_with("claw8ex-gyro set accel-on"), "no-password entry point")
	reg.free()
	reg = _setup(f, _row("asus-rog-ally"))
	eq(_reason(reg, "controller.gyro_accel"), "Only on the MSI Claw 8 EX")
	reg.free()


# ---- MSI Claw 8 EX, hid-msi LED node as read live (Bazzite 45, kernel 7.2.15-ogc1.1) -------

const LIVE_LEDS := preload("res://scripts/controls/input/leds.gd")


## The node exactly as the Claw showed it: go:rgb:joystick_rings (OGC renames hid-msi's
## msi_claw: node), lights disabled, effect/multi_intensity/brightness 0666 (no root),
## enabled and speed 0644 root.
func _claw_live(test_name: String) -> Array:
	var f: RefCounted = Fakes.new(_root(test_name))
	f.with_ip("MSI Claw 8 EX", CLAW_CAPS)
	var d: String = f.led("go:rgb:joystick_rings", "red green blue", "1 90 100", 100, 21, {
		"multi_max_intensity": "100 100 100", "effect": "monocolor",
		"effect_index": "monocolor breathe chroma rainbow frostfire", "enabled": "false",
		"enabled_index": "true false", "speed": "10", "speed_range": "0-20", "trigger": "[none]"})
	for a in ["effect", "multi_intensity", "brightness"]:
		FileAccess.set_unix_permissions(d + "/" + a, 438)   # 0666
	for a in ["enabled", "speed"]:
		FileAccess.set_unix_permissions(d + "/" + a, 420)   # 0644
	return [_setup(f, _row("msi-claw-8-ex")), f]


func test_claw_live_hid_msi_leds() -> void:
	var t := _claw_live("claw_live_led")
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	var n := "/sys/class/leds/go:rgb:joystick_rings"
	for id in ["controller.led_effect", "controller.led_color", "controller.led_brightness", "controller.led_speed"]:
		ok(_avail(reg, id), id + " available (" + _reason(reg, id) + ")")
	eq(_reason(reg, "controller.led_color_2"), "This handheld's lights have one zone")
	eq(_opt_values(reg, "controller.led_effect"), ["off", "solid", "pulse", "rainbow", "spiral", "frostfire"])
	eq(_value(reg, "controller.led_effect"), "off", "enabled=false is dark")
	eq(_value(reg, "controller.led_speed"), 50.0, "10 of 0-20")
	# turning on needs enabled=true (root only): the root action does it
	ok(_w(reg, "controller.led_color", "#ff0000"), "red")
	eq(f.pkexec_calls.size(), 1, "enabled is root-only: one root action")
	eq(f.read(n + "/enabled"), "true")
	eq(f.read(n + "/multi_intensity"), "100 0 0")
	# lit now: colour, brightness, effect and off need no root
	ok(_w(reg, "controller.led_brightness", 40.0), "brightness")
	eq(f.read(n + "/brightness"), "40")
	ok(_w(reg, "controller.led_color", "#00ff00"), "green")
	eq(f.read(n + "/multi_intensity"), "0 100 0")
	ok(_w(reg, "controller.led_effect", "pulse"), "pulse")
	eq(f.read(n + "/effect"), "breathe")
	ok(_w(reg, "controller.led_effect", "off"), "off")
	eq(f.read(n + "/brightness"), "0", "dark by brightness")
	eq(f.read(n + "/enabled"), "true", "root-only enabled left alone")
	eq(_value(reg, "controller.led_effect"), "off")
	eq(f.pkexec_calls.size(), 1, "every change after the first went direct: %s" % [f.pkexec_calls])
	# speed is root-only
	ok(_w(reg, "controller.led_brightness", 60.0), "on again, direct")
	ok(_w(reg, "controller.led_effect", "rainbow"), "rainbow")
	ok(_w(reg, "controller.led_speed", 100.0), "speed through the root action")
	eq(f.read(n + "/speed"), "20")
	eq(f.pkexec_calls.size(), 2)
	reg.free()


## Real sysfs files report a size of 4096 and /proc files 0: get_file_as_string()
## returns "" for both, which hid the Claw's LED node. Two of the node's files are
## links to a real /proc file here, so the regular-file fixture reads like the device.
func test_led_node_reads_files_with_a_fake_size() -> void:
	var src := "/proc/sys/kernel/pid_max"
	if not FileAccess.file_exists(src):
		ok(true, "no /proc here")
		return
	var f: RefCounted = Fakes.new(_root("led_fake_size"))
	var d: String = f.led("go:rgb:joystick_rings", "red green blue", "1 90 100", 100, 21)
	for a in ["max_brightness", "brightness"]:
		DirAccess.remove_absolute(d + "/" + a)
		eq(DirAccess.open(d).create_link(src, d + "/" + a), OK, "link " + a)
	var want := int(LIVE_LEDS._read(src))
	var nodes: Array = LIVE_LEDS.scan(f.sys_root)
	eq(nodes.size(), 1, "the node is found")
	if nodes.size() == 1:
		eq(int(nodes[0]["max"]), want, "max_brightness read to its real end")
	ok(want > 0, "pid_max read: %d" % want)


# ---- Legion Go on InputPlumber with kernel LEDs ----------------------------------------------

func _legion(test_name: String) -> Array:
	var f: RefCounted = Fakes.new(_root(test_name))
	f.with_ip("Lenovo Legion Go", LEGION_CAPS)
	f.led("go:rgb:joystick_rings", "red green blue", "100 100 100", 100, 50, {
		"multi_max_intensity": "100 100 100", "effect": "monocolor", "effect_index": "monocolor breathe chroma rainbow",
		"enabled": "true", "enabled_index": "true false", "mode": "dynamic", "mode_index": "dynamic custom",
		"profile": "0", "profile_range": "1-3", "speed": "50", "speed_range": "0-100"})
	return [_setup(f, _row("lenovo-legion-go")), f]


func test_legion_gyro_sides_and_trackpad() -> void:
	var t := _legion("legion_ip")
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	eq(_opt_values(reg, "controller.gyro_source"), ["left", "right", "both"])
	eq(_value(reg, "controller.gyro_source"), "both")
	ok(_w(reg, "controller.gyro_source", "left"), "left only")
	eq(_value(reg, "controller.gyro_source"), "left")
	var m: Array = f.profile["mapping"]
	eq(m.size(), 1)
	eq(m[0]["source_event"], {"gyroscope": {"name": "Right"}}, "right sensor dropped")
	ok(_w(reg, "controller.gyro", false), "gyro off")
	eq((f.profile["mapping"] as Array).size(), 2, "both dropped")
	eq(_value(reg, "controller.gyro_source"), null)
	ok(_w(reg, "controller.gyro", true), "gyro on")
	eq((f.profile["mapping"] as Array).size(), 0, "both pass again")
	eq(_opt_values(reg, "controller.trackpad"), ["default", "RightPad", "LeftPad", "off"])
	ok(_w(reg, "controller.trackpad", "RightPad"), "as Steam's right pad")
	eq(_value(reg, "controller.trackpad"), "RightPad")
	var pm := (f.profile["mapping"] as Array).filter(func(x): return str(x["name"]).begins_with("GameCove Pad"))
	eq(pm.size(), 3, "motion, press and touch moved")
	eq(pm[0]["target_events"][0]["touchpad"]["name"], "RightPad")
	ok(_w(reg, "controller.trackpad", "off"), "off")
	eq(_value(reg, "controller.trackpad"), "off")
	ok(_w(reg, "controller.trackpad", "default"), "default")
	eq((f.profile["mapping"] as Array).size(), 0)
	eq(_c(reg, "controller.paddle.LeftPaddle1").title, "Back button Y1")
	reg.free()


func test_legion_kernel_leds_through_the_real_root_action() -> void:
	var t := _legion("legion_led")
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	var n := "/sys/class/leds/go:rgb:joystick_rings"
	ok(_avail(reg, "controller.led_color"), "colour (" + _reason(reg, "controller.led_color") + ")")
	eq(_opt_values(reg, "controller.led_effect"), ["off", "solid", "pulse", "rainbow", "spiral"])
	eq(_value(reg, "controller.led_color"), "#ffffff", "100/100 channels read as full")
	eq(_value(reg, "controller.led_brightness"), 50.0)
	ok(_w(reg, "controller.led_color", "#ff8000"), "orange")
	eq(f.read(n + "/multi_intensity"), "100 50 0", "scaled to the ring's 0-100 channels")
	eq(f.read(n + "/profile"), "3", "a valid profile first (HueSync)")
	eq(f.read(n + "/mode"), "custom", "custom mode")
	eq(f.read(n + "/effect"), "monocolor")
	eq(f.read(n + "/enabled"), "true")
	ok(f.pkexec_calls[0].ends_with("controller-led set all,ff8000,50,monocolor"), "spec: " + str(f.pkexec_calls[0]))
	ok(_w(reg, "controller.led_effect", "rainbow"), "rainbow")
	eq(f.read(n + "/effect"), "chroma", "GameCove rainbow is the kernel's chroma")
	eq(_value(reg, "controller.led_effect"), "rainbow")
	ok(_w(reg, "controller.led_speed", 80.0), "speed")
	eq(f.read(n + "/speed"), "80")
	ok(_w(reg, "controller.led_brightness", 0.0), "off by brightness")
	eq(f.read(n + "/brightness"), "0")
	eq(f.read(n + "/enabled"), "false")
	eq(_value(reg, "controller.led_effect"), "off")
	ok(_w(reg, "controller.led_brightness", 70.0), "on again")
	eq(f.read(n + "/brightness"), "70")
	eq(f.read(n + "/enabled"), "true")
	eq(_reason(reg, "controller.led_color_2"), "This handheld's lights have one zone")
	reg.free()


func test_led_refused_value_restores_the_node() -> void:
	var t := _legion("legion_led_fail")
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	var n := "/sys/class/leds/go:rgb:joystick_rings"
	# brightness becomes a directory: the write fails after colour and mode went in
	DirAccess.remove_absolute(f.sys_root + n + "/brightness")
	DirAccess.make_dir_recursive_absolute(f.sys_root + n + "/brightness")
	ok(not _w(reg, "controller.led_color", "#00ff00"), "failure reported")
	eq(f.read(n + "/multi_intensity"), "100 100 100", "colour put back")
	eq(f.read(n + "/mode"), "dynamic", "mode put back")
	reg.free()


func test_zotac_two_zones() -> void:
	var f: RefCounted = Fakes.new(_root("zotac"))
	f.with_ip("ZOTAC Gaming Zone", ["Gamepad:Button:South", "Gamepad:Button:LeftPaddle1", "Gamepad:Button:RightPaddle1",
		"Touchpad:LeftPad:Touch:Motion", "Touchpad:RightPad:Touch:Motion"])
	f.led("zotac:rgb:spectra_zone_0", "red green blue", "255 0 0", 255, 255)
	f.led("zotac:rgb:spectra_zone_1", "red green blue", "0 0 255", 255, 255)
	var reg := _setup(f, _row("zotac-zone"))
	eq(_c(reg, "controller.led_color_2").title, "Second zone colour")
	eq(_value(reg, "controller.led_color_2"), "#0000ff")
	ok(_w(reg, "controller.led_color_2", "#00ff00"), "zone 1")
	eq(f.read("/sys/class/leds/zotac:rgb:spectra_zone_1/multi_intensity"), "0 255 0")
	eq(f.read("/sys/class/leds/zotac:rgb:spectra_zone_0/multi_intensity"), "255 0 0", "zone 0 untouched")
	ok(_w(reg, "controller.led_color", "#ffffff"), "zone 0")
	eq(f.read("/sys/class/leds/zotac:rgb:spectra_zone_1/multi_intensity"), "0 255 0", "zone 1 untouched")
	eq(_opt_values(reg, "controller.trackpad"), ["default", "off"], "two pads: on or off")
	ok(_w(reg, "controller.trackpad", "off"), "both pads off")
	eq((f.profile["mapping"] as Array).size(), 6)
	reg.free()


## The original ROG Ally on SteamOS 3.10 (kernel 7.2.4-valve1-1-neptune): hid-asus-ally's
## node lists "rgb rgb rgb rgb" (one packed 0xRRGGBB per zone), brightness 128/255,
## sleep_animation, and is 0644 root: writes go through the root action.
func test_ally_live_packed_rgb_zones() -> void:
	var f: RefCounted = Fakes.new(_root("ally_live_led"))
	f.with_ip("ASUS ROG Ally", ["Gamepad:Button:South"])
	var n := "/sys/class/leds/ally:rgb:joystick_rings"
	f.led("ally:rgb:joystick_rings", "rgb rgb rgb rgb", "16744448 16744448 16744448 16744448", 255, 128,
		{"sleep_animation": "0", "sleep_animation_index": "0 1"})
	var reg := _setup(f, _row("asus-rog-ally"))
	ok(_avail(reg, "controller.led_color"), "colour (" + _reason(reg, "controller.led_color") + ")")
	eq(_value(reg, "controller.led_color"), "#ff8000", "packed 0xff8000")
	eq(_value(reg, "controller.led_brightness"), 50.0, "128 of 255")
	ok(_w(reg, "controller.led_color", "#102030"), "colour")
	eq(f.read(n + "/multi_intensity"), "1056816 1056816 1056816 1056816", "every zone gets 0x102030")
	eq(f.pkexec_calls.size(), 1, "0644 root: the root action")
	eq(f.read(n + "/sleep_animation"), "0", "never touched")
	reg.free()
	var g: RefCounted = Fakes.new(_root("ally_live_led_nohelper"), false)
	g.with_ip("ASUS ROG Ally", ["Gamepad:Button:South"])
	g.led("ally:rgb:joystick_rings", "rgb rgb rgb rgb", "0 0 0 0", 255, 128)
	var reg2 := _setup(g, _row("asus-rog-ally"))
	eq(_reason(reg2, "controller.led_color"), Provider.R_LED_HELPER, "root-only node without the helper says so")
	reg2.free()


func test_ally_twelve_channel_leds() -> void:
	var f: RefCounted = Fakes.new(_root("ally_led"))
	f.with_ip("ASUS ROG Ally", ["Gamepad:Button:South", "Gyroscope:Center"])
	var idx := " ".join(PackedStringArray(["red green blue", "red green blue", "red green blue", "red green blue"]))
	f.led("ally:rgb:joystick_rings", idx, "0 0 0 0 0 0 0 0 0 0 0 0", 255, 128)
	var reg := _setup(f, _row("asus-rog-ally"))
	ok(_w(reg, "controller.led_color", "#102030"), "colour")
	eq(f.read("/sys/class/leds/ally:rgb:joystick_rings/multi_intensity"), "16 32 48 16 32 48 16 32 48 16 32 48", "all four zones")
	eq(_opt_values(reg, "controller.led_effect"), ["off", "solid"], "no kernel effects: off and solid")
	eq(_reason(reg, "controller.led_speed"), "This handheld's effects have a fixed speed")
	reg.free()


# ---- Handheld Daemon -------------------------------------------------------------------------

func _ally_schema() -> Dictionary:
	return {
		"controllers": {"rog_ally": {"type": "container", "children": {
			"imu": {"type": "bool"},
			"nintendo_mode": {"type": "bool"},
			"controller_mode": {"type": "mode", "modes": {
				"dualsense": {"type": "container", "title": "Dualsense", "children": {
					"paddles_as": {"type": "multiple", "options": {"steam_input": "Steam Input (Edge)", "noob": "Keyboard/Overlay", "disabled": "Disabled"}}}},
				"uinput": {"type": "container", "title": "Xbox"},
				"disabled": {"type": "container", "title": "Paused"}}},
			"limits": {"type": "mode", "modes": {"default": {"type": "container"}, "manual": {"type": "container", "children": {
				"vibration": {"type": "int", "min": 0, "max": 100, "step": 20, "default": 100},
				"ls_min": {"type": "int", "min": 0, "max": 100, "step": 2, "default": 5},
				"rs_min": {"type": "int", "min": 0, "max": 100, "step": 2, "default": 5},
				"lt_min": {"type": "int", "min": 0, "max": 100, "step": 2, "default": 5},
				"rt_min": {"type": "int", "min": 0, "max": 100, "step": 2, "default": 5}}}}},
		}}},
		"rgb": {"handheld": {"type": "container", "children": {"mode": {"type": "mode", "modes": {
			"disabled": {"type": "container", "title": "Off", "children": {}},
			"solid": {"type": "container", "title": "Solid", "children": {
				"hue": {"type": "int", "min": 0, "max": 360, "step": 5}, "saturation": {"type": "int", "min": 0, "max": 100, "step": 10},
				"brightness": {"type": "int", "min": 0, "max": 100, "step": 10}}},
			"pulse": {"type": "container", "children": {
				"hue": {"type": "int", "min": 0, "max": 360, "step": 5}, "saturation": {"type": "int", "min": 0, "max": 100, "step": 10},
				"speedd": {"type": "multiple", "options": {"low": "Low", "medium": "Medium", "high": "High"}}}},
			"duality": {"type": "container", "children": {
				"hue": {"type": "int", "min": 0, "max": 360, "step": 5}, "hue2": {"type": "int", "min": 0, "max": 360, "step": 5},
				"saturation": {"type": "int"}, "brightness": {"type": "int"}}},
			"rainbow": {"type": "container", "children": {"brightnessd": {"type": "multiple", "options": {"low": "Low", "medium": "Medium", "high": "High"}}}},
		}}}}},
	}


func _ally_hhd(test_name: String) -> Array:
	var f: RefCounted = Fakes.new(_root(test_name))
	var st: Dictionary = Fakes.FakeHhd.ally_state()
	st["controllers"]["rog_ally"]["nintendo_mode"] = false
	st["controllers"]["rog_ally"]["controller_mode"]["uinput"] = {}
	st["controllers"]["rog_ally"]["limits"]["manual"] = {"vibration": 100, "ls_min": 5, "rs_min": 5, "lt_min": 5, "rt_min": 5}
	st["rgb"]["handheld"]["mode"]["pulse"] = {"hue": 0, "saturation": 100, "speedd": "medium"}
	st["rgb"]["handheld"]["mode"]["disabled"] = {}
	f.with_hhd(st, _ally_schema())
	f.led("ally:rgb:joystick_rings")   # hhd drives the LEDs: the sysfs node must be left alone
	return [_setup(f, _row("asus-rog-ally")), f]


func test_ally_hhd_controller_settings() -> void:
	var t := _ally_hhd("ally_hhd")
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	eq(_value(reg, "controller.gyro"), true)
	ok(_w(reg, "controller.gyro", false), "imu off")
	eq(f.hhd.state["controllers"]["rog_ally"]["imu"], false)
	eq(_opt_values(reg, "controller.emulation"), ["dualsense", "uinput", "disabled"], "hhd's own modes")
	ok(_w(reg, "controller.emulation", "uinput"), "Xbox")
	eq(f.hhd.state["controllers"]["rog_ally"]["controller_mode"]["mode"], "uinput")
	ok(_w(reg, "controller.emulation", "dualsense"), "DualSense")
	eq(_opt_values(reg, "controller.paddles_as"), ["steam_input", "noob", "disabled"])
	ok(_w(reg, "controller.paddles_as", "noob"), "paddles as shortcuts")
	eq(f.hhd.state["controllers"]["rog_ally"]["controller_mode"]["dualsense"]["paddles_as"], "noob")
	eq(_reason(reg, "controller.paddle.LeftPaddle1"), "Handheld Daemon sets the back buttons together (Back buttons)")
	ok(_w(reg, "controller.nintendo_layout", true), "nintendo")
	eq(f.hhd.state["controllers"]["rog_ally"]["nintendo_mode"], true)
	eq(_reason(reg, "controller.desktop_mode"), "Handheld Daemon has no mouse mode; use the touchpad or Steam's desktop layout")
	reg.free()


func test_ally_hhd_rumble_and_deadzones() -> void:
	var t := _ally_hhd("ally_hhd_limits")
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	eq(_value(reg, "controller.rumble"), true, "default limits vibrate")
	eq(_opt_values(reg, "controller.rumble_strength"), [20, 40, 60, 80, 100])
	ok(_w(reg, "controller.rumble_strength", 60), "60 %")
	eq(f.hhd.state["controllers"]["rog_ally"]["limits"]["mode"], "manual")
	eq(int(f.hhd.state["controllers"]["rog_ally"]["limits"]["manual"]["vibration"]), 60)
	ok(_w(reg, "controller.rumble", false), "off")
	eq(int(f.hhd.state["controllers"]["rog_ally"]["limits"]["manual"]["vibration"]), 0)
	eq(_value(reg, "controller.rumble_strength"), null, "off isn't a strength")
	ok(_w(reg, "controller.deadzone_left_stick", 11.0), "deadzone (snapped to 2)")
	eq(int(f.hhd.state["controllers"]["rog_ally"]["limits"]["manual"]["ls_min"]), 12)
	eq(_value(reg, "controller.deadzone_left_stick"), 12.0)
	eq(_reason(reg, "controller.rumble_test"), "Handheld Daemon can't buzz on request")
	reg.free()


func test_ally_hhd_rgb() -> void:
	var t := _ally_hhd("ally_hhd_rgb")
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	var rgb: Dictionary = f.hhd.state["rgb"]["handheld"]["mode"]
	eq(_opt_values(reg, "controller.led_effect"), ["off", "solid", "pulse", "duality", "rainbow"])
	eq(_value(reg, "controller.led_effect"), "solid")
	ok(_w(reg, "controller.led_color", "#00ff00"), "green")
	rgb = f.hhd.state["rgb"]["handheld"]["mode"]
	eq(int(rgb["solid"]["hue"]), 120)
	eq(int(rgb["solid"]["saturation"]), 100)
	eq(_value(reg, "controller.led_color"), "#00ff00")
	ok(_w(reg, "controller.led_brightness", 72.0), "brightness snapped to hhd's step")
	eq(int(f.hhd.state["rgb"]["handheld"]["mode"]["solid"]["brightness"]), 70)
	ok(_w(reg, "controller.led_effect", "pulse"), "pulse")
	ok(_w(reg, "controller.led_speed", 95.0), "speed -> high")
	eq(f.hhd.state["rgb"]["handheld"]["mode"]["pulse"]["speedd"], "high")
	ok(_w(reg, "controller.led_effect", "rainbow"), "rainbow")
	ok(not _w(reg, "controller.led_speed", 50.0), "rainbow here has no speed")
	ok(_w(reg, "controller.led_color", "#0000ff"), "colour on a colourless effect switches to solid")
	eq(f.hhd.state["rgb"]["handheld"]["mode"]["mode"], "solid")
	ok(_w(reg, "controller.led_brightness", 0.0), "0 = off")
	eq(f.hhd.state["rgb"]["handheld"]["mode"]["mode"], "disabled")
	eq(_value(reg, "controller.led_effect"), "off")
	ok(_avail(reg, "controller.led_color_2"), "duality has a second colour")
	eq(f.pkexec_calls.size(), 0, "sysfs never written while hhd drives the lights")
	reg.free()


func test_hhd_refusal_is_undone() -> void:
	var t := _ally_hhd("ally_hhd_refuse")
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	f.refuse_paths = [["controllers", "rog_ally", "limits", "manual", "ls_min"]]
	ok(not _w(reg, "controller.deadzone_left_stick", 20.0), "hhd kept its value: failure")
	var posts: Array = f.hhd.posts()
	eq(posts.size(), 2, "the change, then the undo")
	var bodies: Array = f.hhd.requests.filter(func(r): return r[0] == "POST").map(func(r): return r[3])
	eq(bodies[1], "{\"controllers\":{\"rog_ally\":{\"limits\":{\"manual\":{\"ls_min\":5},\"mode\":\"default\"}}}}", "old values sent back as ints")
	reg.free()


func test_legion_go_hhd_gyro_mode_and_touchpad() -> void:
	var f: RefCounted = Fakes.new(_root("legion_hhd"))
	f.with_hhd({"controllers": {"legion_go": {"imu": {"mode": "right"}, "nintendo_mode": false,
			"xinput": {"mode": "dualsense_edge", "dualsense_edge": {"paddles_as": "steam_input"}},
			"touchpad": {"mode": "controller"}}}},
		{"controllers": {"legion_go": {"type": "container", "children": {
			"imu": {"type": "mode", "modes": {"disabled": {"title": "Disabled"}, "left": {"title": "Left Controller"},
				"right": {"title": "Right Controller"}, "both": {"title": "Both Controllers"}}},
			"xinput": {"type": "mode", "modes": {"dualsense_edge": {"title": "Dualsense Edge", "children": {
				"paddles_as": {"type": "multiple", "options": {"steam_input": "Steam Input", "both": "Shortcuts + Touchpad"}}}},
				"uinput": {"title": "Xbox"}}},
			"touchpad": {"type": "mode", "modes": {"disabled": {"title": "Disabled"}, "emulation": {"title": "Virtual"},
				"controller": {"title": "Controller"}}}}}}})
	var reg := _setup(f, _row("lenovo-legion-go"))
	eq(_value(reg, "controller.gyro"), true)
	eq(_opt_values(reg, "controller.gyro_source"), ["left", "right", "both"])
	ok(_w(reg, "controller.gyro", false), "off")
	eq(f.hhd.state["controllers"]["legion_go"]["imu"]["mode"], "disabled")
	ok(_w(reg, "controller.gyro", true), "on again")
	eq(f.hhd.state["controllers"]["legion_go"]["imu"]["mode"], "right", "the side it had")
	ok(_w(reg, "controller.gyro_source", "both"), "both")
	eq(f.hhd.state["controllers"]["legion_go"]["imu"]["mode"], "both")
	eq(_opt_values(reg, "controller.trackpad"), ["disabled", "emulation", "controller"])
	ok(_w(reg, "controller.trackpad", "emulation"), "virtual touchpad")
	eq(f.hhd.state["controllers"]["legion_go"]["touchpad"]["mode"], "emulation")
	eq(_opt_values(reg, "controller.emulation"), ["dualsense_edge", "uinput"])
	eq(_value(reg, "controller.paddles_as"), "steam_input")
	eq(_reason(reg, "controller.led_effect"), Provider.R_RGB_BACKEND, "hhd without RGB here")
	reg.free()


func test_oxp_hhd_vibration_levels() -> void:
	var f: RefCounted = Fakes.new(_root("oxp_hhd"))
	f.with_hhd({"controllers": {"oxp": {"imu": true, "vibration_strength": "4", "controller_mode": {"mode": "uinput", "uinput": {}}}}},
		{"controllers": {"oxp": {"type": "container", "children": {"vibration_strength": {"type": "multiple",
			"options": {"v1": "1", "v2": "2", "v3": "3", "v4": "4", "v5": "5"}}}}}})
	var reg := _setup(f, _row("onexplayer-x1-amd"))
	eq(_reason(reg, "controller.rumble"), "This handheld can't turn rumble off; set its strength")
	eq(_opt_values(reg, "controller.rumble_strength"), ["v1", "v2", "v3", "v4", "v5"])
	ok(_w(reg, "controller.rumble_strength", "v2"), "level 2")
	eq(f.hhd.state["controllers"]["oxp"]["vibration_strength"], "v2")
	reg.free()


# ---- nothing running ---------------------------------------------------------------------------

func test_no_backend_every_control_explains() -> void:
	var f: RefCounted = Fakes.new(_root("none"))
	for id in ["steam-deck-oled", "asus-rog-ally", "onexplayer-g1-amd", "gpd-win-4", "msi-claw-8-ex", ""]:
		var reg := _setup(f, _row(id) if id != "" else {})
		for c in reg.list("controller"):
			ok(not c.available, "%s: %s unavailable" % [id, c.id])
			ok(c.reason != "", "%s: %s says why" % [id, c.id])
			ok(not c.write(true), "%s: %s refuses writes" % [id, c.id])
		reg.free()
	var reg2 := _setup(f, _row("steam-deck-oled"))
	eq(_reason(reg2, "controller.led_effect"), Provider.R_NO_RGB)
	eq(_reason(reg2, "controller.gyro"), Provider.R_NONE)
	reg2.free()
	reg2 = _setup(f, _row("onexplayer-g1-amd"))
	eq(_reason(reg2, "controller.gyro"), "This handheld has no gyro")
	reg2.free()
	ok(f.curl_calls.is_empty(), "no /run/hhd: hhd never asked")
	ok(f.pkexec_calls.is_empty(), "no root action")


func test_controls_are_snapshotted_per_game() -> void:
	var t := _claw("claw_snapshot")
	var reg: Node = t[0]
	var snap: Dictionary = reg.snapshot()
	ok(snap.has("controller.gyro"), "gyro is per game")
	ok(snap.has("controller.paddle.LeftPaddle1"), "paddles per game")
	ok(not snap.has("controller.desktop_mode"), "mouse mode isn't")
	ok(not snap.has("controller.rumble_test"), "actions aren't")
	var f: RefCounted = t[1]
	reg.apply({"controller.gyro": false, "controller.nintendo_layout": true})
	eq(IpEdit.gyro_enabled_sources(f.profile, ["Center"]), [], "apply wrote gyro")
	ok(IpEdit.nintendo(f.profile), "and the layout")
	reg.free()
