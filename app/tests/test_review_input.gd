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
