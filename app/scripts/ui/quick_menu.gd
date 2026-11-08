extends Control
## The quick menu overlay: Guide button or F1 opens it, B / Esc closes it,
## LB / RB (or Q / E) switch sections. Always opens on "This game".
## Every control shows only when its service says the device supports it.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Texts := preload("res://scripts/ui/texts.gd")
const ChoiceRow := preload("res://scripts/ui/choice_row.gd")
const SliderRow := preload("res://scripts/ui/slider_row.gd")
const SettingsForm := preload("res://scripts/ui/settings_form.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")

signal closed

const SECTIONS := ["This game", "Power", "Screen", "Controller", "Device"]
const WIDTH := 620
const SUPPORT_TEXT := {
	"full": "Full support: tested on this device by the GameCove team.",
	"beta": "Beta: testers confirmed it works; we haven't tested it ourselves yet.",
	"generic": "Generic: device-specific settings stay hidden until someone tests this device.",
}

var device: Object
var power: Object
var launcher: Object
var gamescope: Object

var section := 0
var game: Dictionary = {}
var tabs: Array[Button] = []
var body: VBoxContainer
var live_label: Label
var status_label: Label
var _focusables: Array = []
var _power_shape := {}


## services: {"device", "power", "launcher", "gamescope"} (the autoloads, or fakes in tests).
func setup(services: Dictionary) -> void:
	name = "QuickMenu"
	device = services["device"]
	power = services["power"]
	launcher = services["launcher"]
	gamescope = services["gamescope"]
	if power.has_signal("changed"):
		power.changed.connect(_on_power_changed)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false

	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed:
			close())
	add_child(dim)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	var sb := ThemeLib.box(ThemeLib.PANEL, 0, 22, 20)
	sb.border_width_left = 2
	sb.border_color = ThemeLib.RAISED_HOVER
	panel.add_theme_stylebox_override("panel", sb)
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -WIDTH
	add_child(panel)
	var col := Kit.vbox(14)
	panel.add_child(col)

	var head := Kit.hbox()
	head.add_child(Kit.label("Quick menu", "HeaderLabel"))
	head.add_child(Kit.spacer())
	live_label = Kit.label("", "QuietLabel")
	live_label.name = "Live"
	live_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	live_label.size_flags_vertical = Control.SIZE_FILL
	head.add_child(live_label)
	col.add_child(head)

	var tab_row := Kit.hbox(4)
	tab_row.name = "Tabs"
	tab_row.add_child(_shoulder("LB"))
	for i in SECTIONS.size():
		var t := Kit.button(SECTIONS[i], "TabButton")
		t.name = "Tab%d" % i
		t.toggle_mode = true
		t.add_theme_font_size_override("font_size", 17)
		t.custom_minimum_size = Vector2(0, 44)
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		t.pressed.connect(show_section.bind(i))
		tab_row.add_child(t)
		tabs.append(t)
	tab_row.add_child(_shoulder("RB"))
	Kit.link_horizontal(tabs)
	for t in tabs:
		t.focus_neighbor_top = t.get_path_to(t)
	col.add_child(tab_row)

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.follow_focus = true
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 6)
	scroll.add_child(pad)
	body = Kit.vbox(20)
	body.name = "Body"
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_child(body)

	status_label = Kit.label("", "AccentLabel", true)
	status_label.name = "Status"
	col.add_child(status_label)
	col.add_child(Kit.label("B  Close    ·    LB / RB  Section    ·    ← →  Change", "QuietLabel"))


