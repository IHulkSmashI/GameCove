extends "res://tests/test_case.gd"
## Every Controls provider against every handheld in devices.json (plus an
## unlisted AMD and Intel one). Harness: tests/devicematrix/matrix.gd;
## fixtures: tools/devicematrix/gen.py; per-device facts and expectations:
## tools/devicematrix/expectations.json. Set DEVICEMATRIX_REPORT=<file> to get
## what every control detected on every device as JSON.

const Matrix := preload("res://tests/devicematrix/matrix.gd")
const DeviceScript := preload("res://scripts/device/device.gd")
const GOOD := "res://tests/devicematrix/sample_good"
const BAD := "res://tests/devicematrix/sample_bad"


func _manifest() -> Dictionary:
	var m := Matrix.manifest()
	ok(not m.has("error"), "matrix generated: %s" % m.get("error", ""))
	return m


func _info(m: Dictionary, id: String) -> Dictionary:
	for d in m.get("devices", []):
		if d["id"] == id:
			return d
	return {}


func test_every_row_has_a_fixture_and_resolves_to_it() -> void:
	var m := _manifest()
	eq(m.get("problems", []), [], "generator self-check")
	for s in m.get("setups", []):
		var sd: Node = DeviceScript.new()
		sd.root = s["root"]
		sd.detect()
		eq(sd.id(), s["expect_row"], "setup %s resolves" % s["id"])
		sd.free()
	var ids := {}
	for d in m.get("devices", []):
		ids[d["id"]] = true
		var dev: Node = DeviceScript.new()
		dev.root = d["root"]
		dev.detect()
		eq(dev.id(), d["expect_row"], "%s resolves" % d["id"])
		if d["generic"]:
			eq(str(dev.profile.get("cpu_vendor", "")), d["vendor"], "%s generic row vendor" % d["id"])
		dev.free()
	for row in DeviceScript.load_table():
		ok(ids.has(row["id"]), "fixture for " + row["id"])
	ok(ids.has("generic-amd") and ids.has("generic-intel"), "generic AMD and Intel fixtures")


func test_expectations_file_is_valid() -> void:
	var m := _manifest()
	var ids: Array = m.get("devices", []).map(func(d): return d["id"])
	var e := Matrix.expectations()
	ok(not e.is_empty(), "expectations.json parses")
	eq(Matrix.expectation_file_problems(e, ids), [] as Array[String], "expectations.json")
	ok(e.get("facts", {}).size() >= 40, "seeded with community-tested facts")


func test_provider_sources_pass_lint() -> void:
	eq(Matrix.lint(), [] as Array[String], "providers reach the system only through ctx")


## The real providers (app/scripts/controls/providers/) on every fixture.
func test_all_providers_on_all_devices() -> void:
	var m := _manifest()
	var e := Matrix.expectations()
	var scripts := Matrix.provider_scripts()
	var report := {}
	var problems: Array[String] = []
	# every devices.json row, then the whole-OS setups the end-to-end suite uses
	# (gen.py SETUPS: Claw 8 EX and Legion Go S on Bazzite, ROG Ally on SteamOS)
	for d in m.get("devices", []) + m.get("setups", []):
		var r := Matrix.run_device(d, scripts, e)
		problems.append_array(r["problems"])
		report[d["id"]] = {"controls": r["report"], "unmatched_commands": r["unmatched"]}
	var out := OS.get_environment("DEVICEMATRIX_REPORT")
	if out != "":
		var f := FileAccess.open(out, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify({"providers": scripts, "devices": report}, " ", true))
			f.close()
	for p in problems.slice(0, 600):
		failures.append("%s: %s" % [_current, p])
	if problems.size() > 600:
		failures.append("%s: ... and %d more" % [_current, problems.size() - 600])


## The harness itself: a careful provider passes everywhere it's tried...
func test_harness_passes_a_careful_provider() -> void:
	var m := _manifest()
	var e := Matrix.expectations()
	e["devices"] = {}   # per-device promises belong to the real providers, not this sample
	var scripts := Matrix.provider_scripts(GOOD)
	for id in ["msi-claw-8-ex", "asus-rog-ally", "lenovo-legion-go-2", "steam-deck-oled", "aokzoe-a1-pro", "onexplayer-2-pro", "onexplayer-3", "generic-amd", "generic-intel"]:
		var r := Matrix.run_device(_info(m, id), scripts, e)
		eq(r["problems"], [] as Array[String], id)
		ok(r["report"]["battery"]["power.tdp_steamos"]["available"] == ("steamos-manager" in _info(m, id)["stack"]), "%s steamos-manager follows the stack" % id)
		ok(not r["report"]["bare"]["power.tdp_steamos"]["available"], "%s nothing answers in bare" % id)


