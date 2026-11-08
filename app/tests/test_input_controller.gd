extends "res://tests/test_case.gd"
## Controller service against a fake InputPlumber (busctl JSON fixtures).

const ControllerScript := preload("res://scripts/input/controller.gd")
const Fake := preload("res://tests/fixtures/system/fake_runner.gd")

const SVC := "org.shadowblip.InputPlumber"
const DEV0 := "/org/shadowblip/InputPlumber/CompositeDevice0"
const GET := "busctl --system get-property " + SVC + " "
const LOAD := "busctl --system call " + SVC + " " + DEV0 + " org.shadowblip.Input.CompositeDevice LoadProfileFromYaml s "


## A fake InputPlumber: serves the fixtures, remembers the last loaded profile
## and the ForceFeedback Enabled value.
class FakeIP:
	var loaded := ""
	var rumble := true

	func _init(f: RefCounted, fixtures: String) -> void:
		var mgr := "/org/shadowblip/InputPlumber/Manager org.shadowblip.InputManager "
		f.responses[GET + mgr + "Version"] = {"code": 0, "out": "{\"type\":\"s\",\"data\":\"0.70.2\"}"}
		f.responses[GET + mgr + "GamepadOrder"] = {"code": 0, "out": "{\"type\":\"ao\",\"data\":[\"" + DEV0 + "\"]}"}
		f.responses["busctl --system call " + SVC + " /org/shadowblip/InputPlumber org.freedesktop.DBus.ObjectManager GetManagedObjects"] = {"code": 0, "file": fixtures + "/managed_objects.json"}
		var reply := FileAccess.get_file_as_string(fixtures + "/profile_reply.json")
		f.handler = func(cmd: String):
			if cmd.begins_with(LOAD):
				loaded = cmd.substr(LOAD.length())
				return {"code": 0, "out": ""}
			if cmd.ends_with("GetProfileYaml"):
				if loaded != "":
					return {"code": 0, "out": JSON.stringify({"type": "s", "data": [loaded]})}
				return {"code": 0, "out": reply}
			if cmd == GET + DEV0 + " org.shadowblip.Output.ForceFeedback Enabled":
				return {"code": 0, "out": "{\"type\":\"b\",\"data\":%s}" % ("true" if rumble else "false")}
			if cmd.begins_with("busctl --system set-property " + SVC + " " + DEV0 + " org.shadowblip.Output.ForceFeedback Enabled b "):
				rumble = cmd.ends_with(" true")
				return {"code": 0, "out": ""}
			return null


func _home(test_name: String) -> String:
	var d := ProjectSettings.globalize_path("user://test_input/" + test_name)
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


func _ctl(test_name: String) -> Array:
	var f: RefCounted = Fake.new()
	var ip := FakeIP.new(f, fixture("system/inputplumber"))
	var c: Node = ControllerScript.new()
	c.setup(f, _home(test_name))
	return [c, f, ip]


func test_refresh_reads_devices_profile_and_caps() -> void:
	var t := _ctl("refresh")
	var c: Node = t[0]
	c.refresh()
	var st: Dictionary = c.state()
	ok(st["available"], "InputPlumber running")
	eq(st["version"], "0.70.2")
	eq(st["devices"].size(), 2)
	eq(st["devices"][0]["path"], DEV0)
	eq(st["devices"][0]["name"], "MSI Claw 8 EX")
	eq(st["active"], DEV0)
	eq(st["profile"]["name"], "Default")
	eq(st["profile"]["paddles"], {"LeftPaddle1": "South", "RightPaddle1": ""})
	eq(st["profile"]["gyro"], "mouse")
	eq(st["rumble"], true)
	ok(st["led"], "device reports LEDs")
	eq(st["supported"], {"profiles": true, "paddles": true, "gyro": true, "rumble": true, "led": false, "per_game": true})
	ok(not c.set_led(Color.RED, 1.0), "no LED setter in InputPlumber")
	c.free()


func test_not_running() -> void:
	var f: RefCounted = Fake.new()
	var c: Node = ControllerScript.new()
	c.setup(f, _home("none"))
	var applied: Array = []
	c.applied.connect(func(s, okk): applied.append([s, okk]))
	c.refresh()
	ok(not c.state()["available"], "not available")
	eq(c.state()["supported"]["profiles"], false)
	c.set_gyro_mode("stick")
	eq(applied, [["gyro", false]])
	ok(not f.called("busctl --system call " + SVC + " " + DEV0), "nothing sent")
	c.free()


