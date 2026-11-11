extends "res://tests/test_case.gd"
## Shared-component traits (devices.json "traits"), selectors, and fixes /
## quirks that follow the shared part instead of a model id.

const Traits := preload("res://scripts/device/traits.gd")
const FixesSvc := preload("res://scripts/device/fixes.gd")
const Plan := preload("res://scripts/installer/plan.gd")


func _rows() -> Array:
	return JSON.parse_string(FileAccess.get_file_as_string("res://data/devices.json"))["devices"]


func _row(id: String) -> Dictionary:
	for r in _rows():
		if r["id"] == id:
			return r
	return {}


func _cat() -> Array:
	return Traits.load_fixes()


func _entry(id: String) -> Dictionary:
	for e in _cat():
		if e["id"] == id:
			return e
	return {}


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").simplify_path()


func _fixset(fix: String, key: String) -> Array:
	var e := _entry(fix)
	var out: Array = []
	for r in _rows():
		if (Traits.fix_auto(e, r) if key == "auto" else Traits.fix_optional(e, r)):
			out.append(r["id"])
	out.sort()
	return out


func _sorted(a: Array) -> Array:
	var b := a.duplicate()
	b.sort()
	return b


# ------------------------------------------------------------ schema

func test_every_row_has_valid_traits() -> void:
	var doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/devices.json"))
	var src: Dictionary = doc.get("_trait_sources", {})
	ok(src.size() > 5, "_trait_sources lists the sources")
	for r in _rows():
		eq(Traits.trait_problems(r), [], r["id"] + ": traits")
		for s in r["traits"].get("sources", []):
			ok(src.has(s), "%s: source %s is described" % [r["id"], s])
		var t: Dictionary = r["traits"]
		if t["cpu_vendor"] != null:
			eq(t["cpu_vendor"], r["cpu_vendor"], r["id"] + ": traits.cpu_vendor = cpu_vendor")
		if t["gpu_arch"] != null and str(r["gpu_arch"]) != "unknown":
			ok(str(r["gpu_arch"]).to_lower() in t["gpu_arch"], r["id"] + ": traits.gpu_arch has gpu_arch")


func test_bad_traits_are_reported() -> void:
	var r := _row("asus-rog-ally").duplicate(true)
	r["traits"]["soc"] = "Phoenix"
	r["traits"]["bogus"] = 1
	r["traits"].erase("wifi")
	var p := Traits.trait_problems(r)
	ok(p.any(func(x): return "soc" in x), "a list trait given as a string")
	ok(p.any(func(x): return "bogus" in x), "unknown trait")
	ok(p.any(func(x): return "wifi missing" in x), "missing trait")
	eq(Traits.trait_problems({"id": "x"}), ["x: missing traits"], "no traits at all")


func test_platform_groups_share_a_body() -> void:
	for pair in [["msi-claw-8-ex", "msi-claw-8-ai-plus"], ["lenovo-legion-go-2", "lenovo-legion-go-2-z2"],
			["onexplayer-2", "onexplayer-2-pro"], ["aokzoe-a1", "aokzoe-a1-pro"], ["ayaneo-2", "ayaneo-2s"],
			["lenovo-legion-go-s-z2go", "lenovo-legion-go-s-z1e"], ["asus-rog-xbox-ally", "asus-rog-xbox-ally-x"]]:
		eq(_row(pair[0])["traits"]["platform"], _row(pair[1])["traits"]["platform"], "%s and %s share a platform" % pair)


# ------------------------------------------------------------ selectors

