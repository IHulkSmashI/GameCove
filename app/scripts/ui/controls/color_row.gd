extends VBoxContainer
## A colour setting for the d-pad: a row of swatches (left / right picks one,
## it applies right away) and a Fine-tune hue track under it (left / right
## slides through every hue at full brightness, which is what LEDs show
## best). Same card look as SliderRow; the ring wraps the whole card while
## either part has focus. Emits `changed("#RRGGBB")` once the value has
## settled for a moment, so holding the d-pad doesn't send a write per step.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const TC := preload("res://scripts/ui/texts_controls.gd")

signal changed(value: String)

const SETTLE_S := 0.3
const SWATCHES := ["#00F0FF", "#2F6BFF", "#7000FF", "#C800FF", "#FF2E88", "#FF3B30", "#FF8A3D", "#FFD60A", "#3DFF6E", "#FFFFFF"]

var button: Button            # the swatch strip
var hue: HSlider
var value := "#00F0FF"
var index := -1               # swatch picked, -1 = a custom hue
var collapse_hint := true
var title_label: Label
var _chip: Panel
var _value_label: Label
var _hint: Label
var _head: HBoxContainer
var _badge_box: HBoxContainer
var _settle: Timer
var _locked := false


class Strip extends Button:
	var host: Object

	func _draw() -> void:
		if host == null:
			return
		var n: int = host.SWATCHES.size()
		var d := minf(30.0, (size.x - 8.0 * (n - 1)) / n)
		var gap := (size.x - d * n) / maxf(1.0, n - 1)
		for i in n:
			var c := Vector2(d / 2.0 + i * (d + gap), size.y / 2.0)
			var col := Color(host.SWATCHES[i])
			if i == host.index:
				draw_circle(c, d / 2.0 + 5.0, ThemeLib.color("ring") if has_focus() else ThemeLib.color("text_2"), false, 2.0, true)
			draw_circle(c, d / 2.0, col, true, -1.0, true)
			draw_circle(c, d / 2.0, Color(ThemeLib.color("line_2"), 0.9), false, 1.0, true)


func setup(title: String, current: String) -> void:
	name = "ColorRow"
	add_theme_constant_override("separation", 0)
	var pad := MarginContainer.new()
	pad.name = "Card"
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right"]:
		pad.add_theme_constant_override("margin_" + side, 18)
	pad.add_theme_constant_override("margin_top", 14)
	pad.add_theme_constant_override("margin_bottom", 12)
	add_child(pad)
	var col := Kit.vbox(10)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_child(col)

	_head = Kit.hbox(10)
	title_label = Kit.label(title)
	title_label.name = "Title"
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.add_theme_font_override("font", ThemeLib.font("semibold"))
	_head.add_child(title_label)
	_chip = Panel.new()
	_chip.name = "Chip"
	_chip.custom_minimum_size = Vector2(22, 22)
	_chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_head.add_child(_chip)
	_value_label = Kit.label("", "ValueLabel")
	_value_label.name = "Value"
	_value_label.add_theme_font_override("font", ThemeLib.font("mono_bold"))
	_head.add_child(_value_label)
	col.add_child(_head)

	var strip := Strip.new()
	strip.host = self
	strip.name = "Swatches"
	strip.flat = true
	strip.focus_mode = Control.FOCUS_ALL
	strip.custom_minimum_size = Vector2(0, 44)
	strip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for st in ["focus", "normal", "hover", "pressed", "hover_pressed"]:
		strip.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	strip.gui_input.connect(_on_strip_input)
	strip.pressed.connect(func(): _pick(posmod(index + 1, SWATCHES.size())))
	strip.focus_entered.connect(_refresh_focus)
	strip.focus_exited.connect(_refresh_focus)
	col.add_child(strip)
	button = strip

	var hrow := Kit.hbox(12)
	hrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var hl := Kit.micro(TC.COLOR_HUE)
	hl.add_theme_color_override("font_color", ThemeLib.color("text_3"))
	hrow.add_child(hl)
	hue = HSlider.new()
	hue.name = "Hue"
	hue.min_value = 0.0
	hue.max_value = 355.0
	hue.step = 5.0
	hue.focus_mode = Control.FOCUS_ALL
	hue.custom_minimum_size = Vector2(0, 28)
	hue.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hue.add_theme_stylebox_override("slider", _rainbow())
	for st in ["grabber_area", "grabber_area_highlight"]:
		hue.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	hue.value_changed.connect(_on_hue)
	hue.focus_entered.connect(_refresh_focus)
	hue.focus_exited.connect(_refresh_focus)
	hrow.add_child(hue)
	col.add_child(hrow)

	_hint = Kit.label(TC.COLOR_HELP, "QuietLabel", true)
	_hint.name = "Hint"
	_hint.visible = false
	col.add_child(_hint)

	_settle = Timer.new()
	_settle.one_shot = true
	_settle.wait_time = SETTLE_S
	_settle.timeout.connect(func(): changed.emit(value))
	add_child(_settle)
	set_value_quiet(current)
	_refresh_focus()


