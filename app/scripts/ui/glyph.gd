extends PanelContainer
## A controller button glyph (see Kit.glyph). Re-reads theme colours when the
## theme changes, so prompts built once stay right in every theme.

const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Icons := preload("res://scripts/ui/icons.gd")

const ROUND := ["A", "B", "X", "Y", "GUIDE", "DPAD", "LR"]
const ICONS := {"GUIDE": "dots", "DPAD": "gamepad", "LR": "leftright"}

var button := ""
var primary := false
var small := false
var _label: Label
var _icon: TextureRect


func setup(b: String, is_primary := false, is_small := false) -> void:
	button = b
	primary = is_primary
	small = is_small
	name = "Glyph_" + b
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	custom_minimum_size = Vector2(22, 22) if small else Vector2(28, 28)
	if small:
		modulate.a = 0.6
	if ICONS.has(b):
		_icon = TextureRect.new()
		_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		_icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_icon)
	else:
		_label = Label.new()
		_label.text = b.capitalize() if b.length() > 2 else b
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_label.add_theme_font_override("font", ThemeLib.font("semibold"))
		var round := b in ROUND
		_label.add_theme_font_size_override("font_size", (12 if small else 14) if round else (11 if small else 13))
		_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_label)
	_restyle()


var _styling := false


func _restyle() -> void:
	if _styling:
		return
	_styling = true
	var round := button in ROUND
	var fg: Color = ThemeLib.color("on_focus") if primary else ThemeLib.color("text")
	var bg: Color = ThemeLib.color("focus_fill") if primary else ThemeLib.soft(0.16)
	var sb := ThemeLib.box(bg, 11 if small else 14, 0 if round else (6 if small else 8), 0)
	sb.border_color = ThemeLib.soft(0.28)
	sb.set_border_width_all(0 if primary else 1)
	add_theme_stylebox_override("panel", sb)
	if _label != null:
		_label.add_theme_color_override("font_color", fg)
	if _icon != null:
		_icon.texture = Icons.tex(ICONS[button], 18, fg)
	_styling = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and button != "":
		_restyle()
