extends RefCounted
## Keeps the controller's place when a list of rows is built again (review 3,
## medium 3). A row that had focus and is gone after the rebuild (Bluetooth
## Forget, a GE-Proton build removed, an app that stopped playing, a clip
## deleted) used to leave nothing focused: with a controller there was no way
## back. Now focus goes to the same control if it's still there, else to the one
## now at its place in the list (the next row, or the last when it was the
## last), else to the card's main button, else to whatever came before the box.
##
##   var m := KeepFocus.mark(self, focusables())    # before freeing the rows
##   ... build the rows again ...
##   KeepFocus.restore(self, m, focusables(), main_button)
##
## Nothing happens when focus wasn't inside the box. Outside a live tree (unit
## tests) the box's TEST_META stands in for the focus owner and follows the move.

const Kit := preload("res://scripts/ui/ui_kit.gd")

const TEST_META := "focus_for_tests"


## The control with focus when it's `box` or inside it, else null.
static func focused_in(box: Control) -> Control:
	var f: Control = null
	if box.has_meta(TEST_META):
		var t: Variant = box.get_meta(TEST_META)
		f = t if t is Control and is_instance_valid(t) else null
	elif box.is_inside_tree():
		f = box.get_viewport().gui_get_focus_owner()
	if f == null or not (f == box or box.is_ancestor_of(f)):
		return null
	return f


## A name for `c` that survives a rebuild: its path under `box` without the
## generated "@Type@123" parts (rows are named after their keys); "" for a
## control without a name of its own.
static func key_of(box: Node, c: Node) -> String:
	if not is_instance_valid(c) or not (c == box or box.is_ancestor_of(c)):
		return ""
	if String(c.name).begins_with("@"):
		return ""   # no name of its own: only its place in the list says which it was
	var parts := PackedStringArray()
	for p in String(box.get_path_to(c)).split("/"):
		if not p.begins_with("@"):
			parts.append(p)
	return "/".join(parts)


## Before the rebuild: {} when focus isn't ours, else where it was.
static func mark(box: Control, focusables: Array) -> Dictionary:
	var f := focused_in(box)
	if f == null:
		return {}
	var idx := -1
	var key := ""
	for i in focusables.size():
		var c: Variant = focusables[i]
		if c is Control and is_instance_valid(c) and (c == f or (c as Control).is_ancestor_of(f)):
			idx = i
			key = key_of(box, c)
			break
	var before: Control = null
	if box.is_inside_tree():
		var p := f.find_prev_valid_focus()
		if p != null and p != box and not box.is_ancestor_of(p):
			before = p
	return {"key": key, "index": idx, "before": weakref(before) if before != null else null}


## After the rebuild: focuses (next frame) and returns the control that takes over.
static func restore(box: Control, m: Dictionary, focusables: Array, fallback: Control = null) -> Control:
	if m.is_empty():
		return null
	var live: Array = focusables.filter(func(c): return c is Control and is_instance_valid(c) and not (c as Control).is_queued_for_deletion())
	var target: Control = null
	if str(m["key"]) != "":
		for c in live:
			if key_of(box, c) == str(m["key"]):
				target = c
				break
	if target == null and int(m["index"]) >= 0 and not live.is_empty():
		target = live[clampi(int(m["index"]), 0, live.size() - 1)]
	if target == null and fallback != null and is_instance_valid(fallback):
		target = fallback
	if target == null and m.get("before") != null:
		target = m["before"].get_ref()
	if target == null:
		return null
	if box.has_meta(TEST_META):
		box.set_meta(TEST_META, target)
	elif target.is_inside_tree():
		Kit.focus_later(target)
	return target
