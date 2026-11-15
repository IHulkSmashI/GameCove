extends "res://tests/e2e/journey_case.gd"
## docs/CONTROLLER-UX.md with a player's hands, where a rule needs the running
## app (the focus walk in tools/layout checks every screen without frames; these
## check what happens over several frames: a sheet that keeps focus, the top
## bar leading into the screen as it is now, a switch that only A changes).


## CUX-6: up from a Settings sheet's first control went into the top bar behind
## the dim. The sheet keeps focus until it closes; B closes it.
func test_a_settings_sheet_keeps_focus_until_it_closes() -> void:
	ok(await open_settings("about"), "Settings > About with the pad")
	var s: Control = main().settings
	s.open_credits()
	await w.frames(4)
	ok(s.sheet.visible, "the credits sheet is open")
	var inside := func() -> bool: return focus() != null and s.sheet.is_ancestor_of(focus())
	if not inside.call():
		await nav_to(func(): return s.sheet.find_children("*", "Button", true, false).filter(func(b): return b.is_visible_in_tree())[0], 6)
	ok(inside.call(), "focus is in the sheet (%s)" % where())
	for p in ["up", "up", "left", "up", "right", "down", "down", "down"]:
		await call(p)
		ok(inside.call(), "after %s, focus is still in the sheet (%s)" % [p, where()])
	await b()
	await w.frames(3)
	ok(not s.sheet.visible, "B closes it")
	ok(focus() != null and not s.sheet.is_ancestor_of(focus()), "and focus is back on the page")


## CUX-5: down from the top bar goes into the screen as it is now: in Settings,
## the category that is open, not the one Settings opened on.
func test_down_from_the_top_bar_lands_on_the_open_category() -> void:
	ok(await open_settings("display"), "Settings > Display with the pad")
	var s: Control = main().settings
	# up out of the page (not through the category list, which would open each category on the way)
	var bar: Control = main().top_bar
	for i in 30:
		if focus() != null and bar.is_ancestor_of(focus()):
			break
		await up()
		await w.frames(1)
	ok(focus() != null and bar.is_ancestor_of(focus()), "up from the page reaches the top bar (%s)" % where())
	eq(s.category, "display", "Display is still the open category")
	await down()
	await w.frames(2)
	eq(focus(), s.cat_buttons["display"], "down from the bar: the open category (Display)")
	eq(s.category, "display", "and Display stays open")


## CUX-3: a switch row changes on A only; left / right leave it as it is.
func test_a_switch_changes_on_a_and_not_on_left_or_right() -> void:
	ok(await open_settings("appearance"), "Settings > Appearance with the pad")
	var s: Control = main().settings
	var row: Control = s.rows.get("reduce_motion")
	if row == null:
		ok(false, "Appearance has its Reduce motion switch")
		return
	ok(await nav_to(row.button, 20), "D-pad to Reduce motion")
	var before: Variant = row.value()
	await right()
	await w.frames(2)
	eq(s.rows["reduce_motion"].value(), before, "right leaves the switch as it is")
	await nav_to(s.rows["reduce_motion"].button, 6)
	await a()
	await w.frames(2)
	ok(s.rows["reduce_motion"].value() != before, "A flips it")
	await a()
	await w.frames(2)
	eq(s.rows["reduce_motion"].value(), before, "A again puts it back")


## CUX-6: the Steam hand-off panel keeps focus while it is up, and gives it back
## when it closes. It fades out, so it is still drawn for a moment after closing:
## focus it took back then went away with it and nothing was focused.
func test_the_steam_hand_off_panel_gives_focus_back_when_it_closes() -> void:
	ok(await go_tab("library"), "Library with the pad")
	await w.frames(3)
	var o: Control = main().steam_overlay
	main()._on_external_window("", "steam", "install")
	await w.frames(4)
	ok(o.is_open() and focus() != null and o.is_ancestor_of(focus()), "the panel is up and has focus (%s)" % where())
	for p in ["up", "left", "down", "right"]:
		await call(p)
		ok(focus() != null and o.is_ancestor_of(focus()), "after %s, focus is still in the panel (%s)" % [p, where()])
	await b()   # the way a player leaves it: B closes it and takes the screen back from Steam
	await w.wait_s(0.6)   # its fade is over
	ok(not o.visible, "the panel is gone")
	ok(focus() != null and focus().is_visible_in_tree() and not o.is_ancestor_of(focus()),
		"and something on the screen has focus (%s)" % where())
	eq(focus_on_screen(), "", "which is on screen")


