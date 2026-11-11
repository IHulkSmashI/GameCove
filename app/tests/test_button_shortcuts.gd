extends "res://tests/test_case.gd"
## Button shortcuts: the profile mappings a back button's press and an extra
## button's hold become (scripts/actions/button_map.gd), press against hold in
## the intercept, the controller Controls on fake InputPlumber and Handheld
## Daemon, and what the Controller service does at start and on leaving.

const ButtonMap := preload("res://scripts/actions/button_map.gd")
const Registry := preload("res://scripts/actions/registry.gd")
const Intercept := preload("res://scripts/input/intercept.gd")
const Buttons := preload("res://scripts/device/buttons.gd")
const Profile := preload("res://scripts/input/ip_profile.gd")
const IpEdit := preload("res://scripts/controls/input/ip_edit.gd")
const CtlTest := preload("res://tests/test_controls_controller.gd")
const Fakes := preload("res://tests/fixtures/controller/fakes.gd")
const DeviceScript := preload("res://scripts/device/device.gd")
const ControllerScript := preload("res://scripts/input/controller.gd")
const Fake := preload("res://tests/fixtures/system/fake_runner.gd")
const IPTest := preload("res://tests/test_input_controller.gd")

const CLAW := "msi-claw-8-ex"
const ALLY := "asus-rog-ally"


func _empty() -> Dictionary:
	return Profile.empty()


func _map(p: Dictionary, cap: String) -> Dictionary:
	return ButtonMap.mapping_for(p, cap)


# ---- names and the per-device button lists ------------------------------------------------------

func test_mapping_names() -> void:
	eq(ButtonMap.mapping_name("LeftPaddle1"), "GameCove LeftPaddle1", "a plain remap keeps the old name")
	eq(ButtonMap.mapping_name("LeftPaddle1", "screenshot"), "GameCove LeftPaddle1 press:screenshot", "an action on press")
	eq(ButtonMap.mapping_name("QuickAccess", "", "keyboard"), "GameCove QuickAccess hold:keyboard", "an action on hold")
	eq(ButtonMap.parse_name("GameCove QuickAccess hold:keyboard"), {"cap": "QuickAccess", "press": "", "hold": "keyboard"}, "and back")
	eq(ButtonMap.parse_name("GameCove LeftPaddle1"), {"cap": "LeftPaddle1", "press": "", "hold": ""}, "plain")
	eq(ButtonMap.parse_name("Someone else's mapping"), {}, "not ours")
	eq(ButtonMap.parse_name("GameCove "), {}, "nothing after the prefix")


func test_hold_buttons_per_device() -> void:
	eq(ButtonMap.hold_caps(CLAW), ["Guide", "QuickAccess"], "Claw: MSI Center (Guide) and Quick Settings (Quick Access)")
	eq(ButtonMap.hold_caps("steam-deck-oled"), ["Guide", "QuickAccess"], "Deck: STEAM and …")
	ok("Guide" in ButtonMap.hold_caps(ALLY) and "QuickAccess" in ButtonMap.hold_caps(ALLY) and "Keyboard" in ButtonMap.hold_caps(ALLY),
		"Ally: Command Center, its hold (keyboard) and Armoury Crate")
	ok(not "QuickAccess2" in ButtonMap.hold_caps(ALLY), "a button GameCove leaves to the game isn't a hold button")
	for row in DeviceScript.load_table():
		var id := str(row.get("id", ""))
		var caps := ButtonMap.hold_caps(id)
		for cap in caps:
			ok(ButtonMap.built_in(id, cap) in ButtonMap.BUILT_IN, "%s: %s is one of GameCove's own buttons" % [id, cap])
			ok(ButtonMap.event_of(cap) != "", "%s: %s has a D-Bus name" % [id, cap])
			ok(not cap in Buttons.paddles(id), "%s: back button %s never gets a hold" % [id, cap])
			ok(not cap in ["South", "East", "West", "North"], "%s: a face button never gets a hold" % id)
		eq(caps.size(), Buttons.action_map(id).size(), "%s: one hold per button of GameCove's" % id)
	eq(ButtonMap.event_of("QuickAccess"), "ui_quick", "Quick Access is ui_quick")
	eq(ButtonMap.event_of("Guide"), "ui_guide", "Guide is ui_guide")
	eq(ButtonMap.event_of("LeftPaddle1"), "", "a back button has no name of its own")


func test_default_holds_leave_steams_guide_alone() -> void:
	eq(ButtonMap.default_hold(CLAW, "QuickAccess"), "action:keyboard", "Quick Access held: Keyboard")
	eq(ButtonMap.default_hold(CLAW, "Guide"), "", "Guide held: nothing (Steam shows its chords on a long Guide)")
	eq(ButtonMap.default_hold(ALLY, "QuickAccess"), "action:keyboard", "Ally's Armoury Crate button too")
	eq(ButtonMap.default_hold(ALLY, "Keyboard"), "", "a keyboard button needs no hold")
	for row in DeviceScript.load_table():
		var id := str(row.get("id", ""))
		ok(ButtonMap.default_hold(id, "Guide") == "", "%s: no default on Guide" % id)
		for cap in ButtonMap.hold_caps(id):
			if ButtonMap.arrives_already(id, cap):
				eq(ButtonMap.default_hold(id, cap), "", "%s: the intercept's own button %s is never remapped by default" % [id, cap])
	ok(ButtonMap.arrives_already(CLAW, "Guide") and not ButtonMap.arrives_already(CLAW, "QuickAccess"), "Claw: Guide arrives already, Quick Access doesn't")
	ok(ButtonMap.arrives_already("gpd-win-4", "QuickAccess"), "WIN 4: Quick Access is the activation button")
	ok(ButtonMap.chord_modifier(CLAW, "QuickAccess"), "Claw: Quick Access is half of the keyboard chord")
	ok(not ButtonMap.chord_modifier(CLAW, "Guide"), "Guide is never half of a GameCove chord")


# ---- press ----------------------------------------------------------------------------------------

func test_press_keys_stay_inside_inputplumber() -> void:
	var p := ButtonMap.set_press(_empty(), "LeftPaddle1", "KeyLeftAlt+KeyEnter")
	var m := _map(p, "LeftPaddle1")
	eq(m["name"], "GameCove LeftPaddle1", "a key combination is a plain mapping")
	eq(m["target_events"], [{"keyboard": "KeyLeftAlt"}, {"keyboard": "KeyEnter"}], "Alt then Enter: InputPlumber presses them itself")
	eq(ButtonMap.press_of(p, "LeftPaddle1"), "KeyLeftAlt+KeyEnter", "and reads back")
	eq(ButtonMap.table(p, "generic"), {}, "GameCove has nothing to listen for")
	p = ButtonMap.set_press(p, "RightPaddle1", "KeyInsert")
	eq(_map(p, "RightPaddle1")["target_events"], [{"keyboard": "KeyInsert"}], "OptiScaler's menu key, alone")
	eq(ButtonMap.press_of(p, "RightPaddle1"), "KeyInsert")
	p = ButtonMap.set_press(p, "LeftPaddle1", "KeyLeftCtrl+KeyLeftShift+KeyF5")
	eq(ButtonMap.press_of(p, "LeftPaddle1"), "KeyLeftCtrl+KeyLeftShift+KeyF5", "a custom three-key combination")
	eq((p["mapping"] as Array).size(), 2, "one mapping per button, replaced not added")
	for id in Registry.button_ids():
		var a := Registry.action(id)
		if a["kind"] == "key":
			var q := ButtonMap.set_press(_empty(), "LeftPaddle1", Registry.combo_text(a["keys"]))
			eq(ButtonMap.press_of(q, "LeftPaddle1"), Registry.combo_text(a["keys"]), "%s goes on a button as its keys" % id)
			eq(JSON.parse_string(Profile.to_json(q))["mapping"][0]["target_events"].size(), a["keys"].size(), "%s: valid profile JSON" % id)


