extends "res://tests/e2e/journey_case.gd"
## Random journeys ("monkey"): a player's hands mashing everything with the
## player's games on the handheld (stores_world.gd), seedable and replayable.
## After every step the invariants hold (journey_case.gd invariants(): the
## safety checks of checks.gd, focus visible and on screen); and every few steps
## no script error has happened, the settings files still parse, the screen
## isn't stuck (B and Guide always get back to Home or the game), and the quick
## menu opens within its budget.
##
## CI: E2E_ITERS runs (run.py default 5) of STEPS steps; soak: E2E_SOAK=1 (200).
## Replay a failure: run.py --suites monkey --seed <seed printed> --iters 1.

## Steps per run.
const STEPS := 70
const SetupFlow := preload("res://scripts/ui/setup/setup_flow.gd")
## What the quick menu may take to open, even on a heavily loaded test machine
## (suite_perf has the real, tight budgets; this only catches a menu that hangs).
const QM_BUDGET_MS := 3000
## Weighted moves: navigation most, then the face buttons, then everything else.
const MOVES := ["up", "down", "left", "right", "up", "down", "left", "right", "a", "a", "b", "b",
	"x", "y", "lb", "rb", "lt", "rt", "start", "view", "guide", "qam", "key", "tap", "hold_b", "play"]


func iters() -> int:
	return maxi(1, OS.get_environment("E2E_ITERS").to_int())


func seed0() -> int:
	var s := OS.get_environment("E2E_SEED").to_int()
	return s if s != 0 else 1


func test_monkey_journeys_hold_the_invariants() -> void:
	await with_stores()
	stores.set_speed(0.05)
	for run in iters():
		if await journey(seed0() * 1000 + run):
			break
	await without_stores()


## Seeds that once broke an invariant, kept for good.
## 3987000: Library search open, Guide to Home, the quick menu opens, B: the hidden Library
## keyboard took the B (and sent focus to the hidden Library): "nothing has focus" on Home.
func test_seed_3987000_hidden_library_keyboard_takes_no_input() -> void:
	await with_stores()
	stores.set_speed(0.05)
	await journey(3987000)
	await without_stores()


## One journey of STEPS moves from `seed`; true when an invariant broke (reported through ok()).
func journey(seed: int) -> bool:
	print("E2E SEED suite_monkey::journey %d" % seed)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var trail: Array = []
	var states: Array = []
	var broke := false
	for step in STEPS:
		var move: String = MOVES[rng.randi() % MOVES.size()]
		trail.append(move)
		var fp := str(focus().get_path()).get_file() if focus() else "none"
		states.append("%s@%s[%s%s]" % [move, where(), fp, " qm" if qm().visible else ""])
		await do_move(move, rng)
		await w.frames(3)   # a menu closing hands focus back over a frame or two
		await w.frames(2)
		# the screen settles (a page glides to the focused row, a sheet fades in)
		await until(func(): return focus_on_screen() == "" or not main()._window_focused or main().launch_overlay.is_open(), 1000)
		var probs := invariants("seed %d step %d (%s)" % [seed, step, move])
		if not probs.is_empty():
			# a hardware file read while the fake system's worker rewrote it reads
			# empty (-1): look again once the workers are quiet; only what stays counts
			await w.idle()
			probs = invariants("seed %d step %d (%s)" % [seed, step, move])
		if step % 10 == 9:
			probs.append_array(await deep_checks("seed %d step %d" % [seed, step]))
		if not probs.is_empty():
			for p in probs:
				ok(false, p)
			var df: Control = main()._screen_default_focus()
			ok(false, "seed %d: before each of the last moves: %s" % [seed, states.slice(maxi(0, states.size() - 6))])
			ok(false, "seed %d: the last moves were %s; on %s, searching %s, sheet %s, keyboard %s, default focus %s (shown %s), quick menu %s, page %s, in settings page %s" % [seed, trail.slice(maxi(0, trail.size() - 12)),
				where(), main().library_screen.searching(), main().game_actions.is_modal(), main().game_actions._kb_open,
				df.get_path() if df != null and is_instance_valid(df) and df.is_inside_tree() else str(df), df.is_visible_in_tree() if df != null and is_instance_valid(df) and df.is_inside_tree() else false,
				qm().visible, main().settings.category, main().settings.in_page()])
			var st2: Control = main().settings
			ok(false, "seed %d: settings focus %s, top bar %s, settings sheet %s, keyboard %s; grab -> %s" % [seed, st2.focus_behavior_recursive, main().top_bar.focus_behavior_recursive,
				st2.sheet != null and st2.sheet.visible, st2.keyboard != null and st2.keyboard.is_open(), _try_grab(df)])
			broke = true
			break
	await calm_down()
	return broke


