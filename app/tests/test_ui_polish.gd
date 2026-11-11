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


# ---- nothing sliced at the foot ------------------------------------------------

## Settings pages follow the device pages' rule: cards the foot would slice
## aren't drawn, inside a long card its rows count, and "More below" shows.
func test_settings_foot_rule() -> void:
	var tall := VBoxContainer.new()
	tall.size = Vector2(600, 900)
	var rows: Array = []
	for i in 6:
		var r := PanelContainer.new()
		r.size = Vector2(600, 110)
		tall.add_child(r)
		rows.append(r)
	var short := PanelContainer.new()
	short.size = Vector2(600, 180)
	var page := VBoxContainer.new()
	page.add_child(short)
	page.add_child(tall)
	var out: Array = []
	SettingsScreen._cut_items_in(page, 300.0, out, 0)
	ok(short in out, "a short card is one piece")
	ok(not tall in out, "a long card isn't")
	for r in rows:
		ok(r in out, "its rows are")
	page.free()
	# The cut ends softly in the gap (a long card's own panel goes on below it).
	ok(FadeMask.CUT_FADE >= 6.0 and FadeMask.CUT_FADE <= 12.0, "the cut fades over the gap between rows")


# ---- the game page ---------------------------------------------------------------

## Time to beat is its own card that goes under the shortest column, so
## About (the tallest) doesn't run below the fold beside half-empty columns.
func test_time_to_beat_floats_to_the_shortest_column() -> void:
	for want in [[[900.0, 300.0, 220.0], "Column2"], [[900.0, 300.0, 700.0], "Column1"], [[200.0, 300.0, 700.0], "Column0"]]:
		var p: Control = Page.new()
		p.size = Vector2(1536, 960)
		p.setup_page(Logic.g("gog", "1", "Cyber", true, 100))
		var heights: Array = want[0]
		for i in 3:
			var body: VBoxContainer = p.add_card("Card %d" % i, "info", "", true, i)
			var block := Control.new()
			block.custom_minimum_size = Vector2(0, heights[i])
			body.add_child(block)
		# (last here: outside the scene tree a card's height is measured once)
		var fbody: VBoxContainer = p.add_card("Time to beat", "clock", "", true, -1, true)
		var fcard: Control = fbody.get_parent()
		eq(p.columns.get_child_count(), 3, "three columns: the floating card takes none")
		eq(String(fcard.get_parent().name), want[1], "under the shortest column of %s" % str(heights))
		eq(fcard.get_index(), 1, "below that column's own card")
		p._place_floats()
		eq(String(fcard.get_parent().name), want[1], "and stays put once placed")
		p.free()


func test_game_page_about_keeps_its_last_lines_in_reach() -> void:
	var games := Games.new()
	var r: Dictionary = games._rig()
	var g: Dictionary = games._steam_game()
	g["info"]["time_to_beat"] = {"main_h": 33.0, "extra_h": 72.0, "complete_h": 129.0, "count": 21}
	var p: Control = GamePage.new()
	p.setup(g, Screens.FakeLauncher.new(), {"library": r["lib"], "state": r["state"], "actions": r["actions"]})
	ok(p.ttb_card != null, "time to beat has its own card")
	ok(p.ttb_card.get_parent().get_meta("float", false), "a floating one")
	var about: Control = p.find_child("Card_" + games.TG.ABOUT.validate_node_name(), true, false)
	ok(about != null and about.find_child("TimeToBeat", true, false) == null, "and no longer lengthens About")
	ok(p.ttb_card.find_child("TimeToBeat", true, false) != null, "the three times are in the card")
	# The read-only lines after About's last button come into view with it.
	var with: Variant = p.meta_card.artwork_button.get_meta("reveal_with", null)
	ok(with is Control and about.is_ancestor_of(with), "Change artwork brings About's last lines with it")
	p.free()
	# Without numbers there's no card, just the line.
	var q: Control = GamePage.new()
	q.setup(games._steam_game(), Screens.FakeLauncher.new(), {"library": r["lib"], "state": r["state"], "actions": r["actions"]})
	ok(q.ttb_card == null, "no times, no card")
	q.free()
	games._free(r)


# ---- Discover: a short Free to keep row ---------------------------------------------

