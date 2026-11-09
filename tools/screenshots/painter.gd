extends RefCounted
## Paints believable placeholder game art (covers 600x900, heroes 1920x620,
## transparent logos) from shapes and gradients, and builds a fake library
## around it. Used only by shoot.gd.

const ThemeLib := preload("res://theme/gamecove_theme.gd")

## title, store, installed, played days ago (-1 never), playtime h, ttb h,
## anticheat, protondb, palette [top, bottom, glow, ink], motif, art "chl", extra
const GAMES := [
	["Hollow Tide", "steam", true, 0.05, 13, 18, "", "platinum", ["#0B2B4A", "#2B8C9E", "#F7D58B", "#06121F"], "ocean", "chl", {"summary": "A lighthouse keeper rows out each night to relight the beacons a drowned town left behind. Quiet exploration, tide puzzles and one very patient seal."}],
	["Ember Circuit", "steam", true, 2, 42, 35, "works", "gold", ["#1A0630", "#C2185B", "#FF9E40", "#12021F"], "neon", "chl", {}],
	["Starfall Drift", "epic", true, 5, 6, 7, "", "silver", ["#050816", "#3B2A7A", "#B8A6FF", "#04040C"], "planet", "ch", {}],
	["Kingdom of Ash", "gog", false, -1, 0, 60, "", "platinum", ["#2A1208", "#C46A2B", "#FFD27A", "#140804"], "mountains", "ch", {}],
	["Neon Ronin", "steam", true, -1, 0, 14, "denied", "borked", ["#0A0B24", "#5B1A73", "#3DF5E8", "#05040F"], "city", "chl", {"added": true}],
	["Quiet Orchard", "gog", true, 20, 4, 5, "", "platinum", ["#E9F2D0", "#7FB069", "#FFF4C2", "#1F3A24"], "forest", "c", {}],
	["Dune Runners", "amazon", true, 40, 3, 9, "", "bronze", ["#F2B263", "#E0703A", "#FFF1C9", "#4A1E10"], "desert", "ch", {}],
	["Glacier Protocol", "epic", true, 12, 9, 22, "works", "gold", ["#DDEFFC", "#5C8DB8", "#FFFFFF", "#132A40"], "mountains", "ch", {"update": true}],
	["Paper Lanterns", "steam", true, 3, 2, 3, "", "platinum", ["#140A1F", "#3D1E4F", "#FFB347", "#0A0510"], "lanterns", "ch", {"cut": 60}],
	["Iron Meridian", "steam", false, -1, 0, 28, "blocked", "gold", ["#1A1F24", "#4B5A66", "#FFB000", "#0B0E11"], "city", "ch", {}],
	["Moss & Marrow", "epic", true, 8, 11, 16, "", "gold", [], "", "", {}],
	["The Last Lighthouse", "gog", true, 30, 1, 8, "", "platinum", [], "", "", {}],
	["Sky Harbor", "amazon", false, -1, 0, -1, "", "", [], "", "", {}],
	["Velvet Arcade", "steam", true, 6, 1.5, 2, "", "platinum", ["#2B0A3D", "#E0417A", "#FFE066", "#15051F"], "neon", "c", {}],
	["Northbound", "steam", true, 10, 21, 12, "works", "platinum", ["#0E1A2B", "#3E6E8E", "#F2E8CF", "#070D15"], "forest", "ch", {}],
	["Crimson Vale", "epic", true, 15, 30, 45, "", "silver", ["#2A0508", "#9E1B2B", "#FF8A5B", "#140203"], "mountains", "ch", {}],
]


