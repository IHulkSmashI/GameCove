extends "res://tests/test_case.gd"
## Proton flavour detection from tool names, compatibilitytools.d and Steam's config.vdf.

const Proton := preload("res://scripts/launch/proton.gd")
const VDF := preload("res://scripts/launch/vdf.gd")
const LauncherScript := preload("res://scripts/launch/launcher.gd")


func _sig(d: Dictionary) -> String:
	return "%s %d.%d" % [d["flavour"], d["major"], d["minor"]]


func test_classify_names() -> void:
	eq(_sig(Proton.classify("GE-Proton10-25")), "ge 10.25", "GE")
	eq(_sig(Proton.classify("Proton-9.23-GE-2")), "ge 9.23", "old GE name")
	eq(_sig(Proton.classify("proton-cachyos-11.0-20260702-slr")), "cachyos 11.0", "CachyOS folder")
	eq(_sig(Proton.classify("1757000000 cachyos-10.0-20250905-slr")), "cachyos 10.0", "CachyOS version file")
	eq(Proton.classify("proton-cachyos")["major"], -1, "CachyOS without version")
	eq(_sig(Proton.classify("proton_11")), "valve 11.0", "proton_11")
	eq(_sig(Proton.classify("Proton 9.0")), "valve 9.0", "Proton 9.0")
	eq(_sig(Proton.classify("1730000000 proton-9.0-4")), "valve 9.0", "Valve version file")
	eq(Proton.classify("proton_experimental")["flavour"], "valve", "experimental")
	eq(Proton.classify("proton_experimental")["major"], Proton.VALVE_LATEST_MAJOR, "experimental = latest")
	eq(Proton.classify("")["flavour"], "native", "no tool")
	eq(Proton.classify("Luxtorpeda")["flavour"], "other", "unknown tool")


func test_vdf_parser() -> void:
	var d := VDF.parse("\"a\" { \"b\" \"1\" // note\n \"C\" { \"d\" \"x \\\"y\\\"\" } }")
	eq(VDF.get_ci(d["a"], "b"), "1", "value")
	eq(VDF.get_ci(VDF.get_ci(d["a"], "c"), "d"), "x \"y\"", "case-insensitive key, escaped quotes")
	eq(VDF.find_ci(d, "c"), {"d": "x \"y\""}, "find nested")


func _dirs() -> Array:
	var steam := fixture("launch/home/.local/share/Steam")
	return Proton.tool_dirs(steam, fixture("launch/root"))


func test_tools_found_by_internal_name() -> void:
	var t := Proton.tools(_dirs())
	ok(t.has("GE-Proton10-25"), "GE in user dir")
	ok(t.has("proton-cachyos-slr"), "CachyOS by internal name")
	ok(t.has("proton-cachyos"), "system-wide CachyOS")


func test_steam_mapping_per_game() -> void:
	var steam := fixture("launch/home/.local/share/Steam")
	var dirs := _dirs()
	var cases := {"100": "ge 10.25", "200": "cachyos 11.0", "300": "valve 11.0", "400": "cachyos 10.0", "999": "valve 11.0"}
	for appid in cases:
		var p := Proton.for_game({"store": "steam", "id": appid}, steam, dirs)
		eq(_sig(p), cases[appid], "appid " + appid)


func test_no_config_means_steam_default() -> void:
	var p := Proton.for_game({"store": "steam", "id": "1"}, "/nonexistent", [])
	eq(p["flavour"], "valve", "default is Valve Proton")
	eq(p["source"], "steam-default", "marked as default")


func test_non_steam_games_use_umu() -> void:
	eq(Proton.for_game({"store": "epic", "id": "x"}, "", [])["source"], "umu-default", "umu default")
	eq(_sig(Proton.for_game({"store": "gog", "id": "x", "proton": "GE-Proton10-25"}, "", _dirs())), "ge 10.25", "picked GE")


func test_launcher_plan_reads_the_system_through_overrides() -> void:
	var l: Node = LauncherScript.new()
	l.home = fixture("launch/home")
	l.root_prefix = fixture("launch/root")
	l.settings_path = OS.get_user_data_dir().path_join("test_launch_plan.json")
	DirAccess.remove_absolute(l.settings_path)
	l.device_profile = {"gpu_family": "amd-rdna3", "xmx": false}
	var plan: Dictionary = l.launch_plan({"key": "steam:200", "store": "steam", "id": "200"})
	eq(plan["proton"]["flavour"], "cachyos", "CachyOS from the fixture")
	eq(plan["env"].get("PROTON_FSR4_UPGRADE"), "1", "auto -> FSR 4 on RDNA3")
	eq(plan["env"].get("LOW_LATENCY_LAYER"), "1", "low latency")
	ok(l.low_latency_layer_installed(), "host layer found in fake root")
	ok(not l.xess_xmx_installed(), "no XMX driver in this home")
	l.home = fixture("launch/xmxhome")
	ok(l.xess_xmx_installed(), "XMX driver found")
	l.free()


func test_the_launch_swap_follows_the_helpers_hands_off_fact() -> void:
	# review H3: PROTON_FSR4_UPGRADE was decided on the app's anti-cheat data alone, so a game the helper refuses (an
	# anti-cheat in its folder or its list note, another tool's files) or an online game nobody added ours to still
	# got the swap at launch
	var l: Node = LauncherScript.new()
	l.home = fixture("launch/home")
	l.root_prefix = fixture("launch/root")
	l.settings_path = OS.get_user_data_dir().path_join("test_launch_hands_off.json")
	DirAccess.remove_absolute(l.settings_path)
	l.device_profile = {"gpu_family": "amd-rdna3", "xmx": false}
	var game := {"key": "steam:200", "store": "steam", "id": "200"}
	eq(l.launch_plan(game)["env"].get("PROTON_FSR4_UPGRADE"), "1", "no hook: the swap, as before")
	var off := {"v": true, "asked": []}
	l.hands_off_hooks.append(func(key: String, g: Dictionary) -> bool:
		off["asked"].append([key, str(g.get("id", ""))])
		return off["v"])
	var plan: Dictionary = l.launch_plan(game)
	ok(not plan["env"].has("PROTON_FSR4_UPGRADE"), "hands off: no FSR 4 swap")
	ok(plan["notes"].any(func(n): return "Left alone" in n), "and it says why: " + str(plan["notes"]))
	eq(off["asked"][-1], ["steam:200", "200"], "the hook gets the game")
	off["v"] = false
	eq(l.launch_plan(game)["env"].get("PROTON_FSR4_UPGRADE"), "1", "added to the game: the swap is back")
	l.device_profile = {"gpu_family": "intel-xe3", "xmx": true}
	off["v"] = true
	ok(not l.launch_plan(game)["env"].has("FSR"), "nor FSR on XeSS on Intel")
	l.free()
