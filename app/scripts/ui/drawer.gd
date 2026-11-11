extends RefCounted
## The one drawer GameCove has: a glass panel floating against a screen edge,
## the full height of the screen (MARGIN from the top, the bottom and that
## edge), every corner rounded the same, near-opaque so nothing behind ghosts
## through its rows, over a scrim that dims the whole screen, top bar and hint
## bar included. The quick menu and the choice sheets (Filter, Manage, ...)
## are both this drawer, so they open in the same place with the same shape;
## what a button does is said by a prompt row at the drawer's own foot.

const ThemeLib := preload("res://theme/gamecove_theme.gd")

## Gap between the drawer and the screen's edges.
const MARGIN := 14.0
## How dark the full-screen scrim is (dark themes).
const SCRIM_ALPHA := 0.55
## The least opaque the drawer's glass gets.
const GLASS_ALPHA := 0.97


## Anchors `panel` (a child of a full-screen Control) as a drawer `width` px
## wide against `side` ("right" or "left").
static func place(panel: Control, width: float, side := "right") -> void:
	panel.anchor_top = 0.0
	panel.anchor_bottom = 1.0
	panel.offset_top = MARGIN
	panel.offset_bottom = -MARGIN
	if side == "left":
		panel.anchor_left = 0.0
		panel.anchor_right = 0.0
		panel.offset_left = MARGIN
		panel.offset_right = MARGIN + width
	else:
		panel.anchor_left = 1.0
		panel.anchor_right = 1.0
		panel.offset_left = -width - MARGIN
		panel.offset_right = -MARGIN


## The drawer's glass for the current theme (padding `pad_x`, `pad_y`).
static func glass(pad_x := 24, pad_y := 20) -> StyleBoxFlat:
	var sb := ThemeLib.glass(-1, pad_x, pad_y)
	sb.bg_color.a = maxf(sb.bg_color.a, GLASS_ALPHA)
	return sb


## The scrim behind an open drawer.
static func scrim() -> Color:
	return Color(0, 0, 0, SCRIM_ALPHA) if ThemeLib.is_dark() else Color(0.08, 0.1, 0.14, 0.6)
