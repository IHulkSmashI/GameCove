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
const SIZE_MICRO := 12
const SIZE_CAPTION := 15
const SIZE_SMALL := 17
const SIZE_BODY := 19
const SIZE_LEAD := 22
const SIZE_TITLE := 26
const SIZE_HEADLINE := 36
const SIZE_DISPLAY := 52

## Kept for older callers.
const FONT := SIZE_BODY
const FONT_QUIET := SIZE_SMALL
const FONT_HEADER := SIZE_TITLE
const FONT_TITLE := SIZE_HEADLINE

# ------------------------------------------------------------ spacing scale
## Every gap, margin and padding comes from this scale (px at 1280x800).
const SPACE_1 := 4
const SPACE_2 := 8
const SPACE_3 := 12
const SPACE_4 := 16
const SPACE_5 := 24
const SPACE_6 := 32
const SPACE_7 := 48
## Screen edge margin, top bar and hint bar heights.
const EDGE := 32
const TOP_BAR_H := 64
const HINT_BAR_H := 52

## Outfit: display and headings. Plus Jakarta Sans: interface text.
## JetBrains Mono: telemetry, micro labels, counts. All OFL-1.1, Latin subset.
const FONT_FILES := {
	"regular": "res://fonts/PlusJakartaSans-Regular.ttf",
	"medium": "res://fonts/PlusJakartaSans-Medium.ttf",
	"semibold": "res://fonts/PlusJakartaSans-SemiBold.ttf",
	"bold": "res://fonts/PlusJakartaSans-Bold.ttf",
	"heading": "res://fonts/Outfit-SemiBold.ttf",
	"heading_bold": "res://fonts/Outfit-Bold.ttf",
	"display": "res://fonts/Outfit-ExtraBold.ttf",
	"display_tight": "res://fonts/Outfit-ExtraBold.ttf",
	"mono": "res://fonts/JetBrainsMono-Medium.ttf",
	"mono_bold": "res://fonts/JetBrainsMono-Bold.ttf",
}
## Letter spacing (px) baked into some weights: tight display, wide mono labels.
const TRACKING := {"display_tight": -1}

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
		tokens["accent_end"] = ArtColor.gradient_end(a, tokens["on_accent"], tokens)
		tokens["ring"] = a
		tokens["glow"] = Color(a, (tokens["glow"] as Color).a)


static func tok(name: String) -> Variant:
	return tokens.get(name, Themes.get_theme("cove").get(name))


static func color(name: String, alpha := -1.0) -> Color:
	var c: Color = tok(name)
	if alpha >= 0.0:
		c.a = alpha
	return c


## A badge tone colour for the current theme (Themes.TONES / TONES_LIGHT).
static func tone(name: String) -> Color:
	# "accent" follows the theme (Sunset's orange, Midnight's blue), not Cove's cyan.
	if name == "accent":
		return color("accent")
	var set := Themes.tones(theme_id)
	return set.get(name, set[""])


static func radius(name := "m") -> int:
	return int(tok("radius_" + name))


static func is_dark() -> bool:
	return int(tok("dark")) == 1


## weight: regular | medium | semibold | bold (Plus Jakarta Sans), heading |
## heading_bold | display | display_tight (Outfit), mono | mono_bold (JetBrains
## Mono). `tabular` turns on tabular figures (clock, battery, slider values) so
## numbers don't jiggle. `tracking` adds letter spacing in px (wide mono labels).
static func font(weight := "regular", tabular := false, tracking := 0) -> Font:
	var key := "%s%s@%d" % [weight, "+tnum" if tabular else "", tracking]
	if _fonts.has(key):
		return _fonts[key]
	var base: Font = load(FONT_FILES.get(weight, FONT_FILES["regular"]))
	var spacing: int = TRACKING.get(weight, 0) + tracking
	if spacing == 0 and not tabular:
		_fonts[key] = base
		return base
	var v := FontVariation.new()
	v.base_font = base
	v.spacing_glyph = spacing
	if tabular and not weight.begins_with("mono"):
		v.opentype_features = {TextServerManager.get_primary_interface().name_to_tag("tnum"): 1}
	_fonts[key] = v
	return v


## Mono micro-label font: JetBrains Mono, tracked wide (READY TO RESUME).
static func mono(bold := false, tracking := 2) -> Font:
	return font("mono_bold" if bold else "mono", false, tracking)


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


