extends RefCounted
## Spot illustrations for empty states, drawn as SVG in the current theme's
## colours: a stack of game cards on a wave (empty library), a magnifier over
## cards (no search results), a tag and calendar (Discover).

const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Icons := preload("res://scripts/ui/icons.gd")


static func _hex(c: Color) -> String:
	return "#" + c.to_html(false)


static func svg(kind: String, size := 220) -> String:
	var acc := _hex(ThemeLib.color("accent"))
	var acc2 := _hex(ThemeLib.color("accent_2"))
	var line := _hex(ThemeLib.color("text"))
	var body := ""
	match kind:
		"no_results":
			body = "<rect x='40' y='54' width='64' height='92' rx='10' fill='%s' fill-opacity='0.18'/>" % acc2
			body += "<rect x='78' y='40' width='64' height='92' rx='10' fill='%s' fill-opacity='0.28'/>" % acc
			body += "<circle cx='132' cy='118' r='34' fill='none' stroke='%s' stroke-width='8'/>" % line
			body += "<path d='M156 142 182 168' stroke='%s' stroke-width='10' stroke-linecap='round'/>" % line
			body += "<path d='M118 118h28' stroke='%s' stroke-width='6' stroke-linecap='round' stroke-opacity='0.6'/>" % line
		"discover":
			body = "<rect x='36' y='60' width='86' height='100' rx='14' fill='%s' fill-opacity='0.22'/>" % acc2
			body += "<rect x='36' y='60' width='86' height='26' rx='13' fill='%s' fill-opacity='0.55'/>" % acc2
			body += "<path d='M58 54v16M100 54v16' stroke='%s' stroke-width='6' stroke-linecap='round'/>" % line
			body += "<path d='M104 96 L150 50 H186 V86 L140 132 Z' fill='%s' fill-opacity='0.85'/>" % acc
			body += "<circle cx='168' cy='68' r='7' fill='%s'/>" % _hex(ThemeLib.color("bg"))
			body += "<path d='M150 150l6 13 14 2-10 10 2 14-12-7-12 7 2-14-10-10 14-2z' fill='%s' fill-opacity='0.9'/>" % line
		_:
			body = "<path d='M10 168c30-14 50-14 80 0s50 14 80 0 30-10 40-6v38H10z' fill='%s' fill-opacity='0.30'/>" % acc
			body += "<path d='M10 182c30-12 50-12 80 0s50 12 80 0 30-8 40-4v26H10z' fill='%s' fill-opacity='0.55'/>" % acc
			body += "<rect x='52' y='44' width='62' height='92' rx='10' transform='rotate(-10 83 90)' fill='%s' fill-opacity='0.35'/>" % acc2
			body += "<rect x='106' y='40' width='62' height='92' rx='10' transform='rotate(9 137 86)' fill='%s' fill-opacity='0.45'/>" % acc
			body += "<rect x='79' y='30' width='62' height='92' rx='10' fill='%s' fill-opacity='0.92'/>" % line
			body += "<path d='M101 64v26l22-13z' fill='%s'/>" % _hex(ThemeLib.color("bg"))
	return "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d' viewBox='0 0 220 220'>%s</svg>" % [size, size, body]


static func rect(kind: String, size := 220) -> TextureRect:
	var r := TextureRect.new()
	r.name = "Illustration"
	r.texture = Icons.from_svg(svg(kind, size))
	r.custom_minimum_size = Vector2(size, size)
	r.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r
