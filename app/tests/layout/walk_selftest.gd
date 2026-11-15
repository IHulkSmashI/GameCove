extends SceneTree
## The focus walk's own test (tests/layout/focus_walk.gd, docs/CONTROLLER-UX.md)
## on small screens built here: each breaks one rule on purpose and the walk
## must name it; the clean screen gets nothing. It needs a live tree (focus,
## input), so it isn't one of tests/run_tests.gd's: tools/layout/run.py runs it
## before the matrix and stops on a failure.
##   godot --headless --path app -s res://tests/layout/walk_selftest.gd

const Walk := preload("res://tests/layout/focus_walk.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")


var failures: Array[String] = []
var _current := ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var n := 0
	for m in get_method_list():
		var name: String = m["name"]
		if not name.begins_with("test_"):
			continue
		_current = name
		call(name)
		n += 1
	for f in failures:
		printerr("WALK SELFTEST FAIL ", f)
	print("WALK SELFTEST %s: %d tests, %d failed" % ["PASS" if failures.is_empty() else "FAIL", n, failures.size()])
	quit(0 if failures.is_empty() else 1)


func eq(actual, expected, what := "") -> void:
	if typeof(actual) != typeof(expected) or actual != expected:
		failures.append("%s: %s expected %s, got %s" % [_current, what, var_to_str(expected), var_to_str(actual)])


func ok(condition: bool, what := "") -> void:
	if not condition:
		failures.append("%s: %s" % [_current, what])


func _root() -> Window:
	return root


func _screen() -> Control:
	var s := Control.new()
	s.name = "WalkScreen"
	s.position = Vector2.ZERO
	s.size = Vector2(1000, 600)
	_root().add_child(s)
	return s


func _button(parent: Control, n: String, at: Vector2, sz := Vector2(120, 60)) -> Button:
	var b := Button.new()
	b.name = n
	b.text = n
	b.focus_mode = Control.FOCUS_ALL
	parent.add_child(b)
	b.position = at
	b.size = sz
	return b


func _kinds(res: Dictionary) -> Array:
	return res["problems"].map(func(p): return p["kind"])


func _scan(s: Control, first: Control) -> Dictionary:
	first.grab_focus()
	var res := Walk.scan(_root())
	s.free()
	return res


func test_a_clean_row_passes() -> void:
	var s := _screen()
	var a := _button(s, "A", Vector2(20, 20))
	_button(s, "B", Vector2(200, 20))
	_button(s, "C", Vector2(380, 20))
	var res := _scan(s, a)
	eq(_kinds(res), [], "three buttons in a row, nothing wrong: %s" % str(res["problems"]))
	ok(int(res["stats"]["presses"]) == 12, "every direction from every button (%s)" % res["stats"])


## The installer's Continue / Back / Skip row: right went past Back.
func test_skipping_the_middle_button_is_found() -> void:
	var s := _screen()
	var a := _button(s, "Continue", Vector2(20, 20))
	var mid: Button = _button(s, "Back", Vector2(200, 20))
	var c := _button(s, "Skip", Vector2(380, 20))
	a.focus_neighbor_right = a.get_path_to(c)
	c.focus_neighbor_left = c.get_path_to(a)
	var res := _scan(s, a)
	ok("pad-skip" in _kinds(res), "right from Continue jumps over Back (%s): %s" % [mid.name if is_instance_valid(mid) else "Back", str(res["problems"])])


func test_going_the_wrong_way_is_found() -> void:
	var s := _screen()
	var a := _button(s, "A", Vector2(20, 20))
	var b := _button(s, "B", Vector2(200, 20))
	b.focus_neighbor_right = b.get_path_to(a)
	var res := _scan(s, a)
	ok("pad-direction" in _kinds(res), "right from B goes back to A: %s" % str(res["problems"]))


## The Device screen's radio group: right changed the value instead of moving on.
func test_dpad_changing_a_value_is_found_and_put_back() -> void:
	var s := _screen()
	var radio := _button(s, "Radio", Vector2(20, 20))
	radio.toggle_mode = true
	radio.gui_input.connect(func(e: InputEvent):
		if e.is_action_pressed("ui_right"):
			radio.button_pressed = not radio.button_pressed
			radio.accept_event())
	_button(s, "Power", Vector2(200, 20))
	radio.grab_focus()
	var res := Walk.scan(_root())
	ok("pad-value" in _kinds(res), "right changed the radio: %s" % str(res["problems"]))
	eq(radio.button_pressed, false, "and the walk put it back")
	s.free()


