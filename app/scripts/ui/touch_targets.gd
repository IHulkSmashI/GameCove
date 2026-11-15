extends Node
## Every control a finger can press is at least 48 x 48 layout px
## (docs/CONTROLLER-UX.md CUX-13; Android's 48 dp, WCAG 2.2's 24 px is the
## floor). Watches controls as they enter the tree and raises a button's,
## slider's or text field's minimum size to 48 where its maker asked for less,
## once, after the maker set it up (deferred). A control that has a reason to be
## smaller says so with meta "ux_small_ok". Nothing runs while nothing is added.

const MIN := 48.0

var _queue: Array = []


static func attach(tree: SceneTree) -> Node:
	var t = load("res://scripts/ui/touch_targets.gd").new()
	t.name = "TouchTargets"
	tree.node_added.connect(t._on_added)
	return t


func _exit_tree() -> void:
	if get_tree() != null and get_tree().node_added.is_connected(_on_added):
		get_tree().node_added.disconnect(_on_added)


func _on_added(n: Node) -> void:
	if not (n is BaseButton or n is Slider or n is LineEdit or n is SpinBox):
		return
	if _queue.is_empty():
		_flush.call_deferred()
	_queue.append(n)


func _flush() -> void:
	var list := _queue
	_queue = []
	for n in list:
		if is_instance_valid(n):
			apply(n as Control)


## Raises `c` to the minimum touch size unless it opts out or isn't touchable.
static func apply(c: Control) -> void:
	if c == null or c.has_meta("ux_small_ok") or c.mouse_filter == Control.MOUSE_FILTER_IGNORE:
		return
	if c.focus_mode == Control.FOCUS_NONE and not c is BaseButton:
		return
	var m := c.custom_minimum_size
	var want := Vector2(maxf(m.x, MIN), maxf(m.y, MIN))
	if want != m:
		c.custom_minimum_size = want
