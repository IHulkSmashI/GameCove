extends VBoxContainer
## One setting: a wide button "Title ...... ‹ Value ›" and a plain line under it.
## Left/right (d-pad, stick, arrow keys) step through values; A / click steps
## forward. Booleans are just two values, Off and On.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Texts := preload("res://scripts/ui/texts.gd")

signal changed(value: Variant)

var key := ""
var values: Array = []
var labels: Array = []
var index := 0
var button: Button
var _value_label: Label
var _hint: Label


func setup(setting_key: String, title: String, vals: Array, lbls: Array, current: Variant) -> void:
	key = setting_key
	name = setting_key
	values = vals
	labels = lbls
	index = maxi(0, values.find(current))
	add_theme_constant_override("separation", 4)

	button = Kit.button("")
	button.name = "Button"
	button.custom_minimum_size = Vector2(0, 54)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.gui_input.connect(_on_gui_input)
	button.pressed.connect(func(): step(1))
	add_child(button)

	var row := Kit.hbox()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 16
	row.offset_right = -16
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(row)
	var t := Kit.label(title)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	t.size_flags_vertical = Control.SIZE_FILL
	row.add_child(t)
	_value_label = Kit.label("", "AccentLabel")
	_value_label.add_theme_font_size_override("font_size", 20)
	_value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_value_label.size_flags_vertical = Control.SIZE_FILL
	row.add_child(_value_label)

	_hint = Kit.label("", "QuietLabel", true)
	_hint.name = "Hint"
	add_child(_hint)
	_refresh()


static func bool_row(setting_key: String, title: String, current: bool) -> VBoxContainer:
	var r: VBoxContainer = load("res://scripts/ui/choice_row.gd").new()
	r.setup(setting_key, title, [false, true], ["Off", "On"], current)
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
	_refresh()
	changed.emit(values[index])


func hint_text() -> String:
	return _hint.text


func value_text() -> String:
	return _value_label.text


func _refresh() -> void:
	var lbl: String = str(labels[index]) if index < labels.size() else str(value())
	_value_label.text = "‹  %s  ›" % lbl if values.size() > 1 else lbl
	_hint.text = Texts.explain(key, value())


func _on_gui_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_left", true):
		step(-1)
		button.accept_event()
	elif event.is_action_pressed("ui_right", true):
		step(1)
		button.accept_event()