func test_a_stepper_may_change_on_left_and_right() -> void:
	var s := _screen()
	var st := _button(s, "Stepper", Vector2(20, 20), Vector2(400, 60))
	st.toggle_mode = true
	st.set_meta("ux_stepper", true)
	st.gui_input.connect(func(e: InputEvent):
		if e.is_action_pressed("ui_left") or e.is_action_pressed("ui_right"):
			st.button_pressed = not st.button_pressed
			st.accept_event())
	_button(s, "Below", Vector2(20, 120), Vector2(400, 60))
	var res := _scan(s, st)
	eq(_kinds(res), [], "left / right on a stepper is its value: %s" % str(res["problems"]))


func test_focusable_things_that_do_nothing_are_found() -> void:
	var s := _screen()
	var a := _button(s, "A", Vector2(20, 20))
	var card := PanelContainer.new()
	card.focus_mode = Control.FOCUS_ALL
	s.add_child(card)
	card.position = Vector2(20, 120)
	card.size = Vector2(300, 80)
	var off := _button(s, "Off", Vector2(20, 240))
	off.disabled = true
	var res := _scan(s, a)
	eq(_kinds(res).count("pad-dead"), 2, "the card and the disabled button: %s" % str(res["problems"]))


## The Welcome cards: the selected card's accent border read as a second focus.
func test_a_selected_look_like_focus_is_found() -> void:
	var s := _screen()
	var a := _button(s, "Easy", Vector2(20, 20), Vector2(300, 200))
	var b := _button(s, "Custom", Vector2(400, 20), Vector2(300, 200))
	b.toggle_mode = true
	b.button_pressed = true
	var sb := StyleBoxFlat.new()
	sb.border_color = ThemeLib.color("accent")
	sb.set_border_width_all(2)
	b.add_theme_stylebox_override("pressed", sb)
	var res := _scan(s, a)
	ok("pad-double" in _kinds(res), "Custom looks focused while Easy is: %s" % str(res["problems"]))


func test_a_control_off_the_window_is_found() -> void:
	var s := _screen()
	var a := _button(s, "A", Vector2(20, 20))
	var view := _root().get_visible_rect()
	_button(s, "Gone", Vector2(view.size.x - 40, 20))
	var res := _scan(s, a)
	ok("pad-offscreen" in _kinds(res), "a button half past the right edge: %s" % str(res["problems"]))


func test_unreachable_and_stuck_are_found() -> void:
	var s := _screen()
	var a := _button(s, "A", Vector2(20, 20))
	_button(s, "B", Vector2(200, 20))
	for side in ["left", "right", "top", "bottom"]:
		a.set("focus_neighbor_" + side, a.get_path_to(a))
	var res := _scan(s, a)
	var k := _kinds(res)
	ok("pad-stuck" in k, "right from A goes nowhere though B is there: %s" % str(res["problems"]))
	ok("pad-unreachable" in k, "B can't be reached: %s" % str(res["problems"]))


func test_small_targets_are_found_unless_declared() -> void:
	var s := _screen()
	var a := _button(s, "A", Vector2(20, 20))
	var tiny_name := _button(s, "Tiny", Vector2(200, 20), Vector2(30, 30)).text
	var ok_small := _button(s, "Key", Vector2(300, 20), Vector2(30, 30))
	ok_small.set_meta("ux_small_ok", "a test key")
	var res := _scan(s, a)
	var small: Array = res["problems"].filter(func(p): return p["kind"] == "pad-target")
	eq(small.size(), 1, "only the undeclared one: %s" % str(small))
	eq(small[0]["text"] if not small.is_empty() else "", tiny_name, "and it is Tiny")


func test_nothing_focused_is_found() -> void:
	var s := _screen()
	_button(s, "A", Vector2(20, 20))
	var f := _root().gui_get_focus_owner()
	if f != null:
		f.release_focus()
	var res := Walk.scan(_root())
	s.free()
	ok("pad-nofocus" in _kinds(res), "a button and no focus: %s" % str(res["problems"]))


## A press that opens something is found, and the walk stops rather than walk a screen that changed.
func test_a_dpad_press_that_changes_the_screen_is_found() -> void:
	var s := _screen()
	var a := _button(s, "A", Vector2(20, 20))
	var b := _button(s, "B", Vector2(20, 120))
	a.gui_input.connect(func(e: InputEvent):
		if e.is_action_pressed("ui_down"):
			b.visible = false
			a.accept_event())
	var res := _scan(s, a)
	ok("pad-action" in _kinds(res), "down hid B: %s" % str(res["problems"]))
