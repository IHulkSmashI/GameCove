extends Control
## Generated cover for a game without art: a gradient picked from the game key
## (ArtColor.fallback_colors), one of three quiet motifs (waves, peaks, rings)
## and either the title set in the display face (older callers) or, on tiles,
## a centred monogram alone (the tile's bottom plate carries the title and
## the store line, so the store isn't printed twice). Drawn once with canvas
## calls, no textures; the renderer caches it until the size changes.

const ArtColor := preload("res://theme/art_color.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const View := preload("res://scripts/ui/library_view.gd")

const MOTIFS := ["waves", "peaks", "rings"]

var game: Dictionary = {}
var corner := 12.0
var colors: Array[Color] = []
var motif := "waves"
var title_label: Label
var store_label: Label
## A ROM's console ("SNES"), printed at the top of its card; "" for other games.
var system_text := ""
## Consoles to draw as a pattern of little cartridge cards, each in its console's
## colours with its name (the Emulation page's hero before any ROM has art).
var pattern_systems: Array = []


func set_pattern(shorts: Array) -> void:
	pattern_systems = shorts.slice(0, 24)
	colors = ArtColor.fallback_colors("emu:pattern")
	queue_redraw()
## Draw the monogram (tiles set this; no title labels).
var monogram := false:
	set(v):
		monogram = v
		queue_redraw()


func setup(g: Dictionary, title_size := 22, radius := 12.0, with_title := true) -> void:
	game = g
	name = "TitleCard"
	corner = radius
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var key: String = g.get("key", g.get("title", ""))
	# A ROM without art: every game of a console shares its colours and carries its name.
	var sys := View.system_of(g)
	system_text = str(g.get("emulated", {}).get("system_short", sys)) if sys != "" else ""
	colors = ArtColor.fallback_colors("system:" + sys if sys != "" else key)
	motif = MOTIFS[ArtColor._stable_hash(key + "#m") % MOTIFS.size()]
	if not with_title:
		return
	title_label = Label.new()
	title_label.name = "Title"
	var title: String = g.get("title", "")
	title_label.text = title if title != "" else "Untitled"
	title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title_label.max_lines_visible = 4
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	title_label.add_theme_font_override("font", ThemeLib.font("display"))
	title_label.add_theme_font_size_override("font_size", title_size)
	title_label.add_theme_color_override("font_color", Color("#FFFFFF"))
	title_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.35))
	title_label.add_theme_constant_override("shadow_offset_y", 2)
	title_label.add_theme_constant_override("line_spacing", -int(title_size * 0.12))
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	var pad := maxf(12.0, title_size * 0.6)
	title_label.offset_left = pad
	title_label.offset_right = -pad
	title_label.offset_top = pad + title_size * 1.1
	title_label.offset_bottom = -pad
	add_child(title_label)

	store_label = Label.new()
	store_label.name = "Store"
	store_label.text = system_text if system_text != "" else View.store_name(g.get("store", ""))
	store_label.add_theme_font_override("font", ThemeLib.font("semibold"))
	store_label.add_theme_font_size_override("font_size", maxi(12, int(title_size * 0.55)))
	store_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.78))
	store_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	store_label.position = Vector2(pad, pad * 0.8)
	add_child(store_label)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func _draw() -> void:
	if colors.is_empty():
		return
	var w := size.x
	var h := size.y
	if w < 2.0 or h < 2.0:
		return
	var shape := rounded_rect(Rect2(Vector2.ZERO, size), corner)
	var a := colors[0]
	var b := colors[1]
	# Diagonal gradient: dark base bottom-left, brighter partner top-right.
	var cols := PackedColorArray()
	for p in shape:
		var t := clampf((p.x / w) * 0.55 + (1.0 - p.y / h) * 0.45, 0.0, 1.0)
		cols.append(a.lerp(b, t))
	draw_polygon(shape, cols)

	if not pattern_systems.is_empty():
		_draw_pattern(w, h, shape)
		var edge := shape.duplicate()
		edge.append(shape[0])
		draw_polyline(edge, Color(1, 1, 1, 0.10), 1.0, true)
		return
	var decor: Array = []
	match motif:
		"waves":
			for i in 3:
				var y0 := h * (0.56 + i * 0.12)
				var amp := h * (0.035 + i * 0.01)
				var pts := PackedVector2Array()
				var steps := 24
				for s in steps + 1:
					var x := w * s / steps
					pts.append(Vector2(x, y0 + sin(s * 0.55 + i * 1.7) * amp))
				pts.append(Vector2(w, h))
				pts.append(Vector2(0, h))
				decor.append([pts, Color(a.darkened(0.25 + i * 0.12), 0.55)])
		"peaks":
			var p1 := PackedVector2Array([Vector2(-w * 0.1, h), Vector2(w * 0.32, h * 0.48), Vector2(w * 0.62, h * 0.78), Vector2(w * 0.86, h * 0.55), Vector2(w * 1.1, h)])
			var p2 := PackedVector2Array([Vector2(-w * 0.1, h), Vector2(w * 0.18, h * 0.72), Vector2(w * 0.5, h * 0.62), Vector2(w * 0.78, h * 0.82), Vector2(w * 1.1, h * 0.7), Vector2(w * 1.1, h)])
			decor.append([p1, Color(a.darkened(0.2), 0.6)])
			decor.append([p2, Color(a.darkened(0.45), 0.75)])
		"rings":
			for i in 4:
				decor.append([_circle(Vector2(w * 0.8, h * 0.24), w * (0.85 - i * 0.18)), Color(b.lightened(0.25), 0.09)])
	# A soft "sun" behind everything except rings.
	if motif != "rings":
		decor.push_front([_circle(Vector2(w * 0.7, h * 0.3), w * 0.24), Color(b.lightened(0.35), 0.30)])
	for d in decor:
		for clipped in Geometry2D.intersect_polygons(d[0], shape):
			if clipped.size() >= 3:
				draw_colored_polygon(clipped, d[1])
	# Bottom shade so the title always reads.
	var shade := PackedVector2Array()
	var shade_cols := PackedColorArray()
	for p in shape:
		shade.append(p)
		shade_cols.append(Color(0, 0, 0, clampf((p.y / h - 0.45) * 0.9, 0.0, 0.45)))
	draw_polygon(shade, shade_cols)
	if monogram:
		_draw_monogram(w, h)
	# Hairline inner border for a printed-card feel.
	var border := shape.duplicate()
	border.append(shape[0])
	draw_polyline(border, Color(1, 1, 1, 0.10), 1.0, true)


