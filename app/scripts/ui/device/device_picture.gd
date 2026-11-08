extends TextureRect
## The handheld's front view (Device.picture_for) with parts lit up: pressed
## buttons filled with the accent colour, the selected one (e.g. the focused
## back-button row) outlined. Part ids follow InputPlumber capability names:
## btn-South, btn-Guide, btn-LeftPaddle1, ... (docs/DEVICES.md, "Glyphs and
## pictures"). The SVG is recoloured as text and rasterised once per
## combination, so pressing a button costs one small SVG render, no per-frame work.

const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Icons := preload("res://scripts/ui/icons.gd")

var source := ""
var path := ""
var lit: Array = []        # capability names shown pressed
var selected: Array = []   # capability names outlined
var _cache := {}


func setup(picture_path: String) -> void:
	path = picture_path
	name = "Picture"
	source = FileAccess.get_file_as_string(picture_path) if picture_path != "" and FileAccess.file_exists(picture_path) else ""
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_render()


## Which parts the picture has (capability names, without "btn-").
func parts() -> Array:
	var out := []
	var re := RegEx.create_from_string("id=\"btn-([A-Za-z0-9]+)\"")
	for m in re.search_all(source):
		out.append(m.get_string(1))
	return out


func has_part(capability: String) -> bool:
	return source.contains("id=\"btn-%s\"" % capability)


func press(capability: String, down: bool) -> void:
	if down and not capability in lit:
		lit.append(capability)
	elif not down:
		lit.erase(capability)
	_render()


func set_selected(capabilities: Array) -> void:
	if capabilities == selected:
		return
	selected = capabilities.duplicate()
	_render()


func clear() -> void:
	lit.clear()
	selected.clear()
	_render()


func _render() -> void:
	if source == "":
		texture = null
		return
	var acc: Color = ThemeLib.color("accent")
	var key := "%s|%s|%s" % [acc.to_html(false), ",".join(PackedStringArray(lit)), ",".join(PackedStringArray(selected))]
	if _cache.has(key):
		texture = _cache[key]
		return
	var svg := source
	for c in selected:
		if not c in lit:
			svg = highlight(svg, "btn-" + c, "#" + Color(acc, 1.0).darkened(0.55).to_html(false), "#" + acc.to_html(false), "2.4")
	for c in lit:
		svg = highlight(svg, "btn-" + c, "#" + acc.to_html(false), "#" + acc.lightened(0.35).to_html(false), "2")
	var t: Texture2D = DPITexture.create_from_string(svg, 2.0)
	if t == null or t.get_width() <= 0:
		t = Icons.from_svg(svg)
	if _cache.size() > 48:
		_cache.clear()
	_cache[key] = t
	texture = t


## Recolours the element with `id` (for a group: its first shape) in SVG text.
static func highlight(svg: String, id: String, fill: String, stroke: String, stroke_width := "") -> String:
	var at := svg.find("id=\"%s\"" % id)
	if at < 0:
		return svg
	var start := svg.rfind("<", at)
	var end := svg.find(">", at)
	if start < 0 or end < 0:
		return svg
	if svg.substr(start, 3) == "<g ":
		start = svg.find("<", end)
		end = svg.find(">", start)
		if start < 0 or end < 0:
			return svg
	var tag := svg.substr(start, end - start + 1)
	var re_fill := RegEx.create_from_string("fill=\"[^\"]*\"")
	var re_stroke := RegEx.create_from_string("stroke=\"[^\"]*\"")
	var re_width := RegEx.create_from_string("stroke-width=\"[^\"]*\"")
	tag = re_fill.sub(tag, "fill=\"%s\"" % fill) if re_fill.search(tag) else tag.replace("<", "<").insert(tag.find(" "), " fill=\"%s\"" % fill)
	tag = re_stroke.sub(tag, "stroke=\"%s\"" % stroke)
	if stroke_width != "":
		tag = re_width.sub(tag, "stroke-width=\"%s\"" % stroke_width)
	return svg.substr(0, start) + tag + svg.substr(end + 1)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and source != "":
		_render()