static func make_library(tree: SceneTree, dir: String) -> Array:
	var now := int(Time.get_unix_time_from_system())
	var out: Array = []
	var i := 0
	for spec in GAMES:
		i += 1
		var title: String = spec[0]
		var slug := title.to_lower().validate_filename().replace(" ", "_")
		var art := {"cover": "", "hero": "", "logo": "", "icon": ""}
		var kinds: String = spec[10]
		if kinds.contains("c"):
			art["cover"] = await _render(tree, spec, "cover", dir + slug + "_cover.png")
		if kinds.contains("h"):
			art["hero"] = await _render(tree, spec, "hero", dir + slug + "_hero.png")
		if kinds.contains("l"):
			art["logo"] = await _logo(tree, title, dir + slug + "_logo.png")
		var ttb: Variant = null
		if float(spec[5]) > 0.0:
			ttb = {"main_h": float(spec[5]), "extra_h": float(spec[5]) * 1.6, "complete_h": float(spec[5]) * 2.7, "count": 120 + i * 37, "source": "igdb"}
		var ac: Variant = null
		if spec[6] != "":
			ac = {"status": spec[6], "anticheats": ["Easy Anti-Cheat"]}
		var g := {
			"key": "%s:%d" % [spec[1], 1000 + i * 77], "store": spec[1], "id": str(1000 + i * 77), "title": title,
			"installed": spec[2], "art": art,
			"info": {"released": 2016 + i % 9, "time_to_beat": ttb, "anticheat": ac, "protondb": spec[7] if spec[7] != "" else null},
			"last_played": int(now - float(spec[3]) * 86400.0) if float(spec[3]) >= 0.0 else 0,
			"playtime_min": int(float(spec[4]) * 60.0),
		}
		var extra: Dictionary = spec[11]
		if extra.get("added", false):
			g["added"] = now - 86400 * 2
		if extra.get("update", false):
			g["update_available"] = true
		if extra.has("cut"):
			g["deal"] = {"cut": extra["cut"]}
		if extra.has("summary"):
			g["info"]["summary"] = extra["summary"]
		out.append(g)
	return out


static func _render(tree: SceneTree, spec: Array, kind: String, path: String) -> String:
	var size := Vector2i(600, 900) if kind == "cover" else Vector2i(1920, 620)
	var vp := SubViewport.new()
	vp.size = size
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var scene := Scene.new()
	scene.spec = spec
	scene.kind = kind
	scene.size = Vector2(size)
	vp.add_child(scene)
	tree.root.add_child(vp)
	await tree.process_frame
	await tree.process_frame
	await RenderingServer.frame_post_draw
	vp.get_texture().get_image().save_png(path)
	vp.queue_free()
	return path


static func _logo(tree: SceneTree, title: String, path: String) -> String:
	var vp := SubViewport.new()
	vp.transparent_bg = true
	vp.size = Vector2i(1100, 360)
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var l := Label.new()
	l.text = title
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size = Vector2(1100, 360)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	l.add_theme_font_override("font", ThemeLib.font("display"))
	l.add_theme_font_size_override("font_size", 150 if title.length() < 12 else 118)
	l.add_theme_constant_override("line_spacing", -30)
	l.add_theme_color_override("font_color", Color("#FFFFFF"))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.55))
	l.add_theme_constant_override("outline_size", 10)
	l.uppercase = true
	vp.add_child(l)
	tree.root.add_child(vp)
	await tree.process_frame
	await tree.process_frame
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	var used := img.get_used_rect()
	if used.size.x > 0:
		img = img.get_region(used.grow(8).intersection(Rect2i(Vector2i.ZERO, img.get_size())))
	img.save_png(path)
	vp.queue_free()
	return path


