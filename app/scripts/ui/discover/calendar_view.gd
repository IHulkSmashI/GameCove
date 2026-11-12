extends "res://scripts/ui/discover/section.gd"
## Release calendar. Two layouts (X switches, remembered):
##   List:  Out now / This week / This month / Later / Date not announced,
##          one row per game with its date and a countdown, and a Notify me
##          toggle beside it.
##   Month: a Monday-first month grid (days with releases are focusable and
##          show small covers where the cell is big enough, else the first
##          titles and a dot with the count; today has an accent tint and bar),
##          with the focused day's games in a panel on the right; month and
##          quarter dates go under "Sometime this month".
## A game coming out today is highlighted. Y toggles Notify me anywhere.

var layout := "list"
var ym := Vector2i(2026, 1)
var list_button: Button
var month_button: Button
var prev_button: Button
var next_button: Button
## "Game data from IGDB" (review M24): IGDB's release dates fill the calendar; opens igdb.com.
var credit_button: Button
var rows: Array = []            # list layout: [row, notify] pairs
var day_buttons: Dictionary = {}   # day -> Button (month layout)
var undated_button: Button
var panel_rows: Array = []      # month layout: [row, notify] pairs in the side panel
var views: Array = []
var empty_card: Control
var _panel: VBoxContainer
var _panel_day := 0
var _scroll: ScrollContainer
var _ym_set := false


func setup(c: RefCounted) -> void:
	super.setup(c)
	name = "Calendar"
	layout = str(ctx.prefs.get_value("calendar_layout"))


func build() -> void:
	rows.clear()
	day_buttons.clear()
	panel_rows.clear()
	views.clear()
	undated_button = null
	prev_button = null
	next_button = null
	credit_button = null
	empty_card = null
	if not _ym_set:
		var t := Model.ymd(ctx.now())
		ym = Vector2i(int(t["year"]), int(t["month"]))
		_ym_set = true
	var col := Kit.vbox(14)
	col.name = "CalendarRoot"
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(col)

	var bar := Kit.hbox(10)
	bar.name = "Toolbar"
	list_button = _chip(T.VIEW_LIST, "list", layout == "list")
	month_button = _chip(T.VIEW_MONTH, "month", layout == "month")
	list_button.pressed.connect(func(): set_layout("list"))
	month_button.pressed.connect(func(): set_layout("month"))
	bar.add_child(list_button)
	bar.add_child(month_button)
	var cal: Array = ctx.discover.calendar
	if layout == "month" and not cal.is_empty():
		var sep := Control.new()
		sep.custom_minimum_size = Vector2(18, 0)
		bar.add_child(sep)
		prev_button = Kit.button("", "ChipButton")
		prev_button.name = "PrevMonth"
		prev_button.icon = Icons.tex("chevron_left", 20)
		prev_button.custom_minimum_size = Vector2(44, 44)
		prev_button.pressed.connect(func(): shift_month(-1))
		bar.add_child(prev_button)
		var mt := Kit.label(T.month_title(ym.x, ym.y), "LeadLabel")
		mt.name = "MonthTitle"
		mt.add_theme_font_override("font", ThemeLib.font("semibold", true))
		mt.custom_minimum_size = Vector2(190, 0)
		mt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		mt.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		mt.size_flags_vertical = Control.SIZE_FILL
		bar.add_child(mt)
		next_button = Kit.button("", "ChipButton")
		next_button.name = "NextMonth"
		next_button.icon = Icons.tex("chevron_right", 20)
		next_button.custom_minimum_size = Vector2(44, 44)
		next_button.pressed.connect(func(): shift_month(1))
		bar.add_child(next_button)
	bar.add_child(Kit.spacer())
	var info: Dictionary = ctx.discover.calendar_info()
	if not info.is_empty():
		var upd := Kit.label("%d games" % cal.size(), "CaptionLabel")
		upd.name = "Count"
		upd.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		upd.size_flags_vertical = Control.SIZE_FILL
		bar.add_child(upd)
	credit_button = Kit.button(T.IGDB_CREDIT, "ChipButton")
	credit_button.name = "IgdbCredit"
	credit_button.set_meta("url", T.IGDB_URL)
	credit_button.set_meta("link", true)
	credit_button.pressed.connect(func(): ctx.open_link({"kind": "url", "uri": T.IGDB_URL}))
	bar.add_child(credit_button)
	col.add_child(bar)
	bar.visible = not cal.is_empty()

	if cal.is_empty():
		var why := T.CAL_EMPTY
		if ctx.status("calendar") == "offline":
			why = T.OFFLINE
		empty_card = W.info_card("discover", T.CAL_EMPTY_TITLE, why, [[T.RETRY, func(): ctx.discover.refresh(true), "update"]])
		empty_card.name = "EmptyCard"
		col.add_child(empty_card)
	elif layout == "month":
		_build_month(col, cal)
	else:
		_build_list(col, cal)
	_link()