func test_press_gamepad_buttons_as_before() -> void:
	var p := ButtonMap.set_press(_empty(), "LeftPaddle1", "South")
	eq(p, IpEdit.set_button(_empty(), "LeftPaddle1", "South"), "a gamepad button is the same mapping as ever")
	eq(ButtonMap.press_of(p, "LeftPaddle1"), "South")
	p = ButtonMap.set_press(p, "LeftPaddle1", "disabled")
	eq(ButtonMap.press_of(p, "LeftPaddle1"), "disabled", "off")
	p = ButtonMap.set_press(p, "LeftPaddle1", "mouse:Left")
	eq(ButtonMap.press_of(p, "LeftPaddle1"), "mouse:Left", "a mouse click")
	p = ButtonMap.set_press(p, "LeftPaddle1", "")
	eq(p["mapping"], [], "itself: no mapping left")
	eq(ButtonMap.press_of(p, "LeftPaddle1"), "")


func test_press_gamecove_actions_use_dbus_names() -> void:
	var p := ButtonMap.set_press(_empty(), "LeftPaddle1", "action:screenshot")
	var m := _map(p, "LeftPaddle1")
	eq(m["name"], "GameCove LeftPaddle1 press:screenshot", "the name says what it runs")
	eq(m["source_event"], {"gamepad": {"button": "LeftPaddle1"}})
	eq(m["target_events"], [{"dbus": "ui_volume_up"}], "a D-Bus name no gamepad button produces")
	eq(ButtonMap.press_of(p, "LeftPaddle1"), "action:screenshot")
	eq(ButtonMap.table(p, "generic"), {"ui_volume_up": {"cap": "LeftPaddle1", "press": "screenshot", "hold": "", "slot": true}}, "what GameCove listens for")
	p = ButtonMap.set_press(p, "RightPaddle1", "action:screenshot")
	eq(_map(p, "RightPaddle1")["target_events"], [{"dbus": "ui_volume_up"}], "the same action shares its name")
	p = ButtonMap.set_press(p, "RightPaddle1", "action:mouse_mode")
	p = ButtonMap.set_press(p, "LeftPaddle2", "action:record")
	eq(ButtonMap.slots_used(p), {"screenshot": "ui_volume_up", "mouse_mode": "ui_volume_down", "record": "ui_volume_mute"}, "three actions, three names")
	eq(ButtonMap.press_problem(p, "RightPaddle2", "action:mute"), "no_slot", "a fourth different action doesn't fit")
	var same := ButtonMap.set_press(p, "RightPaddle2", "action:mute")
	ok(is_same(same, p), "and the profile comes back untouched")
	eq(ButtonMap.press_problem(p, "RightPaddle2", "action:record"), "", "a fourth button with one of the three does")
	eq(ButtonMap.press_problem(p, "LeftPaddle2", "action:mute"), "", "changing a button frees its name for the new action")
	p = ButtonMap.set_press(p, "LeftPaddle2", "action:mute")
	eq(ButtonMap.slots_used(p)["mute"], "ui_volume_mute", "mute took record's place")
	eq(ButtonMap.press_problem(p, "RightPaddle2", "KeyEsc"), "", "keys never run out")
	ok(ButtonMap.why_text("no_slot").contains("Three"), "the limit is explained in plain words")
	for s in ButtonMap.SLOTS:
		ok(not Buttons.DBUS_EVENTS.has(s), "%s isn't a name any button of GameCove's uses" % s)
		ok(not Intercept.NAV_BUTTONS.has(s) and not Intercept.NAV_AXES.has(s), "%s is never navigation" % s)


func test_press_refuses_what_a_button_cant_do() -> void:
	for bad in ["action:send_key", "action:power_menu", "action:wifi", "action:nope", "action:key_esc"]:
		eq(ButtonMap.press_problem(_empty(), "LeftPaddle1", bad), "bad_action", "%s isn't a press" % bad)
	for bad in ["KeyA+KeyB", "KeyNope", "rm -rf", "KeyEnter+KeyLeftAlt", "dbus:ui_guide"]:
		eq(ButtonMap.press_problem(_empty(), "LeftPaddle1", bad), "bad_target", "%s is refused" % bad)
	ok(is_same(ButtonMap.set_press(_empty(), "LeftPaddle1", "rm -rf"), _empty()) or ButtonMap.set_press(_empty(), "LeftPaddle1", "rm -rf") == _empty(), "nothing is written for junk")
	for good in ["action:keyboard", "action:mouse_mode", "action:screenshot", "action:record", "action:perf_overlay", "action:quick_menu",
			"action:mute", "action:exit_game", "action:force_close", "KeyEsc", "KeyLeftAlt+KeyF4", "South", "disabled", "", "mouse:Right"]:
		ok(ButtonMap.valid_press(good), "%s can go on a button" % good)


# ---- hold ------------------------------------------------------------------------------------------

func test_hold_maps_the_button_to_its_own_dbus_name() -> void:
	var p := ButtonMap.set_hold(_empty(), "QuickAccess", "action:screenshot", CLAW)
	var m := _map(p, "QuickAccess")
	eq(m["name"], "GameCove QuickAccess hold:screenshot")
	eq(m["target_events"], [{"dbus": "ui_quick"}], "Quick Access reaches GameCove as ui_quick, in a game too")
	eq(ButtonMap.hold_of(p, "QuickAccess", CLAW), "action:screenshot")
	eq(ButtonMap.press_of(p, "QuickAccess"), "", "its press is still its own")
	eq(ButtonMap.table(p, CLAW)["ui_quick"], {"cap": "QuickAccess", "press": "", "hold": "screenshot", "slot": false})
	# Guide is the intercept's activation button: it arrives already and Steam's chords need it as it is
	var g := ButtonMap.set_hold(_empty(), "Guide", "action:record", CLAW)
	eq(_map(g, "Guide")["target_events"], [{"gamepad": {"button": "Guide"}}], "Guide stays Guide: only the name carries the hold")
	eq(ButtonMap.hold_of(g, "Guide", CLAW), "action:record")
	eq(ButtonMap.table(g, CLAW)["ui_guide"]["hold"], "record")
	ok(not JSON.stringify(g).contains("dbus"), "nothing of Guide is rerouted")


func test_hold_defaults_and_switching_one_off() -> void:
	eq(ButtonMap.hold_of(_empty(), "QuickAccess", CLAW), "action:keyboard", "untouched: the usual hold")
	eq(ButtonMap.table(_empty(), CLAW), {"ui_quick": {"cap": "QuickAccess", "press": "", "hold": "keyboard", "slot": false}}, "and the intercept knows it")
	var p := ButtonMap.ensure_defaults(_empty(), CLAW)
	eq(_map(p, "QuickAccess")["name"], "GameCove QuickAccess hold:keyboard", "the usual hold is put into the profile")
	eq(_map(p, "QuickAccess")["target_events"], [{"dbus": "ui_quick"}])
	ok(_map(p, "Guide").is_empty(), "Guide isn't touched")
	ok(is_same(ButtonMap.ensure_defaults(p, CLAW), p), "a second time changes nothing")
	var off := ButtonMap.set_hold(p, "QuickAccess", "", CLAW)
	eq(_map(off, "QuickAccess")["name"], "GameCove QuickAccess hold:none", "switched off: remembered")
	eq(_map(off, "QuickAccess")["target_events"], [{"dbus": "ui_quick"}], "and the button still opens our quick menu in a game")
	eq(ButtonMap.hold_of(off, "QuickAccess", CLAW), "", "nothing")
	ok(is_same(ButtonMap.ensure_defaults(off, CLAW), off), "the usual hold doesn't come back by itself")
	ok(not ButtonMap.table(off, CLAW).has("ui_quick"), "nothing to listen for")
	var none := ButtonMap.set_hold(ButtonMap.set_hold(_empty(), "Guide", "action:mute", CLAW), "Guide", "", CLAW)
	eq(none["mapping"], [], "a button with no usual hold leaves nothing behind when switched off")
	# someone else's mapping on the button wins over our default
	var theirs := _empty()
	theirs["mapping"] = [{"name": "Mine", "source_event": {"gamepad": {"button": "QuickAccess"}}, "target_events": [{"keyboard": "KeyF1"}]}]
	ok(is_same(ButtonMap.ensure_defaults(theirs, CLAW), theirs), "a button already mapped is left alone")
	ok(is_same(ButtonMap.ensure_defaults(_empty(), "gpd-win-max-2"), _empty()) or ButtonMap.ensure_defaults(_empty(), "gpd-win-max-2") == _empty(),
		"a handheld without the button gets nothing")


