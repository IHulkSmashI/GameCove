extends Control
## "Keep this? Reverting in 15 s": shown after a change that can leave the
## screen unusable (refresh rates we unlocked, HDR, rotation). If nobody
## presses Keep in time, it goes back by itself. A keeps, B or the timer
## goes back. Dims everything behind it (top and hint bars too) and takes
## focus; gives it back when it closes.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const CIcons := preload("res://scripts/ui/controls/cicons.gd")
const TC := preload("res://scripts/ui/texts_controls.gd")

## true = keep, false = go back (the timer ran out or B / Go back).
signal decided(keep: bool)

var seconds_left := 15
var total := 15
var keep_button: Button
var back_button: Button
var count_label: Label
var bar: ProgressBar
var _timer: Timer
var _done := false
var _return_focus: Control


## Opens over `host` (any Control; the dialog fills it). `what` names the
## setting, `now` its new value.
static func open(host: Control, what: String, now: String, secs := 15) -> Control:
	var d = load("res://scripts/ui/controls/keep_dialog.gd").new()
	d.build(what, now, secs)
	host.add_child(d)
	d.start()
	return d


func build(what: String, now: String, secs: int) -> void:
	name = "KeepDialog"
	total = maxi(1, secs)
	seconds_left = total
	set_anchors_preset(Control.PRESET_FULL_RECT)
	z_index = 20
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(ThemeLib.color("scrim"), 0.82)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var card := PanelContainer.new()
	card.name = "Card"
	card.add_theme_stylebox_override("panel", ThemeLib.glass(ThemeLib.radius("xl"), 32, 28))
	card.set_anchors_preset(Control.PRESET_CENTER)
	card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	card.grow_vertical = Control.GROW_DIRECTION_BOTH
	card.custom_minimum_size = Vector2(620, 0)
	add_child(card)
	var col := Kit.vbox(14)
	card.add_child(col)
	var head := Kit.hbox(12)
	head.add_child(CIcons.rect("alert", 28, ThemeLib.tone("warn")))
	var titles := Kit.vbox(2)
	var eyebrow := Kit.micro("%s: %s" % [what, now], "EyebrowLabel")
	eyebrow.name = "What"
	titles.add_child(eyebrow)
	titles.add_child(Kit.label(TC.KEEP_TITLE, "TitleLabel"))
	head.add_child(titles)
	col.add_child(head)
	col.add_child(Kit.label(TC.KEEP_LINE, "QuietLabel", true))
	count_label = Kit.label("", "MonoLabel")
	count_label.name = "Count"
	count_label.add_theme_color_override("font_color", ThemeLib.color("accent"))
	col.add_child(count_label)
	bar = ProgressBar.new()
	bar.name = "Bar"
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 8)
	bar.max_value = total
	bar.add_theme_stylebox_override("background", ThemeLib.box(ThemeLib.soft(0.10), 999, 0, 0))
	bar.add_theme_stylebox_override("fill", ThemeLib.gradient_box(ThemeLib.color("accent"), ThemeLib.color("accent_end"), 4, Color(0, 0, 0, 0), 0, 0))
	col.add_child(bar)
	var buttons := Kit.hbox(12)
	buttons.alignment = BoxContainer.ALIGNMENT_END
	back_button = Kit.secondary(TC.KEEP_NO, "", "B")
	back_button.name = "Back"
	back_button.custom_minimum_size = Vector2(0, 52)
	back_button.pressed.connect(func(): finish(false))
	buttons.add_child(back_button)
	keep_button = Kit.primary(TC.KEEP_YES, "A")
	keep_button.name = "Keep"
	keep_button.custom_minimum_size = Vector2(170, 52)
	keep_button.pressed.connect(func(): finish(true))
	buttons.add_child(keep_button)
	col.add_child(buttons)
	Kit.link_horizontal([back_button, keep_button])
	for b in [back_button, keep_button]:
		b.focus_neighbor_top = b.get_path_to(b)
		b.focus_neighbor_bottom = b.get_path_to(b)
	_timer = Timer.new()
	_timer.wait_time = 1.0
	_timer.timeout.connect(tick)
	add_child(_timer)
	_show()


func start() -> void:
	if is_inside_tree():
		_return_focus = get_viewport().gui_get_focus_owner()
		keep_button.grab_focus()
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
	count_label.text = TC.KEEP_REVERT % maxi(0, seconds_left)
	bar.value = seconds_left


func finish(keep: bool) -> void:
	if _done:
		return
	_done = true
	_timer.stop()
	decided.emit(keep)
	if _return_focus != null and is_instance_valid(_return_focus) and _return_focus.is_inside_tree():
		_return_focus.grab_focus()
	queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if _done:
		return
	if event.is_action_pressed("ui_cancel"):
		finish(false)
		get_viewport().set_input_as_handled()
	elif event is InputEventJoypadButton or event is InputEventKey:
		# Nothing behind the dialog reacts while it's up (LB / RB, Guide...).
		if not (event.is_action("ui_left") or event.is_action("ui_right") or event.is_action("ui_accept")):
			get_viewport().set_input_as_handled()


## Hint bar for main.gd while the dialog has focus.
func hints() -> Array:
	return [["A", TC.KEEP_YES], ["B", TC.KEEP_NO]]
