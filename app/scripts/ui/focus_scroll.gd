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
##  - shows a neighbour with it when the control names one (meta
##    "reveal_with": the read-only card before or after it);
##  - and never stops with a focusable row partly cut off at the top edge:
##    it moves up to show that row whole, or past it when there's no room.
## Nothing runs while focus stays put; one short glide under Motion (instant
## with Reduce motion).

const Motion := preload("res://scripts/ui/motion.gd")

## Room kept above / below the focused control.
const MARGIN := 18.0

var scroll: ScrollContainer
## Extra room under the focused control (pages with a "More below" fade).
var margin_bottom := MARGIN
var _watched: Control
var _content: Control
var _queued := false


static func attach(s: ScrollContainer, bottom_room := MARGIN) -> Node:
	var fs = load("res://scripts/ui/focus_scroll.gd").new()
	fs.name = "FocusScroll"
	fs.scroll = s
	fs.margin_bottom = bottom_room
	s.follow_focus = false
	s.add_child(fs, false, Node.INTERNAL_MODE_BACK)
	return fs


# Every time it enters the tree, not once in _ready: a scroll that is wrapped
# after it was added (FadeMask.wrap takes it out and puts it back) left the
# tree in between, and with it this listener; Settings rebuilt for a new theme
# then stopped following focus.
func _enter_tree() -> void:
	var vp := get_viewport()
	if vp != null and not vp.gui_focus_changed.is_connected(_on_focus):
		vp.gui_focus_changed.connect(_on_focus)


func _exit_tree() -> void:
	_unwatch()
	var vp := get_viewport()
	if vp != null and vp.gui_focus_changed.is_connected(_on_focus):
		vp.gui_focus_changed.disconnect(_on_focus)


func _on_focus(c: Control) -> void:
	_unwatch()
	if c == null or scroll == null or not scroll.is_ancestor_of(c):
		_stop()
		return
	_watched = c
	c.resized.connect(_queue)
	# A freshly built list (a new tab) keeps growing for a few frames:
	# place the focus again once its height settles.
	_content = scroll.get_child(0) as Control if scroll.get_child_count() > 0 else null
	if _content != null and not _content.resized.is_connected(_queue):
		_content.resized.connect(_queue)
	_queue()


## Ends a glide still running for the previous focus.
func _stop() -> void:
	if scroll != null and scroll.has_meta("_mm_vscroll"):
		var t: Variant = scroll.get_meta("_mm_vscroll")
		if t is Tween and (t as Tween).is_valid():
			(t as Tween).kill()
		scroll.remove_meta("_mm_vscroll")


func _unwatch() -> void:
	if _watched != null and is_instance_valid(_watched) and _watched.resized.is_connected(_queue):
		_watched.resized.disconnect(_queue)
	if _content != null and is_instance_valid(_content) and _content.resized.is_connected(_queue):
		_content.resized.disconnect(_queue)
	_watched = null
	_content = null


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
	# A glide toward an older target (the row before it settled) ends here,
	# or it would carry on past the place this pass wants.
	_stop()
	if absf(target - from) < 1.0:
		return
	Motion.method(scroll, "vscroll", func(v: float): scroll.scroll_vertical = int(round(v)), from, target, Motion.FAST)


## Content height scrolled past the top for `c` to show nicely (see above).
func target_for(c: Control) -> float:
	var view := scroll.size.y
	var content: Control = scroll.get_child(0) if scroll.get_child_count() > 0 else null
	if content == null or view <= 0.0:
		return float(scroll.scroll_vertical)
	var max_v := maxf(0.0, content.size.y - view)
	# Focus inside a scroller of its own (a column of cards inside the page):
	# that scroller keeps the control in view; this one only keeps the whole
	# pane in view. Following the control itself would chase it while the inner
	# scroller glides and leave the page scrolled past the pane's top.
	var inner := _nested_scroller(c)
	if inner != null:
		c = inner
	var r := _rect_in_content(_row_of(c, content))
	# A control can ask for a neighbour to show with it (meta "reveal_with"):
	# read-only cards that don't take focus come into view next to the
	# nearest one that does.
	var extra: Variant = c.get_meta("reveal_with") if c.has_meta("reveal_with") and inner == null else null
	if extra is Control and is_instance_valid(extra) and content.is_ancestor_of(extra):
		var u := r.merge(_rect_in_content(extra))
		if u.size.y + MARGIN + margin_bottom <= view:
			r = u
	var top := r.position.y
	var bottom := r.end.y
	var v := float(scroll.scroll_vertical)
	var below := margin_bottom
	if bottom + below <= view:
		return 0.0
	if top - MARGIN < v or bottom - top + MARGIN + below > view:
		v = top - MARGIN   # taller than the view: its top first
	elif bottom + below > v + view:
		v = bottom + below - view
	v = clampf(v, 0.0, max_v)
	# Something cut by the top edge (a row, a line of text): show it whole if
	# the focus still fits, else scroll past it. Several passes, as moving up
	# can cut the next thing (in a tight list, one row at a time).
	var blocks := _blocks(content)
	for _pass in 24:
		var moved := false
		for b in blocks:
			if b == c or b.is_ancestor_of(c) or c.is_ancestor_of(b):
				continue
			var rr := _rect_in_content(b)
			if rr.position.y < v - 1.0 and rr.end.y > v + 1.0:
				var up := maxf(0.0, rr.position.y - 6.0)
				if bottom + below <= up + view:
					v = up
				else:
					v = minf(rr.end.y + 2.0, top - 4.0)
				moved = true
				break
		if not moved:
			break
	return clampf(v, 0.0, max_v)


## The outermost scroller between `c` and this one, or null.
func _nested_scroller(c: Control) -> ScrollContainer:
	var found: ScrollContainer = null
	var p := c.get_parent()
	while p != null and p != scroll:
		if p is ScrollContainer:
			found = p
		p = p.get_parent()
	return found


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
			elif (ch as Control).focus_mode == Control.FOCUS_NONE:
				_labels(ch, out)   # a focusable row is one block, already counted: its own text isn't another
