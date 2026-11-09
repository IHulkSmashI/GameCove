extends RefCounted
## GameCove's icon set: original line icons on a 24 px grid, drawn as SVG and
## turned into DPITextures, which re-rasterise at the screen's scale (crisp on
## 1280x800 and 1920x1200 alike). Cached by name, size and colour.
## No brand logos: stores are shown by name.

## Paths on a 24x24 grid. "s:" = stroke (2 px, round), "f:" = fill.
## Several parts are separated by "|".
const PATHS := {
	"play": "f:M8 5.2v13.6c0 .8.9 1.3 1.6.8l10-6.8c.6-.4.6-1.2 0-1.6l-10-6.8C8.9 3.9 8 4.4 8 5.2z",
	"home": "s:M4 10.5 12 4l8 6.5V19a1.5 1.5 0 0 1-1.5 1.5H15v-5.5H9v5.5H5.5A1.5 1.5 0 0 1 4 19z",
	"library": "s:M4 4.5h6v6H4z|s:M14 4.5h6v6h-6z|s:M4 14h6v6H4z|s:M14 14h6v6h-6z",
	"discover": "s:M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z|f:M15.8 8.2l-2.1 5.5-5.5 2.1 2.1-5.5z",
	"settings": "s:M12 9.2a2.8 2.8 0 1 0 0 5.6 2.8 2.8 0 0 0 0-5.6z|s:M12 5.8a6.2 6.2 0 1 0 0 12.4 6.2 6.2 0 0 0 0-12.4z|s:M12 2.8v3|s:M12 18.2v3|s:M2.8 12h3|s:M18.2 12h3|s:M5.5 5.5l2.1 2.1|s:M16.4 16.4l2.1 2.1|s:M5.5 18.5l2.1-2.1|s:M16.4 7.6l2.1-2.1",
	"sliders": "s:M4 7h9|s:M17 7h3|s:M4 17h3|s:M11 17h9|s:M15 5v4|s:M9 15v4",
	"search": "s:M10.5 4a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13z|s:M15.5 15.5 20 20",
	"bolt": "f:M13.2 2.5 5.5 13.2c-.3.4 0 .9.5.9H11l-1.2 7.1c-.1.6.6.9 1 .4l7.7-10.7c.3-.4 0-.9-.5-.9H13l1.2-7.1c.1-.6-.6-.9-1-.4z",
	"wifi": "s:M2.8 9.2a13.5 13.5 0 0 1 18.4 0|s:M5.9 12.6a9 9 0 0 1 12.2 0|s:M9 15.9a4.6 4.6 0 0 1 6 0|f:M12 17.6a1.6 1.6 0 1 0 0 3.2 1.6 1.6 0 0 0 0-3.2z",
	"shield": "s:M12 3.2 19 6v5.6c0 4.3-3 7.9-7 9.2-4-1.3-7-4.9-7-9.2V6z|s:M8.8 12.2l2.2 2.2 4.2-4.6",
	"shield_x": "s:M12 3.2 19 6v5.6c0 4.3-3 7.9-7 9.2-4-1.3-7-4.9-7-9.2V6z|s:M9.5 9.5l5 5|s:M14.5 9.5l-5 5",
	"shield_alert": "s:M12 3.2 19 6v5.6c0 4.3-3 7.9-7 9.2-4-1.3-7-4.9-7-9.2V6z|s:M12 8.5v4|f:M12 14.6a1.2 1.2 0 1 0 0 2.4 1.2 1.2 0 0 0 0-2.4z",
	"clock": "s:M12 3.5a8.5 8.5 0 1 0 0 17 8.5 8.5 0 0 0 0-17z|s:M12 7.5V12l3 2",
	"gauge": "s:M4 16.5a8 8 0 1 1 16 0|s:M12 16.5l3.6-5|f:M12 14.8a1.8 1.8 0 1 0 0 3.6 1.8 1.8 0 0 0 0-3.6z",
	"star": "f:M12 3.4l2.6 5.4 5.9.8-4.3 4.1 1 5.9L12 16.8l-5.2 2.8 1-5.9-4.3-4.1 5.9-.8z",
	"tag": "s:M3.5 12.3V4.8c0-.7.6-1.3 1.3-1.3h7.5l8.4 8.4c.5.5.5 1.3 0 1.8l-7.5 7.5c-.5.5-1.3.5-1.8 0z|f:M8 6.5a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3z",
	"sparkle": "f:M12 2.8c.7 4.5 2.2 6 6.8 6.8-4.6.8-6.1 2.3-6.8 6.8-.7-4.5-2.2-6-6.8-6.8 4.6-.8 6.1-2.3 6.8-6.8z|f:M18.5 15c.3 1.8.9 2.4 2.7 2.7-1.8.3-2.4.9-2.7 2.7-.3-1.8-.9-2.4-2.7-2.7 1.8-.3 2.4-.9 2.7-2.7z",
	"download": "s:M12 4v11|s:M7.5 10.5 12 15l4.5-4.5|s:M5 19.5h14",
	"update": "s:M19.5 12a7.5 7.5 0 1 1-2.2-5.3|s:M19.5 4.5v4h-4",
	"alert": "s:M12 4 21 19.5H3z|s:M12 10v4|f:M12 16a1.1 1.1 0 1 0 0 2.2 1.1 1.1 0 0 0 0-2.2z",
	"check": "s:M5 12.5l4.5 4.5L19 7",
	"x": "s:M6.5 6.5l11 11|s:M17.5 6.5l-11 11",
	"chevron_left": "s:M14.5 6 8.5 12l6 6",
	"chevron_right": "s:M9.5 6l6 6-6 6",
	"chevron_down": "s:M6 9.5l6 6 6-6",
	"leftright": "s:M8.5 7.5 4 12l4.5 4.5|s:M15.5 7.5 20 12l-4.5 4.5|s:M4.5 12h15",
	"sort": "s:M7.5 5v14|s:M4.5 16l3 3 3-3|s:M16.5 19V5|s:M13.5 8l3-3 3 3",
	"screen": "s:M4.5 5h15a1.5 1.5 0 0 1 1.5 1.5v9a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 15.5v-9A1.5 1.5 0 0 1 4.5 5z|s:M9 20.5h6",
	"gamepad": "s:M7 7.5h10a4.5 4.5 0 0 1 4.4 5.3l-.6 3.4a2.4 2.4 0 0 1-4.2 1.1L14.8 15H9.2l-1.8 2.3a2.4 2.4 0 0 1-4.2-1.1l-.6-3.4A4.5 4.5 0 0 1 7 7.5z|s:M8 10.3v3.4|s:M6.3 12h3.4|f:M15.8 10.2a1.1 1.1 0 1 0 0 2.2 1.1 1.1 0 0 0 0-2.2z|f:M17.9 12.2a1.1 1.1 0 1 0 0 2.2 1.1 1.1 0 0 0 0-2.2z",
	"handheld": "s:M5 6.5h14a3.5 3.5 0 0 1 3.5 3.5v4a3.5 3.5 0 0 1-3.5 3.5H5A3.5 3.5 0 0 1 1.5 14v-4A3.5 3.5 0 0 1 5 6.5z|s:M8 9.5h8v5H8z",
	"power": "s:M12 3.5v8|s:M7.2 6.2a7.5 7.5 0 1 0 9.6 0",
	"game": "s:M12 3.5a8.5 8.5 0 1 0 0 17 8.5 8.5 0 0 0 0-17z|f:M10.2 8.6v6.8c0 .5.5.8.9.5l5-3.4c.4-.3.4-.8 0-1.1l-5-3.4c-.4-.2-.9.1-.9.6z",
	"palette": "s:M12 3.5a8.5 8.5 0 0 0 0 17c1.2 0 1.8-.9 1.4-2l-.4-1c-.4-1.1.4-2.2 1.6-2.2H17a3.5 3.5 0 0 0 3.5-3.5c0-4.6-3.8-8.3-8.5-8.3z|f:M8 10a1.3 1.3 0 1 0 0 2.6A1.3 1.3 0 0 0 8 10z|f:M11.5 6.6a1.3 1.3 0 1 0 0 2.6 1.3 1.3 0 0 0 0-2.6z|f:M15.6 8.4a1.3 1.3 0 1 0 0 2.6 1.3 1.3 0 0 0 0-2.6z",
	"motion": "s:M3.5 9h9|s:M3.5 15h6|s:M15 6l6 6-6 6",
	"info": "s:M12 3.5a8.5 8.5 0 1 0 0 17 8.5 8.5 0 0 0 0-17z|s:M12 11v5.5|f:M12 7.2a1.2 1.2 0 1 0 0 2.4 1.2 1.2 0 0 0 0-2.4z",
	"store": "s:M5 8.5h14l-1.1 11a1.5 1.5 0 0 1-1.5 1.4H7.6a1.5 1.5 0 0 1-1.5-1.4z|s:M9 8.5V7a3 3 0 0 1 6 0v1.5",
	"dots": "f:M5.5 10.2a1.8 1.8 0 1 0 0 3.6 1.8 1.8 0 0 0 0-3.6z|f:M12 10.2a1.8 1.8 0 1 0 0 3.6 1.8 1.8 0 0 0 0-3.6z|f:M18.5 10.2a1.8 1.8 0 1 0 0 3.6 1.8 1.8 0 0 0 0-3.6z",
	"backspace": "s:M8.5 5.5H20a1.5 1.5 0 0 1 1.5 1.5v10a1.5 1.5 0 0 1-1.5 1.5H8.5L3 12z|s:M11.5 9.5l5 5|s:M16.5 9.5l-5 5",
	"space": "s:M4 10v4h16v-4",
	"calendar": "s:M5 5.5h14A1.5 1.5 0 0 1 20.5 7v12a1.5 1.5 0 0 1-1.5 1.5H5A1.5 1.5 0 0 1 3.5 19V7A1.5 1.5 0 0 1 5 5.5z|s:M3.5 10h17|s:M8 3.5v4|s:M16 3.5v4",
	"rocket": "s:M14.5 4.5c3-1 5-1 5-1s0 2-1 5l-6 6-4-4z|s:M9.5 10.5l-3 .5-2.5 2.5 4 1|s:M13.5 14.5l-.5 3-2.5 2.5-1-4|f:M15.5 7a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3z",
	"volume": "s:M4 9.5h3.5L12 5.5v13l-4.5-4H4z|s:M15.5 9a4 4 0 0 1 0 6|s:M18 6.5a7.5 7.5 0 0 1 0 11",
	"cloud_off": "s:M7 18.5h10a4 4 0 0 0 .7-7.9A6 6 0 0 0 6.4 9.2 4.7 4.7 0 0 0 7 18.5z|s:M4 4l16 16",
}

