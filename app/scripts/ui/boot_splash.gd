extends Control
## The boot splash: the logo mark and wordmark glow in (fade + slight scale),
## a light sweeps across, then everything fades away, about 1.3 s in all. It
## never takes input (the home screen behind it is usable at once) and is
## skipped under Reduce motion.

const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")

const IN_S := 0.45
const HOLD_S := 0.45
const OUT_S := 0.35

var _shade: ColorRect
var _mark: Control
var _sweep: ColorRect


## Adds the splash over `host` and plays it, unless motion is reduced.
static func play(host: Control) -> Control:
	if Motion.reduce:
		return null
	var s: Control = load("res://scripts/ui/boot_splash.gd").new()
	host.add_child(s)
	s._start()
	return s


func _init() -> void:
	name = "BootSplash"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 100
	_shade = ColorRect.new()
	_shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shade.color = ThemeLib.color("bg")
	add_child(_shade)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 0)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(row)
	_mark = row
	var glow := Panel.new()
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.custom_minimum_size = Vector2(72, 72)
	var gsb := ThemeLib.box(Color(ThemeLib.color("accent"), 0.10), 18, 0, 0)
	gsb.border_color = Color(ThemeLib.color("accent"), 0.7)
	gsb.set_border_width_all(2)
	gsb.shadow_color = ThemeLib.color("glow")
	gsb.shadow_size = 36
	glow.add_theme_stylebox_override("panel", gsb)
	var logo := TextureRect.new()
	logo.texture = load("res://assets/logo-mark.svg")
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.set_anchors_preset(Control.PRESET_FULL_RECT)
	logo.offset_left = 12
	logo.offset_top = 12
	logo.offset_right = -12
	logo.offset_bottom = -12
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.add_child(logo)
	row.add_child(glow)
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(22, 0)
	row.add_child(spacer)
	for part in [["GAME", "text"], ["COVE", "accent"]]:
		var l := Label.new()
		l.text = part[0]
		l.add_theme_font_override("font", ThemeLib.font("display"))
		l.add_theme_font_size_override("font_size", 56)
		l.add_theme_color_override("font_color", ThemeLib.color(part[1]))
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(l)

	# The light sweep: a soft vertical band that crosses the wordmark once.
	_sweep = ColorRect.new()
	_sweep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sweep.color = Color(1, 1, 1, 0.0)
	_sweep.size = Vector2(90, 220)
	_sweep.rotation = 0.25
	add_child(_sweep)


func _start() -> void:
	_mark.modulate.a = 0.0
	_mark.scale = Vector2(0.94, 0.94)
	_mark.resized.connect(func(): _mark.pivot_offset = _mark.size / 2.0)
	var t := create_tween()
	t.tween_property(_mark, "modulate:a", 1.0, IN_S)
	t.parallel().tween_property(_mark, "scale", Vector2.ONE, IN_S).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	var vw := get_viewport_rect().size
	_sweep.position = Vector2(vw.x * 0.5 - 360, vw.y * 0.5 - 110)
	t.tween_callback(func(): _sweep.color = Color(1, 1, 1, 0.10))
	t.tween_property(_sweep, "position:x", vw.x * 0.5 + 300, HOLD_S).set_trans(Tween.TRANS_SINE)
	t.tween_callback(func(): _sweep.color.a = 0.0)
	t.tween_property(self, "modulate:a", 0.0, OUT_S)
	t.tween_callback(queue_free)