func focusables() -> Array:
	return [button, hue]


static func _rainbow() -> StyleBoxTexture:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 1.0 / 6.0, 2.0 / 6.0, 3.0 / 6.0, 4.0 / 6.0, 5.0 / 6.0, 1.0])
	g.colors = PackedColorArray([Color.RED, Color.YELLOW, Color.GREEN, Color.CYAN, Color.BLUE, Color.MAGENTA, Color.RED])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 256
	t.height = 8
	var sb := StyleBoxTexture.new()
	sb.texture = t
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb


## Shows a value without emitting `changed`.
func set_value_quiet(html: String) -> void:
	if not html.is_valid_html_color():
		return
	value = "#" + Color(html).to_html(false).to_upper()
	index = -1
	for i in SWATCHES.size():
		if Color(SWATCHES[i]).is_equal_approx(Color(value)):
			index = i
	hue.set_value_no_signal(roundf(Color(value).h * 360.0 / 5.0) * 5.0)
	_show()


func _show() -> void:
	_value_label.text = value
	_chip.add_theme_stylebox_override("panel", ThemeLib.box(Color(value), 999, 0, 0))
	button.queue_redraw()


func _pick(i: int) -> void:
	if _locked:
		return
	index = i
	value = SWATCHES[i]
	hue.set_value_no_signal(roundf(Color(value).h * 360.0 / 5.0) * 5.0)
	_show()
	_emit_later()


func _on_hue(h: float) -> void:
	if _locked:
		return
	value = "#" + Color.from_hsv(h / 360.0, 1.0, 1.0).to_html(false).to_upper()
	index = -1
	for i in SWATCHES.size():
		if Color(SWATCHES[i]).is_equal_approx(Color(value)):
			index = i
	_show()
	_emit_later()


func _emit_later() -> void:
	if _settle.is_inside_tree():
		_settle.start()
	else:
		changed.emit(value)


func _on_strip_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_left", true):
		_pick(posmod((index if index >= 0 else 0) - 1, SWATCHES.size()))
		button.accept_event()
	elif event.is_action_pressed("ui_right", true):
		_pick(posmod(index + 1, SWATCHES.size()))
		button.accept_event()


func value_text() -> String:
	return _value_label.text


func set_hint(text: String) -> void:
	_hint.text = text
	_refresh_focus()


func hint_text() -> String:
	return _hint.text


func set_locked(on: bool) -> void:
	_locked = on
	hue.editable = not on
	button.modulate.a = 0.45 if on else 1.0
	hue.modulate.a = 0.45 if on else 1.0


func badge_slot() -> HBoxContainer:
	if _badge_box == null:
		_badge_box = Kit.hbox(6)
		_badge_box.name = "Badges"
		_badge_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_badge_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		title_label.size_flags_horizontal = Control.SIZE_FILL
		_head.add_child(_badge_box)
		_head.move_child(_badge_box, 1)
		var gap := Kit.spacer()
		gap.name = "BadgeGap"
		_head.add_child(gap)
		_head.move_child(gap, 2)
	return _badge_box


func _focused() -> bool:
	return button.has_focus() or hue.has_focus()


func _refresh_focus() -> void:
	_hint.visible = (_focused() or not collapse_hint) and _hint.text != ""
	_hint.add_theme_color_override("font_color", ThemeLib.color("accent") if ThemeLib.is_dark() else ThemeLib.color("text_2"))
	button.queue_redraw()
	queue_redraw()


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	draw_style_box(get_theme_stylebox("normal", &"RowButton"), r)
	if button != null and _focused():
		draw_style_box(ThemeLib.row_focus(), r)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _value_label != null:
		_show()
		_refresh_focus()
