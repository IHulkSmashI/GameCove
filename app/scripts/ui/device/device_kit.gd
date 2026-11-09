extends RefCounted
## Shared pieces for the device pages (About, Controller, Storage, Updates):
## focusable tinted cards, key/value lines, usage bars, state chips. Built on
## ui_kit.gd and the theme tokens; nothing here talks to a service.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Icons := preload("res://scripts/ui/icons.gd")


## A card that can take focus (so the d-pad scrolls through read-only info),
## tinted by its section's colour, with one accent ring when focused.
class FocusCard extends PanelContainer:
	var tint := ""        # theme token ("accent", "info", "good", "warn") or ""
	var focusable := true

	func _init(tint_token := "", can_focus := true) -> void:
		tint = tint_token
		focusable = can_focus
		focus_mode = Control.FOCUS_ALL if can_focus else Control.FOCUS_NONE
		mouse_filter = Control.MOUSE_FILTER_STOP if can_focus else Control.MOUSE_FILTER_IGNORE
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		focus_entered.connect(queue_redraw)
		focus_exited.connect(queue_redraw)
		_restyle()

	var _styling := false

	func _restyle() -> void:
		if _styling:
			return
		_styling = true
		var base: Color = ThemeLib.color("surface")
		var col := Color(base, 0.86) if ThemeLib.is_dark() else Color(base, 0.94)
		if tint != "":
			var t: Color = ThemeLib.color(tint)
			col = Color(col.lerp(t, 0.03), col.a)
		var sb := ThemeLib.box(col, ThemeLib.radius("l"), 22, 18)
		sb.border_color = ThemeLib.color("line")
		sb.set_border_width_all(1)
		add_theme_stylebox_override("panel", sb)
		_styling = false

	func _draw() -> void:
		if has_focus():
			draw_style_box(ThemeLib.row_focus(ThemeLib.radius("l")), Rect2(Vector2.ZERO, size))

	func _notification(what: int) -> void:
		if what == NOTIFICATION_THEME_CHANGED:
			_restyle()
			queue_redraw()


## A thin rounded bar: `fraction` filled (0..1), coloured by how full it is
## unless `tone` says otherwise.
class UsageBar extends Control:
	var fraction := 0.0
	var tone := ""

	func _init(f := 0.0, bar_tone := "", height := 8) -> void:
		fraction = clampf(f, 0.0, 1.0)
		tone = bar_tone
		custom_minimum_size = Vector2(0, height)
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_fraction(f: float) -> void:
		fraction = clampf(f, 0.0, 1.0)
		queue_redraw()

	func bar_color() -> Color:
		if tone != "":
			return ThemeLib.color(tone)
		if fraction >= 0.95:
			return ThemeLib.color("bad")
		if fraction >= 0.85:
			return ThemeLib.color("warn")
		return ThemeLib.color("accent")

	func _draw() -> void:
		var r := size.y / 2.0
		draw_style_box(ThemeLib.box(ThemeLib.soft(0.12), int(r), 0, 0), Rect2(Vector2.ZERO, size))
		if fraction > 0.0:
			var w := maxf(size.y, size.x * fraction)
			draw_style_box(ThemeLib.box(bar_color(), int(r), 0, 0), Rect2(Vector2.ZERO, Vector2(w, size.y)))

	func _notification(what: int) -> void:
		if what == NOTIFICATION_THEME_CHANGED:
			queue_redraw()


## [card, column] with a header row: tinted icon + title, optional chip at the right.
static func card(title: String, icon: String, tint := "accent", can_focus := true) -> Array:
	var c := FocusCard.new(tint, can_focus)
	c.name = "Card_" + title.validate_node_name().replace(" ", "")
	var col := Kit.vbox(10)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(col)
	var head := Kit.hbox(10)
	head.name = "Head"
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var col_icon: Color = ThemeLib.color(tint) if tint != "" else ThemeLib.color("accent")
	head.add_child(Icons.rect(icon, 18, col_icon))
	# Mono micro heading in the section colour ("CHIP AND DRIVERS").
	var t := Kit.micro(title, "EyebrowLabel")
	t.name = "Title"
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	t.add_theme_color_override("font_color", col_icon)
	head.add_child(t)
	col.add_child(head)
	return [c, col]


## Puts a chip at the right end of a card's header.
static func head_chip(col: VBoxContainer, chip: Control) -> void:
	var head := col.get_node_or_null("Head")
	if head != null:
		head.add_child(chip)


## A state chip: text on the theme's chip colour, coloured by tone.
static func chip(text: String, tone := "", icon := "") -> PanelContainer:
	var b: PanelContainer = load("res://scripts/ui/badge.gd").make({"kind": "state", "text": text, "short": text, "tone": tone, "icon": icon}, "chip")
	b.name = "Chip"
	return b


