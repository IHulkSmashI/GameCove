extends Node
## Keeps focus inside a sheet or dialog while it is shown: a D-pad press that
## would leave it (up from its first row into the top bar behind the dim) is
## taken back to where focus was (docs/CONTROLLER-UX.md CUX-6; Xbox XAG 113: "It
## shouldn't be possible to move focus to anything other than interactable
## controls in the dialog box while it's open"). Nothing runs while the panel is
## hidden or while focus stays inside it.
##
##   FocusTrap.attach(sheet, [keyboard])   # once; `allow`: panels it may hand focus to

var allow: Array = []
var _last: Control
var _busy := false


static func attach(panel: Control, also_allow: Array = []) -> Node:
	var t = load("res://scripts/ui/focus_trap.gd").new()
	t.name = "FocusTrap"
	t.allow = also_allow
	panel.add_child(t, false, Node.INTERNAL_MODE_BACK)
	panel.set_meta("ux_modal", "keeps focus while open (FocusTrap)")
	return t


func _enter_tree() -> void:
	var vp := get_viewport()
	if vp != null and not vp.gui_focus_changed.is_connected(_on_focus):
		vp.gui_focus_changed.connect(_on_focus)


func _exit_tree() -> void:
	var vp := get_viewport()
	if vp != null and vp.gui_focus_changed.is_connected(_on_focus):
		vp.gui_focus_changed.disconnect(_on_focus)


func _on_focus(f: Control) -> void:
	var panel := get_parent() as Control
	if _busy or panel == null:
		return
	if f != null and (panel.is_ancestor_of(f) or _allowed(f)):
		_last = f   # also while it fades in: a sheet focuses its first control before it shows
		return
	if not panel.is_visible_in_tree():
		_last = null
		return
	# left the panel while it is up: back to where it was, else its first control
	var back: Control = _last if _last != null and is_instance_valid(_last) and _last.is_visible_in_tree() else _first(panel)
	if back != null:
		_busy = true
		back.grab_focus()
		_busy = false


static func _first(n: Node) -> Control:
	for c in n.get_children():
		if c is Control and (c as Control).is_visible_in_tree():
			if (c as Control).focus_mode == Control.FOCUS_ALL:
				return c
			var d := _first(c)
			if d != null:
				return d
	return null


func _allowed(f: Control) -> bool:
	for a in allow:
		if is_instance_valid(a) and (a == f or (a as Node).is_ancestor_of(f)) and (a as CanvasItem).is_visible_in_tree():
			return true
	return false
