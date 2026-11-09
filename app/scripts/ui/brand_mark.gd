extends RefCounted
## A maker's, chip maker's or store's logo next to its name, through
## device/brand.gd: the bundled logo the owner allows (single-colour ones are
## tinted with the theme's text colour so they sit with the type), else the
## icon the user's own system has installed. When there's no logo it returns
## null and the caller keeps the name as plain text, so names never vanish.

const Brand := preload("res://scripts/device/brand.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")

static var _tex := {}


## The logo as a texture `px` tall (tinted with `tint`, or the theme's text
## colour when `tint` is transparent), or null when there is none.
static func texture(name: String, px := 22, tint := Color(0, 0, 0, 0)) -> Texture2D:
	if name.strip_edges() == "":
		return null
	var path := Brand.logo_for(name)
	if path == "":
		return null
	if tint.a <= 0.0:
		tint = ThemeLib.color("text")
	# Rasterise at 2x so the 1920x1200 layout (1.25x) stays crisp.
	var key := "%s|%d|%s" % [path, px, tint.to_html(false)]
	if _tex.has(key):
		return _tex[key]
	var t: Texture2D = null
	if Brand.bundled_logo_for(name) != "":
		t = Brand.logo_texture(name, px * 2, tint)
	else:
		var img := Image.new()
		var err := img.load_svg_from_buffer(FileAccess.get_file_as_bytes(path)) if path.ends_with(".svg") else img.load(path)
		if err == OK and not img.is_empty():
			t = ImageTexture.create_from_image(img)
	_tex[key] = t
	return t


## A TextureRect `px` high (width from the logo's aspect), or null when there
## is none.
static func rect(name: String, px := 22, tint := Color(0, 0, 0, 0)) -> TextureRect:
	var t := texture(name, px, tint)
	if t == null or t.get_height() <= 0:
		return null
	var r := TextureRect.new()
	r.name = "BrandLogo"
	r.texture = t
	r.tooltip_text = name
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var w := clampf(float(px) * t.get_width() / t.get_height(), px, px * 4.0)
	r.custom_minimum_size = Vector2(w, px)
	r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r
