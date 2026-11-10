extends "res://tests/e2e/e2e_case.gd"
## The animations in the running app, with real frames: the launch zoom plays
## through and hands off to the game (nothing of ours left animating behind
## it), a launch that ends before the game shows goes back into the art,
## screen changes never block input and survive being interrupted.


func _overlay() -> Control:
	return w.main.launch_overlay


## Tweens the tree is running now.
func _tweens() -> int:
	return w.tree.get_processed_tweens().filter(func(t): return t.is_valid() and t.is_running()).size()


## Play from Home: the zoom starts on the hero card, plays through, and the
## moment the game's window takes the screen it's gone and nothing runs.
func test_launch_zooms_then_hands_off_to_the_game() -> void:
	var m: Control = w.main
	m.home.play_button.grab_focus()
	await w.frames(2)
	var src: Dictionary = m._launch_source(GAME_A) if m.home.spotlight_game.get("key", "") == GAME_A["key"] else {}
	var o := _overlay()
	o.show_for(GAME_A, Color.CYAN, src if not src.is_empty() else {"node": m.home.frame})
	eq(o.phase, "opening", "Play: the zoom starts")
	var start := Rect2(o.card.position, o.card.size)
	ok(start.size.x < o.size.x, "from the hero card, not full screen (%s)" % start)
	await w.wait_s(0.2)
	ok(o.card.size.x > start.size.x, "growing")
	await until(func(): return o.phase == "waiting", 2000)
	eq(o.phase, "waiting", "zoom done in time")
	eq(o.card.size, o.size, "full screen")
	ok(o.center.modulate.a > 0.99, "the logo or title shows")
	ok(o.running_tweens() >= 2, "shimmer and drift while the game starts")
	await start_game(GAME_A)
	ok(not w.main._window_focused, "the game has the screen")
	ok(not o.visible and o.phase == "idle", "the splash is gone")
	eq(o.running_tweens(), 0, "none of its tweens left")
	ok(o._timer.is_stopped(), "launch timeout stopped")
	await w.wait_s(0.6)
	eq(_tweens(), 0, "no tween anywhere in the app behind the game")
	await end_game()


## The game ended before its window showed (crashed, or failed to start):
## the zoom goes back into the art it came from and input works again.
func test_launch_that_ends_early_goes_back() -> void:
	var m: Control = w.main
	var o := _overlay()
	o.show_for(GAME_B, Color.CYAN, {"node": m.home.frame})
	m.playing = GAME_B
	m.session.begin(GAME_B, {"ok": true, "app_id": int(GAME_B["id"]), "pid": 0})
	await w.wait_s(0.6)
	ok(o.is_open(), "waiting for the game")
	m.session.stop()   # it never showed a window
	await w.frames(2)
	eq(o.phase, "closing", "the zoom plays back")
	ok(not o.is_open(), "and doesn't hold input on the way")
	await until(func(): return not o.visible, 2000)
	ok(not o.visible, "then it's gone")
	eq(o.running_tweens(), 0, "nothing left running")
	await w.idle()
	await rb()
	eq(m.current, "library", "input works at once")
	await lb()
