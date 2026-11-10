extends RefCounted
## Fake Device, Controller, Storage and Updates services for the device pages'
## tests and screenshots. Same methods and signals as the real autoloads;
## every call is recorded, nothing touches the system.

const DeviceScript := preload("res://scripts/device/device.gd")


class FakeDevice extends Node:
	signal info_updated(info: Dictionary)
	var device_id := "msi-claw-8-ex"
	var slow_requested := 0
	var data: Dictionary = {}

	func id() -> String:
		return device_id

	func picture_for(i: String) -> String:
		return DeviceScript.picture_for(i)

	func features() -> Dictionary:
		for r in DeviceScript.load_table():
			if r["id"] == device_id:
				return DeviceScript.features_of(r)
		return {"gyro": "unknown", "rgb": false}

	func info() -> Dictionary:
		return data.duplicate(true)

	func request_slow_info() -> void:
		slow_requested += 1


class FakeController extends Node:
	signal changed(state: Dictionary)
	signal applied(setting: String, ok: bool)
	signal button_event(capability: String, pressed: bool)
	var st: Dictionary = {}
	var calls: Array[String] = []

	func state() -> Dictionary:
		return st.duplicate(true)

	func refresh() -> void:
		calls.append("refresh")

	func set_paddle(p: String, t: String) -> void:
		calls.append("paddle %s %s" % [p, t])

	func set_gyro_mode(m: String) -> void:
		calls.append("gyro " + m)

	func set_rumble(on: bool) -> void:
		calls.append("rumble %s" % on)

	func test_rumble(_s := 0.6) -> void:
		calls.append("test_rumble")

	func set_game_profile(k: String, on: bool) -> void:
		calls.append("game_profile %s %s" % [k, on])

	func set_button_test(on: bool) -> void:
		calls.append("button_test %s" % on)


class FakeStorage extends Node:
	signal changed(state: Dictionary)
	var st: Dictionary = {"ready": false, "error": "", "watching": false, "drives": [], "libraries": []}
	var calls: Array[String] = []

	func state() -> Dictionary:
		return st.duplicate(true)

	func refresh() -> void:
		calls.append("refresh")

	func watch(on: bool) -> void:
		calls.append("watch %s" % on)

	func measure(p: String) -> void:
		calls.append("measure " + p)


class FakeUpdates extends Node:
	signal changed(state: Dictionary)
	signal checked(kind: String, result: Dictionary)
	signal progress(kind: String, percent: float, line: String)
	signal finished(kind: String, ok: bool, message: String)
	var st: Dictionary = {}
	var calls: Array[String] = []

	func state() -> Dictionary:
		return st.duplicate(true)

	func check_updates() -> void:
		calls.append("check_updates")

	func check(k: String) -> bool:
		calls.append("check " + k)
		return true

	func apply(k: String, _t := "") -> bool:
		calls.append("apply " + k)
		return true

	func reboot() -> bool:
		calls.append("reboot")
		return true


## A realistic Claw 8 EX info() (shape of Device.info()).
static func claw_info() -> Dictionary:
	return {
		"device": {"id": "msi-claw-8-ex", "name": "MSI Claw 8 EX AI+", "maker": "MSI", "model": "Claw 8 EX AI+ A2VM",
			"board": "MS-1T91", "vendor": "Micro-Star International Co., Ltd.", "family": "Claw", "bios_version": "E1T91IMS.10E",
			"bios_date": "09/12/2026", "serial": "hidden", "picture": DeviceScript.picture_for("msi-claw-8-ex")},
		"chip": {"cpu": "Intel Core Ultra X7 358H", "cores": 16, "threads": 16, "gpu": "Arc B390", "gpu_arch": "Xe3",
			"gpu_driver": "xe", "gpu_pci_id": "8086:B080", "mesa": "Mesa 26.0.2", "kernel": "6.19.4-ba01.fc44.x86_64", "vulkan_driver": "anv"},
		"memory": {"total_mb": 32768, "vram_mb": 512, "gtt_mb": 16384},
		"storage": {"internal": {"name": "nvme0n1", "model": "WD PC SN5000S 1TB", "size_gb": 1000.2, "free_gb": 612.4},
			"sd_card": {"name": "mmcblk0", "model": "SD 512GB", "size_gb": 512.0, "free_gb": 88.1}},
		"screen": {"size_in": 8.0, "resolution": [1920, 1200], "type": "IPS", "refresh_hz": [48, 120], "vrr": true, "vrr_range": [48, 120]},
		"battery": {"present": true, "percent": 72, "status": "Discharging", "charging": false, "design_wh": 80.0, "full_wh": 74.6,
			"health_pct": 93, "cycles": 41, "charge_limit_supported": true, "model": "BTY-M5A", "manufacturer": "MSI", "technology": "Li-ion"},
		"software": {"os": "Bazzite", "os_version": "44.20261101", "os_id": "bazzite", "gamecove_version": "0.4.0",
			"steam_version": "1762300000", "proton": ["Proton 10.0-3", "GE-Proton10-25", "Proton Experimental", "Proton 9.0-4"]},
		"support": {"level": "full", "verified": true, "unverified": [], "features": {"tdp": true, "fan": true, "fan_control": true,
			"charge_limit": true, "gyro": "fix", "rgb": true, "rgb_via": "hhd", "vrr": true, "buttons": "msi-claw-8-ex", "paddles": 2, "trackpads": 0, "glyphs": "xbox"},
			"fixes": ["claw8ex-buttons", "claw8ex-vrr", "claw8ex-gyro"], "quirks": ["VRR floor is 48 Hz until the claw8ex-vrr fix.", "Gyro needs the sensor-hub firmware (claw8ex-gyro fix)."],
			"sources": [], "buttons": "msi-claw-8-ex", "glyphs": "xbox"},
	}


