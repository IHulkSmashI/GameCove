extends Button
## A library tile: the game's cover (or a generated cover) and the focus
## treatment: the card lifts, a ring in the theme accent (the same focus
## colour everywhere) with a glow tinted by the cover's colour pulses in, and
## the art pans a few pixels against the direction focus came from. Art loads
## only while the tile is near the screen.
##
## The top three quarters of a cover stay clean (covers carry their own logo
## there). Everything we add sits in one plate along the bottom:
##   title      only where the art doesn't carry one (generated covers); a
##              cover with art never repeats its painted logo, focused or not
##   pill row   one status pill (sale, update, downloading, Linux denied...)
##              and, on Discover, the price
##   sub row    store and playtime (or "Not installed"), plus one quiet extra

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Texts := preload("res://scripts/ui/texts.gd")
const View := preload("res://scripts/ui/library_view.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const ArtColor := preload("res://theme/art_color.gd")
const ArtCache := preload("res://scripts/ui/art_cache.gd")
const Badges := preload("res://scripts/ui/badges.gd")
const Badge := preload("res://scripts/ui/badge.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const FallbackArt := preload("res://scripts/ui/fallback_art.gd")
const UiPrefs := preload("res://scripts/ui/ui_prefs.gd")
const ArtShader := preload("res://shaders/rounded_art.gdshader")
const Themes := preload("res://theme/themes.gd")

const SIZE := Vector2(150, 204)
const LIFT := 1.05
## Height of the gradient at the bottom where the plate sits: only the
## bottom 25 %, starting transparent, so the art above is untouched.
const INFO_H := 0.25
## Covers are never dimmed, focused or not, installed or not: focus is the
## ring and the lift, and "Not installed" is said in the plate.
const REST := Color.WHITE
## Portrait shelves and grids show at most this many covers across (a little
## of the next one peeks in, faded, so the row reads as scrollable).
const PER_ROW := 7.3
## Readability floor (px at the 1280x800 layout; 1920x1200 draws them 1.25x):
## sub-lines 12 (15 on the big panel), titles 14-15 (17.5-19).
const SUB_PX := 12
const TITLE_PX := 14

var game: Dictionary = {}
var tile_size := SIZE
var card: Control
var art: TextureRect
var glow: Panel
var shadow: Panel
var fallback: Control
## Kept for callers; tiles no longer show a focus strip.
var badges_box: VBoxContainer
## The status pill in the plate (sale, update, downloading, Linux denied).
var corner_badge: Control
## The plate over the bottom gradient: title, pill row, sub row.
var info_box: VBoxContainer
var title_label: Label
var pill_row: HBoxContainer
## Discover's price, next to the status pill.
var price_label: Label
var price_icon: TextureRect
var sub_row: HBoxContainer
var sub_label: Label
## One quiet extra after the sub-line, in its tone ("Lowest ever").
var sub_extra: Label
## Gone: the ring, lift and details bar already say which tile is selected.
var selected_pill: PanelContainer = null
var show_label := true
var _glow_box: StyleBoxFlat
var _mat: ShaderMaterial
var _with_badges := true
var _accent := Color(0, 0, 0, 0)
var _base: Panel
var _edge: Panel
var _shade: TextureRect

## Centre of the last focused tile, for the parallax direction.
static var _last_focus := Vector2.ZERO


func setup(g: Dictionary, with_badges := true, tile := SIZE, label_under := true) -> void:
	game = g
	show_label = label_under
	tile_size = tile
	_with_badges = with_badges
	name = "Tile_" + String(g.get("key", "")).validate_node_name()
	theme_type_variation = "TileButton"
	focus_mode = Control.FOCUS_ALL
	custom_minimum_size = tile
	tooltip_text = g.get("title", "")
	var r := float(ThemeLib.radius("m"))

	card = Control.new()
	card.name = "Card"
	Kit.fill(card)
	card.pivot_offset = tile / 2.0
	add_child(card)

	shadow = Panel.new()
	shadow.name = "Shadow"
	Kit.fill(shadow)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.0)
	sb.set_corner_radius_all(int(r))
	sb.shadow_color = Color(0, 0, 0, 0.45 if ThemeLib.is_dark() else 0.18)
	sb.shadow_size = 12
	sb.shadow_offset = Vector2(0, 6)
	shadow.add_theme_stylebox_override("panel", sb)
	card.add_child(shadow)

	# Focus: a thick ring a few px outside the card and a glow in its colour.
	glow = Panel.new()
	glow.name = "Glow"
	Kit.fill(glow)
	_glow_box = StyleBoxFlat.new()
	_glow_box.draw_center = false
	_glow_box.set_border_width_all(3)
	_glow_box.set_corner_radius_all(int(r) + 4)
	_glow_box.set_expand_margin_all(4)
	_glow_box.shadow_size = 18
	_glow_box.anti_aliasing = true
	_glow_box.corner_detail = 12
	glow.add_theme_stylebox_override("panel", _glow_box)
	glow.modulate.a = 0.0
	card.add_child(glow)

	_base = Panel.new()
	_base.name = "Base"
	Kit.fill(_base)
	card.add_child(_base)

	fallback = FallbackArt.new()
	# No title in the art: the plate carries it, like every other cover.
	fallback.setup(g, 19 if tile.x < 170 else 24, r, false)
	fallback.monogram = true
	Kit.fill(fallback)
	card.add_child(fallback)

	art = TextureRect.new()
	art.name = "Cover"
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_SCALE
	art.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	Kit.fill(art)
	_mat = ShaderMaterial.new()
	_mat.shader = ArtShader
	_mat.set_shader_parameter("size", tile)
	_mat.set_shader_parameter("radius", r)
	art.material = _mat
	art.visible = false
	card.add_child(art)

	# The bottom of the card darkens so the title reads on any art.
	_shade = TextureRect.new()
	_shade.name = "Shade"
	_shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_shade.stretch_mode = TextureRect.STRETCH_SCALE
	Kit.fill(_shade)
	var sm := ShaderMaterial.new()
	sm.shader = ArtShader
	sm.set_shader_parameter("size", tile)
	sm.set_shader_parameter("radius", r)
	_shade.material = sm
	card.add_child(_shade)

	_edge = Panel.new()
	_edge.name = "Edge"
	Kit.fill(_edge)
	card.add_child(_edge)

	info_box = Kit.vbox(3)
	info_box.name = "Info"
	info_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_box.anchor_top = 1.0
	info_box.anchor_bottom = 1.0
	info_box.anchor_right = 1.0
	info_box.offset_left = 10
	info_box.offset_right = -10
	info_box.offset_top = -10
	info_box.offset_bottom = -10
	info_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	card.add_child(info_box)
	title_label = Label.new()
	title_label.name = "TitleUnder"
	title_label.text = g.get("title", "")
	title_label.uppercase = true
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_label.clip_text = true
	title_label.add_theme_font_override("font", ThemeLib.font("heading_bold", false, 0))
	title_label.add_theme_font_size_override("font_size", TITLE_PX if tile.x < 170 else TITLE_PX + 1)
	title_label.add_theme_color_override("font_color", Color("#F8FAFC"))
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_box.add_child(title_label)
	pill_row = Kit.hbox(6)
	pill_row.name = "Pills"
	pill_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pill_row.visible = false
	info_box.add_child(pill_row)
	price_label = Label.new()
	price_label.name = "Price"
	price_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	price_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	price_label.clip_text = true
	price_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	price_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	price_label.add_theme_font_override("font", ThemeLib.font("bold", true))
	price_label.add_theme_font_size_override("font_size", ThemeLib.SIZE_CAPTION)
	price_label.add_theme_color_override("font_color", Color.WHITE)
	price_label.visible = false
	pill_row.add_child(price_label)
	sub_row = Kit.hbox(0)
	sub_row.name = "SubRow"
	sub_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_box.add_child(sub_row)
	sub_label = Label.new()
	sub_label.name = "Sub"
	sub_label.text = sub_text(g)
	sub_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	sub_label.clip_text = true
	sub_label.add_theme_font_override("font", ThemeLib.mono(false, 0))
	sub_label.add_theme_font_size_override("font_size", SUB_PX)
	sub_label.add_theme_color_override("font_color", Color(0.80, 0.84, 0.90, 0.92))
	sub_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sub_label.visible = sub_label.text != ""
	sub_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sub_row.add_child(sub_label)
	sub_extra = Label.new()
	sub_extra.name = "SubExtra"
	sub_extra.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	sub_extra.clip_text = true
	sub_extra.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sub_extra.add_theme_font_override("font", ThemeLib.mono(true, 0))
	sub_extra.add_theme_font_size_override("font_size", SUB_PX)
	sub_extra.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sub_extra.visible = false
	sub_row.add_child(sub_extra)
	_update_title()

	badges_box = Kit.vbox(4)
	badges_box.name = "Badges"
	badges_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badges_box.visible = false
	card.add_child(badges_box)
	if with_badges:
		var pill := Badges.for_plate(g)
		if not pill.is_empty():
			set_status_pill(pill)
	_style_card()
	card.modulate = REST

	# Load the cover only while near the screen (with a tile of slack either side).
	var vis := VisibleOnScreenNotifier2D.new()
	vis.name = "Visibility"
	vis.rect = Rect2(-tile.x, -tile.y * 0.5, tile.x * 3.0, tile.y * 2.0)
	vis.screen_entered.connect(ensure_art)
	add_child(vis)

	focus_entered.connect(_on_focus)
	focus_exited.connect(_on_blur)
	_refresh_glow_color()
	# Already loaded elsewhere (shelf + grid share covers): show it now.
	var cached := ArtCache.cached("cover", cover_path())
	if cached != null:
		_show_art(cached, false)


## Tile size for a row `avail_w` px wide: PER_ROW covers across, never
## smaller than SIZE (the 1280x800 layout), 2:3-ish like SIZE.
static func size_for(avail_w: float, gap := 16.0) -> Vector2:
	var w := floorf((avail_w + gap) / PER_ROW - gap)
	w = maxf(SIZE.x, w)
	return Vector2(w, roundf(w * SIZE.y / SIZE.x))


## Width a full-width row of covers gets on this screen (layout px), from the
## window's visible rect; 1280x800 when there's no window yet (tests).
static func row_width() -> float:
	var ml := Engine.get_main_loop()
	var w := 1280.0
	if ml is SceneTree and (ml as SceneTree).root != null:
		w = maxf(w, (ml as SceneTree).root.get_visible_rect().size.x)
	return w - 2.0 * ThemeLib.EDGE


## The plate's title: generated covers only (the art has none). A cover with
## art carries its own logo, so focusing it never adds a second title or
## shifts its store line (the spotlight, details bar or page names it).
func _update_title() -> void:
	if title_label == null:
		return
	title_label.visible = not has_cover()


## The status pill in the plate ({} clears it). Spec as Badges gives it.
func set_status_pill(spec: Dictionary) -> void:
	if corner_badge != null and is_instance_valid(corner_badge):
		if not spec.is_empty() and corner_badge.get("spec") is Dictionary \
				and corner_badge.spec.get("short", "") == spec.get("short", "") and corner_badge.spec.get("tone", "") == spec.get("tone", ""):
			return
		Kit.drop(corner_badge.get_parent(), corner_badge)
		corner_badge = null
	if not spec.is_empty():
		var solid: bool = spec.get("kind", "") in ["sale", "new", "update", "download"] or spec.get("tone", "") in ["info", "bad"]
		corner_badge = Badge.make(spec, "solid" if solid else "tile")
		corner_badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		pill_row.add_child(corner_badge)
		pill_row.move_child(corner_badge, 0)
	_update_pills()


## Discover's price next to the pill. Every deal tile has the same two-line
## plate: line 1 the discount pill and the price (or "See price" when there's
## no real local price: `quiet`), line 2 the store, on one line that never
## wraps, after the store's monochrome logo (`icon`, drawn at the line's
## height like any other icon). `store_line` replaces the store name there
## ("Best price · GG.deals").
func set_price(text: String, quiet := false, icon: Texture2D = null, store_line := "") -> void:
	if price_icon == null:
		price_icon = TextureRect.new()
		price_icon.name = "PriceIcon"
		price_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		price_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		price_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		price_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		sub_row.add_child(price_icon)
		sub_row.move_child(price_icon, 0)
	price_icon.texture = icon
	price_icon.visible = icon != null and text != ""
	if icon != null and icon.get_height() > 0:
		var h := float(SUB_PX)
		price_icon.custom_minimum_size = Vector2(clampf(h * icon.get_width() / icon.get_height(), h, h * 4.0), h)
	sub_row.add_theme_constant_override("separation", 6 if price_icon.visible else 0)
	price_label.text = text
	price_label.add_theme_font_override("font", ThemeLib.font("bold", true))
	price_label.add_theme_font_size_override("font_size", ThemeLib.SIZE_CAPTION)
	price_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.92) if quiet else Color.WHITE)
	price_label.visible = text != ""
	if store_line != "":
		sub_label.text = store_line
	# One line, never two: a long store name trims instead of wrapping.
	sub_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	sub_label.max_lines_visible = -1
	sub_label.clip_text = true
	sub_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	sub_label.visible = sub_label.text != ""
	_update_pills()


