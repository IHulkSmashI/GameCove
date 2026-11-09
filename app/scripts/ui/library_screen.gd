extends Control
## Library: every game as a dense cover grid, filtered by store, sorted
## (recent, A to Z, most played, shortest first) and searched with the
## on-screen keyboard (Y) or a physical one. X cycles the sort. Installed /
## Not installed chips narrow it down; a Downloads chip shows while anything
## is in the queue. Tiles show install state (main passes a tile_hook).

const Kit := preload("res://scripts/ui/ui_kit.gd")
const View := preload("res://scripts/ui/library_view.gd")
const Tile := preload("res://scripts/ui/game_tile.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const Illustrations := preload("res://scripts/ui/illustrations.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const Osk := preload("res://scripts/ui/osk.gd")

signal open_requested(game: Dictionary)
signal game_focused(game: Dictionary)
signal downloads_requested

const INSTALL_FILTERS := [["installed", "Installed"], ["not_installed", "Not installed"]]

const GAP := Vector2(18, 20)
const PAD := Vector2(24, 20)

var games: Array = []
var shown: Array = []
var store := ""
var sort := "recent"
var query := ""
## "" (all) | "installed" | "not_installed"
var install_filter := ""
## Called with every new tile (install badges and progress).
var tile_hook: Callable = Callable()
var filter_buttons: Array = []
var downloads_chip: Button
var top_target: Control

var search_button: Button
var sort_button: Button
var store_buttons: Array = []
var count_label: Label
var details: PanelContainer
var cue: HBoxContainer
var _fade: TextureRect
var _d_title: Label
var _d_meta: HBoxContainer
var _d_badges: HBoxContainer
var grid: GridContainer
var keyboard: PanelContainer
var _scroll: ScrollContainer
var _empty: Control
var _empty_text: Label
var _tiles: Array = []
var _memory_key := ""


func _init() -> void:
	name = "Library"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var margin := Kit.margin(0)
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 48 - int(PAD.x))
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 88)
	margin.add_theme_constant_override("margin_bottom", 58)
	add_child(margin)
	var root := Kit.vbox(10)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(root)

	var head := Kit.hbox(14)
	head.name = "Head"
	var title := Kit.label("Library", "TitleLabel")
	head.add_child(title)
	var dot := Kit.label("·", "TitleLabel")
	dot.add_theme_color_override("font_color", ThemeLib.color("text_3"))
	head.add_child(dot)
	count_label = Kit.label("", "TitleLabel")
	count_label.name = "Count"
	count_label.add_theme_color_override("font_color", ThemeLib.color("accent"))
	head.add_child(count_label)
	var head_pad := Kit.margin(0, int(PAD.x), 0)
	head_pad.add_child(head)
	root.add_child(head_pad)

	var bar := Kit.hbox(10)
	bar.name = "Toolbar"
	search_button = Kit.button("", "ChipButton")
	search_button.name = "Search"
	search_button.custom_minimum_size = Vector2(164, 44)
	search_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	search_button.add_theme_constant_override("h_separation", 10)
	search_button.pressed.connect(open_search)
	bar.add_child(search_button)
	var sep := Control.new()
	sep.custom_minimum_size = Vector2(6, 0)
	bar.add_child(sep)
	for s in View.STORES:
		var b := Kit.button(s[1], "ChipButton")
		b.name = "Store_" + (s[0] if s[0] != "" else "all")
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(0, 44)
		var id: String = s[0]
		b.pressed.connect(func(): set_store(id))
		bar.add_child(b)
		store_buttons.append(b)
	var sep2 := Control.new()
	sep2.custom_minimum_size = Vector2(6, 0)
	bar.add_child(sep2)
	for f in INSTALL_FILTERS:
		var fb := Kit.button(f[1], "ChipButton")
		fb.name = "Filter_" + f[0]
		fb.toggle_mode = true
		fb.custom_minimum_size = Vector2(0, 44)
		var fid: String = f[0]
		fb.pressed.connect(func(): set_install_filter("" if install_filter == fid else fid))
		bar.add_child(fb)
		filter_buttons.append(fb)
	bar.add_child(Kit.spacer())
	downloads_chip = Kit.button("", "ChipButton")
	downloads_chip.name = "DownloadsChip"
	downloads_chip.custom_minimum_size = Vector2(0, 44)
	downloads_chip.add_theme_constant_override("h_separation", 8)
	downloads_chip.visible = false
	downloads_chip.pressed.connect(func(): downloads_requested.emit())
	bar.add_child(downloads_chip)
	sort_button = Kit.button("", "ChipButton")
	sort_button.name = "Sort"
	sort_button.custom_minimum_size = Vector2(0, 44)
	sort_button.add_theme_constant_override("h_separation", 8)
	sort_button.pressed.connect(func(): cycle_sort(1))
	bar.add_child(sort_button)
	var bar_pad := Kit.margin(0, int(PAD.x), 0)
	bar_pad.add_child(bar)
	root.add_child(bar_pad)

	var area := Control.new()
	area.name = "GridArea"
	area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	area.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(area)
	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.follow_focus = false
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	area.add_child(_scroll)
	_fade = TextureRect.new()
	_fade.name = "Fade"
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_fade.stretch_mode = TextureRect.STRETCH_SCALE
	_fade.anchor_top = 1.0
	_fade.anchor_right = 1.0
	_fade.anchor_bottom = 1.0
	_fade.offset_top = -72
	area.add_child(_fade)
	cue = Kit.icon_label("chevron_down", "More below", "CaptionLabel", ThemeLib.color("text_2"), 18, false)
	cue.name = "MoreCue"
	cue.anchor_left = 0.5
	cue.anchor_right = 0.5
	cue.anchor_top = 1.0
	cue.anchor_bottom = 1.0
	cue.offset_left = -70
	cue.offset_right = 70
	cue.offset_top = -28
	cue.offset_bottom = -4
	cue.alignment = BoxContainer.ALIGNMENT_CENTER
	area.add_child(cue)
	_scroll.get_v_scroll_bar().value_changed.connect(func(_v): _update_cue())
	_scroll.get_v_scroll_bar().changed.connect(_update_cue)
	var pad := Kit.margin(0, int(PAD.x), int(PAD.y))
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(pad)
	grid = GridContainer.new()
	grid.name = "Grid"
	grid.columns = 7
	grid.add_theme_constant_override("h_separation", int(GAP.x))
	grid.add_theme_constant_override("v_separation", int(GAP.y))
	pad.add_child(grid)

	details = _build_details()
	var dpad := Kit.margin(0, int(PAD.x), 0)
	dpad.add_child(details)
	root.add_child(dpad)

	_empty = Kit.hbox(28)
	_empty.add_theme_constant_override("separation", 28)
	_empty.name = "Empty"
	_empty.alignment = BoxContainer.ALIGNMENT_CENTER
	_empty.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_empty.add_child(Illustrations.rect("no_results", 180))
	var ecol := Kit.vbox(8)
	ecol.alignment = BoxContainer.ALIGNMENT_CENTER
	ecol.add_child(Kit.label("Nothing here", "HeaderLabel"))
	_empty_text = Kit.label("", "QuietLabel", true)
	_empty_text.name = "EmptyFilter"
	_empty_text.custom_minimum_size = Vector2(380, 0)
	ecol.add_child(_empty_text)
	_empty.add_child(ecol)
	root.add_child(_empty)

	keyboard = Osk.new()
	keyboard.anchor_left = 0.5
	keyboard.anchor_right = 0.5
	keyboard.anchor_top = 1.0
	keyboard.anchor_bottom = 1.0
	keyboard.offset_left = -400
	keyboard.offset_right = 400
	keyboard.offset_top = -420
	keyboard.offset_bottom = -64
	keyboard.text_changed.connect(set_query)
	keyboard.closed.connect(func(_t): _after_search())
	add_child(keyboard)
	_refresh_toolbar()
	set_games([])


