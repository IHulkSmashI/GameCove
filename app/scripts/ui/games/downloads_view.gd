extends Control
## Downloads, under the top bar: a hero card for what's happening now (the
## game's art, title, big gradient progress bar, percent, size, speed, time
## left, Pause / Resume, Cancel, Game page), then two columns: "Up next" (rows;
## A for options: pause, move up / down, cancel, game page; X pauses) and
## "Finished" this session (A opens the game page). Opens from the top bar's
## downloads button or the Library. Live numbers update in place; nothing is
## rebuilt per tick.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const ArtCache := preload("res://scripts/ui/art_cache.gd")
const FallbackArt := preload("res://scripts/ui/fallback_art.gd")
const Illustrations := preload("res://scripts/ui/illustrations.gd")
const TG := preload("res://scripts/ui/texts_games.gd")
const GameIcons := preload("res://scripts/ui/games/game_icons.gd")
const ProgressLine := preload("res://scripts/ui/games/progress_line.gd")
const HeroStage := preload("res://scripts/ui/hero_stage.gd")

## Hero card height; the columns' rows.
const HERO_H := 250
const ROW_H := 88

signal back_requested
signal open_game(game: Dictionary)
## The empty state's button: show games that can be installed.
signal browse_requested

var state: Object
var actions: Object
## func(key: String) -> Dictionary: the Library game for a key ({} if none).
var game_for: Callable = func(_k: String) -> Dictionary: return {}
var title_label: Label
var summary_label: Label
var list: VBoxContainer
var empty: Control
var now_buttons: Array = []
## Focusable rows top to bottom (buttons and rows).
var focus_list: Array = []
## key -> {"bar": ProgressLine, "line": Label, "pct": Label}
var _live := {}
var _scroll: ScrollContainer
var empty_button: Button
var _base: ColorRect
## The two columns under the hero (children of `list`).
var next_col: VBoxContainer
var done_col: VBoxContainer
var _next_rows: Array = []
var _done_rows: Array = []
var _top_target: Control


func setup(install_state: Object, game_actions: Object, lookup: Callable) -> void:
	name = "Downloads"
	state = install_state
	actions = game_actions
	game_for = lookup
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_base = ColorRect.new()
	_base.name = "Base"
	Kit.fill(_base)
	add_child(_base)
	var margin := Kit.margin(0)
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", ThemeLib.EDGE)
	margin.add_theme_constant_override("margin_right", ThemeLib.EDGE)
	# The top bar stays: start where Home's hero card does.
	margin.add_theme_constant_override("margin_top", ThemeLib.TOP_BAR_H + ThemeLib.SPACE_3)
	margin.add_theme_constant_override("margin_bottom", 58)
	add_child(margin)
	var root := Kit.vbox(ThemeLib.SPACE_4)
	margin.add_child(root)
	# Title and queue summary, kept for the empty state and screen readers of
	# the layout; the hero card carries the same numbers when something runs.
	var head := Kit.hbox(ThemeLib.SPACE_3)
	head.name = "Head"
	head.add_child(GameIcons.rect("download", 26, ThemeLib.color("accent")))
	title_label = Kit.label(TG.DL_TITLE.to_upper(), "HeaderLabel")
	head.add_child(title_label)
	summary_label = Kit.micro("")
	summary_label.name = "Summary"
	summary_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(summary_label)
	root.add_child(head)
	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.follow_focus = true
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_scroll)
	var pad := Kit.margin(0, 0, 6)
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(pad)
	list = Kit.vbox(ThemeLib.SPACE_5)
	list.name = "List"
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_child(list)
	empty = _build_empty()
	root.add_child(empty)
	_restyle()
	if state != null:
		state.changed.connect(refresh)
		state.progress.connect(_on_progress)
	refresh()


func _restyle() -> void:
	_base.color = Color(ThemeLib.color("scrim"), 0.8)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _base != null:
		_restyle()


