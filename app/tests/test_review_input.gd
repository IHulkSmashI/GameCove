extends "res://tests/test_case.gd"
## Regression tests for the pre-release review's input-profile findings (H3, M10, M12, M13,
## and the YAML reader), on the fake InputPlumber of fixtures/controller/fakes.gd.

const Provider := preload("res://scripts/controls/providers/controller.gd")
const ControlsScript := preload("res://scripts/controls/controls.gd")
const Fakes := preload("res://tests/fixtures/controller/fakes.gd")
const DeviceScript := preload("res://scripts/device/device.gd")
const IpEdit := preload("res://scripts/controls/input/ip_edit.gd")

const CLAW_CAPS := ["Gamepad:Button:South", "Gamepad:Button:East", "Gamepad:Button:North", "Gamepad:Button:West",
	"Gamepad:Button:Guide", "Gamepad:Button:QuickAccess", "Gamepad:Button:LeftPaddle1", "Gamepad:Button:RightPaddle1",
	"Gamepad:Axis:LeftStick", "Gamepad:Axis:RightStick", "Gamepad:Trigger:LeftTrigger", "Gamepad:Trigger:RightTrigger",
	"Gyroscope:Center", "Accelerometer:Center"]
const LAYOUTS := "/home/.config/inputplumber/profiles/gamecove/msi-claw-8-ex/"


func _row(id: String) -> Dictionary:
	for r in DeviceScript.load_table():
		if r.get("id") == id:
			return r
	return {}


func _root(test_name: String) -> String:
	var d := ProjectSettings.globalize_path("user://test_review_input/" + test_name)
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


## [registry, fakes, ctx]
func _claw(test_name: String) -> Array:
	var f: RefCounted = Fakes.new(_root(test_name))
	f.with_ip("MSI Claw 8 EX", CLAW_CAPS)
	Fakes.write(f.sys_root + "/usr/share/inputplumber/devices/50-msi_claw8_ex_ai_cg3em.yaml",
		"version: 1\nkind: CompositeDevice\nname: MSI Claw 8 EX\ntarget_devices:\n  - xbox-elite\n  - mouse\n  - keyboard\n")
	var reg: Node = ControlsScript.new()
	reg.sync_mode = true
	var c: Dictionary = f.ctx(_row("msi-claw-8-ex"))
	reg.setup(c)
	var p := Provider.new()
	p.setup(c)
	reg.register_provider(p)
	reg.detect_all()
	return [reg, f, c]


func _w(reg: Node, id: String, v: Variant) -> bool:
	var c: RefCounted = reg.control(id)
	var done: bool = c != null and c.write(v)
	if done:
		reg._reread_affected([c])
	return done


# ---- H3: a game's layout is never saved as the everyday one --------------------------------------

func test_h3_game_layout_not_saved_into_default() -> void:
	var t := _claw("h3_default")
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	var ctx: Dictionary = t[2]
	ok(_w(reg, "controller.gyro", false), "everyday: gyro off")
	var everyday := FileAccess.get_file_as_string(f.sys_root + LAYOUTS + "default.yaml")
	ok("Gyro Off" in everyday, "saved as the everyday layout")
	ctx["game_key"] = "steam:1"   # main.gd sets it on the Controls worker when a game starts
	ok(_w(reg, "controller.nintendo_layout", true), "the game's profile: Nintendo layout")
	eq(FileAccess.get_file_as_string(f.sys_root + LAYOUTS + "default.yaml"), everyday, "everyday layout untouched during the game")
	ctx.erase("game_key")
	reg.free()


## The legacy "use its own layout" file of that game gets the game's edits instead.
func test_h3_legacy_game_file_gets_the_game_edit() -> void:
	var t := _claw("h3_legacy")
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	var ctx: Dictionary = t[2]
	var game_file: String = f.sys_root + LAYOUTS + load("res://scripts/input/ip_profile.gd").file_name_for("steam:1")
	Fakes.write(game_file, "{\"version\": 1, \"kind\": \"DeviceProfile\", \"name\": \"g\", \"mapping\": []}")
	ctx["game_key"] = "steam:1"
	ok(_w(reg, "controller.nintendo_layout", true), "Nintendo layout in the game")
	ok("Nintendo" in FileAccess.get_file_as_string(game_file), "saved to the game's own file")
	ok(not FileAccess.file_exists(f.sys_root + LAYOUTS + "default.yaml"), "not to the everyday one")
	reg.free()