## ...and a careless one is caught on each rule.
func test_harness_catches_a_careless_provider() -> void:
	var m := _manifest()
	var e := Matrix.expectations()
	e["devices"] = {}
	var r := Matrix.run_device(_info(m, "asus-rog-ally"), Matrix.provider_scripts(BAD), e)
	var text := "\n".join(r["problems"])
	for needle in ["backlight", "one short line", "ppt_pl1_spl", "power.tdp range", "real path",
			"id must be", "not restored", "above the 30 W known safe here",
			"power.fan_curve: 4 points, the asus_custom_fan_curve table has 8", "quieter than Quiet", "falls at point"]:
		ok(needle in text, "caught: " + needle)
	var r2 := Matrix.run_device(_info(m, "aokzoe-a1"), Matrix.provider_scripts(BAD), e)
	ok("has no RGB" in "\n".join(r2["problems"]), "RGB offered where HueSync/hhd say there is none")


func test_expectations_are_enforced() -> void:
	var m := _manifest()
	var e := {"invariants": {}, "facts": {}, "devices": {
		"lenovo-legion-go-s-z2go": {"power.tdp": {"available": true, "max": 99}, "controller.nope": {"available": true}},
		"vendor:intel": {"power.tdp": {"min": 1}}}}
	var r := Matrix.run_device(_info(m, "lenovo-legion-go-s-z2go"), Matrix.provider_scripts(GOOD), e)
	var text := "\n".join(r["problems"])
	ok("power.tdp (lenovo-legion-go-s-z2go): max 33" in text, "max checked against the row's 33 W")
	ok("controller.nope expected but no provider registers it" in text, "missing control reported")
	ok(not "vendor:intel" in text, "selector skipped on AMD")


## Fan curves: one duty per table point, 0-100 %, never falling, never under Quiet.
func test_curve_rules() -> void:
	var row := {"fan": "asus_custom_fan_curve"}
	eq(Matrix.curve_problems([2, 5, 17, 35, 55, 75, 75, 100], null, row), [] as Array[String], "Quiet itself is fine")
	# review L6: Quiet ends at full speed, so a curve that stops short of it at the hottest point is refused
	ok("point 8 = 75 is quieter than Quiet (100)" in "\n".join(Matrix.curve_problems([2, 5, 17, 35, 55, 75, 75, 75], null, row)), "old 75 % top refused")
	eq(Matrix.curve_problems([100, 100, 100, 100, 100, 100, 100, 100], null, row), [] as Array[String], "Max is fine")
	var t := "\n".join(Matrix.curve_problems([0, 5, 17, 35, 55, 75, 75, 100], null, row))
	ok("point 1 = 0 is quieter than Quiet (2)" in t, "under Quiet caught: " + t)
	t = "\n".join(Matrix.curve_problems([2, 5, 17, 35, 55, 80, 76, 101], null, row))
	ok("falls at point 7" in t and "point 8 = 101 outside 0..100" in t, "falling and over 100 caught: " + t)
	ok("has 3 points" in "\n".join(Matrix.curve_problems([50, 60, 70], null, row)), "point count")
	eq(Matrix.fan_table({"fan": "oxp_ec"}), {}, "manual fan drivers have no curve")


func after_all() -> void:
	Matrix.cleanup()


## Each run generates into its own folder; stale ones (marker, older than an hour) go.
func test_runs_use_their_own_folder_and_stale_ones_go() -> void:
	var m := _manifest()
	var root := str(m.get("devices", [{}])[0].get("root", ""))
	if OS.get_environment("DEVICEMATRIX_DIR") == "":
		ok(("devicematrix-%d" % OS.get_process_id()) in root, "this run's folder: " + root)
	var base := OS.get_user_data_dir()
	var old := base.path_join("devicematrix-999999999")
	var other := base.path_join("devicematrix-999999998")
	for d in [old, other]:
		DirAccess.make_dir_recursive_absolute(d.path_join("x"))
	var f := FileAccess.open(old.path_join(Matrix.MARKER), FileAccess.WRITE)
	f.store_string("")
	f.close()
	ok(not "devicematrix-999999999" in Matrix.clean_stale(3600), "a fresh one (another run going on) stays")
	OS.execute("touch", PackedStringArray(["-d", "2 hours ago", old.path_join(Matrix.MARKER)]))
	var gone := Matrix.clean_stale(3600)
	ok("devicematrix-999999999" in gone and DirAccess.dir_exists_absolute(other), "only folders with gen.py's marker: %s" % [gone])
	ok(not DirAccess.dir_exists_absolute(old), "removed")
	Matrix._rm_tree(other)


## The three test handhelds have their promises written down (tools/devicematrix/expectations.json).
func test_test_handhelds_have_expectations() -> void:
	var d: Dictionary = Matrix.expectations().get("devices", {})
	for id in ["msi-claw-8-ex", "lenovo-legion-go-s-z2go", "asus-rog-ally"]:
		ok(d.get(id, {}).size() > 30 and str(d.get(id, {}).get("_source", "")) != "", id + " covered with a source")