func _build_empty() -> Control:
	var row := Kit.hbox(32)
	row.name = "Empty"
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(Illustrations.rect("library", 200))
	var col := Kit.vbox(10)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(Kit.label(TG.DL_EMPTY, "HeaderLabel"))
	var l := Kit.label(TG.DL_EMPTY_SUB, "QuietLabel", true)
	l.custom_minimum_size = Vector2(380, 0)
	col.add_child(l)
	var b := Kit.button(TG.DL_BROWSE, "AccentButton")
	b.name = "Browse"
	b.custom_minimum_size = Vector2(0, 54)
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	b.icon = GameIcons.tex("library", 20)
	b.add_theme_constant_override("h_separation", 10)
	b.pressed.connect(func(): browse_requested.emit())
	col.add_child(b)
	empty_button = b
	row.add_child(col)
	return row


# ------------------------------------------------------------ build

func _game(d: Dictionary) -> Dictionary:
	var g: Dictionary = game_for.call(str(d.get("key", "")))
	if g.is_empty():
		var key := str(d.get("key", ""))
		g = {"key": key, "title": str(d.get("title", "")), "store": key.get_slice(":", 0), "id": key.get_slice(":", 1),
			"installed": false, "art": {"cover": "", "hero": "", "logo": "", "icon": ""}, "info": {}}
	return g


func refresh() -> void:
	var keep := _focused_id()
	for c in list.get_children():
		Kit.drop(list, c)
	_live.clear()
	now_buttons.clear()
	focus_list.clear()
	_next_rows.clear()
	_done_rows.clear()
	var queue: Array = state.queue if state != null else []
	var done: Array = state.done if state != null else []
	empty.visible = queue.is_empty() and done.is_empty()
	_scroll.visible = not empty.visible
	_summary(queue)
	var first := -1
	if not queue.is_empty():
		first = 0
		for i in queue.size():
			if str(queue[i].get("state", "")) == "running":
				first = i
				break
		list.add_child(_now_card(queue[first]))
	if not empty.visible:
		var cols := Kit.hbox(ThemeLib.SPACE_5)
		cols.name = "Columns"
		cols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		list.add_child(cols)
		next_col = _column(cols, "NextColumn", "%s (%d)" % [TG.DL_NEXT.to_upper(), maxi(queue.size() - 1, 0)], 1.35)
		done_col = _column(cols, "DoneColumn", "%s (%d)" % [TG.DL_DONE.to_upper(), done.size()], 1.0)
		for i in queue.size():
			if i != first:
				var r := _job_row(queue[i], i, queue.size())
				next_col.add_child(r)
				_next_rows.append(r)
		for d in done:
			var r := _done_row(d)
			done_col.add_child(r)
			_done_rows.append(r)
		if _next_rows.is_empty():
			next_col.add_child(_quiet_row(TG.DL_NEXT_NONE))
		if _done_rows.is_empty():
			done_col.add_child(_quiet_row(TG.DL_DONE_NONE))
	focus_list.append_array(_next_rows)
	focus_list.append_array(_done_rows)
	_link()
	if is_visible_in_tree():
		_restore_focus(keep)


## A column under the hero: caps header with a count, rows below.
func _column(parent: HBoxContainer, node_name: String, head: String, ratio: float) -> VBoxContainer:
	var col := Kit.vbox(ThemeLib.SPACE_3)
	col.name = node_name
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_stretch_ratio = ratio
	col.add_child(_section(head))
	parent.add_child(col)
	return col


func _quiet_row(text: String) -> PanelContainer:
	var p := PanelContainer.new()
	p.name = "None"
	p.theme_type_variation = "CardPanel"
	p.custom_minimum_size = Vector2(0, ROW_H)
	var l := Kit.label(text, "QuietLabel")
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	p.add_child(l)
	return p


