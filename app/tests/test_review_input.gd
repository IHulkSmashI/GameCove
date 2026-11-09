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


# ---- M12: mouse mode keeps the emulated controller and puts the targets back ---------------------

## Another tool runs a Steam Deck pad (deck-uhid) while the device config says xbox-elite. Mouse mode
## on pinned [xbox-elite, mouse, keyboard]; off and reset left it.
func test_m12_mouse_mode_restores_the_exact_targets() -> void:
	var t := _claw("m12_mouse")
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	f.targets = ["deck-uhid"]
	reg.detect_all()
	ok(_w(reg, "controller.desktop_mode", true), "mouse mode on")
	eq(f.targets.slice(0, 1), ["deck-uhid"], "still a Steam Deck pad")
	ok("mouse" in f.targets, "with a mouse")
	ok(_w(reg, "controller.desktop_mode", false), "mouse mode off")
	eq(f.targets, ["deck-uhid"], "exactly the targets from before")
	ok(not f.profile.has("target_devices"), "and the profile pins nothing")
	reg.free()


func test_m12_reset_puts_the_targets_back() -> void:
	var t := _claw("m12_reset")
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	f.targets = ["deck-uhid"]
	reg.detect_all()
	ok(_w(reg, "controller.desktop_mode", true), "mouse mode on")
	ok(_w(reg, "controller.reset_layout", true), "reset")
	eq(f.targets, ["deck-uhid"], "the targets from before GameCove changed them")
	reg.free()


# ---- M26: localconfig.vdf is never rewritten with replaced bytes ---------------------------------

## Proof 9.11 C: a persona name with a Latin-1 byte (not UTF-8) came back as U+FFFD after setting
## one game's launch options.
func test_m26_non_utf8_localconfig_is_left_alone() -> void:
	var SC := load("res://scripts/steam/steam_config.gd")
	var base := _root("m26")
	var home := base + "/home"
	var ud := home + "/.local/share/Steam/userdata/42"
	DirAccess.make_dir_recursive_absolute(ud + "/config")
	var lc := ud + "/config/localconfig.vdf"
	var bytes := "\"UserLocalConfigStore\"\n{\n\t\"friends\"\n\t{\n\t\t\"123\"\n\t\t{\n\t\t\t\"name\"\t\t\"Ren".to_utf8_buffer()
	bytes.append(0xE9)
	bytes.append_array("\"\n\t\t}\n\t}\n\t\"Software\"\n\t{\n\t\t\"Valve\"\n\t\t{\n\t\t\t\"Steam\"\n\t\t\t{\n\t\t\t\t\"apps\"\n\t\t\t\t{\n\t\t\t\t\t\"620\"\n\t\t\t\t\t{\n\t\t\t\t\t\t\"LaunchOptions\"\t\t\"-novid\"\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}\n".to_utf8_buffer())
	var w := FileAccess.open(lc, FileAccess.WRITE)
	w.store_buffer(bytes)
	w.close()
	var err: int = SC.set_launch_options(home, ud, "620", "-novid -dx11", base + "/noproc")
	ok(err != OK, "refused (the file isn't UTF-8)")
	eq(FileAccess.get_file_as_bytes(lc), bytes, "every byte as it was")


## An escape the reader doesn't know (\p) is kept as written, not turned into "p".
func test_m26_unknown_escapes_round_trip() -> void:
	var V := load("res://scripts/launch/vdf.gd")
	var W := load("res://scripts/steam/vdf_writer.gd")
	var text := "\"a\"\n{\n\t\"path\"\t\t\"C:\\\\Games\\\\x\"\n\t\"odd\"\t\t\"x\\py\"\n\t\"q\"\t\t\"say \\\"hi\\\"\\n\"\n}\n"
	var d: Variant = V.parse_strict(text)
	ok(d is Dictionary, "parses")
	eq(d["a"]["odd"], "x\\py", "unknown escape kept verbatim")
	eq(d["a"]["path"], "C:\\Games\\x", "known escapes decoded")
	var back: Variant = V.parse_strict(W.dump(d))
	eq(back, d, "dump reads back the same")
	ok("x\\py" in W.dump(d), "and writes \\p as it was")


# ---- L14: the YAML reader keeps everything after a multi-line string ------------------------------

func test_l14_yaml_multiline_strings() -> void:
	var Yaml := load("res://scripts/input/yaml_lite.gd")
	var lit := "version: 1\nkind: DeviceProfile\nname: X\ndescription: |-\n  Line one # not a comment\n    indented two\nmapping:\n- name: m1\n  source_event:\n    gamepad:\n      button: South\n  target_events: []\n"
	var d: Variant = Yaml.parse(lit)
	ok(d is Dictionary, "parses")
	eq(d.get("description"), "Line one # not a comment\n  indented two", "literal block kept as written")
	eq((d.get("mapping", []) as Array).size(), 1, "the mappings after it are there")
	var folded := "name: X\ndescription: >\n  one\n  two\nmapping: []\n"
	var f: Variant = Yaml.parse(folded)
	eq(f.get("description"), "one two\n", "folded block")
	eq(f.get("mapping"), [], "the key after it")
	var plain := "name: X\ndescription: a long line\n  that goes on\nmapping: []\n"
	var g: Variant = Yaml.parse(plain)
	eq(g.get("description"), "a long line that goes on", "plain multi-line scalar")
	eq(g.get("mapping"), [], "the key after it")
	var inseq := "mapping:\n- name: |-\n    two\n    lines\n  source_event:\n    gamepad:\n      button: North\n"
	var h: Variant = Yaml.parse(inseq)
	eq(h["mapping"][0].get("name"), "two\nlines", "block scalar inside a sequence item")
	eq(h["mapping"][0].get("source_event"), {"gamepad": {"button": "North"}}, "and the item's other keys")