## One quiet extra after the store line ({"text", "tone"}; {} clears it): on
## the same line when both fit the plate, else on a line of its own.
func set_extra(spec: Dictionary) -> void:
	var t := str(spec.get("text", ""))
	var tone := str(spec.get("tone", ""))
	sub_extra.add_theme_color_override("font_color", Themes.TONES.get(tone, Color(0.80, 0.84, 0.90)) if tone != "" else Color(0.80, 0.84, 0.90, 0.92))
	sub_extra.visible = t != ""
	var f: Font = sub_label.get_theme_font("font")
	var room := tile_size.x - 20.0
	if price_icon != null and price_icon.visible:
		room -= price_icon.custom_minimum_size.x + 6.0
	var joined := sub_label.text + " · " + t
	var fits := sub_label.visible and sub_label.autowrap_mode == TextServer.AUTOWRAP_OFF \
		and f.get_string_size(joined, HORIZONTAL_ALIGNMENT_LEFT, -1, SUB_PX).x <= room
	if sub_extra.get_parent() != (sub_row if fits else info_box):
		sub_extra.get_parent().remove_child(sub_extra)
		(sub_row if fits else info_box).add_child(sub_extra)
	sub_extra.text = (" · " + t) if fits else t
	# On one line the store keeps its natural width; alone, each trims.
	sub_label.clip_text = not (fits and sub_extra.visible)
	sub_label.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING if fits and sub_extra.visible else TextServer.OVERRUN_TRIM_ELLIPSIS
	sub_label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN if fits and sub_extra.visible else Control.SIZE_EXPAND_FILL


