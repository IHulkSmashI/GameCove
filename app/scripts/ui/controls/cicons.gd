extends RefCounted
## Extra line icons for the Controls UI, on the same 24 px grid and in the
## same path format as icons.gd (s: stroke, f: fill). Unknown names fall back
## to icons.gd, so callers can use either set through tex() / rect().

const Icons := preload("res://scripts/ui/icons.gd")

const PATHS := {
	"layers": "s:M12 3.5 21 8l-9 4.5L3 8z|s:M3 12l9 4.5 9-4.5|s:M3 16l9 4.5 9-4.5",
	"lock": "s:M6.5 10.5h11a1.5 1.5 0 0 1 1.5 1.5v6.5a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 5 18.5V12a1.5 1.5 0 0 1 1.5-1.5z|s:M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5",
	"fan": "f:M12 10.3a1.7 1.7 0 1 0 0 3.4 1.7 1.7 0 0 0 0-3.4z|s:M12 10.3c-1-3.6.2-6.8 2.8-6.8 2.3 0 2.6 3.4-.9 6.5|s:M13.6 12.6c3.6-1 6.8.2 6.8 2.8 0 2.3-3.4 2.6-6.5-.9|s:M11.2 13.6c.9 3.6-.4 6.9-3 6.9-2.3 0-2.5-3.5 1-6.6|s:M10.3 11.4c-3.6.9-6.8-.3-6.8-2.9 0-2.3 3.4-2.6 6.5.9",
	"sun": "s:M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8z|s:M12 2.8v2|s:M12 19.2v2|s:M2.8 12h2|s:M19.2 12h2|s:M5.5 5.5l1.4 1.4|s:M17.1 17.1l1.4 1.4|s:M5.5 18.5l1.4-1.4|s:M17.1 6.9l1.4-1.4",
	"mic": "s:M12 3.5a3 3 0 0 1 3 3v5a3 3 0 0 1-6 0v-5a3 3 0 0 1 3-3z|s:M6.5 11.5a5.5 5.5 0 0 0 11 0|s:M12 17v3.5",
	"bluetooth": "s:M7 7.5l10 9-5 4.5V3l5 4.5-10 9",
	"cpu": "s:M7.5 7.5h9v9h-9z|s:M10 4v3.5|s:M14 4v3.5|s:M10 16.5V20|s:M14 16.5V20|s:M4 10h3.5|s:M4 14h3.5|s:M16.5 10H20|s:M16.5 14H20",
	"thermo": "s:M10 14.5V5a2 2 0 0 1 4 0v9.5a4 4 0 1 1-4 0z|f:M12 15.2a2.2 2.2 0 1 0 0 4.4 2.2 2.2 0 0 0 0-4.4z",
	"wrench": "s:M14.7 6.3a4 4 0 0 0-5.2 5.2l-5.6 5.6a1.8 1.8 0 0 0 2.5 2.5l5.6-5.6a4 4 0 0 0 5.2-5.2l-2.4 2.4-2.5-.5-.5-2.5z",
	"light": "s:M12 3.5a6 6 0 0 0-3.5 10.9V17h7v-2.6A6 6 0 0 0 12 3.5z|s:M9.5 20h5",
	"reset": "s:M4.5 12a7.5 7.5 0 1 0 2.2-5.3|s:M4.5 4.5v4h4",
	"battery_leaf": "s:M5 7.5h12a1.5 1.5 0 0 1 1.5 1.5v6a1.5 1.5 0 0 1-1.5 1.5H5A1.5 1.5 0 0 1 3.5 15V9A1.5 1.5 0 0 1 5 7.5z|s:M21 10.5v3|s:M8 14c0-3 2.5-4.5 6-4.5-.2 3.3-2 4.8-5 4.6",
	"overlay": "s:M4.5 5h15a1.5 1.5 0 0 1 1.5 1.5v11a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 17.5v-11A1.5 1.5 0 0 1 4.5 5z|s:M6.5 8.5h5|s:M6.5 11.5h3",
	"upscale": "s:M4 14v6h6|s:M4 20l7-7|s:M14 4h6v6|s:M20 4l-7 7",
	"frames": "s:M4 6h7v12H4z|s:M13 6h7v12h-7z|s:M15.5 9.5l2 2.5-2 2.5",
	"steam": "s:M12 3.5a8.5 8.5 0 1 0 0 17 8.5 8.5 0 0 0 0-17z|s:M15 8a2.2 2.2 0 1 0 0 4.4A2.2 2.2 0 0 0 15 8z|s:M13 11.5l-3.6 2.6|s:M4 13.5l4 1.6|f:M9 13.3a1.7 1.7 0 1 0 0 3.4 1.7 1.7 0 0 0 0-3.4z",
	"export": "s:M12 15V4|s:M7.5 8.5 12 4l4.5 4.5|s:M5 14v4.5A1.5 1.5 0 0 0 6.5 20h11a1.5 1.5 0 0 0 1.5-1.5V14",
	"import": "s:M12 4v11|s:M7.5 10.5 12 15l4.5-4.5|s:M5 14v4.5A1.5 1.5 0 0 0 6.5 20h11a1.5 1.5 0 0 0 1.5-1.5V14",
	"copy": "s:M9 8.5h9.5a1.5 1.5 0 0 1 1.5 1.5v9a1.5 1.5 0 0 1-1.5 1.5H9A1.5 1.5 0 0 1 7.5 19v-9A1.5 1.5 0 0 1 9 8.5z|s:M16.5 5.5V5A1.5 1.5 0 0 0 15 3.5H5.5A1.5 1.5 0 0 0 4 5v9.5A1.5 1.5 0 0 0 5.5 16H6",
	"save": "s:M5.5 4h10.5l3.5 3.5V18.5A1.5 1.5 0 0 1 18 20H6a1.5 1.5 0 0 1-1.5-1.5v-13A1.5 1.5 0 0 1 6 4z|s:M8 4v4.5h7V4|s:M8 20v-6h8v6",
	"plug": "s:M9 3.5v4|s:M15 3.5v4|s:M6.5 7.5h11V11a5.5 5.5 0 0 1-11 0z|s:M12 16.5v4",
	"moon": "s:M19.5 14.5A8 8 0 0 1 9.5 4.5a8 8 0 1 0 10 10z",
	"airplane": "s:M12 3.5c.9 0 1.5 1 1.5 2.2V10l7 4v2l-7-2v4l2 1.5V21l-3.5-1-3.5 1v-1.5l2-1.5v-4l-7 2v-2l7-4V5.7c0-1.2.6-2.2 1.5-2.2z",
	"scaling": "s:M4 7V4h3|s:M17 4h3v3|s:M20 17v3h-3|s:M7 20H4v-3|s:M8.5 8.5h7v7h-7z",
	"palette2": "s:M12 3.5a8.5 8.5 0 1 0 0 17 8.5 8.5 0 0 0 0-17z|s:M12 3.5v17|f:M12 3.5a8.5 8.5 0 0 0 0 17z",
	"stick": "s:M12 3.5a8.5 8.5 0 1 0 0 17 8.5 8.5 0 0 0 0-17z|s:M12 8.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7z",
	"paddle": "s:M7 4.5h10a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2v-11a2 2 0 0 1 2-2z|s:M9 15.5h6",
	"mouse": "s:M12 3.5a5.5 5.5 0 0 1 5.5 5.5v6a5.5 5.5 0 0 1-11 0V9A5.5 5.5 0 0 1 12 3.5z|s:M12 7v3.5",
	"latency": "s:M12 4.5a8 8 0 1 0 0 16 8 8 0 0 0 0-16z|s:M12 8.5v4h3|s:M9.5 2.5h5",
	"shader": "s:M12 3.5 20 8v8l-8 4.5L4 16V8z|s:M12 12.5V20|s:M12 12.5 20 8|s:M12 12.5 4 8",
	"wave": "s:M3 12c2-4 4-4 6 0s4 4 6 0 4-4 6 0",
}

static var _cache := {}


static func has(name: String) -> bool:
	return PATHS.has(name) or Icons.PATHS.has(name)


static func tex(name: String, size := 24, col: Color = Color.WHITE) -> Texture2D:
	if not PATHS.has(name):
		return Icons.tex(name, size, col)
	var key := "%s|%d|%s" % [name, size, col.to_html()]
	if _cache.has(key):
		return _cache[key]
	var hex := "#" + col.to_html(false)
	var op := "%.3f" % col.a
	var parts := ""
	for p in String(PATHS[name]).split("|"):
		var d := p.substr(2)
		if p.begins_with("f:"):
			parts += "<path d='%s' fill='%s' fill-opacity='%s'/>" % [d, hex, op]
		else:
			parts += "<path d='%s' fill='none' stroke='%s' stroke-opacity='%s' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'/>" % [d, hex, op]
	var t := Icons.from_svg("<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d' viewBox='0 0 24 24'>%s</svg>" % [size, size, parts])
	_cache[key] = t
	return t


static func rect(name: String, size := 24, col: Color = Color.WHITE) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex(name, size, col)
	r.custom_minimum_size = Vector2(size, size)
	r.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return r
