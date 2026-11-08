extends Button
## A library tile: the game's cover (or a generated cover), badges, and the
## focus treatment: the card lifts to 1.06, a ring and glow in the cover's own
## colour pulse in, and the art pans a few pixels against the direction focus
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

const SIZE := Vector2(150, 225)
const LIFT := 1.06

var game: Dictionary = {}
var tile_size := SIZE
var card: Control
var art: TextureRect
var glow: Panel
var shadow: Panel
var fallback: Control
var badges_box: VBoxContainer
var corner_badge: Control
var _glow_box: StyleBoxFlat
var _mat: ShaderMaterial
var _with_badges := true
var _accent := Color(0, 0, 0, 0)

## Centre of the last focused tile, for the parallax direction.
static var _last_focus := Vector2.ZERO


func setup(g: Dictionary, with_badges := true, tile := SIZE) -> void:
	game = g
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

	glow = Panel.new()
	glow.name = "Glow"
	Kit.fill(glow)
	_glow_box = StyleBoxFlat.new()
	_glow_box.set_corner_radius_all(int(r) + 4)
	_glow_box.set_expand_margin_all(4)
	_glow_box.shadow_size = 18
	_glow_box.anti_aliasing = true
	glow.add_theme_stylebox_override("panel", _glow_box)
	glow.modulate.a = 0.0
	card.add_child(glow)

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

	badges_box = Kit.vbox(4)
	badges_box.name = "Badges"
	badges_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badges_box.anchor_top = 1.0
	badges_box.anchor_bottom = 1.0
	badges_box.offset_left = 8
	badges_box.offset_top = -8
	badges_box.offset_bottom = -8
	badges_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	card.add_child(badges_box)
	if with_badges:
		var tb := Badges.for_tile(g)
		for b in tb["strip"]:
			badges_box.add_child(Badge.make(b, "tile"))
		if not tb["corner"].is_empty():
			corner_badge = Badge.make(tb["corner"], "solid")
			corner_badge.position = Vector2(8, 8)
			card.add_child(corner_badge)
	if not g.get("installed", false):
		art.self_modulate = Color(0.78, 0.78, 0.78)
		fallback.modulate = Color(0.8, 0.8, 0.8)

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
	if animate:
		art.modulate.a = 0.0
		Motion.to(art, "modulate:a", 1.0, Motion.BASE)
	_refresh_glow_color()


## The colour this tile glows in: its art's colour when "match art" is on.
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
	_glow_box.bg_color = _accent
	_glow_box.shadow_color = Color(_accent, 0.55)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _glow_box != null:
		_refresh_glow_color()
	elif what == NOTIFICATION_RESIZED and card != null:
		card.pivot_offset = size / 2.0


func _on_focus() -> void:
	ensure_art()
	_refresh_glow_color()
	card.pivot_offset = size / 2.0
	Motion.to(card, "scale", Vector2(LIFT, LIFT), Motion.BASE, Tween.TRANS_BACK)
	Motion.to(glow, "modulate:a", 1.0, Motion.FAST)
	# Glow pulse: starts wide and settles.
	Motion.method(self, "glow", func(v: float): _set_glow(v), 34.0, 18.0, 0.45)
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
	Motion.to(glow, "modulate:a", 0.0, Motion.FAST)
	Motion.method(self, "pan", func(t: float): _set_pan(Vector2.ZERO, 1.0 + 0.045 * t), 1.0, 0.0, Motion.FAST)


func _set_glow(v: float) -> void:
	_glow_box.shadow_size = int(v)
	glow.queue_redraw()


func _set_pan(p: Vector2, z: float) -> void:
	_mat.set_shader_parameter("pan", p)
	_mat.set_shader_parameter("zoom", z)


## Tile badges as [{"text", "tone", ...}] in display order (strip only).
static func badge_specs(g: Dictionary) -> Array:
	return Badges.for_tile(g)["strip"]


## Art-less card (older call): the generated cover.
static func title_card(g: Dictionary, font_size: int) -> Control:
	var c: Control = FallbackArt.new()
	c.setup(g, font_size, float(ThemeLib.radius("m")))
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	return c