class Scene extends Control:
	var spec: Array
	var kind := "cover"
	var rng := RandomNumberGenerator.new()

	func _draw() -> void:
		rng.seed = hash(spec[0])
		var w := size.x
		var h := size.y
		var pal: Array = spec[8].map(func(c): return Color(c))
		var top: Color = pal[0]
		var bottom: Color = pal[1]
		var glow: Color = pal[2]
		var ink: Color = pal[3]
		var horizon := h * (0.62 if kind == "cover" else 0.66)
		_quad(Rect2(0, 0, w, horizon), top, bottom)
		_quad(Rect2(0, horizon, w, h - horizon), bottom.darkened(0.35), ink)
		var sun := Vector2(w * (0.62 if kind == "cover" else 0.7), horizon - h * 0.16)
		var sr := minf(w, h) * (0.20 if kind == "cover" else 0.22)
		for i in 10:
			draw_circle(sun, sr * (2.6 - i * 0.16), Color(glow, 0.035))
		var night := top.get_luminance() < 0.2
		if night:
			for i in 140:
				draw_circle(Vector2(rng.randf() * w, rng.randf() * horizon * 0.85), rng.randf_range(0.6, 2.0) * (w / 600.0), Color(1, 1, 1, rng.randf_range(0.2, 0.9)))
		match spec[9]:
			"ocean": _ocean(w, h, horizon, sun, sr, glow, ink)
			"neon": _neon(w, h, horizon, sun, sr, glow, ink)
			"planet": _planet(w, h, horizon, glow, ink)
			"mountains": _mountains(w, h, horizon, sun, sr, glow, ink, bottom)
			"city": _city(w, h, horizon, glow, ink)
			"forest": _forest(w, h, horizon, sun, sr, glow, ink, bottom)
			"desert": _desert(w, h, horizon, sun, sr, glow, ink)
			"lanterns": _lanterns(w, h, horizon, glow, ink)
		# Vignette.
		_quad(Rect2(0, h * 0.7, w, h * 0.3), Color(0, 0, 0, 0), Color(0, 0, 0, 0.45))
		_quad(Rect2(0, 0, w, h * 0.22), Color(0, 0, 0, 0.35), Color(0, 0, 0, 0))
		if kind == "cover":
			_title(w, h)

	func _quad(r: Rect2, a: Color, b: Color) -> void:
		draw_polygon(PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]),
			PackedColorArray([a, a, b, b]))

	func _ridge(w: float, base_y: float, amp: float, steps: int, col: Color, bottom_y: float) -> void:
		var pts := PackedVector2Array()
		var y := base_y
		for i in steps + 1:
			y = minf(clampf(y + rng.randf_range(-amp, amp), base_y - amp * 2.5, base_y + amp), bottom_y - 1.0)
			pts.append(Vector2(w * i / steps, y))
		pts.append(Vector2(w, bottom_y))
		pts.append(Vector2(0, bottom_y))
		draw_colored_polygon(pts, col)

	func _ocean(w: float, h: float, hz: float, sun: Vector2, sr: float, glow: Color, ink: Color) -> void:
		draw_circle(sun, sr, glow)
		_ridge(w * 0.5, hz - 10, 18, 10, Color(ink, 0.7), hz + 2)
		for i in 26:
			var y: float = hz + (h - hz) * pow(float(i) / 26.0, 1.6)
			var len: float = rng.randf_range(0.05, 0.22) * w
			draw_rect(Rect2(sun.x - len / 2 + rng.randf_range(-30, 30), y, len, 2 + i * 0.25), Color(glow, 0.55 - i * 0.018))
		var boat := Vector2(w * 0.3, hz + (h - hz) * 0.35)
		draw_colored_polygon(PackedVector2Array([boat + Vector2(-40, 0), boat + Vector2(40, 0), boat + Vector2(28, 14), boat + Vector2(-28, 14)]), ink)
		draw_colored_polygon(PackedVector2Array([boat + Vector2(0, -70), boat + Vector2(30, -6), boat + Vector2(0, -6)]), Color(ink, 0.95))

	func _neon(w: float, h: float, hz: float, sun: Vector2, sr: float, glow: Color, ink: Color) -> void:
		var s := Vector2(w * 0.5, hz - sr * 0.4)
		draw_circle(s, sr * 1.1, glow)
		for i in 7:
			var y: float = s.y + sr * 0.15 + i * sr * 0.14
			draw_rect(Rect2(s.x - sr * 1.2, y, sr * 2.4, 4 + i * 1.6), Color(spec[8][0]))
		_ridge(w, hz - 30, 26, 14, Color(ink, 1.0), hz + 1)
		var line := Color(glow.lerp(Color("#FF3DA5"), 0.5), 0.8)
		for i in 18:
			var x: float = w * (i - 4) / 10.0
			draw_line(Vector2(w * 0.5 + (x - w * 0.5) * 0.08, hz), Vector2(x * 1.0, h), line, 2.0)
		for i in 12:
			var t: float = pow(float(i) / 12.0, 2.0)
			draw_line(Vector2(0, hz + (h - hz) * t), Vector2(w, hz + (h - hz) * t), line, 1.5 + t * 2.0)

	func _planet(w: float, h: float, hz: float, glow: Color, ink: Color) -> void:
		var c := Vector2(w * 0.58, h * 0.36)
		var r := minf(w, h) * 0.30
		draw_circle(c, r, Color(spec[8][1]).lightened(0.15))
		for i in 6:
			draw_circle(c + Vector2(r * 0.18 * i, -r * 0.1 * i), r * (1.0 - i * 0.12), Color(glow, 0.06))
		var ring := PackedVector2Array()
		for i in 65:
			var a := TAU * i / 64.0
			ring.append(c + Vector2(cos(a) * r * 1.7, sin(a) * r * 0.32).rotated(-0.35))
		draw_polyline(ring, Color(glow, 0.85), 6.0 * w / 600.0, true)
		_ridge(w, hz + 30, 14, 20, ink, h)
		var ship := Vector2(w * 0.24, h * 0.22)
		draw_colored_polygon(PackedVector2Array([ship, ship + Vector2(46, 14), ship + Vector2(0, 28)]), Color("#FFFFFF"))
		draw_line(ship + Vector2(0, 14), ship + Vector2(-90, 18), Color(glow, 0.6), 3.0)

	func _mountains(w: float, h: float, hz: float, sun: Vector2, sr: float, glow: Color, ink: Color, bottom: Color) -> void:
		draw_circle(sun, sr * 0.8, Color(glow, 0.95))
		_ridge(w, hz - h * 0.18, h * 0.05, 9, bottom.darkened(0.15), h)
		_quad(Rect2(0, hz - h * 0.12, w, h * 0.12), Color(glow, 0.0), Color(glow, 0.22))
		_ridge(w, hz - h * 0.08, h * 0.045, 12, bottom.darkened(0.45), h)
		_ridge(w, hz + h * 0.02, h * 0.03, 16, ink.lerp(bottom, 0.2), h)
		_ridge(w, hz + h * 0.12, h * 0.02, 22, ink, h)
		var p := Vector2(w * 0.22, hz + h * 0.06)
		draw_colored_polygon(PackedVector2Array([p + Vector2(-6, 0), p + Vector2(6, 0), p + Vector2(4, -34), p + Vector2(-4, -34)]), ink)
		draw_circle(p + Vector2(0, -40), 7, ink)

	func _city(w: float, h: float, hz: float, glow: Color, ink: Color) -> void:
		for layer in 3:
			var col: Color = Color(spec[8][1]).darkened(0.35 + layer * 0.2).lerp(ink, layer * 0.35)
			var x := -10.0
			while x < w:
				var bw := rng.randf_range(0.05, 0.12) * w
				var bh := rng.randf_range(0.12, 0.42) * h * (1.0 - layer * 0.2)
				var r := Rect2(x, hz - bh + layer * h * 0.06, bw, bh + h)
				draw_rect(r, col)
				if layer > 0:
					for wy in range(int(r.position.y + 10), int(hz + layer * h * 0.06), 14):
						for wx in range(int(r.position.x + 6), int(r.end.x - 6), 11):
							if rng.randf() < 0.28:
								draw_rect(Rect2(wx, wy, 5, 7), Color(glow, rng.randf_range(0.5, 1.0)))
				x += bw + rng.randf_range(2, 12)
		_quad(Rect2(0, hz, w, h - hz), Color(glow, 0.12), Color(ink, 1.0))

	func _forest(w: float, h: float, hz: float, sun: Vector2, sr: float, glow: Color, ink: Color, bottom: Color) -> void:
		draw_circle(sun, sr * 0.7, Color(glow, 0.9))
		for layer in 4:
			var col: Color = bottom.darkened(0.15 + layer * 0.18).lerp(ink, layer * 0.25)
			var base: float = hz - h * 0.06 + layer * h * 0.07
			var x := -20.0
			while x < w + 20:
				var th := rng.randf_range(0.10, 0.2) * h * (0.7 + layer * 0.15)
				var tw := th * 0.42
				draw_colored_polygon(PackedVector2Array([Vector2(x, base - th), Vector2(x + tw / 2, base), Vector2(x - tw / 2, base)]), col)
				x += tw * rng.randf_range(0.45, 0.8)
			draw_rect(Rect2(0, base - 1, w, h), col)
			_quad(Rect2(0, base - h * 0.08, w, h * 0.08), Color(glow, 0.0), Color(glow, 0.10))

	func _desert(w: float, h: float, hz: float, sun: Vector2, sr: float, glow: Color, ink: Color) -> void:
		draw_circle(sun, sr * 0.9, Color(glow, 0.95))
		for layer in 4:
			var col: Color = Color(spec[8][1]).darkened(layer * 0.16).lerp(ink, layer * 0.18)
			var pts := PackedVector2Array()
			var base: float = hz - h * 0.05 + layer * h * 0.08
			for i in 33:
				var x: float = w * i / 32.0
				pts.append(Vector2(x, base + sin(i * 0.4 + layer * 2.0) * h * 0.025))
			pts.append(Vector2(w, h))
			pts.append(Vector2(0, h))
			draw_colored_polygon(pts, col)
		var p := Vector2(w * 0.7, hz + h * 0.05)
		draw_colored_polygon(PackedVector2Array([p + Vector2(-90, 0), p + Vector2(0, -110), p + Vector2(90, 0)]), Color(ink, 0.9))

	func _lanterns(w: float, h: float, hz: float, glow: Color, ink: Color) -> void:
		_ridge(w, hz, 10, 16, ink, h)
		for i in 26:
			var c := Vector2(rng.randf() * w, rng.randf_range(0.1, 0.75) * h)
			var r := rng.randf_range(8, 26) * (w / 600.0 if kind == "cover" else 1.4)
			for k in 4:
				draw_circle(c, r * (2.2 - k * 0.35), Color(glow, 0.06))
			draw_rect(Rect2(c - Vector2(r * 0.6, r * 0.8), Vector2(r * 1.2, r * 1.6)), Color(glow.lightened(0.2), 0.95))
		draw_rect(Rect2(0, hz, w, 3), Color(glow, 0.4))

	func _title(w: float, h: float) -> void:
		var font: Font = ThemeLib.font("display")
		var t: String = String(spec[0]).to_upper()
		var words := t.split(" ")
		var lines: Array = []
		if words.size() >= 3 or t.length() > 12:
			var mid := int(ceil(words.size() / 2.0))
			lines = [" ".join(words.slice(0, mid)), " ".join(words.slice(mid))]
		else:
			lines = [t]
		var y := h * 0.13
		for line in lines:
			var fs := 120
			while fs > 30 and font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > w * 0.84:
				fs -= 4
			var sz := font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
			var pos := Vector2((w - sz.x) / 2.0, y + fs * 0.8)
			draw_string(font, pos + Vector2(0, 4), line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0, 0, 0, 0.45))
			draw_string(font, pos, line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color("#FFFFFF"))
			y += fs * 0.95
