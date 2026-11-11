extends "res://tests/test_case.gd"
## Chip detection for upscaling (device/gpu_caps.gd): every chip in
## devices.json gets the tier and choices the helper's chips.py gives for it
## (the shared fixture gpu_tiers.json), from the device row alone and from
## what a real system reports.

const GpuCaps := preload("res://scripts/device/gpu_caps.gd")
const DeviceScript := preload("res://scripts/device/device.gd")
const FIXTURE := "res://tests/fixtures/gpu_tiers.json"


func _rows() -> Array:
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	return doc["rows"] if doc is Dictionary else []


func test_fixture_rows_match_the_helper_table() -> void:
	var rows := _rows()
	ok(rows.size() >= 40, "the fixture has every chip (%d)" % rows.size())
	var tiers := {}
	for r in rows:
		var g: Dictionary = r["gpu"]
		var who := str(r["from"])
		eq(GpuCaps.tier(g), r["tier"], who + " tier")
		eq(GpuCaps.upscalers(g), r["upscalers"], who + " upscalers")
		eq(GpuCaps.frame_gens(g).map(func(x): return float(x)), (r["frame_gens"] as Array).map(func(x): return float(x)), who + " multipliers")
		eq(GpuCaps.generators(g), r["generators"], who + " generators")
		eq(GpuCaps.latency(g), r["latency"], who + " latency")
		tiers[r["tier"]] = true
	for t in GpuCaps.TIERS:
		ok(tiers.has(t), "a real chip for tier " + t)


func test_every_device_row_resolves_to_a_tier() -> void:
	var by_id := {}
	for r in _rows():
		by_id[str(r["from"])] = r
	var n := 0
	for row in DeviceScript.load_table():
		var g := GpuCaps.gpu(row)
		ok(g["tier"] in GpuCaps.TIERS, "%s: %s" % [row["id"], g["tier"]])
		if by_id.has(str(row["id"])):
			eq(g["tier"], by_id[str(row["id"])]["tier"], "%s as in the fixture" % row["id"])
			n += 1
		if bool(row.get("xmx", false)):
			eq(g["tier"], "intel_xmx", "%s has XMX" % row["id"])
			eq(GpuCaps.frame_gens(g), [0, 2, 3, 4], "%s: 3x and 4x" % row["id"])
		else:
			ok(not (3 in GpuCaps.frame_gens(g)) and not (4 in GpuCaps.frame_gens(g)), "%s: no multiplier it can't do" % row["id"])
	ok(n >= 20, "fixture rows checked against real device rows (%d)" % n)


func test_named_handhelds() -> void:
	var want := {"msi-claw-8-ex": "intel_xmx", "steam-deck-lcd": "amd_rdna2", "steam-deck-oled": "amd_rdna2",
		"asus-rog-ally": "amd_rdna3", "asus-rog-ally-x": "amd_rdna3", "lenovo-legion-go-s-z2go": "amd_rdna2"}
	var seen := 0
	for row in DeviceScript.load_table():
		if want.has(str(row["id"])):
			eq(GpuCaps.gpu(row)["tier"], want[str(row["id"])], str(row["id"]))
			seen += 1
	ok(seen >= 4, "known handhelds found in the table (%d)" % seen)


func test_what_the_system_reports_fills_the_gaps() -> void:
	# a desktop with an NVIDIA card: no device row says so, the PCI vendor does
	var nv := GpuCaps.record({"chip": "Unknown", "gpu": "NVIDIA GeForce RTX 4070"}, {"gpu_dev": {"vendor": "nvidia", "driver": "nvidia", "pci_id": "10DE:2786"}})
	eq(nv["tier"], "nvidia", "NVIDIA from the card")
	eq(nv["upscalers"], ["own"], "native DLSS is left alone")
	eq(nv["latency"], "reflex", "Reflex")
	eq(GpuCaps.record({}, {})["tier"], "other", "nothing known")
	eq(GpuCaps.record({"gpu_family": "amd-rdna3", "gpu_arch": "RDNA3", "gpu": "AMD Radeon RX 7600"}, {})["tier"], "amd_halo", "an RDNA 3 card runs the full model")
	eq(GpuCaps.record({"gpu_family": "amd-rdna3", "gpu_arch": "RDNA4", "gpu": "AMD Radeon RX 9070 XT"}, {})["tier"], "amd_rdna4", "RX 9000")


