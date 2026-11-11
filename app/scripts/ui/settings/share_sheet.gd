extends Control
## "Send to phone": a QR code for the clip's one-time page (clip_drop.gd) with
## the steps beside it and how long the page stays open. B closes it (and the
## page). Closes by itself once the phone has downloaded the clip.
## Only runs (the page and its countdown) while it's open.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const QR := preload("res://scripts/ui/settings/qr.gd")
const ClipDrop := preload("res://scripts/system/clip_drop.gd")
const Clips := preload("res://scripts/system/clips.gd")
const TX := preload("res://scripts/ui/texts_extras.gd")

## A result for a toast: text, tone.
signal finished(text: String, tone: String)

var drop: Node
## Tests: the network list the page picks its address from.
var interfaces_fn: Callable = func() -> Array: return IP.get_local_interfaces()
## Tests: listen here instead of the LAN address ("" = pick it).
var bind_address := ""
var panel: PanelContainer
var qr_rect: TextureRect
var title_label: Label
var left_label: Label
var _dim: ColorRect
var _open := false
var _focus_before: Control
var _close_button: Button
var _shown_left := -1


func _init() -> void:
	name = "ShareSheet"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	_dim = ColorRect.new()
	_dim.name = "Dim"
	Kit.fill(_dim)
	add_child(_dim)
	panel = PanelContainer.new()
	panel.name = "Panel"
	panel.theme_type_variation = "GlassPanel"
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(panel)
	var row := Kit.hbox(28)
	panel.add_child(row)
	qr_rect = TextureRect.new()
	qr_rect.name = "QR"
	qr_rect.custom_minimum_size = Vector2(264, 264)
	qr_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	qr_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	qr_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	qr_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(qr_rect)
	var col := Kit.vbox(12)
	col.custom_minimum_size = Vector2(380, 0)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	var eyebrow := Kit.label(TX.SHARE_TITLE, "EyebrowLabel")
	eyebrow.uppercase = true
	col.add_child(eyebrow)
	title_label = Kit.label("", "HeaderLabel", true)
	title_label.name = "ClipTitle"
	col.add_child(title_label)
	col.add_child(Kit.label(TX.SHARE_STEPS, "QuietLabel", true))
	var wifi := Kit.icon_label("wifi", TX.SHARE_SAME_WIFI, "QuietLabel", ThemeLib.color("text_2"), 18, false)
	col.add_child(wifi)
	left_label = Kit.label("", "MonoLabel", true)
	left_label.name = "Left"
	col.add_child(left_label)
	_close_button = Kit.secondary("Close", "x")
	_close_button.name = "Close"
	_close_button.custom_minimum_size = Vector2(0, 48)
	_close_button.pressed.connect(close)
	col.add_child(_close_button)
	row.add_child(col)
	_restyle()


func _restyle() -> void:
	_dim.color = Color(ThemeLib.color("scrim"), 0.7)
	panel.add_theme_stylebox_override("panel", ThemeLib.glass(ThemeLib.radius("xl"), 32, 28))


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _dim != null:
		_restyle()


func is_open() -> bool:
	return _open


## Opens the page for `clip` and shows its QR code. False (and a toast) when
## there's no network to serve it on.
func open_for(clip: Dictionary) -> bool:
	if drop == null:
		drop = ClipDrop.new()
		drop.interfaces_fn = interfaces_fn
		drop.bind_address = bind_address
		drop.sent.connect(_on_sent)
		drop.expired.connect(func(_why): _finish(TX.SHARE_EXPIRED, ""))
		add_child(drop)
	if not drop.start(str(clip.get("path", "")), Clips.title_of(clip)):
		finished.emit(TX.SHARE_OFFLINE, "bad")
		return false
	title_label.text = Clips.title_of(clip)
	QR.show_on(qr_rect, drop.url, 6)
	_shown_left = -1
	_update_left()
	if is_inside_tree():
		_focus_before = get_viewport().gui_get_focus_owner()
	_open = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	Motion.fade(self, true)
	set_process(true)
	if is_inside_tree():
		_close_button.grab_focus()
	return true


func _process(_delta: float) -> void:
	_update_left()


func _update_left() -> void:
	var s: int = drop.seconds_left() if drop != null else 0
	if s == _shown_left:
		return
	_shown_left = s
	left_label.text = TX.SHARE_LEFT % [s / 60, s % 60]


func _on_sent() -> void:
	_finish(TX.SHARE_SENT, "good")


func _finish(text: String, tone: String) -> void:
	close()
	finished.emit(text, tone)


func close() -> void:
	if drop != null:
		drop.stop()
	if not _open:
		return
	_open = false
	set_process(false)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	Motion.fade(self, false)
	if _focus_before != null and is_instance_valid(_focus_before) and _focus_before.is_visible_in_tree():
		_focus_before.grab_focus()


func _input(event: InputEvent) -> void:
	if _open and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
