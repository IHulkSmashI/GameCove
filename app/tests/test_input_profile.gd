extends "res://tests/test_case.gd"
## The YAML reader and the InputPlumber profile helpers.

const Yaml := preload("res://scripts/input/yaml_lite.gd")
const Profile := preload("res://scripts/input/ip_profile.gd")


func _profile() -> Dictionary:
	return Yaml.parse(FileAccess.get_file_as_string(fixture("system/inputplumber/profile.yaml")))


func test_yaml_reads_serde_output() -> void:
	var p := _profile()
	eq(p["version"], 1)
	eq(p["name"], "Default")
	eq(p["description"], null)
	eq(p["mapping"].size(), 5)
	eq(p["mapping"][0]["source_event"], {"gamepad": {"button": "LeftTop"}})
	eq(p["mapping"][2]["name"], "Quick: Access")
	eq(p["mapping"][2]["target_events"].size(), 2)
	eq(p["mapping"][3]["target_events"][0]["mouse"]["motion"]["speed_pps"], 800.0)
	eq(p["mapping"][4]["target_events"][0], {"keyboard": "KeyW"})


func test_yaml_edge_cases() -> void:
	eq(Yaml.parse("null\n"), null)
	eq(Yaml.parse(""), null)
	eq(Yaml.parse("a: []\nb: {}\nc: ~\nd: true\ne: \"x # y\"  # comment\n"), {"a": [], "b": {}, "c": null, "d": true, "e": "x # y"})
	eq(Yaml.parse("list:\n  - 1\n  - two\n"), {"list": [1, "two"]})
	eq(Yaml.parse("{\"name\": \"json\"}"), {"name": "json"})


func test_paddles_read() -> void:
	var p := Profile.paddles(_profile(), ["LeftPaddle1", "RightPaddle1", "RightPaddle2"])
	eq(p, {"LeftPaddle1": "South", "RightPaddle1": "", "RightPaddle2": "KeyW+mouse"})


func test_set_paddle_adds_replaces_removes() -> void:
	var p := Profile.set_paddle(_profile(), "RightPaddle1", "East")
	eq(Profile.paddles(p, ["RightPaddle1"])["RightPaddle1"], "East")
	p = Profile.set_paddle(p, "LeftPaddle1", "KeySpace")
	eq(Profile.paddles(p, ["LeftPaddle1"])["LeftPaddle1"], "KeySpace")
	var count := (p["mapping"] as Array).filter(func(m): return Profile.button_of(m["source_event"]) == "LeftPaddle1").size()
	eq(count, 1)
	p = Profile.set_paddle(p, "LeftPaddle1", "")
	eq(Profile.paddles(p, ["LeftPaddle1"])["LeftPaddle1"], "")
	# unrelated mappings stay
	ok((p["mapping"] as Array).any(func(m): return m["name"] == "LeftTop"), "LeftTop kept")


func test_valid_targets() -> void:
	ok(Profile.valid_target("South"), "button")
	ok(Profile.valid_target("KeyW"), "key")
	ok(Profile.valid_target(""), "reset")
	ok(not Profile.valid_target("Key"), "bare Key")
	ok(not Profile.valid_target("rm -rf"), "junk")


func test_gyro_modes() -> void:
	var p := _profile()
	eq(Profile.gyro_mode(p), "mouse")
	p = Profile.set_gyro_mode(p, "stick")
	eq(Profile.gyro_mode(p), "stick")
	eq((p["mapping"] as Array).filter(func(m): return Profile.is_gyro(m["source_event"])).size(), 1)
	p = Profile.set_gyro_mode(p, "off")
	eq(Profile.gyro_mode(p), "off")
	eq(Profile.gyro_mode(Profile.empty()), "off")


func test_json_out_has_no_nulls_and_round_trips() -> void:
	var text := Profile.to_json(_profile())
	ok(not "null" in text, "nulls dropped")
	var back: Dictionary = Yaml.parse(text)
	eq(back["kind"], "DeviceProfile")
	eq(back["mapping"].size(), 5)
	eq(back["mapping"][3]["source_event"], {"gamepad": {"gyro": {"name": "Gyro1"}}})


func test_caps_and_file_names() -> void:
	var caps := ["Gamepad:Button:South", "Gamepad:Button:LeftPaddle1", "Gamepad:Button:RightPaddle1", "Gyroscope:Gamepad"]
	eq(Profile.paddles_from_caps(caps), ["LeftPaddle1", "RightPaddle1"])
	ok(Profile.has_gyro(caps), "gyro")
	ok(not Profile.has_gyro(["Gamepad:Button:South"]), "no gyro")
	eq(Profile.file_name_for("steam:976730"), "steam_3A976730.yaml")
	eq(Profile.file_name_for("epic:../../x"), "epic_3A_2E_2E_2F_2E_2E_2Fx.yaml")
	eq(Profile.legacy_file_name_for("steam:976730"), "steam_976730.yaml")
