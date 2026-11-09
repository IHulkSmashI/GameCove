extends "res://tests/test_case.gd"
## The design system: theme tokens and contrast, generated colours, art accent,
## badges, shelves, sort and search, motion switch, hint bar, components.

const Themes := preload("res://theme/themes.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const ArtColor := preload("res://theme/art_color.gd")
const View := preload("res://scripts/ui/library_view.gd")
const Badges := preload("res://scripts/ui/badges.gd")
const Badge := preload("res://scripts/ui/badge.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const Kit := preload("res://scripts/ui/ui_kit.gd")
const ArtCache := preload("res://scripts/ui/art_cache.gd")
const Tile := preload("res://scripts/ui/game_tile.gd")
const Shelf := preload("res://scripts/ui/shelf.gd")
const Osk := preload("res://scripts/ui/osk.gd")
const Toasts := preload("res://scripts/ui/toast.gd")
const SettingsScreen := preload("res://scripts/ui/settings_screen.gd")
const PageTemplate := preload("res://scripts/ui/page_template.gd")
const DiscoverScreen := preload("res://scripts/ui/discover_screen.gd")
const Sounds := preload("res://scripts/ui/sounds.gd")
const UiPrefs := preload("res://scripts/ui/ui_prefs.gd")
const Texts := preload("res://scripts/ui/texts.gd")
const MainScript := preload("res://scripts/main.gd")
const Logic := preload("res://tests/test_ui_logic.gd")


func _ttb(h: float) -> Dictionary:
	return {"time_to_beat": {"main_h": h, "extra_h": null, "complete_h": null, "count": 5, "source": "igdb"}}


# ------------------------------------------------------------ themes

func test_every_theme_has_every_token() -> void:
	eq(Themes.ORDER.size(), 4, "four built-in themes")
	for id in Themes.ORDER:
		var t: Dictionary = Themes.get_theme(id)
		for k in Themes.TOKENS:
			ok(t.has(k) and t[k] is Color, "%s has colour token %s" % [id, k])
		for k in Themes.NUMBERS:
			ok(t.has(k), "%s has number %s" % [id, k])
		ok(Themes.NAMES.has(id) and Texts.THEME_LINES.has(id), "%s has a name and a line" % id)


func test_theme_text_contrast() -> void:
	for id in Themes.ORDER:
		var t: Dictionary = Themes.get_theme(id)
		var glass := Themes.over(t["glass"], t["bg"])
		for panel in [t["surface"], t["surface_2"], glass]:
			ok(Themes.contrast(t["text"], panel) >= 4.5, "%s: text on panel %.1f" % [id, Themes.contrast(t["text"], panel)])
			ok(Themes.contrast(t["text_2"], panel) >= 4.5, "%s: secondary text on panel %.1f" % [id, Themes.contrast(t["text_2"], panel)])
		ok(Themes.contrast(t["accent"], t["surface"]) >= 4.5, "%s: accent text on surface" % id)
		ok(Themes.contrast(t["on_accent"], t["accent"]) >= 4.5, "%s: text on accent" % id)
		ok(Themes.contrast(t["on_focus"], t["focus_fill"]) >= 4.5, "%s: text on focus fill" % id)
		for k in ["good", "warn", "bad"]:
			ok(Themes.contrast(t[k], t["surface"]) >= 4.5, "%s: %s on surface" % [id, k])
		# Badges sit on the chip over art: check against the chip over black and white.
		var tones := Themes.tones(id)
		eq(tones.keys(), Themes.TONES.keys(), "%s: every badge tone" % id)
		for tone in tones:
			for under in [Color.BLACK, Color.WHITE]:
				var chip := Themes.over(t["chip"], under)
				ok(Themes.contrast(tones[tone], chip) >= 4.5, "%s: badge tone '%s' on chip" % [id, tone])
		# Solid corner flags: dark text on the bright tone, every theme.
		for tone in Themes.TONES:
			ok(Themes.contrast(Color("#0A0F16"), Themes.TONES[tone]) >= 4.5, "flag '%s' text" % tone)


func test_contrast_math() -> void:
	ok(absf(Themes.contrast(Color.BLACK, Color.WHITE) - 21.0) < 0.01, "black on white is 21:1")
	ok(absf(Themes.contrast(Color.RED, Color.RED) - 1.0) < 0.001, "same colour is 1:1")


func test_theme_switch_live() -> void:
	ThemeLib.use("light")
	var th := ThemeLib.build()
	eq(th.get_color("text", "GC"), Themes.get_theme("light")["text"], "tokens on the Theme")
	eq(ThemeLib.is_dark(), false, "light theme")
	ThemeLib.use("nope")
	eq(ThemeLib.theme_id, "cove", "unknown theme falls back to Cove")
	ThemeLib.use("cove", Color("#FF0000"))
	ok(Themes.contrast(ThemeLib.color("accent"), ThemeLib.color("surface")) >= 4.5, "device accent made readable")
	ok(Themes.contrast(ThemeLib.color("on_accent"), ThemeLib.color("accent")) >= 4.5, "text on device accent readable")
	ThemeLib.use("cove")
	var c := Control.new()
	c.theme = ThemeLib.build()
	eq(c.theme.get_type_variation_base("GlassPanel"), &"PanelContainer", "glass panel variation")
	c.free()


# ------------------------------------------------------------ colour from art

func test_fallback_colours_stable_and_distinct() -> void:
	var a := ArtColor.fallback_colors("steam:1")
	eq(a, ArtColor.fallback_colors("steam:1"), "same key, same colours")
	ok(a != ArtColor.fallback_colors("epic:2"), "different key, different colours")
	ok(a[1].v > a[0].v, "partner is brighter than the base")
	# White title on the base must read.
	for k in ["steam:1", "gog:3", "amazon:x", "epic:fn", ""]:
		var c := ArtColor.fallback_colors(k)
		ok(Themes.contrast(Color.WHITE, c[0]) >= 4.5, "title readable on fallback base for '%s'" % k)


func test_vibrant_colour_and_accent() -> void:
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.1, 0.1, 0.12))
	img.fill_rect(Rect2i(0, 0, 32, 12), Color(0.9, 0.3, 0.2))
	var v := ArtColor.vibrant(img)
	ok(v.a > 0.0 and v.r > v.g and v.r > v.b, "picks the red: %s" % v)
	var grey := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	grey.fill(Color(0.5, 0.5, 0.5))
	eq(ArtColor.vibrant(grey).a, 0.0, "grey art has no vibrant colour")
	for id in Themes.ORDER:
		var t: Dictionary = Themes.get_theme(id)
		for picked in [Color("#2A0F5E"), Color("#FFE600"), Color("#103010"), v]:
			var acc := ArtColor.accent_for(picked, t)
			ok(Themes.contrast(acc, t["surface"]) >= 4.5, "%s: art accent readable on surface" % id)
			ok(Themes.contrast(ArtColor.on_color(acc), acc) >= 4.5, "%s: text on art accent readable" % id)
		eq(ArtColor.accent_for(Color(0, 0, 0, 0), t), t["accent"], "%s: no art colour keeps theme accent" % id)


