extends PanelContainer
## One badge: icon + text on a dark chip, coloured by meaning (Themes.TONES).
## Styles: "tile" (small, for covers), "chip" (game page), "solid" (a filled
## flag for the tile corner: sale, new, update).

const Themes := preload("res://theme/themes.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Icons := preload("res://scripts/ui/icons.gd")

## Chip tones remapped for the outline-chip look.
const CHIP_TONES := {"": "accent", "platinum": "good", "new": "accent"}

var spec: Dictionary = {}
var style := "tile"
var label: Label


static func make(b: Dictionary, badge_style := "tile") -> PanelContainer:
	var n: PanelContainer = load("res://scripts/ui/badge.gd").new()
	n.setup(b, badge_style)
	return n


func setup(b: Dictionary, badge_style := "tile") -> void:
	spec = b
	style = badge_style
	name = "Badge_" + String(b.get("kind", "x"))
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 4 if style != "chip" else 6)
	add_child(row)
	var tone_name: String = b.get("tone", "")
	if style == "chip":
		# Chips are colourful outlines: neutral facts read in the accent,
		# a Platinum rating as "works".
		tone_name = CHIP_TONES.get(tone_name, tone_name)
	var tone_col: Color = ThemeLib.color("accent") if tone_name == "accent" else ThemeLib.tone(tone_name)
	var solid := style == "solid"
	# Solid flags: the dark-theme tone as fill with near-black text in every theme.
	var flag: Color = Themes.TONES.get(b.get("tone", ""), Themes.TONES[""])
	var fg := Color("#0A0F16") if solid else tone_col
	# Tile pills always sit on their own dark chip (over art, or in a light
	# theme's list rows), so their text takes the bright dark-theme tones in
	# every theme: Light's deep tones on that chip were unreadable.
	if style == "tile":
		if tone_name == "accent":
			fg = tone_col if ThemeLib.is_dark() else tone_col.lightened(0.55)
		else:
			fg = Themes.TONES.get(tone_name, Themes.TONES[""])
	var chip := style == "chip"
	var icon_px := 12 if not chip else 16
	if b.get("icon", "") != "" and (chip or not solid):
		var ic := Icons.rect(b["icon"], icon_px, fg)
		ic.name = "Icon"
		row.add_child(ic)
	label = Label.new()
	label.name = "Text"
	label.text = b.get("short" if not chip else "text", b.get("text", ""))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", fg)
	# Tile pills are mono micro type; chips (spotlight, game page) are text.
	label.add_theme_font_override("font", ThemeLib.font("bold", true) if chip else ThemeLib.font("mono_bold"))
	label.add_theme_font_size_override("font_size", ThemeLib.SIZE_CAPTION - 1 if chip else 12)
	row.add_child(label)
	# An icon-only pill (a favourite's star on a tile) has no text.
	label.visible = label.text != ""
	var bg: Color = flag if solid else (Color(tone_col, 0.12) if chip else Color(0.02, 0.03, 0.05, 0.78))
	if chip and not ThemeLib.is_dark():
		bg = Color(tone_col, 0.10)
	var px := 6 if not chip else 12
	var py := 2 if not chip else 5
	var sb := ThemeLib.box(bg, 999 if chip else 6, px, py)
	if chip:
		sb.border_color = Color(tone_col, 0.48)
		sb.set_border_width_all(1)
	elif not solid:
		sb.border_color = Color(1, 1, 1, 0.14)
		sb.set_border_width_all(1)
	add_theme_stylebox_override("panel", sb)


func text() -> String:
	return label.text
