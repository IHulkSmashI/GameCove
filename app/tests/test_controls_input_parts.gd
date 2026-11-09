extends "res://tests/test_case.gd"
## The pieces under scripts/controls/input/: hhd over curl, InputPlumber profile
## edits, LED node reading.

const HhdClient := preload("res://scripts/controls/input/hhd_client.gd")
const IpEdit := preload("res://scripts/controls/input/ip_edit.gd")
const Leds := preload("res://scripts/controls/input/leds.gd")
const Caps := preload("res://scripts/controls/input/caps.gd")
const Runner := preload("res://tests/fixtures/system/fake_runner.gd")
const Fakes := preload("res://tests/fixtures/controller/fakes.gd")
const DeviceScript := preload("res://scripts/device/device.gd")


func _root(n: String) -> String:
	var d := ProjectSettings.globalize_path("user://test_ctl_parts/" + n)
	_rm(d)
	DirAccess.make_dir_recursive_absolute(d)
	return d


func _rm(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.include_hidden = true
	for f in d.get_files():
		DirAccess.remove_absolute(path + "/" + f)
	for s in d.get_directories():
		_rm(path + "/" + s)
	DirAccess.remove_absolute(path)


# ---- hhd client --------------------------------------------------------------------

func test_hhd_absent_spawns_nothing() -> void:
	var r: RefCounted = Runner.new()
	var h := HhdClient.new(r, _root("hhd_absent"), "/nonexistent")
	ok(not h.present(), "no /run/hhd")
	eq(h.get_state(), null)
	eq(r.calls.size(), 0, "curl never started")


func test_hhd_socket_first_then_tcp_with_token_and_port() -> void:
	var root := _root("hhd_tcp")
	DirAccess.make_dir_recursive_absolute(root + "/run/hhd")
	Fakes.write(root + "/home/.config/hhd/token", "s3cret")
	Fakes.write(root + "/home/.config/hhd/state.yml", "hhd:\n  http:\n    enable: true\n    port: 5400\n")
	var r: RefCounted = Runner.new()
	r.responses["curl -sS -m 2 -X GET -w \n%{http_code} --unix-socket /run/hhd/api http://localhost/api/v1/state"] = {"code": 7, "out": ""}
	r.responses["curl -sS -m 2 -X GET -w \n%{http_code} -H Authorization: Bearer s3cret http://127.0.0.1:5400/api/v1/state"] = {"code": 0, "out": "{\"controllers\":{\"claw\":{}}}\n200"}
	var h := HhdClient.new(r, root, root + "/home")
	eq(h.port(), 5400, "port from state.yml")
	var st: Variant = h.get_state()
	eq(HhdClient.controller_key(st), "claw")
	eq(r.calls.size(), 2, "socket tried, then TCP")
	r.responses["curl -sS -m 2 -X GET -w \n%{http_code} --unix-socket /run/hhd/api http://localhost/api/v1/state"] = {"code": 0, "out": "Unauthorized\n401"}
	eq(h.get_state(), null, "a non-200 answer is no state")


func test_hhd_post_sends_ints_in_order() -> void:
	var root := _root("hhd_post")
	DirAccess.make_dir_recursive_absolute(root + "/run/hhd")
	var r: RefCounted = Runner.new()
	r.responses["curl -sS -m 2 -X POST*"] = {"code": 0, "out": "{}\n200"}
	var h := HhdClient.new(r, root, root)
	h.set_state({"b": {"x": 5.0, "y": 0.5}, "a": [1.0]})
	ok(r.calls[0].contains("--data-binary {\"b\":{\"x\":5,\"y\":0.5},\"a\":[1]}"), "body: " + r.calls[0])
	ok(r.calls[0].contains("--unix-socket /run/hhd/api"), "socket")


func test_hhd_schema_walk() -> void:
	var s := {"controllers": {"rog_ally": {"type": "container", "children": {
		"controller_mode": {"type": "mode", "modes": {"dualsense": {"title": "DS", "children": {
			"paddles_as": {"type": "multiple", "options": {"a": "A", "b": "B"}}}}}}}}}}
	var n: Variant = HhdClient.schema_node(s, ["controllers", "rog_ally", "controller_mode", "dualsense", "paddles_as"])
	eq(HhdClient.options_of(n), ["a", "b"])
	eq(HhdClient.labels_of(n), {"a": "A", "b": "B"})
	var m: Variant = HhdClient.schema_node(s, ["controllers", "rog_ally", "controller_mode", "mode"])
	eq(HhdClient.options_of(m), ["dualsense"])
	eq(HhdClient.labels_of(m), {"dualsense": "DS"})
	eq(HhdClient.schema_node(s, ["controllers", "rog_ally", "nope"]), null)
	eq(HhdClient.merge({"a": {"b": 1, "c": 2}}, {"a": {"b": 3}}), {"a": {"b": 3, "c": 2}})


# ---- InputPlumber edits ------------------------------------------------------------------

func test_config_head_and_override_precedence() -> void:
	var root := _root("ip_conf")
	Fakes.write(root + "/usr/share/inputplumber/devices/50-x.yaml",
		"# comment\nversion: 1\nname: \"Handheld X\"\nsource_devices:\n  - group: gamepad\n    evdev:\n      name: x\ntarget_devices:\n  - xbox-elite  # main\n  - mouse\noptions:\n  auto_manage: true\n")
	eq(IpEdit.config_targets(root, "Handheld X"), ["xbox-elite", "mouse"])
	Fakes.write(root + "/etc/inputplumber/devices.d/50-x.yaml", "name: Handheld X\ntarget_devices:\n  - deck\n")
	eq(IpEdit.config_targets(root, "Handheld X"), ["deck"], "/etc override wins")
	eq(IpEdit.config_targets(root, "Other"), [])


func test_gyro_sources_and_pads_from_caps() -> void:
	eq(IpEdit.gyro_sources(["Gyroscope:Right", "Gyroscope:Left", "Accelerometer:Left", "Gyroscope:Gamepad"]), ["Left", "Right"])
	eq(IpEdit.pads(["Touchpad:RightPad:Touch:Motion", "Touchpad:LeftPad:Touch:Button:Press"]), ["LeftPad", "RightPad"])
	var p := IpEdit.set_gyro_sources({"mapping": []}, ["Left", "Right"], ["Right"])
	eq(IpEdit.gyro_enabled_sources(p, ["Left", "Right"]), ["Right"])
	ok(not "null" in JSON.stringify(p), "clean")


func test_button_and_nintendo_edits_coexist() -> void:
	var p := IpEdit.set_nintendo({"mapping": []}, true)
	p = IpEdit.set_button(p, "South", "KeyEnter")
	eq(IpEdit.button_target(p, "South"), "KeyEnter")
	ok(IpEdit.nintendo(p), "swap kept")
	p = IpEdit.set_button(p, "South", "")
	eq(IpEdit.button_target(p, "South"), "", "remap gone")
	eq((p["mapping"] as Array).size(), 4, "the four swap mappings stay")
	p = IpEdit.set_nintendo(p, false)
	eq((p["mapping"] as Array).size(), 0)
	ok(not IpEdit.valid_button_target("mouse:Fire"), "unknown mouse button")
	ok(IpEdit.valid_button_target("mouse:Right"), "right click")


func test_targets_and_reset() -> void:
	var p := IpEdit.set_gamepad_target({"mapping": []}, "deck", ["xbox-elite", "mouse", "keyboard", "touchpad"])
	eq(p["target_devices"], ["deck", "mouse", "keyboard", "touchpad"])
	p = IpEdit.set_gamepad_target(p, "ds5-edge", [])
	eq(p["target_devices"], ["ds5-edge", "mouse", "keyboard", "touchpad"])
	p["mapping"] = [{"name": "Theirs", "source_event": {}, "target_events": []}, {"name": "GameCove X", "source_event": {}, "target_events": []}]
	var r := IpEdit.reset(p)
	eq(r["mapping"].map(func(m): return m["name"]), ["Theirs"], "only ours removed")
	ok(not r.has("target_devices"), "target override removed")


# ---- LED nodes -------------------------------------------------------------------------

func test_led_scan_patterns_and_specs() -> void:
	var f: RefCounted = Fakes.new(_root("leds"))
	f.led("ayn:rgb:joystick_rings")
	f.led("multicolor:chassis")
	f.led("zotac:rgb:spectra_zone_1")
	f.led("input5::capslock", "red")
	f.led("asus::kbd_backlight", "red green blue")
	var names := Leds.scan(f.sys_root).map(func(n): return n["name"])
	eq(names, ["ayn:rgb:joystick_rings", "multicolor:chassis", "zotac:rgb:spectra_zone_1"], "only handheld RGB nodes")
	eq(Leds.spec("all", Color8(255, 128, 0), 49.6), "all,ff8000,50")
	eq(Leds.spec("1", Color.BLACK, 0, "breathe", 33.3), "1,000000,0,breathe,33")
	ok(Leds.valid_spec("off"), "off")
	ok(Leds.valid_spec("all,ff8000,100,chroma,20"), "full spec")
	for bad in ["all,FF8000,50", "all,ff8000,101", "10,ff8000,5", "all,ff8000,5,x y", "all;rm,ff8000,5", ""]:
		ok(not Leds.valid_spec(bad), "refused: " + bad)
	ok(not Leds.apply(Runner.new(), "all,ff8000,500"), "invalid never reaches pkexec")


func test_led_effects_mapping() -> void:
	var n := {"effects": ["monocolor", "breathe", "chroma", "rainbow", "frostfire"], "effect": "rainbow", "brightness": 10, "max": 100, "enabled": true}
	eq(Leds.effects_of(n), ["off", "solid", "pulse", "rainbow", "spiral", "frostfire"])
	eq(Leds.effect_of(n), "spiral", "kernel rainbow is the spinning one")
	eq(Leds.kernel_effect(n, "rainbow"), "chroma")
	n["enabled"] = false
	eq(Leds.effect_of(n), "off", "disabled ring reads as off")


func test_caps_per_device() -> void:
	var rows := {}
	for r in DeviceScript.load_table():
		rows[r["id"]] = r
	var lg := Caps.of(rows["lenovo-legion-go"])
	eq(lg["trackpads"], 1)
	ok(lg["rgb"], "Legion Go has RGB")
	eq(lg["paddles"].size(), 4)
	var deck := Caps.of(rows["steam-deck-oled"])
	ok(not deck["rgb"], "Deck has no RGB")
	eq(deck["trackpads"], 2)
	eq(Caps.gyro_block(rows["onexplayer-g1-amd"]), "This handheld has no gyro")
	eq(Caps.gyro_block(rows["msi-claw-8-ai-plus"]), "Linux can't read this handheld's gyro yet")
	eq(Caps.gyro_block(rows["msi-claw-8-ex"]), "", "the Claw 8 EX gyro works with its fix")
	var xa := Caps.of(rows["asus-rog-xbox-ally"])
	ok(xa["extra_buttons"].has("LeftPaddle2"), "Xbox Ally's Armoury Crate hold is remappable")
	ok(not xa["extra_buttons"].has("Guide"), "buttons GameCove uses aren't")
	for id in rows:
		var c := Caps.of(rows[id])
		ok(c.has("paddles") and c.has("trackpads"), id + " caps")


## The Ally's stock profile maps QuickAccess2 -> Screenshot. "As itself" drops it; picking
## Screenshot again must put the stock mapping back, not a "GameCove QuickAccess2" override.
func test_button_back_to_stock_restores_the_stock_mapping() -> void:
	var stock_map := {"name": "Screenshot", "source_event": {"gamepad": {"button": "QuickAccess2"}},
		"target_events": [{"gamepad": {"button": "Screenshot"}}]}
	var stock := {"version": 1, "kind": "DeviceProfile", "name": "Default", "mapping": [stock_map]}
	eq(IpEdit.button_target(stock, "QuickAccess2"), "Screenshot", "stock reads Screenshot")
	var p1 := IpEdit.set_button(stock.duplicate(true), "QuickAccess2", "", stock)
	eq(IpEdit.button_target(p1, "QuickAccess2"), "", "as itself")
	var p2 := IpEdit.set_button(p1, "QuickAccess2", "Screenshot", stock)
	eq(p2["mapping"], [stock_map], "exactly the stock mapping again")
	ok(not (p2["mapping"] as Array).any(func(m): return str(m.get("name", "")).begins_with("GameCove")), "no GameCove override left")
	var p3 := IpEdit.set_button(p2, "QuickAccess2", "KeyF13", stock)
	ok((p3["mapping"] as Array).any(func(m): return m.get("name") == "GameCove QuickAccess2"), "other targets still get GameCove's mapping")
