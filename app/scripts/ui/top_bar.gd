extends HBoxContainer
## Top bar: logo mark, the tab group (LB / RB chips either side, a count on
## Library, "new" dots), search, a red REC chip while recording, the telemetry
## pill (TDP watts and profile, temperature) and the status pill (controller
## battery, Wi-Fi, battery, clock) that opens a small status panel, then
## Settings. Anything unknown is hidden, never invented. Knows nothing about
## services; main.gd feeds it with set_status(), set_telemetry(), set_count(),
## set_recording() and set_pads().

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const TX := preload("res://scripts/ui/texts_extras.gd")

signal tab_pressed(id: String)
signal status_pressed
signal search_pressed

## [id, label, icon]
const TABS := [["home", "Home", "home"], ["library", "Library", "library"], ["discover", "Discover", "discover"], ["stream", "Stream", "stream"], ["settings", "Settings", "settings"]]
const LOW_BATTERY := 15
const HOT_C := 80.0
const WARM_C := 70.0

var tabs := {}           # id -> Button
var current := "home"
var status_button: Button
var search_button: Button
var battery_icon: TextureRect
var battery_label: Label
var clock_label: Label
var wifi_icon: TextureRect
var telemetry: PanelContainer
var tdp_label: Label
var temp_label: Label
var device_name := ""
var battery: Dictionary = {}
var _dots := {}
var _counts := {}        # id -> PanelContainer
var _tab_group: PanelContainer
var _telemetry_data := {}
var _status_seps: Array = []
## The red REC chip (shown while recording).
var rec_chip: PanelContainer
## Controller battery in the status pill: icon and the lowest pad's percentage.
var pad_icon: TextureRect
var pad_label: Label
var pads: Array = []


