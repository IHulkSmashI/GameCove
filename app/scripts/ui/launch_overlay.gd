extends Control
## Launch splash. Play zooms the art it was pressed on (Home's hero, the game
## page's hero, a cover) up to full screen, crossfades it to the game's hero
## art with the logo (or title) centred and a soft shimmer under it while the
## game starts, then hands off: the moment our window loses focus (the game's
## window took the screen) everything stops and hides at once, so nothing of
## ours animates behind the game. A failed or cancelled launch plays the zoom
## backwards into where it came from.
##   overlay.show_for(game, accent, {"node": the Control pressed on (its rect is
##       read at the start and again for the way back), "tex": its art, "radius": corners})
## Only art that's already loaded or on disk (ArtCache) is used: never the network.
## Reduce motion: no zoom, drift or shimmer; it shows and goes at once.
## Every tween here is killed by finish()/back(); the shimmer only loops while
## the overlay is up in front, and the one Timer is the launch timeout.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const ArtCache := preload("res://scripts/ui/art_cache.gd")
const Backdrop := preload("res://scripts/ui/backdrop.gd")
const Motion := preload("res://scripts/ui/motion.gd")

signal cancel_requested(game: Dictionary)

const LAUNCH_TIMEOUT_S := 45.0
## The zoom from the pressed art to full screen.
const ZOOM_S := 0.5
## The pressed art's copy fades in over the original this fast (it drops the
## original's text and shading, so it doesn't pop).
const CARD_IN_S := 0.08
## The hero art crossfades over the pressed art from ART_AT for ART_S.
const ART_AT := 0.12
const ART_S := 0.36
## Logo, shimmer and "Launching…" settle in from TEXT_AT for TEXT_S.
const TEXT_AT := 0.30
const TEXT_S := 0.36
## One pass of the shimmer.
const SHIMMER_S := 1.4
## The slow push-in on the hero art while the game starts.
const DRIFT_S := 14.0
const DRIFT_SCALE := 1.05
## Back into the pressed art (failed or cancelled launch).
const BACK_S := 0.32
## Fade out after the timeout.
const OUT_S := 0.25
## Corners of the zooming card when the source gives none.
const RADIUS := 18.0
## Biggest logo in the middle.
const MAX_LOGO := Vector2(560, 200)
## The scene is always dark (cinematic), whatever the theme.
const BASE_COLOR := Color("#0A0E15")

var game: Dictionary = {}
## The Control Play was pressed on, its art and corner radius (show_for's `src`).
var source: Dictionary = {}
## idle | opening (zooming in) | waiting (the game is starting) | closing
var phase := "idle"
var base: ColorRect
## The card that zooms: a rounded mask over the pressed art and the hero art.
var card: Panel
var src_art: TextureRect
var art: TextureRect
var center: VBoxContainer
var logo: TextureRect
var title: Label
var shimmer: Control
var status: Label
var prompts: Control
var _scrim: TextureRect
var _card_box: StyleBoxFlat
var _timer: Timer
var _tw: Tween
var _loop: Tween
var _drift: Tween
var _from_radius := RADIUS


## An indeterminate progress line: a soft light that glides along a faint track.
class Shimmer extends Control:
	var color := Color.WHITE
	var phase := 0.0:
		set(v):
			phase = v
			queue_redraw()

	func _draw() -> void:
		var w := size.x
		var h := size.y
		if w <= 0.0 or h <= 0.0:
			return
		var track := StyleBoxFlat.new()
		track.bg_color = Color(1, 1, 1, 0.16)
		track.set_corner_radius_all(int(h / 2.0 + 0.5))
		draw_style_box(track, Rect2(Vector2.ZERO, size))
		# The light: transparent -> colour -> transparent, `seg` wide, sliding from
		# off the left end to off the right one.
		var seg := w * 0.38
		var x0 := lerpf(-seg, w, phase)
		var xs := [x0, x0 + seg * 0.5, x0 + seg]
		var cols := [Color(color, 0.0), Color(color, 0.95), Color(color, 0.0)]
		for i in 2:
			var a: float = xs[i]
			var b: float = xs[i + 1]
			var l := clampf(a, 0.0, w)
			var r := clampf(b, 0.0, w)
			if r - l < 0.5:
				continue
			var ca: Color = cols[i].lerp(cols[i + 1], (l - a) / (b - a))
			var cb: Color = cols[i].lerp(cols[i + 1], (r - a) / (b - a))
			draw_polygon(PackedVector2Array([Vector2(l, 0), Vector2(r, 0), Vector2(r, h), Vector2(l, h)]),
				PackedColorArray([ca, cb, cb, ca]))


