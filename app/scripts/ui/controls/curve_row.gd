extends VBoxContainer
## A fan curve you edit with the d-pad. The card shows the curve (one point
## per temperature step, cool on the left, hot on the right) over the quiet
## floor. A starts editing: left / right pick a point, up / down change it
## in 5 % steps, A saves (emits `changed`), B puts it back. The curve never
## falls and never goes under the floor (the control's default, the quiet
## table), the same rule the fan fix enforces.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const TC := preload("res://scripts/ui/texts_controls.gd")

signal changed(value: Array)
## Editing started (true) or ended; the host updates its hint bar.
signal editing_changed(on: bool)

const STEP := 5.0
const CHART_H := 150.0

var button: Button
var points: Array = []        # current (possibly unsaved) values, 0..100
var saved: Array = []
var floor_points: Array = []
var selected := 0
var editing := false
var collapse_hint := true
var lo := 0.0
var hi := 100.0
var labels: Array = []
var title_label: Label
var _value_label: Label
var _hint: Label
var _head: HBoxContainer
var _badge_box: HBoxContainer
var _locked := false


class Chart extends Button:
	var host: Object

	func _draw() -> void:
		if host == null or host.points.is_empty():
			return
		var n: int = host.points.size()
		var left := 8.0
		var right := size.x - 8.0
		var top := 22.0
		var bottom := size.y - 22.0
		var line := ThemeLib.color("line")
		for f in [0.25, 0.5, 0.75, 1.0]:
			var y: float = bottom - (bottom - top) * f
			draw_line(Vector2(left, y), Vector2(right, y), line, 1.0)
		var font := ThemeLib.mono(true, 1)
		draw_string(font, Vector2(left, size.y - 4), TC.CURVE_COOL, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, ThemeLib.color("text_3"))
		draw_string(font, Vector2(right - 40, size.y - 4), TC.CURVE_HOT, HORIZONTAL_ALIGNMENT_RIGHT, 40, 11, ThemeLib.color("text_3"))
		var pts := PackedVector2Array()
		var flo := PackedVector2Array()
		for i in n:
			var x: float = left + (right - left) * (float(i) / maxf(1.0, n - 1))
			pts.append(Vector2(x, host.y_for(float(host.points[i]), top, bottom)))
			if i < host.floor_points.size():
				flo.append(Vector2(x, host.y_for(float(host.floor_points[i]), top, bottom)))
		var acc := ThemeLib.color("accent")
		var area := PackedVector2Array(pts)
		area.append(Vector2(right, bottom))
		area.append(Vector2(left, bottom))
		draw_colored_polygon(area, Color(acc, 0.10))
		if flo.size() == n and n > 1:
			for i in n - 1:
				_dashed(flo[i], flo[i + 1], ThemeLib.color("text_3"))
		if n > 1:
			draw_polyline(pts, acc, 3.0, true)
		for i in n:
			var sel: bool = i == host.selected and (host.editing or has_focus())
			if sel:
				draw_circle(pts[i], 11.0, Color(acc, 0.25), true, -1.0, true)
				draw_circle(pts[i], 7.0, acc, true, -1.0, true)
				draw_circle(pts[i], 7.0, ThemeLib.color("on_accent"), false, 2.0, true)
				var t := "%d%%" % roundi(float(host.points[i]))
				draw_string(font, pts[i] + Vector2(-20, -14), t, HORIZONTAL_ALIGNMENT_CENTER, 40, 12, acc)
			else:
				draw_circle(pts[i], 5.0, acc, true, -1.0, true)

	func _dashed(a: Vector2, b: Vector2, col: Color) -> void:
		var len := a.distance_to(b)
		var d := 6.0
		var t := 0.0
		while t < len:
			draw_line(a.lerp(b, t / len), a.lerp(b, minf(t + d * 0.6, len) / len), col, 1.0)
			t += d


