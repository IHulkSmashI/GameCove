extends Node
## Console-style "follow focus" for a vertical ScrollContainer, replacing
## Godot's follow_focus (which scrolls the instant focus moves, before a row
## that grows on focus has its final height, and leaves the row above half
## cut off at the top edge).
##
##   FocusScroll.attach(scroll)   # once; adds itself as the scroll's child
##
## When focus lands inside the scroll it waits for the layout to settle (two
## deferred passes, and again if the focused control resizes), then:
##  - keeps the top of the list (scroll 0) while the focused control fits
##    below it, so a page opens at its top;
##  - otherwise scrolls the least distance that shows the control with a
##    little room around it;
##  - and never stops with a focusable row partly cut off at the top edge:
##    it moves up to show that row whole, or past it when there's no room.
## Nothing runs while focus stays put; one short glide under Motion (instant
## with Reduce motion).

const Motion := preload("res://scripts/ui/motion.gd")

## Room kept above / below the focused control.
const MARGIN := 18.0

var scroll: ScrollContainer
var _watched: Control
var _queued := false


static func attach(s: ScrollContainer) -> Node:
	var fs = load("res://scripts/ui/focus_scroll.gd").new()
	fs.name = "FocusScroll"
	fs.scroll = s
	s.follow_focus = false
	s.add_child(fs, false, Node.INTERNAL_MODE_BACK)
	return fs


func _ready() -> void:
	get_viewport().gui_focus_changed.connect(_on_focus)


func _exit_tree() -> void:
	_unwatch()
	var vp := get_viewport()
	if vp != null and vp.gui_focus_changed.is_connected(_on_focus):
		vp.gui_focus_changed.disconnect(_on_focus)


func _on_focus(c: Control) -> void:
	_unwatch()
	if c == null or scroll == null or not scroll.is_ancestor_of(c):
		return
	_watched = c
	c.resized.connect(_queue)
	_queue()


func _unwatch() -> void:
	if _watched != null and is_instance_valid(_watched) and _watched.resized.is_connected(_queue):
		_watched.resized.disconnect(_queue)
	_watched = null


func _queue() -> void:
	if _queued:
		return
	_queued = true
	_settle.call_deferred()


# First pass: containers that resorted because of the focus change queue their
# parents' sorts behind us; the second pass runs after those.
func _settle() -> void:
	_apply.call_deferred()


func _apply() -> void:
	_queued = false
	if _watched == null or not is_instance_valid(_watched) or not _watched.is_visible_in_tree():
		return
	var target := target_for(_watched)
	var from := float(scroll.scroll_vertical)
	if absf(target - from) < 1.0:
		return
	Motion.method(scroll, "focus_scroll", func(v: float): scroll.scroll_vertical = int(round(v)), from, target, Motion.FAST)


## Content height scrolled past the top for `c` to show nicely (see above).
func target_for(c: Control) -> float:
	var view := scroll.size.y
	var content: Control = scroll.get_child(0) if scroll.get_child_count() > 0 else null
	if content == null or view <= 0.0:
		return float(scroll.scroll_vertical)
	var max_v := maxf(0.0, content.size.y - view)
	var r := _rect_in_content(_row_of(c, content))
	var top := r.position.y
	var bottom := r.end.y
	var v := float(scroll.scroll_vertical)
	if bottom + MARGIN <= view:
		return 0.0
	if top - MARGIN < v or bottom - top + 2.0 * MARGIN > view:
		v = top - MARGIN   # taller than the view: its top first
	elif bottom + MARGIN > v + view:
		v = bottom + MARGIN - view
	v = clampf(v, 0.0, max_v)
	# Something cut by the top edge (a row, a line of text): show it whole if
	# the focus still fits, else scroll past it. A few passes, as moving up
	# can cut the next thing.
	var blocks := _blocks(content)
	for _pass in 3:
		var moved := false
		for b in blocks:
			if b == c or b.is_ancestor_of(c) or c.is_ancestor_of(b):
				continue
			var rr := _rect_in_content(b)
			if rr.position.y < v - 1.0 and rr.end.y > v + 1.0:
				var up := maxf(0.0, rr.position.y - 6.0)
				if bottom + MARGIN <= up + view:
					v = up
				else:
					v = minf(rr.end.y + 2.0, top - 4.0)
				moved = true
				break
		if not moved:
			break
	return clampf(v, 0.0, max_v)


## The whole row a focused button belongs to (its title, value, explanation,
## slider track): the largest ancestor holding no other focusable control.
func _row_of(c: Control, content: Control) -> Control:
	var a := c
	while true:
		var p := a.get_parent() as Control
		if p == null or p == content or not content.is_ancestor_of(p):
			break
		if _focusables(p).size() > 1 or p.size.y > scroll.size.y * 0.7:
			break
		a = p
	return a


static func _focusables(n: Node, out: Array = []) -> Array:
	for ch in n.get_children():
		if ch is Control and (ch as Control).visible:
			if (ch as Control).focus_mode != Control.FOCUS_NONE:
				out.append(ch)
			_focusables(ch, out)
	return out


func _rect_in_content(c: Control) -> Rect2:
	var g := c.get_global_rect()
	var s := scroll.get_global_rect()
	var k := scroll.get_global_transform().get_scale().y
	k = k if k > 0.0 else 1.0
	return Rect2(Vector2(g.position.x, (g.position.y - s.position.y) / k + scroll.scroll_vertical), g.size / k)


## What must never sit half under the top edge: focusable rows and lines
## of text (labels, notes, card titles).
func _blocks(content: Control) -> Array:
	var out: Array = []
	for f in _focusables(content):
		out.append(_row_of(f, content))
	_labels(content, out)
	return out


static func _labels(n: Node, out: Array) -> void:
	for ch in n.get_children():
		if ch is Control and (ch as Control).visible:
			if ch is Label or ch is RichTextLabel:
				out.append(ch)
			else:
				_labels(ch, out)