func _chip(text: String, icon: String, on: bool) -> Button:
	var b := Kit.button(text, "ChipButton")
	b.name = "Layout_" + text
	b.toggle_mode = true
	b.button_pressed = on
	b.custom_minimum_size = Vector2(96, 44)
	b.set_meta("role", "layout_" + icon)
	return b


func set_layout(l: String) -> void:
	if l == layout:
		_focus_later(list_button if l == "list" else month_button)
		return
	layout = l
	ctx.prefs.set_value("calendar_layout", l)
	refresh()
	_focus_later(default_focus())


func toggle_layout() -> void:
	set_layout("month" if layout == "list" else "list")


func shift_month(by: int) -> void:
	ym = Model.shift_month(ym.x, ym.y, by)
	_panel_day = 0
	refresh()
	_focus_later(prev_button if by < 0 else next_button)


# ---- list layout ---------------------------------------------------------------

func _build_list(col: VBoxContainer, cal: Array) -> void:
	_scroll = W.scroller()
	_scroll.follow_focus = false
	_scroll.set_meta("ux_follows", "each row follows with widgets.follow")   # docs/CONTROLLER-UX.md CUX-8
	col.add_child(_scroll)
	var list := Kit.vbox(10)
	list.name = "List"
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var pad := Kit.margin(0, 4, 6)
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_child(list)
	_scroll.add_child(pad)
	var now: int = ctx.now()
	var first := true
	for grp in Model.group_calendar(cal, now):
		var h := W.heading(T.GROUP_LABELS[grp[0]], grp[1].size())
		if not first:
			var gap := Control.new()
			gap.custom_minimum_size = Vector2(0, 6)
			list.add_child(gap)
		first = false
		list.add_child(h)
		for r in grp[1]:
			var pair := _entry(r, now, 92)
			list.add_child(pair[2])
			rows.append([pair[0], pair[1]])
			follow(_scroll, pair[0])
			follow(_scroll, pair[1])


## [row Button, notify Button, container] for one release.
func _entry(r: Dictionary, now: int, height: int) -> Array:
	var v := Model.release_view(r)
	ctx.art.fill(v, ["cover"])
	views.append(v)
	var today: bool = r.get("days_until") != null and int(r["days_until"]) == 0
	var badges: Array = []
	var cd := T.countdown(r, now)
	if today:
		badges.append({"kind": "today", "text": T.HERO_OUT_TODAY, "tone": "good", "icon": "sparkle"})
	elif cd != "" and cd != T.release_when(r, now):
		badges.append({"kind": "countdown", "text": cd, "tone": T.countdown_tone(r), "icon": "calendar"})
	if ctx.is_wishlisted(v):
		badges.append({"kind": "wish", "text": T.WISHLISTED, "tone": "wish", "icon": "star"})
	if not ctx.owned(v).is_empty():
		badges.append({"kind": "owned", "text": T.OWNED, "tone": "info", "icon": "library"})
	var when := Kit.label(T.release_when(r, now), "LeadLabel")
	when.name = "When"
	when.add_theme_font_override("font", ThemeLib.font("semibold", true))
	when.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	when.custom_minimum_size = Vector2(150, 0)
	if today:
		when.add_theme_color_override("font_color", ThemeLib.color("good"))
	var b := W.row(v, {"title": v["title"], "sub": _sub(r), "badges": badges, "right": when}, height)
	b.set_meta("role", "release")
	b.pressed.connect(func(): ctx.open_page(v))
	b.focus_entered.connect(func(): ctx.focus(v))
	if today:
		_highlight(b)
	var n := _notify_button(v, r)
	var h := Kit.hbox(10)
	h.name = "Entry_" + str(v["key"]).validate_node_name()
	h.add_child(b)
	h.add_child(n)
	return [b, n, h]


