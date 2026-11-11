extends "res://scripts/ui/settings/page.gd"
## Appearance: theme with live mini previews, match game art colours, interface
## size (where the screen has room for more than one), reduce motion, quick menu side, interface sounds. These are UI prefs main.gd
## applies, so every change goes out through host.changed(key, value).

const Themes := preload("res://theme/themes.gd")
const Texts := preload("res://scripts/ui/texts.gd")

var swatches: HBoxContainer


func build() -> void:
	var values: Dictionary = host.values if host != null and "values" in host else {}
	var look := add_card("Look", "palette")
	var ids: Array = Themes.ORDER
	var theme_row := _ui_row(look, "theme", ids, ids.map(func(i): return Themes.NAMES[i]), values.get("theme", "cove"), "palette")
	swatches = previews(values.get("theme", "cove"))
	look.add_child(swatches)
	theme_row.changed.connect(func(v): mark(swatches, v))
	_ui_row(look, "match_art", [false, true], ["Off", "On"], values.get("match_art", true), "sparkle")
	# Interface size: only the sizes that look different on this screen
	var sizes: Array = values.get("interface_sizes", ["default"])
	if sizes.size() > 1:
		var cur: String = str(values.get("interface_size", "default"))
		_ui_row(look, "interface_size", sizes, sizes.map(func(i): return Texts.SIZE_LABELS[i]),
			cur if cur in sizes else "default", "screen")

	var feel := add_card("Feel", "motion")
	_ui_row(feel, "reduce_motion", [false, true], ["Off", "On"], values.get("reduce_motion", false), "motion")
	_ui_row(feel, "menu_side", ["right", "left"], ["Right", "Left"], values.get("menu_side", "right"), "screen")
	var lv: Array = Texts.SOUND_LEVELS
	_ui_row(feel, "ui_sounds", lv, lv.map(func(l): return Texts.SOUND_LABELS[l]), values.get("ui_sounds", "low"), "volume")
	feel.add_child(SKit.note(TS.SOUNDS_NOTE, "info", "SoundsNote"))


func _ui_row(box: Control, key: String, vals: Array, lbls: Array, current: Variant, icon: String) -> VBoxContainer:
	var r: VBoxContainer = ChoiceRow.new()
	r.setup(key, Texts.TITLES[key], vals, lbls, current, icon)
	r.changed.connect(func(v):
		if host != null and host.has_signal("changed"):
			host.changed.emit(key, v))
	add_row(box, r)
	return r


## One mini screen per theme in its own colours: backdrop, a card with an
## accent pill and two text lines, the name. The current one gets a ring.
static func previews(current: String) -> HBoxContainer:
	var row := Kit.hbox(12)
	row.name = "Swatches"
	for id in Themes.ORDER:
		row.add_child(preview(id))
	mark(row, current)
	return row


## One theme's mini screen, named after the theme id.
static func preview(id: String) -> PanelContainer:
	var t: Dictionary = Themes.get_theme(id)
	var p := PanelContainer.new()
	p.name = id
	p.custom_minimum_size = Vector2(0, 104)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var col := Kit.vbox(8)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mini := PanelContainer.new()
	mini.name = "Mini"
	mini.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mini.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mini.add_theme_stylebox_override("panel", ThemeLib.box(t["surface"], int(t["radius_s"]), 10, 8))
	var lines := Kit.vbox(5)
	lines.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pill := Panel.new()
	pill.custom_minimum_size = Vector2(34, 10)
	pill.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pill.add_theme_stylebox_override("panel", ThemeLib.box(t["accent"], 999, 0, 0))
	lines.add_child(pill)
	for w in [0.9, 0.6]:
		var h := Kit.hbox(0)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var l := Panel.new()
		l.custom_minimum_size = Vector2(0, 6)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.size_flags_stretch_ratio = w
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.add_theme_stylebox_override("panel", ThemeLib.box(Color(t["text"], 0.55 if w < 0.8 else 0.85), 999, 0, 0))
		h.add_child(l)
		var rest := Control.new()
		rest.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rest.size_flags_stretch_ratio = 1.0 - w
		rest.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(rest)
		lines.add_child(h)
	mini.add_child(lines)
	col.add_child(mini)
	var name_row := Kit.hbox(6)
	name_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for k in ["accent", "accent_2"]:
		var d := Panel.new()
		d.custom_minimum_size = Vector2(10, 10)
		d.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		d.mouse_filter = Control.MOUSE_FILTER_IGNORE
		d.add_theme_stylebox_override("panel", ThemeLib.box(t[k], 999, 0, 0))
		name_row.add_child(d)
	var lbl := Label.new()
	lbl.text = Themes.NAMES[id]
	lbl.add_theme_color_override("font_color", t["text"])
	lbl.add_theme_font_override("font", ThemeLib.font("semibold"))
	lbl.add_theme_font_size_override("font_size", ThemeLib.SIZE_CAPTION)
	name_row.add_child(lbl)
	col.add_child(name_row)
	p.add_child(col)
	return p


static func mark(row: HBoxContainer, id: String) -> void:
	for p in row.get_children():
		mark_one(p, String(p.name) == id)


## Ring (or not) on one preview, named after its theme id.
static func mark_one(p: Control, on: bool) -> void:
	var t: Dictionary = Themes.get_theme(p.name)
	var sb := ThemeLib.box(t["bg"], ThemeLib.radius("m"), 10, 10)
	sb.border_color = t["accent"] if on else Color(1, 1, 1, 0.10)
	sb.set_border_width_all(3 if on else 1)
	p.add_theme_stylebox_override("panel", sb)
