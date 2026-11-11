extends Control
## A modal choice sheet: dims the screen and slides a glass drawer in from
## the right edge with a title, a line under it and a list of rows. A picks,
## B closes. Used for the Manage
## menu, install / move location, compatibility tool and confirmations.
##
##   sheet.open("Where should it go?", "Pick a drive.", [
##       {"id": "/home/deck/Games", "text": "Internal storage", "detail": "212 GB free",
##        "icon": "drive", "value": "", "current": false, "tone": "", "disabled": false},
##   ], func(id): ...)
##
## Disabled rows stay focusable so their reason (detail) can be read.

const FocusScroll := preload("res://scripts/ui/focus_scroll.gd")
const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const GameIcons := preload("res://scripts/ui/games/game_icons.gd")

signal chosen(id: String)
signal closed
## A pick closed the sheet and the control it was opened from is gone (the
## pick rebuilt it, e.g. Install turning into Pause): the host puts focus back.
signal focus_lost

const WIDTH := 560.0
const MAX_ROWS := 9

var items: Array = []
var rows: Array = []
var title_label: Label
var sub_label: Label
var panel: PanelContainer
var _list: VBoxContainer
var _scroll: ScrollContainer
var _dim: ColorRect
var _callback := Callable()
var _focus_before: Control
var _open := false


func _init() -> void:
	name = "Sheet"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_dim = ColorRect.new()
	_dim.name = "Dim"
	Kit.fill(_dim)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dim)
	panel = PanelContainer.new()
	panel.name = "Panel"
	panel.theme_type_variation = "GlassPanel"
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_top = 0.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -WIDTH
	panel.offset_right = 0.0
	panel.offset_top = 0.0
	# The hint bar stays in view under the drawer.
	panel.offset_bottom = -ThemeLib.HINT_BAR_H
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	add_child(panel)
	var col := Kit.vbox(18)
	panel.add_child(col)
	var head := Kit.vbox(6)
	title_label = Kit.label("", "EyebrowLabel", true)
	title_label.uppercase = true
	title_label.name = "Title"
	head.add_child(title_label)
	sub_label = Kit.label("", "HeaderLabel", true)
	sub_label.name = "Sub"
	head.add_child(sub_label)
	col.add_child(head)
	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	FocusScroll.attach(_scroll)
	col.add_child(_scroll)
	_list = Kit.vbox(6)
	_list.name = "Rows"
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_list)
	_restyle()


func _restyle() -> void:
	var sc: Color = ThemeLib.color("scrim")
	_dim.color = Color(sc, 0.62)
	# A drawer: square on the screen edge, rounded where it meets the page.
	var g := ThemeLib.glass(ThemeLib.radius("xl"), 32, 32)
	g.corner_radius_top_right = 0
	g.corner_radius_bottom_right = 0
	g.border_width_right = 0
	g.bg_color = ThemeLib.color("surface")
	panel.add_theme_stylebox_override("panel", g)


## Short lines (a game's name) read as the headline under a mono eyebrow;
## longer ones (a question's explanation) as a plain line under a headline.
func _style_head(subtitle: String) -> void:
	var short := subtitle != "" and subtitle.length() <= 34 and not subtitle.ends_with(".")
	title_label.theme_type_variation = "EyebrowLabel" if short else "HeaderLabel"
	title_label.uppercase = true
	sub_label.theme_type_variation = "HeaderLabel" if short else "QuietLabel"
	sub_label.uppercase = short
	if short:
		title_label.get_parent().move_child(title_label, 0)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _dim != null:
		_restyle()


func open(title: String, subtitle: String, list: Array, on_choose: Callable = Callable()) -> void:
	_callback = on_choose
	items = list
	title_label.text = title
	sub_label.text = subtitle
	sub_label.visible = subtitle != ""
	_style_head(subtitle)
	for r in rows:
		Kit.drop(_list, r)
	rows.clear()
	var first: Control = null
	for it in list:
		var b := _row(it)
		_list.add_child(b)
		rows.append(b)
		if first == null and not it.get("disabled", false):
			first = b
		if it.get("current", false):
			first = b
	Kit.link_vertical(rows)
	# Up to MAX_ROWS rows show; more scroll.
	var h := 0.0
	for i in mini(rows.size(), MAX_ROWS):
		h += rows[i].custom_minimum_size.y + 6.0
	_scroll.custom_minimum_size = Vector2(0, h - 6.0)
	if is_inside_tree():
		_focus_before = get_viewport().gui_get_focus_owner()
	_open = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	Motion.fade(self, true)
	var dx := Motion.slide(40.0)
	panel.offset_left = -WIDTH + dx
	panel.offset_right = dx
	Motion.to(panel, "offset_left", -WIDTH, Motion.FAST)
	Motion.to(panel, "offset_right", 0.0, Motion.FAST)
	var f: Control = first if first != null else (rows[0] if not rows.is_empty() else null)
	if f != null and is_inside_tree():
		f.grab_focus()


