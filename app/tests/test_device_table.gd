extends "res://tests/test_case.gd"
## devices.json: every row valid, names it refers to exist, the Claw 8 EX row
## unchanged.

const DeviceScript := preload("res://scripts/device/device.gd")
const Buttons := preload("res://scripts/device/buttons.gd")


func test_every_row_passes_the_schema() -> void:
	var table := DeviceScript.load_table()
	ok(table.size() >= 50, "table has the popular handhelds (%d rows)" % table.size())
	for d in table:
		for problem in DeviceScript.row_problems(d):
			ok(false, problem)


func test_ids_unique() -> void:
	var seen := {}
	for d in DeviceScript.load_table():
		ok(not seen.has(d["id"]), "duplicate id " + d["id"])
		seen[d["id"]] = true


func test_rows_refer_to_existing_profiles_art_and_fixes() -> void:
	var fixes_dir := ProjectSettings.globalize_path("res://").path_join("../fixes")
	for d in DeviceScript.load_table():
		ok(Buttons.PROFILES.has(d["buttons"]), "%s: button profile %s" % [d["id"], d["buttons"]])
		ok(Buttons.SET_FILES.has(d["glyphs"]) or d["glyphs"] == "generic", "%s: glyph set %s" % [d["id"], d["glyphs"]])
		var art := "res://assets/devices/art/%s.svg" % d["art"]
		ok(ResourceLoader.exists(art), "%s: picture %s" % [d["id"], art])
		for f in d["fixes"]:
			ok(DirAccess.dir_exists_absolute(fixes_dir.path_join(f)), "%s: fix folder %s" % [d["id"], f])


func test_partial_rows_cite_sources() -> void:
	for d in DeviceScript.load_table():
		if d["support"] != "generic":
			ok(not (d.get("sources", []) as Array).is_empty(), "%s: sources" % d["id"])


func test_cpu_table_valid() -> void:
	var cpus: Array = DeviceScript.load_doc().get("cpus", [])
	ok(cpus.size() >= 10, "cpu fallback table")
	for c in cpus:
		var t: Dictionary = c["tdp"]
		ok(float(t["min"]) < float(t["battery_max"]) and float(t["battery_max"]) <= float(t["plugged_max"]), "%s tdp" % c["chip"])
		ok(c["gpu_family"] in DeviceScript.GPU_FAMILIES and c["gpu_arch"] in DeviceScript.GPU_ARCHS, "%s gpu" % c["chip"])


func test_claw_8_ex_row_kept() -> void:
	var ex := {}
	for d in DeviceScript.load_table():
		if d["id"] == "msi-claw-8-ex":
			ex = d
	eq(ex.get("match"), {"board_name": ["MS-1T91"]}, "match")
	eq(ex.get("tdp"), {"min": 8.0, "battery_max": 35.0, "plugged_max": 35.0, "boost_max": 45.0}, "tdp")
	eq(ex.get("profiles"), {"battery": 12.0, "balanced": 17.0, "performance": 25.0}, "profiles")
	eq(ex.get("tdp_backends"), ["powerstation"], "backends")
	eq(ex.get("fixes"), ["claw8ex-buttons", "claw8ex-vrr", "claw8ex-gyro", "claw-kbd-wakeup"], "fixes")
	eq(ex.get("vrr_range"), [30.0, 120.0], "vrr")
	eq(ex.get("fan"), "msi_wmi_platform", "fan")
	eq(ex.get("gpu_family"), "intel-xe3", "gpu family")
	eq(ex.get("support"), "full", "support")
	eq(ex.get("verified"), true, "verified")


func test_validator_catches_bad_rows() -> void:
	var good := {}
	for d in DeviceScript.load_table():
		if d["id"] == "asus-rog-ally":
			good = d.duplicate(true)
	eq(DeviceScript.row_problems(good), [], "Ally row is fine")
	var bad := good.duplicate(true)
	bad["tdp"] = {"min": 30, "battery_max": 25, "plugged_max": 20}
	ok(not DeviceScript.row_problems(bad).is_empty(), "inverted tdp caught")
	bad = good.duplicate(true)
	bad["panel_hz"] = [120, 60]
	ok(not DeviceScript.row_problems(bad).is_empty(), "inverted refresh caught")
	bad = good.duplicate(true)
	bad["vrr_range"] = [48, 144]
	ok(not DeviceScript.row_problems(bad).is_empty(), "VRR beyond panel caught")
	bad = good.duplicate(true)
	bad["match"] = {"board_name": ["RC7*"]}
	ok(not DeviceScript.row_problems(bad).is_empty(), "wildcard-only specific row caught")
	bad = good.duplicate(true)
	bad["verified"] = true
	bad["unverified"] = ["tdp"]
	ok(not DeviceScript.row_problems(bad).is_empty(), "verified flag mismatch caught")
	bad = good.duplicate(true)
	bad.erase("gyro")
	ok(not DeviceScript.row_problems(bad).is_empty(), "missing field caught")
