extends "res://tests/e2e/e2e_case.gd"
## The quick menu with the pad: the handheld's own button opens it, LB / RB
## walk every tab, the D-pad reaches every quick control this handheld can use
## (and none it can't), left / right change them on the system, Y opens the
## tab's Settings page, B closes, and the Desktop Mode / Steam switches leave
## no InputPlumber device intercepted.

const Catalog := preload("res://scripts/ui/controls/catalog.gd")
const Effects := preload("res://tests/e2e/effects.gd")
const Checks := preload("res://tests/e2e/checks.gd")


func _expected(tab: String) -> Array:
	var out := []
	for id in Catalog.QUICK.get(tab, []):
		var c = qm().model.control(id) if qm().model != null else null
		if c != null and c.available:
			out.append(id)   # blocked ones ("Turn on X first") show, locked
	return out


func test_every_tab_by_pad_shows_what_this_handheld_can_use() -> void:
	await qam()
	ok(qm().visible, "the quick-access button opens the menu")
	eq(qm().section, 0, "it opens on This game")
	ok(qm().body.get_node_or_null("NoGame") != null, "no game running: says so")
	for i in range(1, TC.TAB_IDS.size()):
		await rb()
		eq(qm().section, i, "RB moves to %s" % TC.TAB_IDS[i])
		var tab: String = TC.TAB_IDS[i]
		if tab == "device":
			ok(qm().body.get_node_or_null("DesktopMode/Button") != null, "Device tab: Switch to Desktop Mode")
		await w.frames(2)
		var got := await reachable_ids()
		var want := _expected(tab)
		for id in want:
			ok(id in got, "%s tab: %s reachable with the pad" % [tab, id])
		for id in got:
			ok(id in want, "%s tab: %s shown but it isn't a usable quick control (%s)" % [tab, id, ctl(id).reason if ctl(id) else "?"])
		# back to the top of the tab for the next RB
		qm().focus_target().grab_focus()
	await rb()
	eq(qm().section, 0, "RB wraps to This game")
	await lb()
	eq(qm().section, TC.TAB_IDS.size() - 1, "LB wraps back to Device")
	await b()
	ok(not qm().visible, "B closes it")
	await press(JOY_BUTTON_GUIDE)
	ok(qm().visible, "the pad's Guide button opens it too")
	await press(JOY_BUTTON_GUIDE)
	ok(not qm().visible, "and closes it")


func test_quick_controls_change_the_system() -> void:
	for tab in ["power", "display", "audio", "controller", "device"]:
		ok(await open_menu_tab(tab), "%s tab opened with the pad" % tab)
		qm().focus_target().grab_focus()
		await w.frames(1)
		var done := {}
		for step in 40:
			var f := focus()
			if f == null or not qm().body.is_ancestor_of(f):
				break
			var v := _view_of(f)
			if v != null and not done.has(v.key):
				var id: String = v.key
				done[id] = true
				var c := ctl(id)
				if c != null and qm().model.blocked_reason(c) != "":
					var b0: Variant = c.value
					await change()
					await w.idle()
					ok(c.value == b0, "%s: %s is locked (%s) and stays" % [tab, id, qm().model.blocked_reason(c)])
				elif c != null and c.available and c.kind != "action" and not id in ["network.airplane", "system.keep_awake"] \
						and not (c.kind == "choice" and c.options.size() < 2) and qm().model.blocked_reason(c) == "":
					var before: Variant = c.value
					if c.kind == "slider":
						if before != null and float(before) >= c.max_value - 0.0001:
							await change(-1)
						else:
							await change(1)
						await w.wait_s(0.35)
					else:
						await change(1)
						if c.kind == "color":
							await w.wait_s(0.5)   # ColorRow settles before it sends
					await w.idle()
					var model: Object = qm().model
					ok(not model.is_failed(id) and not model.is_pending(id), "%s: %s applied (failed=%s)" % [tab, id, model.is_failed(id)])
					ok(c.value != before, "%s: %s changed from %s" % [tab, id, before])
					var eff := Effects.check(self, id, c.value)
					ok(eff == "", "%s: %s on the system: %s" % [tab, id, eff])
					for p in Checks.now(w):
						ok(false, "after %s: %s" % [id, p])
					f = focus()
			if f == null:
				break
			var before_focus := f
			await down()
			if focus() == before_focus:
				break
		await b()


func _view_of(f: Node) -> Node:
	var n := f
	while n != null and n != qm():
		if n.get_script() == ControlView:
			return n
		n = n.get_parent()
	return null


func test_y_opens_the_tabs_settings_page() -> void:
	ok(await open_menu_tab("power"), "Power tab")
	await press(JOY_BUTTON_Y)
	await w.frames(3)
	ok(not qm().visible, "Y closes the menu")
	eq(main().current, "settings", "and shows Settings")
	eq(main().settings.category, "power", "on the Power page")
	ok(main().settings.in_page(), "focus inside the page")


## Desktop Mode: A asks, A again switches; InterceptMode 0 on every device first.
func test_desktop_mode_switch_releases_the_controller() -> void:
	ok(await open_menu_tab("device"), "Device tab")
	var desk := qm().body.get_node("DesktopMode/Button") as Button
	ok(await focus_on(desk), "Switch to Desktop Mode reachable with the pad")
	await a()
	eq(desk.text, preload("res://scripts/ui/texts.gd").DESKTOP_CONFIRM, "first A asks")
	eq(w.fake.events.size(), 0, "nothing switched yet")
	await up()
	await down()
	ok(desk.text != preload("res://scripts/ui/texts.gd").DESKTOP_CONFIRM or not is_instance_valid(desk), "moving away cancels")
	desk = qm().body.get_node("DesktopMode/Button") as Button
	await focus_on(desk)
	await a()
	await a()
	await w.idle()
	ok("desktop" in w.fake.events, "the desktop session was asked for")
	for m in w.fake.prop_value("InterceptMode"):
		eq(int(m), 0, "InterceptMode released before the switch")
	# review M8: the fake switch "worked" but GameCove is still here: once the wait is over the
	# controller comes back (done now, so the timer doesn't fire in a later test)
	qm().switch_timed_out(qm()._switch_gen)
	await w.idle()
	eq(qm().status_label.text, preload("res://scripts/ui/texts.gd").SWITCH_STUCK, "says the switch didn't take GameCove away")


func test_steam_mode_switch_releases_the_controller() -> void:
	ok(await open_menu_tab("device"), "Device tab")
	var steam := qm().body.get_node("SteamMode/Button") as Button
	ok(await focus_on(steam), "Switch to Steam reachable with the pad")
	await a()
	await a()
	await w.idle()
	ok("steam" in w.fake.events, "Steam's session was asked for")
	for m in w.fake.prop_value("InterceptMode"):
		eq(int(m), 0, "InterceptMode released before the switch")
