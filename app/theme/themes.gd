extends RefCounted
## Built-in themes as plain data. Every theme provides every key in TOKENS
## (tests check it); components read tokens, never hard-coded colours.
## Documented in docs/DESIGN.md.

## Token names and what they're for.
const TOKENS := {
	"bg": "Screen background behind the art backdrop",
	"surface": "Panels and cards",
	"surface_2": "Raised controls (setting rows, buttons)",
	"surface_3": "Hover / pressed controls, slider tracks",
	"glass": "Frosted panels (quick menu, dialogs, toasts); has alpha",
	"line": "Hairline borders; has alpha",
	"text": "Primary text",
	"text_2": "Secondary text (meta lines, explanations)",
	"text_3": "Faint text: disabled, placeholders",
	"accent": "Brand accent: focus, Play, selected tab",
	"accent_2": "Second accent for gradients and charts",
	"on_accent": "Text and icons on an accent fill",
	"focus_fill": "Fill of a focused plain button",
	"on_focus": "Text on focus_fill",
	"good": "Works, platinum, success",
	"warn": "Caution, partial",
	"bad": "Broken, denied, low battery",
	"info": "Neutral information",
	"scrim": "Colour the backdrop art is darkened toward",
	"chip": "Badge chip background (sits on art); has alpha",
}
## Numbers every theme provides.
const NUMBERS := {
	"scrim_strength": "How far the backdrop art is pulled toward `scrim` (0..1)",
	"radius_s": "Chips, small buttons",
	"radius_m": "Buttons, setting rows, tiles",
	"radius_l": "Panels, cards",
	"radius_xl": "Glass sheets",
	"dark": "1 for dark themes, 0 for light",
}

const ORDER := ["cove", "midnight", "sunset", "light"]
const NAMES := {"cove": "Cove", "midnight": "Midnight", "sunset": "Sunset", "light": "Light"}
const DESCRIBE := {
	"cove": "Teal on deep navy. The GameCove look.",
	"midnight": "True black with ice-blue accents. Saves power on OLED screens.",
	"sunset": "Warm plum and apricot.",
	"light": "Dark text on light panels, highest contrast in bright rooms.",
}

const DATA := {
	"cove": {
		"bg": Color("#0A1120"), "surface": Color("#111A2B"), "surface_2": Color("#18243A"),
		"surface_3": Color("#22314B"), "glass": Color(0.055, 0.086, 0.14, 0.90), "line": Color(1, 1, 1, 0.10),
		"text": Color("#EEF3F8"), "text_2": Color("#A9B6C8"), "text_3": Color("#6F7E93"),
		"accent": Color("#4FD1C5"), "accent_2": Color("#7C9CFF"), "on_accent": Color("#032521"),
		"focus_fill": Color("#F2F6FA"), "on_focus": Color("#0A1120"),
		"good": Color("#5BE3A3"), "warn": Color("#F7BE5F"), "bad": Color("#FF8080"), "info": Color("#86BEFF"),
		"scrim": Color("#060B16"), "chip": Color(0.03, 0.05, 0.09, 0.80),
		"scrim_strength": 0.62, "radius_s": 8, "radius_m": 12, "radius_l": 18, "radius_xl": 26, "dark": 1,
	},
	"midnight": {
		"bg": Color("#000000"), "surface": Color("#0B0B0E"), "surface_2": Color("#15151A"),
		"surface_3": Color("#202028"), "glass": Color(0.02, 0.02, 0.03, 0.92), "line": Color(1, 1, 1, 0.09),
		"text": Color("#F4F4F7"), "text_2": Color("#A3A3AF"), "text_3": Color("#686874"),
		"accent": Color("#8AB0FF"), "accent_2": Color("#C59BFF"), "on_accent": Color("#05112A"),
		"focus_fill": Color("#F4F4F7"), "on_focus": Color("#000000"),
		"good": Color("#62E2A6"), "warn": Color("#F5C062"), "bad": Color("#FF7B86"), "info": Color("#8AB0FF"),
		"scrim": Color("#000000"), "chip": Color(0, 0, 0, 0.82),
		"scrim_strength": 0.74, "radius_s": 8, "radius_m": 12, "radius_l": 18, "radius_xl": 26, "dark": 1,
	},
	"sunset": {
		"bg": Color("#170C12"), "surface": Color("#22121B"), "surface_2": Color("#2E1924"),
		"surface_3": Color("#3D2230"), "glass": Color(0.13, 0.07, 0.10, 0.90), "line": Color(1, 0.9, 0.85, 0.11),
		"text": Color("#FFF2EB"), "text_2": Color("#D6B7AB"), "text_3": Color("#9A7A73"),
		"accent": Color("#FF9E66"), "accent_2": Color("#FF6B95"), "on_accent": Color("#2B0E02"),
		"focus_fill": Color("#FFF2EB"), "on_focus": Color("#22121B"),
		"good": Color("#7FE3B0"), "warn": Color("#FFD073"), "bad": Color("#FF8A8A"), "info": Color("#FFB8D2"),
		"scrim": Color("#12070D"), "chip": Color(0.08, 0.03, 0.05, 0.80),
		"scrim_strength": 0.62, "radius_s": 8, "radius_m": 14, "radius_l": 20, "radius_xl": 28, "dark": 1,
	},
	"light": {
		"bg": Color("#E9EEF4"), "surface": Color("#FFFFFF"), "surface_2": Color("#F1F4F8"),
		"surface_3": Color("#DFE6EE"), "glass": Color(0.98, 0.99, 1.0, 0.94), "line": Color(0.05, 0.1, 0.2, 0.14),
		"text": Color("#0D1624"), "text_2": Color("#465365"), "text_3": Color("#7F8B9C"),
		"accent": Color("#0A776F"), "accent_2": Color("#4B5FD6"), "on_accent": Color("#FFFFFF"),
		"focus_fill": Color("#0D1624"), "on_focus": Color("#FFFFFF"),
		"good": Color("#0E7A55"), "warn": Color("#935400"), "bad": Color("#B4232C"), "info": Color("#2F5BC4"),
		"scrim": Color("#EEF2F7"), "chip": Color(1.0, 1.0, 1.0, 0.92),
		"scrim_strength": 0.80, "radius_s": 8, "radius_m": 12, "radius_l": 18, "radius_xl": 26, "dark": 0,
	},
}

