extends Control
## Pairing with a PC: dims everything and shows a glass sheet with three short
## steps on the left and the PIN in four big mono boxes on the right, with
## "Waiting for your PC…" under it. It moves on by itself when the service says
## "paired" (a check, the PC's name and the permissions reminder; A = Done) or
## "failed" (why, and A = New PIN). B cancels while waiting.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const SIcons := preload("res://scripts/ui/streaming/stream_icons.gd")
const T := preload("res://scripts/ui/texts_streaming.gd")

signal cancel_requested
signal retry_requested
signal done

const WIDTH := 900.0

var state := "closed"   # waiting | paired | failed | closed
var host_name := ""
var pin := ""
var panel: PanelContainer
var title_label: Label
var steps_box: VBoxContainer
var digits: Array = []
var status_label: Label
var status_icon: TextureRect
var note_label: Label
var action: Button
var _dim: ColorRect
var _pin_row: HBoxContainer
var _focus_before: Control


func _init() -> void:
	name = "PairSheet"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_dim = ColorRect.new()
	Kit.fill(_dim)
	add_child(_dim)
	panel = PanelContainer.new()
	panel.name = "Panel"
	panel.theme_type_variation = "GlassPanel"
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -WIDTH / 2.0
	panel.offset_right = WIDTH / 2.0
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(panel)
	var col := Kit.vbox(22)
	panel.add_child(col)
	var head := Kit.hbox(14)
	head.add_child(SIcons.rect("link", 28, ThemeLib.color("accent")))
	title_label = Kit.label("", "HeaderLabel")
	title_label.name = "Title"
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title_label)
	col.add_child(head)
	var body := Kit.hbox(36)
	col.add_child(body)
	steps_box = Kit.vbox(16)
	steps_box.name = "Steps"
	steps_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	steps_box.size_flags_stretch_ratio = 1.1
	body.add_child(steps_box)
	var right := Kit.vbox(16)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.alignment = BoxContainer.ALIGNMENT_CENTER
	body.add_child(right)
	var eyebrow := Kit.label(T.PAIR_ENTER, "EyebrowLabel")
	eyebrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	right.add_child(eyebrow)
	_pin_row = Kit.hbox(12)
	_pin_row.name = "Pin"
	_pin_row.alignment = BoxContainer.ALIGNMENT_CENTER
	right.add_child(_pin_row)
	for i in 4:
		var box := PanelContainer.new()
		box.custom_minimum_size = Vector2(76, 96)
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var d := Kit.label("")
		d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		d.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		d.add_theme_font_override("font", ThemeLib.font("mono_bold"))
		d.add_theme_font_size_override("font_size", 56)
		box.add_child(d)
		_pin_row.add_child(box)
		digits.append(d)
	var srow := Kit.hbox(10)
	srow.alignment = BoxContainer.ALIGNMENT_CENTER
	status_icon = TextureRect.new()
	status_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	status_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	srow.add_child(status_icon)
	status_label = Kit.label("", "QuietLabel")
	status_label.name = "Status"
	srow.add_child(status_label)
	right.add_child(srow)
	note_label = Kit.label("", "QuietLabel", true)
	note_label.name = "Note"
	note_label.add_theme_font_size_override("font_size", ThemeLib.SIZE_CAPTION)
	col.add_child(note_label)
	var foot := Kit.hbox(12)
	foot.alignment = BoxContainer.ALIGNMENT_END
	action = Kit.primary(T.H_CANCEL, "A")
	action.name = "Action"
	action.pressed.connect(_on_action)
	foot.add_child(action)
	col.add_child(foot)
	_restyle()


func _restyle() -> void:
	_dim.color = Color(ThemeLib.color("scrim"), 0.80)
	for d in digits:
		var box: PanelContainer = d.get_parent()
		var sb := ThemeLib.box(ThemeLib.color("surface_2"), ThemeLib.radius("l"), 0, 0)
		sb.border_color = Color(ThemeLib.color("accent"), 0.55)
		sb.set_border_width_all(2)
		box.add_theme_stylebox_override("panel", sb)
		d.add_theme_color_override("font_color", ThemeLib.color("text"))


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _dim != null:
		_restyle()


