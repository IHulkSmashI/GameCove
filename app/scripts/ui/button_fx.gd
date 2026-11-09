extends Control
## Extras for pill buttons, added by Kit.button / Kit.primary(): a soft glow
## behind primary buttons, a slight scale on focus, and, when wanted, the
## label drawn in capitals with a controller glyph inside the button
## ("(A) PLAY  >"). The Button keeps its own `text` and `icon` (so callers,
## tests and the hint bar read "Play"); this node only draws them differently.

const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")

const FOCUS_SCALE := 1.04
const GLYPH := 26.0
const GAP := 10.0

var button: Button
## Draw the label in capitals (primary buttons).
var caps := false
## Controller glyph drawn first inside the button ("" = none).
var glyph := ""
## Glow behind the button (primary buttons).
var glow := false
## Text / icon colour override (art-coloured primaries); a = 0 uses the theme.
var fg := Color(0, 0, 0, 0)
var _glow: Panel
var _base_min := Vector2.ZERO
var _drawing := false


static func attach(b: Button, opts: Dictionary = {}) -> Control:
	var fx: Control = b.get_node_or_null("Fx")
	if fx == null:
		fx = load("res://scripts/ui/button_fx.gd").new()
		fx.name = "Fx"
		fx.button = b
		fx._base_min = b.custom_minimum_size
		b.add_child(fx)
		fx._hook()
	for k in opts:
		fx.set(k, opts[k])
	fx._apply()
	return fx


func _hook() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.focus_entered.connect(_on_focus.bind(true))
	button.focus_exited.connect(_on_focus.bind(false))
	button.resized.connect(func(): button.pivot_offset = button.size / 2.0)
	button.draw.connect(_on_button_draw)


func _apply() -> void:
	var own := caps or glyph != ""
	for c in ["font_color", "font_focus_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color",
			"font_disabled_color", "icon_normal_color", "icon_focus_color", "icon_hover_color", "icon_pressed_color",
			"icon_hover_pressed_color", "icon_disabled_color"]:
		if own:
			button.add_theme_color_override(c, Color(0, 0, 0, 0))
		elif fg.a > 0.0:
			button.add_theme_color_override(c, fg)
		else:
			button.remove_theme_color_override(c)
	if glow and _glow == null:
		_glow = Panel.new()
		_glow.name = "Glow"
		_glow.show_behind_parent = true
		_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		button.add_child(_glow)
		button.move_child(_glow, 0)
	if _glow != null:
		_glow.visible = glow
		_style_glow()
	_fit.call_deferred()
	queue_redraw()


## The glow takes the button's own gradient start (art colour or accent).
func _style_glow() -> void:
	if _glow == null:
		return
	var col: Color = button.get_meta("glow_color", ThemeLib.color("glow"))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(col, 0.0)
	sb.set_corner_radius_all(999)
	sb.shadow_color = Color(col, col.a * 0.85)
	sb.shadow_size = int(ThemeLib.tok("glow_size")) - 2
	sb.shadow_offset = Vector2(0, 2)
	_glow.add_theme_stylebox_override("panel", sb)
	_glow.modulate.a = 1.0 if button.has_focus() else 0.45


func _on_focus(on: bool) -> void:
	if button.disabled:
		return
	button.pivot_offset = button.size / 2.0
	Motion.to(button, "scale", Vector2.ONE * (FOCUS_SCALE if on else 1.0), Motion.FAST)
	if _glow != null:
		Motion.to(_glow, "modulate:a", 1.0 if on else 0.45, Motion.FAST)


func _on_button_draw() -> void:
	if not _drawing:
		queue_redraw()
	# The label is drawn here in capitals (wider than the button's own text):
	# make sure the button is wide enough whenever it redraws (text changes).
	if (caps or glyph != "") and _label() != _fitted_for:
		_fit.call_deferred()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and button != null:
		_style_glow()
		_fit.call_deferred()