# ------------------------------------------------------------ data in

func set_games(list: Array) -> void:
	games = list
	_rebuild(true)


func set_store(id: String) -> void:
	store = id
	_rebuild(false)


func cycle_store(d: int) -> void:
	var ids: Array = View.STORES.map(func(s): return s[0])
	set_store(ids[posmod(ids.find(store) + d, ids.size())])
	if is_inside_tree() and is_visible_in_tree():
		_current_store_button().grab_focus()


func set_sort(mode: String) -> void:
	sort = mode if mode in View.SORTS else "recent"
	_rebuild(false)


func set_install_filter(f: String) -> void:
	install_filter = f if f in ["installed", "not_installed"] else ""
	_rebuild(false)


## Games kept by an install filter ("" keeps all).
static func filter_install(list: Array, f: String) -> Array:
	if f == "installed":
		return list.filter(func(g): return g.get("installed", false))
	if f == "not_installed":
		return list.filter(func(g): return not g.get("installed", false))
	return list


## The Downloads chip: shown while `jobs` > 0, with overall progress (0..1, -1 unknown).
func set_downloads(jobs: int, overall := -1.0) -> void:
	var was := downloads_chip.visible
	downloads_chip.visible = jobs > 0
	downloads_chip.text = ("%d%%" % roundi(overall * 100.0)) if overall >= 0.0 else str(jobs)
	downloads_chip.tooltip_text = "Downloads"
	downloads_chip.icon = load("res://scripts/ui/games/game_icons.gd").tex("download", 20)
	if was != downloads_chip.visible:
		_link_toolbar()