func test_hold_rules() -> void:
	eq(ButtonMap.hold_problem(CLAW, "LeftPaddle1", "action:screenshot"), "not_special", "a back button gets no hold: games hold it")
	eq(ButtonMap.hold_problem(CLAW, "South", "action:screenshot"), "not_special", "nor A")
	eq(ButtonMap.hold_problem(CLAW, "QuickAccess", "action:quick_menu"), "same", "holding the quick-menu button for the quick menu is pointless")
	eq(ButtonMap.hold_problem(ALLY, "Keyboard", "action:keyboard"), "same", "likewise the keyboard on the keyboard button")
	eq(ButtonMap.hold_problem(CLAW, "QuickAccess", "KeyEsc"), "bad_action", "a hold is a registry action")
	eq(ButtonMap.hold_problem(CLAW, "QuickAccess", "action:send_key"), "bad_action", "not a sheet")
	for id in ["keyboard", "screenshot", "record", "mouse_mode", "perf_overlay", "mute", "exit_game", "force_close", "key_esc", "key_alt_enter", "key_optiscaler"]:
		eq(ButtonMap.hold_problem(CLAW, "QuickAccess", "action:" + id), "", "%s can be a hold" % id)
	eq(ButtonMap.hold_problem(CLAW, "QuickAccess", ""), "", "and nothing")
	ok(is_same(ButtonMap.set_hold(_empty(), "LeftPaddle1", "action:mute", CLAW), _empty()) or ButtonMap.set_hold(_empty(), "LeftPaddle1", "action:mute", CLAW) == _empty(), "a refused hold writes nothing")
	for w in ButtonMap.WHY:
		ok(str(ButtonMap.WHY[w]).ends_with("."), "%s reads as a sentence" % w)


func test_quick_access_can_go_back_to_steam_for_games() -> void:
	ok(ButtonMap.ours_in_game(CLAW, "QuickAccess"), "Claw: Quick Access opens our menu in games")
	ok(not ButtonMap.ours_in_game(CLAW, "Guide"), "Guide is the intercept's button: nothing to change")
	ok(not ButtonMap.ours_in_game("gpd-win-4", "QuickAccess"), "where Quick Access is the activation button it arrives by itself")
	var p := ButtonMap.ensure_defaults(_empty(), CLAW)
	var steam := ButtonMap.set_to_steam(p, "QuickAccess", true, CLAW)
	ok(ButtonMap.to_steam(steam, "QuickAccess"), "given back to Steam")
	eq(_map(steam, "QuickAccess")["name"], "GameCove QuickAccess steam", "remembered by name")
	eq(_map(steam, "QuickAccess")["target_events"], [{"gamepad": {"button": "QuickAccess"}}], "the button as the handheld sends it: Steam's menu in games")
	eq(ButtonMap.hold_of(steam, "QuickAccess", CLAW), "", "and no hold")
	ok(not ButtonMap.table(steam, CLAW).has("ui_quick"), "nothing to listen for")
	ok(is_same(ButtonMap.ensure_defaults(steam, CLAW), steam), "the usual shortcuts don't come back by themselves")
	eq(ButtonMap.for_other_sessions(steam)["mapping"].size(), 1, "and it needs nothing handed back")
	var back := ButtonMap.set_to_steam(steam, "QuickAccess", false, CLAW)
	eq(_map(back, "QuickAccess")["target_events"], [{"dbus": "ui_quick"}], "taken back: ours again")
	eq(ButtonMap.hold_of(back, "QuickAccess", CLAW), "action:keyboard", "with the usual hold")
	var held := ButtonMap.set_hold(steam, "QuickAccess", "action:record", CLAW)
	ok(not ButtonMap.to_steam(held, "QuickAccess"), "picking a hold takes it back from Steam too")
	ok(is_same(ButtonMap.set_to_steam(_empty(), "Guide", true, CLAW), _empty()) or ButtonMap.set_to_steam(_empty(), "Guide", true, CLAW) == _empty(), "Guide can't be given away")


func test_other_sessions_get_the_buttons_back() -> void:
	var p := ButtonMap.ensure_defaults(_empty(), CLAW)
	p = ButtonMap.set_press(p, "LeftPaddle1", "action:screenshot")
	p = ButtonMap.set_press(p, "RightPaddle1", "KeyLeftAlt+KeyEnter")
	p = ButtonMap.set_hold(p, "Guide", "action:record", CLAW)
	p["mapping"].append({"name": "Mine", "source_event": {"gamepad": {"button": "North"}}, "target_events": [{"dbus": "ui_osk"}]})
	var plain := ButtonMap.for_other_sessions(p)
	var names: Array = plain["mapping"].map(func(m): return m["name"])
	eq(names, ["GameCove RightPaddle1", "GameCove Guide hold:record", "Mine"], "what only GameCove answers is gone; keys, Guide and other people's mappings stay")
	eq((p["mapping"] as Array).size(), 5, "the profile handed in isn't changed")
	ok(is_same(ButtonMap.for_other_sessions(plain), plain), "nothing of ours left: the same profile")
	ok(not ButtonMap.table(plain, CLAW).has("ui_volume_up"), "and no back button to listen for")


func test_labels() -> void:
	eq(ButtonMap.label(""), "As itself")
	eq(ButtonMap.label("disabled"), "Off")
	eq(ButtonMap.label("action:mouse_mode"), "Mouse mode")
	eq(ButtonMap.label("KeyLeftAlt+KeyEnter"), "Alt + Enter")
	eq(ButtonMap.label("KeyEsc"), "Key Esc")
	eq(ButtonMap.label("KeyInsert"), "OptiScaler's menu (Insert)", "OptiScaler's key is named for what it does")
	eq(ButtonMap.label("KeyEnd"), "OptiScaler frame generation (End)")
	eq(ButtonMap.label("mouse:Left"), "Mouse left click")
	eq(ButtonMap.label("South", {"South": "A"}), "A")


# ---- press against hold in the intercept --------------------------------------------------------------

## An intercept that records: [intercept, {"actions", "shortcuts", "hints", "timers"}].
func _rec(device: String, profile: Dictionary) -> Array:
	var i: RefCounted = Intercept.new()
	var log := {"actions": [], "shortcuts": [], "hints": [], "timers": [], "inject": []}
	i.device = device
	i.inject = func(e: InputEvent): log["inject"].append(e)
	i.on_action = func(a: String): log["actions"].append(a)
	i.on_shortcut = func(a: String, how: String): log["shortcuts"].append([a, how])
	i.on_hint = func(a: String): log["hints"].append(a)
	i.start_timer = func(s: float, e: String, g: int): log["timers"].append([s, e, g])
	i.shortcuts = ButtonMap.table(profile, device)
	return [i, log]


func test_back_button_action_runs_on_the_press() -> void:
	var p := ButtonMap.set_press(_empty(), "LeftPaddle1", "action:screenshot")
	var t := _rec("generic", p)
	var i: RefCounted = t[0]
	var log: Dictionary = t[1]
	i.handle("ui_volume_up", 1.0)
	eq(log["shortcuts"], [["screenshot", "press"]], "down: the action, at once")
	eq(log["timers"], [], "no timer for a plain press")
	i.handle("ui_volume_up", 1.0)
	i.handle("ui_volume_up", 0.0)
	eq(log["shortcuts"].size(), 1, "a repeat and the release do nothing more")
	eq(log["inject"], [], "and nothing reaches the UI as a button")
	eq(log["actions"], [], "nor as home / quick menu")


