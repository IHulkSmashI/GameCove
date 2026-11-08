extends Control
## A slim rounded progress bar: track in surface_3, fill in the accent (or a
## colour you pass). value -1 shows an even, quiet "unknown" track. Draws only
## when the value or theme changes; nothing runs per frame.

const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")

var value := -1.0
var fill_color := Color(0, 0, 0, 0)
var track_alpha := 1.0
var _shown := -1.0


func _init(height := 8.0) -> void:
	custom_minimum_size = Vector2(0, height)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


## 0..1, or -1 for unknown. Glides to the new value unless Reduce motion.
func set_value(v: float, animate := true) -> void:
	var target := clampf(v, 0.0, 1.0) if v >= 0.0 else -1.0
	value = target
	if target < 0.0 or _shown < 0.0 or not animate or not is_inside_tree():
		_shown = target
		queue_redraw()
		return
	Motion.method(self, "progress", func(x: float):
		_shown = x
		queue_redraw(), _shown, target, Motion.BASE)


func set_color(c: Color) -> void:
	fill_color = c
	queue_redraw()


func _draw() -> void:
	var h := size.y
	var r := h / 2.0
	var track: Color = ThemeLib.color("surface_3")
	track.a *= track_alpha
	_pill(Rect2(Vector2.ZERO, size), track, r)
	if _shown < 0.0:
		return
	var w := maxf(h, size.x * _shown) if _shown > 0.0 else 0.0
	if w <= 0.0:
		return
	var col := fill_color if fill_color.a > 0.0 else ThemeLib.color("accent")
	_pill(Rect2(Vector2.ZERO, Vector2(w, h)), col, r)


func _pill(rect: Rect2, col: Color, r: float) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(int(r))
	sb.anti_aliasing = true
	draw_style_box(sb, rect)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		queue_redraw()
