extends Button
## The top bar's downloads button: a download icon, with a ring around it
## showing overall progress while anything is in the queue, and a small count
## when more than one job waits. Redraws only when told (set_progress).

const ThemeLib := preload("res://theme/gamecove_theme.gd")
const GameIcons := preload("res://scripts/ui/games/game_icons.gd")
const Kit := preload("res://scripts/ui/ui_kit.gd")

## Overall 0..1, -1 unknown; only drawn while active.
var fraction := -1.0
var active := false
var count := 0
var paused := false
var _ring: Control
var _count: Label


class Ring extends Control:
	var owner_button: Button

	func _draw() -> void:
		var b = owner_button
		if b == null or not b.active:
			return
		var c := size / 2.0
		var r := minf(size.x, size.y) / 2.0 - 2.0
		draw_arc(c, r, 0.0, TAU, 48, Color(ThemeLib.color("text"), 0.16), 2.5, true)
		var col: Color = ThemeLib.color("text_3") if b.paused else ThemeLib.color("accent")
		if b.fraction >= 0.0:
			draw_arc(c, r, -PI / 2.0, -PI / 2.0 + TAU * maxf(0.03, b.fraction), 48, col, 2.5, true)
		else:
			draw_arc(c, r, -PI / 2.0, 0.0, 16, col, 2.5, true)


func _init() -> void:
	name = "Downloads"
	theme_type_variation = "IconButton"
	focus_mode = Control.FOCUS_ALL
	toggle_mode = false
	custom_minimum_size = Vector2(44, 44)
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tooltip_text = "Downloads"
	_ring = Ring.new()
	_ring.name = "Ring"
	_ring.owner_button = self
	_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ring.anchor_left = 0.5
	_ring.anchor_right = 0.5
	_ring.anchor_top = 0.5
	_ring.anchor_bottom = 0.5
	_ring.offset_left = -17
	_ring.offset_right = 17
	_ring.offset_top = -17
	_ring.offset_bottom = 17
	add_child(_ring)
	_count = Kit.label("", "")
	_count.name = "Count"
	_count.add_theme_font_size_override("font_size", ThemeLib.SIZE_MICRO)
	_count.add_theme_font_override("font", ThemeLib.font("semibold", true))
	_count.anchor_left = 1.0
	_count.anchor_right = 1.0
	_count.offset_left = -16
	_count.offset_right = 0
	_count.offset_top = 0
	_count.offset_bottom = 16
	_count.visible = false
	add_child(_count)
	_restyle()


func set_progress(is_active: bool, overall: float, jobs: int, all_paused := false) -> void:
	active = is_active
	fraction = overall
	count = jobs
	paused = all_paused
	_count.visible = active and jobs > 1
	_count.text = str(jobs)
	tooltip_text = "Downloads" if not active else "Downloads: %d" % jobs
	_restyle()
	_ring.queue_redraw()


func _restyle() -> void:
	icon = GameIcons.tex("download", 18 if active else 22)
	_count.add_theme_color_override("font_color", ThemeLib.color("accent"))


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _ring != null:
		_restyle()
		_ring.queue_redraw()
