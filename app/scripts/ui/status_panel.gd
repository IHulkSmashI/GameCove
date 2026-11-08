extends PanelContainer
## The small panel the top bar's status pill opens: battery (percent, state,
## draw, time left), device, and volume / brightness when something provides
## them. B closes it.
##
## hooks: {"volume": {"get": Callable() -> float 0..100, "set": Callable(float)},
##         "brightness": {...}}. Missing hooks show a "not available" line.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const Texts := preload("res://scripts/ui/texts.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const SliderRow := preload("res://scripts/ui/slider_row.gd")
const Motion := preload("res://scripts/ui/motion.gd")

signal closed

var hooks: Dictionary = {}
var big: Label
var state_label: Label
var detail_label: Label
var device_label: Label
var sliders: Array = []
var _body: VBoxContainer


func _init() -> void:
	name = "StatusPanel"
	theme_type_variation = "GlassPanel"
	visible = false
	anchor_left = 1.0
	anchor_right = 1.0
	offset_left = -380
	offset_right = -24
	offset_top = 72
	mouse_filter = Control.MOUSE_FILTER_STOP
	_body = Kit.vbox(14)
	add_child(_body)
	var top := Kit.hbox(14)
	top.add_child(Icons.rect("bolt", 28, ThemeLib.color("accent")))
	big = Kit.label("", "TitleLabel")
	big.name = "Percent"
	big.add_theme_font_override("font", ThemeLib.font("display", true))
	top.add_child(big)
	var st := Kit.vbox(0)
	st.alignment = BoxContainer.ALIGNMENT_CENTER
	state_label = Kit.label("", "")
	state_label.add_theme_font_override("font", ThemeLib.font("semibold"))
	st.add_child(state_label)
	detail_label = Kit.label("", "QuietLabel")
	st.add_child(detail_label)
	top.add_child(st)
	_body.add_child(top)
	device_label = Kit.label("", "QuietLabel", true)
	_body.add_child(device_label)


func setup(h: Dictionary) -> void:
	hooks = h
	for s in sliders:
		Kit.drop(_body, s)
	sliders.clear()
	for k in ["volume", "brightness"]:
		var title: String = {"volume": "Volume", "brightness": "Brightness"}[k]
		var hk: Variant = hooks.get(k)
		if hk is Dictionary and hk.get("get") is Callable and hk.get("set") is Callable:
			var s: VBoxContainer = SliderRow.new()
			s.setup(k, title, 0, 100, float(hk["get"].call()), 5.0, "%")
			s.changed.connect(func(v): hk["set"].call(v))
			_body.add_child(s)
			sliders.append(s)
		else:
			var l := Kit.icon_label("volume" if k == "volume" else "screen", "%s: %s" % [title, Texts.NOT_AVAILABLE.to_lower()], "QuietLabel", ThemeLib.color("text_3"), 18)
			l.name = "NA_" + k
			_body.add_child(l)
			sliders.append(l)


func set_battery(device_name: String, b: Dictionary) -> void:
	var pct := int(b.get("percent", -1))
	big.text = "%d%%" % pct if pct >= 0 else "—"
	var st: String = b.get("status", "")
	state_label.text = st.capitalize() if st != "" else "Battery"
	var bits: Array[String] = []
	if float(b.get("watts", -1.0)) >= 0.0:
		bits.append("%.1f W" % b["watts"])
	var left := int(b.get("time_left_min", -1))
	if left > 0:
		bits.append("about %d h %02d min left" % [left / 60, left % 60])
	detail_label.text = "   ".join(bits)
	device_label.text = device_name


func open() -> void:
	Motion.fade(self, true)
	for s in sliders:
		if s is VBoxContainer and is_inside_tree():
			s.slider.grab_focus()
			return


func close() -> void:
	if visible:
		Motion.fade(self, false)
		closed.emit()


func first_focus() -> Control:
	for s in sliders:
		if s is VBoxContainer:
			return s.slider
	return null
