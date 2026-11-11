extends VBoxContainer
## A labelled slider in a card: "Power limit (TDP) ...... 17 W", a gradient
## track, evenly spaced tick marks with labels (8W 15W 22W ... with the
## current one lit) and the explanation, in neutral text, while focused. Focused, the card gets the
## selected-row ring. Emits `changed` once the value has settled for a moment,
## so holding the d-pad doesn't send a write per step.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Texts := preload("res://scripts/ui/texts.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")

signal changed(value: float)

const SETTLE_S := 0.3
## This many tick labels under the track (one more when that makes them even).
const MAX_LABELS := 5
## Height of the tick marks under the track.
const TICK_H := 6

var key := ""
var slider: HSlider
var unit := ""
var _value_label: Label
var _settle: Timer
var _hint: Label
var _hint_gap: Control
var _ticks: Control
var _tick_values: Array = []
## Hide the explanation unless the slider has focus.
var collapse_hint := true
var title_label: Label
var _head: HBoxContainer
var _badge_box: HBoxContainer


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
	_head = head
	var t := Kit.label(title)
	title_label = t
	t.name = "Title"
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
	_ticks.custom_minimum_size = Vector2(0, TICK_H + 18)
	_tick_values = tick_values(lo, hi, step)
	for v in _tick_values:
		var l := Kit.label(_fmt(v).replace(" ", ""), "MicroLabel")
		l.add_theme_font_size_override("font_size", 13)
		_ticks.add_child(l)
	for v in _tick_values:
		var m := ColorRect.new()
		m.name = "Mark"
		m.mouse_filter = Control.MOUSE_FILTER_IGNORE
		m.size = Vector2(2, TICK_H)
		_ticks.add_child(m)
	_ticks.resized.connect(_place_ticks)
	col.add_child(_ticks)

	_hint_gap = Control.new()
	_hint_gap.name = "HintGap"
	_hint_gap.custom_minimum_size = Vector2(0, 8)
	_hint_gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_hint_gap)
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


## Label values for the track: evenly spaced from end to end (8, 15, 22, 28,
## 35 W on an 8-35 W range), each rounded to the slider's step so it names a
## value the slider really has. Round-number grids looked lopsided when the
## range didn't start on one (8, 20, 30, 35). When the range splits into four
## or five equal parts the labels are exactly even (0, 10, ... 50 % on a
## 0-50 % range in steps of 5, not 0, 15, 25, 40, 50), so the usual values
## each have their own label to light.
static func tick_values(lo: float, hi: float, step: float) -> Array:
	if hi <= lo:
		return [lo]
	var st := step if step > 0.0 else 1.0
	var steps := roundi((hi - lo) / st)
	var n := clampi(steps, 1, MAX_LABELS - 1)
	if steps > n and steps % n != 0 and steps % MAX_LABELS == 0:
		n = MAX_LABELS
	var out: Array = []
	for i in n + 1:
		var v := lo + roundf(float(steps) * i / n) * st
		v = clampf(v, lo, hi)
		if out.is_empty() or v - float(out[-1]) > st * 0.5:
			out.append(v)
	if float(out[-1]) < hi:
		out[-1] = hi
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
	var n := _tick_values.size()
	for i in n:
		var cx := knob / 2.0 + w * (float(_tick_values[i]) - lo) / span
		var l: Label = _ticks.get_child(i)
		l.size = l.get_minimum_size()
		var x := cx - l.size.x / 2.0
		# The end labels line up with the ends instead of hanging over them.
		if i == 0:
			x = maxf(0.0, cx - 4.0)
		elif i == n - 1:
			x = minf(_ticks.size.x - l.size.x, cx - l.size.x + 4.0)
		l.position = Vector2(clampf(x, 0.0, maxf(0.0, _ticks.size.x - l.size.x)), TICK_H + 2)
		var m: ColorRect = _ticks.get_child(n + i)
		m.position = Vector2(cx - 1.0, 0)


func set_value_quiet(v: float) -> void:
	slider.set_value_no_signal(clampf(v, slider.min_value, slider.max_value))
	_show(slider.value)


func value_text() -> String:
	return _value_label.text


## The line under the slider (shown while focused, or always with collapse_hint off).
func set_hint(text: String) -> void:
	_hint.text = text
	_refresh_focus()


func hint_text() -> String:
	return _hint.text


## A box right after the title for small chips (see ChoiceRow.badge_slot).
func badge_slot() -> HBoxContainer:
	if _badge_box == null:
		_badge_box = Kit.hbox(6)
		_badge_box.name = "Badges"
		_badge_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_badge_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		title_label.size_flags_horizontal = Control.SIZE_FILL
		_head.add_child(_badge_box)
		_head.move_child(_badge_box, title_label.get_index() + 1)
		var gap := Kit.spacer()
		gap.name = "BadgeGap"
		_head.add_child(gap)
		_head.move_child(gap, _badge_box.get_index() + 1)
	return _badge_box


## Locked: shown dimmed, the d-pad can't move it.
func set_locked(on: bool) -> void:
	slider.editable = not on
	slider.modulate.a = 0.45 if on else 1.0
	_value_label.modulate.a = 0.45 if on else 1.0


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
	# A tick lights only when the value is exactly on it (a "nearest" tick
	# lit under 20 W read as 22 W, an off-by-one bug).
	var best := lit_tick(_tick_values, v, slider.step)
	for i in _tick_values.size():
		var l: Label = _ticks.get_child(i)
		var on := i == best
		l.add_theme_color_override("font_color", ThemeLib.color("accent") if on else ThemeLib.color("text_2"))
		l.add_theme_font_override("font", ThemeLib.mono(on, 1))
		var m: ColorRect = _ticks.get_child(_tick_values.size() + i)
		m.color = ThemeLib.color("accent") if on else ThemeLib.soft(0.28)
	_place_ticks()


## Index of the tick the value sits on (within half a step), or -1.
static func lit_tick(ticks: Array, v: float, step: float) -> int:
	var tol := maxf(0.0001, (step if step > 0.0 else 1.0) * 0.5 - 0.0001)
	for i in ticks.size():
		if absf(float(ticks[i]) - v) < tol:
			return i
	return -1


func _refresh_focus() -> void:
	var f := slider.has_focus()
	_hint.visible = (f or not collapse_hint) and _hint.text != ""
	_hint_gap.visible = _hint.visible
	_hint.add_theme_color_override("font_color", ThemeLib.color("text_2"))
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
