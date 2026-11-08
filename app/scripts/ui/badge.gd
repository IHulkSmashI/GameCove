extends PanelContainer
## One badge: icon + text on a dark chip, coloured by meaning (Themes.TONES).
## Styles: "tile" (small, for covers), "chip" (game page), "solid" (a filled
## flag for the tile corner: sale, new, update).

const Themes := preload("res://theme/themes.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Icons := preload("res://scripts/ui/icons.gd")

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
	row.add_theme_constant_override("separation", 5 if style == "tile" else 8)
	add_child(row)
	var tone_col: Color = ThemeLib.tone(b.get("tone", ""))
	var solid := style == "solid"
	# Solid flags: the dark-theme tone as fill with near-black text in every theme.
	var flag: Color = Themes.TONES.get(b.get("tone", ""), Themes.TONES[""])
	var fg := Color("#0A0F16") if solid else tone_col
	var icon_px := 14 if style != "chip" else 18
	if b.get("icon", "") != "":
		var ic := Icons.rect(b["icon"], icon_px, fg)
		ic.name = "Icon"
		row.add_child(ic)
	label = Label.new()
	label.name = "Text"
	label.text = b.get("short" if style != "chip" else "text", b.get("text", ""))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", fg)
	label.add_theme_font_override("font", ThemeLib.font("semibold" if style != "chip" else "medium", true))
	label.add_theme_font_size_override("font_size", ThemeLib.SIZE_MICRO if style != "chip" else ThemeLib.SIZE_SMALL)
	row.add_child(label)
	var bg: Color = flag if solid else ThemeLib.color("chip")
	var px := 7 if style != "chip" else 12
	var py := 3 if style != "chip" else 6
	var sb := ThemeLib.box(bg, 999 if style == "chip" else 6, px, py)
	if style == "chip":
		sb.border_color = Color(tone_col, 0.35)
		sb.set_border_width_all(1)
	add_theme_stylebox_override("panel", sb)


func text() -> String:
	return label.text
