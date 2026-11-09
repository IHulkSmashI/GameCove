extends RefCounted
## A maker's or store's logo next to its name, through device/brand.gd
## (bundled logos the owner allows, else the icon the user's own system has
## installed). Shown unmodified at a fixed height; when there's no logo the
## name stays plain text, so callers always keep the name.

const Brand := preload("res://scripts/device/brand.gd")

static var _tex := {}


## The logo as a texture, or null (makers and chips have none: text only).
static func texture(name: String) -> Texture2D:
	var path := Brand.logo_for(name)
	if path == "":
		return null
	if _tex.has(path):
		return _tex[path]
	var t: Texture2D = null
	if path.begins_with("res://"):
		t = load(path) as Texture2D
	else:
		var img := Image.new()
		var err := img.load_svg_from_buffer(FileAccess.get_file_as_bytes(path)) if path.ends_with(".svg") else img.load(path)
		if err == OK and not img.is_empty():
			t = ImageTexture.create_from_image(img)
	_tex[path] = t
	return t


## A TextureRect `px` high for the logo, or null when there is none.
static func rect(name: String, px := 22) -> TextureRect:
	var t := texture(name)
	if t == null:
		return null
	var r := TextureRect.new()
	r.name = "BrandLogo"
	r.texture = t
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.custom_minimum_size = Vector2(px, px)
	r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r