## With a price (Discover) the pill leads the price line; without one
## (Library: Update, Installing...) it sits at the right end of the store
## line, so it never covers the logo most covers carry in their lower third.
func _update_pills() -> void:
	var has_pill := corner_badge != null and is_instance_valid(corner_badge)
	if has_pill:
		var want: Control = pill_row if price_label.visible else sub_row
		if corner_badge.get_parent() != want:
			corner_badge.get_parent().remove_child(corner_badge)
			want.add_child(corner_badge)
		if want == pill_row:
			pill_row.move_child(corner_badge, 0)
		else:
			sub_row.move_child(corner_badge, sub_row.get_child_count() - 1)
			sub_row.add_theme_constant_override("separation", 6)
	pill_row.visible = (has_pill and corner_badge.get_parent() == pill_row) or price_label.visible
	_style_scrim()


## The mono line under the title: store and playtime, or "Not installed".
static func sub_text(g: Dictionary) -> String:
	var parts: Array[String] = [View.store_name(String(g.get("store", "")))]
	if not g.get("installed", false):
		parts.append("Not installed")
	else:
		var pt := Texts.playtime_text(int(g.get("playtime_min", 0))).replace(" played", "")
		if pt != "":
			parts.append(pt)
	return " · ".join(parts.filter(func(p): return p != ""))


