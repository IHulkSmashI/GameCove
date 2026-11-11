extends "res://tests/test_case.gd"
## Per-game settings: device defaults, validation, save/load roundtrip on a temp path.

const LauncherScript := preload("res://scripts/launch/launcher.gd")


func _launcher(path: String, device: Dictionary = {"gpu_family": "intel-xe3", "xmx": true}) -> Node:
	var l: Node = LauncherScript.new()
	l.settings_path = path
	l.home = ""
	l.device_profile = device
	return l


func _temp(name: String) -> String:
	var p := OS.get_user_data_dir().path_join(name)
	DirAccess.remove_absolute(p)
	return p


func test_contract_shape_and_defaults() -> void:
	var l := _launcher(_temp("test_launch_defaults.json"))
	var s: Dictionary = l.settings_for("steam:1")
	eq(s.keys().size(), 5, "five keys")
	for k in ["goal", "fps_limit", "upscaler", "frame_gen", "low_latency"]:
		ok(s.has(k), "has " + k)
	eq(s["goal"], "balanced", "Claw default")
	l.free()
	var deck := _launcher(_temp("test_launch_defaults2.json"), {"gpu_family": "amd-rdna2"})
	eq(deck.settings_for("steam:1")["goal"], "battery", "older chip: battery first")
	deck.free()
	var custom := LauncherScript.defaults_for({"gpu_family": "amd-rdna3", "launch_defaults": {"fps_limit": 60, "upscaler": "bogus"}})
	eq(custom["fps_limit"], 60, "devices.json launch_defaults")
	eq(custom["upscaler"], "auto", "bad value ignored")


func test_save_and_load_roundtrip() -> void:
	var path := _temp("test_launch_roundtrip.json")
	var a := _launcher(path)
	a.save_settings("steam:976730", {"goal": "smooth", "fps_limit": 90, "upscaler": "xess", "frame_gen": true, "low_latency": false})
	a.record_base_fps("steam:976730", 52)
	a.free()
	ok(FileAccess.file_exists(path), "file written")
	ok(not FileAccess.file_exists(path + ".tmp"), "temp file renamed away")
	var b := _launcher(path)
	eq(b.settings_for("steam:976730"), {"goal": "smooth", "fps_limit": 90, "upscaler": "xess", "frame_gen": true, "low_latency": false}, "same settings back")
	eq(b.base_fps("steam:976730"), 52, "measured fps back")
	ok(b.frame_gen_available("steam:976730"), "52 fps allows frame generation")
	eq(b.settings_for("steam:other")["goal"], "balanced", "other games keep defaults")
	b.reset_settings("steam:976730")
	b.reload()
	eq(b.settings_for("steam:976730")["upscaler"], "auto", "reset")
	b.free()


func test_bad_values_are_dropped() -> void:
	var path := _temp("test_launch_bad.json")
	var l := _launcher(path)
	l.save_settings("k", {"goal": "turbo", "fps_limit": -5, "upscaler": "dlss", "frame_gen": "yes", "low_latency": false, "extra": 1})
	var s: Dictionary = l.settings_for("k")
	eq(s, {"goal": "balanced", "fps_limit": 0, "upscaler": "auto", "frame_gen": false, "low_latency": false}, "only valid values kept")
	l.record_base_fps("k", 30)
	ok(not l.frame_gen_available("k"), "30 fps: no frame generation")
	l.free()


func test_broken_file_starts_fresh() -> void:
	var path := _temp("test_launch_broken.json")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("{not json")
	f.close()
	var l := _launcher(path)
	eq(l.settings_for("x")["upscaler"], "auto", "defaults")
	l.free()


func test_a_game_on_an_nvidia_card_gets_none_of_the_igpus_variables() -> void:
	# review M: an Intel iGPU plus an NVIDIA card: the Intel row's variables (DXVK's Intel vendor id, XeSS on XMX)
	# would hide the NVIDIA card from the game and break its DLSS
	var l := _launcher(_temp("test_launch_nvidia.json"), {"gpu_family": "intel-xe2", "xmx": true})
	l.save_settings("steam:5", {"goal": "balanced", "fps_limit": 0, "upscaler": "xess", "frame_gen": true, "low_latency": true})
	var game := {"key": "steam:5", "store": "steam", "id": "5", "proton": "proton_11"}
	ok(l.launch_plan(game)["env"].has("DXVK_CONFIG"), "on the Intel chip: XeSS shows the Intel GPU")
	l.render_vendor = "nvidia"
	var plan: Dictionary = l.launch_plan(game)
	eq(plan["env"], {}, "on the NVIDIA card: nothing of ours")
	ok(str(plan["notes"]).contains("NVIDIA"), "and says why: " + str(plan["notes"]))
	l.free()