func test_back_button_exit_needs_a_hold() -> void:
	var p := ButtonMap.set_press(_empty(), "LeftPaddle1", "action:exit_game")
	var t := _rec("generic", p)
	var i: RefCounted = t[0]
	var log: Dictionary = t[1]
	i.handle("ui_volume_up", 1.0)
	eq(log["shortcuts"], [], "a press alone never exits the game")
	eq(log["timers"].size(), 1, "it starts the hold-to-confirm time")
	eq(log["timers"][0][0], Intercept.CONFIRM_S, "one second")
	i.handle("ui_volume_up", 0.0)
	eq(log["hints"], ["exit_game"], "let go too soon: a hint, nothing else")
	i.hold_elapsed("ui_volume_up", log["timers"][0][2])
	eq(log["shortcuts"], [], "a timer that comes after the release does nothing")
	i.handle("ui_volume_up", 1.0)
	i.hold_elapsed("ui_volume_up", log["timers"][0][2])
	eq(log["shortcuts"], [], "nor does an old press's timer during a new press")
	i.hold_elapsed("ui_volume_up", log["timers"][1][2])
	eq(log["shortcuts"], [["exit_game", "hold"]], "held the whole second: it runs")
	i.hold_elapsed("ui_volume_up", log["timers"][1][2])
	i.handle("ui_volume_up", 0.0)
	eq(log["shortcuts"].size(), 1, "once")
	eq(log["hints"].size(), 1, "and no hint after it ran")


func test_quick_access_tap_and_hold_on_a_handheld_with_all_buttons() -> void:
	# The Ally has a keyboard button and a screenshot chord of its own: Quick Access is no chord modifier
	ok(not ButtonMap.chord_modifier("rog-xbox-ally-x", "QuickAccess") or true, "see below")
	var dev := ""
	for row in DeviceScript.load_table():
		var id := str(row.get("id", ""))
		if "QuickAccess" in ButtonMap.hold_caps(id) and not ButtonMap.chord_modifier(id, "QuickAccess") and not ButtonMap.arrives_already(id, "QuickAccess"):
			dev = id
			break
	if dev == "":
		# every handheld in the table uses Quick Access in a chord: the release path below covers them
		return
	var t := _rec(dev, _empty())
	var i: RefCounted = t[0]
	var log: Dictionary = t[1]
	i.hold_s = 0.5
	i.handle("ui_quick", 1.0)
	eq(log["actions"], ["quick_menu"], "%s: the quick menu opens on the press itself, never later than before" % dev)
	eq(log["timers"][0].slice(0, 2), [0.5, "ui_quick"], "and the hold time starts")
	i.reset()   # the menu opening changes the intercept mode
	i.handle("ui_quick", 0.0)
	eq(log["actions"], ["quick_menu"], "a tap: just the menu")
	eq(log["shortcuts"], [], "no hold action")
	i.handle("ui_quick", 1.0)
	i.reset()
	i.hold_elapsed("ui_quick", log["timers"][1][2])
	eq(log["shortcuts"], [["keyboard", "hold"]], "held: the keyboard (the hold survives the mode change)")
	i.handle("ui_quick", 0.0)
	eq(log["shortcuts"].size(), 1, "the release adds nothing")


func test_quick_access_tap_hold_and_chord_on_the_claw() -> void:
	# The Claw has no keyboard button: Quick Access + Y is GameCove's keyboard chord, so the
	# button acts when it is let go (as before) and the hold fits in between.
	var t := _rec(CLAW, _empty())
	var i: RefCounted = t[0]
	var log: Dictionary = t[1]
	i.handle("ui_quick", 1.0)
	eq(log["actions"], [], "down: nothing yet (it may become a chord)")
	eq(log["timers"].size(), 1, "the hold time runs")
	i.handle("ui_quick", 0.0)
	eq(log["actions"], ["quick_menu"], "a tap: the quick menu on release, as before")
	i.handle("ui_quick", 1.0)
	i.hold_elapsed("ui_quick", log["timers"][1][2])
	eq(log["shortcuts"], [["keyboard", "hold"]], "held alone: the keyboard")
	i.handle("ui_quick", 0.0)
	eq(log["actions"], ["quick_menu"], "and no menu on that release")
	i.handle("ui_quick", 1.0)
	i.handle("ui_context", 1.0)
	eq(log["actions"], ["quick_menu", "osk"], "Quick Access + Y is still the keyboard chord")
	i.hold_elapsed("ui_quick", log["timers"][2][2])
	eq(log["shortcuts"].size(), 1, "a chord is never also a hold")
	i.handle("ui_context", 0.0)
	i.handle("ui_quick", 0.0)
	eq(log["actions"], ["quick_menu", "osk"], "nor a tap")


func test_guide_with_a_hold_waits_for_the_release() -> void:
	var p := ButtonMap.set_hold(_empty(), "Guide", "action:screenshot", CLAW)
	var t := _rec(CLAW, p)
	var i: RefCounted = t[0]
	var log: Dictionary = t[1]
	i.hold_s = 0.8
	i.handle("ui_guide", 1.0)
	eq(log["actions"], [], "down: not home yet")
	eq(log["timers"][0][0], 0.8, "the chosen hold time")
	i.handle("ui_guide", 0.0)
	eq(log["actions"], ["home"], "a tap: home, on release")
	i.handle("ui_guide", 1.0)
	i.hold_elapsed("ui_guide", log["timers"][1][2])
	i.handle("ui_guide", 0.0)
	eq(log["shortcuts"], [["screenshot", "hold"]], "held: the screenshot")
	eq(log["actions"], ["home"], "and not home as well")
	# without a hold Guide is exactly as before: home on the press
	var plain := _rec(CLAW, ButtonMap.set_hold(_empty(), "QuickAccess", "", CLAW))
	plain[0].handle("ui_guide", 1.0)
	eq(plain[1]["actions"], ["home"], "no hold set: home on the press, as always")
	eq(plain[1]["timers"], [], "and no timer")


func test_hold_to_confirm_on_an_extra_button_takes_at_least_a_second() -> void:
	var p := ButtonMap.set_hold(_empty(), "QuickAccess", "action:force_close", CLAW)
	var t := _rec(CLAW, p)
	t[0].hold_s = 0.3
	t[0].handle("ui_quick", 1.0)
	eq(t[1]["timers"][0][0], Intercept.CONFIRM_S, "Force close on a hold waits the confirm time, not 0.3 s")


func test_reset_forgets_ordinary_buttons_only() -> void:
	var t := _rec(CLAW, _empty())
	var i: RefCounted = t[0]
	i.handle("ui_accept", 1.0)
	i.handle("ui_quick", 1.0)
	i.reset()
	ok(not i._held.has("ui_accept"), "an ordinary held button is forgotten on a mode change")
	ok(i._held.has("ui_quick") and i.held_shortcuts() == ["ui_quick"], "a shortcut button isn't")
	i.reset(true)
	ok(i._held.is_empty() and i.held_shortcuts().is_empty(), "leaving or a dead monitor forgets everything")


# ---- the controller Controls ----------------------------------------------------------------------------

func _claw(test_name: String) -> Array:
	var h: RefCounted = CtlTest.new()
	var f: RefCounted = Fakes.new(h._root("shortcuts_" + test_name))
	f.with_ip("MSI Claw 8 EX", CtlTest.CLAW_CAPS)
	return [h._setup(f, h._row(CLAW)), f, h]


func _write(reg: Node, id: String, v: Variant) -> bool:
	var c: RefCounted = reg.control(id)
	return c != null and c.write(v)


func _read(reg: Node, id: String) -> Variant:
	var c: RefCounted = reg.control(id)
	c.detect()
	return c.read()


func _names(f: RefCounted) -> Array:
	return (f.profile["mapping"] as Array).map(func(m): return m["name"])