func _style_card() -> void:
	var r := ThemeLib.radius("m")
	var base := ThemeLib.box(ThemeLib.color("surface"), r, 0, 0)
	_base.add_theme_stylebox_override("panel", base)
	var edge := StyleBoxFlat.new()
	edge.draw_center = false
	edge.border_color = Color(1, 1, 1, 0.12) if ThemeLib.is_dark() else Color(0, 0, 0, 0.12)
	edge.set_border_width_all(1)
	edge.set_corner_radius_all(r)
	edge.anti_aliasing = true
	_edge.add_theme_stylebox_override("panel", edge)
	_scrim_tall = -1
	_style_scrim()


var _scrim_tall := -1


## The dark foot behind the plate's text: strong enough that white text and
## the store line read on a white or bright cover (Shadow Tactics, Stardew
## Valley), over only the plate's lines so the rest of the cover stays
## undimmed. A price plate (Discover: pill + price, store, reviews) gets a
## taller one.
func _style_scrim() -> void:
	if _shade == null:
		return
	var tall := 1 if price_label != null and price_label.visible else 0
	if tall == _scrim_tall:
		return
	_scrim_tall = tall
	var g := Gradient.new()
	var ink := Color("#06080E")
	g.offsets = scrim_offsets(tall == 1)
	g.colors = PackedColorArray([Color(ink, 0.0), Color(ink, 0.0), Color(ink, 0.86), Color(ink, 0.95)])
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.width = 4
	gt.height = 256
	gt.fill_to = Vector2(0, 1)
	_shade.texture = gt