static func _sub(r: Dictionary) -> String:
	var src: Array = r.get("sources", [])
	var bits: Array = []
	var p := str(r.get("precision", ""))
	if p == "month":
		bits.append("Day not announced")
	elif p == "quarter":
		bits.append("Quarter only")
	elif p == "year":
		bits.append("Year only")
	if r.get("ids", {}).has("steam"):
		bits.append("On Steam")
	elif not src.is_empty():
		bits.append("From " + ", ".join(src.map(func(s): return {"igdb": "IGDB", "wikidata": "Wikidata", "steam": "Steam"}.get(s, str(s).capitalize()))))
	return "  ·  ".join(bits)


## Today (and a game out today in the list): an accent tint and a bar along the
## bottom, never a ring: the ring is focus alone (docs/CONTROLLER-UX.md CUX-1, CUX-2).
func _highlight(b: Button) -> void:
	var sb := ThemeLib.box(Color(ThemeLib.color("accent"), 0.10), ThemeLib.radius("m"), 18, 10)
	sb.border_color = ThemeLib.color("accent")
	sb.border_width_bottom = 3
	b.add_theme_stylebox_override("normal", sb)
	b.set_meta("today", true)


func _notify_button(v: Dictionary, r: Dictionary) -> Button:
	var on: bool = ctx.is_notifying(v)
	var n := Kit.button(T.NOTIFY_ON if on else T.NOTIFY_OFF, "ChipButton")
	n.name = "Notify"
	n.toggle_mode = true
	n.button_pressed = on
	n.icon = Icons.tex("check" if on else "calendar", 18)
	n.add_theme_constant_override("h_separation", 8)
	n.custom_minimum_size = Vector2(196, 48)
	n.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	n.set_meta("view", v)
	n.set_meta("role", "notify")
	n.disabled = r.get("released", false) and not on
	if n.disabled:
		n.focus_mode = Control.FOCUS_NONE
		n.modulate.a = 0.0
	n.pressed.connect(func(): ctx.toggle_notify(v))
	return n


# ---- month layout --------------------------------------------------------------

func _build_month(col: VBoxContainer, cal: Array) -> void:
	var now: int = ctx.now()
	var today := Model.ymd(now)
	var map := Model.month_map(cal, ym.x, ym.y)
	var body := Kit.hbox(20)
	body.name = "MonthBody"
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(body)
	var left := Kit.vbox(8)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 1.55
	body.add_child(left)
	var wk := GridContainer.new()
	wk.columns = 7
	wk.add_theme_constant_override("h_separation", 8)
	for d in T.WEEKDAYS_SHORT:
		var l := Kit.label(d, "CaptionLabel")
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		wk.add_child(l)
	left.add_child(wk)
	var grid := GridContainer.new()
	grid.name = "Grid"
	grid.columns = 7
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(grid)
	var cells := Model.month_cells(ym.x, ym.y)
	var weeks := int(cells.size() / 7.0)
	var cell_h := 64 if weeks > 5 else 74
	for day in cells:
		grid.add_child(_day_cell(day, map["days"].get(day, []), cell_h,
			day > 0 and int(today["year"]) == ym.x and int(today["month"]) == ym.y and int(today["day"]) == day))
	var und: Array = map["undated"]
	if not und.is_empty():
		undated_button = Kit.button("%s: %s" % [T.UNDATED_MONTH, T.wishlist_count(und.size())], "RowButton")
		undated_button.name = "Undated"
		undated_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		undated_button.icon = Icons.tex("calendar", 20)
		undated_button.add_theme_constant_override("h_separation", 10)
		undated_button.custom_minimum_size = Vector2(0, 46)
		undated_button.set_meta("role", "undated")
		undated_button.focus_entered.connect(func(): _show_panel(-1))
		undated_button.pressed.connect(func(): _enter_panel())
		left.add_child(undated_button)
	elif map["days"].is_empty():
		var none := Kit.label(T.CAL_NONE_MONTH, "QuietLabel")
		left.add_child(none)

	var card := PanelContainer.new()
	card.name = "DayPanel"
	card.theme_type_variation = "CardPanel"
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(card)
	_scroll = W.scroller()
	_scroll.follow_focus = true
	card.add_child(_scroll)
	_panel = Kit.vbox(10)
	_panel.name = "Panel"
	_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_panel)
	var first_day := 0
	var keys: Array = map["days"].keys()
	keys.sort()
	for d in keys:
		if int(today["year"]) == ym.x and int(today["month"]) == ym.y and d < int(today["day"]):
			continue
		first_day = d
		break
	if first_day == 0 and not keys.is_empty():
		first_day = keys[0]
	_show_panel(_panel_day if _panel_day != 0 else (first_day if first_day > 0 else -1))


