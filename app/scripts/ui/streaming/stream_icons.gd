extends RefCounted
## Line icons for the Streaming page, drawn like icons.gd (24 px grid, 2 px
## round strokes, "s:" stroke / "f:" fill). Unknown names fall back to
## game_icons.gd, then icons.gd.

const GameIcons := preload("res://scripts/ui/games/game_icons.gd")
const Icons := preload("res://scripts/ui/icons.gd")

const PATHS := {
	"pc": "s:M4 4.5h16A1.5 1.5 0 0 1 21.5 6v9.5A1.5 1.5 0 0 1 20 17H4a1.5 1.5 0 0 1-1.5-1.5V6A1.5 1.5 0 0 1 4 4.5z|s:M12 17v3|s:M8 20.5h8",
	"stream": "s:M4 4.5h16A1.5 1.5 0 0 1 21.5 6v9.5A1.5 1.5 0 0 1 20 17H4a1.5 1.5 0 0 1-1.5-1.5V6A1.5 1.5 0 0 1 4 4.5z|f:M10 8v5.5c0 .4.4.6.7.4l4.2-2.7c.3-.2.3-.6 0-.8l-4.2-2.7c-.3-.2-.7 0-.7.3z|s:M8 20.5h8",
	"moon": "s:M19.5 14.5A8 8 0 0 1 9.5 4.5a8 8 0 1 0 10 10z",
	"sun": "s:M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8z|s:M12 2.5v2|s:M12 19.5v2|s:M2.5 12h2|s:M19.5 12h2|s:M5.3 5.3l1.4 1.4|s:M17.3 17.3l1.4 1.4|s:M5.3 18.7l1.4-1.4|s:M17.3 6.7l1.4-1.4",
	"link": "s:M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1|s:M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1",
	"plus": "s:M12 5v14|s:M5 12h14",
	"signal": "f:M4 16h3v4H4z|f:M9.5 12h3v8h-3z|f:M15 8h3v12h-3z",
	"globe": "s:M12 3.5a8.5 8.5 0 1 0 0 17 8.5 8.5 0 0 0 0-17z|s:M3.5 12h17|s:M12 3.5c2.3 2.3 3.4 5.2 3.4 8.5s-1.1 6.2-3.4 8.5c-2.3-2.3-3.4-5.2-3.4-8.5S9.7 5.8 12 3.5z",
	"house": "s:M4 10.5 12 4l8 6.5V19a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 19z",
	"key": "s:M8 10.5a4 4 0 1 0 0 3|s:M12 12h9|s:M18 12v3|s:M15 12v2",
	"qr": "s:M4 4h6v6H4z|s:M14 4h6v6h-6z|s:M4 14h6v6H4z|f:M14 14h2.5v2.5H14z|f:M17.5 17.5H20V20h-2.5z|f:M14 17.5h2.5V20H14z|f:M17.5 14H20v2.5h-2.5z",
}

static var _cache := {}


static func tex(name: String, size := 24, col: Color = Color.WHITE) -> Texture2D:
	if not PATHS.has(name):
		return GameIcons.tex(name, size, col)
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


static func clear() -> void:
	_cache.clear()


## The empty-state picture: a PC and a handheld joined by a signal, in the
## theme's accents (same construction as illustrations.gd).
static func illustration_svg(acc: Color, acc2: Color, line: Color, bg: Color, size := 220) -> String:
	var a := "#" + acc.to_html(false)
	var b := "#" + acc2.to_html(false)
	var l := "#" + line.to_html(false)
	var g := "#" + bg.to_html(false)
	var body := ""
	body += "<rect x='22' y='44' width='112' height='76' rx='10' fill='%s' fill-opacity='0.30'/>" % b
	body += "<rect x='30' y='52' width='96' height='60' rx='6' fill='%s' fill-opacity='0.85'/>" % a
	body += "<path d='M68 74v16l14-8z' fill='%s'/>" % g
	body += "<path d='M66 120h24M78 120v14M60 136h36' stroke='%s' stroke-width='6' stroke-linecap='round'/>" % l
	body += "<path d='M136 70c10-8 22-8 32 0M142 80c6-5 14-5 20 0' stroke='%s' stroke-width='6' stroke-linecap='round' fill='none' stroke-opacity='0.8'/>" % a
	body += "<rect x='112' y='132' width='96' height='50' rx='22' fill='%s' fill-opacity='0.92'/>" % l
	body += "<rect x='138' y='142' width='44' height='30' rx='4' fill='%s'/>" % a
	body += "<circle cx='125' cy='157' r='5' fill='%s'/><circle cx='195' cy='157' r='5' fill='%s'/>" % [g, g]
	return "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d' viewBox='0 0 220 220'>%s</svg>" % [size, size, body]