func test_selector_grammar() -> void:
	var claw := _row("msi-claw-8-ex")
	var ally := _row("asus-rog-ally")
	ok(Traits.matches("*", claw), "* matches")
	ok(Traits.matches("msi-claw-8-ex", claw) and not Traits.matches("msi-claw-8-ex", ally), "plain id")
	ok(Traits.matches("soc:panther-lake", claw), "list trait")
	ok(Traits.matches("SOC:PANTHER-*", claw) == false, "keys are case-sensitive")
	ok(Traits.matches("soc:PANTHER-*", claw), "values: globs, any case")
	ok(Traits.matches("gpu_arch:rdna3|xe3", claw) and Traits.matches("gpu_arch:rdna3|xe3", ally), "alternatives")
	ok(Traits.matches("driver:xe", claw) and Traits.matches("driver:asus-armoury", ally), "driver = gpu driver or EC")
	ok(Traits.matches("vendor:intel", claw), "vendor = cpu_vendor")
	ok(Traits.matches("panel:csw-pn8007qb1-2", claw), "panel = panel id")
	ok(Traits.matches("panel.type:ips", claw) and Traits.matches("panel.hz:60-120", claw), "panel fields")
	ok(Traits.matches("fingerprint:1c7a:0588", ally), "a value may hold ':'")
	ok(Traits.matches(["soc:nope", "controller:msi-claw"], claw), "list = any-of")
	ok(Traits.matches({"all-of": ["controller:msi-claw", "cpu_vendor:intel"]}, claw), "all-of")
	ok(not Traits.matches({"all-of": ["controller:msi-claw", "cpu_vendor:amd"]}, claw), "all-of fails on one")
	ok(Traits.matches({"not": "cpu_vendor:amd"}, claw), "not")
	ok(not Traits.matches("wifi:ax210", {"id": "x"}), "no traits: only * and the id match")
	ok(not Traits.matches({"bogus": []}, claw), "unknown operator matches nothing")
	eq(Traits.why({"all-of": ["controller:msi-claw", "cpu_vendor:intel"]}, claw), "controller msi-claw and cpu_vendor intel", "why")


func test_selectors_resolve_to_the_sharing_models() -> void:
	var rows := _rows()
	eq(_sorted(Traits.resolve("controller:asus-ally-x", rows)),
		["asus-rog-ally-x", "asus-rog-xbox-ally", "asus-rog-xbox-ally-x", "asus-rog-xbox-ally-x20"], "ASUS controller 0b05:1b4c")
	eq(_sorted(Traits.resolve("panel:csw-pn8007qb1-2", rows)), ["msi-claw-8-ai-plus", "msi-claw-8-ex"], "Claw 8 panel")
	eq(_sorted(Traits.resolve("panel:tmx-tl070fvxs02-0", rows)), ["msi-claw-7-ai-plus", "msi-claw-a1m"], "Claw 7 panel")
	ok(Traits.resolve("ec:oxpec", rows).has("orangepi-neo"), "the Orange Pi Neo shares the OneXPlayer EC")
	eq(Traits.resolve("controller:msi-claw", rows).size(), 6, "every Claw row has the Claw controller")
	eq(Traits.resolve("msi-claw-8-ex", rows, {"msi-claw-8-ex": "why"}), [], "exclude")


# ------------------------------------------------------------ fixes follow traits

func test_each_fix_resolves_to_the_expected_devices() -> void:
	var want := {
		"claw8ex-buttons": [["msi-claw-8-ex"], []],
		"claw8ex-vrr": [["msi-claw-8-ai-plus", "msi-claw-8-ex"], ["msi-claw-7-ai-plus", "msi-claw-a1m"]],
		"claw8ex-gyro": [["msi-claw-8-ex"], []],
		"claw-kbd-wakeup": [["msi-claw-7-ai-plus", "msi-claw-8-ai-plus", "msi-claw-8-ex", "msi-claw-a1m", "msi-claw-a8", "msi-claw-family"], []],
		"claw-wifi-d3cold": [[], ["msi-claw-7-ai-plus", "msi-claw-8-ai-plus", "msi-claw-8-ex", "msi-claw-a1m"]],
		"gpd-fingerprint": [["gpd-win-4", "gpd-win-max-2"], []],
		"gpd-wm2-touch-wakeup": [[], ["gpd-win-max-2"]],
		"ally-controller-wakeup": [["asus-rog-ally-x", "asus-rog-xbox-ally", "asus-rog-xbox-ally-x", "asus-rog-xbox-ally-x20"], []],
		"ally-fingerprint-drain": [["asus-rog-ally", "asus-rog-ally-x"], ["asus-rog-xbox-ally", "asus-rog-xbox-ally-x", "asus-rog-xbox-ally-x20"]],
		"ally-mcu-powersave": [[], ["asus-rog-ally", "asus-rog-ally-x", "asus-rog-xbox-ally", "asus-rog-xbox-ally-x", "asus-rog-xbox-ally-x20"]],
		"onexfly-touch": [["onexplayer-onexfly-f1"], ["aokzoe-a1", "aokzoe-a1-pro", "onexplayer-2", "onexplayer-2-pro", "onexplayer-x1-amd", "onexplayer-x1-mini"]],
	}
	for fix in want:
		eq(_fixset(fix, "auto"), want[fix][0], fix + ": auto")
		eq(_fixset(fix, "optional"), want[fix][1], fix + ": optional")
	eq(_fixset("ax210-d3cold", "auto"), ["ayaneo-2", "ayaneo-2s", "gpd-win-5"], "ax210-d3cold: every row with an AX210")
	eq(_fixset("ax210-d3cold", "optional").size(), _rows().size() - 3, "ax210-d3cold: offered everywhere else")
	eq(_fixset("journal-flood", "auto"), [], "journal-flood: never automatic")
	eq(_fixset("journal-flood", "optional").size(), _rows().size(), "journal-flood: offered on every handheld (the fix checks for steamos-manager)")


