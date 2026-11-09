extends VBoxContainer
## A real device photo (DevicePhoto.photo_for) with rounded corners, fitted
## inside its box, and a one-line credit under it ("Photo: <author>,
## <license>") that opens the Commons file page through the host's link
## opener. Built only when there is a photo; otherwise callers keep the
## drawing. Look-neutral on purpose: the panels' restyle owns the framing.
##
##   DevicePhotoView.make(photo, height, open_link) -> DevicePhotoView or null
##     photo: {"path", "credit"} from DevicePhoto; open_link: Callable(url)

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Photo := preload("res://scripts/device/photo.gd")
const TPhoto := preload("res://scripts/ui/texts_photo.gd")
const RoundShader := preload("res://shaders/rounded_art.gdshader")

var image: TextureRect
var credit: Button
var page_url := ""
var _mat: ShaderMaterial


static func make(photo: Dictionary, height: float, open_link: Callable) -> Control:
	var path := str(photo.get("path", ""))
	var tex := Kit.load_art(path, Vector2i(1200, 1200))
	if tex == null:
		return null
	var v = load("res://scripts/ui/device/device_photo_view.gd").new()
	v._build(tex, photo.get("credit", {}) if photo.get("credit") is Dictionary else {}, height, open_link)
	return v


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
	credit.disabled = page_url == "" or not open_link.is_valid()
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