## Covers show in cells at least this big (cells grow with the grid, so on
## big screens they have room); smaller cells list titles with a dot count.
const COVER_CELL_H := 92.0
const COVER_CELL_W := 96.0


func _day_cell(day: int, rels: Array, h: int, is_today: bool) -> Control:
	if day == 0:
		var pad := Control.new()
		pad.custom_minimum_size = Vector2(0, h)
		pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pad.size_flags_vertical = Control.SIZE_EXPAND_FILL
		pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return pad
	var b := Kit.button("", "RowButton")
	b.name = "Day_%d" % day
	b.custom_minimum_size = Vector2(0, h)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Rows share the grid's height: big screens get taller cells (with covers).
	b.size_flags_vertical = Control.SIZE_EXPAND_FILL
	b.set_meta("role", "day_%d" % day)
	b.set_meta("day", day)
	var col := Kit.vbox(4)
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.offset_left = 10
	col.offset_top = 6
	col.offset_right = -8
	col.offset_bottom = -6
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(col)
	var top := Kit.hbox(6)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var n := Kit.label(str(day), "CaptionLabel")
	n.add_theme_font_override("font", ThemeLib.mono(true, 0))
	if is_today:
		n.add_theme_color_override("font_color", ThemeLib.color("accent"))
	top.add_child(n)
	if is_today:
		var tag := Kit.micro(T.TODAY_TAG, "EyebrowLabel")
		tag.name = "Today"
		tag.add_theme_font_size_override("font_size", 11)
		tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		top.add_child(tag)
	if not rels.is_empty():
		top.add_child(Kit.spacer())
		# Dot with the count: how many games come out that day.
		if rels.size() > 1:
			var count := Kit.label(str(rels.size()), "MicroLabel")
			count.name = "Count"
			count.add_theme_color_override("font_color", ThemeLib.color("accent"))
			top.add_child(count)
		var dot := Panel.new()
		dot.name = "Dot"
		dot.custom_minimum_size = Vector2(8, 8)
		dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dot.add_theme_stylebox_override("panel", ThemeLib.box(ThemeLib.color("accent"), 999, 0, 0))
		top.add_child(dot)
	col.add_child(top)
	var titles := Kit.vbox(2)
	titles.name = "Titles"
	titles.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(titles)
	for r in rels.slice(0, 2 if h >= 70 else 1):
		var t := Kit.label(str(r.get("title", "")), "CaptionLabel")
		t.add_theme_font_size_override("font_size", ThemeLib.SIZE_MICRO)
		t.add_theme_color_override("font_color", ThemeLib.color("text"))
		t.clip_text = true
		t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		titles.add_child(t)
	if rels.size() > (2 if h >= 70 else 1):
		var more := Kit.label("+%d more" % (rels.size() - (2 if h >= 70 else 1)), "CaptionLabel")
		more.add_theme_font_size_override("font_size", ThemeLib.SIZE_MICRO)
		titles.add_child(more)
	if not rels.is_empty():
		b.resized.connect(func(): _fit_cell(b, col, titles, rels))
	if rels.is_empty():
		b.focus_mode = Control.FOCUS_NONE
		b.modulate.a = 0.55
		if is_today:
			b.modulate.a = 1.0
	else:
		day_buttons[day] = b
		b.focus_entered.connect(func(): _show_panel(day))
		b.pressed.connect(func():
			if rels.size() == 1:
				ctx.open_page(_view_for(rels[0]))
			else:
				_enter_panel())
	if is_today:
		_highlight(b)
	return b