func test_record_carries_memory_versions_and_what_is_needed() -> void:
	var z1e := {"chip": "AMD Ryzen Z1 Extreme", "gpu": "Radeon 780M (RDNA 3)", "gpu_family": "amd-rdna3", "gpu_arch": "RDNA3", "xmx": false}
	var r := GpuCaps.record(z1e, {"gpu_dev": {"vendor": "amd", "driver": "amdgpu", "pci_id": "1002:15BF"}, "mesa": "25.1.4",
		"kernel": "6.11.11-valve27", "memory": {"total_mb": 15360, "vram_mb": 4096}})
	eq(r["tier"], "amd_rdna3", "Z1 Extreme")
	eq(r["fsr4"], "default", "FSR 4.1.2 is the default on RDNA 3")
	eq(r["fsr4_model"], "INT8", "INT8 model")
	eq(r["fsr4_listed"], false, "not on AMD's own list: the helper switches INT8 on")
	eq(r["vram_mb"], 4096, "VRAM")
	eq(r["shared_mb"], 15360, "shared memory")
	eq(r["driver"], "amdgpu", "driver")
	eq(r["kernel"], "6.11.11-valve27", "kernel")
	var mesa: Dictionary = r["needs"][0]
	eq(mesa["what"], "mesa", "Mesa is what FSR 4 needs")
	eq(mesa["ok"], false, "25.1 is too old")
	ok("25.2" in str(mesa["line"]), "says which version")
	var newer := GpuCaps.record(z1e, {"mesa": "26.2.4"})
	eq(newer["needs"][0]["ok"], true, "26.2 is fine")
	eq(GpuCaps.record(z1e, {})["needs"][0]["ok"], true, "unknown version: no false alarm")

	var claw := {"chip": "Intel Panther Lake", "gpu": "Arc B390 (Xe3)", "gpu_family": "intel-xe3", "gpu_arch": "Xe3", "xmx": true}
	var c := GpuCaps.record(claw, {"gpu_dev": {"vendor": "intel", "driver": "xe", "pci_id": "8086:B080"}, "xess_xmx": false})
	eq(c["tier"], "intel_xmx", "Claw 8 EX")
	eq(c["xmx_ready"], false, "driver not installed yet")
	var need := {}
	for n in c["needs"]:
		need[n["what"]] = n
	eq(need["kernel driver"]["ok"], true, "xe")
	eq(need["XeSS XMX driver"]["ok"], false, "says the driver is missing")
	eq(GpuCaps.record(claw, {"xess_xmx": true})["xmx_ready"], true, "ready once installed")
	var lpg := GpuCaps.record({"gpu_family": "intel-xe-lpg", "gpu_arch": "Xe-LPG", "xmx": false}, {})
	eq(lpg["tier"], "intel", "Meteor Lake has no XMX")
	eq(lpg["frame_gens"], [0, 2], "2x only")
	eq(lpg["needs"], [], "nothing to install")


func test_summary_is_one_plain_line_per_tier() -> void:
	for r in _rows():
		var line := GpuCaps.summary(GpuCaps.record({"gpu_family": r["gpu"]["family"], "gpu_arch": r["gpu"]["arch"],
			"xmx": r["gpu"]["xmx"], "chip": r["gpu"]["chip"], "gpu": r["gpu"]["gpu"]}, {"gpu_dev": {"vendor": r["gpu"]["vendor"]}}))
		ok(line.length() > 20 and line.length() < 160 and not "\n" in line, "%s: %s" % [r["from"], line])
		ok(not "Partial" in line and not " I " in line, "tone")
