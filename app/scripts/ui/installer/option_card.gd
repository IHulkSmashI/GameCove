extends Button
## A big selectable card for the installer (Easy / Custom, the startup modes):
## optional icon tile, a badge ("Recommended") with a quiet value on the right
## (time estimate), a title in caps, a description, and a footer line that
## turns into "• Selected" when chosen. Styled only from theme tokens (surface,
## line, accent, focus ring), so the shared restyle carries over. A / click /
## tap presses it.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const SKit := preload("res://scripts/ui/settings/kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Icons := preload("res://scripts/ui/icons.gd")

var key := ""
var selected := false
var title_label: Label
var footer: Label
var _footer_text := ""
var _selected_text := ""
var min_height := 200.0
var _content: VBoxContainer


## badge: [text, tone] or []; corner: small text top-right ("~1 MIN").
func setup(card_key: String, title: String, line: String, icon := "", badge: Array = [], corner := "",
		footer_text := "", selected_text := "") -> void:
	key = card_key
	name = "Card_" + card_key
	focus_mode = Control.FOCUS_ALL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	custom_minimum_size = Vector2(0, 200)
	min_height = 200.0
	_footer_text = footer_text
	_selected_text = selected_text if selected_text != "" else footer_text
	var col := Kit.vbox(12)
	col.name = "Content"
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.offset_left = 28
	col.offset_right = -28
	col.offset_top = 24
	col.offset_bottom = -22
	add_child(col)
	_content = col
	col.minimum_size_changed.connect(_fit)
	resized.connect(_fit)
	# Top row: icon tile on the left and the badge on the right, or (no icon)
	# the badge on the left and the mono corner value on the right.
	var top := Kit.hbox(12)
	top.name = "Top"
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var b: Control = null
	if not badge.is_empty():
		b = Kit.chip(badge[0], {"good": "star", "info": "sliders"}.get(badge[1], ""), badge[1])
		b.name = "Badge"
		b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if icon != "":
		var tile := PanelContainer.new()
		tile.name = "IconTile"
		tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tsb := ThemeLib.box(ThemeLib.soft(0.06), ThemeLib.radius("m"), 12, 12)
		tsb.border_color = ThemeLib.color("line_2")
		tsb.set_border_width_all(1)
		tile.add_theme_stylebox_override("panel", tsb)
		tile.add_child(Icons.rect(icon, 26, ThemeLib.color("accent")))
		top.add_child(tile)
		top.add_child(Kit.spacer())
		if b != null:
			top.add_child(b)
	else:
		if b != null:
			top.add_child(b)
		top.add_child(Kit.spacer())
	if corner != "":
		var c := Kit.micro(corner, "EyebrowLabel")
		c.name = "Corner"
		c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		if not badge.is_empty() and badge[1] != "good":
			c.add_theme_color_override("font_color", ThemeLib.color("text_2"))
		top.add_child(c)
	col.add_child(top)
	title_label = Kit.label(title.to_upper(), "LeadLabel", true)
	title_label.name = "Title"
	title_label.add_theme_font_override("font", ThemeLib.font("display"))
	col.add_child(title_label)
	var l := Kit.label(line, "CaptionLabel", true)
	l.name = "Line"
	l.add_theme_font_override("font", ThemeLib.font("regular"))
	l.add_theme_color_override("font_color", ThemeLib.color("text_2"))
	l.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(l)
	# Mono footer: "• SELECTED BY DEFAULT" in the accent once chosen.
	footer = Kit.label("", "MonoLabel")
	footer.name = "Footer"
	footer.add_theme_font_override("font", ThemeLib.mono(false, 1))
	footer.add_theme_font_size_override("font_size", ThemeLib.SIZE_MICRO + 1)
	col.add_child(footer)
	set_selected(false)


## Buttons don't size to their children: grow to fit the content.
func _fit() -> void:
	if _content == null:
		return
	var want := maxf(min_height, _content.get_combined_minimum_size().y + 46.0)
	if absf(custom_minimum_size.y - want) > 1.0:
		custom_minimum_size.y = want


func set_selected(on: bool) -> void:
	selected = on
	if footer != null:
		footer.text = ("●  " + _selected_text) if on else _footer_text
		footer.add_theme_font_override("font", ThemeLib.mono(on, 1))
		footer.add_theme_color_override("font_color", ThemeLib.color("accent") if on else ThemeLib.color("text_2"))
	_restyle()


var _styling := false


func _restyle() -> void:
	if _styling:
		return
	_styling = true
	var r := ThemeLib.radius("l")
	var base := ThemeLib.box(ThemeLib.color("surface"), r, 0, 0)
	base.border_color = ThemeLib.color("accent") if selected else ThemeLib.color("line")
	base.set_border_width_all(2 if selected else 1)
	var hover := base.duplicate() as StyleBoxFlat
	hover.bg_color = ThemeLib.color("surface_3")
	for st in ["normal", "pressed", "disabled"]:
		add_theme_stylebox_override(st, base)
	for st in ["hover", "hover_pressed"]:
		add_theme_stylebox_override(st, hover)
	add_theme_stylebox_override("focus", ThemeLib.focus_ring(r + 4, ThemeLib.color("accent"), 3))
	_styling = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and footer != null and not _styling:
		_styling = true
		footer.add_theme_color_override("font_color", ThemeLib.color("accent") if selected else ThemeLib.color("text_2"))
		_styling = false
		_restyle()
