extends VBoxContainer
## One setting: a wide row "Title ...... [ A | B | C ]" with a segmented
## control (the chosen segment filled with the accent) when there are two to
## four short values, else "‹ Value ›" with position dots; and a line under it
## (neutral text, inside the row's card while it shows). Left/right (d-pad, stick, arrow keys) step
## through values; A / click steps forward. Booleans are a switch (Off / On).

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Texts := preload("res://scripts/ui/texts.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")

signal changed(value: Variant)

## Most position dots under a stepper's value.
const MAX_DOTS := 9

var key := ""
var values: Array = []
var labels: Array = []
var index := 0
var button: Button
var icon_name := ""
var _value_label: Label
var _hint: Label
var _left: TextureRect
var _right: TextureRect
var _dots: HBoxContainer
var _switch: Panel
var _knob: Panel
var _is_bool := false
var _segments: HBoxContainer
var _busy := false
## Hide the explanation unless the row has focus.
var collapse_hint := true
## Optional func(value) -> String for the line under the row; default Texts.explain.
var explainer: Callable
## Optional func(key, value) -> String for the line under the row; Texts.explain otherwise.
var explain_fn: Callable
## Locked rows show their value but don't change (a setting that needs
## another one first, or isn't available). Set with set_locked().
var locked := false
var title_label: Label
var _row: HBoxContainer
var _badge_box: HBoxContainer
## Optional card look for the row (and its line when carded) instead of the
## theme's RowButton box, e.g. the quick menu's tinted per-game switch.
var card_box: StyleBox
## Left / right step through the values (settings pages). Off in the installer: a choice there changes only on
## A, and the d-pad only moves focus between controls and columns.
var step_on_pad := true


func setup(setting_key: String, title: String, vals: Array, lbls: Array, current: Variant, icon := "") -> void:
	key = setting_key
	name = setting_key
	values = vals
	labels = lbls
	icon_name = icon
	index = maxi(0, values.find(current))
	_is_bool = values == [false, true]
	add_theme_constant_override("separation", 6)

	button = Kit.button("", "RowButton")
	button.name = "Button"
	button.custom_minimum_size = Vector2(0, 52)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.gui_input.connect(_on_gui_input)
	button.pressed.connect(func(): step(1))
	button.focus_entered.connect(_refresh_focus)
	button.focus_exited.connect(_refresh_focus)
	add_child(button)

	var row := Kit.hbox(12)
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 18
	row.offset_right = -14
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(row)
	_row = row
	if icon != "":
		row.add_child(Icons.rect(icon, 22, ThemeLib.color("text_2")))
	var t := Kit.label(title)
	title_label = t
	t.name = "Title"
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	t.size_flags_vertical = Control.SIZE_FILL
	t.add_theme_font_override("font", ThemeLib.font("medium"))
	row.add_child(t)

	_value_label = Kit.label("", "ValueLabel")
	_value_label.name = "Value"
	_value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_value_label.size_flags_vertical = Control.SIZE_FILL
	if _is_bool:
		_value_label.add_theme_color_override("font_color", ThemeLib.color("text_2"))
		_value_label.add_theme_font_size_override("font_size", ThemeLib.SIZE_SMALL)
		row.add_child(_value_label)
		_switch = Panel.new()
		_switch.name = "Switch"
		_switch.custom_minimum_size = Vector2(46, 26)
		_switch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_switch.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_knob = Panel.new()
		_knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_knob.size = Vector2(20, 20)
		_knob.position = Vector2(3, 3)
		_switch.add_child(_knob)
		row.add_child(_switch)
	elif segmented(lbls):
		_value_label.visible = false
		row.add_child(_value_label)
		_segments = Kit.hbox(2)
		_segments.name = "Segments"
		_segments.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_segments.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		for i in lbls.size():
			var seg := PanelContainer.new()
			seg.name = "Seg%d" % i
			seg.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var sl := Kit.label(str(lbls[i]))
			sl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			sl.add_theme_font_override("font", ThemeLib.font("mono_bold"))
			sl.add_theme_font_size_override("font_size", 13)
			seg.add_child(sl)
			_segments.add_child(seg)
		var holder := PanelContainer.new()
		holder.name = "SegmentTrack"
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		holder.add_child(_segments)
		row.add_child(holder)
	else:
		var val_col := Kit.vbox(2)
		val_col.alignment = BoxContainer.ALIGNMENT_CENTER
		val_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var vrow := Kit.hbox(6)
		vrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_left = Icons.rect("chevron_left", 18, ThemeLib.color("text_3"))
		_right = Icons.rect("chevron_right", 18, ThemeLib.color("text_3"))
		vrow.add_child(_left)
		vrow.add_child(_value_label)
		vrow.add_child(_right)
		val_col.add_child(vrow)
		_dots = Kit.hbox(4)
		_dots.alignment = BoxContainer.ALIGNMENT_CENTER
		_dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# Every stepper gets its dots: one per value up to MAX_DOTS, past that
		# MAX_DOTS dots and the lit one follows the position proportionally.
		if values.size() > 1:
			for i in mini(values.size(), MAX_DOTS):
				var d := Panel.new()
				d.custom_minimum_size = Vector2(5, 5)
				d.mouse_filter = Control.MOUSE_FILTER_IGNORE
				_dots.add_child(d)
		val_col.add_child(_dots)
		row.add_child(val_col)

	_hint = Kit.label("", "QuietLabel", true)
	_hint.name = "Hint"
	add_child(_hint)
	_refresh()


