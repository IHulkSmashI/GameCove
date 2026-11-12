extends "res://tests/e2e/e2e_case.gd"
## The on-screen keyboard on the real app, with the pad only: every place that
## opens it (Library search, a Settings key, a game's launch options, the
## wishlist's Steam name, a streaming host) gets a keyboard that's on the
## screen, clear of the field being edited, types what the buttons say, and
## hands the text back.

const Osk := preload("res://scripts/ui/osk.gd")


func _on_screen(k: Control) -> bool:
	var view := Rect2(Vector2.ZERO, w.tree.root.get_visible_rect().size)
	return view.grow(1.0).encloses(k.get_global_rect())


func _hold(button: JoyButton, seconds: float) -> void:
	var e := InputEventJoypadButton.new()
	e.device = 0
	e.button_index = button
	e.pressed = true
	e.pressure = 1.0
	_send(e)
	await w.wait_s(seconds)
	var u := InputEventJoypadButton.new()
	u.device = 0
	u.button_index = button
	u.pressed = false
	_send(u)
	await w.frames(2)


func _pull(axis: JoyAxis) -> void:
	await stick(axis, 1.0)


## Everything the keyboard promises, on the one `k` that's open (text "").
func _drive(k: Control, where: String) -> void:
	ok(k.is_visible_in_tree(), "%s: the keyboard is open" % where)
	await w.wait_s(0.35)      # its slide in
	ok(_on_screen(k), "%s: all of it is on the screen (%s)" % [where, k.get_global_rect()])
	eq(focus(), k.first_key(), "%s: focus starts on Q" % where)
	await a()
	eq(k.text, "q", "%s: A types the focused key" % where)
	await right()
	await a()
	eq(k.text, "qw", "%s: the D-pad moves along the keys" % where)
	# A held direction keeps going and wraps around the row.
	var before: Control = focus()
	await _hold(JOY_BUTTON_DPAD_RIGHT, Osk.REPEAT_DELAY + Osk.REPEAT_RATE * 4.5)
	var row: Array = k.keys[k.keys.size() - 4]
	var moved: int = posmod(row.find(focus()) - row.find(before), row.size())
	ok(moved >= 3, "%s: a held D-pad repeats (%d keys)" % [where, moved])
	await _hold(JOY_BUTTON_DPAD_RIGHT, Osk.REPEAT_DELAY + Osk.REPEAT_RATE * 12.0)
	ok(row.has(focus()), "%s: and wraps around inside the row" % where)
	await up()
	await up()
	ok(k.keys[-1].has(focus()) or (k.keys[0].size() == 1 and focus() == k.keys[0][0]), "%s: up from the top row wraps to the far end" % where)
	# Shift once, Caps twice (L3 / LT), symbols (RT).
	await press(JOY_BUTTON_LEFT_STICK)
	ok(k.shift and not k.caps, "%s: L3 is Shift" % where)
	await _pull(JOY_AXIS_TRIGGER_LEFT)
	ok(k.caps, "%s: LT again is Caps" % where)
	k.first_key().grab_focus()
	await a()
	await a()
	eq(k.text, "qwQQ", "%s: Caps types capitals" % where)
	await _pull(JOY_AXIS_TRIGGER_LEFT)
	ok(not k.shift, "%s: and a third press lets go" % where)
	await _pull(JOY_AXIS_TRIGGER_RIGHT)
	ok(k.symbols, "%s: RT shows the symbols" % where)
	ok(focus() != null and k.is_ancestor_of(focus()), "%s: focus stays on the keys" % where)
	k.keys[k.keys.size() - 5][1].grab_focus()
	await a()
	eq(k.text, "qwQQ@", "%s: a symbol types" % where)
	await _pull(JOY_AXIS_TRIGGER_RIGHT)
	ok(not k.symbols, "%s: RT again: letters" % where)
	# Space, the caret, backspace (held).
	await press(JOY_BUTTON_Y)
	eq(k.text, "qwQQ@ ", "%s: Y is space" % where)
	await lb()
	await lb()
	eq(k.caret, 4, "%s: LB moves the caret left" % where)
	await press(JOY_BUTTON_X)
	eq(k.text, "qwQ@ ", "%s: X deletes before the caret" % where)
	await rb()
	eq(k.caret, 4, "%s: RB moves it right" % where)
	await _hold(JOY_BUTTON_X, Osk.REPEAT_DELAY + Osk.REPEAT_RATE * 6.0)
	eq(k.text, " ", "%s: held X keeps deleting, up to the caret" % where)
	ok(k._repeat.is_stopped(), "%s: nothing repeats once it's let go" % where)
	# A tap or click in the text puts the caret there.
	k.set_text("abcdef")
	await w.frames(2)
	var tap := InputEventMouseButton.new()
	tap.button_index = MOUSE_BUTTON_LEFT
	tap.pressed = true
	tap.position = k.field.get_global_rect().position + Vector2(k._width("abc") + 1.0, 10.0)
	tap.global_position = tap.position
	w.tree.root.push_input(tap, true)    # already in the viewport's own coordinates
	await w.frames(2)
	eq(k.caret, 3, "%s: a click in the text puts the caret there" % where)
	k.set_text("")
	k.first_key().grab_focus()
	for i in 3:
		await a()
	eq(k.text, "qqq", "%s: ready to hand back" % where)


