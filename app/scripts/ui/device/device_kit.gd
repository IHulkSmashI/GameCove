extends RefCounted
## Shared pieces for the device pages (About, Controller, Storage, Updates):
## focusable tinted cards, key/value lines, usage bars, state chips. Built on
## ui_kit.gd and the theme tokens; nothing here talks to a service.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Icons := preload("res://scripts/ui/icons.gd")
## Card padding: tight enough that About this device's cards fit at 1280x800.
const PAD_X := 18
const PAD_Y := 14


## A card tinted by its section's colour, with one accent ring when focused.
## Read-only cards on About this device don't take focus; one with something
## to do (set_action) does, shows "(A) Copy info" in its header, and runs it
## on A.
class FocusCard extends PanelContainer:
	var tint := ""        # theme token ("accent", "info", "good", "warn") or ""
	var focusable := true
	var action_text := ""
	var action: Callable
	var _pill: Control

	## Gives the card a real job: focusable, a quiet "(A) text" pill at the
	## right of its header, `fn` on A.
	func set_action(text: String, fn: Callable) -> void:
		action_text = text
		action = fn
		focusable = true
		focus_mode = Control.FOCUS_ALL
		mouse_filter = Control.MOUSE_FILTER_STOP
		if not gui_input.is_connected(_on_input):
			gui_input.connect(_on_input)
		var head: Node = find_child("Head", true, false)
		if head == null:
			return
		if _pill != null and is_instance_valid(_pill):
			_pill.queue_free()
		var p := PanelContainer.new()
		p.name = "Action"
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var row := Kit.hbox(6)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(Kit.glyph("A", false, true))
		var l := Kit.label(text, "CaptionLabel")
		l.name = "Text"
		row.add_child(l)
		p.add_child(row)
		head.add_child(p)
		_pill = p
		_style_pill()

	func _on_input(e: InputEvent) -> void:
		if e.is_action_pressed("ui_accept") and action.is_valid():
			accept_event()
			action.call()

	## The "(A) text" pill shows only while this card holds focus: one (A)
	## prompt on screen at a time. Hidden by alpha, so the header never shifts.
	func _style_pill() -> void:
		if _pill == null or not is_instance_valid(_pill):
			return
		var on := has_focus()
		_pill.add_theme_stylebox_override("panel", ThemeLib.box(ThemeLib.soft(0.10), 999, 10, 3))
		_pill.modulate.a = 1.0 if on else 0.0

	func _init(tint_token := "", can_focus := true) -> void:
		tint = tint_token
		focusable = can_focus
		focus_mode = Control.FOCUS_ALL if can_focus else Control.FOCUS_NONE
		mouse_filter = Control.MOUSE_FILTER_STOP if can_focus else Control.MOUSE_FILTER_IGNORE
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		focus_entered.connect(queue_redraw)
		focus_exited.connect(queue_redraw)
		focus_entered.connect(_style_pill)
		focus_exited.connect(_style_pill)
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
		var sb := ThemeLib.box(col, ThemeLib.radius("l"), PAD_X, PAD_Y)
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
## `fixed`: the key column is exactly `key_width` (long keys wrap), so the
## values of every card on a page line up on one vertical axis.
static func kv(pairs: Array, key_width := 150, compact := false, fixed := false) -> GridContainer:
	var g := GridContainer.new()
	g.name = "Lines"
	g.columns = 2
	g.add_theme_constant_override("h_separation", 16)
	g.add_theme_constant_override("v_separation", 4 if compact else 8)
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
		if fixed:
			k.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
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
	# "none": nothing to do / not needed (a faint dash, never a cross).
	var icon: String = {"yes": "check", "no": "x", "maybe": "alert", "none": "minus"}.get(state, "dots")
	var tone: String = {"yes": "good", "no": "text_3", "maybe": "warn"}.get(state, "text_3")
	var row := Kit.hbox(10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(Icons.rect(icon, 18, ThemeLib.color(tone)))
	var l := Kit.label(text, "", true)
	if state in ["no", "none"]:
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
	load("res://scripts/ui/focus_scroll.gd").attach(s, 48.0)
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	s.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return s


## Every card (FocusCard) under `box`, in any column; else its direct children.
static func cards_in(box: Node) -> Array:
	var out: Array = []
	for n in box.find_children("*", "PanelContainer", true, false):
		if n is FocusCard:
			out.append(n)
	if out.is_empty():
		for c in box.get_children():
			if c is Control:
				out.append(c)
	return out


## "More below" at the column's foot while more cards wait below (never
## otherwise): the column's mask hides a card the edge would slice.
static func more_cue(holder: Control, s: ScrollContainer) -> HBoxContainer:
	var cue := Kit.icon_label("chevron_down", "More below", "CaptionLabel", ThemeLib.color("text_2"), 16, false)
	cue.name = "MoreCue"
	cue.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cue.anchor_left = 0.5
	cue.anchor_right = 0.5
	cue.anchor_top = 1.0
	cue.anchor_bottom = 1.0
	cue.offset_left = -70
	cue.offset_right = 70
	cue.offset_top = -24
	cue.offset_bottom = 0
	cue.alignment = BoxContainer.ALIGNMENT_CENTER
	# its own plate: a card taller than the column can't be cut above the cue, and its
	# text would show through the words
	var plate := Panel.new()
	plate.name = "MoreCuePlate"
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.anchor_left = 0.5
	plate.anchor_right = 0.5
	plate.anchor_top = 1.0
	plate.anchor_bottom = 1.0
	plate.offset_left = -76
	plate.offset_right = 76
	plate.offset_top = -27
	plate.offset_bottom = 1
	plate.add_theme_stylebox_override("panel", ThemeLib.box(Color(ThemeLib.color("bg"), 0.94), 999, 0, 0))
	holder.add_child(plate)
	holder.add_child(cue)
	var bar := s.get_v_scroll_bar()
	var upd := func(_v = 0.0):
		if is_instance_valid(cue):
			cue.visible = bar.max_value - bar.page - bar.value > 24.0
			if is_instance_valid(plate):
				plate.visible = cue.visible
	bar.value_changed.connect(upd)
	bar.changed.connect(upd)
	upd.call()
	return cue


## Padding around the scroller's content so focus rings aren't clipped.
static func pad(child: Control, px := 8) -> MarginContainer:
	var m := Kit.margin(px)
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	m.add_child(child)
	return m