func cycle_sort(d := 1) -> void:
	set_sort(View.SORTS[posmod(View.SORTS.find(sort) + d, View.SORTS.size())])


func set_query(q: String) -> void:
	query = q
	_rebuild(false)


func open_search() -> void:
	keyboard.open(query)


func searching() -> bool:
	return keyboard.visible


func tiles() -> Array:
	return _tiles


func default_focus() -> Control:
	if not _tiles.is_empty():
		for t in _tiles:
			if t.game.get("key", "") == _memory_key:
				return t
		return _tiles[0]
	return _current_store_button()


func set_top_target(c: Control) -> void:
	top_target = c
	_link_toolbar()


# ------------------------------------------------------------ build

func _rebuild(keep_focus: bool) -> void:
	var focused_key := ""
	if keep_focus and is_inside_tree():
		var f := get_viewport().gui_get_focus_owner()
		if f != null and f in _tiles:
			focused_key = f.game.get("key", "")
	shown = View.sort_games(View.search(filter_install(View.filter_by_store(games, store), install_filter), query), sort)
	for t in _tiles:
		Kit.drop(grid, t)
	_tiles.clear()
	for g in shown:
		var t: Button = Tile.new()
		t.setup(g, true, Tile.SIZE, false)
		var game: Dictionary = g
		t.pressed.connect(func(): open_requested.emit(game))
		t.focus_entered.connect(_on_tile_focus.bind(t))
		grid.add_child(t)
		_tiles.append(t)
		if tile_hook.is_valid():
			tile_hook.call(t)
	_refresh_toolbar()
	_link_grid()
	_empty.visible = shown.is_empty()
	_scroll.get_parent().visible = not shown.is_empty()
	details.get_parent().visible = not shown.is_empty()
	if games.is_empty():
		_empty_text.text = "Your games will show up here once a store has some installed."
	elif query != "":
		_empty_text.text = "No games match \"%s\". Try fewer letters or another store." % query
	elif shown.is_empty() and install_filter != "":
		_empty_text.text = ("Nothing installed here yet. Clear the Installed filter to see everything you own." if install_filter == "installed"
			else "Everything here is installed. Clear the filter to see all your games.")
	elif shown.is_empty():
		_empty_text.text = "No %s games found. Pick another store or All." % View.store_name(store)
	count_label.text = ("%d of %d" % [shown.size(), games.size()]) if shown.size() != games.size() else ("%d games" % games.size() if games.size() != 1 else "1 game")
	if focused_key != "":
		for t in _tiles:
			if t.game.get("key", "") == focused_key:
				_focus_later(t)
				return


