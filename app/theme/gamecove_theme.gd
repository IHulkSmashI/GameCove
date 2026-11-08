extends RefCounted
## GameCove's theme, built in code from the current theme's tokens
## (theme/themes.gd), so switching themes is one call: ThemeLib.use(id) then
## put ThemeLib.build() on the root control. Every control below re-reads
## tokens on NOTIFICATION_THEME_CHANGED, so the switch is live.
## Sized for 1280x800 on a 7-8" screen read from arm's length; see docs/DESIGN.md.

const Themes := preload("res://theme/themes.gd")
const ArtColor := preload("res://theme/art_color.gd")

# ------------------------------------------------------------ type scale
## px at 1280x800 (the viewport scales up on bigger panels).
const SIZE_MICRO := 13
const SIZE_CAPTION := 15
const SIZE_SMALL := 17
const SIZE_BODY := 19
const SIZE_LEAD := 22
const SIZE_TITLE := 26
const SIZE_HEADLINE := 36
const SIZE_DISPLAY := 54

## Kept for older callers.
const FONT := SIZE_BODY
const FONT_QUIET := SIZE_SMALL
const FONT_HEADER := SIZE_TITLE
const FONT_TITLE := SIZE_HEADLINE

const FONT_FILES := {
	"regular": "res://fonts/Inter-Regular.otf",
	"medium": "res://fonts/Inter-Medium.otf",
	"semibold": "res://fonts/Inter-SemiBold.otf",
	"display": "res://fonts/InterDisplay-Bold.otf",
}

static var theme_id := "cove"
static var tokens: Dictionary = Themes.get_theme("cove").duplicate()
static var _fonts := {}


## Switch the current tokens. `accent` (optional, e.g. devices.json "accent")
## replaces the theme accent after it's been made readable on this theme.
static func use(id: String, accent: Color = Color(0, 0, 0, 0)) -> void:
	theme_id = id if Themes.has_theme(id) else "cove"
	tokens = Themes.get_theme(theme_id).duplicate()
	if accent.a > 0.0:
		var a := ArtColor.accent_for(accent, tokens)
		tokens["accent"] = a
		tokens["on_accent"] = ArtColor.on_color(a)


static func tok(name: String) -> Variant:
	return tokens.get(name, Themes.get_theme("cove").get(name))


static func color(name: String, alpha := -1.0) -> Color:
	var c: Color = tok(name)
	if alpha >= 0.0:
		c.a = alpha
	return c


static func radius(name := "m") -> int:
	return int(tok("radius_" + name))


static func is_dark() -> bool:
	return int(tok("dark")) == 1


## weight: regular | medium | semibold | display. `tabular` turns on tabular
## figures (clock, battery, slider values) so numbers don't jiggle.
static func font(weight := "regular", tabular := false) -> Font:
	var key := weight + ("+tnum" if tabular else "")
	if _fonts.has(key):
		return _fonts[key]
	var base: Font = load(FONT_FILES.get(weight, FONT_FILES["regular"]))
	var f: Font = base
	if tabular:
		var v := FontVariation.new()
		v.base_font = base
		v.opentype_features = {TextServerManager.get_primary_interface().name_to_tag("tnum"): 1}
		f = v
	_fonts[key] = f
	return f


static func box(bg: Color, r := -1, pad_x := 16, pad_y := 10) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(r if r >= 0 else radius("m"))
	s.content_margin_left = pad_x
	s.content_margin_right = pad_x
	s.content_margin_top = pad_y
	s.content_margin_bottom = pad_y
	s.anti_aliasing = true
	s.corner_detail = 10
	return s


## A ring drawn just outside the control, so it never shifts layout.
static func focus_ring(r := -1, col: Color = Color(0, 0, 0, 0), width := 3) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.draw_center = false
	s.border_color = col if col.a > 0.0 else color("accent")
	s.set_border_width_all(width)
	var rr := r if r >= 0 else radius("m")
	s.set_corner_radius_all(rr + 4)
	s.set_expand_margin_all(4)
	s.anti_aliasing = true
	s.corner_detail = 10
	return s


