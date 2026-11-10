extends "res://tests/test_case.gd"
## The animations (launch zoom, screen changes, little moments, boot intro):
## where they start and end, that interrupting them is safe, that Reduce motion
## makes them instant, and that nothing keeps running once they're done.
## Tweens are stepped by hand (Tween.custom_step), no frames needed.

const Motion := preload("res://scripts/ui/motion.gd")
const LaunchOverlay := preload("res://scripts/ui/launch_overlay.gd")

const GAME := {"key": "steam:1", "title": "Hades", "installed": true, "art": {}}


func _root() -> Window:
	return (Engine.get_main_loop() as SceneTree).root


## A 1280x800 host in the tree with a launch overlay in it.
func _overlay_host() -> Array:
	var host := Control.new()
	host.size = Vector2(1280, 800)
	_root().add_child(host)
	var o: Control = LaunchOverlay.new()
	host.add_child(o)
	return [host, o]


func _tex(w: int, h: int, c: Color) -> Texture2D:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return ImageTexture.create_from_image(img)


## (Unit tests run outside a live tree, where tweens don't advance: the
## e2e suite_animations.gd plays them through in the running app.)
func test_launch_starts_on_the_pressed_art() -> void:
	var was: bool = Motion.reduce
	Motion.reduce = false
	var hv := _overlay_host()
	var host: Control = hv[0]
	var o: Control = hv[1]
	var src := Control.new()
	host.add_child(src)
	src.position = Vector2(100, 200)
	src.size = Vector2(180, 270)
	var cover := _tex(6, 9, Color.RED)
	o.show_for(GAME, Color.CYAN, {"node": src, "tex": cover, "radius": 12.0})
	ok(o.visible and o.is_open(), "up and open at once")
	eq(o.phase, "opening", "zooming")
	eq(o.card.position, Vector2(100, 200), "starts on the pressed cover")
	eq(o.card.size, Vector2(180, 270), "at its size")
	eq(o.card.get_theme_stylebox("panel").corner_radius_top_left, 12, "with its corners")
	eq(o.src_art.texture, cover, "showing its art")
	eq(o.card.clip_children, CanvasItem.CLIP_CHILDREN_ONLY, "rounded while it moves")
	eq(o.base.modulate.a, 0.0, "the screen behind still shows")
	eq(o.center.modulate.a, 0.0, "logo comes in later")
	eq(o.running_tweens(), 2, "zoom and shimmer")
	eq(o.title.text, "Hades", "the title stands in for a missing logo")
	eq(o.prompts.modulate.a, 0.0, "no Cancel hint yet: it only shows if the game is slow to start")
	host.free()
	Motion.reduce = was


func test_launch_without_a_source_grows_from_the_middle() -> void:
	var was: bool = Motion.reduce
	Motion.reduce = false
	var hv := _overlay_host()
	var o: Control = hv[1]
	o.show_for(GAME, Color.CYAN, {})
	var r := Rect2(o.card.position, o.card.size)
	ok(r.size.x > 100.0 and r.size.x < 1280.0, "smaller than the screen (%s)" % r)
	ok(r.get_center().distance_to(Vector2(640, 400)) < 1.0, "centred")
	eq(o.card.modulate.a, 0.0, "and fades in")
	hv[0].free()
	Motion.reduce = was


func test_handoff_stops_everything_at_once() -> void:
	var was: bool = Motion.reduce
	Motion.reduce = false
	var hv := _overlay_host()
	var o: Control = hv[1]
	o.show_for(GAME, Color.CYAN, {})
	o.finish()   # our window lost focus mid-zoom: the game has the screen
	ok(not o.visible, "hidden")
	eq(o.phase, "idle", "idle")
	eq(o.running_tweens(), 0, "no tween left running behind the game")
	ok(o._timer.is_stopped(), "timeout stopped")
	ok(o.art.texture == null, "art let go")
	o.finish()
	ok(not o.visible, "finishing twice is harmless")
	hv[0].free()
	Motion.reduce = was


