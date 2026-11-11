extends "res://tests/test_case.gd"
## devices.json: every row valid, names it refers to exist, the Claw 8 EX row
## unchanged.

const DeviceScript := preload("res://scripts/device/device.gd")
const Buttons := preload("res://scripts/device/buttons.gd")
const Caps := preload("res://scripts/controls/input/caps.gd")


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


# ---- by_os: what an OS release changes about a handheld (devices.json by_os) --------------------

func _row(id: String) -> Dictionary:
	for d in DeviceScript.load_table():
		if d["id"] == id:
			return d
	return {}


func test_legion_go_gyro_and_lights_follow_bazzite_44() -> void:
	var go := _row("lenovo-legion-go")
	var b44 := DeviceScript.for_os(go, {"family": "bazzite", "version": "44"})
	eq(b44["gyro"], "no", "Bazzite 44: gyro broken (Bazzite's Legion Go page)")
	ok(str(b44.get("gyro_reason", "")).contains("Bazzite 44"), "says why")
	eq(Caps.gyro_block(b44), b44["gyro_reason"], "the gyro control shows that reason")
	eq(b44["rgb"]["via"], "kernel", "lights: the kernel's LED node, no Handheld Daemon")
	ok(not (b44.get("os_notes", []) as Array).is_empty(), "os_notes say what changed")
	var b43 := DeviceScript.for_os(go, {"family": "bazzite", "version": "43"})
	eq(b43["gyro"], "yes", "Bazzite 43: as the row says")
	var steamos := DeviceScript.for_os(go, {"family": "steamos", "version": "3.8.2"})
	eq(steamos["gyro"], "yes", "SteamOS: gyro works")
	eq(go["gyro"], "yes", "the table row itself is never changed")
	eq(DeviceScript.for_os(go, {"family": "bazzite", "version": ""})["gyro"], "yes", "unknown version: as the row says")


func test_no_hhd_lights_promised_on_bazzite_44() -> void:
	# Bazzite 44 ships no Handheld Daemon: no row may say hhd runs the lights there
	for d in DeviceScript.load_table():
		var b := DeviceScript.for_os(d, {"family": "bazzite", "version": "44"})
		var rgb: Variant = b.get("rgb")
		ok(not (rgb is Dictionary and str(rgb.get("via", "")) == "hhd"), "%s: lights not by hhd on Bazzite 44" % d["id"])


func test_gyro_corrections_cite_bazzite() -> void:
	eq(_row("gpd-win-max-2")["gyro"], "no", "Win Max 2: Bazzite lists the gyro as non-functional")
	eq(_row("acer-predator-atlas-8")["gyro"], "no", "Atlas 8: gyro doesn't work in Linux (Bazzite)")
	ok(Caps.gyro_block(_row("gpd-win-max-2")) != "", "Win Max 2: the gyro control says why")


func test_x1_air_row() -> void:
	var r := _row("onexplayer-x1-air")
	eq(r.get("xmx"), true, "Lunar Lake: XMX")
	eq(r.get("gpu_family"), "intel-xe2", "Xe2")
	eq(r.get("fan"), "oxp_ec", "oxpec fan")
	eq(r["tdp"]["plugged_max"], 30.0, "hhd PL1 30")
	eq(r["tdp"]["boost_max"], 32.0, "PL2 = PL1 + 2")


func test_validator_catches_bad_by_os() -> void:
	var bad := _row("lenovo-legion-go").duplicate(true)
	bad["by_os"] = [{"os": "bazzite", "from": 44, "set": {"tdp": {"min": 1}}, "why": "x", "source": "y"}]
	ok(not DeviceScript.row_problems(bad).is_empty(), "by_os can't change limits")
	bad["by_os"] = [{"os": "bazzite", "set": {"gyro": "no"}}]
	ok(not DeviceScript.row_problems(bad).is_empty(), "by_os needs why and source")
	bad = _row("lenovo-legion-go").duplicate(true)
	bad["rgb"] = {"zones": "x", "via": "magic"}
	ok(not DeviceScript.row_problems(bad).is_empty(), "unknown rgb via caught")