## A ring drawn just outside the control (a 1 px gap, then `width` px), so it
## never shifts layout. With `glow`, a soft halo in the glow colour too.
static func focus_ring(r := -1, col: Color = Color(0, 0, 0, 0), width := 2, glow := false) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.draw_center = false
	s.border_color = col if col.a > 0.0 else color("ring")
	s.set_border_width_all(width)
	var rr := r if r >= 0 else radius("m")
	s.set_corner_radius_all(rr + width + 1 if rr < 900 else rr)
	s.set_expand_margin_all(width + 1)
	s.anti_aliasing = true
	s.corner_detail = 12
	if glow:
		s.shadow_color = Color(color("glow"), color("glow").a * 0.6)
		s.shadow_size = int(tok("glow_size"))
	return s


## The selected-row look: a thick ring hugging the card, a cyan glow that
## falls below it, and the card's own dark fill (no tint), so text keeps its
## contrast. Rows, list items and device cards share it.
static func row_focus(r := -1) -> StyleBoxFlat:
	var rr := r if r >= 0 else radius("m")
	var s := focus_ring(rr, color("ring"), 3)
	s.draw_center = true
	# Opaque: a StyleBoxFlat's shadow shows through a see-through centre.
	var base: Color = color("surface_2") if is_dark() else color("surface")
	s.bg_color = base.lerp(color("ring"), 0.04)
	s.bg_color.a = 1.0
	var g: Color = color("glow")
	s.shadow_color = Color(g, g.a * 0.6)
	s.shadow_size = int(tok("glow_size"))
	s.shadow_offset = Vector2(0, 4)
	return s


## A pill (fully rounded) with an optional hairline border.
static func pill(bg: Color, border: Color = Color(0, 0, 0, 0), pad_x := 20, pad_y := 10) -> StyleBoxFlat:
	var s := box(bg, 999, pad_x, pad_y)
	if border.a > 0.0:
		s.border_color = border
		s.set_border_width_all(1)
	return s


## Frosted panel: translucent over the already-blurred backdrop, a hairline
## border and a soft shadow.
static func glass(r := -1, pad_x := 24, pad_y := 20) -> StyleBoxFlat:
	var s := box(color("glass"), r if r >= 0 else radius("xl"), pad_x, pad_y)
	s.border_color = color("line_2")
	s.set_border_width_all(1)
	s.shadow_color = Color(0, 0, 0, 0.40 if is_dark() else 0.12)
	s.shadow_size = 28
	s.shadow_offset = Vector2(0, 8)
	return s


## A glass card for content on art: darker glass, hairline, rounded `radius_l`.
static func card(pad_x := 20, pad_y := 18) -> StyleBoxFlat:
	var c := box(Color(color("glass"), color("glass").a * 0.9), radius("l"), pad_x, pad_y)
	c.border_color = color("line_2")
	c.set_border_width_all(1)
	return c


## A soft fill that reads on art and on panels: the text colour at low alpha.
static func soft(alpha := 0.10) -> Color:
	return color("text", alpha)


static var _gradients := {}

## A horizontal gradient pill (primary buttons, slider fills) as a nine-patch
## StyleBoxTexture from an SVG DPITexture, so it stays crisp at any scale.
## `h` is the source height; the stretch keeps the caps round for any height
## >= h. `sheen` adds a faint light edge along the top.
static func gradient_pill(c1: Color, c2: Color, h := 40, pad_x := 24, pad_y := 10, sheen := true) -> StyleBoxTexture:
	var key := "%s|%s|%d|%s" % [c1.to_html(), c2.to_html(), h, sheen]
	var tex: Texture2D = _gradients.get(key)
	if tex == null:
		var w := h * 3
		var r := h / 2.0
		var sh := ""
		if sheen:
			sh = "<rect x='1' y='1' width='%d' height='%d' rx='%.1f' fill='none' stroke='#FFFFFF' stroke-opacity='0.28' stroke-width='1'/>" % [w - 2, h - 2, r - 1]
		var svg := "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d'><defs><linearGradient id='g' x1='0' y1='0' x2='1' y2='0'><stop offset='0' stop-color='#%s' stop-opacity='%.3f'/><stop offset='1' stop-color='#%s' stop-opacity='%.3f'/></linearGradient></defs><rect width='%d' height='%d' rx='%.1f' fill='url(#g)'/>%s</svg>" % [
			w, h, c1.to_html(false), c1.a, c2.to_html(false), c2.a, w, h, r, sh]
		tex = load("res://scripts/ui/icons.gd").from_svg(svg)
		_gradients[key] = tex
	var sb := StyleBoxTexture.new()
	sb.texture = tex
	var m := h / 2.0
	sb.texture_margin_left = m
	sb.texture_margin_right = m
	sb.texture_margin_top = m - 1
	sb.texture_margin_bottom = m - 1
	sb.content_margin_left = pad_x
	sb.content_margin_right = pad_x
	sb.content_margin_top = pad_y
	sb.content_margin_bottom = pad_y
	return sb