## CUX-6: B on a game's options sheet after the tile it came from was rebuilt (a
## favourite toggled re-deals Home's shelves; monkey seed 121003): focus stayed on
## a row of the closed sheet and the next press left nothing focused.
func test_b_on_a_sheet_whose_tile_is_gone_puts_focus_on_the_screen() -> void:
	await with_stores()
	ok(await go_tab("home"), "Home with the pad")
	await w.frames(4)
	var home: Control = main().screens["home"]
	var tile: Control = null
	for i in 12:
		if focus() != null and "game" in focus() and focus().get("game") is Dictionary and not (focus().get("game") as Dictionary).is_empty() \
				and focus().get_script() != null and str(focus().get_script().resource_path).ends_with("game_tile.gd"):
			tile = focus()
			break
		await down()
		await w.frames(2)
	if tile == null:
		ok(false, "Home has a game tile the D-pad reaches (%s)" % where())
		await without_stores()
		return
	await start_btn()
	await w.frames(4)
	ok(sheet_open(), "Start opens the game's options")
	# the shelves are dealt again under the sheet, as after a favourite or an install
	home.set_games(w.autoload("Library").games)
	await w.frames(4)
	ok(not is_instance_valid(tile) or not tile.is_visible_in_tree(), "the tile the sheet came from is gone")
	await b()
	await w.wait_s(0.5)
	ok(not sheet_open(), "B closes the sheet")
	ok(focus() != null and focus().is_visible_in_tree() and not sheet().is_ancestor_of(focus()),
		"and focus is on the screen, not on a row of the closed sheet (%s)" % where())
	await b()
	await w.frames(3)
	ok(focus() != null and focus().is_visible_in_tree(), "another B still leaves something focused (%s)" % where())
	await without_stores()


## CUX-6: the quick menu opened and closed over a Settings sheet (Profiles: a
## layer's actions) leaves something focused, whatever is pressed next. These are
## the presses monkey seed 128004 ended on with nothing focused (Legion, once in
## CI; they replay clean here, so this holds the sequence rather than a fix).
func test_the_quick_menu_over_a_settings_sheet_leaves_focus_somewhere() -> void:
	ok(await open_settings("profiles"), "Settings > Profiles with the pad")
	await w.frames(3)
	await a()
	await w.frames(5)
	var row: Control = focus()
	if row == null or not String(row.name).begins_with("Row_"):
		ok(false, "A on the first profile row opens its actions (%s)" % where())
		return
	await view_btn()
	await w.frames(3)
	await left()
	await w.frames(3)
	await x()
	await w.frames(5)
	if not qm().visible:
		await qam()
		await w.frames(5)
	ok(qm().visible, "Quick Access opens the quick menu over the sheet")
	await qam()
	await w.wait_s(0.5)
	ok(not qm().visible, "and closes it")
	ok(focus() != null and focus().is_visible_in_tree(), "something visible has focus after the menu (%s)" % where())
	for p in ["left", "up", "down", "right"]:
		await call(p)
		await w.frames(2)
		ok(focus() != null and focus().is_visible_in_tree(), "after %s something visible still has focus (%s)" % [p, where()])
	eq(focus_on_screen(), "", "and it is on screen")
	await b()
	await w.frames(4)


## The Library shows two whole rows of covers on the smallest layout (1280x800). The 48 px touch
## targets made the bars above the grid taller and left it 5 px short: one row, and an empty band.
func test_the_library_shows_two_rows_of_covers_on_the_smallest_screen() -> void:
	await with_stores()
	ok(await go_tab("library"), "Library with the pad")
	await w.frames(6)
	var lib: Control = main().screens["library"]
	var view: Vector2 = w.tree.root.get_visible_rect().size
	# what the bars around the grid take is the same on every height: on an 800 px screen the grid gets the rest
	var chrome: float = view.y - lib._area.size.y
	var pitch: float = lib.tile_size.y + lib.GAP.y
	var two_rows: float = 2.0 * pitch + 2.0 * lib.PAD.y - lib.GAP.y
	if view.x > 1281.0:
		print("E2E NOTE library rows: a wider layout than 1280 (%s): covers are another size" % view)
	else:
		ok(800.0 - chrome >= two_rows, "two rows of covers (%d px) fit under the bars of a 1280x800 screen (the bars take %d px, leaving %d)" % [int(two_rows), int(chrome), int(800.0 - chrome)])
	await without_stores()


## CUX-10: the hint bar names what the focused control does. A plain row that opens something
## ("Open on SteamDB" on the game page) said "left / right: Change", as if it were a stepper.
func test_the_hint_for_a_row_says_what_it_really_does() -> void:
	var ChoiceRow: Script = load("res://scripts/ui/choice_row.gd")
	var host := VBoxContainer.new()
	w.tree.root.add_child(host)
	var link := Button.new()
	link.theme_type_variation = "RowButton"
	host.add_child(link)
	eq(main().focus_kind(link), "button", "a row that opens something: A")
	eq(main().hints_for({"kind": main().focus_kind(link), "page": true})[0], ["A", "Select"], "and the bar says A")
	var strip := Button.new()
	strip.theme_type_variation = "RowButton"
	strip.set_meta("ux_stepper", true)
	host.add_child(strip)
	eq(main().focus_kind(strip), "row", "a strip that says left / right are its value: left / right")
	var stepper: VBoxContainer = ChoiceRow.new()
	stepper.setup("s", "S", [1, 2, 3, 4, 5], ["1", "2", "3", "4", "5"], 1)
	host.add_child(stepper)
	eq(main().focus_kind(stepper.button), "row", "a stepper: left / right")
	var toggle: VBoxContainer = ChoiceRow.bool_row("t", "T", false)
	host.add_child(toggle)
	eq(main().focus_kind(toggle.button), "toggle", "a switch: A changes it")
	host.queue_free()
	await w.frames(2)


