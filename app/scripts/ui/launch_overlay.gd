extends Control
## Launch splash: the game's art full screen, its logo or title, a spinner and
## "Launching…", with B to cancel. Shown from Play until the game takes focus
## (GameSession.started / our window losing focus) or LAUNCH_TIMEOUT_S.
## The spinner only turns while this is visible.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const ArtCache := preload("res://scripts/ui/art_cache.gd")
const Backdrop := preload("res://scripts/ui/backdrop.gd")
const GameHeader := preload("res://scripts/ui/game_header.gd")
const Motion := preload("res://scripts/ui/motion.gd")

signal cancel_requested(game: Dictionary)

const LAUNCH_TIMEOUT_S := 45.0

var game: Dictionary = {}
var art: TextureRect
var header: VBoxContainer
var status: Label
var spinner: Control
var _timer: Timer
var _scrim: TextureRect


class Spinner extends Control:
	var angle := 0.0
	var color := Color.WHITE

	func _ready() -> void:
		set_process(false)

	func _process(delta: float) -> void:
		angle = fposmod(angle + delta * TAU * 0.9, TAU)
		queue_redraw()

	func _draw() -> void:
		var c := size / 2.0
		var r := minf(size.x, size.y) / 2.0 - 3.0
		draw_arc(c, r, 0.0, TAU, 48, Color(color, 0.18), 4.0, true)
		draw_arc(c, r, angle, angle + PI * 0.6, 24, color, 4.0, true)


func _init() -> void:
	name = "LaunchOverlay"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	var base := ColorRect.new()
	base.name = "Base"
	Kit.fill(base)
	add_child(base)
	art = TextureRect.new()
	art.name = "Art"
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	Kit.fill(art)
	add_child(art)
	_scrim = TextureRect.new()
	_scrim.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_scrim.stretch_mode = TextureRect.STRETCH_SCALE
	Kit.fill(_scrim)
	add_child(_scrim)

	var m := Kit.margin(0, 64, 0)
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	m.add_theme_constant_override("margin_bottom", 72)
	add_child(m)
	var col := Kit.vbox(18)
	col.alignment = BoxContainer.ALIGNMENT_END
	m.add_child(col)
	header = GameHeader.new()
	header.max_logo = Vector2(560, 180)
	header.max_badges = 0
	col.add_child(header)
	var row := Kit.hbox(16)
	spinner = Spinner.new()
	spinner.custom_minimum_size = Vector2(34, 34)
	spinner.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(spinner)
	status = Kit.label("Launching…", "LeadLabel")
	status.name = "Status"
	status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(status)
	row.add_child(Kit.spacer())
	row.add_child(Kit.prompts([["B", "Cancel"]]))
	col.add_child(row)

	_timer = Timer.new()
	_timer.one_shot = true
	_timer.wait_time = LAUNCH_TIMEOUT_S
	_timer.timeout.connect(func(): finish())
	add_child(_timer)
	_restyle(base)


func _restyle(base: ColorRect = null) -> void:
	var b := base if base != null else get_node_or_null("Base") as ColorRect
	if b != null:
		b.color = ThemeLib.color("bg")
	var sc: Color = ThemeLib.color("scrim")
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	g.colors = PackedColorArray([Color(sc, 0.2), Color(sc, 0.35), Color(sc, 0.92)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 4
	t.height = 256
	t.fill_to = Vector2(0, 1)
	_scrim.texture = t
	(spinner as Spinner).color = ThemeLib.color("accent")


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _scrim != null:
		_restyle()


func show_for(g: Dictionary, accent: Color = Color(0, 0, 0, 0)) -> void:
	game = g
	header.show_game(g, "")
	status.text = "Launching…" if g.get("installed", true) else "Starting the install…"
	(spinner as Spinner).color = accent if accent.a > 0.0 else ThemeLib.color("accent")
	art.texture = null
	var a: Variant = g.get("art", {})
	var hero_path: String = a.get("hero", "") if a is Dictionary else ""
	var tex: Texture2D = null
	if ArtCache.usable(hero_path):
		tex = ArtCache.request("hero", hero_path, func(t):
			if game.get("key", "") == g.get("key", ""):
				art.texture = t, self)
	if tex == null:
		var src := Backdrop.art_source(g)
		if src != "":
			tex = ArtCache.request("blur", src, func(t):
				if game.get("key", "") == g.get("key", "") and art.texture == null:
					art.texture = t, self)
	art.texture = tex
	Motion.fade(self, true, Motion.BASE)
	spinner.set_process(is_inside_tree())
	if _timer.is_inside_tree():
		_timer.start()


## The game took focus (or timed out): fade away.
func finish() -> void:
	if not visible:
		return
	_timer.stop()
	spinner.set_process(false)
	Motion.fade(self, false, Motion.SLOW)


func cancel() -> void:
	var g := game
	finish()
	cancel_requested.emit(g)


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		cancel()
		get_viewport().set_input_as_handled()
