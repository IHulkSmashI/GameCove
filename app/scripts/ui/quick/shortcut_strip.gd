extends VBoxContainer
## The quick menu's Shortcuts strip: one row of large icon buttons above the
## tabs' rows, for the things people want in one press while they play
## (keyboard, screenshot, record, send a key, mouse mode, mute, sleep...).
##
## Which shortcuts show and in what order comes from ShortcutPrefs (Settings >
## Quick menu); of those, only the ones that work on this handheld right now
## show (Runner.context()). What a button does is the Runner's job
## (scripts/actions/runner.gd): the strip is only the buttons.
##
## Cheap by design, the menu's open time is budgeted (tests/e2e/suite_perf.gd):
##   * the buttons are built once (setup(), or when the list or the theme
##     changed) and kept while the menu is closed;
##   * refresh() only reads memory (the Controls cache, Recording's state) to
##     show, hide and tint what's already there: no program, no D-Bus call;
##   * a toggle's new state arrives later through Runner.state_changed.
## The sheets (Send a key, Power, the Force close question) are made the first
## time one is needed.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const CIcons := preload("res://scripts/ui/controls/cicons.gd")
const Registry := preload("res://scripts/actions/registry.gd")
const Prefs := preload("res://scripts/actions/shortcut_prefs.gd")
const Sheet := preload("res://scripts/ui/games/sheet.gd")
const T := preload("res://scripts/ui/quick/texts_shortcuts.gd")

## Asked to close the menu (an action that hands the screen back to the game).
signal close_requested
## The set of visible buttons changed (the menu links focus again).
signal relinked

const BUTTON_MIN := Vector2(56, 62)
const ICON_PX := 26
const GAP := 4

var runner: Object
## Where sheets go (the quick menu itself, so they cover its panel).
var sheet_host: Control
var buttons := {}            # id -> Button
var sheet: Control
var _row: HBoxContainer
var _scroll: ScrollContainer
var _built_sig := ""
var _last := ""              # the shortcut focus was on last
var _states := {}            # id -> what refresh() last drew


func setup(action_runner: Object, host: Control) -> void:
	name = "Shortcuts"
	runner = action_runner
	sheet_host = host
	add_theme_constant_override("separation", 0)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.follow_focus = true
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_scroll)
	# room for the focus ring and its glow, which are drawn outside a button
	var pad := Kit.margin(0, 4, 5)
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(pad)
	_row = Kit.hbox(GAP)
	_row.name = "Row"
	_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_child(_row)
	if runner != null and runner.has_signal("state_changed"):
		runner.state_changed.connect(_on_state_changed)
	build()


func _sig() -> String:
	return var_to_str([Prefs.shown(), ThemeLib.theme_id, ThemeLib.tokens.hash()])


## Makes the buttons for the shortcuts the user keeps shown (hidden until
## refresh() says they work here).
func build() -> void:
	for c in _row.get_children():
		_row.remove_child(c)
		c.queue_free()
	buttons.clear()
	_states.clear()
	for id in Prefs.shown():
		var a := Registry.action(id)
		if a.is_empty():
			continue
		var b := _button(a)
		_row.add_child(b)
		buttons[id] = b
	_built_sig = _sig()
	refresh()


func _button(a: Dictionary) -> Button:
	var b := Kit.button("", "RowButton")
	b.name = "Shortcut_" + str(a["id"])
	b.custom_minimum_size = BUTTON_MIN
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.tooltip_text = str(a["help"])
	b.set_meta("action", a["id"])
	var col := Kit.vbox(3)
	col.name = "Col"
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	icon.custom_minimum_size = Vector2(ICON_PX, ICON_PX)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(icon)
	var l := Label.new()
	l.name = "Name"
	l.text = str(a["short"])
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.clip_text = true
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override("font", ThemeLib.font("medium"))
	l.add_theme_font_size_override("font_size", ThemeLib.SIZE_MICRO)
	l.add_theme_color_override("font_color", ThemeLib.color("text"))
	col.add_child(l)
	b.add_child(col)
	var id: String = a["id"]
	b.pressed.connect(press.bind(id))
	b.focus_entered.connect(func(): _last = id)
	return b


## Shows the shortcuts that work right now and their state. Memory reads only.
func refresh() -> void:
	if _row == null:
		return
	if _built_sig != _sig():
		build()
		return
	var ctx: Dictionary = runner.context() if runner != null else {}
	var before := visible_ids()
	for id in buttons:
		var b: Button = buttons[id]
		var ok := runner != null and Registry.why_not(id, ctx) == ""
		b.visible = ok
		if ok:
			_paint(id, runner.state_of(id))
	visible = not visible_ids().is_empty()
	if before != visible_ids():
		_link_row()
		relinked.emit()