func _row(it: Dictionary) -> Button:
	var b := Kit.button("", "RowButton")
	b.name = "Row_" + str(it.get("id", "x")).validate_node_name()
	var detail := str(it.get("detail", ""))
	b.custom_minimum_size = Vector2(0, 62 if detail != "" else 52)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var disabled: bool = it.get("disabled", false)
	var tone := str(it.get("tone", ""))
	var main_col: Color = ThemeLib.color("text_3") if disabled else (ThemeLib.color(tone) if tone in ["bad", "warn", "good"] else ThemeLib.color("text"))
	if tone == "bad" and not disabled:
		var bad: Color = ThemeLib.color("bad")
		for st in ["normal", "hover"]:
			var sb := ThemeLib.box(Color(bad, 0.10 if st == "normal" else 0.16), ThemeLib.radius("m"), 18, 10)
			sb.border_color = Color(bad, 0.45)
			sb.set_border_width_all(1)
			b.add_theme_stylebox_override(st, sb)
	var row := Kit.hbox(14)
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 18
	row.offset_right = -16
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(row)
	if str(it.get("icon", "")) != "":
		row.add_child(GameIcons.rect(it["icon"], 22, main_col if disabled or tone != "" else ThemeLib.color("text_2")))
	var texts := Kit.vbox(0)
	texts.alignment = BoxContainer.ALIGNMENT_CENTER
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := Kit.label(str(it.get("text", "")))
	l.name = "Text"
	l.add_theme_color_override("font_color", main_col)
	l.add_theme_font_override("font", ThemeLib.font("medium"))
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	texts.add_child(l)
	if detail != "":
		var d := Kit.label(detail, "QuietLabel")
		d.name = "Detail"
		d.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		d.add_theme_font_size_override("font_size", ThemeLib.SIZE_CAPTION)
		if disabled:
			d.add_theme_color_override("font_color", ThemeLib.color("text_3"))
		texts.add_child(d)
	row.add_child(texts)
	if str(it.get("value", "")) != "":
		var v := Kit.label(str(it["value"]), "CaptionLabel")
		v.name = "Value"
		v.add_theme_font_override("font", ThemeLib.font("medium", true))
		v.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(v)
	if it.get("current", false):
		row.add_child(GameIcons.rect("check", 22, ThemeLib.color("accent")))
	var id := str(it.get("id", ""))
	b.pressed.connect(func():
		if not disabled:
			pick(id))
	return b


## Choose a row by id (what A on that row does). Focus goes back to where the
## sheet was opened from, unless the pick opened another sheet or moved focus
## itself; when that control is gone, `focus_lost` asks the host.
func pick(id: String) -> void:
	var cb := _callback
	close(false)
	# Focus goes back first, so whatever the pick opens (a confirmation, Steam's
	# card, the keyboard) remembers the control the sheet came from, not a row
	# of a sheet that's gone, and gives focus back there when it closes.
	var back := _focus_before
	if back != null and is_instance_valid(back) and back.is_visible_in_tree():
		back.grab_focus()
	elif is_inside_tree():
		# that control was rebuilt meanwhile: nothing of this sheet keeps focus
		var row := get_viewport().gui_get_focus_owner()
		if row != null and is_ancestor_of(row):
			row.release_focus()
	chosen.emit(id)
	if cb.is_valid():
		cb.call(id)
	if _open or not is_inside_tree():
		return
	var f := get_viewport().gui_get_focus_owner()
	if f != null and not is_ancestor_of(f) and f.is_visible_in_tree() and not f.is_queued_for_deletion():
		return
	_focus_before = back
	if _focus_before != null and is_instance_valid(_focus_before) and _focus_before.is_visible_in_tree():
		_focus_before.grab_focus()
	else:
		if f != null:
			f.release_focus()
		focus_lost.emit()


func close(restore_focus := true) -> void:
	if not _open:
		return
	_open = false
	_callback = Callable()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	Motion.fade(self, false)
	closed.emit()
	if restore_focus and _focus_before != null and is_instance_valid(_focus_before) and _focus_before.is_visible_in_tree():
		_focus_before.grab_focus()


func is_open() -> bool:
	return _open


func _input(event: InputEvent) -> void:
	if not _open:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


static func hints() -> Array:
	return [["A", "Select"], ["B", "Close"]]
