extends "res://tests/test_case.gd"
## Device.info() against a fake ROG Ally filesystem.

const DeviceScript := preload("res://scripts/device/device.gd")


func _ally() -> Node:
	var d: Node = DeviceScript.new()
	d.root = fixture("devices/sys_ally")
	d.home = fixture("devices/sys_ally/home/deck")
	d.detect()
	return d


func test_info_groups_and_values() -> void:
	var d := _ally()
	var i: Dictionary = d.info()
	eq(i.keys(), ["device", "chip", "memory", "storage", "screen", "battery", "software", "support"], "groups in order")
	eq(i["device"]["name"], "ASUS ROG Ally", "name")
	eq(i["device"]["model"], "ROG Ally RC71L_RC71L", "DMI product")
	eq(i["device"]["bios_version"], "RC71L.341", "BIOS")
	eq(i["device"]["bios_date"], "04/15/2025", "BIOS date")
	eq(i["device"]["serial"], "hidden", "serial never read")
	eq(i["device"]["picture"], "res://assets/devices/art/rog-ally.svg", "picture")
	eq(i["chip"]["cpu"], "AMD Ryzen Z1 Extreme", "cpu")
	eq(i["chip"]["cores"], 8, "cores")
	eq(i["chip"]["threads"], 16, "threads")
	eq(i["chip"]["gpu_arch"], "RDNA3", "arch")
	eq(i["chip"]["gpu_driver"], "amdgpu", "driver")
	eq(i["chip"]["gpu_pci_id"], "1002:15BF", "pci id")
	eq(i["chip"]["kernel"], "6.17.7-ba14.fc43.x86_64", "kernel")
	eq(i["memory"], {"total_mb": 15618, "vram_mb": 4096, "gtt_mb": 7808}, "memory")
	eq(i["storage"]["internal"]["model"], "Micron_2400_MTFDKBK512QFM", "drive")
	eq(i["storage"]["internal"]["size_gb"], 512.1, "drive size")
	eq(i["storage"]["sd_card"]["size_gb"], 127.9, "SD card")
	eq(i["screen"]["resolution"], [1920.0, 1080.0], "resolution")
	eq(i["screen"]["refresh_hz"], [48.0, 120.0], "refresh")
	eq(i["screen"]["vrr"], true, "vrr")
	eq(i["battery"]["health_pct"], 92, "health 36.8 / 40 Wh")
	eq(i["battery"]["design_wh"], 40.0, "design")
	eq(i["battery"]["cycles"], 123, "cycles")
	eq(i["battery"]["percent"], 76, "percent")
	eq(i["battery"]["charging"], false, "discharging")
	eq(i["battery"]["charge_limit_supported"], true, "charge limit")
	eq(i["software"]["os"], "Bazzite 43 (FROM Fedora Kinoite)", "os")
	eq(i["software"]["os_version"], "43", "os version")
	eq(i["software"]["gamecove_version"], "dev", "version")
	eq(i["support"]["level"], "full", "tested on hardware (RC71L)")
	eq(i["support"]["buttons"], "rog-ally", "button profile")
	ok(i["support"]["features"]["tdp"], "features")
	d.free()


func test_slow_info() -> void:
	var d := _ally()
	var s: Dictionary = d.slow_info(false)
	eq(s["steam_version"], "1761234567", "Steam client build")
	eq(s["proton"], ["GE-Proton10-25", "Proton - Experimental", "Proton 10.0"], "Proton builds, games skipped")
	ok(s["free_gb"].has("internal") and float(s["free_gb"]["internal"]) >= 0.0, "free space")
	d._slow = s
	var i: Dictionary = d.info()
	eq(i["software"]["steam_version"], "1761234567", "merged into info()")
	ok(i["storage"]["internal"].has("free_gb"), "free space merged")
	d.free()


func test_parsers() -> void:
	var vk := "Devices:\n========\nGPU0:\n\tapiVersion         = 1.4.311\n\tdriverName         = radv\n\tdriverInfo         = Mesa 25.1.3\n\tdeviceName = AMD Radeon 780M (RADV PHOENIX)\nGPU1:\n\tdriverName = llvmpipe\n"
	eq(DeviceScript.parse_vulkaninfo(vk), {"driver_name": "radv", "driver_info": "Mesa 25.1.3", "device_name": "AMD Radeon 780M (RADV PHOENIX)"}, "vulkaninfo")
	eq(DeviceScript.mesa_from_text("4.6 (Core Profile) Mesa 25.2.0-devel"), "Mesa 25.2.0-devel", "GL version")
	eq(DeviceScript.mesa_from_text("NVIDIA 580.1"), "", "not Mesa")


func test_empty_system_gives_unknowns() -> void:
	var d: Node = DeviceScript.new()
	d.root = fixture("devices/does_not_exist")
	d.home = d.root
	d.detect()
	var i: Dictionary = d.info()
	eq(i["device"]["id"], "unknown", "unknown")
	eq(i["battery"]["present"], false, "no battery")
	eq(i["memory"]["total_mb"], -1, "no meminfo")
	eq(i["storage"]["internal"], {}, "no drive")
	eq(i["software"]["os"], "", "no os-release")
	d.free()
