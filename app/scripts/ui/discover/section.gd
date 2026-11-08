extends Control
## Base for the four Discover screens (For you, Deals, Coming soon,
## Wishlist). root.gd shows one at a time, routes X / Y / B to it and asks it
## for hint-bar entries. Subclasses override build() and the hooks below.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const W := preload("res://scripts/ui/discover/widgets.gd")
const Model := preload("res://scripts/ui/discover/model.gd")
const T := preload("res://scripts/ui/texts_discover.gd")

var ctx: RefCounted
## Where "up" from the first row goes (the section chip in the header).
var top_target: Control
var _built := false
var _dirty := false


func setup(c: RefCounted) -> void:
	ctx = c
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


## (Re)build from the services' current data, keeping focus on the same game.
func refresh() -> void:
	if not visible and _built:
		_dirty = true
		return
	var keep := focused_key()
	for c in get_children():
		W.detach(self, c)
	build()
	_built = true
	_dirty = false
	restore_focus(keep)


## Rebuild if data changed while hidden.
func on_shown() -> void:
	if _dirty or not _built:
		refresh()


func build() -> void:
	pass


func default_focus() -> Control:
	return null


## Section-specific hint entries for the focused control ([[button, text], ...]).
func hints(_f: Control) -> Array:
	return []


## X / Y pressed with focus inside this section; true if handled.
func on_button(_b: String, _f: Control) -> bool:
	return false


## B pressed; true if handled here (e.g. leaving a side panel).
func back(_f: Control) -> bool:
	return false


func on_art(_key: String, _kind: String, _path: String) -> void:
	pass


func set_top_target(c: Control) -> void:
	top_target = c


# ---- focus helpers -------------------------------------------------------------

func _focus_owner() -> Control:
	return get_viewport().gui_get_focus_owner() if is_inside_tree() else null


## "<view key>|<role>" of the focused control, "" if none.
func focused_key() -> String:
	var f := _focus_owner()
	if f == null or not is_ancestor_of(f):
		return ""
	return key_of(f)


static func key_of(c: Control) -> String:
	if c.has_meta("view"):
		return str(c.get_meta("view").get("key", "")) + "|" + str(c.get_meta("role", ""))
	if c.has_meta("role"):
		return "#role:" + str(c.get_meta("role"))
	return "#" + str(c.name)


func restore_focus(k: String) -> void:
	if k == "" or not is_inside_tree() or not is_visible_in_tree():
		return
	for b in W.buttons_in(self):
		if key_of(b) == k and b.is_visible_in_tree():
			_focus_later(b)
			return
	_focus_later(default_focus())


static func _focus_later(c: Control) -> void:
	if c == null:
		return
	var ref: WeakRef = weakref(c)
	(func():
		var n: Control = ref.get_ref()
		if n != null and n.is_inside_tree() and n.is_visible_in_tree():
			n.grab_focus()
	).call_deferred()


## The view a focused control stands for ({} if none).
static func view_of(f: Control) -> Dictionary:
	if f != null and f.has_meta("view"):
		return f.get_meta("view")
	if f != null and f.get("game") is Dictionary and f.game.has("kind"):
		return f.game
	return {}


## Keep `c` visible inside scroll `s` when it gets focus.
static func follow(s: ScrollContainer, c: Control, margin := 24.0) -> void:
	W.follow(s, c, margin)