func _init() -> void:
	name = "TopBar"
	set_meta("ux_nav_bar", true)   # a press out of it lands on the screen's main control (docs/CONTROLLER-UX.md CUX-5)
	add_theme_constant_override("separation", ThemeLib.SPACE_2)
	var logo := TextureRect.new()
	logo.name = "Logo"
	logo.texture = load("res://assets/logo-mark.svg")
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.custom_minimum_size = Vector2(34, 34)
	logo.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(logo)
	# Wordmark: GAME in white, COVE in the accent.
	var word := Kit.hbox(0)
	word.name = "Wordmark"
	word.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for part in ["Game", "Cove"]:
		var l := Kit.label(part.to_upper())
		l.name = part
		l.add_theme_font_override("font", ThemeLib.font("display"))
		l.add_theme_font_size_override("font_size", 22)
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		word.add_child(l)
	add_child(word)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(ThemeLib.SPACE_5, 0)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(gap)

	_tab_group = PanelContainer.new()
	_tab_group.name = "TabGroup"
	_tab_group.theme_type_variation = "PillPanel"
	_tab_group.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_tab_group.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_tab_group)
	var group_row := Kit.hbox(ThemeLib.SPACE_1)
	group_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_group.add_child(group_row)
	group_row.add_child(Kit.glyph("LB", false, true))
	for t in TABS:
		var b := Kit.button(t[1], "TabButton")
		b.name = "Tab_" + t[0]
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(0, 38)
		b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var id: String = t[0]
		b.pressed.connect(func(): tab_pressed.emit(id))
		if id == "settings":
			b.text = ""
			b.icon = Icons.tex("settings", 22)
			b.tooltip_text = t[1]
			b.custom_minimum_size = Vector2(44, 44)
			b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var dot := Panel.new()
		dot.name = "Dot"
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dot.custom_minimum_size = Vector2(8, 8)
		dot.size = Vector2(8, 8)
		dot.anchor_left = 1.0
		dot.anchor_right = 1.0
		dot.offset_left = -10
		dot.offset_right = -2
		dot.offset_top = 2
		dot.offset_bottom = 10
		dot.visible = false
		b.add_child(dot)
		_dots[id] = dot
		if id == "settings":
			add_child(b)
		else:
			group_row.add_child(b)
		tabs[id] = b
	_add_count("library")
	group_row.add_child(Kit.glyph("RB", false, true))
	add_child(Kit.spacer())

	search_button = Kit.icon_button("search", "Search", 44)
	search_button.name = "Search"
	search_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	search_button.pressed.connect(func(): search_pressed.emit())
	add_child(search_button)

	rec_chip = PanelContainer.new()
	rec_chip.name = "RecChip"
	rec_chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	rec_chip.custom_minimum_size = Vector2(0, 32)
	rec_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rec_chip.visible = false
	var rrow := Kit.hbox(6)
	rrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rec_chip.add_child(rrow)
	var rdot := Panel.new()
	rdot.name = "RecDot"
	rdot.custom_minimum_size = Vector2(9, 9)
	rdot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	rdot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rrow.add_child(rdot)
	var rl := Kit.label(TX.REC_CHIP, "MonoLabel")
	rl.name = "RecText"
	rl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	rl.add_theme_font_override("font", ThemeLib.font("mono_bold"))
	rrow.add_child(rl)
	add_child(rec_chip)

	telemetry = PanelContainer.new()
	telemetry.name = "Telemetry"
	telemetry.theme_type_variation = "PillPanel"
	telemetry.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	telemetry.custom_minimum_size = Vector2(0, 40)
	telemetry.mouse_filter = Control.MOUSE_FILTER_IGNORE
	telemetry.visible = false
	add_child(telemetry)
	var trow := Kit.hbox(ThemeLib.SPACE_2)
	trow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	telemetry.add_child(trow)
	var live := Panel.new()
	live.name = "LiveDot"
	live.custom_minimum_size = Vector2(8, 8)
	live.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	live.mouse_filter = Control.MOUSE_FILTER_IGNORE
	trow.add_child(live)
	tdp_label = Kit.label("", "MonoLabel")
	tdp_label.name = "Tdp"
	tdp_label.uppercase = true
	tdp_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	trow.add_child(tdp_label)
	trow.add_child(_sep())
	temp_label = Kit.label("", "MonoLabel")
	temp_label.name = "Temp"
	temp_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	trow.add_child(temp_label)

	status_button = Kit.button("", "TabButton")
	status_button.name = "Status"
	status_button.toggle_mode = false
	status_button.custom_minimum_size = Vector2(0, 40)
	status_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	status_button.pressed.connect(func(): status_pressed.emit())
	add_child(status_button)
	# Settings sits at the far right, after the status pill.
	move_child(tabs["settings"], get_child_count() - 1)
	tabs["settings"].toggle_mode = true
	link_bar()
	var pill := Kit.hbox(ThemeLib.SPACE_2)
	pill.name = "Pill"
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pill.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pill.offset_left = ThemeLib.SPACE_4
	pill.offset_right = -ThemeLib.SPACE_4
	pill.alignment = BoxContainer.ALIGNMENT_CENTER
	status_button.add_child(pill)
	pad_icon = Icons.rect("gamepad", 18, ThemeLib.color("text"))
	pad_icon.name = "PadIcon"
	pad_icon.visible = false
	pill.add_child(pad_icon)
	pad_label = Kit.label("", "MonoLabel")
	pad_label.name = "PadBattery"
	pad_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	pad_label.visible = false
	pill.add_child(pad_label)
	var s0 := _sep()
	s0.name = "PadSep"
	s0.visible = false
	pill.add_child(s0)
	wifi_icon = Icons.rect("wifi", 18, ThemeLib.color("text"))
	wifi_icon.name = "Wifi"
	wifi_icon.visible = false
	pill.add_child(wifi_icon)
	var s1 := _sep()
	pill.add_child(s1)
	battery_label = Kit.label("", "MonoLabel")
	battery_label.name = "Battery"
	battery_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	pill.add_child(battery_label)
	battery_icon = TextureRect.new()
	battery_icon.name = "BatteryIcon"
	battery_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	battery_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	battery_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pill.add_child(battery_icon)
	var s2 := _sep()
	pill.add_child(s2)
	_status_seps = [s1, s2]
	clock_label = Kit.label("", "MonoLabel")
	clock_label.name = "Clock"
	clock_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	clock_label.add_theme_font_override("font", ThemeLib.font("mono_bold"))
	pill.add_child(clock_label)
	_restyle()
	select("home")