func _refresh_toolbar() -> void:
	var ids: Array = View.STORES.map(func(s): return s[0])
	for i in store_buttons.size():
		store_buttons[i].set_pressed_no_signal(ids[i] == store)
	for i in filter_buttons.size():
		filter_buttons[i].set_pressed_no_signal(INSTALL_FILTERS[i][0] == install_filter)
	search_button.text = query if query != "" else "Search"
	search_button.icon = Icons.tex("search", 20)
	sort_button.text = View.SORT_NAMES[sort]
	sort_button.icon = Icons.tex("sort", 20)
	_link_toolbar()


func _toolbar() -> Array:
	var out: Array = [search_button]
	out.append_array(store_buttons)
	out.append_array(filter_buttons)
	if downloads_chip != null and downloads_chip.visible:
		out.append(downloads_chip)
	out.append(sort_button)
	return out


func _link_toolbar() -> void:
	var bar := _toolbar()
	Kit.link_horizontal(bar)
	for b in bar:
		b.focus_neighbor_top = b.get_path_to(top_target if top_target != null else b)
		var down: Control = default_focus() if not _tiles.is_empty() else b
		b.focus_neighbor_bottom = b.get_path_to(down)


func _link_grid() -> void:
	var cols := grid.columns
	for i in _tiles.size():
		var t: Control = _tiles[i]
		var up: Control = _tiles[i - cols] if i >= cols else _current_store_button()
		var down: Control = _tiles[i + cols] if i + cols < _tiles.size() else (_tiles[_tiles.size() - 1] if i / cols < (_tiles.size() - 1) / cols else t)
		t.focus_neighbor_top = t.get_path_to(up)
		t.focus_neighbor_bottom = t.get_path_to(down)
		t.focus_neighbor_left = t.get_path_to(_tiles[i - 1] if i % cols > 0 else t)
		t.focus_neighbor_right = t.get_path_to(_tiles[i + 1] if i % cols < cols - 1 and i + 1 < _tiles.size() else t)


func _current_store_button() -> Button:
	var ids: Array = View.STORES.map(func(s): return s[0])
	return store_buttons[maxi(0, ids.find(store))]


func _on_tile_focus(t: Control) -> void:
	_memory_key = t.game.get("key", "")
	show_details(t.game)
	for b in _toolbar():
		b.focus_neighbor_bottom = b.get_path_to(t)
	var row := _tiles.find(t) / grid.columns
	var pitch := Tile.SIZE.y + GAP.y
	# Keep the focused row fully above the bottom fade, showing as much of the
	# rows above it as fits.
	var bottom := (row + 1) * pitch + PAD.y + 40.0
	var target := clampf(bottom - _scroll.size.y, 0.0, row * pitch)
	Motion.method(_scroll, "vscroll", func(v: float): _scroll.scroll_vertical = int(v),
		float(_scroll.scroll_vertical), target, Motion.BASE)
	game_focused.emit(t.game)


## The slim bar under the grid: the focused game's title, store, playtime
## and badges (tiles in the grid carry one corner pill at most).
func _build_details() -> PanelContainer:
	var p := PanelContainer.new()
	p.name = "Details"
	p.theme_type_variation = "CardPanel"
	var row := Kit.hbox(18)
	p.add_child(row)
	var pill := PanelContainer.new()
	pill.name = "SelectedPill"
	pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pl := Kit.micro("Selected", "MicroLabel")
	pl.name = "Text"
	pl.add_theme_font_override("font", ThemeLib.mono(true, 2))
	pill.add_child(pl)
	row.add_child(pill)
	_d_title = Kit.label("", "HeaderLabel")
	_d_title.name = "Title"
	_d_title.max_lines_visible = 1
	row.add_child(_d_title)
	_d_meta = Kit.hbox(18)
	_d_meta.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_d_meta)
	_style_details(p)
	# No spacer: the meta line takes all the free width (a spacer split it
	# in half and cut "Played…" short with room to spare).
	_d_badges = Kit.hbox(8)
	row.add_child(_d_badges)
	return p


