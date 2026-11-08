extends Control
## Discover: deals, release calendar, wishlist and store pages.
##
## build_content() makes the Discover area (scripts/ui/discover/root.gd) from
## the Discover and Art services. `DiscoverScreen.content_factory` still
## replaces it when set: func(services: Dictionary) -> Control.
## `services` is what main.gd passes to setup():
##   {"library": Library, "open_game": Callable(game), "toast": Callable(text, icon, tone, detail)}
## plus, for tests and previews, optional "discover" / "art" fakes, "prefs_path"
## and "clock". This screen adds "stage" (full-screen layer behind the content,
## for hero art) and "overlay" (full-screen layer above it, for store pages).
##
## Talks to main.gd only through what main already offers: `game_focused`
## (the backdrop follows), `default_focus()`, `set_top_target()`, and, found
## by duck typing on the host, `hint_bar` (redrawn with Discover's own hints
## after main draws its generic ones) and `top_bar` (hidden while a store
## page is open; a dot on the Discover tab while alerts wait).

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Root := preload("res://scripts/ui/discover/root.gd")

signal game_focused(game: Dictionary)
signal open_requested(game: Dictionary)

static var content_factory: Callable = Callable()

var services: Dictionary = {}
var content: Control
var stage: Control
var overlay: Control
var _margin: MarginContainer
var _hint_queued := false


func _init() -> void:
	name = "Discover"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage = Control.new()
	stage.name = "Stage"
	stage.set_anchors_preset(Control.PRESET_FULL_RECT)
	stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(stage)
	_margin = Kit.margin(0)
	_margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	_margin.add_theme_constant_override("margin_left", 48)
	_margin.add_theme_constant_override("margin_right", 48)
	_margin.add_theme_constant_override("margin_top", 92)
	_margin.add_theme_constant_override("margin_bottom", 58)
	add_child(_margin)
	overlay = Control.new()
	overlay.name = "Overlay"
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(overlay)
	visibility_changed.connect(func():
		if visible:
			_set_tab_dot(false))


func _ready() -> void:
	get_viewport().gui_focus_changed.connect(func(_f): request_hints())


func setup(svc: Dictionary) -> void:
	services = svc.duplicate()
	services["stage"] = stage
	services["overlay"] = overlay
	if content != null:
		content.queue_free()
	for layer in [stage, overlay]:
		for c in layer.get_children():
			c.queue_free()
	content = content_factory.call(services) if content_factory.is_valid() else build_content()
	_margin.add_child(content)
	if content.has_signal("game_focused"):
		content.game_focused.connect(func(g): game_focused.emit(g))
	if content.has_signal("open_requested"):
		content.open_requested.connect(func(g): open_requested.emit(g))
	if content.has_signal("hints_changed"):
		content.hints_changed.connect(request_hints)
	if content.has_signal("page_toggled"):
		content.page_toggled.connect(_on_page_toggled)
	if content.has_signal("alerts_changed"):
		content.alerts_changed.connect(func(n): _set_tab_dot(n > 0 and not is_visible_in_tree()))


func build_content() -> Control:
	var r: Control = Root.new()
	r.setup(services)
	return r


func default_focus() -> Control:
	if content != null and content.has_method("default_focus"):
		return content.default_focus()
	return null


func set_top_target(c: Control) -> void:
	if content != null and content.has_method("set_top_target"):
		content.set_top_target(c)


## The node that owns the hint bar and top bar (main.gd), found by duck typing.
func host() -> Node:
	var n := get_parent()
	while n != null:
		if n.get("hint_bar") is Control:
			return n
		n = n.get_parent()
	return null


## Redraw the hint bar with Discover's hints once main has drawn its own.
func request_hints() -> void:
	if _hint_queued or not is_inside_tree():
		return
	_hint_queued = true
	_apply_hints.call_deferred()


func _apply_hints() -> void:
	_hint_queued = false
	if content == null or not content.has_method("hints_for") or not is_visible_in_tree():
		return
	var f := get_viewport().gui_get_focus_owner()
	if f == null or not content.has_method("owns") or not content.owns(f):
		return
	var h := host()
	if h == null:
		return
	var bar: Control = h.hint_bar
	for c in bar.get_children():
		bar.remove_child(c)
		c.queue_free()
	bar.add_child(Kit.prompts(content.hints_for(f)))


func _on_page_toggled(open: bool) -> void:
	var h := host()
	if h != null and h.get("top_bar") is Control:
		h.top_bar.visible = not open
	request_hints()


func _set_tab_dot(on: bool) -> void:
	var h := host()
	if h != null and h.get("top_bar") is Control and h.top_bar.has_method("set_dot"):
		h.top_bar.set_dot("discover", on)