# ---- M13: profile edits never start from a stale or failed read ----------------------------------

const OTHER := {"name": "Someone Else", "source_event": {"gamepad": {"button": "LeftPaddle1"}}, "target_events": [{"keyboard": "KeyW"}]}


## A failed GetProfileYaml read as {}: the edit went onto an empty profile and dropped every mapping.
func test_m13_failed_read_is_a_failed_edit() -> void:
	var t := _claw("m13_failed")
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	f.profile["mapping"] = [OTHER.duplicate(true)]
	f.refuse_yaml = true
	var c: RefCounted = reg.control("controller.nintendo_layout")
	eq(c.write(true), false, "the edit fails")
	eq(f.profile["mapping"], [OTHER], "the loaded profile keeps its mappings")
	ok(f.loads.is_empty(), "nothing sent to InputPlumber")
	reg.free()


## The Controller service loaded default.yaml while the Controls snapshot was cached (1.5 s):
## the edit was built on the profile from before.
func test_m13_edit_reads_the_live_profile() -> void:
	var t := _claw("m13_stale")
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	var be: RefCounted = reg.control("controller.nintendo_layout").get_meta("provider").be
	be.snapshot()
	be._snap_at = Time.get_ticks_msec()   # cached right now (the fixture's detection takes a while)
	f.profile = {"version": 1, "kind": "DeviceProfile", "name": "Loaded", "mapping": [OTHER.duplicate(true)]}
	ok(_w(reg, "controller.nintendo_layout", true), "Nintendo on")
	ok((f.profile["mapping"] as Array).any(func(m): return m.get("name") == "Someone Else"), "the mapping loaded meanwhile is kept")
	reg.free()


## Both workers edit under one lock.
func test_m13_one_lock_for_both_workers() -> void:
	var Lock := load("res://scripts/input/profile_lock.gd")
	ok(Lock != null and Lock.mutex is Mutex, "a shared profile lock exists")
	for f in ["res://scripts/controls/input/backend.gd", "res://scripts/input/controller.gd"]:
		ok("ProfileLock.mutex.lock()" in FileAccess.get_file_as_string(f), "%s takes it" % f)


# ---- M10: the layout comes back when InputPlumber restarts ----------------------------------------

const ControllerScript := preload("res://scripts/input/controller.gd")
const FakeRunner := preload("res://tests/fixtures/system/fake_runner.gd")
const IPTest := preload("res://tests/test_input_controller.gd")


func test_m10_layout_reloaded_when_inputplumber_restarts() -> void:
	var f: RefCounted = FakeRunner.new()
	var _ip = IPTest.FakeIP.new(f, fixture("system/inputplumber"))
	var c: Node = ControllerScript.new()
	var home := _root("m10") + "/home"
	c.setup(f, home)
	c.device_id = "msi-claw-8-ex"
	c.set_device("msi-claw-8-ex")
	var layout := "{\"version\": 1, \"kind\": \"DeviceProfile\", \"name\": \"Mine\", \"mapping\": []}"
	Fakes.write(c.default_profile_path(), layout)
	c.refresh()
	c.setup_intercept_for_tests()
	c.monitor_line({"kind": "started"})
	f.calls.clear()
	c.monitor_line({"kind": "owner", "owner": ":1.77"})
	var loads: Array = f.calls.filter(func(cmd): return " LoadProfileFromYaml s " in cmd)
	eq(loads.size(), 1, "the everyday layout is loaded onto the new device")
	ok(not loads.is_empty() and "\"Mine\"" in str(loads[0]), "the saved one: %s" % [loads])
	f.calls.clear()
	c.monitor_line({"kind": "added", "path": "/org/shadowblip/InputPlumber/CompositeDevice3"})
	eq(f.calls.filter(func(cmd): return " LoadProfileFromYaml s " in cmd).size(), 1, "and onto a re-added composite device")
	c.free()
