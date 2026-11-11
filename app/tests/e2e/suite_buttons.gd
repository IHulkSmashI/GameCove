extends "res://tests/e2e/e2e_case.gd"
## Button shortcuts on the real app over a fake handheld: Quick Access in a game
## (a short press opens GameCove's quick menu, a hold opens Steam's keyboard,
## the strip's Steam menu opens Steam's own), press against hold timing on real
## timers, the Button shortcuts page with the pad (this handheld's buttons, the
## sheets, the rules), the buttons handed back on every way out of the session
## and put back after InputPlumber starts the pad over (sleep / wake, a new
## controller type), and the profile lock between the page and the service.

const ButtonMap := preload("res://scripts/actions/button_map.gd")
const Prefs := preload("res://scripts/actions/shortcut_prefs.gd")
const TS := preload("res://scripts/ui/quick/texts_shortcuts.gd")
const Catalog := preload("res://scripts/ui/controls/catalog.gd")

const DEV0 := "/org/shadowblip/InputPlumber/CompositeDevice0"


func _events() -> Array:
	w.fake._log_mutex.lock()
	var e: Array = w.fake.events.duplicate()
	w.fake._log_mutex.unlock()
	return e


func _profile() -> Dictionary:
	w.fake._mutex.lock()
	var p: Dictionary = w.fake.ip_profile.duplicate(true)
	w.fake._mutex.unlock()
	return p


func _set_profile(p: Dictionary) -> void:
	w.fake._mutex.lock()
	w.fake.ip_profile = p
	w.fake._mutex.unlock()


func _names() -> Array:
	return (_profile().get("mapping", []) as Array).map(func(m): return str(m.get("name", "")))


func _has_dbus(p: Dictionary) -> bool:
	return JSON.stringify(p.get("mapping", [])).contains("\"dbus\"")


func _ctl() -> Node:
	return w.autoload("Controller")


## The D-Bus line InputPlumber sends for Quick Access going down / up.
func _quick(down: bool) -> void:
	_ctl().monitor_line({"kind": "event", "path": "/org/shadowblip/InputPlumber/devices/target/dbus0", "event": "ui_quick", "value": 1.0 if down else 0.0})


func _quick_cap() -> String:
	var q := Buttons.buttons_for(device_id(), "quick_menu")
	return str(q[0]) if not q.is_empty() else ""


func _ours() -> bool:
	return _quick_cap() == "QuickAccess" and ButtonMap.ours_in_game(device_id(), "QuickAccess")


## A game on screen, GameCove's menu closed.
func _in_game() -> void:
	Prefs.reset()
	await start_game(GAME_A)
	await until(func(): return not w.main._window_focused, 4000)
	await w.idle()


func test_quick_access_belongs_to_gamecove_in_games() -> void:
	if not _ours():
		ok(true, "%s: Quick Access is the intercept's own button here" % setup_name())
		return
	await w.idle()
	ok(await until(func(): return "GameCove QuickAccess hold:keyboard" in _names(), 4000), "at start, the live profile maps Quick Access to GameCove (held: Keyboard)")
	var m: Dictionary = ButtonMap.mapping_for(_profile(), "QuickAccess")
	eq(m.get("target_events"), [{"dbus": "ui_quick"}], "as its own D-Bus name, which reaches us while a game has the pad")
	ok(not FileAccess.file_exists(_ctl().default_profile_path()), "loaded only: no layout file written for it")
	eq(_ctl().state()["shortcuts"].get("ui_quick", {}).get("hold", ""), "keyboard", "the intercept listens for the hold")


func test_in_game_short_press_opens_our_menu_and_hold_opens_the_keyboard() -> void:
	if not _ours():
		ok(true, "%s: no Quick Access mapping to test" % setup_name())
		return
	await _in_game()
	# a short press: the menu, nothing else
	w.fake.reset_log()
	_quick(true)
	await w.frames(3)
	_quick(false)
	ok(await until(func(): return qm().visible, 3000), "a short press in the game opens GameCove's quick menu")
	await w.frames(2)
	ok(not "steam steam://open/keyboard" in _events(), "and not the keyboard")
	await b()
	await until(func(): return not qm().visible, 3000)
	await w.idle()
	# a hold past the hold time: Steam's keyboard over the game, and no menu
	var hold_s: float = _ctl().intercept.hold_s
	w.fake.reset_log()
	var t0 := Time.get_ticks_msec()
	_quick(true)
	ok(await until(func(): return "steam steam://open/keyboard" in _events(), int(hold_s * 1000) + 3000), "held: Steam's keyboard opens")
	ok(Time.get_ticks_msec() - t0 >= int(hold_s * 1000) - 20, "only once the hold time has passed (%.1f s)" % hold_s)
	_quick(false)
	await w.frames(3)
	ok(not qm().visible, "and the quick menu doesn't open as well")
	# a press shorter than the hold time is never a hold
	w.fake.reset_log()
	_quick(true)
	await w.wait_s(hold_s * 0.4)
	_quick(false)
	ok(await until(func(): return qm().visible, 3000), "let go before the hold time: the menu")
	await w.wait_s(hold_s + 0.2)
	ok(not "steam steam://open/keyboard" in _events(), "the hold timer of that press does nothing after the release")
	await b()
	await end_game()