## After layout: covers when the cell has room, titles otherwise. Rebuilt only
## when the cell's size changes enough to matter (never per frame).
func _fit_cell(b: Button, col: VBoxContainer, titles: Control, rels: Array) -> void:
	var big := b.size.y >= COVER_CELL_H and b.size.x >= COVER_CELL_W
	var bucket := Vector2i(int(b.size.x / 8.0), int(b.size.y / 8.0)) if big else Vector2i.ZERO
	if b.get_meta("cover_bucket", Vector2i(-1, -1)) == bucket:
		return
	b.set_meta("cover_bucket", bucket)
	var old := col.get_node_or_null("Covers")
	if old != null:
		col.remove_child(old)
		old.queue_free()
	titles.visible = not big
	if big:
		_cell_covers(col, rels, b.size.y, b.size.x)


## Small covers in a big cell: one cover beside its title, or as many covers
## as fit side by side (the last one says "+n" when more don't fit).
func _cell_covers(col: VBoxContainer, rels: Array, h: float, w: float) -> void:
	var ch := floorf(h - 42.0)
	var cw := floorf(ch * 2.0 / 3.0)
	var row := Kit.hbox(6)
	row.name = "Covers"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(row)
	var inner := w - 18.0
	if rels.size() == 1:
		row.add_child(W.thumb(_view_for(rels[0]), Vector2(cw, ch)))
		var t := Kit.label(str(rels[0].get("title", "")), "CaptionLabel", true)
		t.add_theme_font_size_override("font_size", ThemeLib.SIZE_MICRO)
		t.add_theme_color_override("font_color", ThemeLib.color("text"))
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		t.size_flags_vertical = Control.SIZE_FILL   # the whole cover height, so every line fits;
		t.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM   # the text still sits at the bottom
		t.max_lines_visible = 3
		t.autowrap_mode = TextServer.AUTOWRAP_WORD
		t.clip_text = true
		t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		if inner - cw - 6.0 >= 40.0:
			row.add_child(t)
		return
	var fits := maxi(1, int((inner + 6.0) / (cw + 6.0)))
	var shown := mini(rels.size(), fits)
	for i in shown:
		row.add_child(W.thumb(_view_for(rels[i]), Vector2(cw, ch)))
	if rels.size() > shown:
		var more := Kit.label("+%d" % (rels.size() - shown + 1), "MicroLabel")
		more.name = "More"
		more.add_theme_color_override("font_color", ThemeLib.color("text"))
		more.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		more.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		var shade := PanelContainer.new()
		shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
		shade.add_theme_stylebox_override("panel", ThemeLib.box(Color(ThemeLib.color("scrim"), 0.72), ThemeLib.radius("s"), 0, 0))
		shade.add_child(more)
		var last: Control = row.get_child(row.get_child_count() - 1)
		Kit.fill(shade)
		last.add_child(shade)


func _view_for(r: Dictionary) -> Dictionary:
	var key := Model.art_key(r)
	for v in views:
		if v["key"] == key:
			return v
	var v := Model.release_view(r)
	ctx.art.fill(v, ["cover"])
	views.append(v)
	return v


