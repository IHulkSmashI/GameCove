extends Button
## One PC on the Streaming page: a glass card with the PC's icon on a tile
## coloured by its state, the name, a mono status line (dot, state, latency,
## home network or remote) and what A does now. The PC whose apps show below
## keeps a thin accent outline; focus is the usual ring with its glow.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const SIcons := preload("res://scripts/ui/streaming/stream_icons.gd")
const T := preload("res://scripts/ui/texts_streaming.gd")

const SIZE := Vector2(330, 118)
const TONES := {"online": "good", "busy": "info", "asleep": "warn", "waking": "warn", "offline": "", "checking": "", "unknown": ""}

var host: Dictionary = {}
var selected := false
var _tile: Panel
var _icon: TextureRect
var _name: Label
var _status: Label
var _dot: Panel
var _line: Label
var _kind: TextureRect


func _init() -> void:
	focus_mode = Control.FOCUS_ALL
	custom_minimum_size = SIZE
	clip_contents = false
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)
	var row := Kit.hbox(16)
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 18
	row.offset_right = -18
	row.offset_top = 16
	row.offset_bottom = -16
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)
	_tile = Panel.new()
	_tile.name = "Tile"
	_tile.custom_minimum_size = Vector2(64, 64)
	_tile.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_tile)
	_icon = TextureRect.new()
	_icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tile.add_child(_icon)
	var col := Kit.vbox(4)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(col)
	var top := Kit.hbox(8)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(top)
	_name = Kit.label("", "LeadLabel")
	_name.name = "Name"
	_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_name.add_theme_font_override("font", ThemeLib.font("heading_bold"))
	_name.add_theme_font_size_override("font_size", 21)
	top.add_child(_name)
	_kind = TextureRect.new()
	_kind.name = "Kind"
	_kind.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_kind.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_kind.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(_kind)
	var srow := Kit.hbox(8)
	srow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(srow)
	_dot = Panel.new()
	_dot.custom_minimum_size = Vector2(8, 8)
	_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	srow.add_child(_dot)
	_status = Kit.micro("")
	_status.name = "Status"
	_status.add_theme_font_override("font", ThemeLib.mono(true, 1))
	srow.add_child(_status)
	_line = Kit.label("", "QuietLabel")
	_line.name = "Line"
	_line.add_theme_font_size_override("font_size", ThemeLib.SIZE_CAPTION)
	_line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(_line)


func set_host(h: Dictionary, line: String, is_selected: bool) -> void:
	host = h
	selected = is_selected
	name = "Host_" + str(h.get("id", "")).validate_node_name()
	_name.text = str(h.get("name", "")) if str(h.get("name", "")) != "" else str(h.get("address", ""))
	var st := str(h.get("status", "unknown"))
	var parts: Array[String] = [T.STATUS.get(st, st)]
	if int(h.get("latency_ms", -1)) >= 0 and st in ["online", "busy"]:
		parts.append(T.LATENCY % maxi(1, int(h["latency_ms"])))
	if bool(h.get("remote", false)):
		parts.append(T.REMOTE)
	_status.text = " · ".join(parts).to_upper()
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status.clip_text = true
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tooltip_text = T.REMOTE if bool(h.get("remote", false)) else T.LAN
	_line.text = line
	_restyle()


func status_tone() -> String:
	return TONES.get(str(host.get("status", "")), "")


var _styling := false


func _restyle() -> void:
	# overrides below send NOTIFICATION_THEME_CHANGED again: don't loop
	if _styling:
		return
	_styling = true
	var tone := status_tone()
	var col: Color = ThemeLib.tone(tone) if tone != "" else ThemeLib.color("text_3")
	var base: Color = ThemeLib.color("surface")
	var sb := ThemeLib.box(Color(base, 0.86 if ThemeLib.is_dark() else 0.95), ThemeLib.radius("l"), 0, 0)
	sb.border_color = Color(ThemeLib.color("accent"), 0.85) if selected else ThemeLib.color("line")
	sb.set_border_width_all(2 if selected else 1)
	for st in ["normal", "hover", "pressed", "disabled", "focus"]:
		add_theme_stylebox_override(st, sb if st != "focus" else StyleBoxEmpty.new())
	var online := str(host.get("status", "")) in ["online", "busy"]
	var tile := ThemeLib.box(Color(col, 0.16 if online else 0.10), ThemeLib.radius("m"), 0, 0)
	tile.border_color = Color(col, 0.45)
	tile.set_border_width_all(1)
	_tile.add_theme_stylebox_override("panel", tile)
	_icon.texture = SIcons.tex("moon" if str(host.get("status", "")) == "asleep" else "pc", 30,
		col if tone != "" else ThemeLib.color("text_2"))
	var dot := ThemeLib.box(col, 999, 0, 0)
	_dot.add_theme_stylebox_override("panel", dot)
	_status.add_theme_color_override("font_color", col if tone != "" else ThemeLib.color("text_2"))
	_kind.texture = SIcons.tex("globe" if bool(host.get("remote", false)) else "house", 18, ThemeLib.color("text_3"))
	_line.add_theme_color_override("font_color", ThemeLib.color("text_2"))
	_styling = false


func _draw() -> void:
	if has_focus():
		draw_style_box(ThemeLib.row_focus(ThemeLib.radius("l")), Rect2(Vector2.ZERO, size))
		# the card's content sits over the ring's fill: redraw the selected outline inside it
		if selected:
			var sb := ThemeLib.box(Color(0, 0, 0, 0), ThemeLib.radius("l"), 0, 0)
			sb.draw_center = false
			sb.border_color = Color(ThemeLib.color("accent"), 0.5)
			sb.set_border_width_all(1)
			draw_style_box(sb, Rect2(Vector2.ZERO, size))


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _tile != null and not host.is_empty():
		_restyle()
		queue_redraw()
