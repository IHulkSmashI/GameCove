extends VBoxContainer
## One Control from describe(), drawn with the design system's rows:
##   toggle -> ChoiceRow switch, choice -> ChoiceRow (segments or ‹ value ›),
##   slider -> SliderRow, action -> ActionRow, color -> ColorRow,
##   curve -> CurveRow.
## States, all from the model (model.gd):
##   unavailable  greyed, its one-line reason always showing, can't change
##   blocked      needs another setting on first ("Turn on Lights first")
##   needs root   a lock chip; the explanation says no password is needed
##   from profile a chip naming the layer the value comes from
##   pending      an "Applying…" chip until the Controls worker answers
##   failed       the old value comes back, a line says it didn't work
## Settings that can blank the screen (refresh rate after an unlock, HDR) get
## a "Keep this? Reverting in 15 s" check after they apply (keep_dialog.gd).
##
## Pages treat it like any row: `key`, `button` (first focusable),
## focusables().

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const CIcons := preload("res://scripts/ui/controls/cicons.gd")
const TC := preload("res://scripts/ui/texts_controls.gd")
const Model := preload("res://scripts/ui/controls/model.gd")
const ChoiceRow := preload("res://scripts/ui/choice_row.gd")
const SliderRow := preload("res://scripts/ui/slider_row.gd")
const ActionRow := preload("res://scripts/ui/settings/action_row.gd")
const ColorRow := preload("res://scripts/ui/controls/color_row.gd")
const CurveRow := preload("res://scripts/ui/controls/curve_row.gd")
const KeepDialog := preload("res://scripts/ui/controls/keep_dialog.gd")
const SessionGuard := preload("res://scripts/ui/controls/session_guard.gd")

## The focus chain inside changed (rebuilt); hosts relink.
signal rebuilt
## A value was asked for (after the model accepted it).
signal edited(id: String, value: Variant)

var model: Object
var id := ""
var key := ""
var desc: Dictionary = {}
var row: Control
var button: Control
var status_label: Label
## Optional: an icon for the row, a title override, a Control to put dialogs in.
var opts: Dictionary = {}
var _shape := ""
var _badges: HBoxContainer
var _confirm_from: Variant = null
var _confirming := false


## A view for control `cid`, or null when the model doesn't know it.
static func make(m: Object, cid: String, options := {}) -> Control:
	if m == null or not m.has(cid):
		return null
	var v = load("res://scripts/ui/controls/control_view.gd").new()
	v.setup(m, cid, options)
	return v


func setup(m: Object, cid: String, options := {}) -> void:
	model = m
	id = cid
	key = cid
	opts = options
	name = cid.validate_node_name()
	add_theme_constant_override("separation", 4)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_label = Kit.label("", "QuietLabel", true)
	status_label.name = "Status"
	status_label.visible = false
	add_child(status_label)
	model.changed.connect(_on_changed)
	model.failed.connect(_on_failed)
	model.pending_changed.connect(_on_pending)
	model.refreshed.connect(refresh)
	refresh()


func _exit_tree() -> void:
	if model == null:
		return
	for pair in [["changed", _on_changed], ["failed", _on_failed], ["pending_changed", _on_pending], ["refreshed", refresh]]:
		if model.is_connected(pair[0], pair[1]):
			model.disconnect(pair[0], pair[1])


func _enter_tree() -> void:
	if model != null and not model.is_connected("refreshed", refresh):
		model.changed.connect(_on_changed)
		model.failed.connect(_on_failed)
		model.pending_changed.connect(_on_pending)
		model.refreshed.connect(refresh)
		refresh()


func focusables() -> Array:
	if row != null and row.has_method("focusables"):
		return row.focusables()
	return [button] if button != null else []


## Re-reads the description; rebuilds the row only when its shape changed.
func refresh() -> void:
	desc = model.describe(id)
	if desc.is_empty():
		return
	var shape := _shape_of(desc)
	if shape != _shape or row == null:
		_rebuild()
	else:
		_show_value()
	_decorate()


## Kind, availability and range: what the row is built from.
static func _shape_of(d: Dictionary) -> String:
	return var_to_str([d.get("kind"), d.get("available"), d.get("options"), d.get("min"), d.get("max"),
		d.get("step"), d.get("points"), d.get("blocked") != ""])


func title() -> String:
	return str(opts.get("title", desc.get("title", id)))


