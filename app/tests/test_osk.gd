extends "res://tests/test_case.gd"
## The on-screen keyboard (scripts/ui/osk.gd): its pages, Shift and Caps, the
## caret, the controller's buttons, paste, the field's window on long text,
## and its colours in every theme.

const Osk := preload("res://scripts/ui/osk.gd")
const TextKeyboard := preload("res://scripts/ui/games/text_keyboard.gd")
const Themes := preload("res://theme/themes.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const Kit := preload("res://scripts/ui/ui_kit.gd")


func _kb() -> PanelContainer:
	var k: PanelContainer = Osk.new()
	k.visible = true
	k.showing = true   # open (what open() sets), without its fade
	return k


func _pad(k: PanelContainer, button: JoyButton, pressed := true) -> void:
	var e := InputEventJoypadButton.new()
	e.button_index = button
	e.pressed = pressed
	k._input(e)


## Seed 3987000 of the monkey: Library search open, Guide to Home, the quick menu opens, B: the
## hidden keyboard took the B (closing itself, which sent focus to the hidden Library) and the
## quick menu stayed open with nothing focused.
func test_a_hidden_keyboard_takes_no_input() -> void:
	var root: Window = (Engine.get_main_loop() as SceneTree).root
	var host := Control.new()
	root.add_child(host)
	var k: PanelContainer = Osk.new()
	host.add_child(k)
	k.showing = true   # open, on a screen that then goes away
	k.visible = true
	var closed := []
	k.closed.connect(func(t): closed.append(t))
	host.visible = false
	_pad(k, JOY_BUTTON_B)
	ok(closed.is_empty() and k.showing, "B on a hidden keyboard doesn't close it")
	_pad(k, JOY_BUTTON_X)
	_pad(k, JOY_BUTTON_Y)
	eq(k.text, "", "nor does it type or delete")
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.keycode = KEY_A
	ev.unicode = 65
	k._input(ev)
	eq(k.text, "", "a physical key isn't typed into it either")
	host.visible = true
	k.visible = true
	_pad(k, JOY_BUTTON_B)
	eq(closed.size(), 1, "shown again, B closes it as before")
	host.free()


## Leaving the screen a keyboard is open on puts it away without `closed` (which would send focus back
## to that screen); the screen fades out for a moment first, and a keyboard still open there took the B.
func test_dismiss_puts_it_away_quietly() -> void:
	var k := _kb()
	var closed := []
	k.closed.connect(func(t): closed.append(t))
	k.dismiss()
	ok(not k.showing and not k.is_open(), "not open any more")
	ok(closed.is_empty(), "and `closed` was not sent")
	_pad(k, JOY_BUTTON_B)
	ok(closed.is_empty(), "so a B afterwards isn't taken")
	k.dismiss()   # twice is fine
	ok(Osk.GROUP == "osk", "keyboards are found by main.gd through their group")


func _trigger(k: PanelContainer, axis: JoyAxis, value: float) -> void:
	var e := InputEventJoypadMotion.new()
	e.axis = axis
	e.axis_value = value
	k._input(e)


func _texts(rows: Array) -> String:
	var out := ""
	for r in rows:
		for b in r:
			out += (b as Button).text
	return out


## Letters with a number row, and a symbols page: together every printable
## ASCII character can be typed with the keys alone.
func test_pages_cover_printable_ascii() -> void:
	var k := _kb()
	eq(k.keys.size(), 5, "four rows of keys and the action row")
	eq(_texts([k.keys[0]]), "1234567890", "the number row on the letters page")
	eq(_texts([k.keys[1]]), "qwertyuiop", "qwerty")
	var typed := {}
	for page in k._page_rows:
		for row in page:
			for b in row:
				(b as Button).pressed.emit()
	k.press_shift()
	k.press_shift()          # Caps
	for row in k._page_rows[0]:
		for b in row:
			(b as Button).pressed.emit()
	k.max_len = 1000
	k.set_text("")
	for page in k._page_rows:
		for row in page:
			for b in row:
				(b as Button).pressed.emit()
	k._set_shift(false)
	for row in k._page_rows[0]:
		for b in row:
			(b as Button).pressed.emit()
	k.space_button.pressed.emit()
	for i in k.text.length():
		typed[k.text[i]] = true
	var missing := ""
	for code in range(32, 127):
		if not typed.has(String.chr(code)):
			missing += String.chr(code)
	eq(missing, "", "every printable ASCII character has a key")
	for ch in "@_/?&=%+#":
		ok(typed.has(ch), "%s for codes, URLs and keys" % ch)
	k.free()


func test_touch_targets_and_names() -> void:
	var k := _kb()
	ok(Osk.KEY.x >= 60.0 and Osk.KEY.y >= 48.0, "keys are thumb-sized at 1280x800")
	for row in k.keys:
		for b in row:
			ok((b as Button).custom_minimum_size.y >= 48.0, "%s is tall enough to tap" % b.name)
			ok((b as Button).custom_minimum_size.x >= 60.0, "%s is wide enough to tap" % b.name)
			eq((b as Button).focus_mode, Control.FOCUS_ALL, "and takes focus")
	# The whole grid fits the sheet every caller gives it (800 px, 24 px padding).
	ok(10 * Osk.KEY.x + 9 * Osk.GAP <= 800.0 - 48.0, "ten keys fit the sheet")
	var w := 0.0
	for b in k._action_row:
		w += (b as Button).custom_minimum_size.x
	ok(w + 7 * Osk.GAP <= 10 * Osk.KEY.x + 9 * Osk.GAP, "so does the action row")
	# The controller's buttons are shown on the keys that share them.
	for pair in [[k.back_button, "X"], [k.space_button, "Y"], [k.shift_button, "LT"], [k.symbols_button, "RT"],
			[k.left_button, "LB"], [k.right_button, "RB"]]:
		ok((pair[0] as Button).find_child("Glyph_" + pair[1], true, false) != null, "%s shows %s" % [pair[0].name, pair[1]])
	eq(k.done_button.get_node("Fx").glyph, "MENU", "Done shows Menu (Start)")
	ok(Kit.prompts_text(k.find_child("Tips", true, false)).contains("B"), "B closes, said beside the field")
	ok(k.clear_button != null and k.done_button.text == "Done", "clear and Done are there")
	k.free()


func test_typing_at_the_caret() -> void:
	var k := _kb()
	var got: Array = []
	k.text_changed.connect(func(t): got.append(t))
	for ch in "helo":
		k.type(ch)
	eq(k.caret, 4, "the caret follows the text")
	k.move_caret(-1)
	k.type("l")
	eq(k.text, "hello", "typed where the caret is")
	eq(k.caret, 4, "and the caret moves past it")
	k.move_caret(-10)
	eq(k.caret, 0, "the caret stops at the start")
	k.backspace()
	eq(k.text, "hello", "nothing before it to delete")
	k.delete_forward()
	eq(k.text, "ello", "Delete takes the next one")
	k.move_caret(99)
	eq(k.caret, 4, "and stops at the end")
	k.backspace()
	eq(k.text, "ell", "backspace takes the one before")
	eq(got[-1], "ell", "every change is announced")
	k.set_text("")
	eq(k.field.text, "Type to search", "the placeholder when empty")
	eq(k._caret.position.x, 0.0, "with the caret at its start")
	k.max_len = 3
	for ch in "abcdef":
		k.type(ch)
	eq(k.text, "abc", "max_len holds")
	k.read_clipboard = func() -> String: return "zzz"
	k.paste()
	eq(k.text, "abc", "for a paste too")
	k.free()


func test_shift_once_caps_twice() -> void:
	var k := _kb()
	k.max_len = 100
	ok(k.shift_button != null and not k.shift, "Shift is always there, off")
	eq(k.keys[1][0].text, "q", "lower case keys")
	k.shift_button.pressed.emit()
	ok(k.shift and not k.caps, "one press: the next letter")
	eq(k.keys[1][0].text, "Q", "the keys show capitals")
	ok(k.shift_button.get_meta("on") and not k.shift_button.get_meta("strong"), "the key shows it's on")
	k.type("a")
	k.type("b")
	eq(k.text, "Ab", "one capital, then lower case again")
	ok(not k.shift, "Shift lets go by itself")
	k.shift_button.pressed.emit()
	k.type("1")
	ok(k.shift, "a digit doesn't use it up")
	k.shift_button.pressed.emit()
	ok(k.shift and k.caps, "a second press: Caps")
	ok(k.shift_button.get_meta("strong"), "shown stronger")
	k.type("c")
	k.type("d")
	eq(k.text, "Ab1CD", "Caps stays")
	k.shift_button.pressed.emit()
	ok(not k.shift and not k.caps, "a third press: off")
	k.type("e")
	eq(k.text, "Ab1CDe", "lower case")
	eq(k.keys[1][0].text, "q", "and the keys say so")
	k.free()


func test_symbols_page() -> void:
	var k := _kb()
	ok(not k.symbols, "letters first")
	k.symbols_button.pressed.emit()
	ok(k.symbols, "RT's key turns the page")
	eq(k.keys.size(), 5, "four rows and the action row")
	eq(_texts([k.keys[0]]), "!@#$%^&*", "symbols")
	eq((k.symbols_button.get_node("Face/Word") as Label).text, "ABC", "the key says how to get back")
	ok(k.symbols_button.get_meta("on"), "and shows it's on")
	for row in k.keys:
		for b in row:
			ok(b.focus_neighbor_top != NodePath() and b.focus_neighbor_left != NodePath(), "%s is wired" % b.name)
	k.keys[0][1].pressed.emit()
	eq(k.text, "@", "a symbol types")
	k.toggle_symbols()
	ok(not k.symbols and _texts([k.keys[1]]) == "qwertyuiop", "back to letters")
	k.symbols = true
	k._show_page()
	k.open("x")
	ok(not k.symbols, "opening starts on letters")
	k.free()


## Left / right wrap inside a row (a linear list); up on the top row and down on
## the action row stay put (a grid doesn't loop: docs/CONTROLLER-UX.md CUX-5).
func test_focus_wraps() -> void:
	var k := _kb()
	var top: Array = k.keys[0]
	var last: Array = k.keys[-1]
	eq(top[0].get_node(top[0].focus_neighbor_left), top[-1], "left from the first key: the last")
	eq(top[-1].get_node(top[-1].focus_neighbor_right), top[0], "right from the last key: the first")
	eq(top[0].get_node(top[0].focus_neighbor_top), top[0], "up from the top row: stays")
	eq(last[-1].get_node(last[-1].focus_neighbor_bottom), last[-1], "down from Done: stays")
	eq(k.keys[1][0].get_node(k.keys[1][0].focus_neighbor_top), top[0], "up from the second row: the top row")
	ok(top[0].get_parent().has_meta("ux_wrap"), "a row says it wraps (the focus walk accepts it)")
	eq(last[0], k.shift_button, "Shift first")
	eq(last[-1], k.done_button, "Done last")
	k.free()


func test_controller_buttons() -> void:
	var k := _kb()
	var closed: Array = []
	k.closed.connect(func(t): closed.append(t))
	for ch in "ab":
		k.type(ch)
	_pad(k, JOY_BUTTON_Y)
	eq(k.text, "ab ", "Y: space")
	_pad(k, JOY_BUTTON_X)
	eq(k.text, "ab", "X: backspace")
	eq(k._repeat_what, "back", "and it repeats while held")
	_pad(k, JOY_BUTTON_X, false)
	eq(k._repeat_what, "", "until it's let go")
	_pad(k, JOY_BUTTON_LEFT_SHOULDER)
	eq(k.caret, 1, "LB: the caret left")
	eq(k._repeat_what, "caret_left", "held, it keeps going")
	_pad(k, JOY_BUTTON_LEFT_SHOULDER, false)
	k.type("x")
	eq(k.text, "axb", "typing goes where the caret is")
	_pad(k, JOY_BUTTON_RIGHT_SHOULDER)
	eq(k.caret, 3, "RB: the caret right")
	_pad(k, JOY_BUTTON_RIGHT_SHOULDER, false)
	_pad(k, JOY_BUTTON_LEFT_STICK)
	ok(k.shift and not k.caps, "L3: Shift")
	_trigger(k, JOY_AXIS_TRIGGER_LEFT, 0.9)
	ok(k.caps, "LT: Shift again (Caps)")
	_trigger(k, JOY_AXIS_TRIGGER_LEFT, 0.95)
	ok(k.caps, "one pull is one press")
	_trigger(k, JOY_AXIS_TRIGGER_LEFT, 0.0)
	_trigger(k, JOY_AXIS_TRIGGER_LEFT, 1.0)
	ok(not k.shift, "let go and pulled again: off")
	_trigger(k, JOY_AXIS_TRIGGER_LEFT, 0.0)
	_trigger(k, JOY_AXIS_TRIGGER_RIGHT, 1.0)
	ok(k.symbols, "RT: symbols")
	_trigger(k, JOY_AXIS_TRIGGER_RIGHT, 0.8)
	ok(k.symbols, "held, it stays")
	_trigger(k, JOY_AXIS_TRIGGER_RIGHT, 0.0)
	_trigger(k, JOY_AXIS_TRIGGER_RIGHT, 1.0)
	ok(not k.symbols, "RT again: letters")
	# A held D-pad direction repeats; the first step is the usual focus move.
	_pad(k, JOY_BUTTON_DPAD_RIGHT)
	eq(k._repeat_what, "right", "a held D-pad direction repeats")
	_pad(k, JOY_BUTTON_DPAD_RIGHT, false)
	eq(k._repeat_what, "", "until it's let go")
	ok(Osk.REPEAT_DELAY >= 0.3 and Osk.REPEAT_RATE <= 0.1, "after a short wait, at a steady pace")
	k.repeat_step("back")
	eq(k.text, "ax", "a repeat of backspace deletes one more")
	k.repeat_step("caret_left")
	eq(k.caret, 1, "a repeat of LB moves one more")
	_pad(k, JOY_BUTTON_START)
	eq(closed, ["ax"], "Menu (Start) is Done: the text goes back")
	k.visible = true
	k.showing = true   # open (what open() sets), without its fade
	_pad(k, JOY_BUTTON_B)
	eq(closed.size(), 2, "B closes too")
	eq(closed[1], "", "but B cancels: what was typed since it opened is not kept")
	k.visible = false
	_pad(k, JOY_BUTTON_Y)
	eq(k.text, "", "closed, it takes nothing")
	k.free()


func _key_event(code: Key, unicode := 0, ctrl := false) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = code
	e.unicode = unicode
	e.ctrl_pressed = ctrl
	e.pressed = true
	return e


func test_physical_keyboard_and_paste() -> void:
	var k := _kb()
	k._input(_key_event(KEY_A, 65))
	eq(k.text, "a", "search lower-cases a physical keyboard")
	k._input(_key_event(KEY_BACKSPACE))
	eq(k.text, "", "Backspace")
	k.use_for_codes("Paste your key")
	ok(k.paste_button.visible, "codes get a Paste key beside the field")
	eq(k.keys[0], [k.paste_button], "reachable with the D-pad, above the number row")
	eq(k.keys.size(), 6, "then the four rows and the actions")
	k._input(_key_event(KEY_A, 65))
	eq(k.text, "A", "codes keep the case typed")
	k.read_clipboard = func() -> String: return "  Key-123\nabc \r\n"
	k._input(_key_event(KEY_V, 0, true))
	eq(k.text, "AKey-123 abc", "Ctrl+V pastes one clean line at the caret")
	k.set_text("")
	k.paste_button.pressed.emit()
	eq(k.text, "Key-123 abc", "and so does the Paste key")
	k._input(_key_event(KEY_HOME))
	eq(k.caret, 0, "Home")
	k._input(_key_event(KEY_DELETE))
	eq(k.text, "ey-123 abc", "Delete")
	k._input(_key_event(KEY_END))
	eq(k.caret, k.text.length(), "End")
	var closed: Array = []
	k.closed.connect(func(t): closed.append(t))
	k._input(_key_event(KEY_ENTER))
	eq(closed, ["ey-123 abc"], "Enter is Done")
	k.free()
	var search := _kb()
	ok(not search.paste_button.visible, "search has no Paste key")
	search.read_clipboard = func() -> String: return "Hades"
	search._input(_key_event(KEY_V, 0, true))
	eq(search.text, "hades", "but Ctrl+V still pastes")
	search.free()


## Tapping or clicking the text puts the caret between the characters nearest the tap.
func test_tap_places_the_caret() -> void:
	var k := _kb()
	k.set_text("hello world")
	var before: float = k._caret.position.x
	k.field.gui_input.emit(_click(k._width("hel") + 1.0))
	eq(k.caret, 3, "a tap just right of 'hel' puts the caret after it")
	eq(k._caret.position.x, k._width("hel"), "and the caret is drawn there")
	k.field.gui_input.emit(_click(k._width("hello wor") - 2.0))
	eq(k.caret, 9, "a tap near the end of 'wor'")
	k.field.gui_input.emit(_click(0.0))
	eq(k.caret, 0, "a tap at the left edge: the start")
	k.field.gui_input.emit(_click(5000.0))
	eq(k.caret, 11, "a tap past the text: the end")
	ok(before > 0.0, "(the caret started at the end)")
	k._insert("X")
	eq(k.text, "hello worldX", "typing goes in at the caret")
	k.set_text("")
	k.field.gui_input.emit(_click(40.0))
	eq(k.caret, 0, "empty text: nothing to place")
	k.free()


## Long text: a tap lands on what shows, with the window's ellipsis counted.
func test_tap_in_scrolled_text() -> void:
	var k := _kb()
	k.max_len = 200
	var long := ""
	for i in 12:
		long += "word%02d " % i
	k.set_text(long)
	k.move_caret(-long.length())
	k.move_caret(40)
	var shown_start: int = k._win_start
	var lead: String = "…" if shown_start > 0 else ""
	k.field.gui_input.emit(_click(k._width(lead + long.substr(shown_start, 3)) + 0.5))
	eq(k.caret, shown_start + 3, "the tap maps through the window, not the whole text")
	k.free()


func _click(x: float) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = true
	e.position = Vector2(x, 10)
	return e


## Text longer than the field scrolls: the caret is always in the window.
func test_field_scrolls_with_the_caret() -> void:
	var k := _kb()
	k.max_len = 200
	var long := ""
	for i in 12:
		long += "word%02d " % i
	k.set_text(long)
	ok(k.field.text.begins_with("…") and k.field.text.ends_with("word11 "), "at the end: the end shows")
	ok(k.field.text.length() <= Osk.FIELD_CHARS, "no longer than the field")
	k.move_caret(-long.length())
	ok(k.field.text.begins_with("word00") and k.field.text.ends_with("…"), "caret at the start: the start shows")
	eq(k._caret.position.x, 0.0, "and the caret is at the left edge")
	k.move_caret(40)
	ok(k.field.text.contains("word04"), "moving on, the window follows")
	var x: float = k._caret.position.x
	k.move_caret(1)
	ok(k._caret.position.x > x, "the caret moves with each step")
	k.set_text("short")
	eq(k.field.text, "short", "short text shows whole")
	ok(k._caret.position.x > 0.0, "caret after it")
	k.free()


## Key, focused key, pressed key and the modifier-on states read at AA in
## every theme, Light included; nothing is a fixed colour.
func test_colours_in_every_theme() -> void:
	for id in Themes.ORDER:
		ThemeLib.use(id)
		var t: Dictionary = Themes.get_theme(id)
		var th: Theme = ThemeLib.build()
		var sheet: Color = Themes.over(t["glass"], t["bg"])
		var text: Color = th.get_color("font_color", "KeyButton")
		for st in ["normal", "hover", "pressed"]:
			var sb := th.get_stylebox(st, "KeyButton") as StyleBoxFlat
			var c := Themes.contrast(text, Themes.over(sb.bg_color, sheet))
			ok(c >= 4.5, "%s: %s key %.2f" % [id, st, c])
		var focus := th.get_stylebox("focus", "KeyButton") as StyleBoxFlat
		var fc := Themes.contrast(th.get_color("font_focus_color", "KeyButton"), focus.bg_color)
		ok(fc >= 4.5, "%s: focused key %.2f" % [id, fc])
		ok(Themes.contrast(focus.bg_color, sheet) >= 3.0, "%s: the focused key stands out from the sheet" % id)
		var k := _kb()
		k.press_shift()
		var on := k.shift_button.get_theme_stylebox("normal") as StyleBoxFlat
		ok(on != th.get_stylebox("normal", "KeyButton"), "%s: Shift on has its own fill" % id)
		var oc := Themes.contrast(k.shift_button.get_meta("ink"), on.bg_color)
		ok(oc >= 4.5, "%s: Shift on %.2f" % [id, oc])
		k.press_shift()
		var caps := k.shift_button.get_theme_stylebox("normal") as StyleBoxFlat
		var cc := Themes.contrast(k.shift_button.get_meta("ink"), caps.bg_color)
		ok(cc >= 4.5, "%s: Caps %.2f" % [id, cc])
		ok(caps.bg_color != on.bg_color, "%s: Caps looks different from Shift" % id)
		k.press_shift()
		ok(not k.shift_button.has_theme_stylebox_override("normal"), "%s: off again: the plain key" % id)
		k.toggle_symbols()
		var sym := k.symbols_button.get_theme_stylebox("normal") as StyleBoxFlat
		ok(Themes.contrast(k.symbols_button.get_meta("ink"), sym.bg_color) >= 4.5, "%s: symbols on" % id)
		ok(Themes.contrast(k._caret.color, sheet) >= 3.0, "%s: the caret shows (%.2f)" % [id, Themes.contrast(k._caret.color, sheet)])
		k.set_text("x")
		ok(Themes.contrast(k.field.get_theme_color("font_color"), sheet) >= 4.5, "%s: the field's text" % id)
		k.free()
	ThemeLib.use("cove")


func test_motion_respects_reduce() -> void:
	var was: bool = Motion.reduce
	Motion.reduce = true
	eq(Motion.slide(Osk.SLIDE), 0.0, "no slide under Reduce motion")
	var k := _kb()
	k._pulse(k.keys[1][0])
	eq(k.keys[1][0].scale, Vector2.ONE, "and no key pulse")
	Motion.reduce = was
	ok(Osk.SLIDE > 0.0, "otherwise the sheet rises as it opens")
	eq(k.grow_vertical, Control.GROW_DIRECTION_BEGIN, "pinned by its foot: it grows upward, never off the screen")
	k.free()


## The longer-text keyboard (launch options, collection names) is the same one.
func test_text_keyboard_is_the_same_keyboard() -> void:
	var k: PanelContainer = TextKeyboard.new()
	ok(k.shift_button != null and k.symbols_button != null and k.left_button != null, "Shift, symbols and the caret")
	k.toggle_shift()
	for ch in "dxvk":
		k.type(ch)
	k.toggle_shift()
	k.type("_")
	k.type("x")
	eq(k.text, "DXVK_x", "capitals held on, a symbol, lower case")
	k.set_text("")
	k.max_len = 5
	for ch in "abcdefgh":
		k.type(ch)
	eq(k.text, "abcde", "its limit is max_len")
	k.free()


## Review Medium (input): an on-screen keyboard hidden without close() (its screen went away) went on taking
## every key and button, unseen. It stays open (so its focus is there when the screen is back; closing it
## silently lost the focus, monkey seed 99001) but takes nothing while it is hidden.
func test_a_keyboard_that_is_hidden_stops_taking_input() -> void:
	var k := _kb()
	k._input(_key_event(KEY_A, 65))
	eq(k.text, "a", "open: it types")
	k.visible = false   # its screen went away, no close()
	ok(k.is_open(), "still open")
	k._input(_key_event(KEY_B, 66))
	_pad(k, JOY_BUTTON_Y)
	eq(k.text, "a", "but takes nothing while hidden")
	k.visible = true
	k._input(_key_event(KEY_C, 67))
	eq(k.text, "ac", "and types again when it is back")
	k.free()


## Review Medium: a keyboard still open under the quick menu (Library search, then Quick Access) took the menu's
## buttons: LB / RB moved the caret and B cancelled the search. The menu on top owns the pad.
func test_a_keyboard_under_the_quick_menu_takes_nothing() -> void:
	var k := _kb()
	var menu := Control.new()
	menu.visible = false
	Osk.add_cover(menu)
	k._input(_key_event(KEY_A, 65))
	eq(k.text, "a", "no menu: it types")
	menu.visible = true
	k._input(_key_event(KEY_B, 66))
	_pad(k, JOY_BUTTON_B)
	_pad(k, JOY_BUTTON_LEFT_SHOULDER)
	eq(k.text, "a", "the menu is shown: nothing reaches the keyboard")
	ok(k.is_open(), "it stays open under the menu")
	menu.visible = false
	k._input(_key_event(KEY_C, 67))
	eq(k.text, "ac", "the menu closed: it types again")
	# a keyboard that is part of the menu is not covered by it
	var inner := _kb()
	menu.add_child(inner)
	menu.visible = true
	inner._input(_key_event(KEY_D, 68))
	eq(inner.text, "d", "the menu's own keyboard still types")
	Osk.covers.erase(menu)
	k.free()
	menu.free()


## Review: X held, the quick menu opens, X released: the release went to the menu, so the keyboard never stopped its
## repeat and kept deleting (25 characters down to 9 in 1.5 s).
func test_a_key_held_when_the_quick_menu_opens_stops_repeating() -> void:
	var root: Window = (Engine.get_main_loop() as SceneTree).root
	var host := Control.new()
	root.add_child(host)
	var k: PanelContainer = Osk.new()
	host.add_child(k)
	k.visible = true
	k.showing = true
	k.text = "abcdefghij"
	k.caret = 10
	var menu := Control.new()
	menu.visible = false
	root.add_child(menu)
	Osk.add_cover(menu)
	_pad(k, JOY_BUTTON_X)
	eq(k.text, "abcdefghi", "X deletes one")
	eq(k._repeat_what, "back", "and starts repeating")
	menu.visible = true                            # the quick menu opens; the release goes to it
	k._on_repeat()
	eq(k.text, "abcdefghi", "the repeat deletes nothing under the menu")
	eq(k._repeat_what, "", "and is stopped")
	menu.visible = false
	k._on_repeat()
	eq(k.text, "abcdefghi", "the menu closed with X still down: no repeat comes back")
	# a press while the menu is shown stops one that was running, too
	_pad(k, JOY_BUTTON_X)
	menu.visible = true
	_pad(k, JOY_BUTTON_Y)
	ok(k._repeat_what == "", "an event under the menu clears a held repeat")
	Osk.covers.erase(menu)
	menu.free()
	host.free()


func test_cancel_puts_the_old_text_back_and_done_keeps_the_new() -> void:
	var k := _kb()
	var got := {"changed": [], "closed": []}
	k.text_changed.connect(func(t): got["changed"].append(t))
	k.closed.connect(func(t): got["closed"].append(t))
	k.open("old")
	k.set_text("new")
	k.cancel()
	eq(k.text, "old", "B / Esc: back to what it was")
	eq(got["changed"].back(), "old", "the owner hears the old text first (a live search shows its old list)")
	eq(got["closed"], ["old"], "and closed carries it")
	k.open("old")
	k.set_text("")   # Clear, then B
	k.cancel()
	eq(got["closed"].back(), "old", "Clear then B does not save an empty value")
	k.open("old")
	k.type("x")
	k.close()
	eq(got["closed"].back(), "oldx", "Done keeps it")
	k.free()


func test_cancel_is_told_to_the_owner() -> void:
	var k := _kb()
	k.open("old")
	k.set_text("new")
	k.cancel()
	ok(k.cancelled, "cancelled")
	k.open("old")
	ok(not k.cancelled, "a new session starts clean")
	k.close()
	ok(not k.cancelled, "Done is not a cancel")
	k.free()


func test_a_secret_is_drawn_as_dots_until_shown() -> void:
	var k := _kb()
	k.use_for_codes("API key", 600, true)
	ok(k.show_button.visible, "a Show key beside Paste")
	k.open("abc123")
	eq(k._display(k.text), "••••••", "dots, one per character")
	eq(k.text, "abc123", "the text itself is untouched")
	k.toggle_reveal()
	eq(k._display(k.text), "abc123", "Show reveals it")
	k.close()
	k.open("abc123")
	ok(not k.revealed, "and it is hidden again the next time")
	k.free()


func test_accented_letters_are_on_a_page_of_their_own() -> void:
	var k := _kb()
	k.open("")
	k.toggle_accents()
	ok(k.accents and k.symbols, "the Accents key opens the page (RT then goes back to the letters)")
	eq(_texts([k.keys[0]]), "àáâãäåæç", "the first row")
	k.type("é")
	eq(k.text, "é", "typed")
	k.toggle_shift()
	k.type("é")
	eq(k.text, "éÉ", "and a capital with Shift")
	k.toggle_symbols()
	ok(not k.symbols and not k.accents, "RT: back to the letters")
	k.free()
