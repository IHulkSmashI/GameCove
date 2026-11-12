extends Control
## The boot intro over the home screen. If res://assets/boot/intro.ogv exists
## (the owner's clip, Theora, no audio) it plays that, stopped VIDEO_END_S in
## (~0.3 s after its glow settles; the file itself is untouched); otherwise a
## code animation of the GameCove mark (assets/logo-mark.svg, the same file as
## the repo's assets/logo.svg): it scales in and one soft cyan glow sweeps
## across the wordmark, on the clip's slate background so the two look the
## same. Either way it ends the same: the mark flies into the top bar's logo
## (scale + move, MORPH_S) as the slate fades off the home screen, then one
## soft ring pulses on the control that has focus (Home's Play): ready.
## To swap the clip see docs/BOOT_INTRO.md.
##
## It never delays anything: main.gd adds it last in _ready, after the session
## client's heartbeat/ready file is set up, and nothing waits for it; the home
## screen behind is live at once. Any button (or key or click) skips it (that
## press is used up, the way a console's intro skip is); it also goes at once
## when our window loses focus. Reduce motion: no intro at all.
## Nothing runs once it's done: its tweens end with it and it frees itself.

const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")

## The clip's background (#0F1723), also the code animation's.
const BG := Color("#0F1723")
const GLOW := Color("#00F0FF")
## Code animation: scale-in, glow sweep (the halo settles by ~1.37 s), a
## short hold, then the fly-in (MORPH_S): about 1.9 s in all.
const IN_S := 0.55
const SWEEP_AT := 0.45
const SWEEP_S := 0.7
const HOLD_UNTIL := 1.6
## The clip plays this long (its glow settles at ~1.7 s), then the fly-in.
const VIDEO_END_S := 2.0
## Where the mark sits in the clip: centred, the SVG's 512-px box drawn this
## wide as a share of the clip's width (the mark is 640 px of a 1920x1200 frame).
const CLIP_MARK_FRAC := 805.0 / 1920.0
## The mark flies into the top bar's logo while the slate fades.
const MORPH_S := 0.28
## Then one ring pulse on the focused control.
const PULSE_S := 0.2
const PULSE_GROW := 0.08
## Skipped: fade out this fast.
const SKIP_S := 0.15

## Where the clip is looked for (tests point it elsewhere).
static var video_path := "res://assets/boot/intro.ogv"

## "video" or "code".
var mode := ""
var player: VideoStreamPlayer
var _shade: ColorRect
var _mark: Control
var _halo: Panel
var _sweep: TextureRect
## The code animation's mark inside its halo.
var _logo: TextureRect
## What flies into the top bar (the clip's mark redrawn, or the code
## animation's whole mark + wordmark row), and the top bar's logo (hidden meanwhile).
var flyer: Control
var _center: Control
var _header_logo: CanvasItem
## The top bar's wordmark, hidden while the code animation's own flies in.
var _header_word: CanvasItem
var _host: Control
var _tw: Tween
var _done := false


## Adds the intro over `host` and plays it, unless motion is reduced. Returns it (or null).
static func play(host: Control) -> Control:
	if Motion.reduce:
		return null
	var s: Control = load("res://scripts/ui/boot_splash.gd").new()
	s.build(pick_mode())
	s._host = host
	host.add_child(s)
	s._start()
	return s


## "video" when the clip is there, else "code".
static func pick_mode() -> String:
	return "video" if video_path != "" and (ResourceLoader.exists(video_path) or FileAccess.file_exists(video_path)) else "code"


func _init() -> void:
	name = "BootSplash"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	set_meta("ux_no_walk", "the boot intro: any button skips it")
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 100
	_shade = ColorRect.new()
	_shade.name = "Shade"
	_shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shade.color = BG
	add_child(_shade)


func build(m: String) -> void:
	mode = m
	if m == "video":
		_build_video()
	else:
		_build_code()


func _build_video() -> void:
	player = VideoStreamPlayer.new()
	player.name = "Intro"
	player.set_anchors_preset(Control.PRESET_FULL_RECT)
	player.expand = true   # the clip is 16:10 like the screen; it fills it
	player.mouse_filter = Control.MOUSE_FILTER_IGNORE
	player.volume_db = -80.0
	var st: VideoStream = load(video_path) if ResourceLoader.exists(video_path) else null
	if st == null:
		st = VideoStreamTheora.new()
		st.file = video_path
	player.stream = st
	player.finished.connect(_morph)   # a clip shorter than VIDEO_END_S
	add_child(player)


