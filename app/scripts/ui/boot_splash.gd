extends Control
## The boot intro over the home screen. If res://assets/boot/intro.ogv exists
## (the owner's clip, Theora, no audio) it plays that; otherwise a code
## animation of the GameCove mark (assets/logo-mark.svg, the same file as the
## repo's assets/logo.svg): it scales in, one soft cyan glow sweeps across the
## wordmark, then everything fades away, under 2 s, on the clip's slate
## background so the two look the same. To swap the clip see docs/BOOT_INTRO.md.
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
## Code animation: scale-in, glow sweep, hold, fade out (1.9 s in all).
const IN_S := 0.55
const SWEEP_AT := 0.45
const SWEEP_S := 0.7
const HOLD_UNTIL := 1.5
const OUT_S := 0.4
## Skipped: fade out this fast.
const SKIP_S := 0.15
## A clip runs at most this long, whatever its length.
const MAX_VIDEO_S := 6.0
const VIDEO_OUT_S := 0.3

## Where the clip is looked for (tests point it elsewhere).
static var video_path := "res://assets/boot/intro.ogv"

## "video" or "code".
var mode := ""
var player: VideoStreamPlayer
var _shade: ColorRect
var _mark: Control
var _halo: Panel
var _sweep: TextureRect
var _tw: Tween
var _done := false


## Adds the intro over `host` and plays it, unless motion is reduced. Returns it (or null).
static func play(host: Control) -> Control:
	if Motion.reduce:
		return null
	var s: Control = load("res://scripts/ui/boot_splash.gd").new()
	s.build(pick_mode())
	host.add_child(s)
	s._start()
	return s


## "video" when the clip is there, else "code".
static func pick_mode() -> String:
	return "video" if video_path != "" and (ResourceLoader.exists(video_path) or FileAccess.file_exists(video_path)) else "code"


func _init() -> void:
	name = "BootSplash"
	set_anchors_preset(Control.PRESET_FULL_RECT)
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
	player.finished.connect(_finish.bind(VIDEO_OUT_S))
	add_child(player)


func _build_code() -> void:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
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
		_tw.tween_interval(MAX_VIDEO_S)
		_tw.tween_callback(_finish.bind(VIDEO_OUT_S))
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
	_tw.chain().tween_property(self, "modulate:a", 0.0, OUT_S)
	_tw.chain().tween_callback(queue_free)


func _set_halo(a: float) -> void:
	var sb := _halo.get_theme_stylebox("panel") as StyleBoxFlat
	if sb != null:
		sb.shadow_color = Color(GLOW, a)


## Any button skips it. `now`: gone this frame (our window lost focus).
func skip(now := false) -> void:
	if now:
		_done = true
		if _tw != null and _tw.is_valid():
			_tw.kill()
		if player != null:
			player.stop()
		queue_free()
		return
	_finish(SKIP_S)


func _finish(out_s: float) -> void:
	if _done:
		return
	_done = true
	if _tw != null and _tw.is_valid():
		_tw.kill()
	_tw = create_tween()
	_tw.tween_property(self, "modulate:a", 0.0, out_s)
	_tw.tween_callback(queue_free)


func _exit_tree() -> void:
	if player != null:
		player.stop()


func _input(event: InputEvent) -> void:
	if _done or not event.is_pressed() or event.is_echo():
		return
	if event is InputEventJoypadButton or event is InputEventKey or event is InputEventMouseButton:
		skip()
		get_viewport().set_input_as_handled()