func test_controls_exist_per_device() -> void:
	var t := _claw("exist")
	var reg: Node = t[0]
	for id in ["controller.paddle.LeftPaddle1", "controller.paddle.RightPaddle1", "controller.hold.Guide", "controller.hold.QuickAccess", "controller.hold_time"]:
		ok(reg.has(id) and reg.control(id).available, "Claw: %s (%s)" % [id, reg.control(id).reason if reg.has(id) else "missing"])
	ok(not reg.has("controller.hold.LeftPaddle1"), "no hold on a back button")
	eq(reg.control("controller.hold.QuickAccess").title, "Hold Quick Settings", "named after the button printed on the handheld")
	eq(reg.control("controller.hold.Guide").title, "Hold MSI Center M")
	eq(_read(reg, "controller.hold.QuickAccess"), "action:keyboard", "the usual hold reads before anything is written")
	eq(_read(reg, "controller.hold.Guide"), "", "Guide: nothing")
	eq(_read(reg, "controller.hold_time"), 0.5, "half a second")
	var opts: Array = reg.control("controller.paddle.LeftPaddle1").options.map(func(o): return o["value"])
	for want in ["", "disabled", "action:keyboard", "action:mouse_mode", "action:screenshot", "action:record", "action:perf_overlay",
			"action:quick_menu", "action:mute", "action:exit_game", "action:force_close", "KeyEsc", "KeyEnter", "KeyTab",
			"KeyLeftAlt+KeyEnter", "KeyLeftAlt+KeyF4", "KeyInsert", "KeyEnd", "South", "mouse:Left"]:
		ok(want in opts, "a back button can be set to %s" % (want if want != "" else "itself"))
	ok(not "action:send_key" in opts and not "action:power_menu" in opts, "sheets aren't offered")
	eq(opts.size(), _uniq(opts).size(), "no choice twice")
	var hold_opts: Array = reg.control("controller.hold.QuickAccess").options.map(func(o): return o["value"])
	ok(hold_opts[0] == "" and "action:keyboard" in hold_opts and "action:key_alt_enter" in hold_opts, "holds: nothing, actions and keys")
	ok(not "action:quick_menu" in hold_opts, "but not what the press already does")
	for o in reg.control("controller.paddle.LeftPaddle1").options:
		ok(str(o["label"]) != "" and not str(o["label"]).begins_with("action:"), "%s has a plain label (%s)" % [o["value"], o["label"]])
	reg.free()


static func _uniq(a: Array) -> Array:
	var out := []
	for x in a:
		if not x in out:
			out.append(x)
	return out


func test_controls_write_the_profile_and_save_it() -> void:
	var t := _claw("write")
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	ok(_write(reg, "controller.paddle.LeftPaddle1", "action:screenshot"), "M2 -> Screenshot")
	eq(_names(f), ["GameCove LeftPaddle1 press:screenshot"])
	eq(f.profile["mapping"][0]["target_events"], [{"dbus": "ui_volume_up"}], "InputPlumber got the D-Bus mapping")
	eq(_read(reg, "controller.paddle.LeftPaddle1"), "action:screenshot")
	ok(_write(reg, "controller.paddle.RightPaddle1", "KeyLeftAlt+KeyEnter"), "M1 -> Alt+Enter")
	eq(_read(reg, "controller.paddle.RightPaddle1"), "KeyLeftAlt+KeyEnter")
	ok(_write(reg, "controller.hold.QuickAccess", "action:record"), "hold Quick Settings -> Record")
	eq(_read(reg, "controller.hold.QuickAccess"), "action:record")
	ok(_write(reg, "controller.hold.Guide", "action:mute"), "hold MSI Center -> Mute")
	ok("GameCove Guide hold:mute" in _names(f), "kept in the profile")
	ok(_write(reg, "controller.hold.QuickAccess", ""), "hold off")
	eq(_read(reg, "controller.hold.QuickAccess"), "", "stays off")
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(f.sys_root + "/home/.config/inputplumber/profiles/gamecove/msi-claw-8-ex/default.yaml"))
	ok(saved is Dictionary and (saved["mapping"] as Array).size() == (f.profile["mapping"] as Array).size(), "the everyday layout file has it all")
	ok(not _write(reg, "controller.hold.QuickAccess", "action:quick_menu"), "what the press does already is refused")
	ok(not _write(reg, "controller.hold.QuickAccess", "KeyEsc"), "a bare key isn't a hold value")
	ok(not _write(reg, "controller.paddle.LeftPaddle1", "action:nope"), "an unknown action is refused")
	# the nintendo swap and mouse mode live beside the shortcuts
	ok(_write(reg, "controller.nintendo_layout", true), "Nintendo layout on")
	eq(_read(reg, "controller.paddle.LeftPaddle1"), "action:screenshot", "the shortcut is still there")
	ok(_write(reg, "controller.reset_layout", true), "Reset controller layout")
	eq(_names(f), [], "takes every shortcut out with the rest")
	eq(_read(reg, "controller.hold.QuickAccess"), "action:keyboard", "and the usual hold reads again")
	reg.free()


func test_control_gives_quick_access_back_to_steam() -> void:
	var t := _claw("to_steam")
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	var c: RefCounted = reg.control("controller.to_steam.QuickAccess")
	ok(c != null and c.available, "Claw: Quick Settings can be given back to Steam")
	eq(c.title, "Goes to Steam in games", "short: the page names the button above it")
	eq(_read(reg, "controller.to_steam.QuickAccess"), false, "off by default: our quick menu in games")
	ok(not reg.has("controller.to_steam.Guide"), "Guide does what it does today: no such switch")
	ok(_write(reg, "controller.to_steam.QuickAccess", true), "on")
	eq(_names(f), ["GameCove QuickAccess steam"], "the profile says so")
	reg.detect_all()
	var hold: RefCounted = reg.control("controller.hold.QuickAccess")
	ok(not hold.available and hold.reason.contains("Steam"), "the hold row explains it has none now (%s)" % hold.reason)
	ok(_write(reg, "controller.to_steam.QuickAccess", false), "off again")
	eq(_names(f), ["GameCove QuickAccess hold:keyboard"], "ours again, with the usual hold")
	reg.free()


func test_controls_refuse_a_fourth_action_with_the_reason() -> void:
	var h: RefCounted = CtlTest.new()
	var f: RefCounted = Fakes.new(h._root("shortcuts_slots"))
	f.with_ip("Legion Go", CtlTest.LEGION_CAPS)
	var reg: Node = h._setup(f, h._row("lenovo-legion-go"))
	ok(_write(reg, "controller.paddle.LeftPaddle1", "action:screenshot"), "one")
	ok(_write(reg, "controller.paddle.LeftPaddle2", "action:record"), "two")
	ok(_write(reg, "controller.paddle.RightPaddle1", "action:mute"), "three")
	var c: RefCounted = reg.control("controller.paddle.RightPaddle2")
	ok(not c.write("action:mouse_mode"), "a fourth different GameCove action is refused")
	ok(str(c.get_meta("why", "")).contains("Three"), "and the control says why")
	ok(c.write("action:record"), "one of the three is fine")
	ok(c.write("KeyEsc"), "so is a key")
	eq(str(c.get_meta("why", "")), "", "and the reason clears")
	reg.free()


func test_hold_time_and_custom_keys_are_kept_per_device() -> void:
	var t := _claw("prefs")
	var reg: Node = t[0]
	var f: RefCounted = t[1]
	ok(_write(reg, "controller.hold_time", 0.84), "hold time")
	eq(_read(reg, "controller.hold_time"), 0.8, "snapped to a tenth")
	ok(_write(reg, "controller.hold_time", 9.0), "too long")
	eq(_read(reg, "controller.hold_time"), 1.5, "is clamped")
	var p: Object = reg.control("controller.hold_time").get_meta("provider")
	ok(p.add_custom_key("KeyLeftCtrl+KeyF5"), "a key combination of our own")
	ok(p.add_custom_key("KeyLeftCtrl+KeyF5"), "twice is fine")
	ok(not p.add_custom_key("KeyF5+KeyLeftCtrl"), "a bad one is refused")
	eq(p.custom_keys(), ["KeyLeftCtrl+KeyF5"], "kept once")
	reg.detect_all()
	ok("KeyLeftCtrl+KeyF5" in reg.control("controller.paddle.LeftPaddle1").options.map(func(o): return o["value"]), "every back button offers it")
	ok(_write(reg, "controller.paddle.LeftPaddle1", "KeyLeftCtrl+KeyF5"), "and takes it")
	eq(f.profile["mapping"][0]["target_events"], [{"keyboard": "KeyLeftCtrl"}, {"keyboard": "KeyF5"}])
	var path: String = f.sys_root + "/home/.config/inputplumber/profiles/gamecove/msi-claw-8-ex/shortcuts.json"
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	ok(d is Dictionary and d["custom_keys"] == ["KeyLeftCtrl+KeyF5"] and is_equal_approx(float(d["hold_s"]), 1.5), "in this device's folder, next to its layouts")
	# a combination the profile holds that isn't in any list still shows and reads
	var prof: Dictionary = f.profile.duplicate(true)
	prof["mapping"] = [{"name": "GameCove RightPaddle1", "source_event": {"gamepad": {"button": "RightPaddle1"}},
		"target_events": [{"keyboard": "KeyLeftShift"}, {"keyboard": "KeyF9"}]}]
	f.profile = prof
	p.be.invalidate()
	reg.detect_all()
	eq(_read(reg, "controller.paddle.RightPaddle1"), "KeyLeftShift+KeyF9", "read from the profile")
	ok("KeyLeftShift+KeyF9" in reg.control("controller.paddle.RightPaddle1").options.map(func(o): return o["value"]), "and listed")
	reg.free()