func test_steam_menu_shortcut_opens_steams_own_menu() -> void:
	await _in_game()
	await qam()
	ok(qm().visible and qm().strip != null, "the menu with its strip")
	await up()
	var ids: Array = qm().strip.visible_ids()
	var want := "steam_menu"
	ok(want in ids, "%s: the strip has Steam menu over a game (%s)" % [setup_name(), ids])
	if not want in ids:
		await b()
		await end_game()
		return
	for i in ids.find(want):
		await right()
	ok(focus() == qm().strip.buttons[want], "Steam menu reached with the pad")
	w.fake.reset_log()
	await a()
	ok(not qm().visible, "our menu closes first")
	ok(await until(func(): return "chord Gamepad:Button:QuickAccess" in _events(), 3000), "one Quick Access press straight to the virtual pad, which Steam reads as its menu")
	eq(last_set("org.shadowblip.InputPlumber", "org.shadowblip.Input.CompositeDevice", "InterceptMode"), "1", "the game has the pad (Pass) when it goes")
	await end_game()
	# without a game Steam menu doesn't show
	await qam()
	ok(not "steam_menu" in qm().strip.visible_ids(), "with GameCove in front the strip has no Steam menu")
	await b()


# ---- the Button shortcuts page --------------------------------------------------------

## Settings > Controller > Button shortcuts, reached with the pad; the card.
func _open_page() -> Control:
	var s: Control = main().settings
	var guard := 0
	while main().current != "settings" and guard < 8:
		await rb()
		guard += 1
	await w.frames(3)
	if main().current != "settings":
		return null
	var cats: Array = s.categories()
	var btns: Dictionary = s.cat_buttons
	if not "controller" in cats:
		return null
	if focus() == null or not focus() in btns.values():
		btns[s.category].grab_focus()
		await w.frames(1)
	guard = 0
	while focus() != btns["controller"] and guard < 24:
		if cats.find(btns.find_key(focus())) < cats.find("controller"):
			await down()
		else:
			await up()
		guard += 1
	await right()
	await w.frames(3)
	# the Buttons card's link
	guard = 0
	while guard < 40:
		var f := focus()
		if f != null and f.get_parent() != null and str(f.get_parent().name) == "button_map":
			break
		await down()
		guard += 1
	await a()
	await w.frames(4)
	return main().settings.find_child("ShortcutsCard", true, false)


func test_button_shortcuts_page_lists_this_handhelds_buttons() -> void:
	var card: Control = await _open_page()
	ok(card != null, "%s: Settings > Controller > Button shortcuts opens the page" % setup_name())
	if card == null:
		return
	var want: Array = []
	for cap in ButtonMap.hold_caps(device_id()):
		want.append("hold:" + cap)
	for cap in Buttons.paddles(device_id()):
		if controls().has("controller.paddle." + cap):
			want.append("press:" + cap)
	var have: Array = card.rows.keys().filter(func(k): return not str(k).begins_with("press:") or not controls().has("controller.button." + str(k).trim_prefix("press:")))
	eq(have, want, "a hold per button next to the screen, a press per back button")
	ok(focus() != null and card.is_ancestor_of(focus()), "the link puts focus on the card's first row")
	if _ours():
		eq(card.rows["hold:QuickAccess"].value_label.text, "Keyboard", "Quick Access held: Keyboard")
		ok(card.find_child("controller_to_steam_QuickAccess", true, false) != null, "with the switch that gives it back to Steam")
	ok(card.find_child("TestArea", true, false) != null, "a test area")
	# every control of this page that works here has its row (Settings > Controller doesn't list them)
	var all: Array = controls().list("controller").map(func(c): return str(c.id))
	for id in Catalog.expand(Catalog.OWN_PAGE, all, {}):
		if not controls().available(id):
			continue
		var cap: String = id.get_slice(".", 2)
		var key := ""
		if id.begins_with("controller.paddle.") or id.begins_with("controller.button."):
			key = "press:" + cap
		elif id.begins_with("controller.hold."):
			key = "hold:" + cap
		var there: bool = card.rows.has(key) if key != "" else (card.find_child(id.replace(".", "_"), true, false) != null
			or (id == "controller.reset_shortcuts" and card.reset_row != null))
		ok(there, "%s: %s is on the Button shortcuts page" % [setup_name(), id])
	await _leave_settings()


