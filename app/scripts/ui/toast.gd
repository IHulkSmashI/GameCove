extends VBoxContainer
## Toasts: short glass notes stacked top-right (downloads, battery low, price
## drops, fix installed). They never take focus and leave on their own.
##   toasts.show_toast("Gyro aiming installed", "check", "good", "Restart to finish.")

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const Themes := preload("res://theme/themes.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")

signal shown(text: String)

const MAX := 3
const STAY_S := 4.0
const WIDTH := 360
## Slide-in from the right edge.
const SLIDE_PX := 56.0
const IN_S := 0.28
## Tones whose badge pops bigger: deals, releases, achievements.
const BIG_POP := ["sale", "new", "gold"]


func _init() -> void:
	name = "Toasts"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", 10)
	anchor_left = 1.0
	anchor_right = 1.0
	offset_left = -WIDTH - 20
	offset_right = -20
	offset_top = 76
	offset_bottom = 400
	focus_mode = Control.FOCUS_NONE


## tone: "", good, warn, bad, info, sale, ... (Themes.TONES) colours the icon.
func show_toast(text: String, icon := "info", tone := "", detail := "") -> Control:
	var p := PanelContainer.new()
	p.name = "Toast"
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.focus_mode = Control.FOCUS_NONE
	var sb := ThemeLib.glass(ThemeLib.radius("l"), 16, 12)
	p.add_theme_stylebox_override("panel", sb)
	var row := Kit.hbox(12)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var col: Color = ThemeLib.color(tone) if tone in ["good", "warn", "bad", "info", "accent"] else ThemeLib.tone(tone)
	var badge := PanelContainer.new()
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.add_theme_stylebox_override("panel", ThemeLib.box(Color(col, 0.18), 999, 8, 8))
	badge.add_child(Icons.rect(icon, 20, col))
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(badge)
	var texts := Kit.vbox(2)
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var t := Kit.label(text, "", true)
	t.add_theme_font_override("font", ThemeLib.font("semibold"))
	texts.add_child(t)
	if detail != "":
		texts.add_child(Kit.label(detail, "QuietLabel", true))
	row.add_child(texts)
	p.add_child(row)
	Kit.ignore_mouse(p)   # labels, icons and boxes too: a toast never eats a tap
	add_child(p)
	while get_child_count() > MAX:
		Kit.drop(self, get_child(0))
	# Slides in from the right edge as it fades in; its badge pops (a new deal,
	# a release, a fresh unlock get a bigger one).
	p.modulate.a = 0.0
	Motion.to(p, "modulate:a", 1.0, Motion.BASE)
	Motion.enter(p, "position:x", SLIDE_PX, 0.0, IN_S, 0.0, Tween.TRANS_QUART, Tween.EASE_OUT)
	Motion.pop(badge, 0.55 if tone in BIG_POP else 0.8, 0.4, 0.06)
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = STAY_S
	timer.timeout.connect(func(): _dismiss(p))
	p.add_child(timer)
	if p.is_inside_tree():
		timer.start()
	shown.emit(text)
	return p


func _dismiss(p: Control) -> void:
	if not is_instance_valid(p):
		return
	var tw := Motion.to(p, "modulate:a", 0.0, Motion.BASE)
	Motion.to(p, "position:x", SLIDE_PX * 0.6, Motion.BASE, Tween.TRANS_CUBIC, Tween.EASE_IN)
	if tw == null:
		p.queue_free()
	else:
		tw.finished.connect(p.queue_free)


func count() -> int:
	return get_child_count()
