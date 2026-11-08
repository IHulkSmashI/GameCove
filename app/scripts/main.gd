extends Control
## Home screen: header with live device numbers, the game library, and the
## quick menu (Guide button or F1). Built in code so layout stays in one place.

const SECTIONS := ["This game", "Power", "Screen", "Controller", "Device"]
const BG := Color(0.07, 0.086, 0.11)
const PANEL := Color(0.09, 0.11, 0.14)
const TEXT := Color(0.91, 0.925, 0.945)
const QUIET := Color(0.6, 0.64, 0.69)
const ACCENT := Color(0.31, 0.82, 0.77)

var _battery_label: Label
var _grid: GridContainer
var _empty_label: Label
var _menu: PanelContainer
var _menu_body: VBoxContainer
var _menu_tabs: Array[Button] = []
var _section := 0


func _ready() -> void:
	_build_home()
	_build_quick_menu()
	_fill_library()
	_refresh_header()
	var timer := Timer.new()
	timer.wait_time = 5.0
	timer.timeout.connect(_refresh_header)
	add_child(timer)
	timer.start()


func _unhandled_input(event: InputEvent) -> void:
	var toggle: bool = (event is InputEventJoypadButton and event.pressed
		and event.button_index == JOY_BUTTON_GUIDE) \
		or (event is InputEventKey and event.pressed and event.keycode == KEY_F1)
	if toggle:
		_set_menu_open(not _menu.visible)
		get_viewport().set_input_as_handled()
		return
	if not _menu.visible:
		return
	if event.is_action_pressed("ui_cancel"):
		_set_menu_open(false)
	elif event is InputEventJoypadButton and event.pressed:
		if event.button_index == JOY_BUTTON_LEFT_SHOULDER:
			_show_section(posmod(_section - 1, SECTIONS.size()))
		elif event.button_index == JOY_BUTTON_RIGHT_SHOULDER:
			_show_section(posmod(_section + 1, SECTIONS.size()))
	else:
		return
	get_viewport().set_input_as_handled()


# ---------------------------------------------------------------- home

func _build_home() -> void:
	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 24)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 40)
	add_child(margin)
	margin.add_child(root)

	var header := HBoxContainer.new()
	root.add_child(header)
	header.add_child(_label("GameCove", 30, TEXT))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	_battery_label = _label("", 18, QUIET)
	header.add_child(_battery_label)

	root.add_child(_label("Library", 20, TEXT))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)
	_grid = GridContainer.new()
	_grid.columns = 4
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", 16)
	_grid.add_theme_constant_override("v_separation", 16)
	scroll.add_child(_grid)
	_empty_label = _label("No installed games found yet. Steam games show up here once Steam has installed them.", 16, QUIET)
	_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_empty_label)

	root.add_child(_label("Press the Guide button (or F1) for the quick menu.", 14, QUIET))


func _fill_library() -> void:
	for child in _grid.get_children():
		child.queue_free()
	var games: Array = Library.games
	_empty_label.visible = games.is_empty()
	for g in games:
		var b := Button.new()
		b.text = g["title"]
		b.custom_minimum_size = Vector2(260, 120)
		b.clip_text = true
		b.focus_mode = Control.FOCUS_ALL
		var game: Dictionary = g
		b.pressed.connect(func(): Library.launch(game))
		_grid.add_child(b)
	if _grid.get_child_count() > 0:
		(_grid.get_child(0) as Control).grab_focus.call_deferred()


func _refresh_header() -> void:
	var b := Device.battery()
	var parts: Array[String] = [Device.display_name()]
	if b["watts"] >= 0.0:
		parts.append("%.1f W" % b["watts"])
	if b["percent"] >= 0:
		parts.append("%d%%%s" % [b["percent"], " (charging)" if b["status"] == "Charging" else ""])
	_battery_label.text = "  ·  ".join(parts)


# ---------------------------------------------------------------- quick menu

func _build_quick_menu() -> void:
	_menu = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL
	style.content_margin_left = 24
	style.content_margin_right = 24
	style.content_margin_top = 24
	style.content_margin_bottom = 24
	_menu.add_theme_stylebox_override("panel", style)
	_menu.anchor_left = 0.55
	_menu.anchor_right = 1.0
	_menu.anchor_bottom = 1.0
	_menu.visible = false
	add_child(_menu)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	_menu.add_child(row)

	var rail := VBoxContainer.new()
	rail.custom_minimum_size = Vector2(130, 0)
	row.add_child(rail)
	for i in SECTIONS.size():
		var tab := Button.new()
		tab.text = SECTIONS[i]
		tab.toggle_mode = true
		tab.custom_minimum_size = Vector2(0, 56)
		var idx := i
		tab.pressed.connect(func(): _show_section(idx))
		rail.add_child(tab)
		_menu_tabs.append(tab)

	_menu_body = VBoxContainer.new()
	_menu_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_menu_body.add_theme_constant_override("separation", 14)
	row.add_child(_menu_body)


func _set_menu_open(open: bool) -> void:
	_menu.visible = open
	if open:
		_show_section(0)  # always opens on This game
	elif _grid.get_child_count() > 0:
		(_grid.get_child(0) as Control).grab_focus()


func _show_section(i: int) -> void:
	_section = i
	for t in _menu_tabs.size():
		_menu_tabs[t].button_pressed = t == i
	_menu_tabs[i].grab_focus()
	for child in _menu_body.get_children():
		child.queue_free()
	_menu_body.add_child(_label(SECTIONS[i], 24, TEXT))
	for line in _section_lines(i):
		var l := _label(line[0], line[1], line[2])
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_menu_body.add_child(l)


## [text, size, color] rows per section. Live values where we already read them;
## the rest says what the section will hold, so testers know what's coming.
func _section_lines(i: int) -> Array:
	var p: Dictionary = Device.profile
	match i:
		0:
			return [
				["Quick goal, frame rate, upscaling and frame generation for the game you're playing.", 16, QUIET],
				["Opens here every time, because it's what you want mid-game.", 14, QUIET],
			]
		1:
			var b := Device.battery()
			var rows: Array = []
			if b["percent"] >= 0:
				rows.append(["Battery: %d%% %s" % [b["percent"], b["status"]], 18, TEXT])
			if b["watts"] >= 0.0:
				rows.append(["Drawing %.1f W right now" % b["watts"], 18, TEXT])
			if p.has("tdp"):
				rows.append(["Power range on this device: %d to %d W" % [p["tdp"]["min"], p["tdp"]["battery_max"]], 16, QUIET])
			rows.append(["Power profiles and auto TDP come next.", 14, QUIET])
			return rows
		2:
			var hz: Array = p.get("panel_hz", [])
			var rows2: Array = []
			if hz.size() == 2:
				rows2.append(["Panel: %d to %d Hz" % [hz[0], hz[1]], 18, TEXT])
			rows2.append(["Brightness, refresh rate, VRR and HDR come next.", 14, QUIET])
			return rows2
		3:
			return [
				["Button layout, gyro and back buttons, through InputPlumber.", 16, QUIET],
			]
		4:
			return [
				[Device.display_name(), 18, TEXT],
				["%s · %s" % [p.get("chip", "Unknown chip"), p.get("gpu", "unknown GPU")], 16, QUIET],
				["Support: %s" % Device.support_level(), 16, ACCENT if Device.support_level() == "full" else QUIET],
			]
	return []


func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l
