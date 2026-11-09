extends Button
## A library tile: the game's cover (or a generated cover), badges, and the
## focus treatment: the card lifts to 1.06, a ring in the theme accent (the
## same focus colour everywhere) with a glow tinted by the cover's colour
## pulses in, and the art pans a few pixels against the direction focus
## came from. Art loads only while the tile is near the screen.

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

const SIZE := Vector2(150, 204)
const LIFT := 1.05
## Height of the gradient at the bottom where the title and sub-line sit.
const INFO_H := 0.52

var game: Dictionary = {}
var tile_size := SIZE
var card: Control
var art: TextureRect
var glow: Panel
var shadow: Panel
var fallback: Control
var badges_box: VBoxContainer
var corner_badge: Control
## Bottom block over the gradient: extra pills (Discover), title, sub-line.
var info_box: VBoxContainer
var title_label: Label
var sub_label: Label
## "SELECTED" pill shown while focused.
var selected_pill: PanelContainer
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
	fallback.setup(g, 19 if tile.x < 170 else 24, r)
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

	info_box = Kit.vbox(2)
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
	title_label.add_theme_font_size_override("font_size", 15 if tile.x < 170 else 18)
	title_label.add_theme_color_override("font_color", Color("#F8FAFC"))
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_box.add_child(title_label)
	sub_label = Label.new()
	sub_label.name = "Sub"
	sub_label.text = sub_text(g)
	sub_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	sub_label.clip_text = true
	sub_label.add_theme_font_override("font", ThemeLib.mono(false, 0))
	sub_label.add_theme_font_size_override("font_size", 11)
	sub_label.add_theme_color_override("font_color", Color(0.80, 0.84, 0.90, 0.85))
	sub_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sub_label.visible = sub_label.text != ""
	info_box.add_child(sub_label)
	# The art-less cover already carries the title.
	title_label.visible = cover_path() != ""

	badges_box = Kit.vbox(4)
	badges_box.name = "Badges"
	badges_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badges_box.offset_left = 8
	badges_box.offset_top = 32
	badges_box.offset_bottom = 32
	card.add_child(badges_box)
	# Unfocused: one corner pill at most. Focused: up to two more under SELECTED.
	badges_box.modulate.a = 0.0
	if with_badges:
		var tb := Badges.for_tile(g)
		for b in tb["strip"]:
			badges_box.add_child(Badge.make(b, "tile"))
		if not tb["corner"].is_empty():
			var solid: bool = tb["corner"]["kind"] in ["sale", "new", "update", "download"]
			corner_badge = Badge.make(tb["corner"], "solid" if solid else "tile")
			corner_badge.anchor_left = 1.0
			corner_badge.anchor_right = 1.0
			corner_badge.grow_horizontal = Control.GROW_DIRECTION_BEGIN
			corner_badge.offset_right = -8
			corner_badge.offset_left = -8
			corner_badge.offset_top = 8
			card.add_child(corner_badge)
	selected_pill = PanelContainer.new()
	selected_pill.name = "Selected"
	selected_pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	selected_pill.position = Vector2(8, 8)
	var sl := Kit.micro("● Selected", "MicroLabel")
	sl.name = "Text"
	sl.add_theme_font_override("font", ThemeLib.mono(true, 1))
	sl.add_theme_font_size_override("font_size", 10)
	selected_pill.add_child(sl)
	selected_pill.modulate.a = 0.0
	card.add_child(selected_pill)
	_style_card()
	card.modulate = Color(0.82, 0.82, 0.82) if ThemeLib.is_dark() else Color(0.94, 0.94, 0.94)
	if not g.get("installed", false):
		art.self_modulate = Color(0.72, 0.72, 0.72)
		fallback.modulate = Color(0.76, 0.76, 0.76)

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
	var g := Gradient.new()
	var ink := Color("#040508")
	g.offsets = PackedFloat32Array([0.0, 1.0 - INFO_H, 0.80, 1.0])
	g.colors = PackedColorArray([Color(ink, 0.0), Color(ink, 0.0), Color(ink, 0.78), Color(ink, 0.94)])
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.width = 4
	gt.height = 128
	gt.fill_to = Vector2(0, 1)
	_shade.texture = gt
	var acc := ThemeLib.color("accent")
	selected_pill.add_theme_stylebox_override("panel", ThemeLib.box(acc, 999, 8, 2))
	selected_pill.get_node("Text").add_theme_color_override("font_color", ThemeLib.color("on_accent"))


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
	title_label.visible = true
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
	# The focused tile shows SELECTED and its corner pill; the strip's facts
	# (Platinum, time to beat) sit in the hero / details bar instead.
	Motion.to(selected_pill, "modulate:a", 1.0, Motion.FAST)
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
	Motion.to(card, "modulate", Color(0.82, 0.82, 0.82) if ThemeLib.is_dark() else Color(0.94, 0.94, 0.94), Motion.FAST)
	Motion.to(glow, "modulate:a", 0.0, Motion.FAST)
	Motion.to(badges_box, "modulate:a", 0.0, Motion.FAST)
	Motion.to(selected_pill, "modulate:a", 0.0, Motion.FAST)
	Motion.method(self, "pan", func(t: float): _set_pan(Vector2.ZERO, 1.0 + 0.045 * t), 1.0, 0.0, Motion.FAST)


func _set_glow(v: float) -> void:
	_glow_box.shadow_size = int(v)
	glow.queue_redraw()


func _set_pan(p: Vector2, z: float) -> void:
	_mat.set_shader_parameter("pan", p)
	_mat.set_shader_parameter("zoom", z)


## Tile badges as [{"text", "tone", ...}]: the focus strip, then the corner pill.
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
