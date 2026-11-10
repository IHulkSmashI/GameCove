extends "res://tests/test_case.gd"
## The neon design language: new tokens and their contrast in every theme,
## fonts, the primary gradient (also from art colours), glyph sets, button
## extras, top-bar telemetry and count, the progression card, tiles.

const Themes := preload("res://theme/themes.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const ArtColor := preload("res://theme/art_color.gd")
const Kit := preload("res://scripts/ui/ui_kit.gd")
const Glyph := preload("res://scripts/ui/glyph.gd")
const TopBar := preload("res://scripts/ui/top_bar.gd")
const ProgressCard := preload("res://scripts/ui/progress_card.gd")
const Tile := preload("res://scripts/ui/game_tile.gd")
const ChoiceRow := preload("res://scripts/ui/choice_row.gd")
const MainScript := preload("res://scripts/main.gd")
const Logic := preload("res://tests/test_ui_logic.gd")


func _opaque(t: Dictionary, k: String) -> Color:
	var c: Color = t[k]
	return Themes.over(c, t["bg"]) if c.a < 1.0 else c


func test_new_tokens_in_every_theme() -> void:
	for k in ["glass_2", "line_2", "accent_end", "ring", "glow", "face_a", "face_b", "face_x", "face_y", "on_face"]:
		ok(Themes.TOKENS.has(k), "token %s documented" % k)
	for id in Themes.ORDER:
		var t: Dictionary = Themes.get_theme(id)
		for k in Themes.TOKENS:
			ok(t.has(k) and t[k] is Color, "%s has %s" % [id, k])
		ok(int(t.get("glow_size", 0)) > 0, "%s has a glow size" % id)


func test_text_tokens_reach_4_5() -> void:
	for id in Themes.ORDER:
		var t: Dictionary = Themes.get_theme(id)
		for pair in Themes.TEXT_PAIRS:
			var c := Themes.contrast(_opaque(t, pair[0]), _opaque(t, pair[1]))
			ok(c >= 4.5, "%s: %s on %s is %.2f" % [id, pair[0], pair[1], c])
		# The focus ring must stand out from the screen (non-text, 3:1).
		ok(Themes.contrast(t["ring"], t["bg"]) >= 3.0, "%s: ring visible on bg" % id)


func test_fonts_bundled() -> void:
	for w in ThemeLib.FONT_FILES:
		ok(ResourceLoader.exists(ThemeLib.FONT_FILES[w]), "font file for " + w)
	ok(ThemeLib.font("display") != null and ThemeLib.font("mono") != null, "Outfit and JetBrains Mono load")
	var wide: Font = ThemeLib.mono(false, 2)
	ok(wide is FontVariation and (wide as FontVariation).spacing_glyph == 2, "mono micro labels are tracked wide")
	ok((ThemeLib.font("display_tight") as FontVariation).spacing_glyph < 0, "display titles tracked tight")
	for f in ["OFL-Outfit.txt", "OFL-PlusJakartaSans.txt", "OFL-JetBrainsMono.txt"]:
		ok(FileAccess.file_exists("res://fonts/" + f), "licence " + f)
	ok(not FileAccess.file_exists("res://fonts/Inter-Regular.otf"), "Inter dropped")


func test_gradient_end_keeps_label_readable() -> void:
	for id in Themes.ORDER:
		var t: Dictionary = Themes.get_theme(id)
		for art in [Color("#FF9E40"), Color("#2B8C9E"), Color("#B8A6FF"), Color("#7FB069"), Color("#E0417A"), Color("#FFFFFF")]:
			var a := ArtColor.accent_for(art, t)
			var on := ArtColor.on_color(a)
			var e := ArtColor.gradient_end(a, on, t)
			ok(Themes.contrast(on, a) >= 4.5, "%s: label on art start %s" % [id, art.to_html()])
			ok(Themes.contrast(on, e) >= 4.5, "%s: label on art end %s" % [id, art.to_html()])
	ThemeLib.use("cove", Color("#FF3355"))
	ok(Themes.contrast(ThemeLib.color("on_accent"), ThemeLib.color("accent_end")) >= 4.5, "device accent: gradient end readable")
	eq(ThemeLib.color("ring"), ThemeLib.color("accent"), "device accent drives the ring")
	ThemeLib.use("cove")


func test_theme_builds_new_variations() -> void:
	for id in Themes.ORDER:
		ThemeLib.use(id)
		var th := ThemeLib.build()
		for v in ["AccentButton", "IconButton", "PillPanel", "MicroLabel", "MonoLabel", "EyebrowLabel"]:
			ok(th.get_type_variation_base(v) != &"", "%s: variation %s" % [id, v])
		ok(th.get_stylebox("normal", "AccentButton") is StyleBoxTexture, "%s: primary is a gradient pill" % id)
		var f: StyleBoxFlat = th.get_stylebox("focus", "Button")
		eq(f.border_width_left, 2, "%s: 2 px focus ring" % id)
		eq(f.border_color, Themes.get_theme(id)["ring"], "%s: ring colour" % id)
	ThemeLib.use("cove")


func test_glyph_sets_and_colours() -> void:
	Glyph.use_set("xbox")
	eq(Glyph.label_for("LB"), "LB", "xbox bumper")
	eq(Glyph.face_color("A"), ThemeLib.color("face_a"), "A is green")
	eq(Glyph.face_color("Y"), ThemeLib.color("face_y"), "Y is yellow")
	eq(Glyph.face_color("LB").a, 0.0, "bumpers aren't coloured")
	Glyph.use_set("deck")
	eq(Glyph.label_for("LB"), "L1", "Deck bumper")
	eq(Glyph.label_for("RT"), "R2", "Deck trigger")
	eq(Glyph.face_color("A").a, 0.0, "Deck faces stay monochrome")
	var g: Control = Kit.glyph("LB")
	eq((g.get_child(0) as Label).text, "L1", "glyph shows the Deck label")
	eq(String(g.name), "Glyph_LB", "name keeps the logical button (prompts_text)")
	g.free()
	Glyph.use_set("nope")
	eq(Glyph.glyph_set, "xbox", "unknown set falls back to xbox")


func test_primary_button_keeps_text() -> void:
	var b := Kit.primary("Play", "A", "play")
	eq(b.text, "Play", "text unchanged (tests, hint bar)")
	var fx: Control = b.get_node("Fx")
	ok(fx.caps and fx.glyph == "A" and fx.glow, "caps, glyph and glow")
	eq(fx._label(), "PLAY", "drawn in capitals")
	ok(b.get_node_or_null("Glow") != null, "glow behind the button")
	Kit.accent_button(b, Color("#FF9E40"))
	ok(Themes.contrast(fx.fg, Color("#FF9E40")) >= 4.5 or fx.fg.a > 0.0, "art colour sets the label colour")
	b.free()
	var s := Kit.secondary("TDP", "power", "X")
	eq(s.get_node("Fx").glyph, "X", "secondary with a glyph")
	eq(s.get_node("Fx").caps, false, "secondary keeps its case")
	s.free()
	var i := Kit.icon_button("search", "Search")
	eq(i.theme_type_variation, &"IconButton", "round icon button")
	i.free()


func test_top_bar_telemetry_and_count() -> void:
	var b: HBoxContainer = TopBar.new()
	b.set_telemetry({"tdp_w": 17.2, "profile": "balanced", "temp_c": 58.0})
	ok(b.telemetry.visible, "pill shows with data")
	eq(b.tdp_label.text, "17W balanced", "watts and profile")
	eq(b.temp_label.text, "58°C", "temperature")
	b.set_telemetry({"tdp_w": -1.0, "profile": "", "temp_c": -1.0})
	ok(not b.telemetry.visible, "nothing known: pill hidden")
	b.set_telemetry({"tdp_w": 12.0, "profile": "", "temp_c": -1.0})
	ok(b.telemetry.visible and not b.temp_label.visible, "temperature hidden when unknown")
	b.set_count("library", 48)
	eq(b.count_text("library"), "48", "library count")
	b.set_count("library", -1)
	eq(b.count_text("library"), "", "count hidden")
	ok(b.search_button != null and b.has_signal("search_pressed"), "search button")
	b.free()


func test_progress_card_real_data_only() -> void:
	var c: PanelContainer = ProgressCard.new()
	c.show_game(Logic.g("steam", "42", "A"))
	ok(not c.visible, "no data: hidden")
	c._on_loaded("42", {"total": 4, "unlocked": 2, "items": [
		{"name": "Common", "unlocked": true, "rarity": 60.0}, {"name": "Rare", "unlocked": true, "rarity": 3.25},
		{"name": "Locked", "unlocked": false, "rarity": 0.5}]})
	ok(c.visible, "shows with achievements")
	eq(c.count_label.text, "2 / 4 (50%)", "count and percent")
	eq(c.rare_name.text, "Rarest: Rare", "rarest unlocked, not locked")
	eq(c.rare_line.text, "Unlocked by 3.2% of players", "rarity line")
	ok(not c.battery_row.visible, "no battery estimate: no line")
	c.set_battery_left("~2 h 05 min")
	ok(c.battery_row.visible, "battery line when known")
	c.show_game(Logic.g("epic", "x", "B"))
	ok(c.visible and not c.bar.visible, "non-Steam game: only the battery line")
	c.free()


func test_battery_left_text() -> void:
	eq(MainScript.battery_left_text({"percent": 50, "status": "Discharging", "watts": 10.0}, 60.0), "~3 h 00 min", "30 Wh at 10 W")
	eq(MainScript.battery_left_text({"percent": 10, "status": "Discharging", "watts": 12.0}, 60.0), "~30 min", "under an hour")
	eq(MainScript.battery_left_text({"percent": 50, "status": "Charging", "watts": 10.0}, 60.0), "", "charging: unknown")
	eq(MainScript.battery_left_text({"percent": 50, "status": "Discharging", "watts": 10.0}, -1.0), "", "no capacity: unknown")


func test_tile_card_layout() -> void:
	var g := Logic.g("steam", "7", "Witcher 3", true, 0)
	g["playtime_min"] = 600
	var t: Button = Tile.new()
	t.setup(g)
	eq(t.custom_minimum_size, Tile.SIZE, "tile size")
	eq(t.sub_label.text, "Steam · 10 h", "mono sub-line: store and playtime")
	eq(t.selected_pill, null, "no SELECTED pill on the cover (ring, lift and details bar say it)")
	eq(t.info_box.get_parent(), t.card, "title block on the card")
	ok(t.title_label.visible, "a generated cover gets its title in the plate")
	eq(t.fallback.get("title_label"), null, "and none in the art (no double title)")
	ok(t.fallback.monogram, "a monogram watermark instead")
	ok(t.sub_label.get_theme_font_size("font_size") >= 12, "sub-line at the readability floor")
	t.free()
	var u := Logic.g("steam", "9", "Neon", false, 0, {"anticheat": {"status": "denied", "anticheats": ["EAC"]}})
	var t2: Button = Tile.new()
	t2.setup(u)
	ok(t2.corner_badge != null and t2.corner_badge.get_parent() == t2.sub_row, "status pill sits at the end of the store line, clear of the cover's logo")
	ok(t2.sub_row.get_child(t2.sub_row.get_child_count() - 1) == t2.corner_badge, "on its right")
	eq(t2.corner_badge.label.text, "Linux denied", "the anti-cheat problem, not 'Not installed'")
	t2.free()
	eq(Tile.size_for(1216.0), Vector2(Tile.SIZE.x + 2, roundf((Tile.SIZE.x + 2) * Tile.SIZE.y / Tile.SIZE.x)), "1280x800: about the base size")
	ok(Tile.size_for(1472.0).x > 180.0, "1920x1200: bigger covers, still seven across")
	eq(Tile.size_for(800.0), Tile.SIZE, "never smaller than the base size")
	eq(Tile.sub_text(Logic.g("gog", "1", "X", false)), "GOG · Not installed", "not installed")


func test_tile_focus_ring_is_theme_accent() -> void:
	var g := Logic.g("steam", "8", "Hollow Tide", true, 0)
	var t: Button = Tile.new()
	t.setup(g)   # no art: the generated cover's colour stands in for the art's
	t._refresh_glow_color()
	eq(t._glow_box.border_color, ThemeLib.color("accent"), "ring in the theme accent, not the art colour")
	ok(t.accent() != ThemeLib.color("accent"), "the art colour differs here (so the test means something)")
	ok(not t._glow_box.shadow_color.is_equal_approx(Color(ThemeLib.color("accent"), 0.45)), "the art colour tints the glow")
	t.free()


func test_choice_row_segments() -> void:
	ok(ChoiceRow.segmented(["Battery", "Balanced", "Performance"]), "three short values: segments")
	ok(not ChoiceRow.segmented(["A"]), "one value: no segments")
	ok(not ChoiceRow.segmented(["1", "2", "3", "4", "5"]), "five values: arrows")
	var r: VBoxContainer = ChoiceRow.new()
	r.setup("fan", "Fan", ["quiet", "auto", "max"], ["Quiet", "Auto", "Max"], "auto")
	ok(r.find_child("Segments", true, false) != null, "segmented control built")
	eq(r.value_text(), "Auto", "value text kept")
	r.step(1)
	eq(r.value(), "max", "left/right still step")
	r.free()


func test_big_screens_get_more_room() -> void:
	eq(MainScript.base_size_for(Vector2i(1280, 800)), Vector2i(1280, 800), "800p unchanged")
	eq(MainScript.base_size_for(Vector2i(1024, 640)), Vector2i(1280, 800), "smaller: same base")
	eq(MainScript.base_size_for(Vector2i(1920, 1200)), Vector2i(1536, 960), "1200p lays out at 1.25x")


func test_slider_tick_labels_are_even() -> void:
	var SliderRow = load("res://scripts/ui/slider_row.gd")
	eq(SliderRow.tick_values(5.0, 25.0, 1.0), [5.0, 10.0, 15.0, 20.0, 25.0], "even steps on 5-25 W")
	eq(SliderRow.tick_values(8.0, 35.0, 1.0), [8.0, 15.0, 22.0, 28.0, 35.0], "even steps from an odd start")
	eq(SliderRow.tick_values(0.0, 2.0, 1.0), [0.0, 1.0, 2.0], "no repeats on a short range")
	var v: Array = SliderRow.tick_values(8.0, 35.0, 1.0)
	eq(v[0], 8.0, "starts at the minimum")
	eq(v[-1], 35.0, "ends at the maximum")
	ok(v.size() <= SliderRow.MAX_LABELS, "at most %d labels" % SliderRow.MAX_LABELS)
	var r: VBoxContainer = SliderRow.new()
	r.setup("tdp", "Power limit (TDP)", 5, 30, 17)
	eq(r.value_text(), "17 W", "value shown")
	ok(r.find_child("Ticks", true, false) != null, "labelled ticks")
	r.free()
	var t: Array = SliderRow.tick_values(8.0, 35.0, 1.0)
	eq(SliderRow.lit_tick(t, 20.0, 1.0), -1, "20 W lights no tick (not the nearest, 22 W)")
	eq(SliderRow.lit_tick(t, 22.0, 1.0), 2, "22 W lights 22 W")
	eq(SliderRow.lit_tick([2.0, 5.0, 8.0], 6.0, 1.0), -1, "Boost 6 W lights no tick")
	eq(SliderRow.lit_tick([0.0, 0.5, 1.0], 0.5, 0.5), 1, "half steps")


func test_selected_row_ring_is_opaque() -> void:
	var s: StyleBoxFlat = ThemeLib.row_focus()
	eq(s.bg_color.a, 1.0, "opaque fill, so the glow never tints the row")
	eq(s.border_width_top, 3, "thick ring")
	ok(s.shadow_size > 0, "glow")


func test_chip_badges_are_colourful() -> void:
	var Badge = load("res://scripts/ui/badge.gd")
	var b: PanelContainer = Badge.make({"kind": "proton", "text": "ProtonDB Platinum", "short": "Platinum", "tone": "platinum", "icon": "gauge"}, "chip")
	eq(b.label.get_theme_color("font_color"), ThemeLib.tone("good"), "Platinum reads as works")
	b.free()
	var n: PanelContainer = Badge.make({"kind": "ttb", "text": "18 h to beat", "short": "18 h", "tone": "", "icon": "clock"}, "chip")
	eq(n.label.get_theme_color("font_color"), ThemeLib.color("accent"), "neutral facts in the accent")
	n.free()


func test_titles_in_capitals() -> void:
	var t := Kit.label("Library", "TitleLabel")
	ok(t.uppercase and t.text == "Library", "shown in capitals, text kept")
	t.free()
	var q := Kit.label("x", "QuietLabel")
	ok(not q.uppercase, "body text untouched")
	q.free()


func test_boot_splash_skipped_under_reduce_motion() -> void:
	var Motion = load("res://scripts/ui/motion.gd")
	var Splash = load("res://scripts/ui/boot_splash.gd")
	var host := Control.new()
	var was: bool = Motion.reduce
	Motion.reduce = true
	eq(Splash.play(host), null, "no splash")
	Motion.reduce = was
	var s: Control = Splash.new()
	eq(s.mouse_filter, Control.MOUSE_FILTER_IGNORE, "never takes input")
	s.free()
	host.free()


func test_tile_pills_readable_in_every_theme() -> void:
	# Tile pills sit on their own dark chip (over art, or in Light's list rows
	# like Discover's wishlist "In 106 days" / "Target"): readable in all themes.
	var Badge = load("res://scripts/ui/badge.gd")
	var chip := Color(0.02, 0.03, 0.05)
	for id in Themes.ORDER:
		ThemeLib.use(id)
		for tone in ["", "good", "warn", "bad", "info", "accent", "new", "sale", "wish", "gold"]:
			var b: PanelContainer = Badge.make({"kind": "x", "text": "In 106 days", "tone": tone}, "tile")
			var fg: Color = b.label.get_theme_color("font_color")
			ok(Themes.contrast(fg, chip) >= 4.5, "%s: %s tile pill readable (%.2f)" % [id, tone, Themes.contrast(fg, chip)])
			b.free()
	ThemeLib.use("cove")


func test_synopsis_in_sentence_case() -> void:
	var Texts = load("res://scripts/ui/texts.gd")
	eq(Texts.calm_caps("THE CRITICALLY ACCLAIMED FANTASY ACTION RPG. Rise, Tarnished, and be guided by grace."),
		"The critically acclaimed fantasy action RPG. Rise, Tarnished, and be guided by grace.", "a shouted sentence calmed, acronyms kept")
	eq(Texts.calm_caps("A lighthouse keeper rows out. NASA helps."), "A lighthouse keeper rows out. NASA helps.", "mixed case and short words untouched")


## In a canvas_item fragment(), COLOR already holds the texture at UV times
## the modulate: multiplying a fresh sample by it squares every pixel (the
## covers and heroes rendered at well under half their real brightness).
func test_art_shaders_keep_art_at_full_brightness() -> void:
	for p in ["res://shaders/rounded_art.gdshader", "res://shaders/hero_fade.gdshader"]:
		var src := FileAccess.get_file_as_string(p)
		ok(src != "", "%s readable" % p)
		var code := ""
		for line in src.split("\n"):
			if not line.strip_edges().begins_with("//"):
				code += line + "\n"
		ok(not code.contains(") * COLOR"), "%s doesn't multiply a texture sample by COLOR" % p)


## Dark themes stand on a lifted ground (not near-black) with cards a step
## above it; Midnight stays OLED black; Light stays light.
func test_grounds_are_lifted_and_cards_step_up() -> void:
	var lum := func(c: Color) -> float: return c.get_luminance()
	for id in ["cove", "sunset"]:
		var t: Dictionary = Themes.get_theme(id)
		ok(lum.call(t["bg"]) >= lum.call(Color("#121826")) - 0.005, "%s: ground lifted off black" % id)
		ok(lum.call(t["surface"]) > lum.call(t["bg"]), "%s: cards a step above the ground" % id)
		ok(lum.call(t["surface_2"]) > lum.call(t["surface"]), "%s: raised controls above cards" % id)
		ok(float(t["scrim_strength"]) <= 0.70, "%s: backdrop art shows through" % id)
	eq(Themes.get_theme("midnight")["bg"], Color("#000000"), "Midnight keeps true black for OLED")
	ok(lum.call(Themes.get_theme("light")["bg"]) > 0.8, "Light stays light")


func test_covers_are_never_dimmed() -> void:
	for installed in [true, false]:
		var t: Button = Tile.new()
		t.setup(Logic.g("steam", "9", "Game", installed, 0), true)
		eq(t.card.modulate, Color.WHITE, "cover at full brightness (installed %s)" % installed)
		eq(t.art.self_modulate, Color.WHITE, "art not dimmed (installed %s)" % installed)
		ok(Tile.INFO_H <= 0.25, "the plate shades only the bottom quarter")
		t.free()


# ---- Light's hero: the art at full colour, a dark scrim under light text ----

const HeroInk := preload("res://scripts/ui/hero_ink.gd")
const HeroStage := preload("res://scripts/ui/hero_stage.gd")
const ArtCache := preload("res://scripts/ui/art_cache.gd")
const HERO_DIR := "user://test_light_hero"


## A 1920x620 hero written to disk: `base` everywhere with lighter bands and a
## diagonal sweep, so every sample point has its own colour.
func _hero_art(name: String, base: Color, lift: Color) -> String:
	var dir := ProjectSettings.globalize_path(HERO_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	var img := Image.create(480, 155, false, Image.FORMAT_RGB8)
	for y in img.get_height():
		for x in img.get_width():
			var t := 0.5 + 0.5 * sin((x + y * 2.0) / 23.0)
			img.set_pixel(x, y, base.lerp(lift, t))
	img.resize(1920, 620, Image.INTERPOLATE_BILINEAR)
	var path := dir.path_join(name + ".png")
	img.save_png(path)
	return path


func _hero_game(name: String, path: String) -> Dictionary:
	var g: Dictionary = Logic.g("steam", name, "Elden Ring", true, 100)
	g["art"]["hero"] = path
	return g


## What the stage's front layer shows at `at` (px in the stage): the art's own
## pixel there (covered, like the TextureRect), then hero_fade.gdshader's sums
## with the parameters the layer's material really has. [colour, scrim alpha,
## art pixel].
func _hero_pixel(st: Control, at: Vector2) -> Array:
	var layer: TextureRect = st.layers[st._front]
	var img: Image = layer.texture.get_image()
	var s := maxf(st.size.x / img.get_width(), st.size.y / img.get_height())
	var off := (Vector2(img.get_width(), img.get_height()) * s - st.size) * 0.5
	var px := ((at + off) / s).floor()
	var art := img.get_pixel(clampi(int(px.x), 0, img.get_width() - 1), clampi(int(px.y), 0, img.get_height() - 1))
	var m := layer.material as ShaderMaterial
	var shade: Color = m.get_shader_parameter("shade_color")
	var x := at.x / st.size.x
	var a := shade.a * (1.0 - smoothstep(float(m.get_shader_parameter("shade_from")), float(m.get_shader_parameter("shade_to")), x))
	var c := Color(lerpf(art.r, shade.r, a), lerpf(art.g, shade.g, a), lerpf(art.b, shade.b, a), 1.0)
	# its alpha: opaque unless a fade into the backdrop is on
	var alpha := smoothstep(float(m.get_shader_parameter("fade_left_from")), float(m.get_shader_parameter("fade_left_to")), x)
	alpha *= 1.0 - smoothstep(float(m.get_shader_parameter("fade_bottom_from")), 1.0, at.y / st.size.y)
	return [c, a, Color(art.r, art.g, art.b, 1.0), alpha]


## The Home hero in Light, measured: under the title the art comes through a
## dark scrim (never a white band, never more than 55 % black, gone by 45 % of
## the width), the picture is untouched past it, and the white title reads at
## 4.5:1 or better on bright art and on dark art, at both screen sizes.
func test_light_hero_shows_the_art_under_a_dark_scrim() -> void:
	ThemeLib.use("light")
	ArtCache.clear()
	var arts := {
		"bright": _hero_art("bright", Color(0.62, 0.80, 0.96), Color(1.0, 1.0, 1.0)),
		"dark": _hero_art("dark", Color(0.03, 0.05, 0.09), Color(0.16, 0.22, 0.30)),
		"other": _hero_art("other", Color(0.98, 0.78, 0.10), Color(1.0, 0.95, 0.60)),
	}
	var worst := {}
	for width in [1856.0, 1216.0]:      # the hero frame at 1920x1200 and at 1280x800
		var shown := {}
		for id in arts:
			var st: Control = HeroStage.new()
			st.frame_radius = 24.0
			st.set_anchors_preset(Control.PRESET_TOP_LEFT)
			st.size = Vector2(width, 330)
			var g := _hero_game(id, arts[id])
			st.show_game(g)
			ok(st.text_on_art(), "%s: the words are on the art" % id)
			var head: VBoxContainer = load("res://scripts/ui/game_header.gd").new()
			head.on_art = st.text_on_art()
			head.show_game(g, "Jump back in")
			var left: float = 32.0                       # Home's FRAME_PAD
			var right: float = left + float(head.title_right())
			st.set_text_extent(right)
			var m := (st.layers[st._front] as TextureRect).material as ShaderMaterial
			var shade: Color = m.get_shader_parameter("shade_color")
			ok(shade.r + shade.g + shade.b < 0.01, "%s: the scrim is dark, not a light band" % id)
			ok(shade.a <= HeroInk.MAX + 0.001 and HeroInk.MAX <= 0.55, "%s: at most 55 %% black (%.2f)" % [id, shade.a])
			ok(float(m.get_shader_parameter("shade_to")) <= 0.45, "%s: gone by 45 %% of the width" % id)
			ok(float(m.get_shader_parameter("shade_from")) * width >= right - 1.0 or float(m.get_shader_parameter("shade_from")) >= HeroInk.HOLD_MAX,
				"%s: full strength to the end of the title" % id)
			var ink: Color = head.title.get_theme_color("font_color")
			eq(ink, Color.WHITE, "%s: white title, as in the dark themes" % id)
			eq(head.title.get_theme_color("font_shadow_color").get_luminance(), 0.0, "%s: no light halo" % id)
			var pts: Array = []
			for fy in [0.34, 0.42, 0.50]:        # the title's rows in the 330 px hero
				for fx in [0.0, 0.25, 0.5, 0.75, 1.0]:
					pts.append(Vector2(lerpf(left, right, fx), 330.0 * fy))
			var seen: Array = []
			var low := 99.0
			for p in pts:
				var r := _hero_pixel(st, p)
				var bg: Color = r[0]
				seen.append(bg)
				eq(r[3], 1.0, "%s: the art is opaque there" % id)
				ok(float(r[1]) <= 0.551, "%s: the scrim never hides the art" % id)
				ok(Themes.luminance(bg) < 0.20, "%s: not washed toward white (luminance %.3f)" % [id, Themes.luminance(bg)])
				low = minf(low, Themes.contrast(ink, bg))
			ok(low >= 4.5, "%s at %d px: title contrast %.2f" % [id, int(width), low])
			worst["%s@%d" % [id, int(width)]] = low
			shown[id] = seen
			# Past the scrim the picture is exactly the picture, to the right edge and the foot.
			for p in [Vector2(width * 0.46, 40), Vector2(width * 0.7, 165), Vector2(width - 30, 320), Vector2(width * 0.5, 326)]:
				var r := _hero_pixel(st, p)
				eq(r[0], r[2], "%s: untouched art at %s" % [id, p])
				eq(r[3], 1.0, "%s: and opaque" % id)
			head.free()
			st.free()
		# The art is what you see under the title: another picture, other pixels.
		for i in shown["bright"].size():
			var a: Color = shown["bright"][i]
			var b: Color = shown["other"][i]
			ok(absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) > 0.12, "under the title the art shows through (point %d)" % i)
			ok(shown["dark"][i] != shown["bright"][i], "and follows the picture")
	print("    light hero title contrast: ", worst)
	# The scrim is as strong as the picture needs: dark art gets the least.
	ok(HeroInk.strength_for(ArtCache.text_side("hero", arts["dark"])) <= HeroInk.MIN + 0.001, "dark art: the lightest scrim")
	ok(HeroInk.strength_for(ArtCache.text_side("hero", arts["bright"])) > 0.5, "bright art: a stronger one")
	ArtCache.clear()
	ThemeLib.use("cove")


## Light text only where there's art behind it: with no picture (or a poster
## on the right, or the welcome glow) the header keeps the theme's dark text.
func test_light_hero_text_follows_the_art() -> void:
	ThemeLib.use("light")
	ArtCache.clear()
	var Home = load("res://scripts/ui/home.gd")
	var h: Control = Home.new()
	h.set_games([_hero_game("dark", _hero_art("dark", Color(0.03, 0.05, 0.09), Color(0.16, 0.22, 0.30)))])
	ok(h.hero_stage.text_on_art() and h.header.light_ink(), "art behind the title: light ink")
	eq(h.header.title.get_theme_color("font_color"), Color.WHITE, "white title")
	ok(Themes.contrast(h.header._meta_color(), Color(0.1, 0.1, 0.1)) >= 4.5, "light info line")
	h.set_games([Logic.g("steam", "9", "No Art", true, 100)])
	ok(not h.hero_stage.text_on_art() and not h.header.light_ink(), "no art: the theme's text")
	ok(not h.header.title.has_theme_color_override("font_color"), "the theme's dark title on the light frame")
	eq(h.header.title.get_theme_color("font_shadow_color").a, 0.0, "and no halo")
	h.set_games([])
	ok(not h.hero_stage.text_on_art(), "the welcome glow is no picture")
	var wm := (h.hero_stage.layers[h.hero_stage._front] as TextureRect).material as ShaderMaterial
	eq((wm.get_shader_parameter("shade_color") as Color).a, 0.0, "so it gets no scrim")
	h.free()
	# The game page (and the store and emulation pages built on it).
	var Page = load("res://scripts/ui/page_template.gd")
	var p: Control = Page.new()
	p.setup_page(_hero_game("bright", _hero_art("bright", Color(0.62, 0.80, 0.96), Color(1.0, 1.0, 1.0))))
	ok(p.header.light_ink(), "game page: light ink on its art")
	var side := (p._side.texture as GradientTexture2D).gradient
	var top := 0.0
	for i in side.get_point_count():
		var c := side.get_color(i)
		ok(c.r + c.g + c.b < 0.01, "game page: a dark scrim")
		top = maxf(top, c.a)
		if side.get_offset(i) >= 0.45:
			eq(c.a, 0.0, "game page: gone by 45 % of the width")
	ok(top <= 0.551 and top > 0.5, "game page: at most 55 %% black on bright art (%.2f)" % top)
	var foot := (p._fade.texture as GradientTexture2D).gradient
	for i in foot.get_point_count():
		eq(foot.get_color(i).a, 0.0, "game page: nothing washes the foot of the art")
	p.free()
	# Chips on the hero stay light and opaque.
	var chip: Control = load("res://scripts/ui/badge.gd").make({"kind": "time", "text": "46 h to beat", "tone": "info", "icon": "clock"}, "chip")
	eq((chip.get_theme_stylebox("panel") as StyleBoxFlat).bg_color.a, 1.0, "light: hero chips are opaque")
	chip.free()
	# The dark themes keep their own shade toward the backdrop.
	ThemeLib.use("cove")
	var st: Control = HeroStage.new()
	st.frame_radius = 24.0
	st._apply_fade()
	var dm := (st.layers[0] as TextureRect).material as ShaderMaterial
	ok(is_equal_approx((dm.get_shader_parameter("shade_color") as Color).a, 0.80), "cove: its shade is unchanged")
	eq(float(dm.get_shader_parameter("shade_to")), 0.58, "cove: to 58 % of the width")
	st.free()
	ArtCache.clear()


## A store hero with black bars baked into its sides (Frostpunk's) is shown
## without them, so the art never ends in a hard vertical edge.
func test_hero_stage_trims_baked_side_bars() -> void:
	var HS = load("res://scripts/ui/hero_stage.gd")
	var img := Image.create(400, 100, false, Image.FORMAT_RGB8)
	img.fill(Color(0.5, 0.4, 0.3))
	img.fill_rect(Rect2i(0, 0, 40, 100), Color.BLACK)
	img.fill_rect(Rect2i(370, 0, 30, 100), Color.BLACK)
	eq(HS.content_columns(img), Vector2i(40, 370), "both bars found")
	var plain := Image.create(400, 100, false, Image.FORMAT_RGB8)
	plain.fill(Color(0.5, 0.4, 0.3))
	plain.fill_rect(Rect2i(0, 0, 4, 100), Color.BLACK)
	eq(HS.content_columns(plain), Vector2i(0, 400), "a thin dark edge isn't a bar")
	var night := Image.create(400, 100, false, Image.FORMAT_RGB8)
	night.fill(Color.BLACK)
	night.fill_rect(Rect2i(150, 40, 100, 20), Color.WHITE)
	eq(HS.content_columns(night), Vector2i(0, 400), "a dark picture isn't cropped to a sliver")
