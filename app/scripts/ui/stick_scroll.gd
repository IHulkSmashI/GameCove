extends Node
## The right stick scrolls a page: up / down on it moves `scroll`, the way it
## does on every console. For what the D-pad doesn't stop on (read-only cards
## and text: docs/CONTROLLER-UX.md CUX-7), so nothing below the fold is out of
## a pad's reach.
##
##   StickScroll.attach(scroller, func() -> bool: return <the page has the pad>)
##
## Runs per frame only while the stick is held past its dead zone on a page
## that owns the pad and has more than it shows; nothing ticks otherwise
## (docs/PERFORMANCE.md).

const TD := preload("res://scripts/ui/texts_device.gd")

## Past this the stick counts as pushed.
const DEADZONE := 0.3
## Layout px a second at a full push.
const SPEED := 1500.0

var scroll: ScrollContainer
## True while the page is the one the pad is on (focus inside it, nothing over it).
var owns: Callable
var _stick := 0.0
var _carry := 0.0


static func attach(s: ScrollContainer, owns_pad: Callable) -> Node:
	var n = load("res://scripts/ui/stick_scroll.gd").new()
	n.name = "StickScroll"
	n.scroll = s
	n.owns = owns_pad
	s.add_child(n, false, Node.INTERNAL_MODE_BACK)
	return n


## The hint bar's prompt for it.
static func hint() -> Array:
	return ["RS", TD.HINT_SCROLL]


func _ready() -> void:
	set_process(false)


## More content than shows.
func can_scroll() -> bool:
	if scroll == null or not is_instance_valid(scroll):
		return false
	var bar := scroll.get_v_scroll_bar()
	return bar != null and bar.max_value - bar.page > 1.0


func _owns_pad() -> bool:
	return scroll != null and scroll.is_visible_in_tree() and owns.is_valid() and bool(owns.call())


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventJoypadMotion) or (event as InputEventJoypadMotion).axis != JOY_AXIS_RIGHT_Y:
		return
	push((event as InputEventJoypadMotion).axis_value if _owns_pad() else 0.0)


## The right stick's up / down position (-1..1): scrolls while past the dead zone.
func push(v: float) -> void:
	_stick = v if absf(v) > DEADZONE else 0.0
	_carry = 0.0
	set_process(_stick != 0.0 and can_scroll() and _owns_pad())


func _process(delta: float) -> void:
	if _stick == 0.0 or not can_scroll() or not _owns_pad():
		_stick = 0.0
		set_process(false)
		return
	# faster the further it is pushed; whole pixels, the rest carried to the next frame
	_carry += signf(_stick) * (absf(_stick) - DEADZONE) / (1.0 - DEADZONE) * SPEED * delta
	var px := int(_carry)
	if px != 0:
		_carry -= px
		scroll.scroll_vertical += px
