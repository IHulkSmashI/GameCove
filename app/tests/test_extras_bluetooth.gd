extends "res://tests/test_case.gd"
## Bluetooth devices: scripts/system/bluetooth.gd over a fake BlueZ (busctl JSON
## as systemd 255 prints it) and the Settings > System card. Nothing real runs.

const Bluetooth := preload("res://scripts/system/bluetooth.gd")
const Card := preload("res://scripts/ui/settings/bluetooth_card.gd")
const GroupPage := preload("res://scripts/ui/controls/group_page.gd")
const Fake := preload("res://tests/fixtures/system/fake_runner.gd")
const UIC := preload("res://tests/test_ui_controls.gd")
const TX := preload("res://scripts/ui/texts_extras.gd")

const GMO := "busctl --system call org.bluez / org.freedesktop.DBus.ObjectManager GetManagedObjects"
const PAD := "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_01"
const BUDS := "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_02"
const NEW := "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_03"
const NAMELESS := "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_04"


static func _b(v: bool) -> Dictionary:
	return {"type": "b", "data": v}


static func _s(v: String) -> Dictionary:
	return {"type": "s", "data": v}


## A BlueZ tree: one adapter, a connected controller with battery, paired
## earbuds, a new speaker and a nameless address from a scan.
class Bluez extends RefCounted:
	var powered := true
	var tree := {}
	var ok_calls := {}   # "Connect" / "Pair" / ... -> bool

	func _init() -> void:
		tree = {
			"/org/bluez/hci0": {"org.bluez.Adapter1": {"Powered": {"type": "b", "data": true}}},
			PAD: {"org.bluez.Device1": {"Name": {"type": "s", "data": "Xbox Wireless Controller"}, "Alias": {"type": "s", "data": "Xbox Wireless Controller"},
				"Address": {"type": "s", "data": "AA:BB:CC:DD:EE:01"}, "Icon": {"type": "s", "data": "input-gaming"},
				"Paired": {"type": "b", "data": true}, "Connected": {"type": "b", "data": true}, "Trusted": {"type": "b", "data": true}},
				"org.bluez.Battery1": {"Percentage": {"type": "y", "data": 80}}},
			BUDS: {"org.bluez.Device1": {"Name": {"type": "s", "data": "Galaxy Buds"}, "Address": {"type": "s", "data": "AA:BB:CC:DD:EE:02"},
				"Icon": {"type": "s", "data": "audio-headset"}, "Paired": {"type": "b", "data": true}, "Connected": {"type": "b", "data": false}}},
			NEW: {"org.bluez.Device1": {"Name": {"type": "s", "data": "JBL Flip 6"}, "Address": {"type": "s", "data": "AA:BB:CC:DD:EE:03"},
				"Paired": {"type": "b", "data": false}, "Connected": {"type": "b", "data": false}}},
			NAMELESS: {"org.bluez.Device1": {"Address": {"type": "s", "data": "AA:BB:CC:DD:EE:04"}, "Alias": {"type": "s", "data": "AA-BB-CC-DD-EE-04"},
				"Paired": {"type": "b", "data": false}}},
		}

	func answer(cmd: String) -> Variant:
		if cmd == GMO:
			tree["/org/bluez/hci0"]["org.bluez.Adapter1"]["Powered"]["data"] = powered
			return {"code": 0, "out": JSON.stringify({"type": "a{oa{sa{sv}}}", "data": [tree]})}
		if cmd.begins_with("busctl --system call org.bluez "):
			var parts := cmd.split(" ")
			var method: String = parts[6]
			var good: bool = ok_calls.get(method, true)
			if good:
				_apply(parts[4], method, parts)
			return {"code": 0 if good else 1, "out": ""}
		if cmd.begins_with("busctl --system set-property org.bluez "):
			return {"code": 0, "out": ""}
		if cmd.begins_with("bluetoothctl --timeout"):
			return {"code": 0, "out": ""}
		return null

	func _apply(path: String, method: String, parts: PackedStringArray) -> void:
		match method:
			"Connect": tree[path]["org.bluez.Device1"]["Connected"] = {"type": "b", "data": true}
			"Disconnect": tree[path]["org.bluez.Device1"]["Connected"] = {"type": "b", "data": false}
			"Pair": tree[path]["org.bluez.Device1"]["Paired"] = {"type": "b", "data": true}
			"RemoveDevice": tree.erase(parts[parts.size() - 1])