func _leave_settings() -> void:
	var guard := 0
	while main().current == "settings" and guard < 6:
		await b()
		guard += 1
	await w.idle()


## Moves focus down to row `key` of the card.
func _to_row(card: Control, key: String) -> bool:
	for i in 40:
		if focus() == card.rows[key].button:
			return true
		await down()
	return focus() == card.rows[key].button


func test_page_sets_a_back_button_with_the_pad_and_keeps_the_rules() -> void:
	var paddles: Array = Buttons.paddles(device_id()).keys().filter(func(c): return controls().has("controller.paddle." + str(c)))
	if paddles.size() < 2:
		ok(true, "%s: fewer than two back buttons" % setup_name())
		return
	var card: Control = await _open_page()
	if card == null:
		ok(false, "page opens")
		return
	var cap: String = paddles[0]
	ok(await _to_row(card, "press:" + cap), "the first back button's press row")
	await a()
	ok(card.sheet_open(), "A opens the sheet")
	eq(card.sheet.items[2]["id"], "group:action", "kinds listed")
	await down()
	await down()
	await a()   # A GameCove action
	await w.frames(3)
	ok(card.sheet_open() and card.sheet.items.any(func(i): return i["id"] == "set:action:screenshot"), "the actions")
	var at: int = card.sheet.items.map(func(i): return i["id"]).find("set:action:screenshot")
	for i in at - card.sheet.rows.find(focus()):
		await down()
	await a()
	ok(await until(func(): return ButtonMap.press_of(_profile(), cap) == "action:screenshot", 4000), "picked with A: InputPlumber has it")
	eq(ButtonMap.mapping_for(_profile(), cap)["target_events"], [{"dbus": "ui_volume_up"}], "as a D-Bus name no button sends")
	await w.idle()
	ok(focus() == card.rows["press:" + cap].button, "focus back on the row")
	eq(card.rows["press:" + cap].value_label.text, "Screenshot", "the row shows it")
	# the same action on the other back button shares the name
	var other: String = paddles[1]
	controls().set_value("controller.paddle." + other, "action:screenshot")
	await w.idle()
	eq(ButtonMap.mapping_for(_profile(), other)["target_events"], [{"dbus": "ui_volume_up"}], "a second button with the same action shares it")
	# what a hold can't be
	if _ours():
		var d: Dictionary = controls().describe_cached("controller.hold.QuickAccess")
		ok(not d.get("options", []).any(func(o): return o["value"] == "action:quick_menu"), "Quick Access can't be held for the quick menu (that's its press)")
		controls().set_value("controller.to_steam.QuickAccess", true)
		await w.idle()
		ok(not controls().available("controller.hold.QuickAccess"), "given back to Steam: no hold")
		eq(ButtonMap.mapping_for(_profile(), "QuickAccess")["target_events"], [{"gamepad": {"button": "QuickAccess"}}], "and in games the button is Steam's again")
		controls().set_value("controller.to_steam.QuickAccess", false)
		await w.idle()
	# reset puts it all back
	controls().set_value("controller.reset_shortcuts", true)
	await w.idle()
	ok(ButtonMap.press_of(_profile(), cap) == "" and ButtonMap.press_of(_profile(), other) == "", "Reset button shortcuts: back buttons as themselves")
	if _ours():
		ok("GameCove QuickAccess hold:keyboard" in _names(), "Quick Access ours again, held: Keyboard")
	await _leave_settings()


func test_test_area_shows_press_and_hold() -> void:
	if not _ours():
		ok(true, "%s: nothing to hold" % setup_name())
		return
	var card: Control = await _open_page()
	if card == null:
		ok(false, "page opens")
		return
	var hold_s: float = _ctl().intercept.hold_s
	_quick(true)
	await w.frames(2)
	eq(card.test_label.text, TS.BS_TEST_DOWN % Buttons.label_for(device_id(), "QuickAccess"), "down: shown at once")
	ok(await until(func(): return card.test_label.text.contains("held"), int(hold_s * 1000) + 3000), "held: the test area says so")
	_quick(false)
	await w.idle()
	await _leave_settings()


