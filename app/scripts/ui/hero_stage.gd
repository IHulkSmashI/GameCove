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

var game: Dictionary = {}
var layers: Array[TextureRect] = []
var _front := 0
var _path := ""
var _paused := false


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
		add_child(t)
		layers.append(t)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		for l in layers:
			(l.material as ShaderMaterial).set_shader_parameter("rect_size", size)
			l.pivot_offset = Vector2(size.x * 0.75, size.y * 0.4)


static func hero_path(g: Dictionary) -> String:
	var a: Variant = g.get("art", {})
	var p: String = a.get("hero", "") if a is Dictionary else ""
	return p if ArtCache.usable(p) else ""


func show_game(g: Dictionary) -> void:
	var p := hero_path(g)
	if g.get("key", "") == game.get("key", "-") and p == _path:
		return
	game = g
	_path = p
	if p == "":
		_crossfade(null)
		return
	var want := p
	var tex := ArtCache.request("hero", p, func(t):
		if _path == want:
			_crossfade(t), self)
	if tex != null:
		_crossfade(tex)


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


func _crossfade(tex: Texture2D) -> void:
	var old := layers[_front]
	_front = 1 - _front
	var new := layers[_front]
	if new.get_index() < old.get_index():
		move_child(new, old.get_index())   # new fades in on top
	new.texture = tex
	Motion.to(new, "scale", Vector2.ONE, 0.0)
	new.modulate.a = 0.0
	Motion.to(new, "modulate:a", 1.0 if tex != null else 0.0, CROSSFADE)
	Motion.to(old, "modulate:a", 0.0, CROSSFADE)
	if tex != null and not Motion.reduce and not _paused:
		Motion.to(new, "scale", Vector2(DRIFT_SCALE, DRIFT_SCALE), DRIFT_S, Tween.TRANS_SINE, Tween.EASE_IN_OUT)


func pause_motion() -> void:
	_paused = true
	for l in layers:
		Motion.to(l, "scale", l.scale, 0.0)


func resume_motion() -> void:
	_paused = false
