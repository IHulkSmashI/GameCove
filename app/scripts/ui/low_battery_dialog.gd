extends Control
## "Battery at 5 %. Going to sleep to save your game." with a 30 s countdown. Any button or
## key stays awake; when the count runs out the handheld sleeps (low_battery.gd). Shown over
## everything, a running game too (main.gd marks our window as gamescope's overlay while it
## shows). Like the Keep this? dialog, it counts with a 1 s timer that only runs while open.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const TS := preload("res://scripts/ui/texts_saves.gd")

## true = stay awake (a button), false = the count ran out (sleep).
signal decided(stay_awake: bool)

var seconds_left := TS.LOW_SECONDS
var total := TS.LOW_SECONDS
var title_label: Label
var count_label: Label
var bar: ProgressBar
var stay_button: Button
var _timer: Timer
var _done := false
var _return_focus: Control


## Opens over `host` for `percent`.
static func open(host: Control, percent: int, secs := TS.LOW_SECONDS) -> Control:
	var d = load("res://scripts/ui/low_battery_dialog.gd").new()
	d.build(percent, secs)
	host.add_child(d)
	d.start()
	return d


func build(percent: int, secs: int) -> void:
	name = "LowBatteryDialog"
	# a countdown to sleep: any button means "still here" (docs/CONTROLLER-UX.md CUX-4, the one any-key screen)
	set_meta("ux_any_key", "any button keeps the handheld awake before it sleeps")
	total = maxi(1, secs)
	seconds_left = total
	set_anchors_preset(Control.PRESET_FULL_RECT)
	z_index = 30
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(ThemeLib.color("scrim"), 0.86)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var card := PanelContainer.new()
	card.name = "Card"
	card.add_theme_stylebox_override("panel", ThemeLib.glass(ThemeLib.radius("xl"), 32, 28))
	card.set_anchors_preset(Control.PRESET_CENTER)
	card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	card.grow_vertical = Control.GROW_DIRECTION_BOTH
	card.custom_minimum_size = Vector2(600, 0)
	add_child(card)
	var col := Kit.vbox(14)
	card.add_child(col)
	var head := Kit.hbox(14)
	head.add_child(Icons.rect("power", 32, ThemeLib.tone("bad")))
	title_label = Kit.label(TS.LOW_TITLE % percent, "TitleLabel")
	title_label.name = "Title"
	head.add_child(title_label)
	col.add_child(head)
	col.add_child(Kit.label(TS.LOW_LINE, "QuietLabel", true))
	count_label = Kit.label("", "MonoLabel")
	count_label.name = "Count"
	count_label.add_theme_color_override("font_color", ThemeLib.tone("warn"))
	col.add_child(count_label)
	bar = ProgressBar.new()
	bar.name = "Bar"
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 8)
	bar.max_value = total
	bar.add_theme_stylebox_override("background", ThemeLib.box(ThemeLib.soft(0.10), 999, 0, 0))
	bar.add_theme_stylebox_override("fill", ThemeLib.box(ThemeLib.tone("warn"), 999, 0, 0))
	col.add_child(bar)
	var buttons := Kit.hbox(12)
	buttons.alignment = BoxContainer.ALIGNMENT_END
	stay_button = Kit.primary(TS.LOW_STAY, "A")
	stay_button.name = "Stay"
	stay_button.custom_minimum_size = Vector2(200, 52)
	stay_button.pressed.connect(func(): finish(true))
	buttons.add_child(stay_button)
	col.add_child(buttons)
	_timer = Timer.new()
	_timer.wait_time = 1.0
	_timer.timeout.connect(tick)
	add_child(_timer)
	_show()


func start() -> void:
	if is_inside_tree():
		_return_focus = get_viewport().gui_get_focus_owner()
		stay_button.grab_focus()
		_timer.start()
	modulate.a = 0.0
	Motion.to(self, "modulate:a", 1.0, Motion.FAST)


## One second passed (the timer, or a test).
func tick() -> void:
	if _done:
		return
	seconds_left -= 1
	_show()
	if seconds_left <= 0:
		finish(false)


func _show() -> void:
	count_label.text = TS.LOW_COUNT % maxi(0, seconds_left)
	bar.value = seconds_left


## Closes without deciding (the charger went in).
func dismiss() -> void:
	if _done:
		return
	_done = true
	_timer.stop()
	_close()


func finish(stay_awake: bool) -> void:
	if _done:
		return
	_done = true
	_timer.stop()
	decided.emit(stay_awake)
	_close()


func _close() -> void:
	if _return_focus != null and is_instance_valid(_return_focus) and _return_focus.is_inside_tree():
		_return_focus.grab_focus()
	queue_free()


## Any button or key stays awake (Guide too: nothing behind reacts while it's up).
func _input(event: InputEvent) -> void:
	if _done:
		return
	var pressed: bool = (event is InputEventJoypadButton or event is InputEventKey or event is InputEventMouseButton) and event.is_pressed()
	if pressed:
		if is_inside_tree():
			get_viewport().set_input_as_handled()
		finish(true)


static func hints() -> Array:
	return [["A", TS.LOW_STAY]]
