extends "res://tests/test_case.gd"
## LaunchEnv.compose(): variables per GPU family x Proton flavour, gating, conflicts.

const LaunchEnv := preload("res://scripts/launch/launch_env.gd")
const Proton := preload("res://scripts/launch/proton.gd")

const FAMILIES := ["amd-rdna2", "amd-rdna3", "intel-xe-lpg", "intel-xe2", "intel-xe3"]
const XMX := {"amd-rdna2": false, "amd-rdna3": false, "intel-xe-lpg": false, "intel-xe2": true, "intel-xe3": true}


func _protons() -> Dictionary:
	return {
		"valve11": Proton.classify("proton_11"),
		"valve9": Proton.classify("proton_9"),
		"ge10": Proton.classify("GE-Proton10-25"),
		"cachy10": Proton.classify("proton-cachyos-10.0-20250905-slr"),
		"cachy11": Proton.classify("proton-cachyos-11.0-20260702-slr"),
	}


func _settings(over: Dictionary = {}) -> Dictionary:
	var s := {"goal": "balanced", "fps_limit": 0, "upscaler": "auto", "frame_gen": false, "low_latency": true}
	s.merge(over, true)
	return s


func _env(family: String, proton_name: String, over: Dictionary = {}, host: Dictionary = {}, game: Dictionary = {}) -> Dictionary:
	var h := {"xess_xmx": true, "low_latency_layer": false}
	h.merge(host, true)
	return LaunchEnv.compose(_settings(over), {"gpu_family": family, "xmx": XMX[family]}, _protons()[proton_name], h, game)


func _ids(plan: Dictionary) -> Array:
	return plan["conflicts"].map(func(c): return c["id"])


func test_every_family_and_flavour_gives_a_plain_string_dictionary() -> void:
	for fam in FAMILIES:
		for p in _protons():
			for up in ["auto", "off", "fsr", "xess"]:
				for fg in [false, true]:
					var plan := _env(fam, p, {"upscaler": up, "frame_gen": fg})
					ok(plan["env"] is Dictionary, "env is a Dictionary")
					for k in plan["env"]:
						ok(k is String and plan["env"][k] is String, "%s/%s %s: string pairs" % [fam, p, k])
					# Nothing we emit on our own should conflict.
					eq(_ids(plan), [], "%s/%s/%s/fg=%s no conflicts" % [fam, p, up, fg])


func test_rdna3_fsr4_variable_follows_the_proton() -> void:
	eq(_env("amd-rdna3", "cachy11", {"upscaler": "fsr"})["env"].get("PROTON_FSR4_UPGRADE"), "1", "CachyOS 11")
	ok(not _env("amd-rdna3", "cachy11", {"upscaler": "fsr"})["env"].has("PROTON_FSR4_RDNA3_UPGRADE"), "CachyOS 11 has no RDNA3 var")
	eq(_env("amd-rdna3", "cachy10", {"upscaler": "fsr"})["env"].get("PROTON_FSR4_RDNA3_UPGRADE"), "1", "CachyOS 10")
	eq(_env("amd-rdna3", "ge10", {"upscaler": "fsr"})["env"].get("PROTON_FSR4_UPGRADE"), "1", "GE 10")
	var valve := _env("amd-rdna3", "valve11", {"upscaler": "fsr"})
	eq(valve["env"], {}, "Valve Proton: nothing to set")
	ok(valve["notes"].size() > 0, "Valve Proton: says why")


func test_auto_upscaler_per_family() -> void:
	eq(_env("amd-rdna3", "cachy11")["upscaler"], "fsr", "RDNA3 + CachyOS -> FSR 4")
	eq(_env("amd-rdna3", "valve11")["upscaler"], "off", "RDNA3 + Valve -> game's own")
	eq(_env("amd-rdna2", "cachy11")["upscaler"], "off", "RDNA2 never gets FSR 4")
	eq(_env("amd-rdna2", "cachy11", {"upscaler": "fsr"})["env"].has("PROTON_FSR4_UPGRADE"), false, "RDNA2 fsr: no upgrade")
	eq(_env("intel-xe3", "valve11")["upscaler"], "xess", "Xe3 with XMX driver -> XeSS")
	eq(_env("intel-xe3", "valve11", {}, {"xess_xmx": false})["upscaler"], "off", "Xe3 without driver -> game's own")
	eq(_env("intel-xe-lpg", "valve11")["upscaler"], "off", "Xe-LPG has no XMX")