func test_failed_launch_goes_back_without_blocking_input() -> void:
	var was: bool = Motion.reduce
	Motion.reduce = false
	var hv := _overlay_host()
	var o: Control = hv[1]
	o.show_for(GAME, Color.CYAN, {"rect": Rect2(64, 76, 1152, 330), "tex": _tex(4, 2, Color.BLUE)})
	o.back()
	eq(o.phase, "closing", "on its way back")
	ok(not o.is_open(), "no longer takes input")
	eq(o.mouse_filter, Control.MOUSE_FILTER_IGNORE, "lets the screen behind have it")
	eq(o.running_tweens(), 1, "one tween: the way back (shimmer stopped)")
	o.back()
	eq(o.phase, "closing", "a second back is ignored")
	o.finish()
	ok(not o.visible and o.running_tweens() == 0, "focus lost on the way back: gone at once")
	hv[0].free()
	Motion.reduce = was


func test_cancel_and_interrupts_are_safe() -> void:
	var was: bool = Motion.reduce
	Motion.reduce = false
	var hv := _overlay_host()
	var o: Control = hv[1]
	var got := []
	o.cancel_requested.connect(func(g): got.append(g.get("key", "")))
	o.show_for(GAME, Color.CYAN, {})
	o.cancel()
	eq(got, ["steam:1"], "B cancels the launch")
	eq(o.phase, "closing", "and plays back")
	o.show_for(GAME, Color.CYAN, {})
	eq(o.phase, "opening", "Play again while it goes back: starts over")
	eq(o.running_tweens(), 2, "with only its own tweens")
	o.finish()
	ok(not o.visible and o.running_tweens() == 0, "hidden, nothing running")
	hv[0].free()
	Motion.reduce = was


func test_launch_under_reduce_motion_is_instant() -> void:
	var was: bool = Motion.reduce
	Motion.reduce = true
	var hv := _overlay_host()
	var host: Control = hv[0]
	var o: Control = hv[1]
	var src := Control.new()
	host.add_child(src)
	src.size = Vector2(100, 100)
	o.show_for(GAME, Color.CYAN, {"node": src})
	eq(o.phase, "waiting", "straight to waiting")
	eq(o.card.position, Vector2.ZERO, "full screen at once")
	eq(o.center.modulate.a, 1.0, "logo shows at once")
	eq(o.running_tweens(), 0, "no zoom, no shimmer loop")
	o.back()
	ok(not o.visible and o.phase == "idle", "gone at once on the way back too")
	host.free()
	Motion.reduce = was


func test_drawn_rect_includes_the_focus_lift() -> void:
	var host := Control.new()
	_root().add_child(host)
	var c := Control.new()
	host.add_child(c)
	c.position = Vector2(100, 100)
	c.size = Vector2(200, 300)
	c.pivot_offset = c.size / 2.0
	c.scale = Vector2(1.1, 1.1)
	var r: Rect2 = LaunchOverlay.drawn_rect(c)
	ok(r.position.distance_to(Vector2(90, 85)) < 0.01, "lifted rect starts up-left (%s)" % r.position)
	ok(r.size.distance_to(Vector2(220, 330)) < 0.01, "and is bigger")
	host.free()


func test_motion_enter_and_pop_are_instant_when_they_cant_play() -> void:
	var was: bool = Motion.reduce
	var c := Control.new()
	Motion.reduce = false
	eq(Motion.enter(c, "position:x", 50.0, 0.0), null, "out of the tree: set at once")
	eq(c.position.x, 0.0, "at its target")
	Motion.reduce = true
	eq(Motion.pop(c, 0.5), null, "reduce motion: no pop")
	eq(c.scale, Vector2.ONE, "full size")
	eq(Motion.enter(c, "modulate:a", 0.0, 1.0), null, "reduce motion: no entrance")
	eq(c.modulate.a, 1.0, "shown")
	c.free()
	Motion.reduce = was


func test_newly_unlocked_achievements() -> void:
	var Card = load("res://scripts/ui/games/achievements_card.gd")
	var now := 1_000_000
	var list := [
		{"id": "a", "unlocked": true, "unlock_time": now - 3600},
		{"id": "b", "unlocked": true, "unlock_time": now - 30 * 86400},
		{"id": "c", "unlocked": false},
	]
	Card._seen_unlocked.erase("t1")
	eq(Card.newly_unlocked("t1", list, now), ["a"], "first look: only the recent unlock is new")
	eq(Card.newly_unlocked("t1", list, now), [], "seen: nothing new the second time")
	list[2] = {"id": "c", "unlocked": true, "unlock_time": now}
	eq(Card.newly_unlocked("t1", list, now), ["c"], "unlocked since: new")
	Card._seen_unlocked.erase("t1")