func _rebuild() -> void:
	var had_focus := false
	if row != null:
		for f in focusables():
			if is_instance_valid(f) and f.has_focus():
				had_focus = true
		remove_child(row)
		row.queue_free()
	row = null
	button = null
	_badges = null
	_shape = _shape_of(desc)
	var icon := str(opts.get("icon", ""))
	if not bool(desc.get("available", false)):
		var r: VBoxContainer = ActionRow.new()
		r.setup("row", title(), "", str(desc.get("reason", "")), icon, false)
		r.collapse_hint = false
		r.set_hint(str(desc.get("reason", "")))
		r.title_label.modulate.a = 0.5
		row = r
		button = r.button
	else:
		match str(desc.get("kind", "")):
			"toggle":
				var r: VBoxContainer = ChoiceRow.new()
				r.setup("row", title(), [false, true], ["Off", "On"], desc.get("value") == true, icon)
				r.changed.connect(_ask)
				row = r
				button = r.button
			"choice":
				var vals: Array = []
				var labels: Array = []
				for o in desc.get("options", []):
					if o is Dictionary:
						vals.append(o.get("value"))
						labels.append(str(o.get("label", o.get("value"))))
				if vals.is_empty():
					vals = [desc.get("value")]
					labels = [Model.value_label(desc)]
				var r: VBoxContainer = ChoiceRow.new()
				r.setup("row", title(), vals, labels, vals[_index_of(vals, desc.get("value"))], icon)
				r.changed.connect(_ask)
				row = r
				button = r.button
			"slider":
				var lo := float(desc.get("min", 0.0))
				var hi := float(desc.get("max", 1.0))
				if hi <= lo:
					hi = lo + 1.0
				var st := float(desc.get("step", 1.0))
				var r: VBoxContainer = SliderRow.new()
				var cur: Variant = desc.get("value")
				r.setup("row", title(), lo, hi, float(cur) if cur != null else lo, st if st > 0.0 else 1.0,
					Model.unit_suffix(str(desc.get("unit", ""))))
				r.changed.connect(_ask)
				row = r
				button = r.slider
			"color":
				var r: VBoxContainer = ColorRow.new()
				r.setup(title(), str(desc.get("value", "#00F0FF")) if desc.get("value") != null else "#00F0FF")
				r.changed.connect(_ask)
				row = r
				button = r.button
			"curve":
				var r: VBoxContainer = CurveRow.new()
				r.setup(title(), desc)
				r.changed.connect(_ask)
				row = r
				button = r.button
			_:
				var r: VBoxContainer = ActionRow.new()
				r.setup("row", title(), TC.RUN, "", icon if icon != "" else "", true)
				r.pressed.connect(func(): _ask(true))
				row = r
				button = r.button
	row.name = "Row"
	add_child(row)
	move_child(row, 0)
	_show_value()
	rebuilt.emit()
	if had_focus and button != null and button.is_inside_tree():
		button.grab_focus.call_deferred()


static func _index_of(vals: Array, v: Variant) -> int:
	for i in vals.size():
		if Model._same(vals[i], v):
			return i
	return 0


## Puts the description's value on the row without emitting anything.
func _show_value() -> void:
	if row == null or not bool(desc.get("available", false)):
		return
	var v: Variant = desc.get("value")
	match str(desc.get("kind", "")):
		"toggle":
			row.set_value_quiet(v == true)
		"choice":
			var i := _index_of(row.values, v)
			if not row.values.is_empty():
				row.set_value_quiet(row.values[i])
		"slider":
			if v != null:
				row.set_value_quiet(float(v))
		"color":
			if v != null:
				row.set_value_quiet(str(v))
		"curve":
			row.set_value_quiet(v if v is Array else [])


## Hint, lock, badges and status from the description.
func _decorate() -> void:
	if row == null:
		return
	var avail := bool(desc.get("available", false))
	var blocked := str(desc.get("blocked", ""))
	if avail and row.has_method("set_locked"):
		row.set_locked(blocked != "")
	var hint := explanation()
	if row.has_method("set_explainer"):
		row.collapse_hint = blocked == ""
		row.set_explainer(func(_v): return hint)
	elif row.has_method("set_hint"):
		if "collapse_hint" in row:
			row.collapse_hint = avail and blocked == ""
		row.set_hint(hint)
	_set_badges()
	if not bool(desc.get("failed", false)) and status_label.text != TC.NEXT_SESSION:
		status_label.visible = false


## The line under the row: reason when it can't be used, else the help, the
## jargon line when the help doesn't explain the title, the root note.
func explanation() -> String:
	if not bool(desc.get("available", false)):
		return str(desc.get("reason", ""))
	var blocked := str(desc.get("blocked", ""))
	if blocked != "":
		return blocked
	var parts: Array[String] = []
	var h := str(opts.get("help", desc.get("help", "")))
	if h != "":
		parts.append(h)
	var j := jargon_line(title(), h)
	if j != "":
		parts.append(j)
	var layer := _shown_layer()
	if TC.LAYER_HELP.has(layer):
		parts.append(TC.LAYER_HELP[layer])
	if bool(desc.get("editing", false)):
		parts.append(TC.USE_GAME_EDIT)
	if bool(desc.get("needs_root", false)):
		parts.append(TC.ROOT_HELP)
	return " ".join(parts)


