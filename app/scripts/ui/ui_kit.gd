extends RefCounted
## Small builders shared by every screen.

const ThemeLib := preload("res://theme/gamecove_theme.gd")


static func label(text: String, variation := "", wrap := false) -> Label:
	var l := Label.new()
	l.text = text
	if variation != "":
		l.theme_type_variation = variation
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


static func vbox(sep := 12) -> VBoxContainer:
	var b := VBoxContainer.new()
	b.add_theme_constant_override("separation", sep)
	return b


static func hbox(sep := 12) -> HBoxContainer:
	var b := HBoxContainer.new()
	b.add_theme_constant_override("separation", sep)
	return b


static func spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func button(text: String, variation := "") -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_ALL
	if variation != "":
		b.theme_type_variation = variation
	return b


## Chain controls top to bottom. The ends point at `top` / themselves so focus
## can't wander off into whatever happens to be behind.
static func link_vertical(controls: Array, top: Control = null) -> void:
	for i in controls.size():
		var c: Control = controls[i]
		var up: Control = controls[i - 1] if i > 0 else (top if top != null else c)
		var down: Control = controls[i + 1] if i + 1 < controls.size() else c
		c.focus_neighbor_top = c.get_path_to(up)
		c.focus_neighbor_bottom = c.get_path_to(down)
		c.focus_neighbor_left = c.get_path_to(c)
		c.focus_neighbor_right = c.get_path_to(c)


## Chain controls left to right; ends stop at themselves.
static func link_horizontal(controls: Array) -> void:
	for i in controls.size():
		var c: Control = controls[i]
		c.focus_neighbor_left = c.get_path_to(controls[i - 1] if i > 0 else c)
		c.focus_neighbor_right = c.get_path_to(controls[i + 1] if i + 1 < controls.size() else c)


## Cover/hero art from a local file, scaled down to at most `max_size` so a
## 4K hero doesn't sit in video memory. Cached per path.
static var _art_cache := {}


static func load_art(path: String, max_size: Vector2i) -> Texture2D:
	if path == "" or path.contains("://") or not FileAccess.file_exists(path):
		return null
	var key := "%s@%dx%d" % [path, max_size.x, max_size.y]
	if _art_cache.has(key):
		return _art_cache[key]
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		_art_cache[key] = null
		return null
	var s := minf(1.0, minf(float(max_size.x) / img.get_width(), float(max_size.y) / img.get_height()))
	if s < 1.0:
		img.resize(maxi(1, int(img.get_width() * s)), maxi(1, int(img.get_height() * s)), Image.INTERPOLATE_LANCZOS)
	var tex := ImageTexture.create_from_image(img)
	_art_cache[key] = tex
	return tex


## A small badge with coloured text (older call; see badge.gd / badges.gd).
static func badge(text: String, tone := "") -> PanelContainer:
	return load("res://scripts/ui/badge.gd").make({"kind": "text", "text": text, "short": text, "tone": tone, "icon": ""}, "tile")


## A controller button glyph: "A", "B", "X", "Y" (round), "LB", "RB", "LT",
## "RT", "MENU", "VIEW" (pill), "GUIDE" (round, dots), "DPAD", "LR" (icons).
## `primary` fills it solid, for the main action of a screen.
static func glyph(button: String, primary := false, small := false) -> Control:
	var p := PanelContainer.new()
	p.name = "Glyph_" + button
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var round := button in ["A", "B", "X", "Y", "GUIDE", "DPAD", "LR"]
	var fg: Color = ThemeLib.color("on_focus") if primary else ThemeLib.color("text")
	var bg: Color = ThemeLib.color("focus_fill") if primary else ThemeLib.soft(0.16)
	var sb := ThemeLib.box(bg, 11 if small else 14, 0 if round else (6 if small else 8), 0)
	sb.border_color = ThemeLib.soft(0.28)
	sb.set_border_width_all(0 if primary else 1)
	p.add_theme_stylebox_override("panel", sb)
	p.custom_minimum_size = Vector2(22, 22) if small else Vector2(28, 28)
	if small:
		p.modulate.a = 0.6
	var icon := {"GUIDE": "dots", "DPAD": "gamepad", "LR": "sort"}
	if icon.has(button):
		var ic: TextureRect = load("res://scripts/ui/icons.gd").rect(icon[button], 18, fg)
		ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		p.add_child(ic)
		return p
	var l := Label.new()
	l.text = button.capitalize() if button.length() > 2 else button
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_override("font", ThemeLib.font("semibold"))
	l.add_theme_font_size_override("font_size", (12 if small else 14) if round else (11 if small else 13))
	l.add_theme_color_override("font_color", fg)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(l)
	return p


