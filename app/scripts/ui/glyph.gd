extends PanelContainer
## A controller button glyph (see Kit.glyph). Face buttons are coloured discs
## (A green, B red, X blue, Y yellow, Xbox style) with a dark letter; the
## Steam Deck set keeps its own look (monochrome faces, L1 / R1 / L2 / R2).
## Bumpers and triggers are small mono chips, the d-pad and left/right are a
## chip with arrows. Re-reads theme colours when the theme changes.
## main.gd calls use_set(Device.glyph_set()) so prompts match the handheld.

const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Icons := preload("res://scripts/ui/icons.gd")

const FACES := ["A", "B", "X", "Y"]
const ROUND := ["A", "B", "X", "Y", "GUIDE"]
const ICONS := {"GUIDE": "dots"}
## Chips drawn as text: what each shows.
const ARROWS := {"DPAD": "◂▸ / ▴▾", "LR": "◂ ▸", "UD": "▴ ▾"}
## Labels per glyph set (Buttons.SET_FILES names: xbox, deck).
const SET_LABELS := {
	"xbox": {"MENU": "Menu", "VIEW": "View"},
	"deck": {"LB": "L1", "RB": "R1", "LT": "L2", "RT": "R2", "MENU": "Menu", "VIEW": "View"},
	# PlayStation pads (DualSense, DualShock 4): the shapes, by position
	"ps": {"A": "✕", "B": "◯", "X": "□", "Y": "△", "LB": "L1", "RB": "R1", "LT": "L2", "RT": "R2", "MENU": "Options", "VIEW": "Create"},
}
const FACE_TOKENS := {"A": "face_a", "B": "face_b", "X": "face_x", "Y": "face_y"}

## The glyph set in use: "xbox", "deck" (Steam Deck, Steam Controller) or "ps".
## A handheld uses its own; a box by the TV follows the pad that is plugged in
## (set_for_pad, main.gd).
static var glyph_set := "xbox"

var button := ""
var primary := false
var small := false
var _label: Label
var _icon: TextureRect


static func use_set(set_name: String) -> void:
	glyph_set = set_name if SET_LABELS.has(set_name) else "xbox"


## The glyph set for a connected pad, from its name and USB vendor id (as
## Input.get_joy_name / get_joy_info give them): Sony pads show the shapes, a
## Steam Controller or Steam Deck pad Valve's labels, everything else Xbox
## letters (which is also what Steam Input and InputPlumber present by default).
static func set_for_pad(pad_name: String, vendor_id := 0) -> String:
	var n := pad_name.to_lower()
	if vendor_id == 0x054c or "dualsense" in n or "dualshock" in n or "ps5" in n or "ps4" in n or "playstation" in n or n.begins_with("sony"):
		return "ps"
	if vendor_id == 0x28de or "steam controller" in n or "steam deck" in n or n.begins_with("valve"):
		return "deck"
	return "xbox"


## The text a glyph shows on this set ("LB" -> "L1" on the Deck).
static func label_for(b: String) -> String:
	if ARROWS.has(b):
		return ARROWS[b]
	var labels: Dictionary = SET_LABELS.get(glyph_set, SET_LABELS["xbox"])
	return labels.get(b, b)


## Fill of a face-button glyph; transparent for everything else and on the
## Deck (its face buttons aren't coloured).
static func face_color(b: String) -> Color:
	if glyph_set in ["deck", "ps"] or not FACE_TOKENS.has(b):
		return Color(0, 0, 0, 0)
	return ThemeLib.color(FACE_TOKENS[b])


func setup(b: String, is_primary := false, is_small := false) -> void:
	button = b
	primary = is_primary
	small = is_small
	name = "Glyph_" + b
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var round := b in ROUND
	custom_minimum_size = Vector2(22, 22) if small else Vector2(26, 26)
	if ICONS.has(b):
		_icon = TextureRect.new()
		_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		_icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_icon)
	else:
		_label = Label.new()
		_label.text = label_for(b)
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		var face := b in FACES
		_label.add_theme_font_override("font", ThemeLib.font("mono_bold") if face else ThemeLib.mono(true, 1))
		# never under 11 px: a 5.5" 1080p panel can't show 10 px text readably (ui_scale.gd)
		var fs := (12 if small else 14) if round else 11
		_label.add_theme_font_size_override("font_size", fs)
		_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_label)
	_restyle()


var _styling := false


func _restyle() -> void:
	if _styling:
		return
	_styling = true
	var round := button in ROUND
	var face := face_color(button)
	var fg: Color
	var bg: Color
	var border := Color(0, 0, 0, 0)
	if face.a > 0.0:
		bg = face
		fg = ThemeLib.color("on_face")
	elif round:
		bg = ThemeLib.color("focus_fill") if primary else ThemeLib.soft(0.16)
		fg = ThemeLib.color("on_focus") if primary else ThemeLib.color("text")
		border = ThemeLib.soft(0.28) if not primary else border
	else:
		# Bumpers, triggers, d-pad: a small dark chip with a hairline.
		bg = ThemeLib.color("glass_2")
		fg = ThemeLib.color("text")
		border = ThemeLib.color("line_2")
	var r := 999 if round else 6
	var sb := ThemeLib.box(bg, r, 0 if round else (6 if small else 7), 0 if round else 2)
	if border.a > 0.0:
		sb.border_color = border
		sb.set_border_width_all(1)
	add_theme_stylebox_override("panel", sb)
	if _label != null:
		_label.add_theme_color_override("font_color", fg)
		_label.text = label_for(button)
	if _icon != null:
		_icon.texture = Icons.tex(ICONS[button], 18, fg)
	_styling = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and button != "":
		_restyle()
