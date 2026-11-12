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
