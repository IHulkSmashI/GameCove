extends Control
## "Open on your phone": a QR code of a web page (a game's Metacritic or
## OpenCritic page, an artist's SteamGridDB profile) with its address, the
## way store sign-in hands a page to the phone. There's no browser in Gaming
## Mode, so this is how a source's page is opened. A or B closes it.
##
##   handoff.open("Metacritic", "Hades on Metacritic", "https://www.metacritic.com/game/hades")

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const QR := preload("res://scripts/ui/settings/qr.gd")

signal closed

var title_label: Label
var line_label: Label
var url_label: Label
var qr_rect: TextureRect
var done_button: Button
var url := ""
var _dim: ColorRect
var _focus_before: Control
var _open := false


func _init() -> void:
	name = "LinkHandoff"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_dim = ColorRect.new()
	_dim.name = "Dim"
	Kit.fill(_dim)
	_dim.color = Color(ThemeLib.color("scrim"), 0.7)
	add_child(_dim)
	var center := CenterContainer.new()
	center.name = "Center"
	Kit.fill(center)
	add_child(center)
	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.add_theme_stylebox_override("panel", ThemeLib.glass(ThemeLib.radius("xl"), 36, 32))
	center.add_child(panel)
	var row := Kit.hbox(32)
	panel.add_child(row)
	var frame := PanelContainer.new()
	frame.name = "QRFrame"
	frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	frame.add_theme_stylebox_override("panel", ThemeLib.box(Color.WHITE, ThemeLib.radius("l"), 10, 10))
	qr_rect = TextureRect.new()
	qr_rect.name = "QR"
	qr_rect.custom_minimum_size = Vector2(232, 232)
	qr_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	qr_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	qr_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	frame.add_child(qr_rect)
	row.add_child(frame)
	var col := Kit.vbox(12)
	col.custom_minimum_size = Vector2(380, 0)
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(col)
	title_label = Kit.label("", "EyebrowLabel")
	title_label.name = "Title"
	title_label.uppercase = true
	col.add_child(title_label)
	line_label = Kit.label("", "HeaderLabel", true)
	line_label.name = "Line"
	col.add_child(line_label)
	col.add_child(Kit.label("Scan the code with your phone's camera to open the page there.", "QuietLabel", true))
	url_label = Kit.label("", "CaptionLabel", true)
	url_label.name = "Url"
	url_label.add_theme_color_override("font_color", ThemeLib.color("text_3"))
	col.add_child(url_label)
	done_button = Kit.button("Done", "AccentButton")
	done_button.name = "Done"
	done_button.custom_minimum_size = Vector2(160, 52)
	done_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	done_button.pressed.connect(close)
	col.add_child(done_button)
	done_button.focus_neighbor_left = done_button.get_path_to(done_button)
	done_button.focus_neighbor_right = done_button.get_path_to(done_button)
	done_button.focus_neighbor_top = done_button.get_path_to(done_button)
	done_button.focus_neighbor_bottom = done_button.get_path_to(done_button)


func is_open() -> bool:
	return _open


func open(title: String, line: String, address: String) -> void:
	url = address
	title_label.text = title
	line_label.text = line
	url_label.text = address
	QR.show_on(qr_rect, address, 6)
	_open = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	if is_inside_tree():
		_focus_before = get_viewport().gui_get_focus_owner()
		Motion.fade(self, true)
		done_button.grab_focus()
	else:
		visible = true


func close() -> void:
	if not _open:
		return
	_open = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if is_inside_tree():
		Motion.fade(self, false)
		if is_instance_valid(_focus_before) and _focus_before.is_inside_tree():
			_focus_before.grab_focus()
	else:
		visible = false
	closed.emit()


func _input(event: InputEvent) -> void:
	if not _open:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


static func hints() -> Array:
	return [["A", "Done"], ["B", "Close"]]