func setup(title: String, desc: Dictionary) -> void:
	name = "CurveRow"
	add_theme_constant_override("separation", 0)
	lo = float(desc.get("min", 0.0))
	hi = float(desc.get("max", 100.0))
	labels = desc.get("labels", [])
	var d: Variant = desc.get("default")
	floor_points = (d as Array).duplicate() if d is Array else []
	var pad := MarginContainer.new()
	pad.name = "Card"
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right"]:
		pad.add_theme_constant_override("margin_" + side, 18)
	pad.add_theme_constant_override("margin_top", 14)
	pad.add_theme_constant_override("margin_bottom", 12)
	add_child(pad)
	var col := Kit.vbox(6)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_child(col)
	_head = Kit.hbox(10)
	title_label = Kit.label(title)
	title_label.name = "Title"
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.add_theme_font_override("font", ThemeLib.font("semibold"))
	_head.add_child(title_label)
	_value_label = Kit.label("", "ValueLabel")
	_value_label.name = "Value"
	_value_label.add_theme_font_override("font", ThemeLib.font("mono_bold"))
	_head.add_child(_value_label)
	col.add_child(_head)
	var chart := Chart.new()
	chart.host = self
	chart.name = "Chart"
	chart.flat = true
	chart.focus_mode = Control.FOCUS_ALL
	chart.custom_minimum_size = Vector2(0, CHART_H)
	chart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for st in ["focus", "normal", "hover", "pressed", "hover_pressed"]:
		chart.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	chart.gui_input.connect(_on_input)
	chart.pressed.connect(toggle_edit)
	chart.focus_entered.connect(_refresh)
	chart.focus_exited.connect(func():
		if editing:
			cancel()
		_refresh())
	col.add_child(chart)
	button = chart
	_hint = Kit.label("", "QuietLabel", true)
	_hint.name = "Hint"
	_hint.visible = false
	col.add_child(_hint)
	var v: Variant = desc.get("value")
	set_value_quiet(v if v is Array else floor_points)


func focusables() -> Array:
	return [button]


func y_for(v: float, top: float, bottom: float) -> float:
	return bottom - (bottom - top) * clampf((v - lo) / maxf(1.0, hi - lo), 0.0, 1.0)


func set_value_quiet(v: Array) -> void:
	points = []
	for x in v:
		points.append(float(x))
	saved = points.duplicate()
	selected = clampi(selected, 0, maxi(0, points.size() - 1))
	_refresh()


## A: start editing, or save while editing.
func toggle_edit() -> void:
	if _locked or points.is_empty():
		return
	if editing:
		editing = false
		saved = points.duplicate()
		changed.emit(points.duplicate())
	else:
		editing = true
	editing_changed.emit(editing)
	_refresh()


func cancel() -> void:
	if not editing:
		return
	editing = false
	points = saved.duplicate()
	editing_changed.emit(false)
	_refresh()


## Moves point `i` by `d` percent, keeping the curve rising and over the floor.
func nudge(i: int, d: float) -> void:
	if i < 0 or i >= points.size():
		return
	var v := clampf(float(points[i]) + d, lo, hi)
	if i < floor_points.size():
		v = maxf(v, float(floor_points[i]))
	points[i] = v
	for j in range(i + 1, points.size()):
		points[j] = maxf(float(points[j]), v)
	for j in range(i - 1, -1, -1):
		points[j] = minf(float(points[j]), v)
		if j < floor_points.size():
			points[j] = maxf(float(points[j]), float(floor_points[j]))
	_refresh()


func _on_input(event: InputEvent) -> void:
	if not editing:
		if event.is_action_pressed("ui_left", true) and selected > 0:
			selected -= 1
			_refresh()
			button.accept_event()
		elif event.is_action_pressed("ui_right", true) and selected < points.size() - 1:
			selected += 1
			_refresh()
			button.accept_event()
		return
	if event.is_action_pressed("ui_left", true):
		selected = maxi(0, selected - 1)
	elif event.is_action_pressed("ui_right", true):
		selected = mini(points.size() - 1, selected + 1)
	elif event.is_action_pressed("ui_up", true):
		nudge(selected, STEP)
	elif event.is_action_pressed("ui_down", true):
		nudge(selected, -STEP)
	elif event.is_action_pressed("ui_cancel"):
		cancel()
	else:
		return
	_refresh()
	button.accept_event()


func value_text() -> String:
	return _value_label.text


func set_hint(text: String) -> void:
	_hint.set_meta("base", text)
	_refresh()


func hint_text() -> String:
	return _hint.text


func set_locked(on: bool) -> void:
	_locked = on
	button.modulate.a = 0.45 if on else 1.0


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


func _refresh() -> void:
	if _value_label == null:
		return
	if points.is_empty():
		_value_label.text = "—"
	elif editing or button.has_focus():
		_value_label.text = TC.CURVE_POINT % [selected + 1, points.size(), roundi(float(points[selected]))]
	else:
		_value_label.text = "%d–%d%%" % [roundi(float(points[0])), roundi(float(points[-1]))]
	var base := str(_hint.get_meta("base", ""))
	_hint.text = TC.CURVE_HELP if editing else (base + (" " if base != "" else "") + "A: " + TC.CURVE_EDIT.to_lower() + ".")
	_hint.visible = (button.has_focus() or editing or not collapse_hint) and _hint.text != ""
	_hint.add_theme_color_override("font_color", ThemeLib.color("accent") if ThemeLib.is_dark() else ThemeLib.color("text_2"))
	button.queue_redraw()
	queue_redraw()


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	draw_style_box(get_theme_stylebox("normal", &"RowButton"), r)
	if button != null and (button.has_focus() or editing):
		draw_style_box(ThemeLib.row_focus(), r)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _value_label != null:
		_refresh()