## One line for jargon in the title when there's no help to explain it.
static func jargon_line(t: String, help: String) -> String:
	if help != "":
		return ""
	for term in TC.JARGON:
		if t.contains(term):
			return str(TC.JARGON[term])
	return ""


## The layer worth naming: none for everyday values, none for "this game"
## when the game has its own settings (everything is then; the header says so).
func _shown_layer() -> String:
	var layer := str(desc.get("layer", ""))
	if layer == "game" and model.has_method("per_game") and model.per_game():
		return ""
	return layer


func _set_badges() -> void:
	if row == null or not row.has_method("badge_slot"):
		return
	var slot: HBoxContainer = row.badge_slot()
	for c in slot.get_children():
		slot.remove_child(c)
		c.queue_free()
	_badges = slot
	if not bool(desc.get("available", false)):
		return
	var layer := _shown_layer()
	if TC.LAYERS.has(layer) and layer != "global":
		var tone := "accent" if layer.begins_with("game") else "info"
		var chip := _chip(TC.LAYERS[layer], "layers" if layer.begins_with("game") else ("plug" if layer == "ac" else "battery_leaf"), tone)
		chip.name = "From"
		slot.add_child(chip)
	if bool(desc.get("needs_root", false)):
		var lock := _chip(TC.ROOT_BADGE, "lock", "")
		lock.name = "Lock"
		slot.add_child(lock)
	if bool(desc.get("pending", false)):
		var p := _chip(TC.PENDING, "", "")
		p.name = "Pending"
		slot.add_child(p)


## A small mono chip that fits inside a 52 px row.
static func _chip(text: String, icon: String, tone: String) -> PanelContainer:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var col: Color = ThemeLib.color("accent") if tone == "accent" else (ThemeLib.tone(tone) if tone != "" else ThemeLib.color("text_2"))
	p.add_theme_stylebox_override("panel", ThemeLib.pill(Color(col, 0.10), Color(col, 0.40), 8, 2))
	var r := Kit.hbox(4)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if icon != "":
		r.add_child(CIcons.rect(icon, 12, col))
	var l := Kit.label(text)
	l.uppercase = true
	l.add_theme_font_override("font", ThemeLib.mono(true, 1))
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", col)
	r.add_child(l)
	p.add_child(r)
	return p


# ---- changes ------------------------------------------------------------------

func _ask(v: Variant) -> void:
	var before: Variant = desc.get("value")
	# set before asking: the answer can come back inside set_value (tests, locals)
	if _needs_confirm() and not _confirming and before != null and not Model._same(before, v):
		_confirm_from = before
	if not model.set_value(id, v):
		_confirm_from = null
		_show_value()
		return
	edited.emit(id, v)


## Settings that get "Keep this?": HDR, the refresh rate once rates were
## unlocked by us, and (next session) the unlock and rotation.
func _needs_confirm() -> bool:
	if id in TC.NEEDS_CONFIRM or id in TC.CONFIRM_NEXT_SESSION:
		return true
	if id == "display.refresh_rate":
		var u: Variant = model.value("display.refresh_unlock")
		return u == true
	return false


func _on_changed(cid: String, _v: Variant) -> void:
	if cid != id:
		if cid in desc.get("requires", []):
			refresh()
		return
	status_label.text = ""
	refresh()
	status_label.visible = false
	if _confirm_from != null:
		var old: Variant = _confirm_from
		_confirm_from = null
		if id in TC.CONFIRM_NEXT_SESSION:
			SessionGuard.remember(id, title(), old, desc.get("value"), Model.value_label(desc))
			status_label.text = TC.NEXT_SESSION
			status_label.add_theme_color_override("font_color", ThemeLib.color("text_2"))
			status_label.visible = true
		else:
			_open_keep(old)


func _on_failed(cid: String, _v: Variant) -> void:
	if cid != id:
		return
	_confirm_from = null
	refresh()
	status_label.text = TC.failed_line(Model.value_label(desc))
	status_label.add_theme_color_override("font_color", ThemeLib.tone("bad"))
	status_label.visible = true


func _on_pending(cid: String, _on: bool) -> void:
	if cid == id:
		desc = model.describe(id)
		_set_badges()


func _open_keep(old: Variant) -> void:
	var host: Control = opts.get("dialog_host")
	if host == null or not is_instance_valid(host):
		host = _top_control()
	if host == null:
		return
	_confirming = true
	var dlg: Control = KeepDialog.open(host, title(), Model.value_label(desc), TC.CONFIRM_SECONDS)
	dlg.decided.connect(func(keep: bool):
		_confirming = false
		if not keep:
			model.set_value(id, old)
		if button != null and is_instance_valid(button) and button.is_inside_tree():
			button.grab_focus())


func _top_control() -> Control:
	var c: Node = self
	while c.get_parent() is Control:
		c = c.get_parent()
	return c as Control if c is Control and c.is_inside_tree() else null