## Fill the side panel with a day's releases (-1 = month/quarter dates).
func _show_panel(day: int) -> void:
	if _panel == null:
		return
	_panel_day = day
	for c in _panel.get_children():
		W.detach(_panel, c)
	panel_rows.clear()
	var map := Model.month_map(ctx.discover.calendar, ym.x, ym.y)
	var rels: Array = map["undated"] if day < 0 else map["days"].get(day, [])
	var title := T.UNDATED_MONTH if day < 0 else T.day_title(ym.x, ym.y, day)
	_panel.add_child(Kit.icon_label("calendar", title, "HeaderLabel", ThemeLib.color("accent"), 24, false))
	if rels.is_empty():
		_panel.add_child(Kit.label(T.DAY_EMPTY, "QuietLabel", true))
		return
	var now: int = ctx.now()
	for r in rels:
		var pair := _entry(r, now, 78)
		var n: Button = pair[1]
		n.custom_minimum_size = Vector2(56, 48)
		n.text = ""
		n.tooltip_text = T.NOTIFY_ON if n.button_pressed else T.NOTIFY_OFF
		var when: Node = pair[0].find_child("When", true, false)
		if when != null:
			when.visible = false
		_panel.add_child(pair[2])
		panel_rows.append([pair[0], pair[1]])
	_link_panel()


func _enter_panel() -> void:
	if not panel_rows.is_empty():
		_focus_later(panel_rows[0][0])


func _link_panel() -> void:
	var back: Control = day_buttons.get(_panel_day, undated_button) if _panel_day != 0 else null
	for i in panel_rows.size():
		var r: Button = panel_rows[i][0]
		var n: Button = panel_rows[i][1]
		var up: Control = panel_rows[i - 1][0] if i > 0 else r
		var down: Control = panel_rows[i + 1][0] if i + 1 < panel_rows.size() else r
		r.focus_neighbor_top = r.get_path_to(up)
		r.focus_neighbor_bottom = r.get_path_to(down)
		r.focus_neighbor_left = r.get_path_to(back if back != null else r)
		r.focus_neighbor_right = r.get_path_to(n if n.focus_mode != Control.FOCUS_NONE else r)
		n.focus_neighbor_left = n.get_path_to(r)
		n.focus_neighbor_right = n.get_path_to(n)
		n.focus_neighbor_top = n.get_path_to(panel_rows[i - 1][1] if i > 0 and panel_rows[i - 1][1].focus_mode != Control.FOCUS_NONE else n)
		n.focus_neighbor_bottom = n.get_path_to(panel_rows[i + 1][1] if i + 1 < panel_rows.size() and panel_rows[i + 1][1].focus_mode != Control.FOCUS_NONE else n)


# ---- focus ----------------------------------------------------------------------

func _toolbar() -> Array:
	var out: Array = [list_button, month_button]
	if prev_button != null:
		out.append_array([prev_button, next_button])
	if credit_button != null:
		out.append(credit_button)
	return out


func _link() -> void:
	var bar := _toolbar()
	Kit.link_horizontal(bar)
	var below := default_body_focus()
	for b in bar:
		b.focus_neighbor_top = b.get_path_to(top_target if top_target != null else b)
		b.focus_neighbor_bottom = b.get_path_to(below if below != null else b)
	if empty_card != null:
		var eb: Array = empty_card.get_meta("buttons")
		for b in eb:
			b.focus_neighbor_top = b.get_path_to(top_target if top_target != null else b)
			b.focus_neighbor_bottom = b.get_path_to(b)
	if layout == "list":
		for i in rows.size():
			var r: Button = rows[i][0]
			var n: Button = rows[i][1]
			var up: Control = rows[i - 1][0] if i > 0 else list_button
			var down: Control = rows[i + 1][0] if i + 1 < rows.size() else r
			r.focus_neighbor_top = r.get_path_to(up)
			r.focus_neighbor_bottom = r.get_path_to(down)
			r.focus_neighbor_left = r.get_path_to(r)
			r.focus_neighbor_right = r.get_path_to(n if n.focus_mode != Control.FOCUS_NONE else r)
			n.focus_neighbor_left = n.get_path_to(r)
			n.focus_neighbor_right = n.get_path_to(n)
			var nu: Control = _prev_notify(i)
			var nd: Control = _next_notify(i)
			n.focus_neighbor_top = n.get_path_to(nu if nu != null else list_button)
			n.focus_neighbor_bottom = n.get_path_to(nd if nd != null else n)
	else:
		for d in day_buttons:
			var b: Button = day_buttons[d]
			# The top week goes up to the toolbar; Godot finds the rest spatially.
			if d <= 7:
				b.focus_neighbor_top = b.get_path_to(month_button)


