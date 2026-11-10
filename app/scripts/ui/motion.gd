extends RefCounted
## Every animation goes through here, so "Reduce motion" is one switch and
## nothing animates while the screen is idle (Tweens stop when they finish,
## and low-processor mode only redraws while something changes).

const FAST := 0.15
const BASE := 0.22
const SLOW := 0.30

## Settings > Reduce motion. When on, values jump straight to their target.
static var reduce := false


## Animate node.prop to `to`. Kills an earlier animation of the same property
## on the same node. Returns the Tween, or null when the value was set at once
## (reduce motion, node not in the tree, or zero duration).
static func to(node: Object, prop: String, target: Variant, dur := BASE,
		trans := Tween.TRANS_CUBIC, ease := Tween.EASE_OUT) -> Tween:
	if node == null:
		return null
	var meta := "_mt_" + prop.replace(":", "_")
	_kill(node, meta)
	if reduce or dur <= 0.0 or not (node is Node and node.is_inside_tree()):
		node.set_indexed(prop, target)
		return null
	var t: Tween = node.create_tween()
	t.set_trans(trans).set_ease(ease)
	t.tween_property(node, prop, target, dur)
	node.set_meta(meta, t)
	return t


## Animate node.prop from `from` to `target` after `delay` (an entrance: a
## slide-in, a rise). Shares Motion.to()'s slot for the property, so a later
## Motion.to() on it takes over cleanly. Under reduce motion (or out of the
## tree) the property is set to `target` at once.
static func enter(node: Node, prop: String, from: Variant, target: Variant, dur := BASE, delay := 0.0,
		trans := Tween.TRANS_CUBIC, ease := Tween.EASE_OUT) -> Tween:
	if node == null:
		return null
	var meta := "_mt_" + prop.replace(":", "_")
	_kill(node, meta)
	if reduce or dur <= 0.0 or not node.is_inside_tree():
		node.set_indexed(prop, target)
		return null
	node.set_indexed(prop, from)
	var t := node.create_tween()
	t.tween_property(node, prop, target, dur).from(from).set_delay(delay).set_trans(trans).set_ease(ease)
	node.set_meta(meta, t)
	return t


## A little pop (a new deal, a fresh unlock): the control scales up from `from`
## about its centre with a soft overshoot. Nothing under reduce motion.
static func pop(c: Control, from := 0.8, dur := 0.36, delay := 0.0) -> Tween:
	if c == null:
		return null
	_kill(c, "_mt_scale")
	if reduce or dur <= 0.0 or not c.is_inside_tree():
		c.scale = Vector2.ONE
		return null
	c.scale = Vector2.ONE * from
	var t := c.create_tween()
	if delay > 0.0:
		t.tween_interval(delay)
	t.tween_callback(func(): c.pivot_offset = c.size / 2.0)   # laid out by now
	t.tween_property(c, "scale", Vector2.ONE, dur).from(Vector2.ONE * from).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	c.set_meta("_mt_scale", t)
	return t


static func _kill(node: Object, meta: String) -> void:
	if node.has_meta(meta):
		var old: Variant = node.get_meta(meta)
		if old is Tween and (old as Tween).is_valid():
			(old as Tween).kill()
		node.remove_meta(meta)


## Animate a value through a setter (e.g. a shader parameter or scroll offset).
static func method(node: Node, key: String, setter: Callable, from: Variant, target: Variant, dur := BASE,
		trans := Tween.TRANS_CUBIC, ease := Tween.EASE_OUT) -> Tween:
	var meta := "_mm_" + key
	_kill(node, meta)
	if reduce or dur <= 0.0 or not node.is_inside_tree():
		setter.call(target)
		return null
	var t := node.create_tween()
	t.set_trans(trans).set_ease(ease)
	t.tween_method(setter, from, target, dur)
	node.set_meta(meta, t)
	return t


## Fade a control in (and make it visible) or out (and hide it at the end).
static func fade(c: CanvasItem, show: bool, dur := FAST) -> void:
	if show:
		if not c.visible:
			c.modulate.a = 0.0
			c.visible = true
		to(c, "modulate:a", 1.0, dur)
	else:
		var t := to(c, "modulate:a", 0.0, dur)
		if t == null:
			c.visible = false
		else:
			t.finished.connect(func():
				if is_instance_valid(c) and c.modulate.a <= 0.01:
					c.visible = false)


## How far things slide in px; 0 under reduce motion (fades only).
static func slide(px: float) -> float:
	return 0.0 if reduce else px