## Gradient stops (top to bottom, 0..1 of the tile) of the plate's scrim.
static func scrim_offsets(tall: bool) -> PackedFloat32Array:
	return PackedFloat32Array([0.0, 0.52, 0.74, 1.0]) if tall else PackedFloat32Array([0.0, 1.0 - INFO_H - 0.06, 0.86, 1.0])


func cover_path() -> String:
	var a: Variant = game.get("art", {})
	return a.get("cover", "") if a is Dictionary else ""


func has_cover() -> bool:
	return art.visible and art.texture != null


## Start loading the cover (no-op without one, or when it's showing).
func ensure_art() -> void:
	if has_cover():
		return
	var p := cover_path()
	if not ArtCache.usable(p):
		return
	var tex := ArtCache.request("cover", p, func(t): _show_art(t, true), self)
	if tex != null:
		_show_art(tex, false)
	# The glow colour comes from the art; the blur pass picks it.
	if UiPrefs.match_art and not ArtCache.has_accent(p):
		ArtCache.request("blur", p, func(_t): _refresh_glow_color(), self)


func _show_art(tex: Texture2D, animate: bool) -> void:
	if not is_instance_valid(art):
		return
	art.texture = tex
	art.visible = true
	fallback.visible = false
	_update_title()
	# Cover-crop to the card's shape, keeping a little more of the top.
	var ta := float(tex.get_width()) / maxf(1.0, tex.get_height())
	var ca := tile_size.x / tile_size.y
	var crop := Vector2(minf(1.0, ca / ta), minf(1.0, ta / ca))
	_mat.set_shader_parameter("crop", crop)
	_mat.set_shader_parameter("crop_at", Vector2(0.5, 0.5 - (1.0 - crop.y) * 0.2))
	if animate:
		art.modulate.a = 0.0
		Motion.to(art, "modulate:a", 1.0, Motion.BASE)
	_refresh_glow_color()