func open_waiting(name_text: String, pin_text: String, url: String) -> void:
	host_name = name_text
	pin = pin_text
	state = "waiting"
	title_label.text = T.PAIR_TITLE % name_text
	_steps([T.PAIR_STEPS[0], T.PAIR_STEPS[1], T.PAIR_STEPS[2]], url)
	for i in 4:
		digits[i].text = pin_text[i] if i < pin_text.length() else ""
	_pin_row.modulate.a = 1.0
	_status(T.PAIR_WAITING, "clock", "text_2")
	note_label.text = T.PAIR_PERMS
	note_label.visible = true
	action.text = T.H_CANCEL
	_show()


func show_paired() -> void:
	state = "paired"
	_status(T.PAIR_DONE % host_name, "check", "good")
	_pin_row.modulate.a = 0.35
	note_label.text = T.PAIR_PERMS
	action.text = "Done"
	_show()


func show_failed(why: String) -> void:
	state = "failed"
	title_label.text = T.PAIR_FAILED_TITLE
	_status(why, "alert", "warn")
	_pin_row.modulate.a = 0.35
	action.text = T.PAIR_NEW_PIN
	_show()


func _status(text: String, icon: String, tone: String) -> void:
	status_label.text = text
	var c: Color = ThemeLib.color(tone) if tone in ["text_2"] else ThemeLib.tone(tone)
	status_icon.texture = SIcons.tex(icon, 20, c)
	status_label.add_theme_color_override("font_color", c if tone != "text_2" else ThemeLib.color("text_2"))


func _steps(lines: Array, url := "") -> void:
	for c in steps_box.get_children():
		Kit.drop(steps_box, c)
	for i in lines.size():
		var row := Kit.hbox(14)
		var num := PanelContainer.new()
		num.custom_minimum_size = Vector2(34, 34)
		num.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		num.add_theme_stylebox_override("panel", ThemeLib.box(Color(ThemeLib.color("accent"), 0.16), 999, 0, 0))
		var n := Kit.label(str(i + 1))
		n.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		n.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		n.add_theme_font_override("font", ThemeLib.font("mono_bold"))
		n.add_theme_color_override("font_color", ThemeLib.color("accent"))
		num.add_child(n)
		row.add_child(num)
		var texts := Kit.vbox(4)
		texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var l := Kit.label(str(lines[i]), "", true)
		l.add_theme_font_size_override("font_size", ThemeLib.SIZE_SMALL)
		texts.add_child(l)
		if i == 0 and url != "":
			var u := Kit.label(url, "MonoLabel")
			u.name = "Url"
			u.add_theme_color_override("font_color", ThemeLib.color("accent"))
			u.add_theme_font_override("font", ThemeLib.font("mono_bold"))
			texts.add_child(u)
		row.add_child(texts)
		steps_box.add_child(row)


func _show() -> void:
	if not visible:
		if is_inside_tree():
			_focus_before = get_viewport().gui_get_focus_owner()
		Motion.fade(self, true)
		panel.scale = Vector2.ONE * (1.0 if Motion.reduce else 0.97)
		panel.pivot_offset = Vector2(WIDTH / 2.0, 200)
		Motion.to(panel, "scale", Vector2.ONE, Motion.BASE)
	if is_inside_tree():
		action.grab_focus()


func close() -> void:
	if state == "closed":
		return
	state = "closed"
	Motion.fade(self, false)
	if _focus_before != null and is_instance_valid(_focus_before) and _focus_before.is_visible_in_tree():
		_focus_before.grab_focus()


func is_open() -> bool:
	return state != "closed"


func _on_action() -> void:
	match state:
		"waiting":
			cancel_requested.emit()
		"failed":
			retry_requested.emit()
		"paired":
			done.emit()


func _input(event: InputEvent) -> void:
	if state == "closed":
		return
	if event.is_action_pressed("ui_cancel"):
		if state == "waiting":
			cancel_requested.emit()
		else:
			done.emit()
		get_viewport().set_input_as_handled()


func hints() -> Array:
	match state:
		"waiting": return [["A", T.H_CANCEL]]
		"failed": return [["A", T.PAIR_NEW_PIN], ["B", T.H_BACK]]
	return [["A", "Done"], ["B", T.H_BACK]]
