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
const Drawer := preload("res://scripts/ui/drawer.gd")
const FadeMask := preload("res://scripts/ui/fade_mask.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const GameIcons := preload("res://scripts/ui/games/game_icons.gd")

signal chosen(id: String)
signal closed

const WIDTH := 560.0
const Z := 15

var items: Array = []
var rows: Array = []
var title_label: Label
var sub_label: Label
var panel: PanelContainer
## What the buttons do, at the drawer's foot (it covers the screen's hint bar).
var prompts: HBoxContainer
var _list: VBoxContainer
var _scroll: ScrollContainer
var _dim: ColorRect
var _callback := Callable()
var _focus_before: Control
var _open := false


func _init() -> void:
	name = "Sheet"
	# Over the screen's hint bar (the drawer runs the full height and carries
	# its own prompts); dialogs that must win sit higher (keep 20, battery 30).
	z_index = Z
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
	# The same drawer as the quick menu (drawer.gd): the full height, floating
	# against the edge, its prompts at its own foot.
	Drawer.place(panel, WIDTH)
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
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	FocusScroll.attach(_scroll)
	col.add_child(_scroll)
	# More rows than fit (a long list on a small screen) fade out at the foot.
	FadeMask.wrap(_scroll, 20.0)
	_list = Kit.vbox(6)
	_list.name = "Rows"
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_list)
	prompts = Kit.prompts(hints())
	col.add_child(prompts)
	_restyle()


func _restyle() -> void:
	_dim.color = Drawer.scrim()
	panel.add_theme_stylebox_override("panel", Drawer.glass(32, 28))


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
	_scroll.scroll_vertical = 0
	if is_inside_tree():
		_focus_before = get_viewport().gui_get_focus_owner()
	_open = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	Motion.fade(self, true)
	var dx := Motion.slide(40.0)
	panel.offset_left = -WIDTH - Drawer.MARGIN + dx
	panel.offset_right = -Drawer.MARGIN + dx
	Motion.to(panel, "offset_left", -WIDTH - Drawer.MARGIN, Motion.FAST)
	Motion.to(panel, "offset_right", -Drawer.MARGIN, Motion.FAST)
	var f: Control = first if first != null else (rows[0] if not rows.is_empty() else null)
	if f != null and is_inside_tree():
		f.grab_focus()


func _row(it: Dictionary) -> Button:
	var b := Kit.button("", "RowButton")
	b.name = "Row_" + str(it.get("id", "x")).validate_node_name()
	var detail := str(it.get("detail", ""))
	# A line under the name wraps onto a second line when it's long (never an
	# ellipsis mid-word); the row grows to hold it.
	var wraps := detail != "" and _detail_width(detail) > _detail_room(it)
	b.custom_minimum_size = Vector2(0, (82 if wraps else 62) if detail != "" else 52)
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
		if wraps:
			d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			d.max_lines_visible = 2
			d.add_theme_constant_override("line_spacing", 0)
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


## Width of a row's detail line set on one line, px.
static func _detail_width(detail: String) -> float:
	return ThemeLib.font("regular").get_string_size(detail, HORIZONTAL_ALIGNMENT_LEFT, -1, ThemeLib.SIZE_CAPTION).x


## Room a row has for its texts, px: the drawer less its padding, the row's
## own, the icon, the value and the tick.
static func _detail_room(it: Dictionary) -> float:
	var room := WIDTH - 2.0 * 32.0 - 18.0 - 16.0
	if str(it.get("icon", "")) != "":
		room -= 22.0 + 14.0
	var value := str(it.get("value", ""))
	if value != "":
		room -= ThemeLib.font("medium", true).get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, ThemeLib.SIZE_CAPTION).x + 14.0
	if it.get("current", false):
		room -= 22.0 + 14.0
	return room - 4.0


## Choose a row by id (what A on that row does).
func pick(id: String) -> void:
	var cb := _callback
	close(false)
	chosen.emit(id)
	if cb.is_valid():
		cb.call(id)


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
