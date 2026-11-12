extends Control
## Stream settings: a drawer from the right like the other sheets, with choice
## rows for one PC (or, opened from an app, a switch to give that app its own
## settings), and at the bottom what the stream will be after matching this
## screen, decoder and PC ("1920x1200 · 120 fps · AV1 · 46 Mb/s"). Rows save as
## they change; B closes.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const ChoiceRow := preload("res://scripts/ui/choice_row.gd")
const Settings := preload("res://scripts/streaming/stream_settings.gd")
const T := preload("res://scripts/ui/texts_streaming.gd")

signal closed

const WIDTH := 600.0
const ORDER := ["resolution", "fps", "quality", "codec", "hdr", "frame_pacing", "vsync", "audio", "audio_on_host", "performance_overlay", "swap_gamepad_buttons"]

var service: Object
var host_id := ""
var app: Dictionary = {}
var rows := {}
var own_row: VBoxContainer
var panel: PanelContainer
var eyebrow: Label
var title: Label
var summary: Label
var _list: VBoxContainer
var _scroll: ScrollContainer
var _dim: ColorRect
var _open := false
var _focus_before: Control


func _init() -> void:
	name = "StreamSettings"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_dim = ColorRect.new()
	Kit.fill(_dim)
	add_child(_dim)
	panel = PanelContainer.new()
	panel.name = "Panel"
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -WIDTH
	panel.offset_bottom = -ThemeLib.HINT_BAR_H
	add_child(panel)
	var col := Kit.vbox(14)
	panel.add_child(col)
	eyebrow = Kit.label(T.SETTINGS_TITLE, "EyebrowLabel")
	col.add_child(eyebrow)
	title = Kit.label("", "HeaderLabel", true)
	title.name = "Title"
	col.add_child(title)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.follow_focus = true
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(_scroll)
	_list = Kit.vbox(6)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_list)
	var foot := PanelContainer.new()
	foot.name = "Summary"
	foot.add_theme_stylebox_override("panel", ThemeLib.box(ThemeLib.soft(0.06), ThemeLib.radius("m"), 16, 12))
	summary = Kit.label("", "MonoLabel", true)
	summary.add_theme_color_override("font_color", ThemeLib.color("accent"))
	foot.add_child(summary)
	col.add_child(foot)
	_restyle()


func _restyle() -> void:
	_dim.color = Color(ThemeLib.color("scrim"), 0.62)
	var g := ThemeLib.glass(ThemeLib.radius("xl"), 32, 28)
	g.corner_radius_top_right = 0
	g.corner_radius_bottom_right = 0
	g.border_width_right = 0
	g.bg_color = ThemeLib.color("surface")
	panel.add_theme_stylebox_override("panel", g)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _dim != null:
		_restyle()


## For a PC (app = {}) or one app on it.
func open(svc: Object, id: String, for_app := {}) -> void:
	service = svc
	host_id = id
	app = for_app
	var hname: String = svc.display_name(svc.host(id))
	title.text = (T.SETTINGS_FOR_APP % str(app["title"])) if not app.is_empty() else (T.SETTINGS_FOR_PC % hname)
	_build()
	if is_inside_tree():
		_focus_before = get_viewport().gui_get_focus_owner()
	_open = true
	Motion.fade(self, true)
	var dx := Motion.slide(40.0)
	panel.offset_left = -WIDTH + dx
	panel.offset_right = dx
	Motion.to(panel, "offset_left", -WIDTH, Motion.FAST)
	Motion.to(panel, "offset_right", 0.0, Motion.FAST)
	var first: Control = own_row.button if own_row != null else rows[ORDER[0]].button
	if is_inside_tree():
		first.grab_focus()


func _app_id() -> int:
	return int(app.get("id", 0))


## The app edits its own layer only while "Own settings" is on.
func _editing_app() -> bool:
	return not app.is_empty() and service.has_app_picks(host_id, _app_id())


func _build() -> void:
	for c in _list.get_children():
		Kit.drop(_list, c)
	rows.clear()
	own_row = null
	var buttons: Array = []
	if not app.is_empty():
		own_row = ChoiceRow.bool_row("own", T.APP_OWN, service.has_app_picks(host_id, _app_id()))
		own_row.set_explainer(func(v): return "" if v else T.APP_OWN_LINE)
		own_row.changed.connect(func(v):
			service.set_app_override(host_id, _app_id(), bool(v))
			_refresh_values())
		_list.add_child(own_row)
		buttons.append(own_row.button)
	var p: Dictionary = service.effective_picks(host_id, _app_id())
	var hdr_ok: bool = service.hdr_available(host_id)
	for key in ORDER:
		var vals: Array
		var labels: Array
		match key:
			"resolution":
				vals = ["native", "720p", "1080p", "1440p", "4k"]
			"fps":
				vals = Settings.FPS_CHOICES
			"quality":
				vals = Settings.QUALITY.keys()
			"codec":
				vals = Settings.CODECS
			"audio":
				vals = Settings.AUDIO
			_:
				vals = [false, true]
		labels = vals.map(func(v): return _label(key, v))
		var r: VBoxContainer = ChoiceRow.new()
		r.setup(key, T.ROWS[key][0], vals, labels, p.get(key), "")
		var line: String = T.ROWS[key][1]
		if key == "hdr" and not hdr_ok:
			line = T.HDR_UNAVAILABLE
		r.set_explainer(func(_v): return line)
		var k: String = key
		r.changed.connect(func(v): _on_change(k, v))
		_list.add_child(r)
		rows[key] = r
		buttons.append(r.button)
	Kit.link_vertical(buttons)
	_refresh_summary()


func _label(key: String, v: Variant) -> String:
	if T.LABELS.has(key):
		return str(T.LABELS[key].get(v, str(v)))
	if key == "fps":
		return "Native" if str(v) == "native" else "%s fps" % str(v)
	return "On" if v else "Off"


func _on_change(key: String, v: Variant) -> void:
	if not app.is_empty() and not _editing_app():
		# changing a row for one app gives it its own settings
		service.set_app_override(host_id, _app_id(), true)
		if own_row != null:
			own_row.set_value_quiet(true)
	service.set_pick(host_id, key, v, _app_id() if _editing_app() else 0)
	_refresh_summary()


func _refresh_values() -> void:
	var p: Dictionary = service.effective_picks(host_id, _app_id())
	for k in rows:
		rows[k].set_value_quiet(p.get(k))
	_refresh_summary()


func _refresh_summary() -> void:
	var r: Dictionary = service.resolved(host_id, _app_id())
	summary.text = T.WILL_STREAM % Settings.summary(r)


func close(restore_focus := true) -> void:
	if not _open:
		return
	_open = false
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


func hints() -> Array:
	return [["LR", T.H_CHANGE], ["B", T.H_BACK]]