func test_art_cache_blur_and_crop() -> void:
	var img := Image.create(400, 100, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.2, 0.4, 0.9))
	var r := ArtCache.blurred(img)
	eq(r[0].get_width(), 320, "blur is 320 wide")
	ok(r[1].b > r[1].r, "accent from the blur pass")
	var c := ArtCache.crop_to(img, 2.0 / 3.0)
	ok(absf(float(c.get_width()) / c.get_height() - 2.0 / 3.0) < 0.02, "cover crop is 2:3")
	eq(ArtCache.request("cover", ""), null, "no path, no texture")
	eq(ArtCache.request("cover", "/nope/missing.png"), null, "missing file, no texture")


# ------------------------------------------------------------ badges

func test_badges_for_game() -> void:
	var now := 1_000_000
	var g := Logic.g("steam", "1", "A", true, 0, {"protondb": "gold", "anticheat": {"status": "denied", "anticheats": []}})
	g["info"]["time_to_beat"] = _ttb(6.0)["time_to_beat"]
	g["deal"] = {"cut": 60}
	g["wishlisted"] = true
	g["added"] = now - 86400
	g["update_available"] = true
	g["info"]["device_rating"] = "great"
	var kinds: Array = Badges.for_game(g, now).map(func(b): return b["kind"])
	eq(kinds, ["sale", "wish", "new", "update", "device", "protondb", "anticheat", "ttb", "store"], "every badge kind, in order")
	var by := {}
	for b in Badges.for_game(g, now):
		by[b["kind"]] = b
	eq(by["sale"]["text"], "On sale -60%", "sale wording")
	eq(by["protondb"]["tone"], "gold", "ProtonDB tier colour")
	eq(by["anticheat"]["tone"], "bad", "denied is bad")
	eq(by["ttb"]["tone"], "good", "short game")
	eq(by["device"]["text"], "Runs great here", "device rating")
	var tile := Badges.for_tile(g, now)
	eq(tile["corner"]["kind"], "sale", "sale wins the corner")
	eq(tile["strip"].map(func(b): return b["kind"]), ["anticheat", "ttb"], "two strip badges")
	g["added"] = now - 86400 * 30
	ok(not Badges.for_game(g, now).any(func(b): return b["kind"] == "new"), "New fades after two weeks")
	eq(Badges.ttb_length(5.0), "short", "short")
	eq(Badges.ttb_length(20.0), "medium", "medium")
	eq(Badges.ttb_length(50.0), "long", "long")
	eq(Badges.ttb_tone(50.0), "info", "long tone")
	var dl := Logic.g("steam", "2", "B", false)
	dl["download"] = {"progress": 0.456}
	eq(Badges.for_tile(dl)["corner"]["text"], "Downloading 46%", "download progress")