## The lit dot for value `i` of `n` (proportional past MAX_DOTS).
static func dot_for(i: int, n: int) -> int:
	if n <= MAX_DOTS:
		return i
	return roundi(float(i) * (MAX_DOTS - 1) / float(maxi(1, n - 1)))


## Two to four values whose labels fit side by side: a segmented control.
static func segmented(lbls: Array) -> bool:
	if lbls.size() < 2 or lbls.size() > 4:
		return false
	var total := 0
	for l in lbls:
		var n := str(l).length()
		if n > 12:
			return false
		total += n
	return total <= 30


static func bool_row(setting_key: String, title: String, current: bool, icon := "") -> VBoxContainer:
	var r: VBoxContainer = load("res://scripts/ui/choice_row.gd").new()
	r.setup(setting_key, title, [false, true], ["Off", "On"], current, icon)
	return r


## Use `fn(value) -> String` for the explanation (rows whose words aren't in texts.gd).
func set_explainer(fn: Callable) -> void:
	explainer = fn
	_refresh()


func value() -> Variant:
	return values[index] if not values.is_empty() else null


## Show a value without emitting `changed` (e.g. a service reported it).
func set_value_quiet(v: Variant) -> void:
	var i := values.find(v)
	if i >= 0:
		index = i
		_refresh()


func step(d: int) -> void:
	if values.size() < 2 or locked:
		return
	index = posmod(index + d, values.size())
	_refresh(true)
	changed.emit(values[index])


func hint_text() -> String:
	return _hint.text


## A box right after the title for small chips (where a value comes from, a
## lock). The title stops stretching so the chips sit next to it.
func badge_slot() -> HBoxContainer:
	if _badge_box == null:
		_badge_box = Kit.hbox(6)
		_badge_box.name = "Badges"
		_badge_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_badge_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		title_label.size_flags_horizontal = Control.SIZE_FILL
		_row.add_child(_badge_box)
		_row.move_child(_badge_box, title_label.get_index() + 1)
		var gap := Kit.spacer()
		gap.name = "BadgeGap"
		_row.add_child(gap)
		_row.move_child(gap, _badge_box.get_index() + 1)
	return _badge_box


## Locked: the value shows dimmed and left / right / A do nothing.
func set_locked(on: bool) -> void:
	locked = on
	for c in _row.get_children():
		if c != title_label and c != _badge_box and c is CanvasItem and c.name != "BadgeGap":
			c.modulate.a = 0.45 if on else 1.0


func value_text() -> String:
	return _value_label.text


