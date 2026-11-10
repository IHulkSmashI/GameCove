extends Control
## A readable full-height drawer over the game page for the Steam insights
## card: patch notes (Steam BBCode made safe by insights_api.gd), the DLC
## list, or a QR code handing a link (SteamDB) to the phone, like the store
## sign-in does. Up/down (stick or d-pad) scroll, B closes. Nothing in it
## opens anything on the handheld.
##
##   overlay.open_text("Last update", "Patch 1.16.1 · 16 Dec 2025", bbcode)
##   overlay.open_qr("Open on SteamDB", "https://steamdb.info/app/620/", line, note)

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const QR := preload("res://scripts/ui/settings/qr.gd")
const TI := preload("res://scripts/ui/texts_insights.gd")

signal closed

const WIDTH := 720.0
const STEP := 90.0

var mode := ""
var panel: PanelContainer
var title_label: Label
var sub_label: Label
var scroll: ScrollContainer
var body: RichTextLabel
var qr_box: VBoxContainer
var qr_rect: TextureRect
var url_label: Label
var qr_line: Label
var qr_note: Label
var hints: HBoxContainer
var _dim: ColorRect
var _focus_before: Control
var _open := false


func _init() -> void:
	name = "InsightsOverlay"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_dim = ColorRect.new()
	_dim.name = "Dim"
	Kit.fill(_dim)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_dim.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed:
			close())
	add_child(_dim)
	panel = PanelContainer.new()
	panel.name = "Panel"
	panel.theme_type_variation = "GlassPanel"
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -WIDTH
	panel.offset_bottom = -ThemeLib.HINT_BAR_H
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	add_child(panel)
	var col := Kit.vbox(16)
	panel.add_child(col)
	title_label = Kit.label("", "EyebrowLabel", true)
	title_label.name = "Title"
	title_label.uppercase = true
	col.add_child(title_label)
	sub_label = Kit.label("", "HeaderLabel", true)
	sub_label.name = "Sub"
	col.add_child(sub_label)
	scroll = ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)
	body = RichTextLabel.new()
	body.name = "Body"
	body.bbcode_enabled = true
	body.fit_content = true
	body.scroll_active = false
	body.selection_enabled = false
	body.meta_underlined = false
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_color_override("default_color", ThemeLib.color("text_2"))
	body.add_theme_constant_override("line_separation", 6)
	scroll.add_child(body)
	qr_box = Kit.vbox(14)
	qr_box.name = "QrBox"
	qr_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	qr_box.alignment = BoxContainer.ALIGNMENT_CENTER
	qr_line = Kit.label("", "QuietLabel", true)
	qr_line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	qr_box.add_child(qr_line)
	qr_rect = TextureRect.new()
	qr_rect.name = "Qr"
	qr_rect.custom_minimum_size = Vector2(300, 300)
	qr_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	qr_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	qr_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	qr_box.add_child(qr_rect)
	url_label = Kit.label("", "LeadLabel", true)
	url_label.name = "Url"
	url_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	url_label.add_theme_font_override("font", ThemeLib.mono(true, 1))
	qr_box.add_child(url_label)
	qr_note = Kit.label("", "CaptionLabel", true)
	qr_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	qr_note.add_theme_color_override("font_color", ThemeLib.color("text_3"))
	qr_box.add_child(qr_note)
	col.add_child(qr_box)
	hints = Kit.prompts([["B", TI.CLOSE]])
	hints.name = "Hints"
	col.add_child(hints)
	_restyle()


func _restyle() -> void:
	_dim.color = Color(ThemeLib.color("scrim"), 0.62)
	var g := ThemeLib.glass(ThemeLib.radius("xl"), 36, 32)
	g.corner_radius_top_right = 0
	g.corner_radius_bottom_right = 0
	g.border_width_right = 0
	g.bg_color = ThemeLib.color("surface")
	panel.add_theme_stylebox_override("panel", g)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _dim != null:
		_restyle()


## Long text (patch notes, the DLC list): `bbcode` must already be safe
## (insights_api.bbcode_to_rich or built from escaped strings).
func open_text(title: String, subtitle: String, bbcode: String) -> void:
	mode = "text"
	body.text = bbcode
	scroll.visible = true
	qr_box.visible = false
	_replace_hints([["DPAD", TI.SCROLL], ["B", TI.CLOSE]])
	_show(title, subtitle)
	scroll.scroll_vertical = 0


## A link for the phone: a QR code plus the address written out.
func open_qr(title: String, url: String, line: String, note := "") -> void:
	mode = "qr"
	qr_rect.texture = QR.texture(url, 6)
	url_label.text = url
	qr_line.text = line
	qr_note.text = note
	qr_note.visible = note != ""
	scroll.visible = false
	qr_box.visible = true
	_replace_hints([["B", TI.CLOSE]])
	_show(title, "")


func _replace_hints(list: Array) -> void:
	var parent := hints.get_parent()
	var i := hints.get_index()
	Kit.drop(parent, hints)
	hints = Kit.prompts(list)
	hints.name = "Hints"
	parent.add_child(hints)
	parent.move_child(hints, i)


func _show(title: String, subtitle: String) -> void:
	title_label.text = title
	sub_label.text = subtitle
	sub_label.visible = subtitle != ""
	if is_inside_tree():
		_focus_before = get_viewport().gui_get_focus_owner()
		if _focus_before != null:
			_focus_before.release_focus()
	_open = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	Motion.fade(self, true)
	var dx := Motion.slide(40.0)
	panel.offset_left = -WIDTH + dx
	panel.offset_right = dx
	Motion.to(panel, "offset_left", -WIDTH, Motion.FAST)
	Motion.to(panel, "offset_right", 0.0, Motion.FAST)


func is_open() -> bool:
	return _open


func close() -> void:
	if not _open:
		return
	_open = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	Motion.fade(self, false)
	closed.emit()
	if _focus_before != null and is_instance_valid(_focus_before) and _focus_before.is_visible_in_tree():
		_focus_before.grab_focus()


## Scroll by `steps` (positive = down).
func scroll_by(steps: int) -> void:
	scroll.scroll_vertical = int(scroll.scroll_vertical + steps * STEP)


func _input(event: InputEvent) -> void:
	if not _open or event is InputEventMouseMotion:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
	elif event.is_action_pressed("ui_down", true):
		scroll_by(1)
	elif event.is_action_pressed("ui_up", true):
		scroll_by(-1)
	# the page behind stays put while the drawer is open
	if is_inside_tree():
		get_viewport().set_input_as_handled()