func _fake(bz: Bluez) -> RefCounted:
	var f: RefCounted = Fake.new()
	f.handler = bz.answer
	f.set_meta("bluez", bz)   # a method Callable doesn't keep its object alive
	return f


func test_devices_sorted_and_filtered() -> void:
	var snap := Bluetooth.snapshot(_fake(Bluez.new()))
	ok(snap["powered"], "adapter on")
	var names: Array = snap["devices"].map(func(d): return d["name"])
	eq(names, ["Xbox Wireless Controller", "Galaxy Buds", "JBL Flip 6"], "connected, paired, new; nameless address left out")
	var pad: Dictionary = snap["devices"][0]
	eq(pad["battery"], 80, "controller battery from Battery1")
	eq(pad["icon"], "gamepad", "controller icon")
	eq(pad["adapter"], "/org/bluez/hci0", "its adapter")
	eq(snap["devices"][1]["battery"], -1, "no battery reported")
	eq(Bluetooth.snapshot(Fake.new()), {"adapters": [], "devices": [], "powered": false}, "no BlueZ")


func test_actions_go_through_bluez() -> void:
	var bz := Bluez.new()
	var f := _fake(bz)
	ok(Bluetooth.connect_device(f, BUDS), "connect")
	ok(f.called("busctl --system call org.bluez %s org.bluez.Device1 Connect" % BUDS), "Device1.Connect")
	ok(Bluetooth.disconnect_device(f, PAD), "disconnect")
	ok(Bluetooth.pair(f, NEW), "pair")
	ok(f.called("busctl --system set-property org.bluez %s org.bluez.Device1 Trusted b true" % NEW), "trusted so it reconnects by itself")
	ok(f.called("busctl --system call org.bluez %s org.bluez.Device1 Connect" % NEW), "and connected")
	ok(Bluetooth.forget(f, BUDS), "forget")
	ok(f.called("busctl --system call org.bluez /org/bluez/hci0 org.bluez.Adapter1 RemoveDevice o %s" % BUDS), "Adapter1.RemoveDevice on its adapter")
	ok(not Bluetooth.connect_device(f, "/org/bluez/hci0"), "only device paths")
	ok(not Bluetooth.forget(f, "/org/bluez/hci0/dev_x; rm -rf"), "nothing odd reaches busctl")
	bz.ok_calls["Pair"] = false
	ok(not Bluetooth.pair(f, NEW), "a failed pair says so")


func test_scan_uses_bluetoothctl_with_a_timeout() -> void:
	var f := _fake(Bluez.new())
	var snap := Bluetooth.scan(f)
	ok(f.called("bluetoothctl --timeout 10 scan on"), "scans for 10 s while bluetoothctl holds the bus")
	eq(snap["devices"].size(), 3, "then reads the devices")