## Frosted panel: translucent over the already-blurred backdrop, a hairline
## border and a soft shadow.
static func glass(r := -1, pad_x := 24, pad_y := 20) -> StyleBoxFlat:
	var s := box(color("glass"), r if r >= 0 else radius("xl"), pad_x, pad_y)
	s.border_color = color("line")
	s.set_border_width_all(1)
	s.shadow_color = Color(0, 0, 0, 0.35 if is_dark() else 0.12)
	s.shadow_size = 24
	return s


## A soft fill that reads on art and on panels: the text colour at low alpha.
static func soft(alpha := 0.10) -> Color:
	return color("text", alpha)


static func build(t: Dictionary = tokens) -> Theme:
	var saved := tokens
	tokens = t
	var th := Theme.new()
	th.default_font = font("regular")
	th.default_font_size = SIZE_BODY

	# Tokens are also on the theme, so nodes can read them with get_theme_color.
	for k in Themes.TOKENS:
		th.set_color(k, "GC", t[k])

	th.set_color("font_color", "Label", color("text"))
	_label(th, "QuietLabel", SIZE_SMALL, "text_2", "regular")
	_label(th, "CaptionLabel", SIZE_CAPTION, "text_2", "medium")
	_label(th, "HeaderLabel", SIZE_TITLE, "text", "semibold")
	_label(th, "LeadLabel", SIZE_LEAD, "text", "medium")
	_label(th, "TitleLabel", SIZE_HEADLINE, "text", "display")
	_label(th, "DisplayLabel", SIZE_DISPLAY, "text", "display")
	_label(th, "AccentLabel", SIZE_SMALL, "accent", "semibold")
	_label(th, "ValueLabel", SIZE_BODY, "accent", "semibold", true)
	_label(th, "NumberLabel", SIZE_BODY, "text", "medium", true)

	# Plain buttons: soft fill; focused turns solid (console style), so focus
	# is obvious from across the room.
	var on_art := soft(0.12)
	_button(th, "Button", on_art, soft(0.18), soft(0.22), color("text"))
	th.set_font("font", "Button", font("semibold"))
	var f := box(color("focus_fill"))
	th.set_stylebox("focus", "Button", f)
	th.set_color("font_focus_color", "Button", color("on_focus"))
	th.set_color("font_hover_pressed_color", "Button", color("text"))

	th.set_type_variation("AccentButton", "Button")
	var acc: Color = t["accent"]
	_button(th, "AccentButton", acc, acc.lightened(0.10), acc.darkened(0.10), color("on_accent"))
	th.set_font_size("font_size", "AccentButton", SIZE_LEAD)
	th.set_font("font", "AccentButton", font("semibold"))
	var af := box(acc.lightened(0.14))
	af.border_color = color("text")
	af.set_border_width_all(3)
	af.set_expand_margin_all(3)
	th.set_stylebox("focus", "AccentButton", af)
	th.set_color("font_focus_color", "AccentButton", color("on_accent"))

	# Top-bar tabs: quiet text, a soft pill when chosen, solid when focused.
	th.set_type_variation("TabButton", "Button")
	_button(th, "TabButton", Color(0, 0, 0, 0), soft(0.08), soft(0.14), color("text_2"), 999, 18, 8)
	th.set_font("font", "TabButton", font("semibold"))
	th.set_font_size("font_size", "TabButton", SIZE_LEAD)
	for c in ["font_pressed_color", "font_hover_pressed_color", "font_hover_color"]:
		th.set_color(c, "TabButton", color("text"))
	th.set_stylebox("focus", "TabButton", focus_ring(22))
	th.set_color("font_focus_color", "TabButton", color("text"))

	# Quick menu section tabs: icon over label.
	th.set_type_variation("SectionTab", "Button")
	_button(th, "SectionTab", Color(0, 0, 0, 0), soft(0.08), soft(0.14), color("text_2"), radius("m"), 4, 8)
	th.set_font("font", "SectionTab", font("semibold"))
	th.set_font_size("font_size", "SectionTab", SIZE_CAPTION)
	th.set_constant("h_separation", "SectionTab", 4)
	for c in ["font_pressed_color", "font_hover_pressed_color", "font_hover_color"]:
		th.set_color(c, "SectionTab", color("text"))
	th.set_stylebox("focus", "SectionTab", focus_ring(radius("m")))
	th.set_color("font_focus_color", "SectionTab", color("text"))

	# Filter / sort chips.
	th.set_type_variation("ChipButton", "Button")
	_button(th, "ChipButton", soft(0.08), soft(0.14), acc, color("text_2"), 999, 18, 6)
	th.set_font("font", "ChipButton", font("semibold"))
	th.set_font_size("font_size", "ChipButton", SIZE_SMALL)
	for c in ["font_pressed_color", "font_hover_pressed_color"]:
		th.set_color(c, "ChipButton", color("on_accent"))
	th.set_stylebox("hover_pressed", "ChipButton", box(acc.lightened(0.08), 999, 18, 6))
	th.set_stylebox("focus", "ChipButton", focus_ring(999, color("text"), 3))
	th.set_color("font_focus_color", "ChipButton", color("text"))

	# Setting rows: content drawn by the row itself; focus is a ring and a lift.
	th.set_type_variation("RowButton", "Button")
	var row_bg := soft(0.06) if is_dark() else color("surface_2")
	_button(th, "RowButton", row_bg, soft(0.10), soft(0.12), color("text"), radius("m"), 18, 10)
	var rf := box(soft(0.13) if is_dark() else color("surface_3"))
	rf.border_color = acc
	rf.set_border_width_all(2)
	th.set_stylebox("focus", "RowButton", rf)

	# Tiles draw their own card, ring and glow.
	th.set_type_variation("TileButton", "Button")
	var empty := StyleBoxEmpty.new()
	for st in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		th.set_stylebox(st, "TileButton", empty)

	# On-screen keyboard keys.
	th.set_type_variation("KeyButton", "Button")
	_button(th, "KeyButton", soft(0.08), soft(0.14), soft(0.2), color("text"), radius("s"), 6, 6)
	th.set_font("font", "KeyButton", font("medium"))
	th.set_font_size("font_size", "KeyButton", SIZE_LEAD)
	th.set_stylebox("focus", "KeyButton", box(color("focus_fill"), radius("s"), 6, 6))
	th.set_color("font_focus_color", "KeyButton", color("on_focus"))

	# Icons are drawn white and tinted per state, like the text.
	_icons(th, "Button", color("text"), color("on_focus"), color("text"))
	_icons(th, "AccentButton", color("on_accent"), color("on_accent"), color("on_accent"))
	_icons(th, "TabButton", color("text_2"), color("text"), color("text"))
	_icons(th, "SectionTab", color("text_2"), color("text"), color("text"))
	_icons(th, "ChipButton", color("text_2"), color("text"), color("on_accent"))
	_icons(th, "KeyButton", color("text"), color("on_focus"), color("text"))
	_icons(th, "RowButton", color("text_2"), color("text"), color("text"))

	th.set_stylebox("panel", "PanelContainer", box(color("surface"), radius("l"), 20, 18))
	th.set_type_variation("GlassPanel", "PanelContainer")
	th.set_stylebox("panel", "GlassPanel", glass())
	th.set_type_variation("RaisedPanel", "PanelContainer")
	th.set_stylebox("panel", "RaisedPanel", box(soft(0.06) if is_dark() else color("surface"), radius("l"), 18, 14))
	var card := box(Color(color("surface"), 0.74) if is_dark() else Color(color("surface"), 0.92), radius("l"), 20, 18)
	card.border_color = color("line")
	card.set_border_width_all(1)
	th.set_type_variation("CardPanel", "PanelContainer")
	th.set_stylebox("panel", "CardPanel", card)
	th.set_type_variation("BadgePanel", "PanelContainer")
	th.set_stylebox("panel", "BadgePanel", box(color("chip"), radius("s"), 8, 3))

	# Sliders: thick rounded track, accent fill, round grabber.
	var track := box(soft(0.16), 999, 0, 4)
	th.set_stylebox("slider", "HSlider", track)
	var fill := box(acc, 999, 0, 4)
	th.set_stylebox("grabber_area", "HSlider", fill)
	th.set_stylebox("grabber_area_highlight", "HSlider", fill)
	th.set_stylebox("focus", "HSlider", focus_ring(999, Color(0, 0, 0, 0), 2))
	th.set_icon("grabber", "HSlider", _knob(false))
	th.set_icon("grabber_highlight", "HSlider", _knob(true))
	th.set_icon("grabber_disabled", "HSlider", _knob(false))

	var bar := box(soft(0.20), 999, 0, 0)
	for sb in ["VScrollBar", "HScrollBar"]:
		th.set_stylebox("grabber", sb, bar)
		th.set_stylebox("grabber_highlight", sb, box(soft(0.32), 999, 0, 0))
		th.set_stylebox("grabber_pressed", sb, box(soft(0.32), 999, 0, 0))
	th.set_stylebox("scroll", "VScrollBar", box(Color(0, 0, 0, 0), 999, 2, 0))
	th.set_stylebox("scroll", "HScrollBar", box(Color(0, 0, 0, 0), 999, 0, 2))

	var le := box(soft(0.08), 999, 22, 10)
	le.border_color = color("line")
	le.set_border_width_all(1)
	th.set_stylebox("normal", "LineEdit", le)
	th.set_stylebox("read_only", "LineEdit", le)
	th.set_stylebox("focus", "LineEdit", focus_ring(999))
	th.set_color("font_color", "LineEdit", color("text"))
	th.set_color("font_uneditable_color", "LineEdit", color("text"))
	th.set_color("font_placeholder_color", "LineEdit", color("text_3"))
	th.set_font_size("font_size", "LineEdit", SIZE_LEAD)

	th.set_stylebox("panel", "TooltipPanel", box(color("surface_3"), radius("s"), 10, 6))
	th.set_color("font_color", "TooltipLabel", color("text"))
	tokens = saved
	return th


