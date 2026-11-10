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
	"cove": "Electric cyan and violet on deep slate. The GameCove look.",
	"midnight": "Pure black with ice-cyan and violet. Saves power on OLED screens.",
	"sunset": "Warm orange into magenta on deep plum.",
	"light": "Dark text on light glass, highest contrast in bright rooms.",
}

const DATA := {
	"cove": {
		# A lifted deep slate ground; cards and panels a clear step above it.
		"bg": Color("#141B2A"), "surface": Color("#1B2336"), "surface_2": Color("#222B40"),
		"surface_3": Color("#2C364D"), "glass": Color(0.106, 0.137, 0.208, 0.84), "glass_2": Color(0.137, 0.169, 0.247, 0.86),
		"line": Color(1, 1, 1, 0.10), "line_2": Color(1, 1, 1, 0.15),
		"text": Color("#F8FAFC"), "text_2": Color("#A3B1C6"), "text_3": Color("#6F7D93"),
		"accent": Color("#00F0FF"), "accent_2": Color("#7000FF"), "accent_end": Color("#8F86FF"), "on_accent": Color("#00151A"),
		"ring": Color("#00F0FF"), "glow": Color(0.0, 0.94, 1.0, 0.42),
		"focus_fill": Color("#E6FDFF"), "on_focus": Color("#040508"),
		"good": Color("#4ADE80"), "warn": Color("#FBBF24"), "bad": Color("#F87171"), "info": Color("#5CC8FF"),
		"face_a": Color("#22C55E"), "face_b": Color("#EF4444"), "face_x": Color("#3B82F6"), "face_y": Color("#EAB308"),
		"on_face": Color("#040508"),
		"scrim": Color("#121826"), "chip": Color(0.02, 0.025, 0.04, 0.82),
		"scrim_strength": 0.62, "radius_s": 8, "radius_m": 12, "radius_l": 16, "radius_xl": 24, "glow_size": 18, "dark": 1,
	},
	"midnight": {
		# Pure black for OLED: unlit pixels everywhere but cards and text,
		# ice-cyan and violet neon on top.
		"bg": Color("#000000"), "surface": Color("#060609"), "surface_2": Color("#0D0E13"),
		"surface_3": Color("#17181F"), "glass": Color(0.02, 0.02, 0.035, 0.90), "glass_2": Color(0.07, 0.075, 0.10, 0.78),
		"line": Color(1, 1, 1, 0.09), "line_2": Color(0.85, 0.92, 1.0, 0.16),
		"text": Color("#F5F7FA"), "text_2": Color("#9CA3B4"), "text_3": Color("#5C6272"),
		"accent": Color("#4CC9FF"), "accent_2": Color("#8B5CFF"), "accent_end": Color("#9B7BFF"), "on_accent": Color("#00121F"),
		"ring": Color("#4CC9FF"), "glow": Color(0.30, 0.79, 1.0, 0.40),
		"focus_fill": Color("#EAF8FF"), "on_focus": Color("#000000"),
		"good": Color("#4ADE80"), "warn": Color("#FBBF24"), "bad": Color("#FF7A85"), "info": Color("#7CB8FF"),
		"face_a": Color("#22C55E"), "face_b": Color("#EF4444"), "face_x": Color("#3B82F6"), "face_y": Color("#EAB308"),
		"on_face": Color("#000000"),
		"scrim": Color("#000000"), "chip": Color(0, 0, 0, 0.84),
		"scrim_strength": 0.80, "radius_s": 8, "radius_m": 12, "radius_l": 16, "radius_xl": 24, "glow_size": 18, "dark": 1,
	},
	"sunset": {
		# Warm neon: orange into magenta over a lifted deep plum.
		"bg": Color("#24151F"), "surface": Color("#2B1926"), "surface_2": Color("#341E2D"),
		"surface_3": Color("#412639"), "glass": Color(0.16, 0.095, 0.14, 0.86), "glass_2": Color(0.20, 0.11, 0.16, 0.80),
		"line": Color(1, 0.88, 0.85, 0.10), "line_2": Color(1, 0.80, 0.78, 0.18),
		"text": Color("#FFF4EE"), "text_2": Color("#D4B3AA"), "text_3": Color("#93716B"),
		"accent": Color("#FF8A3D"), "accent_2": Color("#FF2E88"), "accent_end": Color("#FF4F9A"), "on_accent": Color("#220800"),
		"ring": Color("#FF8A3D"), "glow": Color(1.0, 0.54, 0.24, 0.42),
		"focus_fill": Color("#FFF1E8"), "on_focus": Color("#160A10"),
		"good": Color("#6EE7A8"), "warn": Color("#FFD166"), "bad": Color("#FF7B7B"), "info": Color("#FFA8CB"),
		"face_a": Color("#4FD992"), "face_b": Color("#FF6B6B"), "face_x": Color("#55A6FF"), "face_y": Color("#FFCC4D"),
		"on_face": Color("#12070D"),
		"scrim": Color("#201219"), "chip": Color(0.07, 0.025, 0.045, 0.86),
		"scrim_strength": 0.62, "radius_s": 8, "radius_m": 12, "radius_l": 16, "radius_xl": 24, "glow_size": 18, "dark": 1,
	},
	"light": {
		# The Neon language on light glass: deep cyan into violet, dark ink.
		"bg": Color("#EEF1F6"), "surface": Color("#FFFFFF"), "surface_2": Color("#F4F6FA"),
		"surface_3": Color("#E1E6EE"), "glass": Color(0.99, 0.995, 1.0, 0.92), "glass_2": Color(1.0, 1.0, 1.0, 0.82),
		"line": Color(0.04, 0.08, 0.16, 0.12), "line_2": Color(0.04, 0.08, 0.16, 0.22),
		"text": Color("#0A0F1A"), "text_2": Color("#475266"), "text_3": Color("#808B9C"),
		"accent": Color("#007A8C"), "accent_2": Color("#6D28D9"), "accent_end": Color("#5B21B6"), "on_accent": Color("#FFFFFF"),
		"ring": Color("#008396"), "glow": Color(0.0, 0.62, 0.72, 0.30),
		"focus_fill": Color("#0A0F1A"), "on_focus": Color("#FFFFFF"),
		"good": Color("#0E7A55"), "warn": Color("#8F5200"), "bad": Color("#B4232C"), "info": Color("#2F5BC4"),
		"face_a": Color("#2DBE6C"), "face_b": Color("#F0505E"), "face_x": Color("#3B8EF0"), "face_y": Color("#F2B526"),
		"on_face": Color("#05070B"),
		"scrim": Color("#F0F3F8"), "chip": Color(1.0, 1.0, 1.0, 0.92),
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