func _init() -> void:
	name = "LaunchOverlay"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	base = ColorRect.new()
	base.name = "Base"
	base.color = BASE_COLOR
	Kit.fill(base)
	add_child(base)

	card = Panel.new()
	card.name = "Card"
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card_box = StyleBoxFlat.new()
	_card_box.bg_color = BASE_COLOR
	_card_box.anti_aliasing = true
	_card_box.corner_detail = 10
	card.add_theme_stylebox_override("panel", _card_box)
	add_child(card)
	src_art = TextureRect.new()
	src_art.name = "From"
	src_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	src_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	Kit.fill(src_art)
	card.add_child(src_art)
	art = TextureRect.new()
	art.name = "Art"
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	Kit.fill(art)
	card.add_child(art)
	card.resized.connect(func(): art.pivot_offset = card.size / 2.0)

	_scrim = TextureRect.new()
	_scrim.name = "Scrim"
	_scrim.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_scrim.stretch_mode = TextureRect.STRETCH_SCALE
	Kit.fill(_scrim)
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	g.colors = PackedColorArray([Color(0, 0, 0, 0.30), Color(0, 0, 0, 0.42), Color(0, 0, 0, 0.88)])
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.width = 4
	gt.height = 256
	gt.fill_to = Vector2(0, 1)
	_scrim.texture = gt
	add_child(_scrim)

	# The middle: logo or title, the shimmer, "Launching…". Not in a container,
	# so it can scale in about its centre.
	center = VBoxContainer.new()
	center.name = "Center"
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_theme_constant_override("separation", 0)
	center.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_MINSIZE)
	center.grow_horizontal = Control.GROW_DIRECTION_BOTH
	center.grow_vertical = Control.GROW_DIRECTION_BOTH
	center.resized.connect(func(): center.pivot_offset = center.size / 2.0)
	add_child(center)
	logo = TextureRect.new()
	logo.name = "Logo"
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	logo.visible = false
	center.add_child(logo)
	title = Kit.label("", "DisplayLabel", true)
	title.name = "Title"
	title.uppercase = true
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.custom_minimum_size = Vector2(760, 0)
	title.max_lines_visible = 2
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.add_theme_color_override("font_color", Color.WHITE)
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.5))
	title.add_theme_constant_override("shadow_offset_y", 2)
	title.add_theme_constant_override("shadow_outline_size", 10)
	center.add_child(title)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 34)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(gap)
	shimmer = Shimmer.new()
	shimmer.name = "Shimmer"
	shimmer.custom_minimum_size = Vector2(260, 4)
	shimmer.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	shimmer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(shimmer)
	var gap2 := Control.new()
	gap2.custom_minimum_size = Vector2(0, 14)
	gap2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(gap2)
	status = Kit.label("Launching…", "LeadLabel")
	status.name = "Status"
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status.add_theme_color_override("font_color", Color(1, 1, 1, 0.82))
	center.add_child(status)

	var m := Kit.margin(0, 64, 0)
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	m.add_theme_constant_override("margin_bottom", 40)
	add_child(m)
	var col := Kit.vbox(0)
	col.alignment = BoxContainer.ALIGNMENT_END
	m.add_child(col)
	var row := Kit.hbox(0)
	row.add_child(Kit.spacer())
	prompts = Kit.prompts([["B", "Cancel"]])
	row.add_child(prompts)
	col.add_child(row)

	# only the overlay itself takes taps (while it's up); its pieces never do, so
	# on its way out (mouse_filter IGNORE) the first tap reaches what's below
	for k in get_children():
		Kit.ignore_mouse(k)

	_timer = Timer.new()
	_timer.one_shot = true
	_timer.wait_time = LAUNCH_TIMEOUT_S
	_timer.timeout.connect(func(): finish(true))
	add_child(_timer)
	resized.connect(_on_resized)


## Up and taking input (zooming in or waiting for the game), not on its way out.
func is_open() -> bool:
	return phase == "opening" or phase == "waiting"


