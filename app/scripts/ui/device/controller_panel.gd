extends "res://scripts/ui/device/device_panel.gd"
## Controller page: the handheld's picture with pressed buttons lit (and the
## back button you're editing outlined), back-button remapping, gyro mode,
## rumble on/off with a test buzz, the lights (read-only), this game's own
## layout, and a button test. Talks to the Controller service (InputPlumber);
## Controller.refresh() runs when the page opens.

const Picture := preload("res://scripts/ui/device/device_picture.gd")
const ChoiceRow := preload("res://scripts/ui/choice_row.gd")
const Buttons := preload("res://scripts/device/buttons.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const ControlView := preload("res://scripts/ui/controls/control_view.gd")
const CModel := preload("res://scripts/ui/controls/model.gd")
const CShared := preload("res://scripts/ui/controls/shared.gd")
const TC := preload("res://scripts/ui/texts_controls.gd")

## Godot joypad buttons -> InputPlumber capability (part ids in the picture).
## SDL paddles: 1 = upper right, 2 = upper left, 3 = lower right, 4 = lower left.
const JOY_CAPS := {
	JOY_BUTTON_A: "South", JOY_BUTTON_B: "East", JOY_BUTTON_X: "West", JOY_BUTTON_Y: "North",
	JOY_BUTTON_BACK: "Select", JOY_BUTTON_GUIDE: "Guide", JOY_BUTTON_START: "Start",
	JOY_BUTTON_LEFT_STICK: "LeftStick", JOY_BUTTON_RIGHT_STICK: "RightStick",
	JOY_BUTTON_LEFT_SHOULDER: "LeftBumper", JOY_BUTTON_RIGHT_SHOULDER: "RightBumper",
	JOY_BUTTON_DPAD_UP: "DPadUp", JOY_BUTTON_DPAD_DOWN: "DPadDown", JOY_BUTTON_DPAD_LEFT: "DPadLeft", JOY_BUTTON_DPAD_RIGHT: "DPadRight",
	JOY_BUTTON_PADDLE1: "RightPaddle1", JOY_BUTTON_PADDLE2: "LeftPaddle1", JOY_BUTTON_PADDLE3: "RightPaddle2", JOY_BUTTON_PADDLE4: "LeftPaddle2",
}
const HOLD_TO_STOP_S := 1.0

var device_id := "generic"
var state: Dictionary = {}
var picture: TextureRect
var rows := {}               # key -> ChoiceRow
var test_button: Button
var rumble_button: Button
var testing := false
var _loaded := false
var _side: VBoxContainer
var _cards: VBoxContainer
var _caption: Label
var _trigger_down := {}
var _hold: Timer


static func build(services_: Dictionary) -> Control:
	var p = load("res://scripts/ui/device/controller_panel.gd").new()
	p.name = "ControllerPanel"
	p.services = services_
	p._build()
	return p


func _build() -> void:
	var dev := svc("device")
	if dev != null and dev.has_method("id"):
		device_id = dev.id()
	_side = side_column(0.95)
	_cards = main_column(1.05)
	_fill_side()
	var ctl := svc("controller")
	if ctl != null:
		listen(ctl.changed, _on_changed)
		if ctl.has_signal("button_event"):
			listen(ctl.button_event, _on_button_event)
		state = ctl.state()
		_loaded = bool(state.get("available", false))
		ctl.refresh()
	_fill_cards()
	_hold = Timer.new()
	_hold.one_shot = true
	_hold.wait_time = HOLD_TO_STOP_S
	_hold.timeout.connect(stop_test)
	add_child(_hold)


func opened() -> void:
	var ctl := svc("controller")
	if ctl != null:
		ctl.refresh()


func closed() -> void:
	if testing:
		stop_test()


func _leave() -> void:
	if testing:
		stop_test()
	super._leave()


func _on_changed(st: Dictionary) -> void:
	state = st
	_loaded = true
	var f := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	var keep := _focus_key(f)
	clear_box(_cards)
	rows.clear()
	_fill_cards()
	_restore_focus(keep)


func _focus_key(f: Control) -> String:
	if f == null:
		return ""
	for k in rows:
		if rows[k].button == f:
			return "row:" + k
	if f == test_button:
		return "test"
	if f == rumble_button:
		return "rumble_test"
	return "card:" + String(f.name) if f.get_parent() == _cards else ""


func _restore_focus(key: String) -> void:
	if key == "" or not is_inside_tree():
		return
	var target: Control = null
	if key.begins_with("row:") and rows.has(key.substr(4)):
		target = rows[key.substr(4)].button
	elif key == "test":
		target = test_button
	elif key == "rumble_test":
		target = rumble_button
	elif key.begins_with("card:") and _cards.has_node(key.substr(5)):
		target = _cards.get_node(key.substr(5))
	if target != null and is_instance_valid(target):
		target.grab_focus()


# ---- left: the picture ----------------------------------------------------------

func _fill_side() -> void:
	var hero := DKit.card("", "gamepad", "accent", false)
	hero[0].name = "PictureCard"
	hero[0].size_flags_vertical = Control.SIZE_EXPAND_FILL
	Kit.drop(hero[1], hero[1].get_node("Head"))
	picture = Picture.new()
	var dev := svc("device")
	picture.setup(dev.picture_for(device_id) if dev != null and dev.has_method("picture_for") else "")
	picture.custom_minimum_size = Vector2(0, 250)
	hero[1].add_child(picture)
	_caption = Kit.label(Texts.PICTURE_CAPTION, "QuietLabel", true)
	_caption.name = "Caption"
	_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hero[1].add_child(_caption)
	# what the special buttons do here
	var legend := Kit.vbox(8)
	legend.name = "Legend"
	legend.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for b in Buttons.special_buttons(device_id):
		if str(b.get("action", "")) == "":
			continue
		var row := Kit.hbox(10)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tex: Texture2D = load(str(b["glyph"])) if ResourceLoader.exists(str(b["glyph"])) else null
		var ic := TextureRect.new()
		ic.texture = tex
		ic.custom_minimum_size = Vector2(26, 26)
		ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(ic)
		var l := Kit.label(str(b["label"]), "")
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		row.add_child(Kit.label(_action_name(str(b["action"])), "ValueLabel"))
		legend.add_child(row)
	if legend.get_child_count() > 0:
		hero[1].add_child(legend)
	_side.add_child(hero[0])


static func _action_name(a: String) -> String:
	return {"home": "Home", "quick_menu": "Quick menu", "osk": "Keyboard", "screenshot": "Screenshot"}.get(a, a)


# ---- right: settings ------------------------------------------------------------

func _fill_cards() -> void:
	var focus: Array = []
	if not _loaded:
		var c := DKit.card(Texts.CONTROLLER_TITLE, "gamepad", "accent")
		c[0].name = "Card_checking"
		c[1].add_child(DKit.quiet(Texts.CHECKING))
		_cards.add_child(c[0])
		focus.append(c[0])
	elif not bool(state.get("available", false)):
		var c2 := DKit.card(Texts.NO_INPUTPLUMBER, "alert", "warn")
		c2[0].name = "Card_missing"
		c2[1].add_child(DKit.quiet(Texts.NO_INPUTPLUMBER_LINE))
		_cards.add_child(c2[0])
		focus.append(c2[0])
	if not _loaded or not bool(state.get("available", false)):
		# gyro on Controls doesn't need the Controller service's state
		focus.append_array(_gyro_controls_card())
	else:
		focus.append_array(_paddles_card())
		focus.append_array(_gyro_card())
		focus.append_array(_rumble_card())
		focus.append_array(_led_card())
		focus.append_array(_game_card())
	focus.append_array(_test_card())
	chain(focus)


func _supported(k: String) -> bool:
	var s: Dictionary = state.get("supported", {}) if state.get("supported") is Dictionary else {}
	return bool(s.get(k, false))


func _row(box: VBoxContainer, key: String, title: String, vals: Array, labels: Array, current: Variant, icon: String, explain: Callable) -> VBoxContainer:
	var r: VBoxContainer = ChoiceRow.new()
	r.explain_fn = explain
	r.setup(key, title, vals, labels, current, icon)
	box.add_child(r)
	rows[key] = r
	return r


func _paddles_card() -> Array:
	var prof: Dictionary = state.get("profile", {}) if state.get("profile") is Dictionary else {}
	var current: Dictionary = prof.get("paddles", {}) if prof.get("paddles") is Dictionary else {}
	var names: Array = current.keys()
	if names.is_empty():
		names = Buttons.paddles(device_id).keys()
	if names.is_empty() or not _supported("paddles"):
		return []
	names.sort()
	var c := DKit.card(Texts.PADDLES_TITLE, "gamepad", "accent", false)
	c[0].name = "Card_paddles"
	c[1].add_child(DKit.quiet(Texts.PADDLES_LINE))
	var out := []
	var targets: Array = Texts.PADDLE_TARGETS
	for p in names:
		var label := Buttons.label_for(device_id, p)
		var side := "left" if str(p).begins_with("Left") else "right"
		var cur := str(current.get(p, ""))
		if not cur in targets:
			targets = targets + [cur]
		var r := _row(c[1], "paddle_" + str(p), "%s  ·  %s back" % [label, side], targets,
			targets.map(func(t): return Texts.paddle_target(t)), cur, "",
			func(_k, _v): return Texts.PADDLE_EXPLAIN)
		var cap := str(p)
		r.changed.connect(func(v): _set_paddle(cap, str(v)))
		r.button.focus_entered.connect(func(): picture.set_selected([cap]))
		r.button.focus_exited.connect(func(): picture.set_selected([]))
		out.append(r.button)
	_cards.add_child(c[0])
	return out


func _set_paddle(cap: String, target: String) -> void:
	var ctl := svc("controller")
	if ctl != null:
		ctl.set_paddle(cap, target)


## Gyro through the Controls (controller.gyro on/off, controller.emulation):
## aiming itself is Steam Input's, so the card says so. The Controller
## service's older "mouse" / "stick" gyro modes write a profile form current
## InputPlumber ignores (docs/CONTROLS.md), so they're only the fallback when
## there are no Controls.
func _gyro_controls_card() -> Array:
	var ctl: Object = services.get("controls", CShared.autoload("Controls"))
	if ctl == null or not ctl.has_method("has") or not ctl.has("controller.gyro"):
		return []
	var m = CModel.new()
	m.setup(ctl, services.get("profiles", CShared.autoload("Profiles")))
	var c := DKit.card(Texts.GYRO_TITLE, "motion", "info", false)
	c[0].name = "Card_gyro"
	var out := []
	for id in ["controller.gyro", "controller.emulation", "controller.gyro_accel"]:
		var v: Control = ControlView.make(m, id)
		if v == null or (id == "controller.gyro_accel" and not bool(v.desc.get("available", false))):
			if v != null:
				v.free()
			continue
		c[1].add_child(v)
		out.append_array(v.focusables())
	c[1].add_child(DKit.quiet(TC.GYRO_STEAM_TITLE + ". " + TC.GYRO_STEAM_LINE))
	_cards.add_child(c[0])
	return out if not out.is_empty() else [c[0]]


func _gyro_card() -> Array:
	var via_controls := _gyro_controls_card()
	if not via_controls.is_empty():
		return via_controls
	var dev := svc("device")
	var f: Dictionary = dev.features() if dev != null and dev.has_method("features") else {}
	var hw := str(f.get("gyro", "unknown"))
	var c := DKit.card(Texts.GYRO_TITLE, "motion", "info", not _supported("gyro"))
	c[0].name = "Card_gyro"
	if _supported("gyro"):
		# No Controls here: the old "mouse" / "stick" modes would write a
		# profile form current InputPlumber ignores, so no switch that does
		# nothing. Aiming is Steam Input's; say where it lives.
		c[1].add_child(DKit.quiet(TC.GYRO_STEAM_TITLE + ". " + TC.GYRO_STEAM_LINE))
		_cards.add_child(c[0])
		return [c[0]]
	if hw == "none":
		c[0].free()
		return []
	c[1].add_child(DKit.quiet(Texts.GYRO_MISSING.get(hw, Texts.GYRO_MISSING["unknown"])))
	_cards.add_child(c[0])
	return [c[0]]


func _rumble_card() -> Array:
	var c := DKit.card(Texts.RUMBLE_TITLE, "sparkle", "accent", not _supported("rumble"))
	c[0].name = "Card_rumble"
	_cards.add_child(c[0])
	if not _supported("rumble"):
		c[1].add_child(DKit.quiet(Texts.RUMBLE_MISSING))
		return [c[0]]
	var on: Variant = state.get("rumble")
	var r := _row(c[1], "rumble", "Rumble", [false, true], ["Off", "On"], on == true, "",
		func(_k, v): return Texts.RUMBLE_EXPLAIN.get(v, ""))
	r.changed.connect(func(v): svc("controller").set_rumble(bool(v)))
	rumble_button = Kit.button(Texts.RUMBLE_TEST)
	rumble_button.name = "RumbleTest"
	rumble_button.custom_minimum_size = Vector2(0, 48)
	rumble_button.disabled = on != true
	rumble_button.pressed.connect(func(): svc("controller").test_rumble(0.6))
	c[1].add_child(rumble_button)
	return [r.button, rumble_button] if not rumble_button.disabled else [r.button]


func _led_card() -> Array:
	var dev := svc("device")
	var f: Dictionary = dev.features() if dev != null and dev.has_method("features") else {}
	if not (bool(state.get("led", false)) or bool(f.get("rgb", false))):
		return []
	var c := DKit.card(Texts.LED_TITLE, "palette", "info")
	c[0].name = "Card_lights"
	var via := str(f.get("rgb_via", ""))
	if via != "" and Texts.LED_BY.has(via):
		DKit.head_chip(c[1], DKit.chip("Run by " + Texts.LED_BY[via], ""))
	c[1].add_child(DKit.quiet(Texts.LED_LINE))
	_cards.add_child(c[0])
	return [c[0]]


func _game_card() -> Array:
	if not _supported("per_game"):
		return []
	var game := str(state.get("game", ""))
	var c := DKit.card(Texts.GAME_PROFILE_TITLE, "game", "accent", game == "")
	c[0].name = "Card_game"
	_cards.add_child(c[0])
	if game == "":
		c[1].add_child(DKit.quiet(Texts.GAME_PROFILE_IDLE))
		return [c[0]]
	var title := game.get_slice(":", 1) if game.contains(":") else game
	var r := _row(c[1], "game_profile", "Use its own layout", [false, true], ["Off", "On"], bool(state.get("game_profile", false)), "",
		func(_k, v): return Texts.GAME_PROFILE_EXPLAIN[true] % title if v else Texts.GAME_PROFILE_EXPLAIN[false])
	r.changed.connect(func(v): svc("controller").set_game_profile(game, bool(v)))
	return [r.button]


func _test_card() -> Array:
	var c := DKit.card(Texts.TEST_TITLE, "gamepad", "good", false)
	c[0].name = "Card_test"
	c[1].add_child(DKit.quiet(Texts.TEST_LINE))
	if str(state.get("game", "")) != "":
		c[1].add_child(DKit.quiet(Texts.TEST_GAME_NOTE))
	test_button = Kit.button(Texts.TEST_START)
	test_button.name = "TestButton"
	test_button.custom_minimum_size = Vector2(0, 50)
	test_button.pressed.connect(start_test)
	c[1].add_child(test_button)
	_cards.add_child(c[0])
	return [test_button]


func hints_for(c: Control) -> Array:
	if testing:
		return [["B", Texts.TEST_HOLD]]
	for k in rows:
		if rows[k].button == c:
			return [["LR", "Change"], ["B", "Back"]]
	if c is Button:
		return [["A", c.text], ["B", "Back"]]
	return [["DPAD", "Scroll"], ["B", "Back"]]


# ---- lighting buttons and the button test --------------------------------------------

func start_test() -> void:
	if testing:
		return
	testing = true
	picture.clear()
	var ctl := svc("controller")
	if ctl != null and ctl.has_method("set_button_test"):
		ctl.set_button_test(true)
	_caption.text = Texts.TEST_RUNNING
	_caption.add_theme_color_override("font_color", ThemeLib.color("accent"))
	if test_button != null:
		test_button.text = Texts.TEST_HOLD
	set_hints([["B", Texts.TEST_HOLD]])


func stop_test() -> void:
	if not testing:
		return
	testing = false
	_hold.stop()
	picture.clear()
	var ctl := svc("controller")
	if ctl != null and ctl.has_method("set_button_test"):
		ctl.set_button_test(false)
	_caption.text = Texts.PICTURE_CAPTION
	_caption.remove_theme_color_override("font_color")
	if test_button != null and is_instance_valid(test_button):
		test_button.text = Texts.TEST_START
		if test_button.is_inside_tree():
			test_button.grab_focus()
	set_hints(hints_for(test_button))


## Light a part. While testing, B held for a second ends the test.
func light(cap: String, down: bool) -> void:
	if picture == null:
		return
	picture.press(cap, down)
	if testing and cap == "East":
		if down:
			_hold.start()
		else:
			_hold.stop()


func _on_button_event(cap: String, down: bool) -> void:
	if is_visible_in_tree():
		light(cap, down)


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event is InputEventJoypadButton and JOY_CAPS.has(event.button_index):
		light(JOY_CAPS[event.button_index], event.pressed)
	elif event is InputEventJoypadMotion and event.axis in [JOY_AXIS_TRIGGER_LEFT, JOY_AXIS_TRIGGER_RIGHT]:
		var cap := "LeftTrigger" if event.axis == JOY_AXIS_TRIGGER_LEFT else "RightTrigger"
		var was: bool = _trigger_down.get(cap, false)
		var down: bool = event.axis_value > 0.5 if not was else event.axis_value > 0.3
		if down != was:
			_trigger_down[cap] = down
			light(cap, down)
	else:
		return
	if testing:
		get_viewport().set_input_as_handled()