## CUX-7: read-only cards on the device pages take no focus; the right stick
## scrolls them into view, and only while it is pushed.
func test_read_only_device_cards_take_no_focus_and_the_right_stick_scrolls() -> void:
	ok(await open_settings("device"), "Settings > Device with the pad")
	var s: Control = main().settings
	var page: Control = s.pages.get("device")
	if page == null:
		ok(false, "Settings has its Device page")
		return
	var FocusCard: Script = load("res://scripts/ui/device/device_kit.gd").FocusCard
	var panel: Control = null
	for id in page.tabs:
		page.select_part(id)
		await w.frames(6)
		var p: Control = page.panels.get(id)
		if p == null:
			continue
		for c in p.find_children("*", "PanelContainer", true, false):
			if is_instance_of(c, FocusCard) and c.action_text == "":
				eq(c.focus_mode, Control.FOCUS_NONE, "%s: the read-only card %s takes no focus" % [id, c.name])
		for f in p.focus_chain():
			ok(f.focus_mode == Control.FOCUS_ALL, "%s: every stop of its focus chain takes focus (%s)" % [id, f.name])
		if panel == null and p.has_method("can_stick_scroll") and p.can_stick_scroll():
			panel = p
			break
	if panel == null:
		ok(false, "a device page has more cards than the screen shows")
		return
	page.tabs[page.part].grab_focus()
	await w.frames(2)
	var sc: ScrollContainer = panel._stick_scroller
	sc.scroll_vertical = 0
	ok(["RS", load("res://scripts/ui/texts_device.gd").HINT_SCROLL] in panel.scroll_hints(), "the hint bar can name the right stick")
	eq(panel.is_processing(), false, "nothing ticks while the stick rests")
	var push := InputEventJoypadMotion.new()
	push.device = 0
	push.axis = JOY_AXIS_RIGHT_Y
	push.axis_value = 1.0
	_send(push)
	await w.frames(12)
	var down_px := sc.scroll_vertical
	ok(down_px > 0, "the right stick pushed down scrolls the cards (%d px)" % down_px)
	eq(focus(), page.tabs[page.part], "and focus stays where it was")
	var rest := InputEventJoypadMotion.new()
	rest.device = 0
	rest.axis = JOY_AXIS_RIGHT_Y
	rest.axis_value = 0.0
	_send(rest)
	await w.frames(3)
	eq(panel.is_processing(), false, "let go: nothing ticks")
	var at := sc.scroll_vertical
	await w.frames(6)
	eq(sc.scroll_vertical, at, "and the page stays put")
	push.axis_value = -1.0
	_send(push)
	await w.frames(12)
	ok(sc.scroll_vertical < at, "pushed up, it scrolls back")
	_send(rest)
	await w.frames(2)
	# the quick menu over the page: the stick isn't the page's
	sc.scroll_vertical = 0
	await qam()
	await w.frames(4)
	if qm().visible:
		push.axis_value = 1.0
		_send(push)
		await w.frames(8)
		eq(sc.scroll_vertical, 0, "with the quick menu open the page under it doesn't scroll")
		_send(rest)
		await qam()
		await w.frames(4)


## CUX-5: "up" and "down" asked at the press (Kit.lead_up / lead_down) go where
## the screen says now, both on one control.
func test_up_and_down_asked_at_the_press() -> void:
	var Kit: Script = load("res://scripts/ui/ui_kit.gd")
	var host := Control.new()
	host.name = "LeadTest"
	w.tree.root.add_child(host)
	var made: Array = []
	for n in ["A", "B", "C"]:
		var btn := Button.new()
		btn.name = n
		btn.focus_mode = Control.FOCUS_ALL
		btn.position = Vector2(40, 40)   # one on top of the other: where they sit says nothing
		btn.size = Vector2(120, 48)
		host.add_child(btn)
		made.append(btn)
	var to := [made[1]]
	Kit.lead_up([made[0]], func(): return to[0])
	Kit.lead_down([made[0]], func(): return made[2])
	made[0].grab_focus()
	await up()
	eq(focus(), made[1], "up goes where the screen says now")
	to[0] = made[2]
	made[0].grab_focus()
	await up()
	eq(focus(), made[2], "and follows when that changes")
	made[0].grab_focus()
	await down()
	eq(focus(), made[2], "down has its own target")
	host.queue_free()
	await w.frames(2)
	await go_tab("home")