## One move of the player's hands.
func do_move(move: String, rng: RandomNumberGenerator) -> void:
	match move:
		"up": await up()
		"down": await down()
		"left": await left()
		"right": await right()
		"a": await a()
		"b": await b()
		"x": await x()
		"y": await y()
		"lb": await lb()
		"rb": await rb()
		"lt": await lt()
		"rt": await rt()
		"start": await start_btn()
		"view": await view_btn()
		"guide": await guide()
		"qam": await qam()
		"hold_b": await hold(JOY_BUTTON_B, 600)
		"key":
			var keys := [KEY_UP, KEY_DOWN, KEY_ENTER, KEY_ESCAPE, KEY_A, KEY_E, KEY_Q, KEY_BACKSPACE]
			var k: Key = keys[rng.randi() % keys.size()]
			await key(k, 97 if k == KEY_A else 0)
		"tap":
			var size: Vector2 = w.tree.root.get_visible_rect().size
			await tap(Vector2(rng.randf_range(0.0, size.x), rng.randf_range(0.0, size.y)))
		"play":
			# now and then a game quits by itself (the player closed it from inside)
			if main().session.is_active():
				stores.game_quit(str(main().session.game.get("id", "")))
	await w.frames(1)


## Every few steps: script errors, settings files, a way home, the quick menu's budget.
func deep_checks(where_: String) -> Array[String]:
	var out: Array[String] = []
	var errs: Array[Dictionary] = []
	if "errors" in w.tree and w.tree.errors != null:
		errs = w.tree.errors.take()
	for e in Checks.drop_noise(errs):
		out.append("%s: %s" % [where_, e.get("text", e)])
	var bad := settings_files_valid()
	if bad != "":
		out.append("%s: settings files that don't parse: %s" % [where_, bad])
	# the monkey asked for another session (Switch to Desktop / Steam pressed twice):
	# GameCove lets the controller go and waits to be replaced; the fake switch
	# never comes, so the wait ends the way it does when a switch doesn't happen
	var sessions: Array = w.fake.events.filter(func(e): return str(e) in ["desktop", "steam", "plasma", "gamescope", "gnome"])
	if not sessions.is_empty() and qm().has_method("switch_timed_out"):
		qm().switch_timed_out(qm()._switch_gen)
		w.fake.events.clear()
		await w.idle()
	# what the last presses started lands first (Y in the quick menu opens its
	# Settings page once the menu has closed)
	await w.wait_s(0.5)
	await w.idle()
	# never stuck: B a few times and Guide get home (or back to the game)
	var game_on: bool = main().session.is_active()
	if not game_on and not main()._window_focused:
		main().notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	for i in 5:
		if qm().visible or main().page != null or main()._downloads_open() or main()._apps_open() or main().game_actions.is_modal() \
				or main().steam_overlay.is_open() or main().settings.in_page():
			await b()
			await w.frames(3)
	await w.frames(4)
	var heard := []
	if not game_on and main().current != "home":
		var cb := func(a): heard.append([a, main().current])
		w.autoload("Controller").ui_action.connect(cb)
		await guide()
		await until(func(): return main().current == "home", 2000)
		w.autoload("Controller").ui_action.disconnect(cb)
	var home_or_game: bool = main().current == "home" or main().session.is_active()
	if not home_or_game:
		var st: Control = main().settings
		out.append("%s: stuck: B and Guide didn't get home (on %s; keep dialog %s, settings sheet %s, settings keyboard %s, setup %s, focus %s, events %s, intercepting %s, qm %s, heard %s)" % [where_, where(),
			main().find_child("KeepDialog", true, false) != null, st.sheet != null and st.sheet.visible, st.keyboard != null and st.keyboard.is_open(),
			SetupFlow.instance != null and is_instance_valid(SetupFlow.instance), focus().get_path() if focus() else "none",
			w.fake.events, w.autoload("Controller")._intercepting, qm().visible, heard])
	# the quick menu opens within its budget
	if not qm().visible:
		var t0 := Time.get_ticks_msec()
		await qam()
		var ms := Time.get_ticks_msec() - t0
		if not qm().visible:
			out.append("%s: the quick menu didn't open" % where_)
		elif ms > QM_BUDGET_MS:
			out.append("%s: the quick menu took %d ms to open" % [where_, ms])
		await b()
		await w.frames(3)
	return out


## Between runs: put away what the run left open, end a game, settle.
func calm_down() -> void:
	if qm().visible:
		qm().close()
	if main().session.is_active():
		stores.game_quit(str(main().session.game.get("id", "")))
		await until(func(): return not main().session.is_active(), 12000)
	for i in 6:
		if main().game_actions.is_modal() or main().page != null or main()._downloads_open() or main()._apps_open() or main().steam_overlay.is_open():
			await b()
			await w.frames(3)
	main().show_screen("home")
	await w.wait_s(0.4)
	await w.idle()


func _try_grab(c: Control) -> String:
	if c == null or not is_instance_valid(c):
		return "none"
	c.grab_focus()
	return str(focus() == c)