static func _icons(th: Theme, type: String, normal: Color, focus: Color, pressed: Color) -> void:
	th.set_color("icon_normal_color", type, normal)
	th.set_color("icon_hover_color", type, normal.lerp(color("text"), 0.6))
	th.set_color("icon_focus_color", type, focus)
	th.set_color("icon_pressed_color", type, pressed)
	th.set_color("icon_hover_pressed_color", type, pressed)
	th.set_color("icon_disabled_color", type, color("text_3"))


static func _label(th: Theme, type: String, size: int, col: String, weight: String, tabular := false) -> void:
	th.set_type_variation(type, "Label")
	th.set_font_size("font_size", type, size)
	th.set_color("font_color", type, color(col))
	th.set_font("font", type, font(weight, tabular))


static func _button(th: Theme, type: String, normal: Color, hover: Color, pressed: Color, fnt: Color,
		r := -1, px := 18, py := 10) -> void:
	th.set_stylebox("normal", type, box(normal, r, px, py))
	th.set_stylebox("hover", type, box(hover, r, px, py))
	th.set_stylebox("pressed", type, box(pressed, r, px, py))
	th.set_stylebox("hover_pressed", type, box(pressed, r, px, py))
	var dis := box(Color(normal, normal.a * 0.45), r, px, py)
	th.set_stylebox("disabled", type, dis)
	th.set_stylebox("focus", type, focus_ring(r))
	for c in ["font_color", "font_focus_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		th.set_color(c, type, fnt)
	th.set_color("font_disabled_color", type, color("text_3"))


static var _knobs := {}

## Slider knob, rasterised at 2x for crisp edges on 1920x1200.
static func _knob(focused: bool) -> Texture2D:
	var key := "%s|%s|%s" % [focused, color("accent").to_html(), color("text").to_html()]
	if _knobs.has(key):
		return _knobs[key]
	var fill := "#" + Color("#FFFFFF").to_html(false)
	var ring := "#" + color("accent").to_html(false)
	var svg := ""
	if focused:
		svg = "<svg xmlns='http://www.w3.org/2000/svg' width='36' height='36'><circle cx='18' cy='18' r='16' fill='%s' fill-opacity='0.30'/><circle cx='18' cy='18' r='11' fill='%s'/><circle cx='18' cy='18' r='11' fill='none' stroke='%s' stroke-width='3'/></svg>" % [ring, fill, ring]
	else:
		svg = "<svg xmlns='http://www.w3.org/2000/svg' width='36' height='36'><circle cx='18' cy='19' r='11' fill='#000' fill-opacity='0.25'/><circle cx='18' cy='18' r='10' fill='%s'/></svg>" % fill
	var img := Image.new()
	img.load_svg_from_string(svg, 1.0)
	var tex := ImageTexture.create_from_image(img)
	_knobs[key] = tex
	return tex