func test_badge_component() -> void:
	var b: PanelContainer = Badge.make({"kind": "sale", "text": "On sale -60%", "short": "-60%", "tone": "sale", "icon": "tag"}, "tile")
	eq(b.text(), "-60%", "tile shows the short text")
	ok(b.find_child("Icon", true, false) != null, "icon")
	b.free()
	var c: PanelContainer = Badge.make({"kind": "sale", "text": "On sale -60%", "short": "-60%", "tone": "sale", "icon": "tag"}, "chip")
	eq(c.text(), "On sale -60%", "chip shows the full text")
	c.free()


# ------------------------------------------------------------ shelves, sort, search

func _lib() -> Array:
	var a := Logic.g("steam", "1", "Alpha", true, 100, _ttb(4.0))
	var b := Logic.g("epic", "2", "bravo", true, 300, {"anticheat": {"status": "works", "anticheats": ["EAC"]}})
	var c := Logic.g("gog", "3", "Charlie: Ünïcode", false, 0, _ttb(40.0))
	var d := Logic.g("steam", "4", "Delta Force", true, 0, _ttb(9.5))
	a["playtime_min"] = 50
	b["playtime_min"] = 900
	d["playtime_min"] = 300
	return [a, b, c, d]


func test_shelves() -> void:
	var s := View.shelves(_lib())
	eq(s.map(func(x): return x["id"]), ["recent", "installed", "short", "anticheat", "store_steam", "store_epic", "store_gog", "all"], "shelf order")
	eq(s[2]["games"].map(func(g): return g["title"]), ["Alpha", "Delta Force"], "short games, shortest first")
	eq(s[3]["games"].map(func(g): return g["title"]), ["bravo"], "anti-cheat friendly")
	eq(s[-1]["games"].map(func(g): return g["title"]), ["Alpha", "bravo", "Charlie: Ünïcode", "Delta Force"], "all games A to Z")
	var one_store := View.shelves([Logic.g("steam", "1", "A"), Logic.g("steam", "2", "B")])
	ok(not one_store.any(func(x): return String(x["id"]).begins_with("store_")), "no store shelves with one store")
	eq(View.shelves([]), [], "empty library, no shelves")