## Focus: left / right along the hero's buttons, down into "Up next" (or
## "Finished"), up / down inside a column, left / right across the columns at
## the same row, up from the top rows back to the hero, up from the hero to
## the top bar.
func _link() -> void:
	Kit.link_vertical(_next_rows)
	Kit.link_vertical(_done_rows)
	var below_hero: Control = _next_rows[0] if not _next_rows.is_empty() else (_done_rows[0] if not _done_rows.is_empty() else null)
	for i in now_buttons.size():
		var b: Control = now_buttons[i]
		b.focus_neighbor_left = b.get_path_to(now_buttons[i - 1] if i > 0 else b)
		b.focus_neighbor_right = b.get_path_to(now_buttons[i + 1] if i + 1 < now_buttons.size() else b)
		b.focus_neighbor_bottom = b.get_path_to(below_hero if below_hero != null else b)
		b.focus_neighbor_top = b.get_path_to(b)
	var hero_first: Control = now_buttons[0] if not now_buttons.is_empty() else null
	for rows in [_next_rows, _done_rows]:
		if not rows.is_empty():
			var top: Control = hero_first if hero_first != null else rows[0]
			rows[0].focus_neighbor_top = rows[0].get_path_to(top)
	for i in _next_rows.size():
		if not _done_rows.is_empty():
			_next_rows[i].focus_neighbor_right = _next_rows[i].get_path_to(_done_rows[mini(i, _done_rows.size() - 1)])
	for i in _done_rows.size():
		if not _next_rows.is_empty():
			_done_rows[i].focus_neighbor_left = _done_rows[i].get_path_to(_next_rows[mini(i, _next_rows.size() - 1)])
	_link_top()


## D-pad up from the top of the view goes to `c` (the top bar's tab).
func set_top_target(c: Control) -> void:
	_top_target = c
	_link_top()


func _link_top() -> void:
	if not is_instance_valid(_top_target) or not is_inside_tree() or not _top_target.is_inside_tree():
		return
	var tops: Array = now_buttons.duplicate()
	if now_buttons.is_empty():
		for rows in [_next_rows, _done_rows]:
			if not rows.is_empty():
				tops.append(rows[0])
		if empty.visible and empty_button != null:
			tops.append(empty_button)
	for c in tops:
		c.focus_neighbor_top = c.get_path_to(_top_target)


func _summary(queue: Array) -> void:
	if queue.is_empty():
		summary_label.text = ""
		return
	var bits: Array[String] = ["%d in the queue" % queue.size() if queue.size() != 1 else "1 in the queue"]
	var r := TG.rate(state.total_rate())
	if r != "":
		bits.append(r)
	summary_label.text = " · ".join(bits)


func _section(text: String) -> Label:
	var l := Kit.label(text.to_upper(), "HeaderLabel")
	l.add_theme_font_size_override("font_size", ThemeLib.SIZE_LEAD)
	l.add_theme_constant_override("line_spacing", 0)
	return l


func _thumb(g: Dictionary, size: Vector2) -> Control:
	var box := Control.new()
	box.custom_minimum_size = size
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fb := FallbackArt.new()
	fb.setup(g, 13 if size.x < 80 else 18, float(ThemeLib.radius("s")), size.x >= 80)
	Kit.fill(fb)
	box.add_child(fb)
	var path := str(g.get("art", {}).get("cover", ""))
	if ArtCache.usable(path):
		var art := TextureRect.new()
		Kit.fill(art)
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		box.add_child(art)
		var ref: WeakRef = weakref(art)
		var tex := ArtCache.request("cover", path, func(t):
			var a: TextureRect = ref.get_ref()
			if a != null:
				a.texture = t, self)
		if tex != null:
			art.texture = tex
	return box


func _job_text(d: Dictionary) -> String:
	var key := str(d.get("key", ""))
	var st: String = state.state_of(key)
	var action := str(d.get("action", "install"))
	if st == "paused" or str(d.get("state", "")) == "paused":
		return TG.STATE_LABEL["paused"]
	if st in TG.RUNNING or str(d.get("state", "")) == "running":
		return TG.ACTION_ING.get(action, "Working")
	return TG.QUEUED_AS.get(action, TG.STATE_LABEL["queued"])


