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


func _visible_screens() -> Array:
	var m: Control = w.main
	return m.SCREENS.filter(func(id): return m.screens[id].visible)


## RB slides the next screen in from the right, LB from the left, and the
## new screen has focus while it's still moving.
func test_screen_changes_follow_the_press_and_never_block_input() -> void:
	var m: Control = w.main
	var mot = load("res://scripts/ui/motion.gd")
	mot.reduce = false
	await rb()
	var lib: Control = m.screens["library"]
	eq(m.current, "library", "RB: Library")
	ok(lib.position.x > 0.0 and lib.modulate.a < 1.0, "slides in from the right (x %.1f, a %.2f)" % [lib.position.x, lib.modulate.a])
	ok(m.screens["home"].visible, "Home still fading out under it")
	await w.frames(2)
	var f: Control = focus()
	ok(f != null and (lib.is_ancestor_of(f) or m.top_bar.is_ancestor_of(f)), "focus already on Library (%s)" % [f.get_path() if f != null else "none"])
	await w.wait_s(0.4)
	eq(lib.position.x, 0.0, "in place")
	eq(lib.modulate.a, 1.0, "fully shown")
	eq(_visible_screens(), ["library"], "Home hidden once it faded")
	eq(m.screens["home"].position.x, 0.0, "and put back in place")
	# Wrap-around: LB from Home goes to Settings, sliding in from the left.
	await lb()
	await lb()
	eq(m.current, "settings", "LB twice: Settings (wrapped)")
	ok(m.screens["settings"].position.x < 0.0, "came from the left, the way LB points")
	await w.wait_s(0.4)
	await rb()
	eq(m.current, "home", "RB from Settings: Home")
	ok(m.screens["home"].position.x > 0.0, "from the right, though Home is first in the row")
	await w.wait_s(0.4)


## Pressing through screens faster than they animate leaves exactly the last
## one showing, in place, with focus in it.
func test_interrupted_screen_changes_settle_cleanly() -> void:
	var m: Control = w.main
	for i in 3:
		await rb()
	await lb()
	await rb()
	await rb()
	await lb()
	eq(m.current, "stream", "the presses all counted (3 right, 1 left, 2 right, 1 left)")
	await w.wait_s(0.5)
	eq(_visible_screens(), ["stream"], "only Stream shows")
	for id in m.SCREENS:
		eq(m.screens[id].position.x, 0.0, "%s back in place" % id)
	eq(m.screens["stream"].modulate.a, 1.0, "Stream fully shown")
	var f: Control = focus()
	ok(f != null and (m.screens["stream"].is_ancestor_of(f) or m.top_bar.is_ancestor_of(f)), "focus on Stream")
	await b()
	await w.wait_s(0.4)
	eq(_visible_screens(), ["home"], "B: home")


## Reduce motion: tabs switch at once, nothing animates.
func test_screen_changes_under_reduce_motion_are_instant() -> void:
	var m: Control = w.main
	var mot = load("res://scripts/ui/motion.gd")
	mot.reduce = true
	await rb()
	eq(m.screens["library"].position.x, 0.0, "no slide")
	eq(m.screens["library"].modulate.a, 1.0, "no fade")
	eq(_visible_screens(), ["library"], "Home gone at once")
	await b()
	mot.reduce = false


## The game page rises in over the screen; closing it lands focus back on the tile.
func test_game_page_opens_and_closes_smoothly() -> void:
	var m: Control = w.main
	await w.idle()
	var tiles: Array = m.home.shelves()[0].tiles if not m.home.shelves().is_empty() else []
	if tiles.is_empty():
		ok(true, "no shelves on this setup")
		return
	tiles[0].grab_focus()
	await w.frames(2)
	await a()
	ok(m.page != null, "A on a tile: the game page")
	ok(m.page.position.y > 0.0 and m.page.modulate.a < 1.0, "rising in")
	await w.wait_s(0.4)
	eq(m.page.position.y, 0.0, "in place")
	await b()
	ok(m.page == null, "B closes it at once")
	eq(focus(), tiles[0], "focus back on the tile")
	await w.wait_s(0.4)
	eq(m.home.scale, Vector2.ONE, "Home settled back")
	eq(m.home.modulate.a, 1.0, "fully shown")


## Toasts slide in from the right and settle; their timers and tweens end.
func test_toast_slides_in_and_settles() -> void:
	var m: Control = w.main
	var p: Control = m.toasts.show_toast("Paper Lanterns is 60% off", "tag", "sale", "Wishlist price drop")
	await w.frames(2)
	ok(p.position.x > 1.0, "slides in from the right (x %.1f)" % p.position.x)
	await w.wait_s(0.5)
	eq(p.position.x, 0.0, "in place")
	eq(p.modulate.a, 1.0, "shown")
	p.queue_free()
	await w.frames(2)


## A wake (the wall clock jumped ahead) fades the screen up from dark after
## Power has been asked to re-read, and leaves nothing running.
func test_wake_fade_after_a_resume() -> void:
	var m: Control = w.main
	m._last_wake_ms = -1_000_000
	m._clock_mark = [Time.get_unix_time_from_system() - 600.0, Time.get_ticks_msec()]
	m._check_resume()
	await w.frames(2)
	var shade: Control = m._wake_shade
	ok(shade != null and shade.visible and shade.modulate.a > 0.3, "fading up from dark")
	eq(shade.mouse_filter, Control.MOUSE_FILTER_IGNORE, "never takes input")
	await rb()
	eq(m.current, "library", "input works during the fade")
	await w.wait_s(0.9)
	ok(not shade.visible, "gone after the fade")
	eq(m._screen_layer.scale, Vector2.ONE, "screens settled")
	await lb()
	await w.idle()


## Shelves seen for the first time ease in; rebuilt ones don't.
func test_shelves_ease_in_once() -> void:
	var h: Control = w.main.home
	if h.games.is_empty():
		ok(true, "no games on this setup")
		return
	h._revealed.clear()
	h.set_games(h.games)
	await w.frames(1)
	var s: Control = h.shelves()[0]
	ok(s.modulate.a < 1.0 or s.tiles[0].card.position.y > 0.0, "first show: easing in")
	await w.wait_s(0.7)
	eq(s.modulate.a, 1.0, "shown")
	eq(s.tiles[0].card.position.y, 0.0, "covers in place")
	h.set_games(h.games)
	await w.frames(1)
	eq(h.shelves()[0].modulate.a, 1.0, "a rebuild doesn't animate again")


## The quick menu's tabs (Audio included) fade their cards in on LB / RB;
## opening the menu itself adds nothing (its latency budget is suite_perf's).
func test_quick_menu_tabs_fade_in() -> void:
	await qam()
	var q: Control = qm()
	ok(q.visible, "menu open")
	eq(q.body.modulate.a, 1.0, "on open: no fade on the cards")
	var ids: Array = TC.TAB_IDS
	var target := ids.find("audio")
	if target < 0:
		target = 1
	for i in target:
		await rb()
	eq(ids[q.section], ids[target], "on the %s tab" % ids[target])
	await w.frames(1)
	ok(q.body.modulate.a < 1.0, "its cards fade in (a %.2f)" % q.body.modulate.a)
	await w.wait_s(0.3)
	eq(q.body.modulate.a, 1.0, "then fully shown")
	var f: Control = focus()
	ok(f != null and q.is_ancestor_of(f), "focus stays in the menu")
	await b()
	await w.idle()