## The details bar: an accent-edged card with a solid SELECTED pill.
func _style_details(p: PanelContainer) -> void:
	var acc := ThemeLib.color("accent")
	var sb := ThemeLib.card(22, 12)
	sb.border_color = Color(acc, 0.45)
	p.add_theme_stylebox_override("panel", sb)
	var pill := p.find_child("SelectedPill", true, false) as PanelContainer
	if pill != null:
		pill.add_theme_stylebox_override("panel", ThemeLib.box(acc, 4, 8, 3))
		(pill.get_node("Text") as Label).add_theme_color_override("font_color", ThemeLib.color("on_accent"))


func show_details(g: Dictionary) -> void:
	_d_title.text = g.get("title", "")
	for c in _d_meta.get_children():
		Kit.drop(_d_meta, c)
	var GH = load("res://scripts/ui/game_header.gd")
	var parts: Array[String] = []
	for seg in GH.meta_segments(g, int(Time.get_unix_time_from_system())).slice(0, 3):
		parts.append(seg[1])
	var m := Kit.label("  ·  ".join(parts), "MonoLabel")
	m.add_theme_font_override("font", ThemeLib.mono(false, 1))
	m.add_theme_color_override("font_color", ThemeLib.color("text_2"))
	m.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	m.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_d_meta.add_child(m)
	for c in _d_badges.get_children():
		Kit.drop(_d_badges, c)
	var n := 0
	for b in load("res://scripts/ui/badges.gd").for_game(g):
		if b["kind"] == "store" or n >= 3:
			continue
		_d_badges.add_child(load("res://scripts/ui/badge.gd").make(b, "chip"))
		n += 1


func _update_cue() -> void:
	var bar := _scroll.get_v_scroll_bar()
	var more := bar.max_value - bar.page - bar.value > 24.0
	cue.visible = more
	_fade.visible = more


## LT / RT: jump to the previous / next first letter in the current order.
func jump_letter(d: int) -> void:
	if _tiles.is_empty() or not is_inside_tree():
		return
	var f := get_viewport().gui_get_focus_owner()
	var i := maxi(0, _tiles.find(f))
	var cur := _initial(_tiles[i].game)
	var j := i
	while true:
		j += d
		if j < 0 or j >= _tiles.size():
			return
		var ini := _initial(_tiles[j].game)
		if ini != cur:
			if d < 0:
				# Land on the first tile of that letter.
				while j > 0 and _initial(_tiles[j - 1].game) == ini:
					j -= 1
			_tiles[j].grab_focus()
			return


static func _initial(g: Dictionary) -> String:
	var t := View.fold(String(g.get("title", "")))
	if t.begins_with("the "):
		t = t.substr(4)
	return t.substr(0, 1) if t != "" else "#"


func _after_search() -> void:
	if not _tiles.is_empty():
		_focus_later(_tiles[0])
	else:
		_focus_later(search_button)


func _focus_later(c: Control) -> void:
	var ref: WeakRef = weakref(c)
	(func():
		var n: Control = ref.get_ref()
		if n != null and n.is_inside_tree() and n.is_visible_in_tree():
			n.grab_focus()
	).call_deferred()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and sort_button != null:
		_refresh_toolbar()
		count_label.add_theme_color_override("font_color", ThemeLib.color("accent"))
		if details != null:
			_style_details(details)
		var g := Gradient.new()
		var sc: Color = ThemeLib.color("scrim")
		g.colors = PackedColorArray([Color(sc, 0.0), Color(sc, 0.9)])
		var t := GradientTexture2D.new()
		t.gradient = g
		t.width = 4
		t.height = 64
		t.fill_to = Vector2(0, 1)
		_fade.texture = t
	elif what == NOTIFICATION_RESIZED and grid != null:
		var w := size.x - 48 - 24 - PAD.x
		var cols := maxi(3, int((w + GAP.x) / (Tile.SIZE.x + GAP.x)))
		# Spread the leftover width into the gaps so the grid spans the row.
		var gap := clampf((w - 4.0 - cols * Tile.SIZE.x) / maxf(1.0, cols - 1), GAP.x, GAP.x * 3.0)
		grid.add_theme_constant_override("h_separation", int(gap))
		if cols != grid.columns:
			grid.columns = cols
			_link_grid()