# ---- handing the buttons back, and taking them again -----------------------------------------

func _rearm() -> void:
	_ctl().setup_intercept_for_tests()
	_ctl().monitor_line({"kind": "started"})
	await w.idle()


func test_every_session_switch_hands_the_buttons_back() -> void:
	if not _ours():
		ok(true, "%s: nothing of ours to hand back" % setup_name())
		return
	await w.idle()
	controls().set_value("controller.paddle." + str(Buttons.paddles(device_id()).keys()[0]), "action:mute")
	await w.idle()
	ok(_has_dbus(_profile()), "in our session: buttons that only GameCove answers")
	var saved := FileAccess.get_file_as_string(_ctl().default_profile_path())
	for how in ["quick menu: Switch to Steam", "Shortcuts strip: Power > Desktop", "Shortcuts strip: Power > Steam"]:
		w.fake.reset_log()
		match how:
			"quick menu: Switch to Steam":
				qm().switch_session("steam")
			"Shortcuts strip: Power > Desktop":
				main().actions.power("desktop")
			"Shortcuts strip: Power > Steam":
				main().actions.power("steam")
		ok(await until(func(): return not _has_dbus(_profile()), 4000), "%s: the profile Steam / the desktop inherit has none" % how)
		ok(await until(func(): return _events().any(func(e): return str(e) in ["steam", "desktop"]), 4000), "%s: then the switch runs" % how)
		ok(w.fake.prop_value("InterceptMode").all(func(m): return int(m) == 0), "%s: and the pad sends to everyone" % how)
		eq(FileAccess.get_file_as_string(_ctl().default_profile_path()), saved, "%s: the layout file keeps them for next time" % how)
		# the switch didn't happen (GameCove is still here): take the buttons again
		qm().switch_timed_out(qm()._switch_gen)
		# switch_timed_out starts the real `gdbus monitor` again: let it go (without the restart
		# a dying monitor asks for) and let the fake's stand in for it
		_ctl().release_intercept()
		await w.idle()
		await _rearm()
		ok(await until(func(): return _has_dbus(_profile()), 4000), "%s: GameCove still here takes them again" % how)
	controls().set_value("controller.reset_shortcuts", true)
	await w.idle()


func test_buttons_come_back_after_inputplumber_starts_the_pad_over() -> void:
	if not _ours():
		ok(true, "%s: nothing to put back" % setup_name())
		return
	await w.idle()
	controls().set_value("controller.paddle." + str(Buttons.paddles(device_id()).keys()[0]), "KeyEsc")
	await w.idle()
	for why in ["sleep / wake", "a new controller type"]:
		if why == "a new controller type" and controls().available("controller.emulation"):
			var opts: Array = controls().describe_cached("controller.emulation").get("options", []).map(func(o): return o["value"])
			var pick: Variant = opts.filter(func(v): return v != controls().value("controller.emulation"))
			if not pick.is_empty():
				controls().set_value("controller.emulation", pick[0])
				await w.idle()
		# InputPlumber made the composite device again: the stock profile, nothing of ours
		_set_profile({"version": 1, "kind": "DeviceProfile", "name": "Default", "mapping": []})
		_ctl().monitor_line({"kind": "added", "path": DEV0})
		ok(await until(func(): return "GameCove QuickAccess hold:keyboard" in _names(), 5000), "after %s: Quick Access is ours again" % why)
		ok(await until(func(): return ButtonMap.press_of(_profile(), str(Buttons.paddles(device_id()).keys()[0])) == "KeyEsc", 5000), "after %s: the back button's key too (from the layout file)" % why)
		await w.idle()
	controls().set_value("controller.reset_shortcuts", true)
	await w.idle()


func test_page_and_service_never_lose_each_others_change() -> void:
	if not _ours():
		ok(true, "%s: no default mapping to race" % setup_name())
		return
	await w.idle()
	var cap: String = Buttons.paddles(device_id()).keys()[0]
	# the page writes while the service puts the usual shortcuts in (both read-modify-write the profile)
	_set_profile({"version": 1, "kind": "DeviceProfile", "name": "Default", "mapping": []})
	controls().set_value("controller.paddle." + cap, "KeyTab")
	_ctl().refresh()
	await w.idle()
	ok(await until(func(): return ButtonMap.press_of(_profile(), cap) == "KeyTab" and "GameCove QuickAccess hold:keyboard" in _names(), 5000),
		"under the profile lock both changes are in InputPlumber's profile (%s)" % [_names()])
	controls().set_value("controller.reset_shortcuts", true)
	await w.idle()