func _build_code() -> void:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	_center = center
	var row := HBoxContainer.new()
	row.name = "Mark"
	row.add_theme_constant_override("separation", 0)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(row)
	_mark = row
	_halo = Panel.new()
	_halo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_halo.custom_minimum_size = Vector2(120, 120)
	# A soft round glow behind the mark (no box).
	var hb := ThemeLib.box(Color(GLOW, 0.0), 60, 0, 0)
	hb.shadow_color = Color(GLOW, 0.35)
	hb.shadow_size = 36
	_halo.add_theme_stylebox_override("panel", hb)
	var logo := TextureRect.new()
	logo.name = "Logo"
	logo.texture = load("res://assets/logo-mark.svg")
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.set_anchors_preset(Control.PRESET_FULL_RECT)
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_halo.add_child(logo)
	_logo = logo
	row.add_child(_halo)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(26, 0)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(gap)
	for part in [["GAME", Color("#E8EEF7")], ["COVE", GLOW]]:
		var l := Label.new()
		l.text = part[0]
		l.add_theme_font_override("font", ThemeLib.font("display"))
		l.add_theme_font_size_override("font_size", 68)
		l.add_theme_color_override("font_color", part[1])
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(l)
	# The glow sweep: a soft cyan band, added on top (it lights what it crosses).
	_sweep = TextureRect.new()
	_sweep.name = "Sweep"
	_sweep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sweep.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_sweep.stretch_mode = TextureRect.STRETCH_SCALE
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 1.0])
	g.colors = PackedColorArray([Color(GLOW, 0.34), Color(GLOW, 0.0)])
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.width = 64
	gt.height = 64
	gt.fill = GradientTexture2D.FILL_RADIAL   # soft on every side (an ellipse once stretched)
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	_sweep.texture = gt
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_sweep.material = mat
	_sweep.size = Vector2(260, 180)
	_sweep.rotation = 0.12
	_sweep.modulate.a = 0.0
	add_child(_sweep)


func _start() -> void:
	if mode == "video":
		player.play()
		_tw = create_tween()
		_tw.tween_interval(VIDEO_END_S)
		_tw.tween_callback(_morph)
		return
	_mark.modulate.a = 0.0
	_mark.scale = Vector2(0.82, 0.82)
	_mark.resized.connect(func(): _mark.pivot_offset = _mark.size / 2.0)
	var vw := get_viewport_rect().size
	var y := vw.y * 0.5 - 90.0
	_sweep.position = Vector2(vw.x * 0.5 - 560.0, y)
	_tw = create_tween().set_parallel(true)
	_tw.tween_property(_mark, "modulate:a", 1.0, IN_S * 0.7)
	_tw.tween_property(_mark, "scale", Vector2.ONE, IN_S).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_tw.tween_property(_sweep, "modulate:a", 1.0, 0.12).set_delay(SWEEP_AT)
	_tw.tween_property(_sweep, "position:x", vw.x * 0.5 + 340.0, SWEEP_S).set_delay(SWEEP_AT).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tw.tween_property(_sweep, "modulate:a", 0.0, 0.18).set_delay(SWEEP_AT + SWEEP_S - 0.18)
	_tw.tween_method(_set_halo, 0.35, 0.6, SWEEP_S * 0.5).set_delay(SWEEP_AT + 0.15)
	_tw.tween_method(_set_halo, 0.6, 0.35, SWEEP_S * 0.6).set_delay(SWEEP_AT + 0.15 + SWEEP_S * 0.5)
	_tw.chain().tween_interval(maxf(0.0, HOLD_UNTIL - (SWEEP_AT + SWEEP_S)))
	_tw.chain().tween_callback(_morph)


func _set_halo(a: float) -> void:
	var sb := _halo.get_theme_stylebox("panel") as StyleBoxFlat
	if sb != null:
		sb.shadow_color = Color(GLOW, a)


## The mark's rect now, in our coordinates: the clip's (centred, a share of
## its width) or the code animation's logo.
func mark_rect() -> Rect2:
	if mode == "video":
		var r := Rect2(player.position, player.size)
		var side := minf(r.size.x * CLIP_MARK_FRAC, r.size.y * CLIP_MARK_FRAC * 1920.0 / 1200.0)
		return Rect2(r.get_center() - Vector2(side, side) / 2.0, Vector2(side, side))
	return _local_rect(_logo)


## A control's drawn rect (with its and its parents' scale) in our coordinates.
func _local_rect(c: Control) -> Rect2:
	var xf := c.get_global_transform()
	return get_global_transform().affine_inverse() * Rect2(xf.origin, c.size * xf.get_scale())


## The top bar's logo (host.top_bar's "Logo"), when it's on screen.
func header_logo() -> Control:
	var tb: Variant = _host.get("top_bar") if _host != null and is_instance_valid(_host) else null
	var l: Node = (tb as Node).get_node_or_null("Logo") if tb is Node else null
	if not l is Control:
		return null
	var c := l as Control
	return c if c.is_visible_in_tree() or (not c.is_inside_tree() and c.visible) else null


