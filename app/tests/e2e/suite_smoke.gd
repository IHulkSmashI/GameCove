extends "res://tests/e2e/e2e_case.gd"
## The world comes up: the fixture is what Device sees, the quick menu opens
## with the handheld's own button and closes with B.


func test_boot_and_menu() -> void:
	eq(str(w.autoload("Device").id()), device_id(), "Device resolves the fixture's DMI")
	ok(controls().list().size() > 50, "providers loaded")
	await qam()
	ok(qm().visible, "quick menu opens with the handheld's button")
	await b()
	ok(not qm().visible, "B closes it")