func test_indicator_only_with_fsr4() -> void:
	var s := _settings({"upscaler": "fsr"})
	var on := LaunchEnv.compose(s, {"gpu_family": "amd-rdna3"}, _protons()["cachy11"], {}, {}, {"indicator": true})
	eq(on["env"].get("PROTON_FSR4_INDICATOR"), "1", "indicator with FSR 4")
	var off := LaunchEnv.compose(s, {"gpu_family": "amd-rdna3"}, _protons()["valve11"], {}, {}, {"indicator": true})
	ok(not off["env"].has("PROTON_FSR4_INDICATOR"), "no indicator without FSR 4")


func test_low_latency_layer() -> void:
	eq(_env("amd-rdna3", "cachy11")["env"].get("LOW_LATENCY_LAYER"), "1", "bundled in CachyOS 11")
	ok(not _env("amd-rdna3", "valve11")["env"].has("LOW_LATENCY_LAYER"), "not in Valve Proton")
	eq(_env("amd-rdna3", "valve11", {}, {"low_latency_layer": true})["env"].get("LOW_LATENCY_LAYER"), "1", "host layer")
	ok(not _env("amd-rdna3", "cachy11", {"low_latency": false})["env"].has("LOW_LATENCY_LAYER"), "off when asked")
	ok(not _env("intel-xe3", "cachy11")["env"].has("LOW_LATENCY_LAYER_REFLEX"), "Anti-Lag 2 by default")


func test_intel_xmx_variables() -> void:
	var fsr: Dictionary = _env("intel-xe3", "valve11", {"upscaler": "fsr", "frame_gen": true})["env"]
	eq(fsr.get("FSR"), "xess", "FSR on XeSS")
	eq(fsr.get("XESS_FG"), "2", "XeSS frame generation")
	ok(not fsr.has("FSR_FG"), "FSR=xess already covers frame generation")
	var fg: Dictionary = _env("intel-xe2", "valve11", {"frame_gen": true})["env"]
	eq(fg.get("FSR_FG"), "xess", "FSR frame generation onto XeSS-FG")
	eq(_env("intel-xe3", "valve11", {"low_latency": false})["env"].get("IGDEXT_XELL_CAP"), "off", "XeLL off when asked")
	eq(_env("intel-xe3", "valve11", {"frame_gen": true}, {"xess_xmx": false})["env"], {}, "no driver: nothing")
	eq(_env("intel-xe-lpg", "valve11", {"frame_gen": true})["env"], {}, "no XMX: nothing")


func test_proton11_shows_intel_gpu_for_explicit_xess() -> void:
	eq(_env("intel-xe3", "valve11", {"upscaler": "xess"})["env"].get("DXVK_CONFIG"), LaunchEnv.SHOW_INTEL, "Proton 11")
	ok(not _env("intel-xe3", "valve9", {"upscaler": "xess"})["env"].has("DXVK_CONFIG"), "Proton 9 doesn't hide it")
	ok(not _env("intel-xe3", "valve11")["env"].has("DXVK_CONFIG"), "auto leaves it alone")
	ok(not _env("intel-xe3", "ge10", {"upscaler": "xess"})["env"].has("DXVK_CONFIG"), "GE 10")


func test_optiscaler_only_on_cachyos11_without_anticheat() -> void:
	eq(_env("intel-xe3", "cachy11", {"upscaler": "xess"})["env"].get("PROTON_USE_OPTISCALER"), "1", "CachyOS 11")
	ok(not _env("intel-xe3", "valve11", {"upscaler": "xess"})["env"].has("PROTON_USE_OPTISCALER"), "Valve")
	ok(not _env("intel-xe3", "cachy10", {"upscaler": "xess"})["env"].has("PROTON_USE_OPTISCALER"), "CachyOS 10")
	var ac := _env("intel-xe3", "cachy11", {"upscaler": "xess"}, {}, {"anticheat": true})
	ok(not ac["env"].has("PROTON_USE_OPTISCALER"), "never with anti-cheat")


