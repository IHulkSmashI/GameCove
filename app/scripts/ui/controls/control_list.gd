extends VBoxContainer
## A run of control views (control_view.gd) for one card or quick menu tab:
## the main ids first, then a "More settings" row that opens the advanced
## ones and everything this handheld can't use (greyed, each with its
## reason). With `hide_unavailable` (the quick menu) controls that can't be
## used are left out, so the menu only shows what works.
##
## Lays itself out again when detection changes what's available. Emits
## `rebuilt` whenever its focus chain changes; focusables() is that chain.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const KeepFocus := preload("res://scripts/ui/keep_focus.gd")
const TC := preload("res://scripts/ui/texts_controls.gd")
const ControlView := preload("res://scripts/ui/controls/control_view.gd")
const ActionRow := preload("res://scripts/ui/settings/action_row.gd")
const CIcons := preload("res://scripts/ui/controls/cicons.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")

signal rebuilt

var model: Object
var main_ids: Array = []
var more_ids: Array = []
var opts: Dictionary = {}
var expanded := false
var views := {}              # id -> view
var more_row: VBoxContainer
var _sig := ""
var _stale := false


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and _stale and is_visible_in_tree():
		_on_refreshed()


## opts: hide_unavailable (bool), titles ({id: title}), icons ({id: icon}),
## help ({id: text}), dialog_host (Control), more_title (String).
func setup(m: Object, main: Array, more: Array = [], options := {}) -> void:
	model = m
	main_ids = main.filter(func(i): return m.has(str(i)))
	more_ids = more.filter(func(i): return m.has(str(i)))
	opts = options
	name = str(options.get("name", "ControlList"))
	add_theme_constant_override("separation", int(options.get("separation", 10)))
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	model.refreshed.connect(_on_refreshed)
	_layout()


func _exit_tree() -> void:
	if model != null and model.is_connected("refreshed", _on_refreshed):
		model.disconnect("refreshed", _on_refreshed)


func _enter_tree() -> void:
	if model != null and not model.is_connected("refreshed", _on_refreshed):
		model.refreshed.connect(_on_refreshed)
		_on_refreshed()


func _usable(id: String) -> bool:
	return bool(model.describe(id).get("available", false))


## Which ids go where now: [shown, behind More].
func placement() -> Array:
	var shown := []
	var advanced := []
	var cant := []
	var hide := bool(opts.get("hide_unavailable", false))
	for id in main_ids:
		if _usable(id):
			shown.append(id)
		elif not hide:
			cant.append(id)
	for id in more_ids:
		if _usable(id):
			advanced.append(id)
		elif not hide:
			cant.append(id)
	# usable advanced settings before the ones that can't be used
	return [shown, advanced + cant]


func _on_refreshed() -> void:
	# hidden (the quick menu closed, another tab showing): sort it out when shown
	if is_inside_tree() and not is_visible_in_tree():
		_stale = true
		return
	catch_up(true)


## A change came while hidden: lay out again now, hidden or not (see
## control_view.gd catch_up).
func catch_up(force := false) -> void:
	if not (_stale or force):
		return
	_stale = false
	var p := placement()
	var sig := var_to_str(p)
	if sig != _sig:
		_layout()


func _layout() -> void:
	var p := placement()
	_sig = var_to_str(p)
	var keep := _focused_id()
	var mark := KeepFocus.mark(self, focusables())
	for c in get_children():
		remove_child(c)
	# views are kept and put back; the More row is made again every time
	if more_row != null and is_instance_valid(more_row):
		more_row.queue_free()
	more_row = null
	for id in p[0]:
		add_child(_view(id))
	if not p[1].is_empty():
		more_row = _more_row(p[1])
		add_child(more_row)
		if expanded:
			for id in p[1]:
				add_child(_view(id))
	# free views no longer placed
	for id in views.keys():
		if not (id in p[0] or (expanded and id in p[1])):
			if views[id].get_parent() == null:
				views[id].queue_free()
			views.erase(id)
	rebuilt.emit()
	if keep != "" and is_inside_tree():
		var target: Control = views[keep].button if views.has(keep) else (more_row.button if more_row != null and keep == "<more>" else null)
		if target != null:
			Kit.focus_later(target)
			return
	# that control went: the nearest one left
	KeepFocus.restore(self, mark, focusables())


func _view(id: String) -> Control:
	if views.has(id) and is_instance_valid(views[id]):
		return views[id]
	var o := {"dialog_host": opts.get("dialog_host")}
	var titles: Dictionary = opts.get("titles", {})
	if titles.has(id):
		o["title"] = titles[id]
	var icons: Dictionary = opts.get("icons", {})
	if icons.has(id):
		o["icon"] = icons[id]
	var helps: Dictionary = opts.get("help", {})
	if helps.has(id):
		o["help"] = helps[id]
	var v: Control = ControlView.make(model, id, o)
	v.rebuilt.connect(func(): rebuilt.emit())
	views[id] = v
	return v


func _more_row(ids_: Array) -> VBoxContainer:
	var r: VBoxContainer = ActionRow.new()
	var n := ids_.size()
	r.setup("More", str(opts.get("more_title", TC.LESS if expanded else TC.MORE)), TC.MORE_COUNT % n if not expanded else "", "", "", false)
	var names: Array = ids_.map(func(i): return str(model.describe(i).get("title", i)))
	r.set_hint(", ".join(names.slice(0, 6)) + ("…" if names.size() > 6 else ""))
	r.title_label.add_theme_color_override("font_color", ThemeLib.color("text_2"))
	var chev := CIcons.rect("chevron_down" if not expanded else "chevron_right", 18, ThemeLib.color("text_3"))
	chev.name = "Chevron"
	r.button.get_child(0).add_child(chev)
	r.pressed.connect(toggle_more)
	return r


func toggle_more() -> void:
	expanded = not expanded
	_layout()
	if is_inside_tree() and more_row != null:
		Kit.focus_later(more_row.button)


func focusables() -> Array:
	var out := []
	for c in get_children():
		if c == more_row:
			out.append(more_row.button)
		elif c.has_method("focusables"):
			out.append_array(c.focusables())
	return out


func _focused_id() -> String:
	if not is_inside_tree():
		return ""
	var f := get_viewport().gui_get_focus_owner()
	if f == null or not is_ancestor_of(f):
		return ""
	if more_row != null and more_row.is_ancestor_of(f):
		return "<more>"
	for id in views:
		if is_instance_valid(views[id]) and views[id].is_ancestor_of(f):
			return id
	return ""