func _shoulder(text: String) -> Label:
	var l := Kit.label(text, "QuietLabel")
	l.custom_minimum_size = Vector2(30, 0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.size_flags_vertical = Control.SIZE_FILL
	return l


# ------------------------------------------------------------ open / close

## `for_game` is the game the "This game" section edits ({} for none).
func open(for_game: Dictionary) -> void:
	game = for_game
	visible = true
	gamescope.set_overlay(true)
	show_section(0)
	refresh_live()


func close() -> void:
	if not visible:
		return
	visible = false
	gamescope.set_overlay(false)
	closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
	elif _is_shoulder(event, JOY_BUTTON_LEFT_SHOULDER, KEY_Q):
		show_section(posmod(section - 1, SECTIONS.size()))
	elif _is_shoulder(event, JOY_BUTTON_RIGHT_SHOULDER, KEY_E):
		show_section(posmod(section + 1, SECTIONS.size()))
	else:
		return
	if get_viewport() != null:
		get_viewport().set_input_as_handled()


static func _is_shoulder(event: InputEvent, button: JoyButton, key: Key) -> bool:
	if event is InputEventJoypadButton:
		return event.pressed and event.button_index == button
	if event is InputEventKey:
		return event.pressed and not event.echo and event.keycode == key
	return false


# ------------------------------------------------------------ sections

func show_section(i: int, keep_focus := "") -> void:
	section = i
	status_label.text = ""
	for t in tabs.size():
		tabs[t].set_pressed_no_signal(t == i)
	for c in body.get_children():
		body.remove_child(c)
		c.queue_free()
	_focusables.clear()
	match i:
		0: _build_game()
		1: _build_power()
		2: _build_screen()
		3: _build_controller()
		4: _build_device()

	Kit.link_vertical(_focusables, tabs[i])
	for t in tabs:
		t.focus_neighbor_bottom = t.get_path_to(_focusables[0] if not _focusables.is_empty() else t)
	if is_inside_tree():
		focus_target(keep_focus).grab_focus()


## Where focus goes in the current section: the control whose row is named
## `keep` (after a rebuild), else the first control, else the section's tab.
func focus_target(keep := "") -> Control:
	for f in _focusables:
		if keep != "" and f.get_parent().name == keep:
			return f
	return _focusables[0] if not _focusables.is_empty() else tabs[section]


## Called every few seconds by main while the menu is open.
func refresh_live() -> void:
	var b: Dictionary = device.battery()
	live_label.text = _battery_text(b)
	var power_live := body.get_node_or_null("PowerLive") as Label
	if power_live != null:
		power_live.text = _battery_text(b, true)


static func _battery_text(b: Dictionary, long := false) -> String:
	var parts: Array[String] = []
	if int(b.get("percent", -1)) >= 0:
		var st: String = b.get("status", "")
		parts.append(("Battery %d%%" if long else "%d%%") % b["percent"] + (", %s" % st.to_lower() if long and st != "" else ""))
	if float(b.get("watts", -1.0)) >= 0.0:
		parts.append(("drawing %.1f W" if long else "%.1f W") % b["watts"])
	if parts.is_empty():
		return "Battery readings aren't available on this device." if long else ""
	return "   ·   ".join(parts)


func _line(text: String, variation := "", node_name := "") -> Label:
	var l := Kit.label(text, variation, true)
	if node_name != "":
		l.name = node_name
	body.add_child(l)
	return l


func _unavailable(setting: String) -> void:
	_line("%s: %s" % [Texts.TITLES[setting], Texts.NOT_AVAILABLE], "QuietLabel", "NA_" + setting)


func _add_row(r: Control) -> void:
	body.add_child(r)
	_focusables.append(r.button if "button" in r else r.slider)


func _build_game() -> void:
	if game.is_empty():
		_line("No game selected", "HeaderLabel")
		_line("Pick a game on the home screen; its frame rate, upscaling and frame generation show up here.", "QuietLabel")
		return
	_line(game.get("title", ""), "HeaderLabel", "GameTitle")
	_line("Changes save for this game and apply the next time it starts.", "QuietLabel")
	var form: VBoxContainer = SettingsForm.new()
	form.setup(game.get("key", ""), launcher, false)
	form.goal_changed.connect(_on_goal_changed)
	form.saved.connect(_on_game_settings_saved)
	body.add_child(form)
	_focusables.append_array(form.focusables())


func _on_goal_changed(goal: String) -> void:
	var st: Dictionary = power.state()
	if not st["supported"].get("profiles", false):
		return
	var p := Texts.goal_profile(goal, st.get("profiles", []))
	if p != "" and p != st.get("profile", "") and not power.set_profile(p):
		status_label.text = "Couldn't switch the power profile; the device kept its current one."


func _on_game_settings_saved(settings: Dictionary) -> void:
	if gamescope.is_running():
		gamescope.set_fps_limit(int(settings.get("fps_limit", 0)))


func _build_power() -> void:
	var st: Dictionary = power.state()
	var sup: Dictionary = st.get("supported", {})
	_power_shape = _shape(st)
	_line(_battery_text(device.battery(), true), "", "PowerLive")

	var profiles: Array = st.get("profiles", [])
	if sup.get("profiles", false) and not profiles.is_empty():
		var r: VBoxContainer = ChoiceRow.new()
		r.setup("profile", Texts.TITLES["profile"], profiles, profiles.map(func(p): return String(p).capitalize()), st.get("profile", ""))
		r.changed.connect(func(v): _apply(power.set_profile(v), r, "profile"))
		_add_row(r)
	else:
		_unavailable("profile")

	var lo := float(st.get("tdp_min", -1.0))
	var hi := float(st.get("tdp_max", -1.0))
	if sup.get("tdp", false) and lo >= 0.0 and hi > lo:
		var s: VBoxContainer = SliderRow.new()
		s.setup("tdp", Texts.TITLES["tdp"], lo, hi, float(st.get("tdp_w", lo)))
		s.changed.connect(func(v): _apply(power.set_tdp(v), s, "tdp"))
		_add_row(s)
	else:
		_unavailable("tdp")

	if sup.get("charge_limit", false):
		var limits: Array = Texts.CHARGE_LIMITS.duplicate()
		var cur := int(st.get("charge_limit", 100))
		if cur > 0 and cur not in limits:
			limits.append(cur)
			limits.sort()
		var c: VBoxContainer = ChoiceRow.new()
		c.setup("charge_limit", Texts.TITLES["charge_limit"], limits, limits.map(func(p): return Texts.charge_label(p)), cur)
		c.changed.connect(func(v): _apply(power.set_charge_limit(v), c, "charge_limit"))
		_add_row(c)
	else:
		_unavailable("charge_limit")

	var fans: Array = st.get("fan_modes", [])
	if sup.get("fan", false) and not fans.is_empty():
		var f: VBoxContainer = ChoiceRow.new()
		f.setup("fan", Texts.TITLES["fan"], fans, fans.map(func(m): return String(m).capitalize()), st.get("fan_mode", ""))
		f.changed.connect(func(v): _apply(power.set_fan_mode(v), f, "fan"))
		_add_row(f)
	else:
		_unavailable("fan")


## A setter said no: put the control back to what the device really has.
func _apply(ok: bool, row: Control, setting: String) -> void:
	if ok:
		status_label.text = ""
		return
	status_label.text = "Couldn't change %s; the device kept its current setting." % Texts.TITLES[setting].to_lower()
	if setting in ["profile", "tdp", "charge_limit", "fan"]:
		_update_power_values(power.state())
	elif setting == "refresh":
		row.set_value_quiet(row.values[-1])
	elif setting == "screen_fps":
		row.set_value_quiet(0)


static func _shape(st: Dictionary) -> Dictionary:
	return {"supported": st.get("supported", {}), "profiles": st.get("profiles", []),
		"fan_modes": st.get("fan_modes", []), "tdp": [st.get("tdp_min"), st.get("tdp_max")]}


func _on_power_changed(st: Dictionary) -> void:
	if not visible or section != 1:
		return
	if _shape(st) != _power_shape:
		var f := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
		show_section(1, f.get_parent().name if f != null and body.is_ancestor_of(f) else "")
	else:
		_update_power_values(st)


func _update_power_values(st: Dictionary) -> void:
	var map := {"profile": st.get("profile"), "tdp": st.get("tdp_w"), "charge_limit": st.get("charge_limit"), "fan": st.get("fan_mode")}
	for k in map:
		var r := body.get_node_or_null(k)
		if r != null and map[k] != null:
			r.set_value_quiet(map[k])


func _build_screen() -> void:
	var p: Dictionary = device.profile
	var hz: Array = p.get("panel_hz", [])
	if hz.size() == 2:
		_line("Panel: %d to %d Hz" % [hz[0], hz[1]], "QuietLabel")
	if not gamescope.is_running():
		_unavailable("refresh")
		_unavailable("screen_fps")
		_line("These work when GameCove runs as the gamescope session.", "QuietLabel")
		return
	var rates := Texts.refresh_rates(hz)
	if not rates.is_empty():
		var r: VBoxContainer = ChoiceRow.new()
		r.setup("refresh", Texts.TITLES["refresh"], rates, rates.map(func(x): return "%d Hz" % x), rates[-1])
		r.changed.connect(func(v): _apply(gamescope.set_refresh_rate(v), r, "refresh"))
		_add_row(r)
	var fps: Array = Texts.FPS_LIMITS
	var f: VBoxContainer = ChoiceRow.new()
	f.setup("screen_fps", Texts.TITLES["screen_fps"], fps, fps.map(func(x): return Texts.fps_label(x)), 0)
	f.changed.connect(func(v): _apply(gamescope.set_fps_limit(v), f, "screen_fps"))
	_add_row(f)


func _build_controller() -> void:
	var pads := Input.get_connected_joypads()
	if pads.is_empty():
		_line("No controller detected", "HeaderLabel")
	else:
		for id in pads:
			_line("Connected: %s" % Input.get_joy_name(id))
	_line("Built-in controls of the %s." % device.display_name(), "QuietLabel")
	_line("Button remapping, gyro and back buttons: %s. They'll come through InputPlumber." % Texts.NOT_AVAILABLE.to_lower(), "QuietLabel")


func _build_device() -> void:
	var p: Dictionary = device.profile
	var level: String = device.support_level()
	_line(device.display_name(), "HeaderLabel", "DeviceName")
	_line("Chip: %s" % p.get("chip", "Unknown"))
	_line("Graphics: %s" % p.get("gpu", "Unknown"))
	var support := _line("Support: %s" % level.capitalize(), "", "Support")
	if level == "full":
		support.add_theme_color_override("font_color", ThemeLib.ACCENT)
	_line(SUPPORT_TEXT.get(level, SUPPORT_TEXT["generic"]), "QuietLabel")


func focusables() -> Array:
	return _focusables
