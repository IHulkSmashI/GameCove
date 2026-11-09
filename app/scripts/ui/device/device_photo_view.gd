extends VBoxContainer
## A real device photo (DevicePhoto.photo_for) with rounded corners, fitted
## inside its box, and a one-line credit under it ("Photo: <author>,
## <license>") that opens the Commons file page through the host's link
## opener. Built only when there is a photo; otherwise callers keep the
## drawing. Look-neutral on purpose: the panels' restyle owns the framing.
##
##   DevicePhotoView.make(photo, height, open_link) -> DevicePhotoView or null
##     photo: {"path", "credit"} from DevicePhoto; open_link: Callable(url)
##     A family row's photo also has "caption" / "pictured" ("MSI Claw (model
##     not identified)", "Pictured: MSI Claw 8 AI+"), shown over the credit.
##     A bundled picture (res://assets/device_photos/) has credit {}: no credit
##     line at all (the button stays, hidden and disabled, so callers that
##     check credit.disabled skip it).
##
## Makers' pictures often sit in a big plain margin (square store shots, wide
## banners). The view crops that margin at display time (subject_rect: the
## box of pixels that differ from the corner colour), so the handheld fills the
## frame; the cached file stays exactly as the maker served it.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Photo := preload("res://scripts/device/photo.gd")
const TPhoto := preload("res://scripts/ui/texts_photo.gd")
const RoundShader := preload("res://shaders/rounded_art.gdshader")

var image: TextureRect
var credit: Button
var caption: Label
var page_url := ""
var _mat: ShaderMaterial


static func make(photo: Dictionary, height: float, open_link: Callable) -> Control:
	var path := str(photo.get("path", ""))
	var tex := load_trimmed(path)
	if tex == null:
		return null
	var v = load("res://scripts/ui/device/device_photo_view.gd").new()
	v._build(tex, photo.get("credit", {}) if photo.get("credit") is Dictionary else {}, height, open_link)
	var cap := str(photo.get("caption", ""))
	if cap != "":
		v._add_caption(cap, str(photo.get("pictured", "")))
	return v


static var _trim_cache := {}

## The photo with its plain margin cropped, at most 1200 px; null when the file
## is missing or unreadable. Cached per path and modification time.
static func load_trimmed(path: String) -> Texture2D:
	var bundled := path.begins_with(Photo.BUNDLED_DIR) and not path.contains("..")
	if path == "" or (path.contains("://") and not bundled) or not FileAccess.file_exists(path):
		return null
	var key := "%s@%d" % [path, FileAccess.get_modified_time(path)]
	if _trim_cache.has(key):
		return _trim_cache[key]
	var img := _load_bundled(path) if bundled else Image.load_from_file(path)
	if img == null or img.is_empty():
		return null
	var r := subject_rect(img)
	if r.size != img.get_size():
		img = img.get_region(r)
	var s := minf(1.0, 1200.0 / maxf(img.get_width(), img.get_height()))
	if s < 1.0:
		img.resize(maxi(1, int(img.get_width() * s)), maxi(1, int(img.get_height() * s)), Image.INTERPOLATE_LANCZOS)
	var tex := ImageTexture.create_from_image(img)
	_trim_cache[key] = tex
	return tex


## A picture shipped in the pck: read the raw bytes (export_presets.cfg
## force-includes them) and decode by sniffed type, so it works the same in
## the editor and an exported build.
static func _load_bundled(path: String) -> Image:
	var b := FileAccess.get_file_as_bytes(path)
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	match Photo.sniff_image(b):
		"webp":
			err = img.load_webp_from_buffer(b)
		"png":
			err = img.load_png_from_buffer(b)
		"jpg":
			err = img.load_jpg_from_buffer(b)
	return img if err == OK else null


