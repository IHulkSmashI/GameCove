extends RefCounted
## GameCove's one theme, built in code so colours and sizes live in one place.
## Sized for 1280x800 on an 8" screen and read from arm's length.
## Contrast (WCAG): TEXT on PANEL 14.4:1, QUIET on PANEL 6.8:1, QUIET on
## BUTTON_HOVER 5.3:1, dark text on ACCENT 10:1.

const BG := Color("#12161C")
const PANEL := Color("#171C23")
const RAISED := Color("#1F2630")
const RAISED_HOVER := Color("#27303B")
const TEXT := Color("#E8ECF1")
const QUIET := Color("#9AA4B0")
const ACCENT := Color("#4FD1C5")
const ON_ACCENT := Color("#0B1416")
const WARN := Color("#F2B35B")
const BAD := Color("#F28B82")

const FONT := 20
const FONT_QUIET := 17
const FONT_HEADER := 24
const FONT_TITLE := 34
const RADIUS := 10


static func box(bg: Color, radius := RADIUS, pad_x := 16, pad_y := 10) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.content_margin_left = pad_x
	s.content_margin_right = pad_x
	s.content_margin_top = pad_y
	s.content_margin_bottom = pad_y
	s.anti_aliasing = true
	return s


## The focus ring: a 3 px accent outline drawn just outside the control, so it
## reads on any background and never shifts layout.
static func focus_ring(radius := RADIUS) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.draw_center = false
	s.border_color = ACCENT
	s.set_border_width_all(3)
	s.set_corner_radius_all(radius + 3)
	s.set_expand_margin_all(4)
	s.anti_aliasing = true
	return s


static func build() -> Theme:
	var t := Theme.new()
	t.default_font_size = FONT

	t.set_color("font_color", "Label", TEXT)

	_button(t, "Button", RAISED, RAISED_HOVER, Color("#2C3A44"), TEXT)
	t.set_type_variation("AccentButton", "Button")
	_button(t, "AccentButton", ACCENT, ACCENT.lightened(0.15), ACCENT.darkened(0.15), ON_ACCENT)
	t.set_font_size("font_size", "AccentButton", FONT_HEADER)

	# Library tiles: no padding, art fills the button.
	t.set_type_variation("TileButton", "Button")
	_button(t, "TileButton", PANEL, RAISED, RAISED, TEXT)
	for st in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		var b: StyleBoxFlat = t.get_stylebox(st, "TileButton").duplicate()
		b.set_content_margin_all(0)
		b.set_corner_radius_all(12)
		t.set_stylebox(st, "TileButton", b)
	t.set_stylebox("focus", "TileButton", focus_ring(12))

	# Section tabs and store filter: flat until chosen, accent when chosen.
	t.set_type_variation("TabButton", "Button")
	_button(t, "TabButton", Color(0, 0, 0, 0), RAISED, ACCENT, QUIET)
	t.set_color("font_pressed_color", "TabButton", ON_ACCENT)
	t.set_color("font_hover_pressed_color", "TabButton", ON_ACCENT)
	t.set_color("font_focus_color", "TabButton", TEXT)
	t.set_color("font_hover_color", "TabButton", TEXT)
	t.set_stylebox("hover_pressed", "TabButton", box(ACCENT.lightened(0.1)))

	t.set_stylebox("panel", "PanelContainer", box(PANEL, 14, 20, 18))
	t.set_type_variation("RaisedPanel", "PanelContainer")
	t.set_stylebox("panel", "RaisedPanel", box(RAISED, 12, 16, 12))
	t.set_type_variation("BadgePanel", "PanelContainer")
	t.set_stylebox("panel", "BadgePanel", box(Color(0.04, 0.05, 0.07, 0.88), 6, 8, 3))

	t.set_type_variation("QuietLabel", "Label")
	t.set_color("font_color", "QuietLabel", QUIET)
	t.set_font_size("font_size", "QuietLabel", FONT_QUIET)
	t.set_type_variation("HeaderLabel", "Label")
	t.set_font_size("font_size", "HeaderLabel", FONT_HEADER)
	t.set_type_variation("TitleLabel", "Label")
	t.set_font_size("font_size", "TitleLabel", FONT_TITLE)
	t.set_type_variation("AccentLabel", "Label")
	t.set_color("font_color", "AccentLabel", ACCENT)
	t.set_font_size("font_size", "AccentLabel", FONT_QUIET)

	# Sliders: thick track, accent fill, ring when focused.
	var track := box(RAISED_HOVER, 4, 0, 4)
	t.set_stylebox("slider", "HSlider", track)
	var fill := box(ACCENT, 4, 0, 4)
	t.set_stylebox("grabber_area", "HSlider", fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", fill)
	t.set_stylebox("focus", "HSlider", focus_ring(6))

	t.set_color("font_color", "CheckButton", TEXT)
	t.set_color("font_focus_color", "CheckButton", TEXT)
	t.set_color("font_hover_color", "CheckButton", TEXT)
	t.set_color("font_pressed_color", "CheckButton", TEXT)
	t.set_color("font_hover_pressed_color", "CheckButton", TEXT)
	for st in ["normal", "hover", "pressed", "hover_pressed"]:
		t.set_stylebox(st, "CheckButton", box(RAISED if st != "hover" and st != "hover_pressed" else RAISED_HOVER))
	t.set_stylebox("focus", "CheckButton", focus_ring())

	var bar := box(Color(1, 1, 1, 0.18), 4, 0, 0)
	t.set_stylebox("grabber", "VScrollBar", bar)
	t.set_stylebox("grabber_highlight", "VScrollBar", box(Color(1, 1, 1, 0.3), 4, 0, 0))
	t.set_stylebox("grabber_pressed", "VScrollBar", box(Color(1, 1, 1, 0.3), 4, 0, 0))
	t.set_stylebox("scroll", "VScrollBar", box(Color(0, 0, 0, 0), 4, 3, 0))
	t.set_stylebox("grabber", "HScrollBar", bar)
	t.set_stylebox("scroll", "HScrollBar", box(Color(0, 0, 0, 0), 4, 0, 3))
	return t


static func _button(t: Theme, type: String, normal: Color, hover: Color, pressed: Color, font: Color) -> void:
	t.set_stylebox("normal", type, box(normal))
	t.set_stylebox("hover", type, box(hover))
	t.set_stylebox("pressed", type, box(pressed))
	t.set_stylebox("hover_pressed", type, box(pressed))
	t.set_stylebox("disabled", type, box(normal.darkened(0.3)))
	t.set_stylebox("focus", type, focus_ring())
	for c in ["font_color", "font_focus_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		t.set_color(c, type, font)
	t.set_color("font_disabled_color", type, QUIET)
