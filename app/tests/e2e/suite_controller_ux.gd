extends "res://tests/e2e/journey_case.gd"
## docs/CONTROLLER-UX.md with a player's hands, where a rule needs the running
## app (the focus walk in tools/layout checks every screen without frames; these
## check what happens over several frames: a sheet that keeps focus, the top
## bar leading into the screen as it is now, a switch that only A changes).


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