func _font() -> Font:
	return button.get_theme_font("font")


func _font_size() -> int:
	return button.get_theme_font_size("font_size")


func _label() -> String:
	return button.text.to_upper() if caps else button.text


func _color() -> Color:
	if button.disabled:
		return ThemeLib.color("text_3")
	if fg.a > 0.0:
		return fg
	var v := String(button.theme_type_variation)
	if v == "AccentButton":
		return ThemeLib.color("on_accent")
	return ThemeLib.color("text")


## Width the content needs: pads + glyph + text + icon.
func content_width() -> float:
	var sb := button.get_theme_stylebox("normal")
	var w := sb.get_margin(SIDE_LEFT) + sb.get_margin(SIDE_RIGHT)
	if glyph != "":
		w += GLYPH + GAP
	w += _font().get_string_size(_label(), HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size()).x
	if button.icon != null:
		w += GAP + _icon_size().x
	return w


func _icon_size() -> Vector2:
	var t := button.icon
	if t == null:
		return Vector2.ZERO
	var h := minf(float(t.get_height()), 22.0)
	return Vector2(t.get_width() * h / maxf(1.0, t.get_height()), h)


var _fitted_for := ""
var _fitted_w := -1.0


func _fit() -> void:
	if not is_instance_valid(button) or not (caps or glyph != ""):
		return
	# A minimum the caller set after attach() counts as the new floor.
	if absf(button.custom_minimum_size.x - _fitted_w) > 0.5:
		_base_min.x = button.custom_minimum_size.x
	_fitted_for = _label()
	_fitted_w = maxf(_base_min.x, ceilf(content_width()))
	button.custom_minimum_size.x = _fitted_w


func _draw() -> void:
	if not (caps or glyph != "") or button == null:
		return
	_drawing = true
	var col := _color()
	var f := _font()
	var fs := _font_size()
	var text := _label()
	var tw := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var total := tw
	if glyph != "":
		total += GLYPH + GAP
	var isz := _icon_size()
	if button.icon != null:
		total += GAP + isz.x
	var x := (size.x - total) / 2.0
	var cy := size.y / 2.0
	if glyph != "":
		_draw_glyph(Vector2(x + GLYPH / 2.0, cy))
		x += GLYPH + GAP
	var asc := f.get_ascent(fs)
	var desc := f.get_descent(fs)
	draw_string(f, Vector2(x, cy + (asc - desc) / 2.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
	x += tw
	if button.icon != null:
		x += GAP
		draw_texture_rect(button.icon, Rect2(Vector2(x, cy - isz.y / 2.0), isz), false, col)
	_drawing = false


## The glyph inside a button: on a primary, a dark disc with a light letter;
## elsewhere the coloured face (Glyph.face_color) with a dark letter.
func _draw_glyph(c: Vector2) -> void:
	var Glyph = load("res://scripts/ui/glyph.gd")
	var r := GLYPH / 2.0
	var primary := String(button.theme_type_variation) == "AccentButton"
	var bg: Color
	var ink: Color
	if primary:
		bg = Color(0.02, 0.03, 0.05, 0.88) if ThemeLib.is_dark() or _color().get_luminance() < 0.5 else Color(1, 1, 1, 0.92)
		ink = Color("#FFFFFF") if bg.get_luminance() < 0.5 else Color("#05070B")
	else:
		bg = Glyph.face_color(glyph)
		ink = ThemeLib.color("on_face")
		if bg.a <= 0.0:
			bg = ThemeLib.soft(0.18)
			ink = ThemeLib.color("text")
	draw_circle(c, r, bg, true, -1.0, true)
	var label: String = Glyph.label_for(glyph)
	var f := ThemeLib.font("mono_bold")
	var fs := 13
	var w := f.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(f, Vector2(c.x - w / 2.0, c.y + (f.get_ascent(fs) - f.get_descent(fs)) / 2.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ink)
