extends "res://tests/e2e/e2e_case.gd"
## A device that isn't a handheld (the Steam Machine setup: no battery, no
## panel, a DualSense on a cable whose battery is not the system's): no battery
## anywhere, no handheld power limits, "device" wording, TV layout, HDMI-CEC.
## On the handheld setups the same walk checks nothing was taken away.

const Words := preload("res://scripts/ui/words.gd")
const UiScale := preload("res://scripts/ui/ui_scale.gd")
const BATTERY_IDS := ["power.charge_limit", "power.battery_long_life", "power.battery_saver", "power.battery_saver_at",
	"power.low_battery_sleep", "power.low_battery_sleep_at"]


func boxed() -> bool:
	return bool(w.info.get("boxed", false))


func _texts(n: Node, out: Array) -> void:
	if n is CanvasItem and not (n as CanvasItem).visible:
		return
	if n is Label and (n as Label).text != "":
		out.append((n as Label).atr((n as Label).text))
	elif n is Button and (n as Button).text != "":
		out.append((n as Button).atr((n as Button).text))
	for c in n.get_children():
		_texts(c, out)


## Every text on screen now; fails on handheld / battery wording on a box.
func _read_screen(where: String) -> void:
	var all := []
	_texts(w.tree.root, all)
	if not boxed():
		return
	for t in all:
		ok(str(t).findn("handheld") < 0 or str(t).find("Handheld Daemon") >= 0, "%s says handheld on a Steam Machine: %s" % [where, t])
		ok(str(t).findn("battery") < 0 or str(t).findn("controller") >= 0, "%s talks about a battery the device doesn't have: %s" % [where, t])


func test_device_is_what_the_fixture_says() -> void:
	var dev: Node = w.autoload("Device")
	eq(dev.is_handheld(), not boxed(), "handheld or not")
	eq(dev.has_battery(), not boxed(), "battery")
	eq(Words.installed(), boxed(), "wording swapped only off a handheld")
	if boxed():
		eq(dev.id(), "valve-steam-machine", "the Steam Machine row")
		eq(dev.battery()["percent"], -1, "no battery reading (the DualSense's 15 % is not ours)")
		eq(UiScale.screen_for(dev)["kind"], "tv", "its screen is the TV")
		eq(UiScale.layout_for(Vector2i(3840, 2160), UiScale.screen_for(dev)), Vector2i(1422, 800), "4K lays out for the couch")


func test_no_battery_or_handheld_power_controls_on_a_box() -> void:
	if not boxed():
		ok(available("display.brightness"), "a handheld keeps its brightness")
		return
	for id in BATTERY_IDS + ["power.tdp", "power.profile", "power.autotune", "display.brightness"]:
		ok(not available(id), "%s is not offered" % id)
	eq(power().state()["supported"]["tdp"], false, "no TDP though steamos-manager answers TdpLimit1")
	ok(available("display.hdmi_cec"), "HDMI-CEC from steamos-manager")
	eq(ctl("display.hdmi_cec").value, 2, "remote and power")


func test_hdmi_cec_writes_through_steamos_manager() -> void:
	if not available("display.hdmi_cec"):
		ok(not boxed(), "only the box's steamos-manager offers CEC here")
		return
	controls().set_value("display.hdmi_cec", 1)
	var sm := "com.steampowered.SteamOSManager1"
	ok(await until(func(): return last_set(sm, sm + ".HdmiCec1", "HdmiCecState") == "1"), "HdmiCecState 1 through steamos-manager")
	controls().set_value("display.hdmi_cec", 2)
	ok(await until(func(): return last_set(sm, sm + ".HdmiCec1", "HdmiCecState") == "2"), "and back to 2")
	await w.idle()


func test_every_screen_reads_right() -> void:
	for i in 5:
		await w.frames(4)
		_read_screen("screen " + str(main().current))
		await rb()
	await b()
	# the quick menu, every tab
	for tab in TC.TAB_IDS:
		if await open_menu_tab(tab):
			_read_screen("quick menu " + tab)
	if qm().visible:
		await qam()
	# settings, every category
	main().show_screen("settings")
	await w.frames(3)
	var st: Control = main().settings
	for id in st.cat_buttons:
		st.open_category(id)
		await w.frames(4)
		_read_screen("settings " + str(id))
	if boxed():
		ok(not main().top_bar.battery_label.visible, "no battery in the status pill")
		ok(not st.cat_buttons.has("battery"), "no battery category")
	main().show_screen("home")
	await w.frames(2)
	# Settings built every page (the Storage page too) and was left again: nothing may still poll the mounts
	var storage: Node = w.autoload("Storage")
	if storage != null:
		ok(storage._timer == null or storage._timer.is_stopped(), "the Storage mount watch is stopped once Settings is left")