func test_sort() -> void:
	var lib := _lib()
	var titles := func(list): return list.map(func(g): return g["title"])
	eq(titles.call(View.sort_games(lib, "recent")), ["bravo", "Alpha", "Charlie: Ünïcode", "Delta Force"], "recent, then A to Z")
	eq(titles.call(View.sort_games(lib, "az")), ["Alpha", "bravo", "Charlie: Ünïcode", "Delta Force"], "A to Z ignores case")
	eq(titles.call(View.sort_games(lib, "playtime")), ["bravo", "Delta Force", "Alpha", "Charlie: Ünïcode"], "most played")
	eq(titles.call(View.sort_games(lib, "ttb")), ["Alpha", "Delta Force", "Charlie: Ünïcode", "bravo"], "shortest first, unknown last")
	eq(lib[0]["title"], "Alpha", "input untouched")


func test_search() -> void:
	var lib := _lib()
	var titles := func(q): return View.search(lib, q).map(func(g): return g["title"])
	eq(titles.call(""), ["Alpha", "bravo", "Charlie: Ünïcode", "Delta Force"], "empty query keeps all")
	eq(titles.call("BRA"), ["bravo"], "case-insensitive")
	eq(titles.call("unicode"), ["Charlie: Ünïcode"], "accents folded")
	eq(titles.call("d f"), ["Delta Force"], "word starts")
	eq(titles.call("lta"), ["Delta Force"], "substring")
	eq(titles.call("xyz"), [], "no match")
	eq(View.fold("  The Witcher 3: Wild-Hunt "), "the witcher 3 wild hunt", "fold")


# ------------------------------------------------------------ motion

func test_reduce_motion_switch() -> void:
	var c := Control.new()
	var was := Motion.reduce
	Motion.reduce = true
	eq(Motion.to(c, "modulate:a", 0.25, 0.3), null, "no tween under reduce motion")
	ok(absf(c.modulate.a - 0.25) < 0.001, "value set at once")
	eq(Motion.slide(30.0), 0.0, "no slide under reduce motion")
	Motion.reduce = false
	eq(Motion.slide(30.0), 30.0, "slides back on")
	eq(Motion.to(c, "modulate:a", 0.5, 0.3), null, "outside the tree values jump too")
	ok(absf(c.modulate.a - 0.5) < 0.001, "value set")
	Motion.reduce = was
	c.free()


func test_prefs_round_trip() -> void:
	var path := "user://test_ui_prefs.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var was_motion := Motion.reduce
	UiPrefs.load_prefs(path)
	eq(UiPrefs.values(), UiPrefs.DEFAULTS, "defaults when there's no file")
	UiPrefs.set_values({"theme": "sunset", "match_art": false, "reduce_motion": true})
	ok(Motion.reduce, "reduce motion applied")
	UiPrefs.save_prefs()
	UiPrefs.set_values(UiPrefs.DEFAULTS)
	UiPrefs.load_prefs(path)
	eq(UiPrefs.values(), {"theme": "sunset", "match_art": false, "reduce_motion": true}, "saved and loaded")
	UiPrefs.set_values({"theme": "bogus"})
	eq(UiPrefs.theme, "cove", "unknown theme rejected")
	UiPrefs.set_values(UiPrefs.DEFAULTS)
	UiPrefs.path = UiPrefs.PATH
	Motion.reduce = was_motion


# ------------------------------------------------------------ components

func test_icons_and_glyphs() -> void:
	for n in Icons.PATHS:
		ok(Icons.svg(n).begins_with("<svg"), "icon " + n)
	ok(Icons.tex("play", 24) != null, "icon texture")
	ok(Icons.battery(50, true) != null, "battery icon")
	var row := Kit.prompts([["A", "Open"], [["LB", "RB"], "Sections"], ["GUIDE", "Quick menu"]])
	eq(Kit.prompts_text(row), "A Open  LB RB Sections  GUIDE Quick menu", "prompt row")
	row.free()


