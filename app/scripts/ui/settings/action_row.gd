extends VBoxContainer
## A settings row that does something when pressed (sign in, type a key, open
## a page): "Icon Title ...... value ›" in the same RowButton look as
## choice_row.gd, with its explanation under it while focused.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")

signal pressed

var key := ""
var button: Button
var title_label: Label
var value_label: Label
var _hint: Label
var _chevron: TextureRect
var _icon := ""
var _row: HBoxContainer
var _badge_box: HBoxContainer
## Keep the explanation visible even without focus.
var collapse_hint := true


func setup(row_key: String, title: String, value := "", hint := "", icon := "", show_chevron := true) -> void:
	key = row_key
	name = row_key
	_icon = icon
	add_theme_constant_override("separation", 6)
	button = Kit.button("", "RowButton")
	button.name = "Button"
	button.custom_minimum_size = Vector2(0, 52)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(func(): pressed.emit())
	button.focus_entered.connect(_refresh_focus)
	button.focus_exited.connect(_refresh_focus)
	add_child(button)
	var row := Kit.hbox(12)
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 18
	row.offset_right = -14
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(row)
	_row = row
	if icon != "":
		row.add_child(Icons.rect(icon, 22, ThemeLib.color("text_2")))
	title_label = Kit.label(title)
	title_label.name = "Title"
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title_label.size_flags_vertical = Control.SIZE_FILL
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_label.add_theme_font_override("font", ThemeLib.font("medium"))
	row.add_child(title_label)
	value_label = Kit.label(value, "ValueLabel")
	value_label.name = "Value"
	value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	value_label.size_flags_vertical = Control.SIZE_FILL
	value_label.add_theme_font_size_override("font_size", ThemeLib.SIZE_SMALL)
	row.add_child(value_label)
	if show_chevron:
		_chevron = Icons.rect("chevron_right", 18, ThemeLib.color("text_3"))
		row.add_child(_chevron)
	_hint = Kit.label(hint, "QuietLabel", true)
	_hint.name = "Hint"
	add_child(_hint)
	_refresh_focus()


func set_value(text: String, tone := "") -> void:
	value_label.text = text
	if tone == "":
		value_label.remove_theme_color_override("font_color")
	else:
		value_label.add_theme_color_override("font_color", ThemeLib.tone(tone) if tone != "muted" else ThemeLib.color("text_3"))


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
		title_label.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
		_row.add_child(_badge_box)
		_row.move_child(_badge_box, title_label.get_index() + 1)
		var gap := Kit.spacer()
		gap.name = "BadgeGap"
		_row.add_child(gap)
		_row.move_child(gap, _badge_box.get_index() + 1)
	return _badge_box


func _refresh_focus() -> void:
	_hint.visible = _hint.text != "" and (button.has_focus() or not collapse_hint)
	if _chevron != null:
		_chevron.texture = Icons.tex("chevron_right", 18, ThemeLib.color("text") if button.has_focus() else ThemeLib.color("text_3"))
