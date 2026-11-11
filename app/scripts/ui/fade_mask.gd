extends TextureRect
## A true alpha mask at the foot of a scrolling area (CSS mask-image: linear-
## gradient(to bottom, black calc(100% - px), transparent)): its children draw
## only where the mask is opaque, so whatever is clipped at the bottom fades
## out over `px` instead of showing a hard sliver, over any background (glass,
## art, light themes). The fade shows only while more content waits below.
##
##   var mask := FadeMask.wrap(scroll, 20)   # puts `scroll` inside the mask
##
## Godot can't nest clip-children masks: an inner mask inside an outer one
## draws its own (white) gradient as a solid block and none of its children,
## on real GPUs as well as llvmpipe (it's the Compatibility renderer's canvas
## group). So a mask that finds itself inside another one stands down: no
## clipping, its texture hidden, its children drawn as usual; the outer mask
## still fades the foot, and a card the cut would have hidden is hidden by
## its own alpha instead.

## Height of the fade, in layout px.
var px := 20.0
## In cut mode the mask ends over this many px (the gap under the last whole item).
const CUT_FADE := 9.0
## Optional `fn() -> Array[Control]` (cards in the scrolling content): while
## more waits below, the mask ends at the foot of the last one that's fully in
## view, so a card cut by the edge doesn't show at all (no sliver, no second
## header) instead of fading.
var cut_fn: Callable
var scroll: ScrollContainer
var _grad: Gradient
var _on := false


## Moves `s` into a new mask that takes its place (index, size flags, ratio).
static func wrap(s: ScrollContainer, fade_px := 20.0) -> TextureRect:
	var m: TextureRect = load("res://scripts/ui/fade_mask.gd").new()
	m.px = fade_px
	m.name = String(s.name) + "Mask"
	m.size_flags_horizontal = s.size_flags_horizontal
	m.size_flags_vertical = s.size_flags_vertical
	m.size_flags_stretch_ratio = s.size_flags_stretch_ratio
	m.custom_minimum_size = s.custom_minimum_size
	var parent := s.get_parent()
	if parent != null:
		var i := s.get_index()
		# Outside a container the scroll was placed by anchors: the mask takes them.
		if not parent is Container:
			for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
				m.set_anchor(side, s.get_anchor(side))
				m.set_offset(side, s.get_offset(side))
		parent.remove_child(s)
		parent.add_child(m)
		parent.move_child(m, i)
	m.add_child(s)
	s.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	m.attach(s)
	# Masks already inside `s` (wrapped before this one) are nested now; one
	# put inside another mask later finds out when it enters the tree.
	m.fit_nesting()
	for k in m.find_children("*", "TextureRect", true, false):
		if k.has_method("fit_nesting"):
			k.fit_nesting()
	return m


## True when an ancestor of `n` already clips its children (a mask of any kind).
static func inside_mask(n: Node) -> bool:
	var p := n.get_parent()
	while p != null:
		if p is CanvasItem and (p as CanvasItem).clip_children != CanvasItem.CLIP_CHILDREN_DISABLED:
			return true
		p = p.get_parent()
	return false


## True while this mask stands down because it sits inside another one.
var nested := false


## Clips (the fade) on its own; inside another mask, no clipping and no
## texture, so it never shows as a white block.
func fit_nesting() -> void:
	var was := nested
	nested = inside_mask(self)
	clip_children = CanvasItem.CLIP_CHILDREN_DISABLED if nested else CanvasItem.CLIP_CHILDREN_ONLY
	self_modulate.a = 0.0 if nested else 1.0
	if was != nested:
		_paint()


## Cards hidden by alpha while nested (the cut without a mask).
var _alpha_hidden: Array = []


## Nested: cards whose top is below `cut` (the ones the mask would have hidden)
## go transparent; every other card it hid comes back.
func _hide_below(cut: float) -> void:
	var keep: Array = []
	if cut > 0.0 and cut_fn.is_valid():
		for c in cut_fn.call():
			if c is CanvasItem and is_instance_valid(c) and (c as Control).get_global_rect().position.y - global_position.y > cut:
				keep.append(c)
	for c in _alpha_hidden:
		if is_instance_valid(c) and not c in keep:
			c.modulate.a = 1.0
	for c in keep:
		c.modulate.a = 0.0
	_alpha_hidden = keep


func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		fit_nesting()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_SCALE
	clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	_grad = Gradient.new()
	var t := GradientTexture2D.new()
	t.gradient = _grad
	t.width = 4
	t.height = 256
	t.fill_from = Vector2(0, 0)
	t.fill_to = Vector2(0, 1)
	texture = t
	resized.connect(_paint)
	_paint()


func attach(s: ScrollContainer) -> void:
	scroll = s
	var bar := s.get_v_scroll_bar()
	bar.value_changed.connect(func(_v): _update())
	bar.changed.connect(_update)
	# Cards settle a frame after the content resizes: look again then.
	s.sort_children.connect(func(): _update.call_deferred())
	_update()


## True while the fade shows (more content below).
func fading() -> bool:
	return _on


func _update() -> void:
	if scroll == null:
		return
	var bar := scroll.get_v_scroll_bar()
	var want := bar.max_value - bar.page - bar.value > 1.0
	if want != _on or cut_fn.is_valid():
		_on = want
		_paint()


func _paint() -> void:
	var h := maxf(size.y, 1.0)
	var cut := cut_at() if _on else -1.0
	if nested or not _alpha_hidden.is_empty():
		_hide_below(cut if nested else -1.0)
	if cut > 0.0:
		# The mask ends in the gap under the last whole item, over a few px:
		# when the items are rows of one long card, the card's own panel goes
		# on below the cut and would otherwise end in a hard line.
		var e := clampf(cut / h, 0.0, 1.0)
		var from := clampf((cut - CUT_FADE) / h, 0.0, e)
		_grad.offsets = PackedFloat32Array([0.0, from, e, 1.0])
		_grad.colors = PackedColorArray([Color.WHITE, Color.WHITE, Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.0)])
		return
	var start := clampf(1.0 - px / h, 0.0, 1.0)
	_grad.offsets = PackedFloat32Array([0.0, start, 1.0])
	_grad.colors = PackedColorArray([Color.WHITE, Color.WHITE, Color(1, 1, 1, 0.0) if _on else Color.WHITE])


## Where the mask ends in cut mode (px from the top), or -1: the foot of the
## lowest card that's whole in view, plus room for its focus ring, when only
## a sliver of the next card shows at the bottom edge (else the plain fade).
func cut_at() -> float:
	if not cut_fn.is_valid() or not is_inside_tree():
		return -1.0
	var h := size.y
	var best := -1.0
	var cut_one := false
	var cut_top := h
	for c in cut_fn.call():
		if not (c is Control) or not is_instance_valid(c) or not c.is_visible_in_tree():
			continue
		var r: Rect2 = c.get_global_rect()
		var top := r.position.y - global_position.y
		var bot := r.end.y - global_position.y
		if bot <= h + 0.5 and top >= -0.5:
			if bot > best:
				best = bot
		elif top < h and bot > h:
			# Only a sliver is hidden; a card you're reading (a big part of
			# the view, or one with focus) is left to the fade instead.
			if h - top > minf(160.0, h * 0.35) or c.has_focus():
				return -1.0
			cut_one = true
			cut_top = minf(cut_top, top)
	if not cut_one or best <= 0.0:
		return -1.0
	# Room for the ring under the last whole card, but never a pixel of the
	# next card's top edge.
	return minf(h, minf(best + 10.0, cut_top - 1.0))