func test_no_fix_applies_to_a_device_lacking_its_trait() -> void:
	# For every trait-selected fix: each picked row has the trait, and no row
	# with the trait is left out unless it is excluded with a reason.
	var keys := {"claw-kbd-wakeup": "controller:msi-claw", "ally-controller-wakeup": "controller:asus-ally-x",
		"gpd-fingerprint": "fingerprint:2808:9338|2541:9711", "ax210-d3cold": "wifi:ax210",
		"ally-fingerprint-drain": "fingerprint:1c7a:0588", "claw8ex-gyro": "imu:ish-hid-sensor"}
	for fix in keys:
		var e := _entry(fix)
		for r in _rows():
			var has := Traits.matches(keys[fix], r)
			if Traits.fix_auto(e, r):
				ok(has, "%s: auto on %s, which has %s" % [fix, r["id"], keys[fix]])
			elif has and not e.get("exclude", {}).has(r["id"]):
				ok(false, "%s: %s has %s but doesn't get it" % [fix, r["id"], keys[fix]])
	# the VRR fix never reaches an AMD GPU, even with the Claw 8 body
	var vrr := _entry("claw8ex-vrr")
	for r in _rows():
		if Traits.fix_auto(vrr, r) or Traits.fix_optional(vrr, r):
			ok(Traits.matches("gpu_driver:xe|i915", r), "claw8ex-vrr only with an Intel GPU driver: " + r["id"])
	ok(vrr["exclude"].has("msi-claw-a8"), "the A8 is excluded with a reason")


func test_python_and_godot_agree_and_devices_json_is_generated() -> void:
	# fixes/lib/fix-devices.txt and devices.json "fixes" come from tools/traits/traits.py;
	# the app resolves the same selectors itself.
	var lines := FileAccess.get_file_as_string(_repo().path_join("fixes/lib/fix-devices.txt")).split("\n", false)
	var listed := {}
	for l in lines:
		if l.begins_with("#"):
			continue
		var f := l.split("\t")
		listed[f[0]] = Array(f[1].split(" ", false))
	for e in _cat():
		if not e["kind"] in ["root", "file"]:
			continue
		ok(listed.has(e["id"]), e["id"] + " in fix-devices.txt")
		var mine: Array = []
		var everywhere := false
		for r in _rows():
			if Traits.fix_auto(e, r) or Traits.fix_optional(e, r):
				mine.append(r["id"])
		if e.get("auto") is String and e["auto"] == "*" or e.get("optional") is String and e["optional"] == "*":
			everywhere = true
		eq(_sorted(listed.get(e["id"], [])), ["*"] if everywhere else _sorted(mine), e["id"] + ": fix-devices.txt = app resolution")
	for r in _rows():
		eq(r["fixes"], Traits.auto_fixes(r, _cat()), r["id"] + ": devices.json fixes = resolved auto")


func test_rule_dmi_comes_from_the_resolved_devices() -> void:
	# Every handheld a fix may act on has a DMI line in devices.txt (gcfix.sh builds
	# the rule's DMI match from them), and the fixes read DEVICES from fix-devices.txt.
	var dev_lines := FileAccess.get_file_as_string(_repo().path_join("fixes/lib/devices.txt")).split("\n", false)
	var with_dmi := {}
	for l in dev_lines:
		if not l.begins_with("#"):
			with_dmi[l.get_slice("\t", 0)] = true
	for e in _cat():
		if e["kind"] != "file":
			continue
		var src := FileAccess.get_file_as_string(_repo().path_join("fixes/%s/fix.sh" % e["id"]))
		ok(src.contains("DEVICES=\"@\""), e["id"] + ": devices come from the trait resolution")
		ok(not src.contains("[dmi/id]"), e["id"] + ": no hand-written DMI match (gc_rule_lines adds it)")
		for r in _rows():
			if Traits.fix_auto(e, r) or Traits.fix_optional(e, r):
				ok(with_dmi.has(r["id"]), "%s: %s has DMI ids for the rule" % [e["id"], r["id"]])