func test_toast_and_shelf_entrances_end_in_place() -> void:
	var was: bool = Motion.reduce
	Motion.reduce = true
	var Toasts = load("res://scripts/ui/toast.gd")
	var t: VBoxContainer = Toasts.new()
	var p: Control = t.show_toast("Paper Lanterns is 60% off", "tag", "sale")
	eq(p.position.x, 0.0, "in place at once")
	eq(p.modulate.a, 1.0, "shown")
	t.free()
	var Shelf = load("res://scripts/ui/shelf.gd")
	var s: VBoxContainer = Shelf.new()
	s.setup("x", "X", [{"key": "a", "title": "A"}, {"key": "b", "title": "B"}])
	s.reveal()
	eq(s.modulate.a, 1.0, "shelf shown at once")
	eq(s.tiles[1].card.position.y, 0.0, "covers in place")
	s.free()
	Motion.reduce = was


func test_boot_intro_plays_the_clip_when_there_else_the_code_animation() -> void:
	var Splash = load("res://scripts/ui/boot_splash.gd")
	var keep: String = Splash.video_path
	eq(Splash.pick_mode(), "video", "the owner's clip ships in res://assets/boot/intro.ogv")
	ok(load(keep) is VideoStream, "and loads as a video stream (Theora)")
	var v: Control = Splash.new()
	v.build("video")
	ok(v.player != null and v.player.stream is VideoStream, "a VideoStreamPlayer on the clip")
	eq(v.mouse_filter, Control.MOUSE_FILTER_IGNORE, "never takes the mouse")
	eq(v._shade.color, Color("#0F1723"), "on the clip's own background, so the hand-off is seamless")
	v.free()
	Splash.video_path = "res://assets/boot/missing.ogv"
	eq(Splash.pick_mode(), "code", "no clip: the code animation")
	Splash.video_path = keep
	var c: Control = Splash.new()
	c.build("code")
	ok(c.find_child("Mark", true, false) != null and c.find_child("Sweep", true, false) != null, "the mark and its glow sweep")
	var logo: TextureRect = c.find_child("Logo", true, false)
	ok(logo != null and logo.texture != null, "the GameCove mark (assets/logo-mark.svg = assets/logo.svg)")
	ok(Splash.IN_S + 0.0 <= Splash.HOLD_UNTIL and Splash.HOLD_UNTIL + Splash.MORPH_S <= 2.0, "the code animation is 2 s or less")
	c.skip()
	ok(c._done, "a button skips it")
	c.free()


func test_boot_intro_never_delays_readiness() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/main.gd")
	var heartbeat := src.find("health.watch_session(session)")
	var intro := src.find("boot_splash.gd\").play(self)")
	ok(heartbeat > 0 and intro > heartbeat, "the intro starts after the heartbeat is set up")
	ok(not src.contains("await _boot_intro") and not src.contains("_boot_intro.finished"), "nothing waits for it")
	ok(src.contains("_boot_intro.skip(true)"), "it goes at once when our window loses focus")