## A rounded-rectangle gradient box (chosen list items), corners `r`, with a
## hairline in `border` (a = 0: none).
static func gradient_box(c1: Color, c2: Color, r := 12, border: Color = Color(0, 0, 0, 0), pad_x := 16, pad_y := 10) -> StyleBoxTexture:
	var key := "box|%s|%s|%d|%s" % [c1.to_html(), c2.to_html(), r, border.to_html()]
	var tex: Texture2D = _gradients.get(key)
	if tex == null:
		var w := r * 6
		var h := r * 4
		var edge := ""
		if border.a > 0.0:
			edge = "<rect x='0.5' y='0.5' width='%d' height='%d' rx='%.1f' fill='none' stroke='#%s' stroke-opacity='%.3f' stroke-width='1'/>" % [w - 1, h - 1, r - 0.5, border.to_html(false), border.a]
		var svg := "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d'><defs><linearGradient id='g' x1='0' y1='0' x2='1' y2='0'><stop offset='0' stop-color='#%s' stop-opacity='%.3f'/><stop offset='1' stop-color='#%s' stop-opacity='%.3f'/></linearGradient></defs><rect width='%d' height='%d' rx='%d' fill='url(#g)'/>%s</svg>" % [
			w, h, c1.to_html(false), c1.a, c2.to_html(false), c2.a, w, h, r, edge]
		tex = load("res://scripts/ui/icons.gd").from_svg(svg)
		_gradients[key] = tex
	var sb := StyleBoxTexture.new()
	sb.texture = tex
	sb.texture_margin_left = r
	sb.texture_margin_right = r
	sb.texture_margin_top = r
	sb.texture_margin_bottom = r
	sb.content_margin_left = pad_x
	sb.content_margin_right = pad_x
	sb.content_margin_top = pad_y
	sb.content_margin_bottom = pad_y
	return sb