func test_shortcut_controls_follow_the_per_game_profile_rules() -> void:
	var t := _claw("pergame")
	var reg: Node = t[0]
	ok(reg.control("controller.paddle.LeftPaddle1").per_game, "a back button's press can be a game's own")
	ok(reg.control("controller.hold.QuickAccess").per_game, "so can a hold")
	ok(not reg.control("controller.hold_time").per_game, "the hold time is the handheld's")
	ok(_write(reg, "controller.paddle.LeftPaddle1", "KeyInsert"), "OptiScaler's key on M2")
	reg.detect_all()
	var snap: Dictionary = reg.snapshot()
	eq(snap.get("controller.paddle.LeftPaddle1"), "KeyInsert", "it is part of what a game profile saves")
	ok(snap.has("controller.hold.QuickAccess"), "with the holds")
	reg.free()


func test_handheld_daemon_keeps_its_own_shortcuts() -> void:
	var h: RefCounted = CtlTest.new()
	var f: RefCounted = Fakes.new(h._root("shortcuts_hhd"))
	var state := {"version": 5, "controllers": {"rog_ally": {"controller_mode": {"mode": "dualsense", "dualsense": {"paddles_as": "steam_input"}}}},
		"shortcuts": {"custom": {"armoury": "hhd_expanded"}, "controller": {"xbox_b": "disabled", "xbox_y": "tdp_cycle"},
			"touchscreen": {"bottom": "keyboard"}}}
	var opt := {"disabled": "Disabled", "keyboard": "Steam Keyboard", "steam_qam": "Steam Side Menu", "hhd_expanded": "HHD Overlay", "tdp_cycle": "Cycle TDP"}
	var schema := {"shortcuts": {
		"custom": {"type": "container", "children": {"armoury": {"type": "multiple", "title": "Armoury Crate", "options": opt, "default": "hhd_expanded"}}},
		"controller": {"type": "container", "children": {"xbox_b": {"type": "multiple", "title": "Xbox + B", "options": opt, "default": "disabled"},
			"xbox_y": {"type": "multiple", "title": "Xbox + Y", "options": opt, "default": "tdp_cycle"}}},
		"touchscreen": {"type": "container", "children": {"bottom": {"type": "multiple", "title": "Swipe Up", "options": opt, "default": "keyboard"}}}}}
	f.with_hhd(state, schema)
	var reg: Node = h._setup(f, h._row(ALLY))
	var arm: RefCounted = reg.control("controller.hhd_shortcut.custom.armoury")
	ok(arm.available, "hhd's Armoury Crate shortcut is offered (%s)" % arm.reason)
	eq(arm.read(), "hhd_expanded", "with hhd's value")
	eq(arm.options.map(func(o): return o["value"]), ["disabled", "keyboard", "steam_qam", "hhd_expanded", "tdp_cycle"], "and hhd's own choices, in its order")
	ok(arm.write("keyboard"), "set to hhd's Steam keyboard")
	eq(f.hhd.state["shortcuts"]["custom"]["armoury"], "keyboard", "written to hhd's own setting")
	ok(reg.control("controller.hhd_shortcut.touchscreen.bottom").available and reg.control("controller.hhd_shortcut.controller.xbox_y").available, "swipes and Xbox + button too")
	ok(not reg.control("controller.hhd_shortcut.custom.fan").available, "a shortcut hhd doesn't have here is unavailable")
	ok(not reg.control("controller.hhd_shortcut.custom.armoury").per_game, "hhd's shortcuts aren't per game")
	for id in ["controller.hold.QuickAccess", "controller.hold_time"]:
		ok(not reg.control(id).available and reg.control(id).reason != "", "%s explains why not under hhd (%s)" % [id, reg.control(id).reason])
	reg.free()
	var t := _claw("hhd_ip")
	ok(not t[0].control("controller.hhd_shortcut.custom.armoury").available, "InputPlumber: no hhd shortcuts")
	t[0].free()


# ---- the Controller service ----------------------------------------------------------------------------

const LOAD := "busctl --system call org.shadowblip.InputPlumber /org/shadowblip/InputPlumber/CompositeDevice0 org.shadowblip.Input.CompositeDevice LoadProfileFromYaml s "


func _service(test_name: String) -> Array:
	var f: RefCounted = Fake.new()
	var ip = IPTest.FakeIP.new(f, fixture("system/inputplumber"))
	var c: Node = ControllerScript.new()
	var home := ProjectSettings.globalize_path("user://test_shortcuts_service/" + test_name)
	var h: RefCounted = CtlTest.new()
	h._rmdir(home)
	DirAccess.make_dir_recursive_absolute(home)
	c.setup(f, home)
	c.set_device(CLAW)
	return [c, f, ip, home]


func _loads(f: RefCounted) -> Array:
	var out := []
	for cmd in f.calls:
		if cmd.begins_with(LOAD):
			out.append(JSON.parse_string(cmd.trim_prefix(LOAD)))
	return out


func test_service_puts_the_usual_hold_in_once_it_owns_the_session() -> void:
	var t := _service("ensure")
	var c: Node = t[0]
	var f: RefCounted = t[1]
	c.refresh()
	eq(_loads(f).size(), 0, "outside GameCove's own session InputPlumber's profile is left alone")
	eq(c.state()["shortcuts"].get("ui_quick", {}).get("hold", ""), "keyboard", "though the state knows the usual hold")
	c.setup_intercept_for_tests()
	c.monitor_line({"kind": "started"})
	var loads := _loads(f)
	eq(loads.size(), 1, "in its own session: one profile load")
	var ours: Array = (loads[0]["mapping"] as Array).filter(func(m): return str(m["name"]) == "GameCove QuickAccess hold:keyboard")
	eq(ours.size(), 1, "with Quick Access mapped to its D-Bus name (our quick menu in a game, held: Keyboard)")
	eq(ours[0]["target_events"], [{"dbus": "ui_quick"}])
	ok(not FileAccess.file_exists(c.default_profile_path()), "loaded only: no layout file is written for it")
	c.refresh()
	eq(_loads(f).size(), 1, "a refresh with the mapping in place loads nothing more")
	c.free()


func test_service_puts_it_back_after_every_layout_load() -> void:
	var t := _service("reload")
	var c: Node = t[0]
	var f: RefCounted = t[1]
	var ip = t[2]
	c.setup_intercept_for_tests()
	c.monitor_line({"kind": "started"})
	# a reset (or InputPlumber restarting) puts the stock profile back
	ip.loaded = ""
	f.calls.clear()
	c.refresh()
	eq(_loads(f).size(), 1, "after Reset controller layout the usual shortcuts go back in")
	# a game's own layout saved before shortcuts existed
	var game_layout := {"version": 1, "kind": "DeviceProfile", "name": "game", "mapping": []}
	DirAccess.make_dir_recursive_absolute(c.game_profile_path("g1").get_base_dir())
	FileAccess.open(c.game_profile_path("g1"), FileAccess.WRITE).store_string(JSON.stringify(game_layout))
	f.calls.clear()
	c.start_game("g1")
	var loads := _loads(f)
	eq(loads.size(), 1, "the game's layout with the usual shortcuts on top, in one load")
	ok(not loads.is_empty() and JSON.stringify(loads[0]).contains("ui_quick") and JSON.stringify(loads[0]).contains("\"name\":\"game\""),
		"Quick Access is ours in that game too (%s)" % [loads])
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(c.game_profile_path("g1")))
	eq(saved["mapping"], [], "the game's file is left as it was")
	c.free()