static var _cache := {}


## A Texture2D of icon `name`, `size` px square, in `col`.
static func tex(name: String, size := 24, col: Color = Color.WHITE) -> Texture2D:
	var key := "%s|%d|%s" % [name, size, col.to_html()]
	if _cache.has(key):
		return _cache[key]
	var t := _make(svg(name, size, col))
	_cache[key] = t
	return t


## The SVG source of an icon (also used by tests and the docs).
static func svg(name: String, size := 24, col: Color = Color.WHITE) -> String:
	var spec: String = PATHS.get(name, "")
	if spec == "":
		# the Controls UI's extra icons (controls/cicons.gd), else the dots
		var extra: Dictionary = load("res://scripts/ui/controls/cicons.gd").PATHS
		spec = extra.get(name, PATHS["dots"])
	var hex := "#" + col.to_html(false)
	var op := "%.3f" % col.a
	var parts := ""
	for p in spec.split("|"):
		var d := p.substr(2)
		if p.begins_with("f:"):
			parts += "<path d='%s' fill='%s' fill-opacity='%s'/>" % [d, hex, op]
		else:
			parts += "<path d='%s' fill='none' stroke='%s' stroke-opacity='%s' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'/>" % [d, hex, op]
	return "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d' viewBox='0 0 24 24'>%s</svg>" % [size, size, parts]