func _prev_notify(i: int) -> Control:
	for j in range(i - 1, -1, -1):
		if rows[j][1].focus_mode != Control.FOCUS_NONE:
			return rows[j][1]
	return null


func _next_notify(i: int) -> Control:
	for j in range(i + 1, rows.size()):
		if rows[j][1].focus_mode != Control.FOCUS_NONE:
			return rows[j][1]
	return null


func default_body_focus() -> Control:
	if empty_card != null:
		var eb: Array = empty_card.get_meta("buttons")
		return eb[0] if not eb.is_empty() else null
	if layout == "list":
		return rows[0][0] if not rows.is_empty() else null
	var days: Array = day_buttons.keys()
	days.sort()
	var today := Model.ymd(ctx.now())
	for d in days:
		if int(today["year"]) != ym.x or int(today["month"]) != ym.y or d >= int(today["day"]):
			return day_buttons[d]
	if not days.is_empty():
		return day_buttons[days[0]]
	return undated_button


func set_top_target(c: Control) -> void:
	super.set_top_target(c)
	if list_button != null and is_instance_valid(list_button):
		for b in _toolbar():
			b.focus_neighbor_top = b.get_path_to(c)
	if empty_card != null and is_instance_valid(empty_card):
		for b in empty_card.get_meta("buttons"):
			b.focus_neighbor_top = b.get_path_to(c)


func default_focus() -> Control:
	var b := default_body_focus()
	return b if b != null else list_button


func hints(f: Control) -> Array:
	if empty_card != null:
		return [["A", T.HINT_SELECT]]
	if f in _toolbar():
		return [["A", T.HINT_SELECT], ["X", T.HINT_LAYOUT]]
	if f.has_meta("day") or f == undated_button:
		return [["A", T.HINT_OPEN], ["X", T.HINT_LAYOUT]]
	var v := view_of(f)
	if v.is_empty():
		return [["A", T.HINT_SELECT], ["X", T.HINT_LAYOUT]]
	var a := T.HINT_OPEN if f.get_meta("role", "") != "notify" else (T.HINT_UNNOTIFY if ctx.is_notifying(v) else T.HINT_NOTIFY)
	var out: Array = [["A", a]]
	if not v["data"].get("released", false) or ctx.is_notifying(v):
		out.append(["Y", T.HINT_UNNOTIFY if ctx.is_notifying(v) else T.HINT_NOTIFY])
	out.append(["X", T.HINT_LAYOUT])
	return out


func on_button(b: String, f: Control) -> bool:
	if b == "x":
		if empty_card != null:
			return false
		toggle_layout()
		return true
	if b == "y":
		var v := view_of(f)
		if v.is_empty():
			return false
		if v["data"].get("released", false) and not ctx.is_notifying(v):
			return true
		ctx.toggle_notify(v)
		return true
	return false


func back(f: Control) -> bool:
	# From the day panel, B goes back to the day.
	if layout == "month" and _panel != null and is_instance_valid(_panel) and _panel.is_ancestor_of(f):
		var target: Control = day_buttons.get(_panel_day, undated_button) if _panel_day > 0 else undated_button
		if target != null:
			target.grab_focus()
			return true
	return false


func on_art(key: String, kind: String, path: String) -> void:
	if kind != "cover":
		return
	W.ArtLinkScript.apply(views, key, kind, path)
	for c in find_children("Thumb", "", true, false):
		if c.view.get("key", "") == key:
			c.view["art"]["cover"] = path
			c.refresh()