func test_hints_follow_focus() -> void:
	var h := MainScript.hints_for({"screen": "home", "page": false, "kind": "tile"})
	eq(h[0], ["A", "Open"], "tile: A opens")
	ok(h.any(func(x): return x[1] == "Sections"), "LB/RB on screens")
	ok(not h.any(func(x): return x[1] == "Search"), "no search on home")
	var l := MainScript.hints_for({"screen": "library", "page": false, "kind": "tile"})
	ok(l.any(func(x): return x == ["Y", "Search"]) and l.any(func(x): return x == ["X", "Sort"]), "library: search and sort")
	ok(l.any(func(x): return x == ["B", "Home"]), "B goes home from other tabs")
	var p := MainScript.hints_for({"screen": "home", "page": true, "kind": "play", "label": "Install"})
	eq(p[0], ["A", "Install"], "page: A says what Play does")
	ok(p.any(func(x): return x == ["B", "Back"]) and not p.any(func(x): return x[1] == "Sections"), "page: B back, no tabs")
	eq(MainScript.hints_for({"screen": "settings", "kind": "row"})[0], ["LR", "Change"], "rows: left/right change")
	eq(MainScript.hints_for({"kind": ""})[-1], ["GUIDE", "Quick menu"], "quick menu always listed")


func test_tile_and_shelf() -> void:
	var g := Logic.g("gog", "3", "Witcher 3", false, 0, _ttb(30.0))
	var t: Button = Tile.new()
	t.setup(g)
	eq(t.custom_minimum_size, Tile.SIZE, "tile size")
	ok(t.find_child("TitleCard", true, false).visible, "no art: generated cover")
	ok(not t.has_cover(), "no cover texture")
	eq(t.badge_specs(g).map(func(b): return b["kind"]), ["ttb", "not_installed"], "tile badges")
	t.free()
	var s: VBoxContainer = Shelf.new()
	s.setup("short", "Short games", [Logic.g("steam", "1", "A"), Logic.g("steam", "2", "B")])
	eq(s.tiles.size(), 2, "shelf tiles")
	eq(s.tiles[0].get_node(s.tiles[0].focus_neighbor_left), s.tiles[0], "left end stops")
	eq(s.tiles[0].get_node(s.tiles[0].focus_neighbor_right), s.tiles[1], "right goes along")
	eq(s.remembered(), s.tiles[0], "remembers the first tile")
	s.free()


func test_keyboard() -> void:
	var k: PanelContainer = Osk.new()
	var got: Array = []
	k.text_changed.connect(func(t): got.append(t))
	k.type("h")
	k.type("i")
	k.backspace()
	k.type(" ")
	eq(got, ["h", "hi", "h", "h "], "typing")
	eq(k.text, "h ", "text")
	k.set_text("")
	eq(k.field.text, "Type to search", "placeholder")
	for r in k.keys:
		for b in r:
			ok(b.focus_neighbor_top != NodePath() and b.focus_neighbor_bottom != NodePath(), "key wired")
	k.free()


func test_toasts() -> void:
	var t: VBoxContainer = Toasts.new()
	for i in 5:
		t.show_toast("Note %d" % i, "info", "good")
	eq(t.count(), Toasts.MAX, "at most three at once")
	ok(t.get_child(0).focus_mode == Control.FOCUS_NONE, "never takes focus")
	t.free()


func test_settings_screen() -> void:
	var s: Control = SettingsScreen.new()
	s.setup({"theme": "midnight", "match_art": false, "reduce_motion": true, "menu_side": "left", "ui_sounds": "off"}, [["Device", "Claw"]])
	eq(s.rows.keys(), ["theme", "match_art", "reduce_motion", "menu_side", "ui_sounds"], "settings rows")
	eq(s.rows["theme"].value(), "midnight", "current theme")
	eq(s.rows["reduce_motion"].value(), true, "reduce motion on")
	var got: Array = []
	s.changed.connect(func(k, v): got.append([k, v]))
	s.rows["theme"].step(1)
	s.rows["reduce_motion"].step(1)
	eq(got, [["theme", "sunset"], ["reduce_motion", false]], "changes reported")
	for k in s.rows:
		ok(s.rows[k].hint_text().length() > 20, "explanation under " + k)
	s.free()


