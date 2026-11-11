extends "res://tests/test_case.gd"
## The final design pass: one thing glows per screen, one drawer shape, no
## sliced rows, a balanced game page, featured giveaways, Light's inks.

const Themes := preload("res://theme/themes.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Kit := preload("res://scripts/ui/ui_kit.gd")
const Drawer := preload("res://scripts/ui/drawer.gd")
const Sheet := preload("res://scripts/ui/games/sheet.gd")
const QuickMenu := preload("res://scripts/ui/quick_menu.gd")
const ButtonFx := preload("res://scripts/ui/button_fx.gd")
const Page := preload("res://scripts/ui/page_template.gd")
const GamePage := preload("res://scripts/ui/game_page.gd")
const Shelf := preload("res://scripts/ui/shelf.gd")
const Tile := preload("res://scripts/ui/game_tile.gd")
const Badge := preload("res://scripts/ui/badge.gd")
const SettingsScreen := preload("res://scripts/ui/settings_screen.gd")
const FadeMask := preload("res://scripts/ui/fade_mask.gd")
const Logic := preload("res://tests/test_ui_logic.gd")
const Games := preload("res://tests/test_ui_games.gd")
const Screens := preload("res://tests/test_ui_screens.gd")


# ---- one thing glows ---------------------------------------------------------

## A primary button that waits (Continue while a card has focus) is a calm
## filled pill with no glow; only focus brings the gradient, ring and glow.
func test_waiting_primary_is_calm() -> void:
	for id in Themes.ORDER:
		ThemeLib.use(id)
		var b := Kit.primary("Continue")
		var other := Kit.button("Easy")
		var fx: Control = b.get_node("Fx")
		ok(fx.is_calm(), "%s: without focus it waits" % id)
		var calm := b.get_theme_stylebox("normal")
		ok(calm is StyleBoxFlat, "%s: a plain filled pill, not the gradient" % id)
		eq(b.get_node("Glow").modulate.a, 0.0, "%s: no glow without focus" % id)
		if calm is StyleBoxFlat:
			var fill: Color = (calm as StyleBoxFlat).bg_color
			eq(fill.a, 1.0, "%s: the fill is opaque" % id)
			ok(Themes.contrast(fx._color(), fill) >= 4.5, "%s: its label reads (%.2f)" % [id, Themes.contrast(fx._color(), fill)])
			ok(Themes.contrast(fill, ThemeLib.color("accent")) >= 1.5, "%s: clearly not the bright accent fill" % id)
		b.focus_entered.emit()
		ok(not fx.is_calm(), "%s: focus wakes it" % id)
		ok(b.get_theme_stylebox("normal") is StyleBoxTexture, "%s: the gradient with focus" % id)
		eq(fx._color(), ThemeLib.color("on_accent"), "%s: and its own ink" % id)
		b.focus_exited.emit()
		ok(fx.is_calm() and b.get_theme_stylebox("normal") is StyleBoxFlat, "%s: calm again when focus moves on" % id)
		# An art-coloured primary (Play) follows the same rule.
		Kit.accent_button(b, Color("#D9A441"))
		ok(b.get_theme_stylebox("normal") is StyleBoxFlat, "%s: an art-coloured one waits calmly too" % id)
		b.free()
		other.free()
	ThemeLib.use("cove")


# ---- one drawer ---------------------------------------------------------------

func _radii(sb: StyleBoxFlat) -> Array:
	return [sb.corner_radius_top_left, sb.corner_radius_top_right, sb.corner_radius_bottom_left, sb.corner_radius_bottom_right]


## The choice sheet (Filter, Manage) and the quick menu are the same drawer:
## full height, the same margins, every corner the same radius.
func test_sheet_and_quick_menu_share_the_drawer() -> void:
	var s: Control = Sheet.new()
	var q: Control = QuickMenu.new()
	q.setup({})
	for p in [s.panel, q.panel]:
		eq(p.anchor_top, 0.0, "from the top")
		eq(p.anchor_bottom, 1.0, "to the bottom")
		eq(p.offset_top, Drawer.MARGIN, "the same gap at the top (no stop under the top bar)")
		eq(p.offset_bottom, -Drawer.MARGIN, "and at the foot (over the hint bar)")
		eq(p.offset_right, -Drawer.MARGIN, "floating against the right edge")
	var a := s.panel.get_theme_stylebox("panel") as StyleBoxFlat
	var b := q.panel.get_theme_stylebox("panel") as StyleBoxFlat
	eq(_radii(a), _radii(b), "the same corners")
	ok(_radii(a).min() == _radii(a).max() and _radii(a)[0] == ThemeLib.radius("xl"), "every corner rounded alike")
	ok(a.bg_color.a >= Drawer.GLASS_ALPHA and b.bg_color.a >= Drawer.GLASS_ALPHA, "near-opaque glass")
	ok(s.prompts != null and Kit.prompts_text(s.prompts).contains("Select"), "the sheet says what A does at its own foot")
	ok(s.z_index > 0, "and sits over the screen's hint bar")
	s.free()
	q.free()


## A row's line under its name wraps onto a second line; it never ends in an
## ellipsis mid-word ("...Steam ROM Manag...").
func test_sheet_detail_wraps() -> void:
	var s: Control = Sheet.new()
	var long := "ES-DE or RetroDECK and the games Steam ROM Manager added"
	s.open("Filter", "Pick what the Library shows.", [
		{"id": "all", "text": "All games", "detail": "Everything you haven't hidden", "icon": "grid", "value": "30", "current": true},
		{"id": "emu", "text": "Emulation", "detail": long, "icon": "gamepad", "value": "5"},
	])
	var short_row: Button = s.rows[0]
	var long_row: Button = s.rows[1]
	var d: Label = long_row.find_child("Detail", true, false)
	eq(d.text, long, "the whole line")
	eq(d.autowrap_mode, TextServer.AUTOWRAP_WORD_SMART, "wraps")
	eq(d.max_lines_visible, 2, "onto two lines")
	ok(long_row.custom_minimum_size.y > short_row.custom_minimum_size.y, "the row grows to hold them")
	eq((short_row.find_child("Detail", true, false) as Label).autowrap_mode, TextServer.AUTOWRAP_OFF, "a short line stays one line")
	ok(Sheet._detail_width(long) / 2.0 < Sheet._detail_room(s.items[1]), "two lines are enough for it")
	s.free()