func _sep() -> Panel:
	var p := Panel.new()
	p.name = "Sep"
	p.custom_minimum_size = Vector2(1, 16)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


func _add_count(id: String) -> void:
	var p := PanelContainer.new()
	p.name = "Count"
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.anchor_left = 1.0
	p.anchor_right = 1.0
	p.anchor_top = 0.5
	p.anchor_bottom = 0.5
	p.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	p.grow_vertical = Control.GROW_DIRECTION_BOTH
	p.offset_right = -10
	var l := Kit.label("", "MonoLabel")
	l.name = "Text"
	l.add_theme_font_size_override("font_size", ThemeLib.SIZE_MICRO)
	l.add_theme_font_override("font", ThemeLib.font("mono_bold"))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	p.add_child(l)
	p.visible = false
	tabs[id].add_child(p)
	_counts[id] = p


## Left/right across the bar: Home, Library, Discover, Stream, search, status, Settings.
func link_bar() -> void:
	Kit.link_horizontal(pad_order())


## Every button of the bar the pad can reach, left to right as drawn: the tabs,
## Search, whatever main.gd put in the bar (Downloads), the status pill and
## Settings. Built from the bar's own children, so nothing in the middle is
## skipped (docs/CONTROLLER-UX.md CUX-5).
func pad_order() -> Array:
	var out: Array = []
	for c in get_children():
		if c == _tab_group:
			for t in TABS:
				if t[0] != "settings" and tabs[t[0]].visible:
					out.append(tabs[t[0]])
		elif c is Button and (c as Button).visible and (c as Button).focus_mode == Control.FOCUS_ALL:
			out.append(c)
	return out


func select(id: String) -> void:
	current = id
	for k in tabs:
		tabs[k].set_pressed_no_signal(k == id)
	_tint_tabs()


func tab_order() -> Array:
	return TABS.map(func(t): return t[0])


func tab_buttons() -> Array:
	return TABS.map(func(t): return tabs[t[0]])


## A small accent dot on a tab: something new there.
func set_dot(id: String, on: bool) -> void:
	if _dots.has(id):
		_dots[id].visible = on


func has_dot(id: String) -> bool:
	return _dots.has(id) and _dots[id].visible


## A count badge inside a tab (Library: number of games); n < 0 hides it.
func set_count(id: String, n: int) -> void:
	if not _counts.has(id):
		return
	var p: PanelContainer = _counts[id]
	p.visible = n >= 0
	p.get_node("Text").text = str(n)
	_pad_tabs()


func count_text(id: String) -> String:
	return _counts[id].get_node("Text").text if _counts.has(id) and _counts[id].visible else ""


## `wifi`: {} when unknown (icon hidden), else {"connected": bool, "strength": 0..1}.
func set_status(dev_name: String, bat: Dictionary, clock: String, wifi: Dictionary = {}) -> void:
	device_name = dev_name
	battery = bat
	clock_label.text = clock
	clock_label.visible = clock != ""
	var pct := int(bat.get("percent", -1))
	var charging: bool = bat.get("status", "") in ["Charging", "Full"]
	battery_label.visible = pct >= 0
	battery_icon.visible = pct >= 0
	if pct >= 0:
		battery_label.text = "%d%%" % pct
		var low := is_low(bat)
		var fg: Color = ThemeLib.color("bad") if low else ThemeLib.color("text")
		var fill: Color = ThemeLib.color("bad") if low else (ThemeLib.color("good") if charging else ThemeLib.color("accent"))
		battery_icon.texture = Icons.battery(pct, charging, 24, fg, fill)
		battery_label.add_theme_color_override("font_color", fg)
	wifi_icon.visible = not wifi.is_empty()
	if not wifi.is_empty():
		var on: bool = wifi.get("connected", false)
		wifi_icon.texture = Icons.tex("wifi" if on else "cloud_off", 18, ThemeLib.color("accent") if on else ThemeLib.color("text_3"))
	_status_seps[0].visible = wifi_icon.visible and pct >= 0
	_status_seps[1].visible = (pct >= 0 or wifi_icon.visible) and clock_label.visible
	_fit_pill()


