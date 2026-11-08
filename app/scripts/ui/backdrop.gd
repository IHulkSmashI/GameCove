extends Control
## The art-first background: the focused game's art, blurred (ArtCache "blur":
## a tiny image stretched with linear filtering), crossfading when focus moves,
## with a slow Ken Burns zoom and a gradient scrim so text on top always reads.
## The zoom is one 20 s tween per game, stopped by Reduce motion or idle, so
## a still screen costs nothing.

const ThemeLib := preload("res://theme/gamecove_theme.gd")
const ArtColor := preload("res://theme/art_color.gd")
const ArtCache := preload("res://scripts/ui/art_cache.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const UiPrefs := preload("res://scripts/ui/ui_prefs.gd")

signal accent_changed(color: Color)

const CROSSFADE := 0.25
const KEN_BURNS_S := 20.0
const KEN_BURNS_SCALE := 1.05

var game: Dictionary = {}
var accent := Color(0, 0, 0, 0)
var base: ColorRect
var layers: Array[TextureRect] = []
var tint: ColorRect
var scrim_v: TextureRect
var scrim_h: TextureRect
var _front := 0
var _source := ""
var _paused := false


func _init() -> void:
	name = "Backdrop"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	base = ColorRect.new()
	base.name = "Base"
	_fill(base)
	add_child(base)
	for i in 2:
		var t := TextureRect.new()
		t.name = "Art%d" % i
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		t.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		t.modulate.a = 0.0
		_fill(t)
		add_child(t)
		layers.append(t)
	tint = ColorRect.new()
	tint.name = "Tint"
	_fill(tint)
	add_child(tint)
	scrim_v = TextureRect.new()
	scrim_v.name = "ScrimV"
	scrim_v.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	scrim_v.stretch_mode = TextureRect.STRETCH_SCALE
	_fill(scrim_v)
	add_child(scrim_v)
	scrim_h = TextureRect.new()
	scrim_h.name = "ScrimH"
	scrim_h.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	scrim_h.stretch_mode = TextureRect.STRETCH_SCALE
	_fill(scrim_h)
	add_child(scrim_h)
	_restyle()


func _fill(c: Control) -> void:
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_restyle()
		_apply_accent()
	elif what == NOTIFICATION_RESIZED:
		for l in layers:
			l.pivot_offset = size / 2.0


## Rebuild colours from the current theme tokens.
func _restyle() -> void:
	base.color = ThemeLib.color("bg")
	var sc: Color = ThemeLib.color("scrim")
	var k := float(ThemeLib.tok("scrim_strength"))
	scrim_v.texture = _gradient(true, [
		[0.0, Color(sc, k * 0.80)], [0.30, Color(sc, k * 0.55)], [0.62, Color(sc, k * 0.95)], [1.0, Color(sc, minf(1.0, k + 0.3))]])
	scrim_h.texture = _gradient(false, [
		[0.0, Color(sc, k * 0.85)], [0.45, Color(sc, k * 0.25)], [1.0, Color(sc, 0.0)]])


static func _gradient(vertical: bool, stops: Array) -> GradientTexture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array(stops.map(func(s): return s[0]))
	g.colors = PackedColorArray(stops.map(func(s): return s[1]))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 8 if vertical else 256
	t.height = 256 if vertical else 8
	t.fill_from = Vector2(0, 0)
	t.fill_to = Vector2(0, 1) if vertical else Vector2(1, 0)
	return t


## Which picture a game's backdrop comes from: hero art, else the cover.
static func art_source(g: Dictionary) -> String:
	var a: Variant = g.get("art", {})
	if not a is Dictionary:
		return ""
	for k in ["hero", "cover"]:
		if ArtCache.usable(a.get(k, "")):
			return a[k]
	return ""


## Fade to this game's art. Same game: nothing happens.
func show_game(g: Dictionary) -> void:
	var src := art_source(g)
	var key: String = g.get("key", "")
	if key == game.get("key", "-") and src == _source:
		return
	game = g
	_source = src
	if g.is_empty():
		_crossfade(null)
		_set_accent(Color(0, 0, 0, 0))
		return
	if src == "":
		var c := ArtColor.fallback_colors(key)
		_crossfade(_fallback_texture(c))
		_set_accent(c[1])
		return
	var want := src
	var tex := ArtCache.request("blur", src, func(t):
		if _source == want:
			_crossfade(t)
			_pick_accent(g), self)
	if tex != null:
		_crossfade(tex)
	_pick_accent(g)


## The accent comes from the cover when there is one, so the screen agrees
## with the focused tile's glow; else from the backdrop picture.
func _pick_accent(g: Dictionary) -> void:
	var a: Variant = g.get("art", {})
	var cover: String = a.get("cover", "") if a is Dictionary else ""
	var path := cover if ArtCache.usable(cover) else _source
	if path == "":
		return
	if ArtCache.has_accent(path):
		_set_accent(ArtCache.accent(path))
		return
	var key: String = g.get("key", "")
	ArtCache.request("blur", path, func(_t):
		if game.get("key", "") == key:
			_set_accent(ArtCache.accent(path)), self)


static func _fallback_texture(c: Array) -> GradientTexture2D:
	var g := Gradient.new()
	g.colors = PackedColorArray([c[0].darkened(0.2), c[1].darkened(0.1)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 64
	t.height = 40
	t.fill_from = Vector2(0, 1)
	t.fill_to = Vector2(1, 0)
	return t


func _crossfade(tex: Texture2D) -> void:
	var old := layers[_front]
	_front = 1 - _front
	var new := layers[_front]
	new.texture = tex
	if new.get_index() > old.get_index():
		move_child(new, old.get_index())   # new goes under the old one
	Motion.to(new, "modulate:a", 1.0 if tex != null else 0.0, 0.0)
	Motion.to(new, "scale", Vector2.ONE, 0.0)
	new.pivot_offset = size / 2.0
	Motion.to(old, "modulate:a", 0.0, CROSSFADE)
	_ken_burns(new)


func _ken_burns(layer: TextureRect) -> void:
	if Motion.reduce or _paused or layer.texture == null:
		return
	Motion.to(layer, "scale", Vector2(KEN_BURNS_SCALE, KEN_BURNS_SCALE), KEN_BURNS_S, Tween.TRANS_SINE, Tween.EASE_IN_OUT)


## Stop the slow zoom (idle, game running, reduce motion). Keeps the frame.
func pause_motion() -> void:
	_paused = true
	for l in layers:
		if l.has_meta("_mt_scale"):
			var t: Tween = l.get_meta("_mt_scale")
			if t != null and t.is_valid():
				t.kill()
			l.remove_meta("_mt_scale")


func resume_motion() -> void:
	_paused = false


func _set_accent(picked: Color) -> void:
	accent = picked
	_apply_accent()
	accent_changed.emit(current_accent())


## The accent the screen should use now: the art's (made readable) when
## "Match game art" is on and we have one, else the theme's.
func current_accent() -> Color:
	if UiPrefs.match_art and accent.a > 0.0:
		return ArtColor.accent_for(accent, ThemeLib.tokens)
	return ThemeLib.color("accent")


func _apply_accent() -> void:
	var a := accent if (UiPrefs.match_art and accent.a > 0.0) else ThemeLib.color("accent")
	tint.color = Color(a, 0.10 if ThemeLib.is_dark() else 0.05)
