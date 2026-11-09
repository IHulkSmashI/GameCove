extends VBoxContainer
## A labelled slider in a card: "Power limit (TDP) ...... 17 W", a gradient
## track, labelled ticks (5W 10W 15W ... with the current one lit) and the
## explanation, in the accent, while focused. Focused, the card gets the
## selected-row ring. Emits `changed` once the value has settled for a moment,
## so holding the d-pad doesn't send a write per step.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Texts := preload("res://scripts/ui/texts.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")

signal changed(value: float)

const SETTLE_S := 0.3
## At most this many tick labels under the track.
const MAX_LABELS := 6

var key := ""
var slider: HSlider
var unit := ""
var _value_label: Label
var _settle: Timer
var _hint: Label
var _ticks: Control
var _tick_values: Array = []


func setup(setting_key: String, title: String, lo: float, hi: float, current: float, step := 1.0, value_unit := " W") -> void:
	key = setting_key
	name = setting_key
	unit = value_unit
	add_theme_constant_override("separation", 0)

	var pad := MarginContainer.new()
	pad.name = "Card"
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right"]:
		pad.add_theme_constant_override("margin_" + side, 18)
	pad.add_theme_constant_override("margin_top", 14)
	pad.add_theme_constant_override("margin_bottom", 12)
	add_child(pad)
	var col := Kit.vbox(4)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_child(col)

	var head := Kit.hbox()
	var t := Kit.label(title)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.add_theme_font_override("font", ThemeLib.font("semibold"))
	head.add_child(t)
	_value_label = Kit.label("", "ValueLabel")
	_value_label.name = "Value"
	_value_label.add_theme_font_override("font", ThemeLib.font("mono_bold"))
	head.add_child(_value_label)
	col.add_child(head)

	slider = HSlider.new()
	slider.name = "Slider"
	slider.min_value = lo
	slider.max_value = hi
	slider.step = step
	slider.focus_mode = Control.FOCUS_ALL
	slider.custom_minimum_size = Vector2(0, 28)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.set_value_no_signal(clampf(current, lo, hi))
	slider.value_changed.connect(_on_value_changed)
	col.add_child(slider)

	_ticks = Control.new()
	_ticks.name = "Ticks"
	_ticks.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ticks.custom_minimum_size = Vector2(0, 16)
	_tick_values = tick_values(lo, hi, step)
	for v in _tick_values:
		_ticks.add_child(Kit.label(_fmt(v).replace(" ", ""), "MicroLabel"))
	_ticks.resized.connect(_place_ticks)
	col.add_child(_ticks)

	_hint = Kit.label(Texts.explain(key), "QuietLabel", true)
	_hint.name = "Hint"
	_hint.visible = false
	col.add_child(_hint)
	slider.focus_entered.connect(_refresh_focus)
	slider.focus_exited.connect(_refresh_focus)

	_settle = Timer.new()
	_settle.one_shot = true
	_settle.wait_time = SETTLE_S
	_settle.timeout.connect(func(): changed.emit(slider.value))
	add_child(_settle)
	_show(slider.value)
	_refresh_focus()


## Label values for the track: both ends plus round numbers between them
## (every 5 W on a 4-30 W range), at most MAX_LABELS, none crowding an end.
static func tick_values(lo: float, hi: float, step: float) -> Array:
	if hi <= lo:
		return [lo]
	var span := hi - lo
	var nice := step if step > 0.0 else 1.0
	for n in [1.0, 2.0, 5.0, 10.0, 20.0, 25.0, 50.0, 100.0, 250.0, 500.0]:
		if n >= step and span / n <= MAX_LABELS - 1:
			nice = n
			break
	var out: Array = [lo]
	var v := ceilf(lo / nice) * nice
	while v < hi - 0.001:
		if v - lo >= nice * 0.5 and hi - v >= nice * 0.5:
			out.append(v)
		v += nice
	out.append(hi)
	return out


## Puts each tick label under its spot on the track (the grabber's travel).
func _place_ticks() -> void:
	var lo := slider.min_value
	var span := maxf(0.0001, slider.max_value - lo)
	var knob := 0.0
	var g: Texture2D = slider.get_theme_icon("grabber")
	if g != null:
		knob = g.get_width()
	var w := _ticks.size.x - knob
	for i in _ticks.get_child_count():
		var l: Label = _ticks.get_child(i)
		l.size = l.get_minimum_size()
		var x := knob / 2.0 + w * (float(_tick_values[i]) - lo) / span - l.size.x / 2.0
		l.position = Vector2(clampf(x, 0.0, maxf(0.0, _ticks.size.x - l.size.x)), 0)


func set_value_quiet(v: float) -> void:
	slider.set_value_no_signal(clampf(v, slider.min_value, slider.max_value))
	_show(slider.value)


func value_text() -> String:
	return _value_label.text


func _on_value_changed(v: float) -> void:
	_show(v)
	if _settle.is_inside_tree():
		_settle.start()
	else:
		changed.emit(v)


func _fmt(v: float) -> String:
	return ("%d" % roundi(v) if is_equal_approx(slider.step, roundf(slider.step)) else "%.1f" % v) + unit


func _show(v: float) -> void:
	_value_label.text = _fmt(v)
	# Light the tick label nearest the value.
	var best := -1
	var dist := INF
	for i in _tick_values.size():
		var d := absf(float(_tick_values[i]) - v)
		if d < dist:
			dist = d
			best = i
	for i in _ticks.get_child_count():
		var l: Label = _ticks.get_child(i)
		var on := i == best
		l.add_theme_color_override("font_color", ThemeLib.color("accent") if on else ThemeLib.color("text_3"))
		l.add_theme_font_override("font", ThemeLib.mono(on, 1))
	_place_ticks()


func _refresh_focus() -> void:
	var f := slider.has_focus()
	_hint.visible = f and _hint.text != ""
	_hint.add_theme_color_override("font_color", ThemeLib.color("accent") if ThemeLib.is_dark() else ThemeLib.color("text_2"))
	queue_redraw()


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	draw_style_box(get_theme_stylebox("normal", &"RowButton"), r)
	if slider != null and slider.has_focus():
		draw_style_box(ThemeLib.row_focus(), r)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _value_label != null:
		_show(slider.value)
		_refresh_focus()