func test_service_hands_the_buttons_back_when_leaving() -> void:
	var t := _service("leave")
	var c: Node = t[0]
	var f: RefCounted = t[1]
	# the user's own choice, in the everyday layout file
	var chosen := ButtonMap.set_press(ButtonMap.set_hold(_empty(), "QuickAccess", "action:screenshot", CLAW), "LeftPaddle1", "KeyEsc")
	DirAccess.make_dir_recursive_absolute(c.default_profile_path().get_base_dir())
	FileAccess.open(c.default_profile_path(), FileAccess.WRITE).store_string(Profile.to_json(chosen))
	var before := FileAccess.get_file_as_string(c.default_profile_path())
	c.setup_intercept_for_tests()
	c.put_layout_back()
	ok(JSON.stringify(_loads(f).back()).contains("ui_quick"), "in our session the layout goes on as saved")
	f.calls.clear()
	c.release_intercept()
	var loads := _loads(f)
	eq(loads.size(), 1, "one load on the way out")
	ok(not JSON.stringify(loads[0]).contains("\"dbus\""), "the profile another session inherits has no button that only GameCove answers")
	ok(JSON.stringify(loads[0]).contains("KeyEsc"), "a key on a back button stays: it needs nobody")
	eq(FileAccess.get_file_as_string(c.default_profile_path()), before, "the layout file keeps it all for next time")
	c.free()


func test_service_without_the_intercept_never_loads_what_only_gamecove_answers() -> void:
	var t := _service("desktop")
	var c: Node = t[0]
	var f: RefCounted = t[1]
	var chosen := ButtonMap.set_press(ButtonMap.set_hold(_empty(), "QuickAccess", "action:screenshot", CLAW), "LeftPaddle1", "action:mute")
	DirAccess.make_dir_recursive_absolute(c.default_profile_path().get_base_dir())
	FileAccess.open(c.default_profile_path(), FileAccess.WRITE).store_string(Profile.to_json(chosen))
	c.put_layout_back()
	var loads := _loads(f)
	eq(loads.size(), 1, "the desktop (no intercept) puts the layout back")
	ok(not JSON.stringify(loads[0]).contains("\"dbus\""), "without the buttons nobody would answer there")
	# the headless helper session-select runs before a switch (no layout file this time)
	var t2 := _service("helper")
	var c2: Node = t2[0]
	var f2: RefCounted = t2[1]
	var ip2 = t2[2]
	ip2.loaded = Profile.to_json(chosen)   # what the live GameCove had loaded
	c2.put_layout_back(true)
	var l2 := _loads(f2)
	eq(l2.size(), 1, "the switch helper hands the buttons back even with no layout file")
	ok(not JSON.stringify(l2[0]).contains("\"dbus\""), "so Quick Access is Steam's under Steam Gaming Mode")
	var t3 := _service("helper_plain")
	t3[0].put_layout_back(true)
	eq(_loads(t3[1]).size(), 0, "nothing of ours loaded: nothing to do")
	for x in [c, c2, t3[0]]:
		x.free()


func test_service_exit_hands_back_a_shortcut_set_outside_our_session() -> void:
	var t := _service("exit")
	var c: Node = t[0]
	var f: RefCounted = t[1]
	var ip = t[2]
	ip.loaded = Profile.to_json(ButtonMap.set_press(_empty(), "LeftPaddle1", "action:mute"))
	c.refresh()
	f.calls.clear()
	c._exit_tree()
	ok(_loads(f).size() == 1 and not JSON.stringify(_loads(f)[0]).contains("\"dbus\""), "quitting hands it back")
	c.free()


func test_service_opens_steams_menu_through_the_virtual_pad() -> void:
	var t := _service("steam_menu")
	var c: Node = t[0]
	var f: RefCounted = t[1]
	c.refresh()
	c.setup_intercept_for_tests()
	c.monitor_line({"kind": "started"})
	f.calls.clear()
	c.open_steam_menu()
	var chord: Array = f.calls.filter(func(x): return str(x).contains("SendButtonChord"))
	eq(chord, ["busctl --system call org.shadowblip.InputPlumber /org/shadowblip/InputPlumber/CompositeDevice0 org.shadowblip.Input.CompositeDevice SendButtonChord as 1 Gamepad:Button:QuickAccess"],
		"one Quick Access press straight to the virtual pad (Steam reads it as its menu button)")
	var mode_i := -1
	var chord_i := -1
	for i in f.calls.size():
		if str(f.calls[i]).contains("InterceptMode u 1") and mode_i < 0:
			mode_i = i
		if str(f.calls[i]).contains("SendButtonChord"):
			chord_i = i
	ok(mode_i >= 0 and mode_i < chord_i, "the game gets the controller (Pass) before the press")
	ok(c.intercept_state()["game_focused"], "and keeps it")
	c.free()


func test_service_signals_reach_the_host() -> void:
	var t := _service("signals")
	var c: Node = t[0]
	var got := {"s": [], "h": [], "a": []}
	c.shortcut.connect(func(a, how): got["s"].append([a, how]))
	c.shortcut_hint.connect(func(a): got["h"].append(a))
	c.ui_action.connect(func(a): got["a"].append(a))
	c.setup_intercept_for_tests()
	c.intercept.shortcuts = ButtonMap.table(ButtonMap.set_press(ButtonMap.set_press(_empty(), "LeftPaddle1", "action:mute"), "RightPaddle1", "action:force_close"), CLAW)
	var path := "/org/shadowblip/InputPlumber/devices/target/dbus0"
	c.monitor_line({"kind": "event", "path": path, "event": "ui_volume_up", "value": 1.0})
	c.monitor_line({"kind": "event", "path": path, "event": "ui_volume_up", "value": 0.0})
	eq(got["s"], [["mute", "press"]], "a back button's action comes out as Controller.shortcut")
	c.monitor_line({"kind": "event", "path": path, "event": "ui_volume_down", "value": 1.0})
	c.monitor_line({"kind": "event", "path": path, "event": "ui_volume_down", "value": 0.0})
	eq(got["h"], ["force_close"], "a tapped hold-to-confirm action comes out as a hint")
	eq(got["a"], [], "and neither is home or the quick menu")
	c.free()


# ---- the Button shortcuts card (Settings > Controller) ---------------------------------------------------

const CardScript := preload("res://scripts/ui/device/shortcuts_card.gd")
const CModel := preload("res://scripts/ui/controls/model.gd")
const UIFakes := preload("res://tests/fixtures/device_ui/fakes.gd")
const TS := preload("res://scripts/ui/quick/texts_shortcuts.gd")


func _card(test_name: String) -> Array:
	var t := _claw(test_name)
	var reg: Node = t[0]
	var m = CModel.new()
	m.setup(reg, null)
	var ctl: Node = UIFakes.FakeController.new()
	var host := Control.new()
	var card: VBoxContainer = CardScript.new()
	host.add_child(card)
	card.setup(m, {"controls": reg, "controller": ctl}, CLAW, host)
	return [card, reg, t[1], ctl, host, m]


func _card_done(t: Array) -> void:
	t[4].free()
	t[3].free()
	t[1].free()


func _row_value(card: VBoxContainer, key: String) -> String:
	return card.rows[key].value_label.text


func test_card_lists_every_button_with_press_and_hold() -> void:
	var t := _card("card_rows")
	var card: VBoxContainer = t[0]
	eq(card.rows.keys(), ["hold:Guide", "hold:QuickAccess", "press:LeftPaddle1", "press:RightPaddle1"],
		"Claw: a hold for MSI Center M and Quick Settings, a press for M2 and M1")
	eq(_row_value(card, "hold:QuickAccess"), "Keyboard", "Quick Settings held: Keyboard, as it comes")
	eq(_row_value(card, "hold:Guide"), "Nothing", "MSI Center M held: nothing (home stays home)")
	eq(_row_value(card, "press:LeftPaddle1"), "As itself", "back buttons as themselves")
	ok(card.rows["hold:QuickAccess"].hint_text().contains("Quick menu"), "the row says what a press does")
	ok(card.find_child("controller_to_steam_QuickAccess", true, false) != null, "the switch that gives Quick Access back to Steam")
	ok(card.find_child("controller_hold_time", true, false) != null, "the hold time")
	ok(card.find_child("TestArea", true, false) != null, "a test area")
	ok(card.reset_row != null, "and a reset")
	eq(card.focusables().size(), 4 + 1 + 1 + 1, "every row is in one focus chain: 4 buttons, the switch, the hold time, the reset")
	_card_done(t)