func _now_card(d: Dictionary) -> PanelContainer:
	var key := str(d.get("key", ""))
	var g := _game(d)
	var p := PanelContainer.new()
	p.name = "Now"
	p.custom_minimum_size = Vector2(0, HERO_H)
	p.add_theme_stylebox_override("panel", _hero_box())
	# The game's art on the right, dissolving toward the text on the left.
	var art := HeroStage.new()
	art.frame_radius = float(ThemeLib.radius("xl"))
	art.set_anchors_preset(Control.PRESET_FULL_RECT)
	p.add_child(art)
	art.show_game(g)
	var edge := Panel.new()
	edge.name = "Edge"
	edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	edge.add_theme_stylebox_override("panel", _hero_edge())
	p.add_child(edge)
	var pad := Kit.margin(0, 40, 32)
	p.add_child(pad)
	var row := Kit.hbox(ThemeLib.SPACE_6)
	pad.add_child(row)
	var col := Kit.vbox(ThemeLib.SPACE_3)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_stretch_ratio = 1.6
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(col)
	var what := Kit.micro(_eyebrow(d), "EyebrowLabel")
	what.name = "What"
	col.add_child(what)
	var t := Kit.label(str(g.get("title", d.get("title", ""))), "TitleLabel")
	t.name = "Title"
	t.uppercase = true
	t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	t.clip_text = true
	col.add_child(t)
	var nums := Kit.hbox(ThemeLib.SPACE_4)
	var pct := Kit.label("", "NumberLabel")
	pct.name = "Percent"
	pct.add_theme_font_override("font", ThemeLib.mono(true, 1))
	pct.add_theme_font_size_override("font_size", ThemeLib.SIZE_LEAD)
	pct.add_theme_color_override("font_color", ThemeLib.color("accent"))
	nums.add_child(pct)
	var line := Kit.label("", "MonoLabel")
	line.name = "Numbers"
	line.add_theme_font_override("font", ThemeLib.mono(false, 1))
	line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nums.add_child(line)
	col.add_child(nums)
	var bar := ProgressLine.new(12.0)
	bar.gradient = true
	bar.name = "Bar"
	col.add_child(bar)
	_live[key] = {"bar": bar, "line": line, "pct": pct}
	_update_live(key)
	var buttons := Kit.hbox(ThemeLib.SPACE_3)
	buttons.name = "Buttons"
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(buttons)
	var c: Dictionary = actions.caps(g) if actions != null else {}
	var paused: bool = state.state_of(key) == "paused" or str(d.get("state", "")) == "paused"
	var can_toggle: bool = c.get("resume" if paused else "pause", false)
	if can_toggle:
		var pb := _button(TG.RESUME if paused else TG.PAUSE, "play" if paused else "pause", "Toggle_" + key, key, func(): actions.toggle_pause(g), true)
		buttons.add_child(pb)
	if c.get("cancel", false):
		buttons.add_child(_button(TG.CANCEL, "x", "Cancel_" + key, key, func(): actions.cancel(g)))
	if not can_toggle and str(g.get("store", "")) == "steam":
		buttons.add_child(_button(TG.DL_STEAM_PAGE, "external", "Steam_" + key, key, func(): actions.open_steam(g, "downloads")))
	buttons.add_child(_button(TG.DL_PAGE, "info", "Page_" + key, key, func(): open_game.emit(g)))
	for b in buttons.get_children():
		now_buttons.append(b)
		focus_list.append(b)
	if not can_toggle and not c.get("cancel", false) and c.has("why"):
		var why := Kit.label(TG.why(c, "pause"), "QuietLabel", true)
		why.add_theme_font_size_override("font_size", ThemeLib.SIZE_CAPTION)
		col.add_child(why)
	return p


## "NOW DOWNLOADING", "NOW UPDATING", "PAUSED" ... over the title.
func _eyebrow(d: Dictionary) -> String:
	var t := _job_text(d)
	if t == TG.STATE_LABEL["paused"]:
		return t
	return TG.DL_NOW_PREFIX + " " + t.to_lower()


## The hero card: the page's glass behind the art, an accent hairline on top.
func _hero_box() -> StyleBoxFlat:
	var sb := ThemeLib.box(ThemeLib.color("surface"), ThemeLib.radius("xl"), 0, 0)
	return sb


func _hero_edge() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.draw_center = false
	sb.border_color = Color(ThemeLib.color("accent"), 0.35)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(ThemeLib.radius("xl"))
	sb.anti_aliasing = true
	return sb


func _button(text: String, icon: String, node_name: String, key: String, cb: Callable, primary := false) -> Button:
	var b := Kit.button(text, "AccentButton" if primary else "")
	b.name = node_name.validate_node_name()
	b.custom_minimum_size = Vector2(150 if primary else 0, 52)
	b.icon = GameIcons.tex(icon, 20)
	b.add_theme_constant_override("h_separation", 10)
	b.pressed.connect(cb)
	b.set_meta("dl_key", key)
	return b


