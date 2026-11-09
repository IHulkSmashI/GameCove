extends "res://tests/test_case.gd"
## The Updates page's maker-firmware and drivers sections, against a fake Updates service.

const Fakes := preload("res://tests/fixtures/device_ui/fakes.gd")
const UpdatesPage := preload("res://scripts/ui/device/updates_panel.gd")
const Hub := preload("res://scripts/system/firmware_texts.gd")


class UsbUpdates extends "res://tests/fixtures/device_ui/fakes.gd".FakeUpdates:
	func prepare_usb(id: String, mount: String) -> bool:
		calls.append("usb %s %s" % [id, mount])
		return true


func _texts(n: Node) -> String:
	var out := PackedStringArray()
	if n is Label or n is Button:
		out.append(n.text)
	for c in n.get_children():
		out.append(_texts(c))
	return "\n".join(out)


func _hub_state() -> Dictionary:
	var st: Dictionary = Fakes.updates_state()
	st["phase"]["maker"] = "available"
	st["phase"]["drivers"] = "up_to_date"
	st["maker"] = {"available": true, "items": [], "error": "", "stale": false}
	st["drivers"] = {"available": false, "items": [], "error": ""}
	st["power"] = {"ac": true, "battery": 80, "ok": true, "reason": ""}
	st["usb_targets"] = [{"mount": "/run/media/deck/USB", "label": "USB", "device": "/dev/sda1"}]
	st["hub"] = [
		{"id": "index:bios:bios", "section": "firmware", "kind": "bios", "name": "BIOS", "current": "341", "latest": "343",
			"status": "update", "how": "guided", "flash": "ez-flash", "notes": "Improves stability.\nSecond line", "source": "index",
			"download_page": "https://www.asus.com/supportonly/RC71L/helpdesk_bios/", "notes_url": ""},
		{"id": "index:controller:mcu", "section": "firmware", "kind": "controller", "name": "Controller (MCU) firmware", "current": "",
			"latest": "V321", "status": "unknown", "how": "link", "flash": "windows", "source": "index", "download_page": "https://x.invalid/"},
		{"id": "fwupd:abc", "section": "firmware", "kind": "fwupd", "name": "System Firmware", "current": "1", "latest": "1", "status": "current", "how": "auto", "source": "fwupd"},
		{"id": "driver:mesa", "section": "drivers", "kind": "mesa", "name": "Mesa (graphics drivers)", "current": "26.1.0", "latest": "26.2.6",
			"status": "upstream", "how": "auto", "source": "os"},
	]
	return st


func test_maker_and_driver_rows() -> void:
	var s := Fakes.services()
	var u := UsbUpdates.new()
	u.st = _hub_state()
	s["updates"].free()
	s["updates"] = u
	var p: Control = UpdatesPage.build(s)
	var t := _texts(p)
	ok(t.contains("New BIOS 343 available (yours: 341)"), "BIOS update line")
	ok(t.contains(Hub.STEPS["ez-flash"][3]), "EZ Flash steps")
	ok(t.contains("Improves stability.") and not t.contains("Second line"), "first line of the notes")
	ok(t.contains("Mesa (graphics drivers)  ·  26.1.0  ·  upstream 26.2.6"), "driver row")
	ok(t.contains(Hub.DRIVER_HOW["auto"]), "drivers come with the system")
	ok(not t.contains("System Firmware  ·  1"), "fwupd devices stay in the Firmware card")
	p.buttons["usb:index:bios:bios"].pressed.emit()
	ok(u.calls.has("usb index:bios:bios /run/media/deck/USB"), "prepares the USB drive")
	p.buttons["link:index:bios:bios"].pressed.emit()
	ok(p.find_child("QR", true, false) != null, "QR of the maker page")
	p.buttons["check:maker"].pressed.emit()
	ok(u.calls.has("check maker"), "check")
	u.finished.emit("usb", false, "checksum_mismatch")
	ok(_texts(p).contains(Hub.REASONS["checksum_mismatch"]), "USB failure explained")
	p.free()
	Fakes.free_services(s)


func test_no_usb_and_power_block() -> void:
	var s := Fakes.services()
	var st := _hub_state()
	st["usb_targets"] = []
	st["phase"]["firmware"] = "available"
	s["updates"].st = st
	var p: Control = UpdatesPage.build(s)
	ok(_texts(p).contains(Hub.NEEDS_USB), "asks for a USB drive")
	s["updates"].finished.emit("firmware", false, "needs_ac")
	ok(_texts(p).contains(Hub.REASONS["needs_ac"]), "charger needed")
	p.free()
	Fakes.free_services(s)


func test_unsupported_maker_and_index_unavailable() -> void:
	var s := Fakes.services()
	var st := _hub_state()
	st["phase"]["maker"] = "unsupported"
	s["updates"].st = st
	var p: Control = UpdatesPage.build(s)
	ok(_texts(p).contains(Hub.UNSUPPORTED_MAKER), "unknown device")
	p.free()
	st["phase"]["maker"] = "error"
	st["maker"]["error"] = "index_unavailable"
	st["hub"] = []
	s["updates"].st = st
	p = UpdatesPage.build(s)
	ok(_texts(p).contains(Hub.INDEX_UNAVAILABLE), "index not downloaded yet")
	p.free()
	Fakes.free_services(s)