func test_featured_cards_fill_a_short_row() -> void:
	var usual: Vector2 = Tile.size_for(Tile.row_width(), Shelf.GAP)
	var f: Vector2 = Shelf.featured_size(1184.0)
	eq(f.y, usual.y, "as tall as the usual covers")
	eq(f.x * 2.0 + Shelf.GAP, 1184.0, "two fill the row exactly")
	ok(f.x > usual.x * 3.0, "wide, not a lonely cover")
	eq(Tile.lift_for(usual), Tile.LIFT, "covers lift as before")
	ok((Tile.lift_for(f) - 1.0) * f.x <= (Tile.LIFT - 1.0) * usual.y + 0.5, "a wide card grows by a few px, not out of its row")
	# A wide card shows the wide art when the game has it, else its cover.
	var dir := ProjectSettings.globalize_path("user://test_featured")
	DirAccess.make_dir_recursive_absolute(dir)
	var img := Image.create(64, 32, false, Image.FORMAT_RGB8)
	img.fill(Color(0.2, 0.5, 0.7))
	img.save_png(dir.path_join("hero.png"))
	img.save_png(dir.path_join("cover.png"))
	var g: Dictionary = Logic.g("epic", "f", "Flotsam")
	g["art"]["cover"] = dir.path_join("cover.png")
	var s: VBoxContainer = Shelf.new()
	s.art_kind = "hero"
	s.setup("free", "Free to keep", [g], f)
	var t: Button = s.tiles[0]
	eq(t.custom_minimum_size, f, "the card takes the featured size")
	eq(t.cover_path(), g["art"]["cover"], "no wide art yet: the cover")
	g["art"]["hero"] = dir.path_join("hero.png")
	eq(t.cover_path(), g["art"]["hero"], "the wide art once it's there")
	eq(t._art_kind(), "hero", "loaded uncropped")
	s.free()


# ---- Light: dark ink on light chips and cards ------------------------------------------

## Every text / ground pair the Light theme puts on a hero or a card reads at
## AA: chips (each tone on its own opaque fill), and the achievements card's
## small lines on its glass, whatever art is behind it.
func test_light_inks_reach_aa() -> void:
	ThemeLib.use("light")
	var t: Dictionary = Themes.get_theme("light")
	for tone in Themes.TONES_LIGHT:
		var chip: Control = Badge.make({"kind": "x", "text": "Community reports: Gold", "tone": tone, "icon": "clock"}, "chip")
		var sb := chip.get_theme_stylebox("panel") as StyleBoxFlat
		eq(sb.bg_color.a, 1.0, "chip %s: opaque" % tone)
		ok(sb.bg_color.get_luminance() > 0.8, "chip %s: light" % tone)
		var ink: Color = chip.label.get_theme_color("font_color")
		var c := Themes.contrast(ink, sb.bg_color)
		ok(c >= 4.5, "chip %s: dark ink at %.2f" % [tone, c])
		chip.free()
	# The achievements card on the hero sits on art: its ground is opaque, so
	# its small lines read the same over the darkest picture.
	var pc: PanelContainer = load("res://scripts/ui/progress_card.gd").new()
	pc._restyle()
	var ground: Color = (pc.get_theme_stylebox("panel") as StyleBoxFlat).bg_color
	eq(ground.a, 1.0, "the hero's achievements card is opaque in Light")
	for l in [pc.rare_line, pc.battery_label, pc.count_label]:
		var c := Themes.contrast((l as Label).get_theme_color("font_color"), ground)
		ok(c >= 4.5, "achievements card: %s at %.2f" % [l.name, c])
	for name in ["text", "text_2", "accent", "good", "warn", "bad", "info"]:
		ok(Themes.contrast(t[name], ground) >= 4.5, "light: %s on the card is %.2f" % [name, Themes.contrast(t[name], ground)])
	pc.free()
	# Cards elsewhere stand on Light's own ground (never on art).
	for k in ["surface", "surface_2", "glass", "glass_2"]:
		var gr: Color = Themes.over(t[k], t["bg"])
		for name in ["text", "text_2", "accent", "good", "warn", "bad", "info"]:
			var c := Themes.contrast(t[name], gr)
			ok(c >= 4.5, "light: %s on %s is %.2f" % [name, k, c])
	ThemeLib.use("cove")