## The end: the mark flies into the top bar's logo as the slate fades off the
## home screen (input already goes to it), then the focus pulse. No top bar
## logo to fly to: a plain fade.
func _morph() -> void:
	if _done:
		return
	_done = true   # presses go to the home screen from here
	if _tw != null and _tw.is_valid():
		_tw.kill()
	var target := header_logo()
	if target == null:
		_done = false
		_finish(SKIP_S * 2.0)
		return
	var from := mark_rect()
	var to := _local_rect(target)
	_header_logo = target
	target.modulate.a = 0.0
	_tw = create_tween().set_parallel(true)
	if mode == "video":
		# The clip's last frame is the mark alone: redraw it at the same place
		# and size, and fly that.
		var t := TextureRect.new()
		t.name = "Flyer"
		t.texture = load("res://assets/logo-mark.svg")
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		t.position = from.position
		t.size = from.size
		add_child(t)
		flyer = t
		player.stop()
		player.visible = false
		_tw.tween_property(flyer, "position", to.position, MORPH_S).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
		_tw.tween_property(flyer, "size", to.size, MORPH_S).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	else:
		# Mark and wordmark fly together (the top bar has both, side by side):
		# scale the whole row about our origin so the mark lands on the logo.
		flyer = _center
		var tb: Node = target.get_parent()
		var word: Node = tb.get_node_or_null("Wordmark") if tb != null else null
		if word is CanvasItem:
			_header_word = word
			_header_word.modulate.a = 0.0
		var k := to.size.x / maxf(1.0, from.size.x)
		_center.pivot_offset = Vector2.ZERO
		var base := _center.position
		_tw.tween_property(_center, "scale", Vector2(k, k), MORPH_S).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
		_tw.tween_property(_center, "position", to.position - (from.position - base) * k, MORPH_S).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
		_tw.tween_method(_set_halo, 0.35, 0.0, MORPH_S * 0.5)
		if _sweep != null:
			_sweep.modulate.a = 0.0
	_tw.tween_property(_shade, "modulate:a", 0.0, MORPH_S * 0.8).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tw.chain().tween_callback(_landed)


## The mark is on the top bar's logo: show that one, pulse the focused control
## (`focused`: that control; default: whatever has focus now).
func _landed(focused: Control = null) -> void:
	_restore_header()
	if flyer != null:
		flyer.visible = false   # the top bar's own logo (and wordmark) take over
	if focused == null and is_inside_tree():
		focused = get_viewport().gui_get_focus_owner()
	var ring := _pulse_ring(focused)
	if ring == null:
		queue_free()
		return
	_tw = create_tween().set_parallel(true)
	_tw.tween_property(ring, "scale", Vector2.ONE * (1.0 + PULSE_GROW), PULSE_S).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tw.tween_property(ring, "modulate:a", 0.0, PULSE_S).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_tw.chain().tween_callback(queue_free)


## A ring in the accent colour around the focused control, its own shape.
func _pulse_ring(f: Control) -> Panel:
	if f == null or not is_instance_valid(f) or (f.is_inside_tree() and not f.is_visible_in_tree()):
		return null
	var r := _local_rect(f).grow(3.0)
	var radius := r.size.y / 2.0
	for sb_name in ["focus", "normal", "panel"]:
		var sb := f.get_theme_stylebox(sb_name) if f.has_theme_stylebox(sb_name) else null
		if sb is StyleBoxFlat and (sb as StyleBoxFlat).corner_radius_top_left > 0:
			radius = (sb as StyleBoxFlat).corner_radius_top_left + 3.0
			break
	var box := StyleBoxFlat.new()
	box.draw_center = false
	box.set_border_width_all(3)
	box.border_color = ThemeLib.color("accent")
	box.set_corner_radius_all(int(minf(radius, r.size.y / 2.0)))
	box.anti_aliasing = true
	var ring := Panel.new()
	ring.name = "FocusPulse"
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ring.add_theme_stylebox_override("panel", box)
	ring.position = r.position
	ring.size = r.size
	ring.pivot_offset = r.size / 2.0
	ring.modulate.a = 0.9
	add_child(ring)
	return ring


func _restore_header() -> void:
	for c in [_header_logo, _header_word]:
		if c != null and is_instance_valid(c):
			(c as CanvasItem).modulate.a = 1.0
	_header_logo = null
	_header_word = null


## Any button skips it. `now`: gone this frame (our window lost focus).
func skip(now := false) -> void:
	if now:
		_done = true
		if _tw != null and _tw.is_valid():
			_tw.kill()
		if player != null:
			player.stop()
		_restore_header()
		queue_free()
		return
	_finish(SKIP_S)


func _finish(out_s: float) -> void:
	if _done:
		return
	_done = true
	if _tw != null and _tw.is_valid():
		_tw.kill()
	_restore_header()
	_tw = create_tween()
	_tw.tween_property(self, "modulate:a", 0.0, out_s)
	_tw.tween_callback(queue_free)


func _exit_tree() -> void:
	_restore_header()
	if player != null:
		player.stop()


func _input(event: InputEvent) -> void:
	if _done or not event.is_pressed() or event.is_echo():
		return
	if event is InputEventJoypadButton or event is InputEventKey or event is InputEventMouseButton:
		skip()
		get_viewport().set_input_as_handled()
