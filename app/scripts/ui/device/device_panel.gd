extends HBoxContainer
## Base for the device pages the Settings screen embeds (About this device,
## Controller, Storage, Updates). Each page is built with
## `static func build(services: Dictionary) -> Control`; services has "device",
## "power", "controller", "storage", "updates" (autoloads or test fakes).
##
## What the host gets from every page:
##   default_focus() -> Control      where focus lands when the page opens
##   set_top_target(c)               what d-pad up from the first row goes to (tabs)
##   hints() -> Array                [[glyph, label], ...] for the hint bar (Kit.prompts)
##   signal hints_changed(hints)     when the focused control changes what A does
##   signal toast_requested(text, icon, tone)
##   focus_chain() / focusables()    the focusable controls, top to bottom
##   opened() / closed()             the host showed / hid the page (also done on enter / exit tree)
## Pages connect to their services when built and disconnect when they leave
## the tree. Nothing polls.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const FadeMask := preload("res://scripts/ui/fade_mask.gd")
const DKit := preload("res://scripts/ui/device/device_kit.gd")
const Texts := preload("res://scripts/ui/texts_device.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")

signal hints_changed(hints: Array)
signal toast_requested(text: String, icon: String, tone: String)
## A card's action wants another device section ("storage", "fixes", ...).
signal part_requested(id: String)
## A card's action wants another Settings category ("power", "display").
signal category_requested(id: String)

var services: Dictionary = {}
var top_target: Control
var _chain: Array = []
var _hints: Array = []
var _conns: Array = []   # [signal, callable] to undo on exit


func _init() -> void:
	add_theme_constant_override("separation", 28)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func svc(name_: String) -> Object:
	var s: Variant = services.get(name_)
	return s if s is Object and is_instance_valid(s) else null


## Connect a service signal for as long as the page lives.
func listen(sig: Signal, fn: Callable) -> void:
	if not sig.is_connected(fn):
		sig.connect(fn)
	_conns.append([sig, fn])


func _exit_tree() -> void:
	_leave()


## Undo every listen(); pages add their own clean-up (Storage.watch(false)).
func _leave() -> void:
	for c in _conns:
		var sig: Signal = c[0]
		if sig.is_connected(c[1]):
			sig.disconnect(c[1])
	_conns.clear()


func default_focus() -> Control:
	return _chain[0] if not _chain.is_empty() else null


func focus_chain() -> Array:
	return _chain.filter(func(c): return is_instance_valid(c) and is_ancestor_of(c))


## Same as focus_chain() (name the Settings screen looks for).
func focusables() -> Array:
	return focus_chain()


## The host shows / hides the page without freeing it. Pages that watch
## something (Storage) start and stop here; both are safe to call twice.
func opened() -> void:
	pass


func closed() -> void:
	pass


func set_top_target(c: Control) -> void:
	top_target = c
	_link()


func hints() -> Array:
	return _hints.duplicate()


func set_hints(list: Array) -> void:
	if list == _hints:
		return
	_hints = list.duplicate()
	hints_changed.emit(hints())


## Set the focus chain (top to bottom) and wire neighbours.
func chain(controls: Array) -> void:
	# only what's still on the page: a row being replaced (a Control row drawing a
	# new button, a dropped card waiting to be freed) has no path to the rest
	_chain = controls.filter(func(c): return c != null and is_instance_valid(c) and is_ancestor_of(c))
	_link()
	for c in _chain:
		if not c.focus_entered.is_connected(_on_focus.bind(c)):
			c.focus_entered.connect(_on_focus.bind(c))


func _link() -> void:
	_chain = _chain.filter(func(c): return is_instance_valid(c) and is_ancestor_of(c))
	if _chain.is_empty():
		return
	Kit.link_vertical(_chain, top_target)


## Override: hints for the control that just took focus.
func hints_for(_c: Control) -> Array:
	return [["DPAD", "Scroll"], ["B", "Back"]]


func _on_focus(c: Control) -> void:
	set_hints(hints_for(c))


## The column on the left of each page: picture or summary.
func side_column(ratio := 0.82) -> VBoxContainer:
	var col := Kit.vbox(16)
	col.name = "Side"
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_stretch_ratio = ratio
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(col)
	return col


## The scrolling column of cards on the right. Returns the VBox to fill.
func main_column(ratio := 1.18) -> VBoxContainer:
	var s := DKit.scroller()
	# The column sits in a holder with a fade at its foot while more cards
	# wait below, so the last card never looks sliced off.
	var holder := Control.new()
	holder.name = "MainColumn"
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	holder.size_flags_stretch_ratio = ratio
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(holder)
	s.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.add_child(s)
	var col := Kit.vbox(16)
	col.name = "Cards"
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.add_child(DKit.pad(col, 6))
	# A card the column's foot would slice isn't drawn at all (the mask ends
	# under the last whole card); "More below" says there's more.
	var mask: TextureRect = FadeMask.wrap(s, 24.0)
	mask.cut_fn = func(): return DKit.cards_in(col)
	DKit.more_cue(holder, s)
	return col


func clear_box(box: Node) -> void:
	for c in box.get_children():
		Kit.drop(box, c)
