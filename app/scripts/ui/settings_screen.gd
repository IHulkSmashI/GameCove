extends Control
## Settings: look and feel (theme, art colours, reduce motion, quick menu
## side), sound, and about this device. Grouped in tinted cards. Emits
## `changed(key, value)`; main.gd applies and saves.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Texts := preload("res://scripts/ui/texts.gd")
const Themes := preload("res://theme/themes.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const ChoiceRow := preload("res://scripts/ui/choice_row.gd")
const Icons := preload("res://scripts/ui/icons.gd")

signal changed(key: String, value: Variant)

var rows := {}
var swatches: HBoxContainer
var top_target: Control
var _scroll: ScrollContainer
var _about: VBoxContainer


func _init() -> void:
	name = "Settings"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## values: {"theme", "match_art", "reduce_motion", "menu_side", "ui_sounds"};
## about: [[label, value], ...] lines for the About card.
func setup(values: Dictionary, about: Array = []) -> void:
	for c in get_children():
		Kit.drop(self, c)
	rows.clear()
	var margin := Kit.margin(0)
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 48)
	margin.add_theme_constant_override("margin_right", 48)
	margin.add_theme_constant_override("margin_top", 88)
	margin.add_theme_constant_override("margin_bottom", 58)
	add_child(margin)
	var root := Kit.vbox(14)
	margin.add_child(root)
	root.add_child(Kit.label("Settings", "TitleLabel"))
	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.follow_focus = true
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_scroll)
	var cols := Kit.hbox(24)
	cols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var pad := Kit.margin(6)
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_child(cols)
	_scroll.add_child(pad)

	var left := Kit.vbox(20)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 1.6
	cols.add_child(left)
	var right := Kit.vbox(20)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(right)

	var look := card("Look", "palette")
	left.add_child(look[0])
	var ids: Array = Themes.ORDER
	_add(look[1], "theme", ids, ids.map(func(i): return Themes.NAMES[i]), values.get("theme", "cove"), "palette")
	swatches = _swatches(values.get("theme", "cove"))
	look[1].add_child(swatches)
	_add(look[1], "match_art", [false, true], ["Off", "On"], values.get("match_art", true), "sparkle")
	_add(look[1], "reduce_motion", [false, true], ["Off", "On"], values.get("reduce_motion", false), "motion")
	_add(look[1], "menu_side", ["right", "left"], ["Right", "Left"], values.get("menu_side", "right"), "screen")

	var sound := card("Sound", "info")
	right.add_child(sound[0])
	var lv: Array = Texts.SOUND_LEVELS
	_add(sound[1], "ui_sounds", lv, lv.map(func(l): return Texts.SOUND_LABELS[l]), values.get("ui_sounds", "low"), "")

	var about_card := card("This device", "handheld")
	right.add_child(about_card[0])
	_about = about_card[1]
	set_about(about)

	var chain: Array = rows.values().map(func(r): return r.button)
	Kit.link_vertical(chain, top_target)


func card(title: String, icon: String) -> Array:
	var p := PanelContainer.new()
	p.theme_type_variation = "CardPanel"
	p.name = "Card_" + title.validate_node_name()
	var col := Kit.vbox(14)
	p.add_child(col)
	col.add_child(Kit.icon_label(icon, title, "HeaderLabel", ThemeLib.color("accent"), 24))
	return [p, col]


func set_about(lines: Array) -> void:
	if _about == null:
		return
	for i in range(_about.get_child_count() - 1, 0, -1):
		Kit.drop(_about, _about.get_child(i))
	for l in lines:
		var row := Kit.hbox(12)
		var k := Kit.label(l[0], "QuietLabel")
		k.custom_minimum_size = Vector2(110, 0)
		row.add_child(k)
		var v := Kit.label(str(l[1]), "", true)
		v.add_theme_font_override("font", ThemeLib.font("medium"))
		row.add_child(v)
		_about.add_child(row)


func set_top_target(c: Control) -> void:
	top_target = c
	var chain: Array = rows.values().map(func(r): return r.button)
	if not chain.is_empty():
		chain[0].focus_neighbor_top = chain[0].get_path_to(c)


func default_focus() -> Control:
	return rows["theme"].button if rows.has("theme") else null


func _add(box: VBoxContainer, key: String, vals: Array, lbls: Array, current: Variant, icon: String) -> void:
	var r: VBoxContainer = ChoiceRow.new()
	r.setup(key, Texts.TITLES[key], vals, lbls, current, icon)
	r.changed.connect(func(v):
		if key == "theme":
			_mark_swatch(v)
		changed.emit(key, v))
	box.add_child(r)
	rows[key] = r


func _swatches(current: String) -> HBoxContainer:
	var row := Kit.hbox(12)
	row.name = "Swatches"
	for id in Themes.ORDER:
		var t: Dictionary = Themes.get_theme(id)
		var p := PanelContainer.new()
		p.name = id
		p.custom_minimum_size = Vector2(0, 64)
		p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var col := Kit.vbox(6)
		var dots := Kit.hbox(5)
		for k in ["accent", "accent_2", "text"]:
			var d := Panel.new()
			d.custom_minimum_size = Vector2(14, 14)
			d.add_theme_stylebox_override("panel", ThemeLib.box(t[k], 999, 0, 0))
			dots.add_child(d)
		col.add_child(dots)
		var l := Label.new()
		l.text = Themes.NAMES[id]
		l.add_theme_color_override("font_color", t["text"])
		l.add_theme_font_override("font", ThemeLib.font("semibold"))
		l.add_theme_font_size_override("font_size", ThemeLib.SIZE_CAPTION)
		col.add_child(l)
		p.add_child(col)
		row.add_child(p)
	_mark_swatch(current, row)
	return row


func _mark_swatch(id: String, row: HBoxContainer = null) -> void:
	var r := row if row != null else swatches
	for p in r.get_children():
		var t: Dictionary = Themes.get_theme(p.name)
		var sb := ThemeLib.box(t["surface"], ThemeLib.radius("m"), 12, 10)
		sb.border_color = t["accent"] if p.name == id else Color(1, 1, 1, 0.08)
		sb.set_border_width_all(3 if p.name == id else 1)
		p.add_theme_stylebox_override("panel", sb)