func test_page_template() -> void:
	var p: Control = PageTemplate.new()
	p.setup_page(Logic.g("steam", "1", "Hades", true, 0, _ttb(20.0)), "On sale")
	var play: Button = p.add_action("Play", "play", true, "Play")
	var more: Button = p.add_action("Wishlist", "star")
	var body: VBoxContainer = p.add_card("About", "info")
	var row: VBoxContainer = load("res://scripts/ui/choice_row.gd").bool_row("frame_gen", "Frame generation", false)
	body.add_child(row)
	p.add_focusables([row.button])
	p.finish()
	eq(p.header.eyebrow.text, "On sale", "line above the title")
	eq(play.get_node(play.focus_neighbor_right), more, "actions in a row")
	eq(play.get_node(play.focus_neighbor_bottom), row.button, "down into the cards")
	eq(more.get_node(more.focus_neighbor_bottom), row.button, "down from any action")
	eq(row.button.get_node(row.button.focus_neighbor_top), play, "up returns to the primary action")
	p.free()


func test_discover_hook() -> void:
	var d: Control = DiscoverScreen.new()
	d.setup({"prefs_path": ""})
	ok(d.find_child("DiscoverRoot", true, false) != null, "the Discover area by default")
	d.free()
	DiscoverScreen.content_factory = func(_svc):
		var c := Label.new()
		c.name = "Custom"
		return c
	var d2: Control = DiscoverScreen.new()
	d2.setup({"library": null})
	ok(d2.find_child("Custom", true, false) != null, "factory content used")
	d2.free()
	DiscoverScreen.content_factory = Callable()


func test_sounds_synthesised() -> void:
	var s: Node = Sounds.new()
	for k in ["move", "select", "back", "toast"]:
		var st: AudioStreamWAV = s.stream(k)
		ok(st.data.size() > 400, "sound %s has samples" % k)
	s.set_level("bogus")
	eq(s.level, "low", "unknown level falls back to low")
	s.set_level("off")
	s.play("move")
	eq(s.get_child_count(), 0, "off: no players created")
	s.free()


func test_ambient_glow_follows_the_game() -> void:
	var Backdrop = load("res://scripts/ui/backdrop.gd")
	var was := Motion.reduce
	var was_match := UiPrefs.match_art
	Motion.reduce = true
	UiPrefs.match_art = true
	var b: Control = Backdrop.new()
	eq(b.glow.modulate.a, 0.0, "no glow without a game")
	b.show_game(Logic.g("steam", "77", "Artless", true, 0))
	ok(b.glow.modulate.a > 0.2, "an art-less game still tints the room (its generated colours)")
	var c: Color = b.glow.modulate
	b.show_game(Logic.g("steam", "78", "Another One", true, 0))
	ok(b.glow.modulate != c, "the colour follows focus")
	eq(b.glow.texture, Backdrop.glow_texture(), "one shared gradient texture")
	UiPrefs.match_art = false
	b.show_game(Logic.g("steam", "79", "Third", true, 0))
	eq(b.glow.modulate.a, 0.0, "off with Match game art colours")
	b.free()
	var p: Control = PageTemplate.new()
	p.setup_page(Logic.g("steam", "80", "Paged", true, 0))
	UiPrefs.match_art = true
	p.set_accent(Color(0.9, 0.4, 0.1))
	ok(p.glow.modulate.a > 0.2, "game page glows in the game's colour")
	p.free()
	Motion.reduce = was
	UiPrefs.match_art = was_match


func test_shelf_fades_its_edges() -> void:
	var games: Array = []
	for i in 14:
		games.append(Logic.g("steam", str(200 + i), "Game %d" % i, true, 0))
	var s: VBoxContainer = Shelf.new()
	s.setup("t", "Test", games)
	eq(s.tile_size, Tile.size_for(Tile.row_width(), Shelf.GAP), "tiles sized for the screen")
	eq(s.faded_edges(), [false, false], "nothing faded before layout")
	s.free()
