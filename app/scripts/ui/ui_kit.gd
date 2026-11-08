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


## A small pill with coloured text, for tile and page badges.
static func badge(text: String, tone := "") -> PanelContainer:
	var p := PanelContainer.new()
	p.theme_type_variation = "BadgePanel"
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var l := label(text)
	l.add_theme_font_size_override("font_size", 15)
	match tone:
		"good":
			l.add_theme_color_override("font_color", ThemeLib.ACCENT)
		"warn":
			l.add_theme_color_override("font_color", ThemeLib.WARN)
		"bad":
			l.add_theme_color_override("font_color", ThemeLib.BAD)
	p.add_child(l)
	return p