func _job_row(d: Dictionary, index: int, count: int) -> Button:
	var key := str(d.get("key", ""))
	var g := _game(d)
	var b := Kit.button("", "RowButton")
	b.name = ("Job_" + key).validate_node_name()
	b.set_meta("dl_key", key)
	b.custom_minimum_size = Vector2(0, ROW_H)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var row := Kit.hbox(16)
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 16
	row.offset_right = -20
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(row)
	var th := _thumb(g, Vector2(44, 64))
	th.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(th)
	var col := Kit.vbox(4)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var t := Kit.label(str(g.get("title", "")), "HeaderLabel")
	t.add_theme_font_size_override("font_size", ThemeLib.SIZE_BODY)
	t.uppercase = true
	t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(t)
	var sub := _job_text(d)
	if int(d.get("size", 0)) > 0:
		sub += " · " + TG.bytes(int(d["size"]))
	var line := Kit.label(sub, "QuietLabel")
	line.add_theme_font_override("font", ThemeLib.mono(false, 1))
	line.add_theme_font_size_override("font_size", ThemeLib.SIZE_CAPTION - 1)
	col.add_child(line)
	row.add_child(col)
	var right := Kit.vbox(6)
	right.alignment = BoxContainer.ALIGNMENT_CENTER
	right.custom_minimum_size = Vector2(120, 0)
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pct := Kit.label("", "CaptionLabel")
	pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	pct.add_theme_font_override("font", ThemeLib.mono(true, 1))
	pct.add_theme_color_override("font_color", ThemeLib.color("accent"))
	right.add_child(pct)
	var bar := ProgressLine.new(6.0)
	right.add_child(bar)
	row.add_child(right)
	_live[key] = {"bar": bar, "line": null, "pct": pct}
	_update_live(key)
	if str(d.get("state", "")) == "queued" and state.fraction(key) < 0.0:
		pct.text = "#%d" % (index + 1) if count > 2 else ""
	b.pressed.connect(func(): _options(d, g, index, count))
	return b


func _done_row(d: Dictionary) -> Button:
	var key := str(d.get("key", ""))
	var g := _game(d)
	var b := Kit.button("", "RowButton")
	b.name = ("Done_" + key + "_" + str(d.get("at", 0))).validate_node_name()
	b.set_meta("dl_done", key)
	b.custom_minimum_size = Vector2(0, ROW_H)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var row := Kit.hbox(16)
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 16
	row.offset_right = -20
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(row)
	var ok: bool = d.get("ok", false)
	var th := _thumb(g, Vector2(44, 64))
	th.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(th)
	var col := Kit.vbox(4)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(col)
	var t := Kit.label(str(g.get("title", d.get("title", ""))), "HeaderLabel")
	t.add_theme_font_size_override("font_size", ThemeLib.SIZE_BODY)
	t.uppercase = true
	t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(t)
	var msg := str(d.get("message", ""))
	var what: String = TG.ACTION_DONE.get(str(d.get("action", "")), "Done") if ok else TG.failed(str(d.get("action", "")), "").replace(" this game", "") + (": " + msg if msg != "" else "")
	var when := TG.ago(int(d.get("at", 0)), int(state.clock.call()) if state != null else int(d.get("at", 0)))
	var l := Kit.label(what + (" · " + when if when != "" else ""), "QuietLabel")
	l.add_theme_font_override("font", ThemeLib.mono(false, 1))
	l.add_theme_font_size_override("font_size", ThemeLib.SIZE_CAPTION - 1)
	l.add_theme_color_override("font_color", ThemeLib.color("good") if ok else ThemeLib.color("bad"))
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(l)
	row.add_child(GameIcons.rect("check" if ok else "alert", 22, ThemeLib.color("good") if ok else ThemeLib.color("bad")))
	b.pressed.connect(func(): open_game.emit(g))
	return b


# ------------------------------------------------------------ live

func _on_progress(key: String) -> void:
	if _live.has(key):
		_update_live(key)
	if state != null:
		_summary(state.queue)