## Play pressed. `accent` tints the shimmer; `src` is where the zoom starts:
## {"node": Control, "rect": Rect2 (when there's no node), "tex": Texture2D, "radius": float}.
func show_for(g: Dictionary, accent: Color = Color(0, 0, 0, 0), src: Dictionary = {}) -> void:
	_stop_all()
	game = g
	source = src
	status.text = "Launching…" if g.get("installed", true) else "Starting the install…"
	(shimmer as Shimmer).color = accent if accent.a > 0.0 else ThemeLib.color("accent")
	_fill(g)
	visible = true
	modulate.a = 1.0
	mouse_filter = Control.MOUSE_FILTER_STOP
	art.scale = Vector2.ONE
	var full := _full_rect()
	var from := source_rect()
	var from_tex: Texture2D = src.get("tex") if src.get("tex") is Texture2D else null
	_from_radius = float(src.get("radius", RADIUS))
	src_art.texture = from_tex if from_tex != null else art.texture
	var crossfade := from_tex != null and art.texture != null and from_tex != art.texture
	if Motion.reduce:
		_set_card(full, 0.0)
		for c in [base, card, art, _scrim, center, prompts]:
			c.modulate.a = 1.0
		center.scale = Vector2.ONE
		(shimmer as Shimmer).phase = 0.5
		phase = "waiting"
		if _timer.is_inside_tree():
			_timer.start()
		return
	phase = "opening"
	var start := from
	if start.size.x < 8.0 or start.size.y < 8.0:
		# Nothing to zoom out of: grow from the middle.
		start = Rect2(full.get_center() - full.size * 0.35, full.size * 0.7)
	_set_card(start, _from_radius)
	card.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	base.modulate.a = 0.0
	card.modulate.a = 0.0
	art.modulate.a = 0.0 if crossfade else 1.0
	for c in [_scrim, center, prompts]:
		c.modulate.a = 0.0
	center.scale = Vector2(0.94, 0.94)
	_tw = create_tween().set_parallel(true)
	# Quick off the mark (the press answers at once), soft landing.
	_tw.tween_property(card, "position", full.position, ZOOM_S).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	_tw.tween_property(card, "size", full.size, ZOOM_S).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	_tw.tween_method(_set_radius, _from_radius, 0.0, ZOOM_S).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	_tw.tween_property(base, "modulate:a", 1.0, ZOOM_S * 0.6)
	_tw.tween_property(card, "modulate:a", 1.0, CARD_IN_S if from_tex != null else ZOOM_S * 0.6)
	if crossfade:
		_tw.tween_property(art, "modulate:a", 1.0, ART_S).set_delay(ART_AT)
	_tw.tween_property(_scrim, "modulate:a", 1.0, TEXT_S).set_delay(TEXT_AT - 0.1)
	_tw.tween_property(center, "modulate:a", 1.0, TEXT_S).set_delay(TEXT_AT)
	_tw.tween_property(center, "scale", Vector2.ONE, TEXT_S + 0.1).set_delay(TEXT_AT).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_tw.tween_property(prompts, "modulate:a", 1.0, TEXT_S).set_delay(TEXT_AT + 0.1)
	_tw.chain().tween_callback(_opened)
	_loop = create_tween().set_loops()
	_loop.tween_property(shimmer, "phase", 1.0, SHIMMER_S).from(0.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if _timer.is_inside_tree():
		_timer.start()


func _opened() -> void:
	phase = "waiting"
	_set_card(_full_rect(), 0.0)
	card.clip_children = CanvasItem.CLIP_CHILDREN_DISABLED   # full screen, square: no mask pass
	_drift = create_tween()
	_drift.tween_property(art, "scale", Vector2(DRIFT_SCALE, DRIFT_SCALE), DRIFT_S).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


## The game took the screen (our window lost focus), or it timed out. Hides at
## once by default: behind the game nothing of ours may keep animating.
## `animate`: fade out (the timeout, with our window still in front).
func finish(animate := false) -> void:
	if phase == "idle":
		return
	_stop_all()
	if not animate or Motion.reduce:
		_hide_now()
		return
	phase = "closing"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tw = create_tween()
	_tw.tween_property(self, "modulate:a", 0.0, OUT_S)
	_tw.tween_callback(_hide_now)


## The launch failed or was cancelled: the zoom runs backwards into the art it
## came from (or shrinks away in the middle when that's gone).
func back() -> void:
	if phase == "idle" or phase == "closing":
		return
	_stop_all()
	if Motion.reduce:
		_hide_now()
		return
	phase = "closing"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var full := _full_rect()
	var to := source_rect()
	var has_to := to.size.x >= 8.0 and to.size.y >= 8.0
	if not has_to:
		to = Rect2(full.get_center() - full.size * 0.3, full.size * 0.6)
	card.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	_tw = create_tween().set_parallel(true)
	for c in [center, prompts]:
		_tw.tween_property(c, "modulate:a", 0.0, 0.12)
	_tw.tween_property(_scrim, "modulate:a", 0.0, 0.2)
	if src_art.texture != null and src_art.texture != art.texture:
		_tw.tween_property(art, "modulate:a", 0.0, 0.2)
	_tw.tween_property(art, "scale", Vector2.ONE, BACK_S).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tw.tween_property(card, "position", to.position, BACK_S).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_tw.tween_property(card, "size", to.size, BACK_S).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_tw.tween_method(_set_radius, _card_box.corner_radius_top_left, _from_radius, BACK_S)
	_tw.tween_property(base, "modulate:a", 0.0, BACK_S)
	if not has_to:
		_tw.tween_property(card, "modulate:a", 0.0, BACK_S)
	_tw.chain().tween_property(card, "modulate:a", 0.0, 0.08)
	_tw.chain().tween_callback(_hide_now)


func cancel() -> void:
	var g := game
	back()
	cancel_requested.emit(g)


## Where the zoom starts and goes back to, in our coordinates: the source
## Control's rect as drawn now (with its focus lift), else src["rect"].
func source_rect() -> Rect2:
	var n: Variant = source.get("node")
	# is_instance_valid first: `is` on a freed tile (the grid rebuilt mid-launch) is a script error.
	if is_instance_valid(n) and n is Control and ((n as Control).is_visible_in_tree() or not (n as Control).is_inside_tree()):
		var r := drawn_rect(n)
		return get_global_transform().affine_inverse() * r
	var r2: Variant = source.get("rect")
	return r2 if r2 is Rect2 else Rect2()


## A Control's rect on screen, with its scale (and its parents').
static func drawn_rect(c: Control) -> Rect2:
	var xf := c.get_global_transform()
	return Rect2(xf.origin, c.size * xf.get_scale())


func _full_rect() -> Rect2:
	var s := size
	if s.x <= 0.0 or s.y <= 0.0:
		s = get_viewport_rect().size if is_inside_tree() else Vector2(1280, 800)
	return Rect2(Vector2.ZERO, s)


func _set_card(r: Rect2, radius: float) -> void:
	card.position = r.position
	card.size = r.size
	_set_radius(radius)


func _set_radius(v: float) -> void:
	_card_box.set_corner_radius_all(int(round(v)))


func _on_resized() -> void:
	if phase == "waiting":
		_set_card(_full_rect(), 0.0)


## Hero art (else the blurred cover) and the logo (else the title), from what's
## loaded or on disk.
func _fill(g: Dictionary) -> void:
	art.texture = null
	var a: Variant = g.get("art", {})
	var hero_path: String = a.get("hero", "") if a is Dictionary else ""
	var tex: Texture2D = null
	if ArtCache.usable(hero_path):
		tex = ArtCache.request("hero", hero_path, func(t):
			if game.get("key", "") == g.get("key", "") and is_instance_valid(art):
				art.texture = t, self)
	if tex == null:
		var src := Backdrop.art_source(g)
		if src != "":
			tex = ArtCache.request("blur", src, func(t):
				if game.get("key", "") == g.get("key", "") and is_instance_valid(art) and art.texture == null:
					art.texture = t, self)
	art.texture = tex
	title.text = str(g.get("title", ""))
	title.visible = true
	logo.visible = false
	var logo_path: String = a.get("logo", "") if a is Dictionary else ""
	if ArtCache.usable(logo_path):
		var lt := ArtCache.request("logo", logo_path, func(t):
			if game.get("key", "") == g.get("key", "") and is_instance_valid(logo):
				_show_logo(t), self)
		if lt != null:
			_show_logo(lt)


func _show_logo(t: Texture2D) -> void:
	if t == null or t.get_width() <= 0 or t.get_height() <= 0:
		return
	var s := minf(MAX_LOGO.x / t.get_width(), MAX_LOGO.y / t.get_height())
	logo.custom_minimum_size = Vector2(t.get_width(), t.get_height()) * s
	logo.texture = t
	logo.visible = true
	title.visible = false


func _stop_all() -> void:
	for t in [_tw, _loop, _drift]:
		if t != null and t.is_valid():
			t.kill()
	_tw = null
	_loop = null
	_drift = null
	if _timer != null:
		_timer.stop()


func _hide_now() -> void:
	_stop_all()
	visible = false
	phase = "idle"
	modulate.a = 1.0
	card.clip_children = CanvasItem.CLIP_CHILDREN_DISABLED
	art.scale = Vector2.ONE
	(shimmer as Shimmer).phase = 0.0
	src_art.texture = null
	art.texture = null
	logo.texture = null
	source = {}


## Running tweens of this overlay (tests, the perf check).
func running_tweens() -> int:
	var n := 0
	for t in [_tw, _loop, _drift]:
		if t != null and t.is_valid() and t.is_running():
			n += 1
	return n


func _unhandled_input(event: InputEvent) -> void:
	if is_open() and event.is_action_pressed("ui_cancel"):
		cancel()
		get_viewport().set_input_as_handled()