## The initials, big and faint, centred in the top of the card. No store
## under them: the plate's store line already names it (and on Stream every
## app is on the same PC).
func _draw_monogram(w: float, h: float) -> void:
	if system_text != "":
		_draw_system(w, h)
	var mono := initials(str(game.get("title", "")))
	if mono == "":
		return
	var f: Font = ThemeLib.font("display")
	var fs := int(w * (0.36 if mono.length() < 2 else 0.30))
	var cy := h * 0.36
	var asc := f.get_ascent(fs)
	var desc := f.get_descent(fs)
	draw_string(f, Vector2(0, cy + (asc - desc) / 2.0), mono, HORIZONTAL_ALIGNMENT_CENTER, w, fs, Color(1, 1, 1, 0.34))


## Rows of little cards across the right of the hero, one per console, in its
## colours with its name: a pattern of the user's own systems, no console art.
func _draw_pattern(w: float, h: float, shape: PackedVector2Array) -> void:
	var ch := h * 0.36
	var cw := ch * 0.74
	var gap := ch * 0.12
	var f: Font = ThemeLib.font("semibold")
	var fs := maxi(11, int(cw * 0.14))
	var i := 0
	for row in 3:
		var y := gap * 0.5 + row * (ch + gap) - ch * 0.35
		var x := w - cw - gap - (cw + gap) * 0.5 * (row % 2)
		while x > w * 0.28:
			var sys := str(pattern_systems[i % pattern_systems.size()])
			i += 1
			var c: Array[Color] = ArtColor.fallback_colors("system:" + sys.to_lower())
			var r := Rect2(x, y, cw, ch)
			var card := rounded_rect(r, cw * 0.1)
			var inside := Geometry2D.intersect_polygons(card, shape)
			for poly in inside:
				var cols := PackedColorArray()
				for p in poly:
					cols.append(c[0].lerp(c[1], clampf((p.y - y) / ch, 0.0, 1.0)))
				draw_polygon(poly, cols)
			if not inside.is_empty() and r.position.y > 0.0 and r.end.y < h:
				draw_string(f, Vector2(x, y + ch * 0.2 + f.get_ascent(fs) * 0.5), sys, HORIZONTAL_ALIGNMENT_CENTER, cw, fs, Color(1, 1, 1, 0.8))
			x -= cw + gap