## Two-column lines: quiet key on the left, value on the right. `pairs` =
## [[key, value], ...]; empty values are skipped. Optional third item: a
## quiet note under the value.
## `compact`: a size smaller (About this device packs its cards in two columns).
static func kv(pairs: Array, key_width := 150, compact := false) -> GridContainer:
	var g := GridContainer.new()
	g.name = "Lines"
	g.columns = 2
	g.add_theme_constant_override("h_separation", 16)
	g.add_theme_constant_override("v_separation", 8)
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for p in pairs:
		var v := str(p[1])
		if v == "" or v == "-1":
			continue
		var k := Kit.label(str(p[0]), "QuietLabel")
		if compact:
			k.add_theme_font_size_override("font_size", ThemeLib.SIZE_CAPTION + 1)
		k.custom_minimum_size = Vector2(key_width, 0)
		k.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		g.add_child(k)
		var box := Kit.vbox(2)
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var val := Kit.label(v, "", true)
		val.name = "Value_" + str(p[0]).validate_node_name().replace(" ", "")
		val.add_theme_font_override("font", ThemeLib.font("semibold", true))
		if compact:
			val.add_theme_font_size_override("font_size", ThemeLib.SIZE_SMALL)
		box.add_child(val)
		if p.size() > 2 and str(p[2]) != "":
			var note := Kit.label(str(p[2]), "CaptionLabel", true)
			note.add_theme_color_override("font_color", ThemeLib.color("text_3"))
			box.add_child(note)
		g.add_child(box)
	return g


## A line with a check, cross or dot icon in front: [ok?, text].
static func check_line(state: String, text: String) -> HBoxContainer:
	var icon: String = {"yes": "check", "no": "x", "maybe": "alert"}.get(state, "dots")
	var tone: String = {"yes": "good", "no": "text_3", "maybe": "warn"}.get(state, "text_3")
	var row := Kit.hbox(10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(Icons.rect(icon, 18, ThemeLib.color(tone)))
	var l := Kit.label(text, "", true)
	if state == "no":
		l.add_theme_color_override("font_color", ThemeLib.color("text_2"))
	row.add_child(l)
	return row


## One "what works" line (Capabilities.states): a green check for what works,
## a warn mark with its reason underneath for what's there but unconfirmed or
## missing a piece, and a faint dash with "Not on this handheld" for hardware
## this model doesn't have (never a cross: nothing here has failed).
static func feature_line(state: String, text: String, note := "", absent_text := "Not on this handheld") -> Control:
	var icon: String = {"yes": "check", "maybe": "alert", "absent": "minus"}.get(state, "dots")
	var tone: String = {"yes": "good", "maybe": "warn", "absent": "text_3"}.get(state, "text_3")
	var col := Kit.vbox(2)
	col.name = "Feature"
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var row := Kit.hbox(10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(Icons.rect(icon, 18, ThemeLib.color(tone)))
	var l := Kit.label(text, "", true)
	if state == "absent":
		l.add_theme_color_override("font_color", ThemeLib.color("text_3"))
	row.add_child(l)
	if state == "absent":
		var a := Kit.label(absent_text, "CaptionLabel")
		a.name = "Absent"
		a.add_theme_color_override("font_color", ThemeLib.color("text_3"))
		a.size_flags_horizontal = Control.SIZE_SHRINK_END
		row.add_child(a)
	col.add_child(row)
	if state == "maybe" and note != "":
		var n := Kit.label(note, "CaptionLabel", true)
		n.name = "Note"
		n.add_theme_color_override("font_color", ThemeLib.color("text_2"))
		var pad := MarginContainer.new()
		pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pad.add_theme_constant_override("margin_left", 28)
		pad.add_child(n)
		col.add_child(pad)
	return col


static func quiet(text: String) -> Label:
	return Kit.label(text, "QuietLabel", true)


## A big centred "nothing here" block: icon, title, line.
static func empty_state(icon: String, title: String, line: String) -> VBoxContainer:
	var b := Kit.vbox(10)
	b.name = "Empty"
	b.alignment = BoxContainer.ALIGNMENT_CENTER
	b.size_flags_vertical = Control.SIZE_EXPAND_FILL
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ic := Icons.rect(icon, 48, ThemeLib.color("text_3"))
	ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	b.add_child(ic)
	var t := Kit.label(title, "HeaderLabel")
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.add_child(t)
	var l := Kit.label(line, "QuietLabel", true)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.custom_minimum_size = Vector2(360, 0)
	b.add_child(l)
	return b


## A vertical scroller that follows focus, without a visible bar.
static func scroller() -> ScrollContainer:
	var s := ScrollContainer.new()
	s.name = "Scroll"
	s.follow_focus = true
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	s.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return s


## Padding around the scroller's content so focus rings aren't clipped.
static func pad(child: Control, px := 8) -> MarginContainer:
	var m := Kit.margin(px)
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	m.add_child(child)
	return m
