extends Control
## The crisp key art behind the Home spotlight: the focused game's hero image,
## right-weighted, dissolving into the blurred backdrop (same picture) toward
## the text on the left and the shelves below. Crossfades between games and
## drifts very slowly while the screen is in use (stopped by idle, a running
## game or Reduce motion).

const ArtCache := preload("res://scripts/ui/art_cache.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const FadeShader := preload("res://shaders/hero_fade.gdshader")

const CROSSFADE := 0.30
const DRIFT_S := 20.0
const DRIFT_SCALE := 1.05
## Where a poster (cover art standing in for a missing hero) starts, 0..1.
const POSTER_LEFT := 0.52

var game: Dictionary = {}
var layers: Array[TextureRect] = []
var _front := 0
var _path := ""
var _paused := false
## Inside the Home hero frame: rounded corners, no drift (it would leave the frame).
var frame_radius := 0.0


func _init() -> void:
	name = "HeroStage"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor_right = 1.0
	anchor_bottom = 0.68
	for i in 2:
		var t := TextureRect.new()
		t.name = "Hero%d" % i
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		t.set_anchors_preset(Control.PRESET_FULL_RECT)
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var m := ShaderMaterial.new()
		m.shader = FadeShader
		t.material = m
		t.modulate.a = 0.0
		t.resized.connect(func(): (t.material as ShaderMaterial).set_shader_parameter("rect_size", t.size))
		add_child(t)
		layers.append(t)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_fade()
	if what == NOTIFICATION_RESIZED:
		for l in layers:
			l.pivot_offset = Vector2(size.x * 0.75, size.y * 0.4)


## The art keeps its full colour in every theme. In its Home / Discover frame
## only the text side gets a shade (dark themes: toward the scrim, fading out
## by 58 % of the width; Light: a light band behind the title that's gone by
## LIGHT_SHADE_TO, never a veil over the picture). Unframed (the downloads
## list), the art dissolves into the backdrop at its edges instead.
const LIGHT_SHADE_FROM := 0.22
const LIGHT_SHADE_TO := 0.40
const LIGHT_SHADE_ALPHA := 0.88


func _apply_fade() -> void:
	for l in layers:
		_fade_layer(l)
	self_modulate = Color.WHITE
	modulate.a = 1.0


func _fade_layer(l: TextureRect) -> void:
	var ThemeLib = load("res://theme/gamecove_theme.gd")
	var dark: bool = ThemeLib.is_dark()
	var m := l.material as ShaderMaterial
	m.set_shader_parameter("fade_left_from", 0.10 if dark else 0.40)
	m.set_shader_parameter("fade_left_to", 0.55 if dark else 0.85)
	m.set_shader_parameter("fade_top", 0.10 if dark else 0.35)
	m.set_shader_parameter("fade_bottom_from", (0.50 if dark else 0.40) if frame_radius <= 0.0 else 0.70)
	m.set_shader_parameter("frame_radius", frame_radius)
	m.set_shader_parameter("shade_color", Color(0, 0, 0, 0))
	m.set_shader_parameter("shade_from", 0.0)
	if frame_radius > 0.0:
		# Key art at full colour in its frame: no fade into the backdrop, only a
		# shade behind the text on the left and a short fade at the foot.
		var sc: Color = ThemeLib.color("scrim")
		m.set_shader_parameter("fade_left_from", -1.0)
		m.set_shader_parameter("fade_left_to", 0.0)
		m.set_shader_parameter("fade_top", 0.0)
		m.set_shader_parameter("fade_bottom_from", 0.84)
		m.set_shader_parameter("shade_color", Color(sc, 0.80 if dark else LIGHT_SHADE_ALPHA))
		m.set_shader_parameter("shade_from", 0.0 if dark else LIGHT_SHADE_FROM)
		m.set_shader_parameter("shade_to", 0.58 if dark else LIGHT_SHADE_TO)
	if l.get_meta("poster", false):
		m.set_shader_parameter("fade_left_from", 0.0)
		m.set_shader_parameter("fade_left_to", 0.55)


static func hero_path(g: Dictionary) -> String:
	var a: Variant = g.get("art", {})
	var p: String = a.get("hero", "") if a is Dictionary else ""
	return p if ArtCache.usable(p) else ""


## No hero image: the cover, as a poster on the right that dissolves leftward.
static func cover_path(g: Dictionary) -> String:
	var a: Variant = g.get("art", {})
	var p: String = a.get("cover", "") if a is Dictionary else ""
	return p if ArtCache.usable(p) else ""


func show_game(g: Dictionary) -> void:
	var p := hero_path(g)
	var kind := "hero"
	if p == "" and frame_radius > 0.0:
		p = cover_path(g)
		kind = "cover"
	if g.get("key", "") == game.get("key", "-") and p == _path:
		return
	game = g
	_path = p
	if p == "":
		_crossfade(null)
		return
	var want := p
	var tex := ArtCache.request(kind, p, func(t):
		if _path == want:
			_crossfade(t, kind == "cover"), self)
	if tex != null:
		_crossfade(tex, kind == "cover")


## First launch: a soft glow in the theme's two accents instead of key art.
func show_welcome() -> void:
	game = {"key": "_welcome"}
	_path = ""
	var ThemeLib = load("res://theme/gamecove_theme.gd")
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.45, 1.0])
	g.colors = PackedColorArray([Color(ThemeLib.color("accent"), 0.55), Color(ThemeLib.color("accent_2"), 0.30), Color(ThemeLib.color("accent_2"), 0.0)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 256
	t.height = 160
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.68, 0.42)
	t.fill_to = Vector2(1.05, 0.95)
	_crossfade(t)


func has_art() -> bool:
	return layers[_front].texture != null


## The art showing now (the launch zoom starts from it), null without.
func front_texture() -> Texture2D:
	return layers[_front].texture


func _crossfade(tex: Texture2D, poster := false) -> void:
	var old := layers[_front]
	_front = 1 - _front
	var new := layers[_front]
	if new.get_index() < old.get_index():
		move_child(new, old.get_index())   # new fades in on top
	new.texture = trim_bars(tex) if tex != null and not poster else tex
	# A poster (cover, no hero) fills the right part of the frame only.
	new.anchor_left = POSTER_LEFT if poster else 0.0
	(new.material as ShaderMaterial).set_shader_parameter("rect_size", new.size)
	new.set_meta("poster", poster)
	_fade_layer(new)
	Motion.to(new, "scale", Vector2.ONE, 0.0)
	new.modulate.a = 0.0
	Motion.to(new, "modulate:a", 1.0 if tex != null else 0.0, CROSSFADE)
	Motion.to(old, "modulate:a", 0.0, CROSSFADE)
	if tex != null and not Motion.reduce and not _paused and frame_radius <= 0.0:
		Motion.to(new, "scale", Vector2(DRIFT_SCALE, DRIFT_SCALE), DRIFT_S, Tween.TRANS_SINE, Tween.EASE_IN_OUT)


## Some store heroes come with black bars baked into their sides (Frostpunk's):
## shown covered in a wide frame, the bar ended the art in a hard vertical
## edge. Returns the art without them (an AtlasTexture), or `tex` as it is.
static func trim_bars(tex: Texture2D) -> Texture2D:
	if not tex is ImageTexture:
		return tex
	var img := tex.get_image()
	if img == null or img.is_empty() or img.is_compressed():
		return tex
	var r := content_columns(img)
	if r.x <= 0 and r.y >= img.get_width():
		return tex
	var a := AtlasTexture.new()
	a.atlas = tex
	a.region = Rect2(r.x, 0, r.y - r.x, img.get_height())
	return a


## [first, end) columns of `img` that aren't a flat near-black bar at either
## side. Bars narrower than 2 % or wider than 30 % of the width are left alone.
static func content_columns(img: Image) -> Vector2i:
	var w := img.get_width()
	var h := img.get_height()
	var dark := func(x: int) -> bool:
		for i in 24:
			var c := img.get_pixel(x, int((i + 0.5) * h / 24.0))
			if c.r + c.g + c.b > 0.08:
				return false
		return true
	var lo := 0
	while lo < w * 0.3 and dark.call(lo):
		lo += 1
	var hi := w
	while hi > w * 0.7 and dark.call(hi - 1):
		hi -= 1
	if lo < w * 0.02 or lo >= w * 0.3:
		lo = 0
	if w - hi < w * 0.02 or hi <= w * 0.7:
		hi = w
	return Vector2i(lo, hi)


func pause_motion() -> void:
	_paused = true
	for l in layers:
		Motion.to(l, "scale", l.scale, 0.0)


func resume_motion() -> void:
	_paused = false


## Put the stage inside a rounded frame (Home's hero card): `side` px from the
## left and right edges, from `top` down `height` px.
func use_frame(side: float, top: float, height: float, radius: float) -> void:
	frame_radius = radius
	anchor_left = 0.0
	anchor_right = 1.0
	anchor_top = 0.0
	anchor_bottom = 0.0
	offset_left = side
	offset_right = -side
	offset_top = top
	offset_bottom = top + height
	_apply_fade()