func test_frame_gen_needs_40_fps() -> void:
	var low := _env("intel-xe3", "valve11", {"frame_gen": true}, {}, {"base_fps": 32})
	eq(low["frame_gen"], false, "32 fps: off")
	ok(not low["env"].has("XESS_FG"), "32 fps: no XESS_FG")
	eq(_env("intel-xe3", "valve11", {"frame_gen": true}, {}, {"base_fps": 45})["frame_gen"], true, "45 fps: on")
	eq(_env("intel-xe3", "valve11", {"frame_gen": true}, {}, {"base_fps": -1})["frame_gen"], true, "unknown: on")
	eq(_env("intel-xe3", "valve11", {"frame_gen": true, "fps_limit": 60})["frame_gen"], false, "60 cap = 30 base: off")
	eq(_env("intel-xe3", "valve11", {"frame_gen": true, "fps_limit": 90})["frame_gen"], true, "90 cap = 45 base: on")


func test_native_games_get_nothing() -> void:
	eq(_env("amd-rdna3", "valve11", {"upscaler": "fsr"})["env"], {}, "sanity")
	var native := LaunchEnv.compose(_settings({"upscaler": "fsr", "frame_gen": true}), {"gpu_family": "amd-rdna3"},
		Proton.classify(""), {"low_latency_layer": true})
	eq(native["env"], {}, "native: empty")


func test_nvapi_spoofing_conflicts_with_fsr4() -> void:
	for spoof in ["PROTON_FORCE_NVAPI", "LOW_LATENCY_LAYER_SPOOF_NVIDIA"]:
		var plan := _env("amd-rdna3", "cachy11", {"upscaler": "fsr"}, {}, {"extra_env": {spoof: "1"}})
		ok("nvapi_spoof_breaks_fsr4" in _ids(plan), spoof + " flagged")
		eq(plan["env"].get(spoof), "1", "user's variable kept")
	var no_fsr := _env("amd-rdna3", "cachy11", {"upscaler": "off"}, {}, {"extra_env": {"PROTON_FORCE_NVAPI": "1"}})
	eq(_ids(no_fsr), [], "spoofing alone is fine")
	var zero := _env("amd-rdna3", "cachy11", {"upscaler": "fsr"}, {}, {"extra_env": {"PROTON_FORCE_NVAPI": "0"}})
	eq(_ids(zero), [], "=0 is off")


func test_other_conflicts() -> void:
	var p := _protons()
	eq(_ids({"conflicts": LaunchEnv.conflicts({"PROTON_FSR4_RDNA3_UPGRADE": "1"}, "amd-rdna3", p["cachy11"])}),
		["removed_var"], "RDNA3 var removed in CachyOS 11")
	eq(_ids({"conflicts": LaunchEnv.conflicts({"PROTON_FSR4_RDNA3_UPGRADE": "1"}, "amd-rdna3", p["cachy10"])}),
		[], "fine in CachyOS 10")
	eq(_ids({"conflicts": LaunchEnv.conflicts({"PROTON_FSR3_UPGRADE": "1"}, "amd-rdna3", p["cachy11"])}),
		["renamed_var"], "FSR3 var renamed")
	eq(_ids({"conflicts": LaunchEnv.conflicts({"LOW_LATENCY_LAYER": "1", "DISABLE_LOW_LATENCY_LAYER": "1"}, "amd-rdna3", p["cachy11"])}),
		["low_latency_disabled"], "disable wins")
	eq(_ids({"conflicts": LaunchEnv.conflicts({"PROTON_USE_OPTISCALER": "1"}, "intel-xe3", p["cachy11"], true, true)}),
		["optiscaler_anticheat"], "OptiScaler with anti-cheat")
	eq(_ids({"conflicts": LaunchEnv.conflicts({"PROTON_FSR4_UPGRADE": "1"}, "intel-xe3", p["cachy11"], false, true)}),
		["fsr4_needs_amd"], "FSR 4 upgrade on Intel")
	eq(_ids({"conflicts": LaunchEnv.conflicts({"XESS_FG": "2"}, "intel-xe3", p["valve11"], false, false)}),
		["needs_xess_xmx"], "XeSS variables without the driver")


func test_dxvk_config_entries_are_joined() -> void:
	var plan := _env("intel-xe3", "valve11", {"upscaler": "xess"}, {}, {"extra_env": {"DXVK_CONFIG": "dxgi.maxFrameRate = 60"}})
	eq(plan["env"]["DXVK_CONFIG"], LaunchEnv.SHOW_INTEL + "; dxgi.maxFrameRate = 60", "joined")
