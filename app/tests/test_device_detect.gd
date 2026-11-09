extends "res://tests/test_case.gd"
## Detection: real DMI ids resolve to exactly one row; unknown hardware gets a
## sane generic row from its CPU and GPU.

const DeviceScript := preload("res://scripts/device/device.gd")


func _fixtures() -> Array:
	var raw := FileAccess.get_file_as_string("res://tests/fixtures/devices/dmi.json")
	return JSON.parse_string(raw)["fixtures"]


func test_every_fixture_resolves_to_its_row() -> void:
	var doc := DeviceScript.load_doc()
	for f in _fixtures():
		var row := DeviceScript.resolve(doc, f["dmi"], "", {})
		var want: String = f["expect"]
		eq(row.get("id", ""), want if want != "" else "unknown", "%s / %s" % [f["dmi"]["sys_vendor"], f["dmi"]["product_name"]])


func test_no_overlapping_specific_rows() -> void:
	var table := DeviceScript.load_table()
	for f in _fixtures():
		var specific := DeviceScript.matching_rows(table, f["dmi"]).filter(func(r): return r.get("tier") == "specific")
		var ids := specific.map(func(r): return r["id"])
		if str(f["expect"]).ends_with("-family") or f["expect"] == "":
			eq(ids, [], "no specific row for %s" % f["dmi"]["product_name"])
		else:
			eq(ids.size(), 1, "exactly one specific row for %s: %s" % [f["dmi"]["product_name"], ids])


func test_every_specific_row_has_a_fixture() -> void:
	var covered := {}
	for f in _fixtures():
		covered[f["expect"]] = true
	for d in DeviceScript.load_table():
		ok(covered.has(d["id"]), "fixture for " + d["id"])


func test_specific_beats_family() -> void:
	var table := DeviceScript.load_table()
	var dmi := {"sys_vendor": "Micro-Star International Co., Ltd.", "board_vendor": "Micro-Star International Co., Ltd.",
		"board_name": "MS-1T52", "product_name": "Claw 8 AI+ A2VM", "product_family": ""}
	var rows := DeviceScript.matching_rows(table, dmi)
	eq(rows.map(func(r): return r["id"]), ["msi-claw-8-ai-plus", "msi-claw-family"], "both match, specific first")


func test_legacy_match_device_still_works() -> void:
	var table := DeviceScript.load_table()
	eq(DeviceScript.match_device(table, "MS-1T91", "Claw 8 EX AI+ CG3EM Launch Pack").get("id", ""), "msi-claw-8-ex", "board")
	eq(DeviceScript.match_device(table, "", "Jupiter").get("id", ""), "steam-deck-lcd", "product")
	eq(DeviceScript.match_device(table, "", "NEXT II"), {}, "vendor-only family rows need sys_vendor")


func test_match_is_case_insensitive_glob() -> void:
	var row := {"tier": "specific", "match": {"sys_vendor": ["ayaneo"], "product_name": ["AIR 1S*"]}}
	ok(DeviceScript.match_score(row, {"sys_vendor": "AYANEO", "product_name": "AIR 1S Limited"}) > 0, "glob + case")
	eq(DeviceScript.match_score(row, {"sys_vendor": "AYANEO", "product_name": ""}), -1, "empty value never matches")
	eq(DeviceScript.match_score(row, {}), -1, "nothing compared, no match")


func test_unknown_amd_handheld_gets_cpu_defaults() -> void:
	var d: Node = DeviceScript.new()
	d.root = fixture("devices/sys_unknown")
	d.detect()
	eq(d.id(), "unknown", "not in the table")
	eq(d.support_level(), "generic", "generic support")
	eq(d.display_name(), "Pocket Z2", "name from DMI")
	eq(d.profile["gpu_family"], "amd-rdna3", "Z2 Extreme -> RDNA 3 family (FSR 4 path)")
	eq(d.profile["gpu_arch"], "RDNA3.5", "arch")
	eq(d.profile["tdp"], {"min": 8.0, "battery_max": 30.0, "plugged_max": 35.0}, "PowerStation's Z2 Extreme range")
	eq(d.gpu["driver"], "amdgpu", "gpu driver")
	eq(d.picture(), "res://assets/devices/art/generic.svg", "generic picture")
	eq(d.glyph_set(), "xbox", "xbox glyphs")
	eq(DeviceScript.row_problems(d.profile), [], "fallback row passes the schema")
	d.free()