## The box holding the subject: pixels that differ from the background (the
## four corners' colour, or transparent), on a small copy, plus a 4 % margin.
## The whole image when the corners disagree (a photo, not a plain backdrop)
## or the subject already fills nearly all of it.
static func subject_rect(img: Image) -> Rect2i:
	var full := Rect2i(Vector2i.ZERO, img.get_size())
	if img.get_width() < 8 or img.get_height() < 8:
		return full
	var small: Image = img.duplicate()
	if small.is_compressed():
		small.decompress()
	small.convert(Image.FORMAT_RGBA8)
	var k := minf(1.0, 160.0 / maxf(small.get_width(), small.get_height()))
	small.resize(maxi(8, int(small.get_width() * k)), maxi(8, int(small.get_height() * k)), Image.INTERPOLATE_BILINEAR)
	var w := small.get_width()
	var h := small.get_height()
	var corners := [small.get_pixel(0, 0), small.get_pixel(w - 1, 0), small.get_pixel(0, h - 1), small.get_pixel(w - 1, h - 1)]
	var bg: Color = corners[0]
	for c in corners:
		if _dist(c, bg) > 0.08:
			return full
	var x0 := w
	var y0 := h
	var x1 := -1
	var y1 := -1
	for y in h:
		for x in w:
			var c := small.get_pixel(x, y)
			if c.a < 0.1 or _dist(c, bg) < 0.1:
				continue
			x0 = mini(x0, x)
			y0 = mini(y0, y)
			x1 = maxi(x1, x)
			y1 = maxi(y1, y)
	if x1 < 0:
		return full
	var sx := float(img.get_width()) / w
	var sy := float(img.get_height()) / h
	var pad := int(0.04 * maxf((x1 - x0 + 1) * sx, (y1 - y0 + 1) * sy))
	var r := Rect2i(int(x0 * sx) - pad, int(y0 * sy) - pad, int((x1 - x0 + 1) * sx) + 2 * pad, int((y1 - y0 + 1) * sy) + 2 * pad).intersection(full)
	if r.get_area() >= int(full.get_area() * 0.9) or r.size.x < 4 or r.size.y < 4:
		return full
	return r


static func _dist(a: Color, b: Color) -> float:
	if a.a < 0.1 and b.a < 0.1:
		return 0.0
	return maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), maxf(absf(a.b - b.b), absf(a.a - b.a)))


## "MSI Claw (model not identified)" over the credit, with what's pictured.
func _add_caption(text: String, pictured: String) -> void:
	caption = Kit.label(text if pictured == "" else "%s\n%s" % [text, pictured], "CaptionLabel", true)
	caption.name = "FamilyCaption"
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.add_theme_color_override("font_color", ThemeLib.color("text_2"))
	add_child(caption)
	move_child(caption, credit.get_index())


func _build(tex: Texture2D, cr: Dictionary, height: float, open_link: Callable) -> void:
	name = "DevicePhoto"
	add_theme_constant_override("separation", 6)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	image = TextureRect.new()
	image.name = "PhotoImage"
	image.texture = tex
	image.custom_minimum_size = Vector2(0, height)
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	_mat.shader = RoundShader
	_mat.set_shader_parameter("radius", float(ThemeLib.radius("m")))
	image.material = _mat
	image.resized.connect(_fit_mask)
	add_child(image)
	page_url = str(cr.get("page_url", ""))
	credit = Button.new()
	credit.name = "PhotoCredit"
	credit.text = Photo.credit_line(cr)
	credit.flat = true
	credit.focus_mode = Control.FOCUS_ALL
	credit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	credit.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	credit.add_theme_font_size_override("font_size", ThemeLib.SIZE_CAPTION)
	credit.add_theme_font_override("font", ThemeLib.font("medium"))
	credit.add_theme_color_override("font_color", ThemeLib.color("text_2"))
	credit.tooltip_text = page_url
	credit.disabled = page_url == "" or not open_link.is_valid() or credit.text == ""
	credit.visible = credit.text != ""
	if not credit.visible:
		credit.focus_mode = Control.FOCUS_NONE
	credit.pressed.connect(func(): open_link.call(page_url))
	add_child(credit)


## The shader rounds the drawn picture, which is the texture fitted into the
## rect; give it that size so the corners land on the photo, not the box.
func _fit_mask() -> void:
	if image.texture == null:
		return
	var ts := image.texture.get_size()
	var box := image.size
	if ts.x <= 0 or ts.y <= 0 or box.x <= 0 or box.y <= 0:
		return
	var s := minf(box.x / ts.x, box.y / ts.y)
	_mat.set_shader_parameter("size", ts * s)