## The colour this tile's glow is tinted with: its art's colour when "match
## art" is on. The ring itself is always the theme accent.
func accent() -> Color:
	if UiPrefs.match_art:
		var p := cover_path()
		var picked := ArtCache.accent(p) if p != "" else Color(0, 0, 0, 0)
		if picked.a <= 0.0 and p == "":
			picked = ArtColor.fallback_colors(game.get("key", ""))[1]
		if picked.a > 0.0:
			return ArtColor.accent_for(picked, ThemeLib.tokens)
	return ThemeLib.color("accent")


func _refresh_glow_color() -> void:
	_accent = accent()
	var ring: Color = ThemeLib.color("accent")
	_glow_box.border_color = ring
	# The art colour only tints the shadow, mixed with the ring so the glow
	# still reads as focus.
	_glow_box.shadow_color = Color(ring.lerp(_accent, 0.6), 0.45)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _glow_box != null:
		_refresh_glow_color()
		_style_card()
	elif what == NOTIFICATION_RESIZED and card != null:
		card.pivot_offset = size / 2.0


func _on_focus() -> void:
	ensure_art()
	_refresh_glow_color()
	card.pivot_offset = size / 2.0
	Motion.to(card, "scale", Vector2(LIFT, LIFT), Motion.BASE, Tween.TRANS_BACK)
	Motion.to(card, "modulate", Color.WHITE, Motion.FAST)
	Motion.to(glow, "modulate:a", 1.0, Motion.FAST)
	_update_title()
	# Glow pulse: starts wide and settles.
	Motion.method(self, "glow", func(v: float): _set_glow(v), 30.0, 18.0, 0.45)
	# Parallax: the art drifts in from the side focus came from.
	var here := global_position + size / 2.0
	var from := (here - _last_focus)
	var dir := from.normalized() if from.length() > 1.0 and _last_focus != Vector2.ZERO else Vector2.ZERO
	_last_focus = here
	if Motion.reduce:
		_set_pan(Vector2.ZERO, 1.0)
	else:
		Motion.method(self, "pan", func(t: float): _set_pan(-dir * 0.035 * (1.0 - t), 1.0 + 0.045 * t), 0.0, 1.0, Motion.SLOW)


func _on_blur() -> void:
	Motion.to(card, "scale", Vector2.ONE, Motion.FAST)
	Motion.to(card, "modulate", REST, Motion.FAST)
	Motion.to(glow, "modulate:a", 0.0, Motion.FAST)
	_update_title()
	Motion.method(self, "pan", func(t: float): _set_pan(Vector2.ZERO, 1.0 + 0.045 * t), 1.0, 0.0, Motion.FAST)


func _set_glow(v: float) -> void:
	_glow_box.shadow_size = int(v)
	glow.queue_redraw()


func _set_pan(p: Vector2, z: float) -> void:
	_mat.set_shader_parameter("pan", p)
	_mat.set_shader_parameter("zoom", z)


## Tile badges as [{"text", "tone", ...}]: the strip, then the corner pill (older callers).
static func badge_specs(g: Dictionary) -> Array:
	var tb := Badges.for_tile(g)
	var out: Array = tb["strip"].duplicate()
	if not tb["corner"].is_empty():
		out.append(tb["corner"])
	return out


## Art-less card (older call): the generated cover.
static func title_card(g: Dictionary, font_size: int) -> Control:
	var c: Control = FallbackArt.new()
	c.setup(g, font_size, float(ThemeLib.radius("m")))
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	return c