## The timings the motion pass settled on (snappy, never in the way).
func test_motion_timings() -> void:
	ok(LaunchOverlay.ZOOM_S >= 0.18 and LaunchOverlay.ZOOM_S <= 0.22, "launch zoom ~0.2 s")
	ok(LaunchOverlay.open_s() <= 0.3, "the whole way in under 0.3 s (%.2f)" % LaunchOverlay.open_s())
	eq(LaunchOverlay.PUSH_SCALE, 1.04, "the hero art pushes in to 1.04 with the title")
	ok(LaunchOverlay.HINT_AT >= 2.0, "the Cancel hint waits 2 s")
	eq(LaunchOverlay.BACK_S, 0.2, "failed or cancelled: back in 0.2 s")
	var M = load("res://scripts/main.gd")
	eq(M.SCREEN_SLIDE_PX, 36.0, "tabs slide 36 px")
	eq(M.SCREEN_IN_S, 0.16, "in 0.16 s")
	ok(M.SCREEN_OUT_S < M.SCREEN_FADE_IN_S, "the old tab is gone before the new one is opaque")
	eq(M.LAUNCH_RECEDE_PX, 32.0, "under the launch the screen drops 32 px")
	eq(M.LAUNCH_RECEDE_S, 0.12, "in 0.12 s")
	eq(M.PAGE_CARDS_PX, 48.0, "game page cards slide 48 px")
	ok(M.PAGE_IN_S == 0.22 and M.PAGE_OUT_S == 0.14, "in 0.22 s, out 0.14 s")
	eq(M.WAKE_FADE_S, 0.2, "wake fade 0.2 s")
	var Toasts = load("res://scripts/ui/toast.gd")
	ok(Toasts.SLIDE_PX == 40.0 and Toasts.IN_S == 0.18 and Toasts.OUT_S == 0.14 and Toasts.STAY_S == 3.5, "toasts: 40 px in 0.18 s, 3.5 s, out 0.14 s")
	var Shelf = load("res://scripts/ui/shelf.gd")
	eq(Shelf.REVEAL_SHELF_STAGGER_S, 0.04, "shelves enter 40 ms apart")
	var Splash = load("res://scripts/ui/boot_splash.gd")
	ok(Splash.VIDEO_END_S + Splash.MORPH_S <= 2.35, "the clip ends with the fly-in by ~2.3 s")
	eq(Splash.MORPH_S, 0.28, "the fly-in is 0.28 s")
	eq(Splash.PULSE_S, 0.2, "one 0.2 s focus pulse")


class SplashHost extends Control:
	var top_bar: Control


func test_boot_intro_ends_by_flying_the_mark_into_the_top_bar() -> void:
	var was: bool = Motion.reduce
	Motion.reduce = false
	var Splash = load("res://scripts/ui/boot_splash.gd")
	for m in ["video", "code"]:
		var host := SplashHost.new()
		host.size = Vector2(1280, 800)
		_root().add_child(host)
		var tb := Control.new()
		tb.name = "TopBar"
		host.add_child(tb)
		host.top_bar = tb
		var logo := TextureRect.new()
		logo.name = "Logo"
		logo.position = Vector2(24, 14)
		logo.size = Vector2(34, 34)
		tb.add_child(logo)
		var b := Button.new()
		b.position = Vector2(100, 300)
		b.size = Vector2(160, 48)
		host.add_child(b)
		var s: Control = Splash.new()
		s.build(m)
		s._host = host
		host.add_child(s)
		s.size = host.size
		if m == "video":
			s.player.size = host.size
			var r: Rect2 = s.mark_rect()
			ok(r.get_center().distance_to(Vector2(640, 400)) < 0.5, "video: the clip's mark is in the middle")
			ok(absf(r.size.x - 1280.0 * Splash.CLIP_MARK_FRAC) < 0.5, "at the clip's size (%s)" % r.size)
		s._morph()
		ok(s._done, "%s: presses go to the home screen once it flies" % m)
		ok(s.flyer != null and s.flyer.texture != null, "%s: the mark flies" % m)
		eq(logo.modulate.a, 0.0, "%s: the top bar's logo waits for it" % m)
		s._landed(b)   # (the focused control; no live viewport in unit tests)
		eq(logo.modulate.a, 1.0, "%s: then shows (the mark landed on it)" % m)
		var ring: Control = s.find_child("FocusPulse", true, false)
		ok(ring != null, "%s: a ring pulses on the focused control" % m)
		if ring != null:
			ok(Rect2(ring.position, ring.size).encloses(Rect2(b.position, b.size)), "%s: around it" % m)
		s.free()
		eq(logo.modulate.a, 1.0, "%s: the top bar's logo is never left hidden" % m)
		host.free()
	Motion.reduce = was


func test_boot_intro_skipped_mid_flight_leaves_the_logo_shown() -> void:
	var Splash = load("res://scripts/ui/boot_splash.gd")
	var host := SplashHost.new()
	_root().add_child(host)
	var tb := Control.new()
	host.add_child(tb)
	host.top_bar = tb
	var logo := TextureRect.new()
	logo.name = "Logo"
	logo.size = Vector2(34, 34)
	tb.add_child(logo)
	var s: Control = Splash.new()
	s.build("code")
	s._host = host
	host.add_child(s)
	s._morph()
	eq(logo.modulate.a, 0.0, "flying")
	s.skip(true)   # our window lost focus
	eq(logo.modulate.a, 1.0, "the top bar's logo is back at once")
	host.free()
