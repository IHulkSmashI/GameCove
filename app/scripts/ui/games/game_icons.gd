extends RefCounted
## Extra line icons for game management, drawn the same way as icons.gd
## (24 px grid, 2 px round strokes, "s:" stroke / "f:" fill paths). Unknown
## names fall back to icons.gd, so callers can use one function for both.

const Icons := preload("res://scripts/ui/icons.gd")

const PATHS := {
	"pause": "f:M7 5h3.2v14H7z|f:M13.8 5H17v14h-3.2z",
	"trophy": "s:M7.5 4.5h9v5a4.5 4.5 0 0 1-9 0z|s:M7.5 6.5H4.5v1.5a3 3 0 0 0 3 3|s:M16.5 6.5h3v1.5a3 3 0 0 1-3 3|s:M12 14v3.5|s:M8.5 20h7|s:M9.5 17.5h5",
	"lock": "s:M6.5 11h11a1 1 0 0 1 1 1v7a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1v-7a1 1 0 0 1 1-1z|s:M8.5 11V8a3.5 3.5 0 0 1 7 0v3",
	"trash": "s:M4.5 7h15|s:M9.5 7V5h5v2|s:M6.5 7l.9 12a1.5 1.5 0 0 0 1.5 1.4h6.2a1.5 1.5 0 0 0 1.5-1.4l.9-12|s:M10 11v6|s:M14 11v6",
	"folder_move": "s:M3.5 7a1.5 1.5 0 0 1 1.5-1.5h4l2 2h8a1.5 1.5 0 0 1 1.5 1.5v8.5a1.5 1.5 0 0 1-1.5 1.5H5a1.5 1.5 0 0 1-1.5-1.5z|s:M10 13.5h6|s:M13.5 11l2.5 2.5-2.5 2.5",
	"wrench": "s:M14.5 4.2a4.5 4.5 0 0 0-5.6 5.9l-5.2 5.2a1.8 1.8 0 0 0 2.5 2.5l5.2-5.2a4.5 4.5 0 0 0 5.9-5.6l-2.6 2.6-2.4-.6-.6-2.4z",
	"terminal": "s:M4.5 5h15a1.5 1.5 0 0 1 1.5 1.5v11a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 17.5v-11A1.5 1.5 0 0 1 4.5 5z|s:M7 10l3 2.5L7 15|s:M12.5 15H17",
	"layers": "s:M12 4 20.5 8.5 12 13 3.5 8.5z|s:M3.5 12.5 12 17l8.5-4.5|s:M3.5 16 12 20.5l8.5-4.5",
	"external": "s:M13.5 4.5h6v6|s:M19.5 4.5l-8 8|s:M17 13.5v4.5a1.5 1.5 0 0 1-1.5 1.5h-9.5A1.5 1.5 0 0 1 4.5 18V8.5A1.5 1.5 0 0 1 6 7h4.5",
	"arrow_up": "s:M12 19V5|s:M6.5 10.5 12 5l5.5 5.5",
	"arrow_down": "s:M12 5v14|s:M6.5 13.5 12 19l5.5-5.5",
	"stop": "s:M7 6.5h10a.5.5 0 0 1 .5.5v10a.5.5 0 0 1-.5.5H7a.5.5 0 0 1-.5-.5V7a.5.5 0 0 1 .5-.5z",
	"drive": "s:M4 13.5h16v4a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 17.5z|s:M4 13.5 6.3 6a1.5 1.5 0 0 1 1.4-1h8.6a1.5 1.5 0 0 1 1.4 1l2.3 7.5|f:M16.5 15.2a1 1 0 1 0 0 2 1 1 0 0 0 0-2z",
	"sdcard": "s:M8.5 3.5h7.5l3 3V19a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 7 19V5a1.5 1.5 0 0 1 1.5-1.5z|s:M10.5 6.5v3|s:M13 6.5v3|s:M15.5 7.5v2",
	"restart": "s:M4.5 12a7.5 7.5 0 1 0 2.2-5.3|s:M4.5 4.5v4h4",
	"queue": "s:M4.5 6.5h15|s:M4.5 12h15|s:M4.5 17.5h9",
}

static var _cache := {}


static func tex(name: String, size := 24, col: Color = Color.WHITE) -> Texture2D:
	if not PATHS.has(name):
		return Icons.tex(name, size, col)
	var key := "%s|%d|%s" % [name, size, col.to_html()]
	if _cache.has(key):
		return _cache[key]
	var t := Icons.from_svg(svg(name, size, col))
	_cache[key] = t
	return t


static func svg(name: String, size := 24, col: Color = Color.WHITE) -> String:
	if not PATHS.has(name):
		return Icons.svg(name, size, col)
	var hex := "#" + col.to_html(false)
	var op := "%.3f" % col.a
	var parts := ""
	for p in String(PATHS[name]).split("|"):
		var d := p.substr(2)
		if p.begins_with("f:"):
			parts += "<path d='%s' fill='%s' fill-opacity='%s'/>" % [d, hex, op]
		else:
			parts += "<path d='%s' fill='none' stroke='%s' stroke-opacity='%s' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'/>" % [d, hex, op]
	return "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d' viewBox='0 0 24 24'>%s</svg>" % [size, size, parts]


static func rect(name: String, size := 24, col: Color = Color.WHITE) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex(name, size, col)
	r.custom_minimum_size = Vector2(size, size)
	r.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return r


static func clear() -> void:
	_cache.clear()