func _refresh(animate := false) -> void:
	var lbl: String = str(labels[index]) if index < labels.size() else str(value())
	_value_label.text = lbl
	if explainer.is_valid():
		_hint.text = str(explainer.call(value()))
	elif explain_fn.is_valid():
		_hint.text = str(explain_fn.call(key, value()))
	else:
		_hint.text = Texts.explain(key, value())
	var acc := ThemeLib.color("accent")
	if _is_bool:
		var on: bool = value() == true
		var track := ThemeLib.box(acc if on else ThemeLib.soft(0.22), 999, 0, 0)
		_switch.add_theme_stylebox_override("panel", track)
		_knob.add_theme_stylebox_override("panel", ThemeLib.box(ThemeLib.color("on_accent") if on else ThemeLib.color("text"), 999, 0, 0))
		Motion.to(_knob, "position:x", 23.0 if on else 3.0, Motion.FAST if animate else 0.0)
	elif _segments != null:
		var track: PanelContainer = _segments.get_parent()
		track.add_theme_stylebox_override("panel", ThemeLib.box(ThemeLib.soft(0.05), 8, 3, 3))
		for i in _segments.get_child_count():
			var seg: PanelContainer = _segments.get_child(i)
			var on := i == index
			var sb := ThemeLib.box(acc if on else ThemeLib.soft(0.07), 6, 10, 3)
			if on:
				sb.shadow_color = ThemeLib.color("glow")
				sb.shadow_size = 8
			seg.add_theme_stylebox_override("panel", sb)
			seg.get_child(0).add_theme_color_override("font_color", ThemeLib.color("on_accent") if on else ThemeLib.color("text_2"))
	elif _dots != null:
		var lit := dot_for(index, values.size())
		for i in _dots.get_child_count():
			var d: Panel = _dots.get_child(i)
			d.add_theme_stylebox_override("panel", ThemeLib.box(acc if i == lit else ThemeLib.soft(0.22), 999, 0, 0))
		var multi := values.size() > 1
		_left.visible = multi
		_right.visible = multi
	_refresh_focus()


func _refresh_focus() -> void:
	# Only the focused row explains itself; the rest stay compact. Focused,
	# the ring wraps the row and its explanation as one card (see _draw).
	var f := button.has_focus()
	_hint.visible = (f or not collapse_hint) and _hint.text != ""
	# Helper text is neutral: the accent belongs to focus and values.
	_hint.add_theme_color_override("font_color", ThemeLib.color("text_2"))
	# A line that always shows (collapse_hint off) sits inside the row's card
	# too, so it reads as part of the setting, not a loose caption.
	var carded := _hint.visible
	var sep := 0 if carded else 6
	if get_theme_constant("separation") != sep:
		_busy = true
		add_theme_constant_override("separation", sep)
		_busy = false
	if carded:
		for st in ["focus", "normal", "hover"]:
			button.add_theme_stylebox_override(st, StyleBoxEmpty.new())
		var pad := StyleBoxEmpty.new()
		pad.content_margin_left = 18
		pad.content_margin_right = 18
		pad.content_margin_bottom = 14
		_hint.add_theme_stylebox_override("normal", pad)
	else:
		for st in ["focus", "normal", "hover"]:
			button.remove_theme_stylebox_override(st)
		_hint.remove_theme_stylebox_override("normal")
		if card_box != null:
			button.add_theme_stylebox_override("normal", card_box)
			button.add_theme_stylebox_override("hover", card_box)
	queue_redraw()
	if _left == null:
		return
	var c: Color = ThemeLib.color("text") if f else ThemeLib.color("text_3")
	_left.texture = Icons.tex("chevron_left", 18, c)
	_right.texture = Icons.tex("chevron_right", 18, c)


func _draw() -> void:
	if button == null or not _hint.visible:
		return
	var r := Rect2(Vector2.ZERO, size)
	var th := button.theme_type_variation
	draw_style_box(card_box if card_box != null else get_theme_stylebox("normal", th if th != "" else &"Button"), r)
	if button.has_focus():
		draw_style_box(ThemeLib.row_focus(), r)


func _on_gui_input(event: InputEvent) -> void:
	if not step_on_pad:
		return
	if event.is_action_pressed("ui_left", true):
		step(-1)
		button.accept_event()
	elif event.is_action_pressed("ui_right", true):
		step(1)
		button.accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _value_label != null and not _busy:
		_busy = true
		_refresh()
		_busy = false
