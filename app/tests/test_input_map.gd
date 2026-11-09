extends "res://tests/test_case.gd"
## Godot 4.7's built-in ui_accept / ui_cancel have no pad buttons (Enter, Space,
## Escape only), so A and B did nothing in GameCove's menus: neither from a pad
## Godot sees nor from InputPlumber's intercept, which injects A / B as joypad
## buttons (intercept.gd NAV_BUTTONS). project.godot adds them.


func _has_button(action: String, button: JoyButton) -> bool:
	for e in InputMap.action_get_events(action):
		if e is InputEventJoypadButton and e.button_index == button and e.device == -1:
			return true
	return false


func test_pad_a_and_b_are_accept_and_cancel() -> void:
	ok(_has_button("ui_accept", JOY_BUTTON_A), "A is ui_accept on every pad")
	ok(_has_button("ui_cancel", JOY_BUTTON_B), "B is ui_cancel on every pad")
	var a := InputEventJoypadButton.new()
	a.device = 3
	a.button_index = JOY_BUTTON_A
	a.pressed = true
	ok(a.is_action_pressed("ui_accept"), "a press of A on any pad accepts")
	var b := InputEventJoypadButton.new()
	b.button_index = JOY_BUTTON_B
	b.pressed = true
	ok(b.is_action_pressed("ui_cancel"), "B goes back")


func test_keyboard_keys_stay() -> void:
	var keys := InputMap.action_get_events("ui_accept").filter(func(e): return e is InputEventKey).map(func(e): return e.keycode)
	ok(KEY_ENTER in keys and KEY_KP_ENTER in keys and KEY_SPACE in keys, "Enter, keypad Enter and Space still accept")
	var esc := InputMap.action_get_events("ui_cancel").filter(func(e): return e is InputEventKey).map(func(e): return e.keycode)
	ok(KEY_ESCAPE in esc, "Escape still goes back")


func test_intercept_injects_what_the_map_takes() -> void:
	var Intercept := load("res://scripts/input/intercept.gd")
	var seen := []
	var i = Intercept.new()
	i.inject = func(e): seen.append(e)
	i.handle("ui_accept", 1.0)
	i.handle("ui_back", 1.0)
	eq(seen.size(), 2, "two buttons injected")
	ok(seen[0].is_action_pressed("ui_accept"), "InputPlumber's South reaches ui_accept")
	ok(seen[1].is_action_pressed("ui_cancel"), "InputPlumber's East reaches ui_cancel")
