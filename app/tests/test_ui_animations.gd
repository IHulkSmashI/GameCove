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