## "(A) Open  (B) Back" style prompt row. `prompts` = [[button, label], ...];
## the first is drawn as the primary action.
static func prompts(list: Array) -> HBoxContainer:
	var row := hbox(22)
	row.name = "Prompts"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for i in list.size():
		var item := hbox(8)
		item.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var buttons: Array = list[i][0] if list[i][0] is Array else [list[i][0]]
		for b in buttons:
			item.add_child(glyph(b, i == 0))
		var l := label(list[i][1], "CaptionLabel")
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		item.add_child(l)
		row.add_child(item)
	return row


## Plain text of a prompt row (tests, accessibility).
static func prompts_text(row: Control) -> String:
	var parts: Array[String] = []
	for item in row.get_children():
		var bits: Array[String] = []
		for c in item.get_children():
			if c is Label:
				bits.append(c.text)
			elif c is PanelContainer and c.name.begins_with("Glyph_"):
				bits.append(String(c.name).substr(6))
		parts.append(" ".join(bits))
	return "  ".join(parts)


## Icon + label in a row.
static func icon_label(icon: String, text: String, variation := "", icon_color: Color = Color(0, 0, 0, 0), size := 20, wrap := true) -> HBoxContainer:
	var row := hbox(10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var col := icon_color if icon_color.a > 0.0 else ThemeLib.color("text_2")
	row.add_child(load("res://scripts/ui/icons.gd").rect(icon, size, col))
	var l := label(text, variation, wrap)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(l)
	return row


## Full-rect child that ignores the mouse.
static func fill(c: Control) -> Control:
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func margin(all := 0, h := -1, v := -1) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", h if h >= 0 else all)
	m.add_theme_constant_override("margin_right", h if h >= 0 else all)
	m.add_theme_constant_override("margin_top", v if v >= 0 else all)
	m.add_theme_constant_override("margin_bottom", v if v >= 0 else all)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return m


## Remove and delete a child. Outside the scene tree (tests) there's no frame
## to run queue_free, so it's freed at once.
static func drop(parent: Node, c: Node) -> void:
	if c.get_parent() == parent:
		parent.remove_child(c)
	if parent.is_inside_tree():
		c.queue_free()
	else:
		c.free()


## Restyle an accent button in `col` (e.g. the game art's colour), keeping
## its text and icon readable (ArtColor.on_color picks dark or light).
static func accent_button(b: Button, col: Color) -> void:
	var a := col if col.a > 0.0 else ThemeLib.color("accent")
	var on: Color = load("res://theme/art_color.gd").on_color(a)
	var states := {"normal": a, "hover": a.lightened(0.1), "pressed": a.darkened(0.1), "hover_pressed": a.darkened(0.1)}
	for st in states:
		b.add_theme_stylebox_override(st, ThemeLib.box(states[st], -1, 18, 10))
	var f := ThemeLib.box(a.lightened(0.14), -1, 18, 10)
	f.border_color = ThemeLib.color("text")
	f.set_border_width_all(3)
	f.set_expand_margin_all(3)
	b.add_theme_stylebox_override("focus", f)
	for c in ["font_color", "font_focus_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color",
			"icon_normal_color", "icon_focus_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color"]:
		b.add_theme_color_override(c, on)