static func controller_state() -> Dictionary:
	return {"available": true, "version": "0.70.2", "devices": [{"path": "/org/shadowblip/InputPlumber/CompositeDevice0", "name": "MSI Claw 8 EX"}],
		"active": "/org/shadowblip/InputPlumber/CompositeDevice0",
		"profile": {"name": "Default", "path": "", "paddles": {"LeftPaddle1": "South", "RightPaddle1": ""}, "gyro": "mouse"},
		"rumble": true, "led": true, "game": "steam:976730", "game_profile": false,
		"supported": {"profiles": true, "paddles": true, "gyro": true, "rumble": true, "led": false, "per_game": true}}


static func storage_state() -> Dictionary:
	return {"ready": true, "error": "", "watching": true,
		"drives": [
			{"device": "/dev/nvme0n1p3", "kind": "internal", "label": "", "model": "WD PC SN5000S 1TB", "fstype": "btrfs", "mount": "/var", "mounts": ["/var", "/home"],
				"size": 998000000000, "used": 386000000000, "free": 612000000000, "compression": "zstd:1", "removable": false},
			{"device": "/dev/mmcblk0p1", "kind": "sd", "label": "Games SD", "model": "SD 512GB", "fstype": "ext4", "mount": "/run/media/deck/Games SD", "mounts": [],
				"size": 512000000000, "used": 471000000000, "free": 41000000000, "compression": "", "removable": true}],
		"libraries": [
			{"store": "steam", "path": "/home/deck/.local/share/Steam", "device": "/dev/nvme0n1p3", "mount": "/home", "free": 612000000000, "bytes": 301000000000, "games": 23, "compression": "zstd:1"},
			{"store": "steam", "path": "/run/media/deck/Games SD/SteamLibrary", "device": "/dev/mmcblk0p1", "mount": "/run/media/deck/Games SD", "free": 41000000000, "bytes": 455000000000, "games": 31, "compression": ""},
			{"store": "heroic", "path": "/home/deck/Games/Heroic", "device": "/dev/nvme0n1p3", "mount": "/home", "free": 612000000000, "bytes": -1, "games": 4, "compression": ""}]}


static func updates_state() -> Dictionary:
	return {"os_info": {"id": "bazzite", "name": "Bazzite", "version": "44.20261101", "variant": "deck-gnome", "atomic": true},
		"phase": {"os": "available", "firmware": "up_to_date", "flatpak": "applying"},
		"os": {"available": true, "version": "44.20261107", "current": "44.20261101", "staged": false, "staged_version": "", "error": "", "notes_url": ""},
		"firmware": {"available": false, "devices": [], "error": ""},
		"flatpak": {"available": true, "pending": [{"id": "org.mozilla.firefox", "name": "Firefox"}, {"id": "com.heroicgameslauncher.hgl", "name": "Heroic"}], "error": ""},
		"supported": {"os": true, "firmware": true, "flatpak": true}, "game_running": false, "reboot_needed": false}


static func services() -> Dictionary:
	var d := FakeDevice.new()
	d.data = claw_info()
	var c := FakeController.new()
	c.st = controller_state()
	var s := FakeStorage.new()
	s.st = storage_state()
	var u := FakeUpdates.new()
	u.st = updates_state()
	return {"device": d, "controller": c, "storage": s, "updates": u, "power": null}


static func free_services(svcs: Dictionary) -> void:
	for k in svcs:
		if svcs[k] is Node and is_instance_valid(svcs[k]):
			svcs[k].free()
