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
	"glass": "Frosted sheets (quick menu, dialogs, toasts); has alpha",
	"glass_2": "Glass pills: secondary buttons, chips, top-bar pills; has alpha",
	"line": "Hairline borders; has alpha",
	"line_2": "Brighter hairline: card edges on art, pill borders; has alpha",
	"text": "Primary text",
	"text_2": "Secondary text (meta lines, explanations)",
	"text_3": "Faint text: disabled, placeholders",
	"accent": "Brand accent: focus, Play, selected tab; start of the primary gradient",
	"accent_2": "Second accent (violet) for gradients and charts",
	"accent_end": "End of the primary gradient; on_accent stays readable on it",
	"on_accent": "Text and icons on an accent fill",
	"ring": "Focus ring",
	"glow": "Soft outer glow of focused and primary controls; has alpha",
	"focus_fill": "Fill of a focused key (on-screen keyboard)",
	"on_focus": "Text on focus_fill",
	"good": "Works, platinum, success",
	"warn": "Caution, partial, DLC and sales",
	"bad": "Broken, denied, low battery",
	"info": "Neutral information",
	"face_a": "A / South glyph",
	"face_b": "B / East glyph",
	"face_x": "X / West glyph",
	"face_y": "Y / North glyph",
	"on_face": "Letter on a face-button glyph",
	"scrim": "Colour the backdrop art is darkened toward",
	"chip": "Badge chip background (sits on art); has alpha",
}
## Text tokens and the token they must reach 4.5:1 against (tests check).
const TEXT_PAIRS := [
	["text", "surface"], ["text", "surface_2"], ["text", "glass"], ["text", "glass_2"],
	["text_2", "surface"], ["text_2", "surface_2"], ["text_2", "glass"], ["text_2", "glass_2"],
	["accent", "surface"], ["on_accent", "accent"], ["on_accent", "accent_end"], ["on_focus", "focus_fill"],
	["good", "surface"], ["warn", "surface"], ["bad", "surface"], ["info", "surface"],
	["on_face", "face_a"], ["on_face", "face_b"], ["on_face", "face_x"], ["on_face", "face_y"],
]
## Numbers every theme provides.
const NUMBERS := {
	"scrim_strength": "How far the backdrop art is pulled toward `scrim` (0..1)",
	"radius_s": "Chips, small buttons",
	"radius_m": "Buttons, setting rows, tiles",
	"radius_l": "Panels, cards",
	"radius_xl": "Glass sheets",
	"glow_size": "Outer glow of focused controls, px",
	"dark": "1 for dark themes, 0 for light",
}

const ORDER := ["cove", "midnight", "sunset", "light"]
const NAMES := {"cove": "Cove", "midnight": "Midnight", "sunset": "Sunset", "light": "Light"}
const DESCRIBE := {
	"cove": "Electric cyan and violet on near-black. The GameCove look.",
	"midnight": "True black with ice-blue and lilac. Saves power on OLED screens.",
	"sunset": "Apricot and rose on deep plum.",
	"light": "Dark text on light glass, highest contrast in bright rooms.",
}