## Tints one button for its state (only when it changed).
func _paint(id: String, st: Dictionary) -> void:
	if _states.get(id) == st:
		return
	_states[id] = st
	var b: Button = buttons[id]
	var a := Registry.action(id)
	var on := bool(st.get("on", false))
	var acc: Color = ThemeLib.tone("bad") if id == "record" and on else ThemeLib.color("accent")
	var icon_col: Color = acc if on else ThemeLib.color("text")
	(b.get_node("Col/Icon") as TextureRect).texture = CIcons.tex(str(a["icon"]), ICON_PX, icon_col)
	var label := b.get_node("Col/Name") as Label
	var word := str(st.get("label", ""))
	label.text = word if word != "" else str(a["short"])
	for state in ["normal", "hover"]:
		b.remove_theme_stylebox_override(state)
	if on:
		# the quiet "on" look (a tint and a hairline); the ring stays focus's alone
		var sb := ThemeLib.box(Color(acc, 0.12 if ThemeLib.is_dark() else 0.10), ThemeLib.radius("m"), 18, 10)
		sb.border_color = Color(acc, 0.5)
		sb.set_border_width_all(1)
		b.add_theme_stylebox_override("normal", sb)
		b.add_theme_stylebox_override("hover", sb)
	b.disabled = bool(st.get("busy", false))


func _on_state_changed() -> void:
	if is_visible_in_tree():
		refresh()


## Ids of the buttons showing, left to right.
func visible_ids() -> Array:
	var out := []
	for c in _row.get_children():
		if c.visible and c.has_meta("action"):
			out.append(str(c.get_meta("action")))
	return out


func focusables() -> Array:
	return visible_ids().map(func(id): return buttons[id])


## The button Up from the rows (or Down from the tabs) lands on: the one used
## last when it still shows, else the first. null when the strip is empty.
func entry() -> Button:
	var ids := visible_ids()
	if ids.is_empty():
		return null
	return buttons[_last] if _last in ids else buttons[ids[0]]


func _link_row() -> void:
	Kit.link_horizontal(focusables())


## Ties the strip into the menu's focus chain: `above` (the open tab) over it,
## `below` (the tab's first row) under it.
func link(above: Control, below: Control) -> void:
	_link_row()
	for b in focusables():
		b.focus_neighbor_top = b.get_path_to(above) if above != null else b.get_path_to(b)
		b.focus_neighbor_bottom = b.get_path_to(below) if below != null else b.get_path_to(b)


# ---- pressing ---------------------------------------------------------------------------

## What A (or a tap) on a shortcut does.
func press(id: String) -> void:
	if runner == null or not runner.can_run(id):
		refresh()
		return
	match id:
		"send_key":
			_open_keys()
		"power_menu":
			_open_power()
		"force_close":
			_ask_force_close()
		_:
			runner.run(id, "strip")
			refresh()


func _sheet() -> Control:
	if sheet == null or not is_instance_valid(sheet):
		sheet = Sheet.new()
		sheet.name = "ShortcutSheet"
		(sheet_host if sheet_host != null else self).add_child(sheet)
		sheet.chosen.connect(_after_pick)
	return sheet


## The menu is closing: an open sheet goes with it.
func close_sheet() -> void:
	if sheet_open():
		sheet.close(false)


## A row was picked: the sheet doesn't hand focus back by itself. When the
## menu is still there and nothing else opened, focus returns to the shortcut.
func _after_pick(_id: String) -> void:
	_refocus.call_deferred()


func _refocus() -> void:
	if is_visible_in_tree() and not sheet_open() and entry() != null:
		entry().grab_focus()


func sheet_open() -> bool:
	return sheet != null and is_instance_valid(sheet) and sheet.is_open()


func _open_keys() -> void:
	var rows: Array = []
	for id in Registry.SEND_KEYS:
		var a := Registry.action(id)
		rows.append({"id": id, "text": a["title"], "detail": a["help"], "icon": "key"})
	_sheet().open(T.KEYS_TITLE, T.KEYS_LINE, rows, func(id: String): runner.run(id, "strip"))


func _ask_force_close() -> void:
	var g: Dictionary = runner.current_game.call() if runner.current_game.is_valid() else {}
	var title := str(g.get("title", T.THE_GAME))
	_sheet().open(T.FORCE_TITLE % title, T.FORCE_LINE, [
		{"id": "no", "text": T.FORCE_NO, "icon": "play"},
		{"id": "yes", "text": T.FORCE_YES, "icon": "x", "tone": "bad"},
	], func(id: String):
		if id == "yes":
			runner.run("force_close", "strip", true))


func _open_power() -> void:
	var rows: Array = []
	for r in Registry.POWER_ROWS:
		rows.append({"id": r[0], "text": r[1], "detail": r[2], "icon": r[3]})
	_sheet().open(T.POWER_TITLE, T.POWER_LINE, rows, _ask_power)


func _ask_power(what: String) -> void:
	var ctx: Dictionary = runner.context()
	var g: Dictionary = runner.current_game.call() if runner.current_game.is_valid() else {}
	var line := T.POWER_GAME_LINE % str(g.get("title", T.THE_GAME_CAP)) if bool(ctx.get("game_running", false)) else ""
	# the sheet that just closed gave focus back; open the question after it
	_open_power_confirm.call_deferred(what, line)


func _open_power_confirm(what: String, line: String) -> void:
	_sheet().open(str(T.POWER_CONFIRM.get(what, "")), line, [
		{"id": "no", "text": T.POWER_NO, "icon": "play"},
		{"id": "yes", "text": str(T.POWER_YES.get(what, "")), "icon": "power", "tone": "bad"},
	], func(id: String):
		if id == "yes":
			runner.power(what))
