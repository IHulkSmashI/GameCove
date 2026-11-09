extends RefCounted
## Fakes for the installer tests and screenshots: a device, a Setup service
## (store status + sign-in signals), Library / Discover / Launcher recorders,
## and targets for each kind of system. Nothing real runs.

const DeviceScript := preload("res://scripts/device/device.gd")


class FakeDevice extends RefCounted:
	var profile := {}

	func display_name() -> String:
		return str(profile.get("name", "Handheld"))

	func support_level() -> String:
		return str(profile.get("support", "generic"))

	func picture_for(id: String) -> String:
		return load("res://scripts/device/device.gd").picture_for(id)

	func battery() -> Dictionary:
		return {"percent": 72, "charging": false}


class FakeSetup extends RefCounted:
	signal changed(steps: Array)
	signal login_started(store: String, info: Dictionary)
	signal login_finished(store: String, ok: bool, message: String)
	var status := {
		"steam": {"signed_in": true, "account": "kira", "tool": "/usr/bin/steam", "how": "steam", "config": "/home/x/.local/share/Steam"},
		"epic": {"signed_in": true, "account": "Kira", "tool": "/usr/bin/legendary", "how": "code", "config": "/home/x/.config/heroic/legendaryConfig/legendary"},
		"gog": {"signed_in": false, "account": "", "tool": "/usr/bin/gogdl", "how": "code", "config": "/home/x/.config/heroic/gog_store/auth.json"},
		"amazon": {"signed_in": false, "account": "", "tool": "/usr/bin/nile", "how": "redirect_url", "config": "/home/x/.config/nile"},
	}
	var calls: Array = []
	var done := {}
	var skipped := {}
	var key := ""

	func store_status() -> Dictionary:
		return status.duplicate(true)

	func start_login(store: String) -> bool:
		calls.append("start " + store)
		login_started.emit(store, {"store": store, "url": "https://example.test/login/" + store, "needs": "code", "param": "code"})
		return true

	func finish_login(store: String, text: String) -> bool:
		calls.append("finish %s %s" % [store, text])
		status[store]["signed_in"] = true
		login_finished.emit(store, true, "")
		return true

	func cancel_login(store: String) -> void:
		calls.append("cancel " + store)

	func complete(step: String) -> bool:
		done[step] = true
		skipped.erase(step)
		return true

	func skip(step: String) -> bool:
		skipped[step] = true
		return true

	func set_steamgriddb_key(k: String) -> bool:
		key = k
		return true


class Recorder extends RefCounted:
	var calls: Array = []

	func set_store_setting(n: String, v: Variant) -> bool:
		calls.append(["store", n, v])
		return true

	func set_settings(patch: Dictionary) -> void:
		calls.append(["discover", patch])

	func set_default_goal(g: String) -> bool:
		calls.append(["goal", g])
		return true


static func claw() -> FakeDevice:
	var d := FakeDevice.new()
	for r in DeviceScript.load_table():
		if r.get("id", "") == "msi-claw-8-ex":
			d.profile = r
	return d


## A Target.detect()-shaped dictionary.
static func target(family := "bazzite", extra := {}) -> Dictionary:
	var method: String = {"bazzite": "rpm-ostree", "fedora-atomic": "rpm-ostree", "steamos": "sysext"}.get(family, "none")
	var pkg: String = {"rpm-ostree": "/dl/gamecove-0.2.0-1.fc43.x86_64.rpm", "sysext": "/dl/gamecove-0.2.0-x86_64.raw"}.get(method, "")
	var names := {"bazzite": "Bazzite 43", "fedora-atomic": "Fedora Linux 43 (Silverblue)", "steamos": "SteamOS 3.7", "other": "Arch Linux"}
	var t := {"os": {"name": names.get(family, "Linux"), "family": family}, "family": family, "method": method,
		"supported": method != "none", "release": {"tag": "v0.2.0", "version": "0.2.0", "os": family, "package": pkg},
		"package": pkg, "installed": false, "staged": false, "state": {}, "maintenance": false,
		"update_available": false, "pending": {}, "steam": {"installed": true, "signed_in": true, "account": "kira"}}
	t.merge(extra, true)
	return t


static func services(dev: Object, setup: Object, rec: Object, power_cfg: String) -> Dictionary:
	return {"setup": setup, "library": rec, "discover": rec, "launcher": rec, "device": dev,
		"power_cfg": power_cfg, "ui_prefs": false}
