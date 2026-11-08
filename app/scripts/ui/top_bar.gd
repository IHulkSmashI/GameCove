extends HBoxContainer
## Top bar: logo mark, section tabs (LB / RB), and the status pill (Wi-Fi,
## battery, clock) that opens a small status panel. Tabs can carry a "new" dot.
## Knows nothing about services; main.gd feeds it with set_status().

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")

signal tab_pressed(id: String)
signal status_pressed

## [id, label, icon]
const TABS := [["home", "Home", "home"], ["library", "Library", "library"], ["discover", "Discover", "discover"], ["settings", "Settings", "settings"]]
const LOW_BATTERY := 15

var tabs := {}           # id -> Button
var current := "home"
var status_button: Button
var battery_icon: TextureRect
var battery_label: Label
var clock_label: Label
var wifi_icon: TextureRect
var device_name := ""
var battery: Dictionary = {}
var _dots := {}


func _init() -> void:
	name = "TopBar"
	add_theme_constant_override("separation", 6)
	var logo := TextureRect.new()
	logo.name = "Logo"
	logo.texture = load("res://assets/logo-mark.svg")
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.custom_minimum_size = Vector2(38, 38)
	logo.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(logo)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(14, 0)
	add_child(gap)
	add_child(Kit.glyph("LB", false, true))
	var order: Array = []
	for t in TABS:
		var b := Kit.button(t[1], "TabButton")
		b.name = "Tab_" + t[0]
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(0, 44)
		b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var id: String = t[0]
		b.pressed.connect(func(): tab_pressed.emit(id))
		if id == "settings":
			b.text = ""
			b.icon = Icons.tex("settings", 22)
			b.tooltip_text = t[1]
			b.custom_minimum_size = Vector2(52, 44)
			b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var dot := Panel.new()
		dot.name = "Dot"
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dot.custom_minimum_size = Vector2(8, 8)
		dot.size = Vector2(8, 8)
		dot.anchor_left = 1.0
		dot.anchor_right = 1.0
		dot.offset_left = -12
		dot.offset_right = -4
		dot.offset_top = 6
		dot.offset_bottom = 14
		dot.visible = false
		b.add_child(dot)
		_dots[id] = dot
		add_child(b)
		tabs[id] = b
		order.append(b)
	add_child(Kit.glyph("RB", false, true))
	add_child(Kit.spacer())

	status_button = Kit.button("", "TabButton")
	status_button.name = "Status"
	status_button.toggle_mode = false
	status_button.custom_minimum_size = Vector2(0, 44)
	status_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	status_button.pressed.connect(func(): status_pressed.emit())
	add_child(status_button)
	# Settings sits at the far right, after the status pill.
	move_child(tabs["settings"], get_child_count() - 1)
	tabs["settings"].toggle_mode = true
	link_bar()
	var pill := Kit.hbox(10)
	pill.name = "Pill"
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pill.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pill.offset_left = 16
	pill.offset_right = -16
	pill.alignment = BoxContainer.ALIGNMENT_CENTER
	status_button.add_child(pill)
	wifi_icon = Icons.rect("wifi", 20, ThemeLib.color("text"))
	wifi_icon.name = "Wifi"
	wifi_icon.visible = false
	pill.add_child(wifi_icon)
	battery_icon = TextureRect.new()
	battery_icon.name = "BatteryIcon"
	battery_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	battery_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	battery_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pill.add_child(battery_icon)
	battery_label = Kit.label("", "NumberLabel")
	battery_label.name = "Battery"
	battery_label.add_theme_font_size_override("font_size", ThemeLib.SIZE_SMALL)
	battery_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	pill.add_child(battery_label)
	clock_label = Kit.label("", "NumberLabel")
	clock_label.name = "Clock"
	clock_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	clock_label.add_theme_font_override("font", ThemeLib.font("semibold", true))
	pill.add_child(clock_label)
	select("home")


## Left/right across the bar: Home, Library, Discover, status, Settings.
func link_bar() -> void:
	var order: Array = [tabs["home"], tabs["library"], tabs["discover"], status_button, tabs["settings"]]
	Kit.link_horizontal(order)


func select(id: String) -> void:
	current = id
	for k in tabs:
		tabs[k].set_pressed_no_signal(k == id)
	_tint_settings_icon()


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


## `wifi`: {} when unknown (icon hidden), else {"connected": bool, "strength": 0..1}.
func set_status(dev_name: String, bat: Dictionary, clock: String, wifi: Dictionary = {}) -> void:
	device_name = dev_name
	battery = bat
	clock_label.text = clock
	var pct := int(bat.get("percent", -1))
	var charging: bool = bat.get("status", "") in ["Charging", "Full"]
	battery_label.visible = pct >= 0
	battery_icon.visible = pct >= 0
	if pct >= 0:
		battery_label.text = "%d%%" % pct
		var low := is_low(bat)
		var fg: Color = ThemeLib.color("bad") if low else ThemeLib.color("text")
		var fill: Color = ThemeLib.color("bad") if low else (ThemeLib.color("good") if charging else ThemeLib.color("text"))
		battery_icon.texture = Icons.battery(pct, charging, 24, fg, fill)
		battery_label.add_theme_color_override("font_color", fg)
	wifi_icon.visible = not wifi.is_empty()
	if not wifi.is_empty():
		var on: bool = wifi.get("connected", false)
		wifi_icon.texture = Icons.tex("wifi" if on else "cloud_off", 20, ThemeLib.color("text") if on else ThemeLib.color("text_3"))
	_fit_pill()


## The pill's button sizes to its contents (buttons don't follow children).
func _fit_pill() -> void:
	var pill: Control = status_button.get_node("Pill")
	status_button.custom_minimum_size.x = pill.get_combined_minimum_size().x + 32


static func is_low(bat: Dictionary) -> bool:
	var pct := int(bat.get("percent", -1))
	return pct >= 0 and pct <= LOW_BATTERY and bat.get("status", "") not in ["Charging", "Full"]


func _tint_settings_icon() -> void:
	tabs["settings"].icon = Icons.tex("settings", 22)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and tabs.has("settings"):
		_tint_settings_icon()
		for id in _dots:
			var sb := ThemeLib.box(ThemeLib.color("accent"), 999, 0, 0)
			_dots[id].add_theme_stylebox_override("panel", sb)
		if not battery.is_empty():
			set_status(device_name, battery, clock_label.text)