func test_card_rows_and_sheet_actions() -> void:
	var bz := Bluez.new()
	var c: VBoxContainer = Card.new()
	c.setup(_fake(bz))
	eq(c.rows.size(), 3, "a row per device")
	eq(c.focusables().size(), 4, "devices plus Find new devices")
	eq(c.rows[PAD].value_label.text, "Connected · 80% battery", "status and battery on the row")
	eq(c.rows[BUDS].hint_text(), TX.BT_ROW_HINT, "one plain line per row")
	eq(c.rows[NEW].hint_text(), TX.BT_NEW_HINT, "new device: how to pair")
	eq(c.find_row.hint_text(), TX.BT_FIND_HINT, "find row explains pairing mode")
	var notes := []
	c.notice.connect(func(t, tone): notes.append([t, tone]))
	c.act(c.state["devices"][1], "connect")
	eq(notes[-1], [TX.BT_DONE["connect"] % "Galaxy Buds", "good"], "connected toast")
	eq(c.rows[BUDS].value_label.text, TX.BT_CONNECTED, "row reads again")
	ok(c._had_state and c._was_on.has(BUDS), "remembered as on (its row popped this once)")
	c.act(c.state["devices"][2], "pair")
	eq(notes[-1], [TX.BT_DONE["pair"] % "JBL Flip 6", "good"], "paired")
	bz.ok_calls["Connect"] = false
	c.act({"path": PAD, "name": "Xbox Wireless Controller", "paired": true, "connected": false}, "connect")
	eq(notes[-1][1], "bad", "a failed connect says so")
	c.act({"path": PAD, "name": "x"}, "rm")
	eq(notes.size(), 3, "unknown actions do nothing")
	c.free()


func test_card_states_off_none_empty() -> void:
	var bz := Bluez.new()
	bz.powered = false
	var c: VBoxContainer = Card.new()
	c.setup(_fake(bz))
	ok(c.find_child("BtOff", true, false) != null, "Bluetooth off: says so")
	eq(c.focusables(), [], "nothing to press")
	c.free()
	var c2: VBoxContainer = Card.new()
	c2.setup(Fake.new())
	ok(c2.find_child("BtNone", true, false) != null, "no adapter: says so")
	c2.free()
	var empty := Bluez.new()
	for p in [PAD, BUDS, NEW]:
		empty.tree.erase(p)
	var c3: VBoxContainer = Card.new()
	c3.setup(_fake(empty))
	ok(c3.find_child("BtEmpty", true, false) != null, "nothing paired: how to start")
	eq(c3.focusables().size(), 1, "Find new devices still there")
	c3.find_new()
	c3.free()


func test_system_page_shows_the_card_only_with_bluetooth() -> void:
	var c: Node = UIC.fake()
	c.add({"id": "network.bluetooth", "title": "Bluetooth", "kind": "toggle", "value": true, "per_game": false})
	var page: VBoxContainer = GroupPage.new()
	page.lazy = false
	page.setup("system", {"controls": c, "bluetooth_runner": _fake(Bluez.new())}, null)
	eq(page.extras.size(), 1, "System gets Bluetooth devices")
	ok(page.focus_part("bluetooth") == page.extras[0].focusables()[0], "the quick menu's row lands on it")
	page.free()
	var page2: VBoxContainer = GroupPage.new()
	page2.lazy = false
	page2.setup("system", {"controls": c}, null)
	eq(page2.extras.size(), 0, "no fake runner under tests: nothing real runs")
	page2.free()
	c.set_available("network.bluetooth", false)
	var page3: VBoxContainer = GroupPage.new()
	page3.lazy = false
	page3.setup("system", {"controls": c, "bluetooth_runner": _fake(Bluez.new())}, null)
	eq(page3.extras.size(), 0, "no Bluetooth here: no card")
	page3.free()
	c.free()


func test_quick_menu_device_tab_links_to_the_devices() -> void:
	var Q = preload("res://tests/test_ui_quick_menu.gd").new()
	var x: Dictionary = Q._menu()
	var TCx := preload("res://scripts/ui/texts_controls.gd")
	var dev: int = TCx.TAB_IDS.find("device")
	x.m.show_section(dev)
	ok(x.m.body.find_child("BluetoothDevices", true, false) == null, "no Bluetooth control: no row")
	x.c.add({"id": "network.bluetooth", "title": "Bluetooth", "kind": "toggle", "value": true, "per_game": false})
	x.m.show_section(dev)
	var row: Node = x.m.body.find_child("BluetoothDevices", true, false)
	ok(row != null, "Device tab: Bluetooth devices row")
	ok(row != null and row.button in x.m.focusables(), "in the focus chain")
	ok(row != null and row.hint_text() == TX.BT_QUICK_HINT, "one plain line")
	Q._done(x)