## Badge colours on a dark `chip` (dark themes). Light themes use
## TONES_LIGHT on a light chip. Contrast is tested against each theme's chip
## over black and over white, since badges sit on art.
const TONES := {
	"": Color("#E6ECF3"),
	"good": Color("#5BE3A3"),
	"warn": Color("#F7BE5F"),
	"bad": Color("#FF9494"),
	"info": Color("#8CC2FF"),
	"accent": Color("#5FDCD0"),
	"platinum": Color("#D5E2EE"),
	"gold": Color("#F4C752"),
	"silver": Color("#BCC5CF"),
	"bronze": Color("#E09A5E"),
	"borked": Color("#FF9A8A"),
	"sale": Color("#B6F06A"),
	"wish": Color("#FFB3D1"),
	"new": Color("#7FD8FF"),
}


const TONES_LIGHT := {
	"": Color("#1F2937"),
	"good": Color("#0B6B4A"),
	"warn": Color("#8A4B00"),
	"bad": Color("#B42318"),
	"info": Color("#1D4FB8"),
	"accent": Color("#0A6B64"),
	"platinum": Color("#3B4A5C"),
	"gold": Color("#7A5A00"),
	"silver": Color("#4B5563"),
	"bronze": Color("#8A4A12"),
	"borked": Color("#B42318"),
	"sale": Color("#3F6B00"),
	"wish": Color("#A3195B"),
	"new": Color("#0B5F8A"),
}


## The badge tone set for a theme.
static func tones(id: String) -> Dictionary:
	return TONES if int(get_theme(id).get("dark", 1)) == 1 else TONES_LIGHT


static func get_theme(id: String) -> Dictionary:
	return DATA.get(id, DATA["cove"])


static func has_theme(id: String) -> bool:
	return DATA.has(id)


## WCAG relative luminance.
static func luminance(c: Color) -> float:
	var ch := func(v: float) -> float:
		return v / 12.92 if v <= 0.03928 else pow((v + 0.055) / 1.055, 2.4)
	return 0.2126 * ch.call(c.r) + 0.7152 * ch.call(c.g) + 0.0722 * ch.call(c.b)


## WCAG contrast ratio between two opaque colours (1..21).
static func contrast(a: Color, b: Color) -> float:
	var la := luminance(a)
	var lb := luminance(b)
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)


## A translucent colour as it looks over an opaque one.
static func over(top: Color, below: Color) -> Color:
	var c := below.lerp(Color(top.r, top.g, top.b), top.a)
	c.a = 1.0
	return c