func test_unknown_intel_xe_handheld() -> void:
	var d: Node = DeviceScript.new()
	d.root = fixture("devices/sys_unknown_xe")
	d.detect()
	eq(d.profile["gpu_family"], "intel-xe2", "xe driver -> Xe2 or newer")
	eq(d.profile["cpu_vendor"], "intel", "intel")
	ok(float(d.profile["tdp"]["min"]) >= 8.0 and float(d.profile["tdp"]["battery_max"]) <= 30.0, "conservative Intel range")
	d.free()


func test_family_row_takes_chip_from_cpu() -> void:
	var doc := DeviceScript.load_doc()
	var dmi := {"sys_vendor": "ONE-NETBOOK", "product_name": "ONEXPLAYER NEXT THING", "board_name": "", "board_vendor": "", "product_family": ""}
	var row := DeviceScript.resolve(doc, dmi, "AMD Ryzen AI 9 HX 370 w/ Radeon 890M", {})
	eq(row["id"], "onexplayer-family", "family")
	eq(row["gpu_arch"], "RDNA3.5", "arch from cpu")
	eq(row["tdp"]["battery_max"], 28.0, "range from cpu table")


func test_unlisted_claw_takes_its_cpu_vendor_from_the_cpu() -> void:
	# review S5-2: the msi-claw-family row no longer says "amd"; an unlisted Intel Claw is Intel
	var doc := DeviceScript.load_doc()
	var dmi := {"sys_vendor": "Micro-Star International Co., Ltd.", "product_name": "Claw Next", "board_name": "MS-1T99",
		"board_vendor": "Micro-Star International Co., Ltd.", "product_family": ""}
	var row := DeviceScript.resolve(doc, dmi, "Intel(R) Core(TM) Ultra 9 999X", {})
	eq(row["id"], "msi-claw-family", "family row")
	eq(row["cpu_vendor"], "intel", "Intel from the CPU name")
	eq(DeviceScript.resolve(doc, dmi, "AMD Ryzen Z9 Extreme", {})["cpu_vendor"], "amd", "AMD from the CPU name")
	eq(DeviceScript.resolve(doc, dmi, "", {"vendor": "intel"})["cpu_vendor"], "intel", "else the GPU's vendor")


func test_multi_chip_row_refined_by_cpu() -> void:
	var doc := DeviceScript.load_doc()
	var dmi := {"sys_vendor": "GPD", "product_name": "G1618-04", "board_name": "Default string", "board_vendor": "GPD", "product_family": ""}
	var early := DeviceScript.resolve(doc, dmi, "AMD Ryzen 7 6800U with Radeon Graphics", {})
	eq(early["gpu_family"], "amd-rdna2", "WIN 4 with 6800U is RDNA 2")
	eq(early["tdp"]["battery_max"], 28.0, "row's own TDP kept")
	var late := DeviceScript.resolve(doc, dmi, "AMD Ryzen 7 8840U w/ Radeon 780M Graphics", {})
	eq(late["gpu_family"], "amd-rdna3", "8840U is RDNA 3")


func test_detect_from_sysfs() -> void:
	var d: Node = DeviceScript.new()
	d.root = fixture("devices/sys_ally")
	d.detect()
	eq(d.id(), "asus-rog-ally", "Ally from sysfs")
	eq(d.display_name(), "ASUS ROG Ally", "name")
	eq(d.maker(), "ASUS", "maker")
	eq(d.chip(), "AMD Ryzen Z1 Extreme", "chip from cpu (row sold with Z1 and Z1 Extreme)")
	eq(d.picture(), "res://assets/devices/art/rog-ally.svg", "picture")
	var f: Dictionary = d.features()
	eq(f["gyro"], "yes", "gyro")
	ok(f["rgb"] and f["charge_limit"] and f["tdp"] and f["vrr"], "rgb, charge, tdp, vrr")
	eq(f["paddles"], 2, "two back buttons")
	d.free()
