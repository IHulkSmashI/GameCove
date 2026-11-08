extends RefCounted
## Pieces shared by the settings pages and first-run setup: tinted cards,
## notes, state chips. Built from the design system (CardPanel, labels, badge).

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Badge := preload("res://scripts/ui/badge.gd")


## A CardPanel with an icon heading and an optional line under it.
## Returns [panel, body VBox].
static func card(title: String, icon: String, line := "") -> Array:
	var p := PanelContainer.new()
	p.theme_type_variation = "CardPanel"
	p.name = "Card_" + title.validate_node_name()
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var col := Kit.vbox(12)
	p.add_child(col)
	var head := Kit.icon_label(icon, title, "LeadLabel", ThemeLib.color("accent"), 22, false)
	head.name = "Heading"
	(head.get_child(1) as Label).add_theme_font_override("font", ThemeLib.font("semibold"))
	col.add_child(head)
	if line != "":
		var l := Kit.label(line, "QuietLabel", true)
		l.name = "Line"
		col.add_child(l)
	return [p, col]


## A note with an icon on a faint tone tint: "warn" for risks, "info" for
## facts, "good" for all-clear. Never focusable.
static func note(text: String, tone := "info", node_name := "Note") -> PanelContainer:
	var p := PanelContainer.new()
	p.name = node_name
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var c: Color = ThemeLib.tone(tone)
	var sb := ThemeLib.box(Color(c, 0.12), ThemeLib.radius("m"), 14, 10)
	sb.border_color = Color(c, 0.35)
	sb.set_border_width_all(1)
	p.add_theme_stylebox_override("panel", sb)
	var row := Kit.hbox(10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon: String = {"warn": "alert", "bad": "alert", "good": "check"}.get(tone, "info")
	var ic := Icons.rect(icon, 20, c)
	ic.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	row.add_child(ic)
	var l := Kit.label(text, "QuietLabel", true)
	l.name = "Text"
	l.add_theme_color_override("font_color", ThemeLib.color("text"))
	row.add_child(l)
	p.add_child(row)
	return p


## Small state chip (Signed in, Done, Skipped…).
static func chip(text: String, tone := "", icon := "") -> PanelContainer:
	return Badge.make({"kind": "state", "text": text, "short": text, "tone": tone, "icon": icon}, "tile")


## "Label    value" line for read-only facts.
static func fact(label: String, value: String, key_width := 150) -> HBoxContainer:
	var row := Kit.hbox(12)
	row.name = "Fact_" + label.validate_node_name()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var k := Kit.label(label, "QuietLabel")
	k.custom_minimum_size = Vector2(key_width, 0)
	row.add_child(k)
	var v := Kit.label(value, "", true)
	v.name = "Value"
	v.add_theme_font_override("font", ThemeLib.font("medium"))
	row.add_child(v)
	return row


## A plain full-width button for a card's main action.
static func action(text: String, icon := "", node_name := "") -> Button:
	var b := Kit.button(text)
	b.name = node_name if node_name != "" else text.validate_node_name()
	b.custom_minimum_size = Vector2(0, 52)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if icon != "":
		b.icon = Icons.tex(icon, 22, ThemeLib.color("text"))
	return b
