extends VBoxContainer
## One setting: a wide row "Title ...... ‹ Value ›" with position dots, and a
## plain line under it. Left/right (d-pad, stick, arrow keys) step through
## values; A / click steps forward. Booleans are a switch (Off / On).

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Texts := preload("res://scripts/ui/texts.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")

signal changed(value: Variant)

var key := ""
var values: Array = []
var labels: Array = []
var index := 0
var button: Button
var icon_name := ""
var _value_label: Label
var _hint: Label
var _left: TextureRect
var _right: TextureRect
var _dots: HBoxContainer
var _switch: Panel
var _knob: Panel
var _is_bool := false
## Hide the explanation unless the row has focus.
var collapse_hint := true
## Optional: func(value) -> String for the line under the row (default:
## Texts.explain). An empty line takes no space.
var explain_fn: Callable = Callable()


func setup(setting_key: String, title: String, vals: Array, lbls: Array, current: Variant, icon := "") -> void:
	key = setting_key
	name = setting_key
	values = vals
	labels = lbls
	icon_name = icon
	index = maxi(0, values.find(current))
	_is_bool = values == [false, true]
	add_theme_constant_override("separation", 6)

	button = Kit.button("", "RowButton")
	button.name = "Button"
	button.custom_minimum_size = Vector2(0, 52)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.gui_input.connect(_on_gui_input)
	button.pressed.connect(func(): step(1))
	button.focus_entered.connect(_refresh_focus)
	button.focus_exited.connect(_refresh_focus)
	add_child(button)

	var row := Kit.hbox(12)
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 18
	row.offset_right = -14
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(row)
	if icon != "":
		row.add_child(Icons.rect(icon, 22, ThemeLib.color("text_2")))
	var t := Kit.label(title)
	t.name = "Title"
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	t.size_flags_vertical = Control.SIZE_FILL
	t.add_theme_font_override("font", ThemeLib.font("medium"))
	row.add_child(t)

	_value_label = Kit.label("", "ValueLabel")
	_value_label.name = "Value"
	_value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_value_label.size_flags_vertical = Control.SIZE_FILL
	if _is_bool:
		_value_label.add_theme_color_override("font_color", ThemeLib.color("text_2"))
		_value_label.add_theme_font_size_override("font_size", ThemeLib.SIZE_SMALL)
		row.add_child(_value_label)
		_switch = Panel.new()
		_switch.name = "Switch"
		_switch.custom_minimum_size = Vector2(46, 26)
		_switch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_switch.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_knob = Panel.new()
		_knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_knob.size = Vector2(20, 20)
		_knob.position = Vector2(3, 3)
		_switch.add_child(_knob)
		row.add_child(_switch)
	else:
		var val_col := Kit.vbox(2)
		val_col.alignment = BoxContainer.ALIGNMENT_CENTER
		val_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var vrow := Kit.hbox(6)
		vrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_left = Icons.rect("chevron_left", 18, ThemeLib.color("text_3"))
		_right = Icons.rect("chevron_right", 18, ThemeLib.color("text_3"))
		vrow.add_child(_left)
		vrow.add_child(_value_label)
		vrow.add_child(_right)
		val_col.add_child(vrow)
		_dots = Kit.hbox(4)
		_dots.alignment = BoxContainer.ALIGNMENT_CENTER
		_dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if values.size() > 1 and values.size() <= 8:
			for i in values.size():
				var d := Panel.new()
				d.custom_minimum_size = Vector2(5, 5)
				d.mouse_filter = Control.MOUSE_FILTER_IGNORE
				_dots.add_child(d)
		val_col.add_child(_dots)
		row.add_child(val_col)

	_hint = Kit.label("", "QuietLabel", true)
	_hint.name = "Hint"
	add_child(_hint)
	_refresh()


static func bool_row(setting_key: String, title: String, current: bool, icon := "") -> VBoxContainer:
	var r: VBoxContainer = load("res://scripts/ui/choice_row.gd").new()
	r.setup(setting_key, title, [false, true], ["Off", "On"], current, icon)
	return r


func value() -> Variant:
	return values[index] if not values.is_empty() else null


## Show a value without emitting `changed` (e.g. a service reported it).
func set_value_quiet(v: Variant) -> void:
	var i := values.find(v)
	if i >= 0:
		index = i
		_refresh()


func step(d: int) -> void:
	if values.size() < 2:
		return
	index = posmod(index + d, values.size())
	_refresh(true)
	changed.emit(values[index])


func hint_text() -> String:
	return _hint.text


func value_text() -> String:
	return _value_label.text


func _refresh(animate := false) -> void:
	var lbl: String = str(labels[index]) if index < labels.size() else str(value())
	_value_label.text = lbl
	_hint.text = explain_fn.call(value()) if explain_fn.is_valid() else Texts.explain(key, value())
	var acc := ThemeLib.color("accent")
	if _is_bool:
		var on: bool = value() == true
		var track := ThemeLib.box(acc if on else ThemeLib.soft(0.22), 999, 0, 0)
		_switch.add_theme_stylebox_override("panel", track)
		_knob.add_theme_stylebox_override("panel", ThemeLib.box(ThemeLib.color("on_accent") if on else ThemeLib.color("text"), 999, 0, 0))
		Motion.to(_knob, "position:x", 23.0 if on else 3.0, Motion.FAST if animate else 0.0)
	elif _dots != null:
		for i in _dots.get_child_count():
			var d: Panel = _dots.get_child(i)
			d.add_theme_stylebox_override("panel", ThemeLib.box(acc if i == index else ThemeLib.soft(0.22), 999, 0, 0))
		var multi := values.size() > 1
		_left.visible = multi
		_right.visible = multi
	_refresh_focus()


func _refresh_focus() -> void:
	# Only the focused row explains itself; the rest stay compact.
	_hint.visible = (button.has_focus() or not collapse_hint) and _hint.text != ""
	if _left == null:
		return
	var f := button.has_focus()
	var c: Color = ThemeLib.color("text") if f else ThemeLib.color("text_3")
	_left.texture = Icons.tex("chevron_left", 18, c)
	_right.texture = Icons.tex("chevron_right", 18, c)


func _on_gui_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_left", true):
		step(-1)
		button.accept_event()
	elif event.is_action_pressed("ui_right", true):
		step(1)
		button.accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _value_label != null:
		_refresh()