## Battery outline with a fill bar for `percent` (0..100); bolt when charging.
static func battery(percent: int, charging: bool, size := 24, col: Color = Color.WHITE, fill_col: Color = Color.WHITE) -> Texture2D:
	var p := clampi(percent, 0, 100)
	var key := "bat|%d|%s|%d|%s|%s" % [p / 5, charging, size, col.to_html(), fill_col.to_html()]
	if _cache.has(key):
		return _cache[key]
	var hex := "#" + col.to_html(false)
	var fhex := "#" + fill_col.to_html(false)
	var w := 14.0 * float(p) / 100.0
	var body := "<rect x='2' y='7' width='18' height='10' rx='2.6' fill='none' stroke='%s' stroke-width='1.8'/>" % hex
	body += "<rect x='21' y='10' width='1.8' height='4' rx='0.9' fill='%s'/>" % hex
	if w > 0.4:
		body += "<rect x='4' y='9' width='%.2f' height='6' rx='1.2' fill='%s'/>" % [w, fhex]
	if charging:
		body += "<path d='M12.2 7.6 8.4 12.6h3l-.9 3.8 3.9-5h-3z' fill='%s' stroke='%s' stroke-width='0.8' stroke-linejoin='round'/>" % [hex, "#000000"]
	var src := "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d' viewBox='0 0 24 24'>%s</svg>" % [size, size, body]
	var t := _make(src)
	_cache[key] = t
	return t


## Any SVG source as a crisp texture.
static func from_svg(source: String) -> Texture2D:
	return _make(source)


static func _make(source: String) -> Texture2D:
	var t: Texture2D = DPITexture.create_from_string(source)
	if t == null or t.get_width() <= 0:
		var img := Image.new()
		img.load_svg_from_string(source, 2.0)
		t = ImageTexture.create_from_image(img)
	return t


## A TextureRect showing an icon at its natural size.
static func rect(name: String, size := 24, col: Color = Color.WHITE) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex(name, size, col)
	r.custom_minimum_size = Vector2(size, size)
	r.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return r