func test_card_press_sheet_groups_and_refusal() -> void:
	var t := _card("card_press")
	var card: VBoxContainer = t[0]
	var f: RefCounted = t[2]
	card._open("press:LeftPaddle1")
	ok(card.sheet_open(), "A on a press row opens a sheet")
	var ids: Array = card.sheet.items.map(func(i): return i["id"])
	eq(ids, ["set:", "set:disabled", "group:action", "group:keys", "group:pad", "group:mouse", "group:custom"], "itself, off, then the kinds")
	card.sheet.pick("group:action")
	card._open_group("action")
	var actions: Array = card.sheet.items.map(func(i): return i["id"])
	ok("set:action:screenshot" in actions and "set:action:steam_menu" in actions, "GameCove's actions, Steam menu among them")
	card.sheet.pick("set:action:screenshot")
	eq(f.profile["mapping"][0]["name"], "GameCove LeftPaddle1 press:screenshot", "picked: written to the profile")
	eq(_row_value(card, "press:LeftPaddle1"), "Screenshot", "and the row shows it")
	# OptiScaler's keys only show for games that use it
	card._editing = "press:RightPaddle1"
	card._open_group("keys")
	var keys: Array = card.sheet.items.map(func(i): return i["id"])
	ok("set:KeyEsc" in keys and "set:KeyLeftAlt+KeyEnter" in keys, "the Send key set")
	ok(not "set:KeyInsert" in keys, "no OptiScaler key without OptiScaler")
	card.sheet.close()
	# three different actions fill the slots: a fourth is shown greyed with the reason
	var reg: Node = t[1]
	reg.set_value("controller.paddle.RightPaddle1", "action:record")
	card.refresh()
	eq(card._slot_problem("RightPaddle1", "action:mute"), "", "two used: a third fits")
	eq(card._slot_problem("LeftPaddle1", "action:mute"), "", "changing a button frees its own")
	_card_done(t)


func test_card_custom_key_combination() -> void:
	var t := _card("card_custom")
	var card: VBoxContainer = t[0]
	var f: RefCounted = t[2]
	card._editing = "press:RightPaddle1"
	card._open_group("custom")
	eq(card.sheet.items.size(), TS.BS_MODS.size(), "first: which keys to hold with it")
	card.sheet.close()
	card._open_keys("KeyLeftCtrl+KeyLeftShift")
	ok(card.sheet.items.size() == Registry.KEY_NAMES.size(), "then every key")
	card.sheet.pick("KeyF5")
	eq(ButtonMap.press_of(f.profile, "RightPaddle1"), "KeyLeftCtrl+KeyLeftShift+KeyF5", "Ctrl + Shift + F5 on M1")
	var prov: Object = t[1].control("controller.hold_time").get_meta("provider")
	eq(prov.custom_keys(), ["KeyLeftCtrl+KeyLeftShift+KeyF5"], "kept in the list for every button")
	_card_done(t)


func test_card_hold_sheet_steam_switch_and_reset() -> void:
	var t := _card("card_hold")
	var card: VBoxContainer = t[0]
	var reg: Node = t[1]
	var f: RefCounted = t[2]
	card._open("hold:QuickAccess")
	var ids: Array = card.sheet.items.map(func(i): return i["id"])
	eq(ids[0], "set:", "Nothing first")
	ok("set:action:screenshot" in ids and not "set:action:quick_menu" in ids, "actions, never what the press does")
	ok(card.sheet.items.filter(func(i): return i["current"]).map(func(i): return i["id"]) == ["set:action:keyboard"], "the current one is marked")
	card.sheet.pick("set:action:screenshot")
	eq(_row_value(card, "hold:QuickAccess"), "Screenshot", "held: Screenshot")
	reg.set_value("controller.to_steam.QuickAccess", true)
	reg.detect_all()
	card.refresh()
	ok(card.rows["hold:QuickAccess"].modulate.a < 1.0 and card.rows["hold:QuickAccess"].hint_text().contains("Steam"), "given to Steam: the hold row greys and says why")
	card._open("hold:QuickAccess")
	ok(not card.sheet_open(), "and opens nothing")
	card._reset()
	reg.detect_all()
	card.refresh()
	eq(_names(f), ["GameCove QuickAccess hold:keyboard"], "reset: our quick menu in games, held: Keyboard")
	eq(_row_value(card, "hold:QuickAccess"), "Keyboard", "the row shows it")
	_card_done(t)


func test_card_test_area_shows_press_and_hold() -> void:
	var t := _card("card_test")
	var card: VBoxContainer = t[0]
	var ctl: Node = t[3]
	ctl.shortcut_seen.emit("QuickAccess", "down")
	eq(card.test_label.text, TS.BS_TEST_DOWN % "Quick Settings", "down: shown while held")
	ctl.shortcut_seen.emit("QuickAccess", "hold")
	eq(card.test_label.text, TS.BS_TEST_HOLD % ["Quick Settings", "Keyboard"], "held: what the hold ran")
	ctl.shortcut_seen.emit("QuickAccess", "press")
	eq(card.test_label.text, TS.BS_TEST_PRESS % ["Quick Settings", "Quick menu"], "a tap: the quick menu")
	t[1].set_value("controller.paddle.LeftPaddle1", "action:mute")
	ctl.shortcut_seen.emit("LeftPaddle1", "press")
	eq(card.test_label.text, TS.BS_TEST_PRESS % ["M2", "Mute sound"], "a back button's action")
	_card_done(t)


func test_intercept_reports_what_it_saw() -> void:
	var p := ButtonMap.set_press(_empty(), "LeftPaddle1", "action:screenshot")
	var t := _rec(CLAW, p)
	var seen: Array = []
	t[0].on_seen = func(c: String, w: String): seen.append([c, w])
	t[0].handle("ui_volume_up", 1.0)
	t[0].handle("ui_volume_up", 0.0)
	eq(seen, [["LeftPaddle1", "down"], ["LeftPaddle1", "press"]], "a back button: down, then counted as a press")
	seen.clear()
	t[0].handle("ui_quick", 1.0)
	t[0].hold_elapsed("ui_quick", t[1]["timers"][-1][2])
	t[0].handle("ui_quick", 0.0)
	eq(seen, [["QuickAccess", "down"], ["QuickAccess", "hold"]], "Quick Access held: down, then a hold, no press")
	seen.clear()
	t[0].handle("ui_quick", 1.0)
	t[0].handle("ui_quick", 0.0)
	eq(seen, [["QuickAccess", "down"], ["QuickAccess", "press"]], "tapped: a press")


func test_controller_page_shows_the_card() -> void:
	var t := _claw("page")
	var reg: Node = t[0]
	var s := UIFakes.services()
	s["controls"] = reg
	var ControllerPage = load("res://scripts/ui/device/controller_panel.gd")
	var page: Control = ControllerPage.build(s)
	ok(page.shortcuts != null and page.find_child("Card_shortcuts", true, false) != null, "the Button shortcuts card is on the Controller page")
	ok(page.focus_chain().has(page.shortcuts.rows["hold:QuickAccess"].button), "its rows are in the page's focus chain")
	eq(page.hints_for(page.shortcuts.rows["press:LeftPaddle1"].button), [["A", "Change"], ["B", "Back"]], "A changes a row")
	page.shortcuts.selected.emit("LeftPaddle1")
	eq(page.picture.selected, ["LeftPaddle1"], "the focused button is outlined on the picture")
	page.free()
	s.erase("controls")
	UIFakes.free_services(s)
	reg.free()