func _update_live(key: String) -> void:
	var w: Dictionary = _live[key]
	var f: float = state.fraction(key) if state != null else -1.0
	var st: String = state.state_of(key) if state != null else ""
	w["bar"].set_value(f)
	w["bar"].visible = f >= 0.0
	w["bar"].set_color(ThemeLib.color("text_3") if st == "paused" else Color(0, 0, 0, 0))
	w["pct"].text = ("%d%%" % roundi(f * 100.0)) if f >= 0.0 else ""
	if w["line"] != null:
		var nums := TG.progress_line(state.progress_of(key)) if st != "paused" else TG.progress_line({"bytes_done": state.progress_of(key).get("bytes_done", -1), "bytes_total": state.progress_of(key).get("bytes_total", 0)})
		w["line"].text = nums if nums != "" else ("Waiting for numbers from the store…" if st != "paused" else "")


# ------------------------------------------------------------ options / input

func _options(d: Dictionary, g: Dictionary, index: int, count: int) -> void:
	if actions == null:
		return
	var key := str(d.get("key", ""))
	var c: Dictionary = actions.caps(g)
	var paused: bool = state.state_of(key) == "paused" or str(d.get("state", "")) == "paused"
	var steam := str(g.get("store", "")) == "steam"
	var rows: Array = []
	if c.get("resume" if paused else "pause", false):
		rows.append({"id": "resume" if paused else "pause", "text": TG.RESUME if paused else TG.PAUSE, "icon": "play" if paused else "pause"})
	if not steam and index > 0:
		rows.append({"id": "up", "text": TG.DL_UP, "icon": "arrow_up"})
	if not steam and index < count - 1:
		rows.append({"id": "down", "text": TG.DL_DOWN, "icon": "arrow_down"})
	if c.get("cancel", false):
		rows.append({"id": "cancel", "text": TG.CANCEL_DOWNLOAD, "detail": TG.CANCEL_DETAIL, "icon": "x", "tone": "bad"})
	if steam:
		rows.append({"id": "steam_downloads", "text": TG.DL_STEAM_PAGE, "icon": "external"})
	rows.append({"id": "page", "text": TG.DL_PAGE, "icon": "info"})
	actions.open_menu(str(g.get("title", "")), _job_text(d), rows, func(id: String):
		if id == "page":
			open_game.emit(g)
		else:
			actions.run(id, g))


## X on a job: pause or resume it.
func toggle_focused() -> bool:
	var key := _focused_key()
	if key == "" or actions == null:
		return false
	var g := _game(state.job(key) if not state.job(key).is_empty() else {"key": key})
	var c: Dictionary = actions.caps(g)
	var paused: bool = state.state_of(key) == "paused"
	if not c.get("resume" if paused else "pause", false):
		return false
	actions.toggle_pause(g)
	return true


func _focused_key() -> String:
	if not is_inside_tree():
		return ""
	var f := get_viewport().gui_get_focus_owner()
	if f != null and is_ancestor_of(f) and f.has_meta("dl_key"):
		return str(f.get_meta("dl_key"))
	return ""


func _focused_id() -> String:
	if not is_inside_tree():
		return ""
	var f := get_viewport().gui_get_focus_owner()
	return String(f.name) if f != null and is_ancestor_of(f) else ""


func _restore_focus(id: String) -> void:
	if id != "":
		for c in focus_list:
			if String(c.name) == id:
				c.grab_focus()
				return
	var f := default_focus()
	if f != null:
		f.grab_focus()


func default_focus() -> Control:
	if focus_list.is_empty():
		return empty_button if empty.visible else null
	return focus_list[0]


func hints_for_focus(f: Control) -> Array:
	var out: Array = []
	if f != null and f.has_meta("dl_done"):
		out.append(["A", TG.DL_PAGE])
	elif f != null and f.theme_type_variation == "RowButton" and f.has_meta("dl_key"):
		out.append(["A", TG.DL_OPTIONS])
		var key := str(f.get_meta("dl_key"))
		out.append(["X", TG.RESUME if state != null and state.state_of(key) == "paused" else TG.PAUSE])
	elif f != null:
		out.append(["A", "Select"])
	out.append(["B", "Back"])
	return out


func open() -> void:
	refresh()
	Motion.fade(self, true)
	var f := default_focus()
	if f != null and is_inside_tree():
		f.grab_focus()