## Live power numbers: {"tdp_w": float, "profile": String, "temp_c": float}.
## Missing or negative values are hidden; with neither, the pill hides.
func set_telemetry(d: Dictionary) -> void:
	_telemetry_data = d
	var w := float(d.get("tdp_w", -1.0))
	var prof := str(d.get("profile", ""))
	var t := float(d.get("temp_c", -1.0))
	var parts: Array[String] = []
	if w > 0.0:
		parts.append("%dW" % roundi(w))
	if prof != "":
		parts.append(prof)
	tdp_label.text = " ".join(parts)
	tdp_label.visible = not parts.is_empty()
	temp_label.visible = t > 0.0
	temp_label.text = "%d°C" % roundi(t) if t > 0.0 else ""
	var hot := ThemeLib.color("bad") if t >= HOT_C else (ThemeLib.color("warn") if t >= WARM_C else ThemeLib.color("good"))
	temp_label.add_theme_color_override("font_color", hot)
	tdp_label.get_parent().get_node("Sep").visible = tdp_label.visible and temp_label.visible
	telemetry.visible = tdp_label.visible or temp_label.visible
	fit_width.call_deferred()


## The pill's button sizes to its contents (buttons don't follow children).
func _fit_pill() -> void:
	var pill: Control = status_button.get_node("Pill")
	status_button.custom_minimum_size.x = pill.get_combined_minimum_size().x + ThemeLib.SPACE_4 * 2
	fit_width.call_deferred()


## The REC chip: on while a recording runs.
func set_recording(on: bool) -> void:
	rec_chip.visible = on
	fit_width.call_deferred()


## Controller batteries (upower.gd pads()): the lowest one in the status pill,
## all of them in its tooltip. [] (or none reporting a level) hides it.
func set_pads(list: Array) -> void:
	pads = list
	var UPower = load("res://scripts/system/upower.gd")
	var text: String = UPower.chip_text(list)
	pad_label.text = text
	pad_label.visible = text != ""
	pad_icon.visible = text != ""
	var low: Dictionary = UPower.lowest(list)
	var warn: bool = not low.is_empty() and int(low["percent"]) <= LOW_BATTERY and not low.get("charging", false)
	var col: Color = ThemeLib.color("bad") if warn else ThemeLib.color("text")
	pad_icon.texture = Icons.tex("gamepad", 18, col)
	pad_label.add_theme_color_override("font_color", col)
	status_button.get_node("Pill/PadSep").visible = pad_label.visible
	status_button.tooltip_text = TX.PADS_TIP % UPower.detail_text(list) if text != "" else ""
	_fit_pill()


static func is_low(bat: Dictionary) -> bool:
	var pct := int(bat.get("percent", -1))
	return pct >= 0 and pct <= LOW_BATTERY and bat.get("status", "") not in ["Charging", "Full"]


## The chosen tab carries a small accent dot before its label.
func _tint_tabs() -> void:
	tabs["settings"].icon = Icons.tex("settings", 22)
	for id in ["home", "library", "discover"]:
		var on: bool = id == current
		tabs[id].icon = null if on or not on else _dot_tex()
	_pad_tabs()


func _dot_tex() -> Texture2D:
	var hex := ThemeLib.color("accent").to_html(false)
	return Icons.from_svg("<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><circle cx='5' cy='5' r='3.5' fill='#%s'/></svg>" % hex)


## Room on the right of a tab for its count badge.
func _pad_tabs() -> void:
	for id in _counts:
		var b: Button = tabs[id]
		var p: PanelContainer = _counts[id]
		var extra := (p.get_combined_minimum_size().x + 8) if p.visible else 0.0
		for st in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
			b.remove_theme_stylebox_override(st)
			if extra <= 0.0:
				continue
			var sb: StyleBox = b.get_theme_stylebox(st).duplicate()
			if st == "focus":
				continue
			sb.content_margin_right = sb.content_margin_right + extra
			b.add_theme_stylebox_override(st, sb)