func test_library_search() -> void:
	main().show_screen("library")
	await w.frames(4)
	var lib: Control = main().library_screen
	lib.search_button.grab_focus()
	await press(JOY_BUTTON_Y)
	var k: Control = lib.keyboard
	ok(lib.searching(), "Y opens search")
	lib.set_query("")
	k.set_text("", false)
	await _drive(k, "search")
	ok(not k.get_global_rect().intersects(lib.search_button.get_global_rect()), "the search box stays in view above the keyboard")
	eq(lib.query, "qqq", "the grid filters as you type")
	eq(k.max_len, Osk.MAX_LEN, "search keeps its short limit")
	await press(JOY_BUTTON_START)
	await w.wait_s(0.3)
	ok(not lib.searching(), "Menu (Start) is Done")
	lib.set_query("")
	main().show_screen("home")
	await w.frames(3)


func test_settings_key() -> void:
	main().show_screen("settings")
	await w.frames(4)
	var s: Control = main().settings
	var got: Array = []
	s.ask_text("Paste your key", "", func(t): got.append(t))
	await w.frames(2)
	var k: Control = s.keyboard
	ok(k.paste_button.is_visible_in_tree(), "a key can be pasted")
	k.read_clipboard = func() -> String: return "ABC-123"
	await _drive(k, "settings key")
	k.keys[0][0].grab_focus()
	await a()
	eq(k.text, "qqqABC-123", "A on Paste puts the clipboard at the caret, case kept")
	await press(JOY_BUTTON_START)
	await w.wait_s(0.3)
	eq(got, ["qqqABC-123"], "Menu (Done) closes and hands the text back")
	ok(not k.visible, "closed")
	# B cancels: nothing typed is kept, and the owner is not called (a key would be saved and checked)
	s.ask_text("Paste your key", "", func(t): got.append(t))
	await w.frames(2)
	k.set_text("typed")
	await b()
	await w.wait_s(0.3)
	eq(got, ["qqqABC-123"], "B cancels: the callback is not called")
	ok(not k.visible, "and it is closed")
	main().show_screen("home")
	await w.frames(3)


func test_launch_options() -> void:
	var acts: Node = main().game_actions
	var got: Array = []
	acts.open_keyboard("Launch options", "What Steam runs the game with.", "", func(t): got.append(t))
	await w.frames(3)
	var k: Control = acts.keyboard
	ok(acts.is_modal(), "the keyboard is a modal")
	await _drive(k, "launch options")
	var head: Control = k.find_child("Head", true, false)
	ok(head != null and head.is_visible_in_tree() and _on_screen(head), "what's being asked shows above the field")
	ok(k.keep_case and k.max_len >= 200, "long text, case kept")
	await press(JOY_BUTTON_START)
	await w.wait_s(0.3)
	eq(got, ["qqq"], "Done hands the text back")
	ok(not acts.is_modal(), "closed")


func test_wishlist_name() -> void:
	main().show_screen("discover")
	await w.frames(6)
	var root: Control = main().discover.content
	if root == null or not root.has_method("show_section"):
		ok(false, "Discover should have its content in the e2e world")
		main().show_screen("home")
		return
	root.show_section("wishlist", false)
	await w.frames(4)
	var wl: Control = root.sections["wishlist"]
	wl.open_import()
	await w.frames(4)
	wl._set_typed("")
	wl._open_keyboard()
	await w.frames(3)
	var k: Control = wl.keyboard
	k.set_text("", false)
	await _drive(k, "wishlist name")
	ok(not k.get_global_rect().intersects(wl.import_field.get_global_rect()), "the name being typed stays in view above the keyboard")
	eq(wl._typed, "qqq", "the field follows the typing")
	await press(JOY_BUTTON_START)
	await w.wait_s(0.3)
	ok(not k.visible, "Done closes it")
	wl.close_import()
	await w.frames(3)
	main().show_screen("home")
	await w.frames(3)