const DATA := {
	"cove": {
		"bg": Color("#040508"), "surface": Color("#0B0F18"), "surface_2": Color("#111724"),
		"surface_3": Color("#1A2132"), "glass": Color(0.055, 0.075, 0.118, 0.80), "glass_2": Color(0.078, 0.106, 0.165, 0.85),
		"line": Color(1, 1, 1, 0.10), "line_2": Color(1, 1, 1, 0.15),
		"text": Color("#F8FAFC"), "text_2": Color("#94A3B8"), "text_3": Color("#5E6B7F"),
		"accent": Color("#00F0FF"), "accent_2": Color("#7000FF"), "accent_end": Color("#8F86FF"), "on_accent": Color("#00151A"),
		"ring": Color("#00F0FF"), "glow": Color(0.0, 0.94, 1.0, 0.42),
		"focus_fill": Color("#E6FDFF"), "on_focus": Color("#040508"),
		"good": Color("#4ADE80"), "warn": Color("#FBBF24"), "bad": Color("#F87171"), "info": Color("#5CC8FF"),
		"face_a": Color("#22C55E"), "face_b": Color("#EF4444"), "face_x": Color("#3B82F6"), "face_y": Color("#EAB308"),
		"on_face": Color("#040508"),
		"scrim": Color("#040508"), "chip": Color(0.02, 0.025, 0.04, 0.82),
		"scrim_strength": 0.86, "radius_s": 8, "radius_m": 12, "radius_l": 16, "radius_xl": 24, "glow_size": 18, "dark": 1,
	},
	"midnight": {
		"bg": Color("#000000"), "surface": Color("#08080B"), "surface_2": Color("#111116"),
		"surface_3": Color("#1B1B22"), "glass": Color(0.015, 0.015, 0.025, 0.88), "glass_2": Color(0.08, 0.08, 0.11, 0.70),
		"line": Color(1, 1, 1, 0.08), "line_2": Color(0.9, 0.92, 1.0, 0.15),
		"text": Color("#F4F4F8"), "text_2": Color("#A6A6B3"), "text_3": Color("#6A6A78"),
		"accent": Color("#8AB6FF"), "accent_2": Color("#B98CFF"), "accent_end": Color("#C3A2FF"), "on_accent": Color("#050D1F"),
		"ring": Color("#9CC2FF"), "glow": Color(0.54, 0.71, 1.0, 0.38),
		"focus_fill": Color("#F4F4F8"), "on_focus": Color("#000000"),
		"good": Color("#5FE3A6"), "warn": Color("#F6C266"), "bad": Color("#FF7D8C"), "info": Color("#8AB6FF"),
		"face_a": Color("#45D98C"), "face_b": Color("#FF6875"), "face_x": Color("#4C9EFF"), "face_y": Color("#FFCB4A"),
		"on_face": Color("#000000"),
		"scrim": Color("#000000"), "chip": Color(0, 0, 0, 0.82),
		"scrim_strength": 0.90, "radius_s": 8, "radius_m": 12, "radius_l": 16, "radius_xl": 24, "glow_size": 16, "dark": 1,
	},
	"sunset": {
		"bg": Color("#0E0609"), "surface": Color("#1A0D13"), "surface_2": Color("#24131B"),
		"surface_3": Color("#331C27"), "glass": Color(0.10, 0.05, 0.075, 0.84), "glass_2": Color(0.20, 0.11, 0.15, 0.62),
		"line": Color(1, 0.9, 0.85, 0.09), "line_2": Color(1, 0.88, 0.82, 0.17),
		"text": Color("#FFF3EC"), "text_2": Color("#D9BBAE"), "text_3": Color("#9A7A73"),
		"accent": Color("#FFA066"), "accent_2": Color("#FF3D7F"), "accent_end": Color("#FF7FA6"), "on_accent": Color("#2A0C02"),
		"ring": Color("#FFB07A"), "glow": Color(1.0, 0.63, 0.40, 0.40),
		"focus_fill": Color("#FFF3EC"), "on_focus": Color("#1A0D13"),
		"good": Color("#7FE3B0"), "warn": Color("#FFD073"), "bad": Color("#FF8A8A"), "info": Color("#FFB8D2"),
		"face_a": Color("#4FD992"), "face_b": Color("#FF6B6B"), "face_x": Color("#55A6FF"), "face_y": Color("#FFCC4D"),
		"on_face": Color("#12070D"),
		"scrim": Color("#0C0408"), "chip": Color(0.07, 0.025, 0.045, 0.86),
		"scrim_strength": 0.84, "radius_s": 8, "radius_m": 12, "radius_l": 16, "radius_xl": 24, "glow_size": 18, "dark": 1,
	},
	"light": {
		"bg": Color("#E8ECF3"), "surface": Color("#FFFFFF"), "surface_2": Color("#F2F5F9"),
		"surface_3": Color("#DEE4EC"), "glass": Color(0.985, 0.99, 1.0, 0.92), "glass_2": Color(1.0, 1.0, 1.0, 0.78),
		"line": Color(0.05, 0.1, 0.2, 0.12), "line_2": Color(0.05, 0.1, 0.2, 0.22),
		"text": Color("#0B1220"), "text_2": Color("#435064"), "text_3": Color("#7F8B9C"),
		"accent": Color("#006E7A"), "accent_2": Color("#5B2BD9"), "accent_end": Color("#4A33C9"), "on_accent": Color("#FFFFFF"),
		"ring": Color("#008A99"), "glow": Color(0.0, 0.55, 0.62, 0.28),
		"focus_fill": Color("#0B1220"), "on_focus": Color("#FFFFFF"),
		"good": Color("#0E7A55"), "warn": Color("#8F5200"), "bad": Color("#B4232C"), "info": Color("#2F5BC4"),
		"face_a": Color("#2DBE6C"), "face_b": Color("#F0505E"), "face_x": Color("#3B8EF0"), "face_y": Color("#F2B526"),
		"on_face": Color("#05070B"),
		"scrim": Color("#EDF1F7"), "chip": Color(1.0, 1.0, 1.0, 0.92),
		"scrim_strength": 0.88, "radius_s": 8, "radius_m": 12, "radius_l": 16, "radius_xl": 24, "glow_size": 14, "dark": 0,
	},
}

## Badge colours on a dark `chip` (dark themes). Light themes use
## TONES_LIGHT on a light chip. Contrast is tested against each theme's chip
## over black and over white, since badges sit on art.
const TONES := {
	"": Color("#E6ECF3"),
	"good": Color("#4ADE80"),
	"warn": Color("#FBBF24"),
	"bad": Color("#F87171"),
	"info": Color("#8CC2FF"),
	"accent": Color("#00F0FF"),
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