## The primary gradient for `a` (the theme accent or a game's art colour).
static func primary_colors(a: Color = Color(0, 0, 0, 0)) -> Array:
	if a.a <= 0.0:
		return [color("accent"), color("accent_end")]
	var on := ArtColor.on_color(a)
	return [a, ArtColor.gradient_end(a, on, tokens)]


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
	_label(th, "PromptLabel", SIZE_CAPTION, "text", "semibold")
	_label(th, "HeaderLabel", SIZE_TITLE, "text", "heading_bold")
	_label(th, "LeadLabel", SIZE_LEAD, "text", "heading")
	_label(th, "TitleLabel", SIZE_HEADLINE, "text", "display_tight")
	_label(th, "DisplayLabel", SIZE_DISPLAY, "text", "display_tight")
	_label(th, "AccentLabel", SIZE_SMALL, "accent", "bold")
	_label(th, "ValueLabel", SIZE_BODY, "accent", "semibold", true)
	_label(th, "NumberLabel", SIZE_BODY, "text", "medium", true)
	# Mono: micro labels (wide tracking), telemetry and the line above a title.
	_label(th, "MicroLabel", SIZE_MICRO, "text_2", "mono")
	th.set_font("font", "MicroLabel", mono(false, 2))
	_label(th, "MonoLabel", SIZE_CAPTION, "text", "mono")
	_label(th, "EyebrowLabel", 13, "accent", "mono_bold")
	th.set_font("font", "EyebrowLabel", mono(true, 3))

	var acc: Color = t["accent"]
	var ring: Color = t["ring"]
	var glow: Color = t["glow"]
	var gsize := int(t["glow_size"])

	# Secondary buttons: dark glass pills with a hairline. Focus: 2 px ring a
	# pixel outside, a soft glow and a faint tint (the focus box draws on top).
	_button(th, "Button", color("glass_2"), color("glass_2").lerp(soft(0.2), 0.35), soft(0.06), color("text"), 999, 22, 11)
	for st in ["normal", "hover", "pressed", "hover_pressed"]:
		var sb: StyleBoxFlat = th.get_stylebox(st, "Button")
		sb.border_color = color("line_2")
		sb.set_border_width_all(1)
	th.set_font("font", "Button", font("bold"))
	th.set_font_size("font_size", "Button", SIZE_SMALL + 1)
	var bf := focus_ring(999, ring, 2)
	bf.draw_center = true
	bf.bg_color = Color(ring, 0.10 if is_dark() else 0.08)
	bf.shadow_color = Color(glow, glow.a * 0.55)
	bf.shadow_size = gsize
	th.set_stylebox("focus", "Button", bf)
	th.set_color("font_focus_color", "Button", color("text"))
	th.set_color("font_hover_pressed_color", "Button", color("text"))
	th.set_constant("h_separation", "Button", 10)

	# Primary: the cyan-to-violet gradient pill (accent -> accent_end), heading
	# face; the focus ring is lighter so it reads next to the cyan end.
	th.set_type_variation("AccentButton", "Button")
	var c2: Color = t["accent_end"]
	th.set_stylebox("normal", "AccentButton", gradient_pill(acc, c2, 40, 26, 11))
	th.set_stylebox("hover", "AccentButton", gradient_pill(acc.lightened(0.10), c2.lightened(0.10), 40, 26, 11))
	th.set_stylebox("pressed", "AccentButton", gradient_pill(acc.darkened(0.12), c2.darkened(0.12), 40, 26, 11))
	th.set_stylebox("hover_pressed", "AccentButton", gradient_pill(acc.darkened(0.12), c2.darkened(0.12), 40, 26, 11))
	th.set_stylebox("disabled", "AccentButton", pill(soft(0.08), color("line"), 26, 11))
	# The glow behind primaries comes from button_fx.gd; focus adds the ring.
	var af := focus_ring(999, ring.lerp(Color.WHITE, 0.55) if is_dark() else ring, 2)
	th.set_stylebox("focus", "AccentButton", af)
	th.set_font("font", "AccentButton", font("heading_bold", false, 1))
	th.set_font_size("font_size", "AccentButton", SIZE_LEAD - 2)
	for c in ["font_color", "font_focus_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		th.set_color(c, "AccentButton", color("on_accent"))
	th.set_color("font_disabled_color", "AccentButton", color("text_3"))

	# Icon-only round button ("more", search).
	th.set_type_variation("IconButton", "Button")
	_button(th, "IconButton", color("glass_2"), color("glass_2").lerp(soft(0.2), 0.35), soft(0.06), color("text"), 999, 12, 12)
	for st in ["normal", "hover", "pressed", "hover_pressed"]:
		var ib: StyleBoxFlat = th.get_stylebox(st, "IconButton")
		ib.border_color = color("line_2")
		ib.set_border_width_all(1)
	th.set_stylebox("focus", "IconButton", bf)

	# Top-bar tabs: quiet text inside the tab group; the chosen tab is a lifted
	# glass pill, focus is the ring.
	th.set_type_variation("TabButton", "Button")
	_button(th, "TabButton", Color(0, 0, 0, 0), soft(0.05), Color(0, 0, 0, 0), color("text_2"), 999, 16, 7)
	var chosen := pill(Color(acc, 0.15 if is_dark() else 0.10), Color(acc, 0.70), 16, 7)
	chosen.shadow_color = Color(glow, glow.a * 0.35)
	chosen.shadow_size = 8
	th.set_stylebox("pressed", "TabButton", chosen)
	th.set_stylebox("hover_pressed", "TabButton", chosen)
	th.set_font("font", "TabButton", font("bold"))
	th.set_font_size("font_size", "TabButton", SIZE_SMALL - 1)
	for c in ["font_pressed_color", "font_hover_pressed_color", "font_hover_color"]:
		th.set_color(c, "TabButton", color("text"))
	th.set_stylebox("focus", "TabButton", focus_ring(999, ring, 2, true))
	th.set_color("font_focus_color", "TabButton", color("text"))

	# Quick menu section tabs: segments of a pill group; the open one is a
	# solid accent segment.
	th.set_type_variation("SectionTab", "Button")
	_button(th, "SectionTab", Color(0, 0, 0, 0), soft(0.06), soft(0.10), color("text_2"), radius("s"), 8, 6)
	var sel := box(acc, radius("s"), 8, 6)
	sel.shadow_color = Color(glow, glow.a * 0.5)
	sel.shadow_size = 8
	th.set_stylebox("pressed", "SectionTab", sel)
	th.set_stylebox("hover_pressed", "SectionTab", sel)
	th.set_font("font", "SectionTab", font("semibold"))
	th.set_font_size("font_size", "SectionTab", SIZE_CAPTION - 1)
	th.set_constant("h_separation", "SectionTab", 4)
	for c in ["font_pressed_color", "font_hover_pressed_color"]:
		th.set_color(c, "SectionTab", color("on_accent"))
	th.set_color("font_hover_color", "SectionTab", color("text"))
	th.set_stylebox("focus", "SectionTab", focus_ring(radius("s"), ring, 2, true))
	th.set_color("font_focus_color", "SectionTab", color("text"))

	# Filter / sort chips: outline pills; chosen = accent-tinted fill and edge.
	th.set_type_variation("ChipButton", "Button")
	_button(th, "ChipButton", Color(0, 0, 0, 0), soft(0.06), Color(acc, 0.16), color("text_2"), 999, 16, 6)
	for st in ["normal", "hover"]:
		var cb: StyleBoxFlat = th.get_stylebox(st, "ChipButton")
		cb.border_color = color("line_2")
		cb.set_border_width_all(1)
	var on_chip := pill(Color(acc, 0.16 if is_dark() else 0.12), Color(acc, 0.70), 16, 6)
	th.set_stylebox("pressed", "ChipButton", on_chip)
	th.set_stylebox("hover_pressed", "ChipButton", on_chip)
	th.set_font("font", "ChipButton", font("semibold"))
	th.set_font_size("font_size", "ChipButton", SIZE_CAPTION + 1)
	for c in ["font_pressed_color", "font_hover_pressed_color"]:
		th.set_color(c, "ChipButton", acc if is_dark() else color("text"))
	th.set_stylebox("focus", "ChipButton", focus_ring(999, ring, 2, true))
	th.set_color("font_focus_color", "ChipButton", color("text"))

	# Setting rows: content drawn by the row itself; glass with a hairline,
	# focus is the ring plus a faint tint.
	th.set_type_variation("RowButton", "Button")
	var row_bg := Color(color("glass_2"), color("glass_2").a * 0.8) if is_dark() else color("surface")
	_button(th, "RowButton", row_bg, row_bg.lerp(soft(0.2), 0.3), soft(0.12), color("text"), radius("m"), 18, 10)
	for st in ["normal", "hover"]:
		var rb: StyleBoxFlat = th.get_stylebox(st, "RowButton")
		rb.border_color = color("line")
		rb.set_border_width_all(1)
	th.set_stylebox("focus", "RowButton", row_focus())

	# Tiles draw their own card, ring and glow.
	th.set_type_variation("TileButton", "Button")
	var empty := StyleBoxEmpty.new()
	for st in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		th.set_stylebox(st, "TileButton", empty)

	# On-screen keyboard keys: glass; focus is a solid light key.
	th.set_type_variation("KeyButton", "Button")
	_button(th, "KeyButton", soft(0.07), soft(0.13), soft(0.2), color("text"), radius("s"), 6, 6)
	th.set_font("font", "KeyButton", font("semibold"))
	th.set_font_size("font_size", "KeyButton", SIZE_LEAD)
	var kf := box(color("focus_fill"), radius("s"), 6, 6)
	kf.shadow_color = Color(glow, glow.a * 0.8)
	kf.shadow_size = gsize - 6
	th.set_stylebox("focus", "KeyButton", kf)
	th.set_color("font_focus_color", "KeyButton", color("on_focus"))

	# Icons are drawn white and tinted per state, like the text.
	_icons(th, "Button", color("text"), color("text"), color("text"))
	_icons(th, "IconButton", color("text"), color("text"), color("text"))
	_icons(th, "AccentButton", color("on_accent"), color("on_accent"), color("on_accent"))
	_icons(th, "TabButton", color("text_2"), color("text"), color("text"))
	_icons(th, "SectionTab", color("text_2"), color("text"), color("text"))
	_icons(th, "ChipButton", color("text_2"), color("text"), acc if is_dark() else color("text"))
	_icons(th, "KeyButton", color("text"), color("on_focus"), color("text"))
	_icons(th, "RowButton", color("text_2"), color("text"), color("text"))

	th.set_stylebox("panel", "PanelContainer", box(color("surface"), radius("l"), 20, 18))
	th.set_type_variation("GlassPanel", "PanelContainer")
	th.set_stylebox("panel", "GlassPanel", glass())
	th.set_type_variation("RaisedPanel", "PanelContainer")
	var raised := box(soft(0.05) if is_dark() else color("surface"), radius("l"), 18, 14)
	raised.border_color = color("line")
	raised.set_border_width_all(1)
	th.set_stylebox("panel", "RaisedPanel", raised)
	th.set_type_variation("CardPanel", "PanelContainer")
	th.set_stylebox("panel", "CardPanel", card())
	th.set_type_variation("BadgePanel", "PanelContainer")
	th.set_stylebox("panel", "BadgePanel", box(color("chip"), radius("s"), 8, 3))
	# Glass pills in the top bar (telemetry, status) and the tab group.
	th.set_type_variation("PillPanel", "PanelContainer")
	th.set_stylebox("panel", "PillPanel", pill(color("glass_2"), color("line_2"), 16, 6))

	# Sliders: slim track, gradient fill, round grabber.
	var track := box(soft(0.14), 999, 0, 3)
	th.set_stylebox("slider", "HSlider", track)
	var fill := gradient_pill(acc, c2, 8, 0, 3, false)
	th.set_stylebox("grabber_area", "HSlider", fill)
	th.set_stylebox("grabber_area_highlight", "HSlider", fill)
	th.set_stylebox("focus", "HSlider", focus_ring(999, Color(0, 0, 0, 0), 2))
	th.set_icon("grabber", "HSlider", _knob(false))
	th.set_icon("grabber_highlight", "HSlider", _knob(true))
	th.set_icon("grabber_disabled", "HSlider", _knob(false))
	th.set_icon("tick", "HSlider", load("res://scripts/ui/icons.gd").from_svg(
		"<svg xmlns='http://www.w3.org/2000/svg' width='4' height='10'><rect x='1' y='0' width='2' height='10' rx='1' fill='#%s' fill-opacity='0.35'/></svg>" % color("text").to_html(false)))
	th.set_constant("center_grabber", "HSlider", 0)

	var bar := box(soft(0.20), 999, 0, 0)
	for sb in ["VScrollBar", "HScrollBar"]:
		th.set_stylebox("grabber", sb, bar)
		th.set_stylebox("grabber_highlight", sb, box(soft(0.32), 999, 0, 0))
		th.set_stylebox("grabber_pressed", sb, box(soft(0.32), 999, 0, 0))
	th.set_stylebox("scroll", "VScrollBar", box(Color(0, 0, 0, 0), 999, 2, 0))
	th.set_stylebox("scroll", "HScrollBar", box(Color(0, 0, 0, 0), 999, 0, 2))

	var le := pill(color("glass_2"), color("line_2"), 22, 10)
	th.set_stylebox("normal", "LineEdit", le)
	th.set_stylebox("read_only", "LineEdit", le)
	th.set_stylebox("focus", "LineEdit", focus_ring(999, ring, 2, true))
	th.set_color("font_color", "LineEdit", color("text"))
	th.set_color("font_uneditable_color", "LineEdit", color("text"))
	th.set_color("font_placeholder_color", "LineEdit", color("text_3"))
	th.set_color("caret_color", "LineEdit", acc)
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
	var key := "%s|%s|%s" % [focused, color("ring").to_html(), color("text").to_html()]
	if _knobs.has(key):
		return _knobs[key]
	var fill := "#FFFFFF"
	var ring := "#" + color("ring").to_html(false)
	var svg := ""
	if focused:
		svg = "<svg xmlns='http://www.w3.org/2000/svg' width='36' height='36'><circle cx='18' cy='18' r='17' fill='%s' fill-opacity='0.22'/><circle cx='18' cy='18' r='11' fill='%s'/><circle cx='18' cy='18' r='12' fill='none' stroke='%s' stroke-width='2.5'/></svg>" % [ring, fill, ring]
	else:
		svg = "<svg xmlns='http://www.w3.org/2000/svg' width='36' height='36'><circle cx='18' cy='19' r='10' fill='#000' fill-opacity='0.30'/><circle cx='18' cy='18' r='9' fill='%s'/></svg>" % fill
	var img := Image.new()
	img.load_svg_from_string(svg, 1.0)
	var tex := ImageTexture.create_from_image(img)
	_knobs[key] = tex
	return tex