func _restyle() -> void:
	var round := ThemeLib.pill(ThemeLib.color("glass_2"), ThemeLib.color("line_2"), 10, 10)
	var round_on := ThemeLib.pill(ThemeLib.soft(0.14) if ThemeLib.is_dark() else ThemeLib.color("surface"), ThemeLib.color("line_2"), 10, 10)
	for st in ["normal", "hover"]:
		tabs["settings"].add_theme_stylebox_override(st, round)
	for st in ["pressed", "hover_pressed"]:
		tabs["settings"].add_theme_stylebox_override(st, round_on)
	var status_box := ThemeLib.pill(ThemeLib.color("glass_2"), ThemeLib.color("line_2"), 16, 6)
	var status_hover := ThemeLib.pill(ThemeLib.color("glass_2").lerp(ThemeLib.soft(0.2), 0.35), ThemeLib.color("line_2"), 16, 6)
	status_button.add_theme_stylebox_override("normal", status_box)
	status_button.add_theme_stylebox_override("hover", status_hover)
	status_button.add_theme_stylebox_override("pressed", status_hover)
	for sep in find_children("*Sep", "Panel", true, false):
		sep.add_theme_stylebox_override("panel", ThemeLib.box(ThemeLib.color("line_2"), 0, 0, 0))
	var rec_box := ThemeLib.pill(Color(ThemeLib.color("bad"), 0.16), Color(ThemeLib.color("bad"), 0.55), 12, 4)
	rec_chip.add_theme_stylebox_override("panel", rec_box)
	var rdot: Panel = rec_chip.find_child("RecDot", true, false)
	rdot.add_theme_stylebox_override("panel", ThemeLib.box(ThemeLib.color("bad"), 999, 0, 0))
	(rec_chip.find_child("RecText", true, false) as Label).add_theme_color_override("font_color", ThemeLib.color("bad"))
	var live: Panel = telemetry.find_child("LiveDot", true, false)
	var ld := ThemeLib.box(ThemeLib.color("accent"), 999, 0, 0)
	ld.shadow_color = ThemeLib.color("glow")
	ld.shadow_size = 6
	live.add_theme_stylebox_override("panel", ld)
	for id in _dots:
		var sb := ThemeLib.box(ThemeLib.color("accent"), 999, 0, 0)
		_dots[id].add_theme_stylebox_override("panel", sb)
	for id in _counts:
		var c := ThemeLib.box(Color(ThemeLib.color("accent"), 0.16), 999, 7, 1)
		_counts[id].add_theme_stylebox_override("panel", c)
		_counts[id].get_node("Text").add_theme_color_override("font_color", ThemeLib.color("accent") if ThemeLib.is_dark() else ThemeLib.color("text"))
	var word: Control = get_node("Wordmark")
	word.get_node("Game").add_theme_color_override("font_color", ThemeLib.color("text"))
	word.get_node("Cove").add_theme_color_override("font_color", ThemeLib.color("accent"))
	tdp_label.add_theme_color_override("font_color", ThemeLib.color("accent") if ThemeLib.is_dark() else ThemeLib.color("text"))


## The band behind the bar: dark glass across the whole width, a hairline under it.
func _draw() -> void:
	var vw := get_viewport_rect().size.x if is_inside_tree() else size.x
	var r := Rect2(Vector2(-global_position.x, -global_position.y), Vector2(vw, ThemeLib.TOP_BAR_H))
	var band := ThemeLib.box(Color(ThemeLib.color("bg"), 0.72 if ThemeLib.is_dark() else 0.80), 0, 0, 0)
	band.border_color = ThemeLib.color("line")
	band.border_width_bottom = 1
	draw_style_box(band, r)


## Five tabs, telemetry and the status pill can outgrow a 1280 px bar: then the
## wordmark goes and the logo mark alone stays.
func fit_width() -> void:
	if not is_inside_tree():
		return
	var word: Control = get_node("Wordmark")
	var room := get_viewport_rect().size.x - offset_left + offset_right
	word.visible = true
	if get_combined_minimum_size().x > room:
		word.visible = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()
		fit_width.call_deferred()
	if what == NOTIFICATION_THEME_CHANGED and tabs.has("settings"):
		queue_redraw()
		_restyle()
		_tint_tabs()
		if not battery.is_empty():
			set_status(device_name, battery, clock_label.text)
		if not _telemetry_data.is_empty():
			set_telemetry(_telemetry_data)