func test_set_paddle_loads_json_and_saves_default() -> void:
	var t := _ctl("paddle")
	var c: Node = t[0]
	var ip: FakeIP = t[2]
	var applied: Array = []
	c.applied.connect(func(s, okk): applied.append([s, okk]))
	c.refresh()
	c.set_paddle("RightPaddle1", "East")
	eq(applied, [["paddle", true]])
	var sent: Dictionary = JSON.parse_string(ip.loaded)
	ok((sent["mapping"] as Array).any(func(m): return m["name"] == "GameCove RightPaddle1"), "mapping sent")
	ok(not "null" in ip.loaded, "clean JSON")
	eq(c.state()["profile"]["paddles"]["RightPaddle1"], "East")
	ok(FileAccess.file_exists(c.default_profile_path()), "saved as the everyday profile")
	c.set_paddle("Nope", "East")
	c.set_paddle("LeftPaddle1", "rm -rf")
	eq(applied.slice(1), [["paddle", false], ["paddle", false]])
	c.free()


func test_gyro_and_rumble() -> void:
	var t := _ctl("gyro")
	var c: Node = t[0]
	var ip: FakeIP = t[2]
	c.refresh()
	c.set_gyro_mode("stick")
	eq(c.state()["profile"]["gyro"], "stick")
	var applied: Array = []
	c.applied.connect(func(s, okk): applied.append([s, okk]))
	c.set_rumble(false)
	eq(applied, [["rumble", true]])
	eq(ip.rumble, false)
	eq(c.state()["rumble"], false)
	c.free()


func test_per_game_profile_switching() -> void:
	var t := _ctl("game")
	var c: Node = t[0]
	var f: RefCounted = t[1]
	var ip: FakeIP = t[2]
	c.refresh()
	# everyday layout: gyro off
	c.set_gyro_mode("off")
	ok(FileAccess.file_exists(c.default_profile_path()), "default saved")
	# a game with no profile: nothing loads
	var loads := func(): return f.calls.filter(func(x): return x.begins_with(LOAD)).size()
	var before: int = loads.call()
	c.start_game("steam:976730")
	eq(loads.call(), before)
	eq(c.state()["game"], "steam:976730")
	ok(not c.state()["game_profile"], "no game profile")
	# make one: gyro as mouse for this game
	c.set_game_profile("steam:976730", true)
	ok(c.has_game_profile("steam:976730"), "saved")
	ok(c.state()["game_profile"], "state says so")
	c.set_gyro_mode("mouse")
	var game_file := FileAccess.get_file_as_string(c.game_profile_path("steam:976730"))
	ok("GameCove Gyro Mouse" in game_file, "edit went to the game's profile")
	ok(not "GameCove Gyro Mouse" in FileAccess.get_file_as_string(c.default_profile_path()), "everyday profile untouched")
	c.end_game()
	ok(not "GameCove Gyro Mouse" in ip.loaded, "everyday layout back after the game")
	eq(c.state()["profile"]["gyro"], "off")
	# next launch loads the game's profile
	c.start_game("steam:976730")
	ok("GameCove Gyro Mouse" in ip.loaded, "game profile loaded at start")
	eq(c.state()["profile"]["gyro"], "mouse")
	c.end_game()
	c.set_game_profile("steam:976730", false)
	ok(not c.has_game_profile("steam:976730"), "deleted")
	c.free()


func test_parse_devices_and_pick_active() -> void:
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(fixture("system/inputplumber/managed_objects.json")))
	var devs: Array = ControllerScript.parse_devices(raw["data"][0])
	eq(devs.map(func(d): return d["path"]), [DEV0, "/org/shadowblip/InputPlumber/CompositeDevice1"])
	eq(devs[1]["gamepad"], false)
	eq(ControllerScript.pick_active(devs, []), DEV0)
	eq(ControllerScript.pick_active(devs, ["/org/shadowblip/InputPlumber/CompositeDevice1"]), "/org/shadowblip/InputPlumber/CompositeDevice1")
	eq(ControllerScript.pick_active([], []), "")