## Review: Library, Menu on a game (or the filter sheet), Guide left the sheet up over Home with focus behind it, and A
## started Home's game. The game sheet, its text keyboard and the status panel go with the screen like Stream's.
func test_game_sheets_and_the_status_panel_go_with_the_screen() -> void:
	for kind in ["sheet", "keyboard", "status"]:
		main().show_screen("library")
		await w.wait_s(0.3)
		match kind:
			"sheet": main().game_actions.open_menu("Game", "sub", [{"id": "x", "text": "Do it"}], func(_id): pass)
			"keyboard": main().game_actions.open_keyboard("Name", "detail", "abc", func(_t): pass)
			"status": main()._open_status()
		await w.frames(3)
		ok(main().game_actions.is_modal() or main().status_panel.visible, "%s is open over Library" % kind)
		await guide()
		await w.wait_s(0.4)
		eq(main().current, "home", "%s: Guide went Home" % kind)
		ok(not main().game_actions.is_modal(), "%s: the game sheet / keyboard went with the Library screen" % kind)
		ok(not main().status_panel.visible, "%s: and the status panel" % kind)
		ok(w.ui_clean(), "%s: nothing modal is left over Home" % kind)
		var f := focus()
		ok(f != null and main().home.is_ancestor_of(f), "%s: Home has the focus, not something behind a sheet" % kind)
	main().show_screen("home")
	await w.frames(3)


## Monkey seed 115001 (step 61): Guide left Stream for Home, and a Y within the screen's fade-out opened Stream's add-a-PC
## keyboard: a screen still fading is shown, so it kept its own buttons. The next B closed that keyboard over Home and
## sent the focus into the hidden screen: "nothing has focus". A screen that has been left takes no input at all.
func test_a_screen_that_was_just_left_takes_no_buttons() -> void:
	main().show_screen("stream")
	await w.frames(4)
	var sc: Control = main().stream_screen
	if sc.keyboard == null:
		sc._make_modals()
	main().show_screen("home")
	await press(JOY_BUTTON_Y)   # the same instant: Stream is still fading out
	await w.frames(2)
	ok(not sc.modal_open(), "Y on Home does not open Stream's keyboard behind it")
	main().show_screen("stream")
	await w.wait_s(0.4)
	await press(JOY_BUTTON_Y)
	await w.frames(2)
	ok(sc.modal_open(), "and once Stream is the screen again its Y works")
	await press(JOY_BUTTON_B)
	await w.wait_s(0.3)
	main().show_screen("home")
	await w.frames(3)


func test_streaming_host() -> void:
	main().show_screen("stream")
	await w.frames(4)
	var sc: Control = main().stream_screen
	if sc.keyboard == null:
		sc._make_modals()
	sc.open_add()
	await w.frames(3)
	var k: Control = sc.keyboard
	await _drive(k, "streaming host")
	await press(JOY_BUTTON_B)
	await w.wait_s(0.3)
	ok(not k.visible, "B closes it")
	main().show_screen("home")
	await w.frames(3)


## Monkey seed 104004: Stream's keyboard and sheets live in main's modal layer, not under the screen, so
## leaving by Guide to Home left them up: the next B closed a hidden dialog and nothing had focus.
func test_streaming_dialogs_go_with_the_screen() -> void:
	main().show_screen("stream")
	await w.frames(4)
	var sc: Control = main().stream_screen
	if sc.keyboard == null:
		sc._make_modals()
	sc.open_add()
	await w.frames(3)
	ok(sc.modal_open(), "Y opened the Add PC keyboard")
	await guide()
	await w.wait_s(0.4)
	eq(main().current, "home", "Guide went Home")
	ok(not sc.modal_open(), "the Add PC keyboard went with the Stream screen")
	ok(not sc.keyboard.showing, "and it is not showing")
	ok(w.ui_clean(), "nothing modal is left over Home")
	await b()
	await w.frames(3)
	ok(focus() != null, "B on Home leaves something focused")
	for kind in ["more", "settings", "pair"]:
		main().show_screen("stream")
		await w.frames(4)
		match kind:
			"more": sc.more_sheet.open("PC", "1.2.3.4", [{"id": "refresh", "text": "Check again"}])
			"settings": sc.settings_sheet.open(sc.service, "x", {})
			"pair": sc.pair_sheet.open_waiting("PC", "1234", "")
		await w.frames(2)
		main().show_screen("library")
		await w.wait_s(0.3)
		ok(not sc.modal_open(), "%s sheet is put away when the tab changes" % kind)
		ok(w.ui_clean(), "%s: nothing modal is left over Library" % kind)
	main().show_screen("home")
	await w.frames(3)
