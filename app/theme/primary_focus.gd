extends StyleBox
## Focus on a primary (gradient) pill: a 2 px white inner border, a 3 px gap
## in the screen's ground colour, then the 3 px accent ring with its glow.
## A plain ring blended into the pill's own cyan end; the white edge and the
## dark gap separate the ring from the fill so it reads as crisply as the ring
## on a focused card. Drawn as three StyleBoxFlat layers.

var _layers: Array[StyleBoxFlat] = []


## ring: the accent ring; gap: the ground behind the button; glow: halo colour.
func setup(ring: Color, gap: Color, glow: Color, glow_size: int, inner := Color.WHITE) -> StyleBox:
	_layers.clear()
	_layers.append(_flat(ring, 3, 6, glow, glow_size))
	_layers.append(_flat(gap, 3, 3))
	_layers.append(_flat(inner, 2, 0))
	return self


func layers() -> Array[StyleBoxFlat]:
	return _layers


static func _flat(col: Color, width: int, expand: int, glow := Color(0, 0, 0, 0), glow_size := 0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.draw_center = false
	s.border_color = col
	s.set_border_width_all(width)
	s.set_corner_radius_all(999)
	s.set_expand_margin_all(expand)
	s.anti_aliasing = true
	s.corner_detail = 12
	if glow.a > 0.0:
		s.shadow_color = glow
		s.shadow_size = glow_size
	return s


func _draw(to_canvas_item: RID, rect: Rect2) -> void:
	for l in _layers:
		l.draw(to_canvas_item, rect)


func _get_draw_rect(rect: Rect2) -> Rect2:
	return rect.grow(6)
