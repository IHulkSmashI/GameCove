extends RefCounted
## Text over hero art, the way consoles do it: the art keeps its full colour
## from edge to edge, a soft dark scrim sits only where the words are, and the
## words are light, whatever the theme. This is the Light theme's hero (Home,
## Discover, game / store / emulation pages); the dark themes keep their own
## scrim toward the backdrop colour, which already reads this way.
##
## The scrim is black at `strength` from the left edge to `hold` (the end of
## the title), then fades to nothing by END of the width. `strength` follows
## the art: just enough for white text to read on it, never more than MAX.
## hero_fade.gdshader draws it (shade_color / shade_from / shade_to);
## alpha_at() and shade() are the same sums, for tests and for picking colours.

const Themes := preload("res://theme/themes.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const ArtColor := preload("res://theme/art_color.gd")

## Strongest scrim, at the far left edge (bright art).
const MAX := 0.55
## Weakest scrim (dark art still gets a hint of it, so the text side is calm).
const MIN := 0.25
## Gone by this fraction of the width.
const END := 0.45
## The full-strength part ends with the title: between these fractions.
const HOLD_MIN := 0.06
const HOLD_MAX := 0.36
## Space after the title before the fade starts, px.
const HOLD_PAD := 20.0
## White text on the scrimmed art aims for this contrast (AA is 4.5).
const AIM := 5.5


## True where this look applies: the light themes.
static func active() -> bool:
	return not ThemeLib.is_dark()


## The title.
static func title() -> Color:
	return Color.WHITE


## The info line under the title: the dark theme's own.
static func meta() -> Color:
	var t: Dictionary = Themes.get_theme("cove")
	return (t["text"] as Color).lerp(t["text_2"], 0.35)


## The short line above the title, and prices: `c` (the art's accent, or the
## theme's) as the dark theme would show it, lifted a little toward white.
static func accent(c: Color) -> Color:
	var t: Dictionary = Themes.get_theme("cove")
	var a: Color = ArtColor.accent_for(c, t) if c.a > 0.0 else t["accent"]
	a = a.lerp(Color.WHITE, 0.25)
	a.a = 1.0
	return a


## The soft shadow under light text on art (never a light halo).
static func shadow(strength := 0.40) -> Color:
	return Color(0, 0, 0, strength)


## Scrim alpha at `x` (0..1 across the hero).
static func alpha_at(x: float, strength: float, hold: float) -> float:
	return strength * (1.0 - smoothstep(hold, END, x))


## `art` as it shows at `x`, under the scrim.
static func shade(art: Color, x: float, strength: float, hold: float) -> Color:
	var a := alpha_at(x, strength, hold)
	return Color(art.r * (1.0 - a), art.g * (1.0 - a), art.b * (1.0 - a), 1.0)


## Where the full-strength part ends for a title whose right edge is
## `title_right` px into a hero `width` px wide.
static func hold_for(title_right: float, width: float) -> float:
	if width <= 0.0:
		return HOLD_MAX
	return clampf((title_right + HOLD_PAD) / width, HOLD_MIN, HOLD_MAX)


## `node`'s left edge in `root`'s coordinates, from the layout alone (works
## outside the scene tree, where global positions don't).
static func x_within(node: Control, root: Node) -> float:
	var x := 0.0
	var n: Node = node
	while n != null and n != root:
		if n is Control:
			x += (n as Control).position.x
		n = n.get_parent()
	return x


## The scrim strength for art whose text side is as bright as `tone` (see
## text_side()): the least that gives white text AIM:1, within MIN..MAX.
## Unknown art (alpha 0) gets MAX.
static func strength_for(tone: Color) -> float:
	if tone.a <= 0.0:
		return MAX
	var c := Color(tone.r, tone.g, tone.b, 1.0)
	var lo := MIN
	var hi := MAX
	if _reads(c, lo):
		return lo
	for i in 8:
		var mid := (lo + hi) * 0.5
		if _reads(c, mid):
			hi = mid
		else:
			lo = mid
	return hi


static func _reads(c: Color, a: float) -> bool:
	return Themes.contrast(Color.WHITE, Color(c.r * (1.0 - a), c.g * (1.0 - a), c.b * (1.0 - a), 1.0)) >= AIM


## How bright the text side of a picture is: the colour at the 97th percentile
## of luminance over a grid on its left END of the width (a stray highlight
## doesn't count, snow or a bright sky does). Cheap: 192 pixels, run where the art is
## decoded (art_cache.gd, off the main thread).
static func text_side(img: Image) -> Color:
	if img == null or img.is_empty() or img.is_compressed():
		return Color(0, 0, 0, 0)
	var w := img.get_width()
	var h := img.get_height()
	var found: Array = []
	for j in 12:
		var y := clampi(int((0.12 + 0.76 * (j + 0.5) / 12.0) * h), 0, h - 1)
		for i in 16:
			var x := clampi(int(END * (i + 0.5) / 16.0 * w), 0, w - 1)
			var c := img.get_pixel(x, y)
			found.append([Themes.luminance(Color(c.r, c.g, c.b, 1.0)), c])
	found.sort_custom(func(a, b): return a[0] < b[0])
	var pick: Color = found[int(found.size() * 0.97)][1]
	return Color(pick.r, pick.g, pick.b, 1.0)
