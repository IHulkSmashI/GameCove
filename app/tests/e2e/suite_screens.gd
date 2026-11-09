extends "res://tests/e2e/e2e_case.gd"
## Every top-bar screen with RB and back with LB, then (at the end of the run)
## the app quits cleanly: a job a screen started (the Stream tab's discovery)
## once outlived the engine and crashed GameCove on exit (run.py fails a
## process that doesn't exit 0 or 1).


func test_every_screen_with_rb_and_back() -> void:
	var seen := []
	for i in 5:
		seen.append(main().current)
		await rb()
		await w.frames(3)
	eq(seen, ["home", "library", "discover", "stream", "settings"], "RB walks every screen")
	eq(main().current, "home", "and wraps to Home")
	await lb()
	eq(main().current, "settings", "LB goes back")
	await b()
	eq(main().current, "home", "B goes home")