func test_fixes_service_and_installer_use_traits() -> void:
	var s: Node = FixesSvc.new()
	s.setup({"device": "asus-rog-xbox-ally-x20", "home": OS.get_cache_dir().path_join("gc_traits_home"), "runner": null})
	ok(s.is_auto("ally-controller-wakeup"), "X20: controller wakeup fix (shared controller)")
	ok(s.is_optional("ally-fingerprint-drain"), "X20: fingerprint fix offered")
	ok("controller asus-ally-x" in s.why("ally-controller-wakeup"), "why names the shared controller")
	s.free()
	eq(Plan.auto_fixes_for(_row("msi-claw-8-ai-plus")), ["claw8ex-vrr", "claw-kbd-wakeup"], "installer: the 8 AI+ gets the panel fix")
	eq(Plan.auto_fixes_for({"id": "x", "fixes": ["fan"]}), ["fan"], "rows without traits keep their list")
	eq(Traits.auto_fixes({"id": "unknown", "traits": {}}), [], "unknown hardware: nothing auto")


# ------------------------------------------------------------ quirks

func test_quirks_follow_traits() -> void:
	var rows := _rows()
	for q in Traits.quirks():
		for k in ["id", "applies", "what", "why", "sources"]:
			ok(q.has(k), "%s: has %s" % [q.get("id", "?"), k])
		ok(not Traits.resolve(q["applies"], rows).is_empty(), q["id"] + ": applies to a device")
	eq(_sorted(Traits.resolve(Traits.quirk("gamescope-known-refresh")["applies"], rows)),
		_sorted(["steam-deck-lcd", "steam-deck-oled", "asus-rog-ally", "asus-rog-ally-x", "asus-rog-xbox-ally-x20",
		"gpd-win-4", "lenovo-legion-go", "lenovo-legion-go-2", "lenovo-legion-go-2-z2", "lenovo-legion-go-s-z2go",
		"lenovo-legion-go-s-z1e", "onexplayer-onexfly-f1", "zotac-zone"]), "gamescope display scripts, by panel")
	eq(_sorted(Traits.resolve(Traits.quirk("session-refresh-switching")["applies"], rows)),
		["onexplayer-g1-amd", "onexplayer-g1-intel", "onexplayer-x1-amd", "onexplayer-x1-intel", "onexplayer-x1-mini"],
		"device-quirks refresh blocks (the X1 Pro has none)")
	ok(Traits.has_quirk("software-brightness-in-pq", _row("lenovo-legion-go-2-z2")), "both Legion Go 2 SoCs share the OLED quirk")
	ok(Traits.has_quirk("fw-ppt-ignored", _row("msi-claw-8-ex")) and not Traits.has_quirk("fw-ppt-ignored", _row("msi-claw-a8")),
		"firmware PPT quirk: Panther Lake Claw firmware only")
	ok(not Traits.has_quirk("hdr-switch-blocked", {}), "no row: no quirk")


# ------------------------------------------------------------ device matrix

func test_matrix_expectations_take_trait_selectors() -> void:
	var Matrix: GDScript = load("res://tests/devicematrix/matrix.gd")
	var lnl := _row("msi-claw-8-ai-plus")
	ok(Matrix.selector_matches("soc:lunar-lake|panther-lake", lnl["id"], {}, lnl), "trait selector on a sibling")
	ok(not Matrix.selector_matches("soc:lunar-lake|panther-lake", "msi-claw-a8", {}, _row("msi-claw-a8")), "not on the AMD Claw")
	ok(Matrix.selector_matches("controller:msi-claw+vendor:intel", lnl["id"], {"vendor": "intel"}, lnl), "a+b: trait and fixture")
	ok(not Matrix.selector_matches("controller:msi-claw+vendor:amd", lnl["id"], {"vendor": "intel"}, lnl), "a+b: both must hold")
	ok(Matrix.selector_matches("vendor:intel", lnl["id"], {"vendor": "intel"}, lnl), "fixture selectors still work")
	var ids := _rows().map(func(r): return r["id"])
	var bad := {"invariants": {}, "devices": {"soc:x": {}, "bogus:y": {}, "nope": {}}}
	var p: Array = Matrix.expectation_file_problems(bad, ids)
	ok(not p.any(func(x): return "soc:x" in x), "trait keys are known selectors")
	ok(p.any(func(x): return "bogus:y" in x) and p.any(func(x): return "nope" in x), "unknown keys and ids are reported")
