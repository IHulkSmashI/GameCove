extends VBoxContainer
## A labelled slider ("Power limit (TDP) ...... 17 W") with a plain line under
## it. Emits `changed` once the value has settled for a moment, so holding the
## d-pad doesn't send a write per step.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Texts := preload("res://scripts/ui/texts.gd")

signal changed(value: float)

const SETTLE_S := 0.3

var key := ""
var slider: HSlider
var unit := ""
var _value_label: Label
var _settle: Timer


func setup(setting_key: String, title: String, lo: float, hi: float, current: float, step := 1.0, value_unit := " W") -> void:
	key = setting_key
	name = setting_key
	unit = value_unit
	add_theme_constant_override("separation", 4)

	var head := Kit.hbox()
	var t := Kit.label(title)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.add_theme_font_override("font", load("res://theme/gamecove_theme.gd").font("medium"))
	head.add_child(t)
	_value_label = Kit.label("", "ValueLabel")
	_value_label.name = "Value"
	head.add_child(_value_label)
	add_child(head)

	slider = HSlider.new()
	slider.name = "Slider"
	slider.min_value = lo
	slider.max_value = hi
	slider.step = step
	slider.focus_mode = Control.FOCUS_ALL
	slider.custom_minimum_size = Vector2(0, 36)
	slider.focus_entered.connect(func(): _value_label.add_theme_font_size_override("font_size", 22))
	slider.focus_exited.connect(func(): _value_label.remove_theme_font_size_override("font_size"))
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.set_value_no_signal(clampf(current, lo, hi))
	slider.value_changed.connect(_on_value_changed)
	add_child(slider)

	add_child(Kit.label(Texts.explain(key), "QuietLabel", true))

	_settle = Timer.new()
	_settle.one_shot = true
	_settle.wait_time = SETTLE_S
	_settle.timeout.connect(func(): changed.emit(slider.value))
	add_child(_settle)
	_show(slider.value)


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


func _show(v: float) -> void:
	_value_label.text = ("%d" % roundi(v) if is_equal_approx(slider.step, roundf(slider.step)) else "%.1f" % v) + unit