## A ROM's console in a pill at the top of the card, like a cartridge label.
func _draw_system(w: float, h: float) -> void:
	var f: Font = ThemeLib.font("semibold")
	var fs := maxi(11, int(w * 0.075))
	var tw := f.get_string_size(system_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var pad := fs * 0.7
	var r := Rect2((w - tw) / 2.0 - pad, h * 0.07, tw + pad * 2.0, fs * 1.7)
	# a hair under half the height: a full half makes the two arcs share points (no triangulation)
	var pill := rounded_rect(r, r.size.y / 2.0 - 0.75)
	draw_colored_polygon(pill, Color(0, 0, 0, 0.28))
	draw_polyline(pill + PackedVector2Array([pill[0]]), Color(1, 1, 1, 0.22), 1.0, true)
	var asc := f.get_ascent(fs)
	var desc := f.get_descent(fs)
	draw_string(f, Vector2(0, r.position.y + (r.size.y + asc - desc) / 2.0), system_text, HORIZONTAL_ALIGNMENT_CENTER, w, fs, Color(1, 1, 1, 0.86))


## "Moss & Marrow" -> "MM", "The Last Lighthouse" -> "LL", "Desktop" -> "D".
static func initials(title: String) -> String:
	var words: Array = []
	for wd in title.replace("&", " ").replace(":", " ").replace("-", " ").split(" ", false):
		var lw := String(wd).to_lower()
		if lw in ["the", "a", "an", "of", "and"] and not words.is_empty() or (lw == "the" and words.is_empty()):
			continue
		words.append(String(wd))
	if words.is_empty():
		return title.substr(0, 1).to_upper()
	var out := ""
	for wd in words.slice(0, 2):
		out += String(wd).substr(0, 1).to_upper()
	return out


static func rounded_rect(r: Rect2, radius: float, seg := 6) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var rad := minf(radius, minf(r.size.x, r.size.y) * 0.5)
	var centers := [r.position + Vector2(r.size.x - rad, rad), r.position + Vector2(rad, rad),
		r.position + Vector2(rad, r.size.y - rad), r.position + r.size - Vector2(rad, rad)]
	var starts := [0.0, -PI / 2.0, PI, PI / 2.0]
	# Counter-clockwise on screen: top-right, top-left, bottom-left, bottom-right.
	for i in 4:
		for s in seg + 1:
			var ang: float = starts[i] - (PI / 2.0) * s / seg
			pts.append(centers[i] + Vector2(cos(ang), sin(ang)) * rad)
	return pts


static func _circle(c: Vector2, r: float, seg := 40) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in seg:
		var ang := -TAU * i / seg
		pts.append(c + Vector2(cos(ang), sin(ang)) * r)
	return pts
