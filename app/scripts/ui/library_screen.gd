extends Control
## Library: every game as a dense cover grid, filtered by store, sorted
## (recent, A to Z, most played, shortest first) and searched with the
## on-screen keyboard (Y) or a physical one. X cycles the sort. Installed /
## Not installed chips narrow it down; a Downloads chip shows while anything
## is in the queue. Tiles show install state (main passes a tile_hook).
## The header's Filter button and View open the Filter sheet (main, through
## CollectionActions): all games, favourites, a collection, emulation or hidden
## games, and the order. The toolbar fills 1280 px, so views live in that sheet.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const View := preload("res://scripts/ui/library_view.gd")
const Tile := preload("res://scripts/ui/game_tile.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const Illustrations := preload("res://scripts/ui/illustrations.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const Osk := preload("res://scripts/ui/osk.gd")
const ButtonFx := preload("res://scripts/ui/button_fx.gd")
const TL := preload("res://scripts/ui/texts_library.gd")

signal open_requested(game: Dictionary)
signal game_focused(game: Dictionary)
signal downloads_requested
## The header's Filter button was pressed: main opens the Filter sheet.
signal filter_requested
## The header's Apps button: open the Apps view (desktop apps, apps_view.gd).
signal apps_requested

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
## Library view (View.VIEWS or "collection:<id>"): "" = every game not hidden.
var view := ""
var view_label: Label
## The critic filter chip: a star and "75+" (a critic score: the star says so;
## "Critics 75+" didn't fit the 1280 px toolbar).
const CRITIC_LABEL := "%d+"
## Genre filter ("" = all) and "critic score 75+" filter.
var genre := ""
var critic_filter := false
var genre_button: Button
var critic_button: Button
## Called with every new tile (install badges and progress).
var tile_hook: Callable = Callable()
var filter_buttons: Array = []
var downloads_chip: Button
var top_target: Control

var search_button: Button
var sort_button: Button
## In the header, not the toolbar: Apps (desktop apps). Up from the toolbar's
## last chip reaches it.
var apps_button: Button
## The header's Filter button (also View): the Filter sheet.
var filter_button: Button
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
var _area: Control
## Whole rows the grid shows at once: the scroll window is cut to fit them, so
## no row is ever sliced through its cover (the cue sits in what's left).
var rows_visible := 2
var _empty: Control
var _empty_text: Label
var _tiles: Array = []
var _memory_key := ""
## Cover size for the current width: at most Tile.PER_ROW-ish (7) across.
var tile_size := Tile.SIZE
const MAX_COLS := 7


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
	# The view the filter sheet picked ("Favourites  ·"), before the count.
	view_label = Kit.label("", "TitleLabel")
	view_label.name = "ViewName"
	view_label.visible = false
	head.add_child(view_label)
	head.add_child(count_label)
	head.add_child(Kit.spacer())
	# Filter (views and order) next to Apps: the toolbar under it is full at 1280 px.
	filter_button = Kit.button(TL.FILTER_TITLE, "ChipButton")
	filter_button.name = "FilterButton"
	filter_button.icon = load("res://scripts/ui/games/game_icons.gd").tex("filter", 18, Color.WHITE)
	filter_button.add_theme_constant_override("h_separation", 8)
	filter_button.custom_minimum_size = Vector2(0, 40)
	filter_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	filter_button.pressed.connect(func(): filter_requested.emit())
	ButtonFx.attach(filter_button, {"glyph": "VIEW"})
	head.add_child(filter_button)
	apps_button = Kit.button("Apps", "ChipButton")
	apps_button.name = "AppsButton"
	apps_button.icon = Icons.tex("apps", 18, Color.WHITE)
	apps_button.add_theme_constant_override("h_separation", 8)
	apps_button.custom_minimum_size = Vector2(0, 40)
	apps_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	apps_button.pressed.connect(func(): apps_requested.emit())
	head.add_child(apps_button)
	var head_pad := Kit.margin(0, int(PAD.x), 0)
	head_pad.add_child(head)
	root.add_child(head_pad)

	# Tight enough that every chip (and the star on the critic one) fits a
	# 1280 px screen.
	var bar := Kit.hbox(6)
	bar.name = "Toolbar"
	search_button = Kit.button("", "ChipButton")
	search_button.name = "Search"
	search_button.custom_minimum_size = Vector2(148, 44)
	search_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	search_button.add_theme_constant_override("h_separation", 10)
	search_button.pressed.connect(open_search)
	# The button that triggers it, right on the control (Y search, X sort).
	ButtonFx.attach(search_button, {"glyph": "Y"})
	bar.add_child(search_button)
	var sep := Control.new()
	sep.custom_minimum_size = Vector2(4, 0)
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
	sep2.custom_minimum_size = Vector2(4, 0)
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
	# Genre (A cycles the library's most common genres) and critic score 75+.
	genre_button = Kit.button("", "ChipButton")
	genre_button.name = "Genre"
	genre_button.custom_minimum_size = Vector2(0, 44)
	genre_button.pressed.connect(func(): cycle_genre(1))
	bar.add_child(genre_button)
	# Says what the number is: a critic score (Metacritic, else OpenCritic / IGDB).
	critic_button = Kit.button(CRITIC_LABEL % View.CRITIC_MIN, "ChipButton")
	critic_button.name = "Critic"
	critic_button.icon = Icons.tex("star", 18, Color.WHITE)
	critic_button.add_theme_constant_override("h_separation", 6)
	for st in ["icon_normal_color", "icon_hover_color", "icon_focus_color"]:
		critic_button.add_theme_color_override(st, ThemeLib.tone("gold"))
	for st in ["icon_pressed_color", "icon_hover_pressed_color"]:
		critic_button.add_theme_color_override(st, ThemeLib.color("on_accent"))
	critic_button.toggle_mode = true
	critic_button.custom_minimum_size = Vector2(0, 44)
	critic_button.tooltip_text = "Critic score %d or more" % View.CRITIC_MIN
	critic_button.pressed.connect(func(): set_critic_filter(not critic_filter))
	bar.add_child(critic_button)
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
	ButtonFx.attach(sort_button, {"glyph": "X"})
	bar.add_child(sort_button)
	var bar_pad := Kit.margin(0, int(PAD.x), 0)
	bar_pad.add_child(bar)
	root.add_child(bar_pad)

	var area := Control.new()
	area.name = "GridArea"
	area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	area.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(area)
	_area = area
	area.resized.connect(_fit_rows)
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


## "" = every genre.
func set_genre(g: String) -> void:
	genre = g
	_rebuild(false)


func cycle_genre(d := 1) -> void:
	var list: Array = [""] + View.top_genres(games)
	set_genre(list[posmod(list.find(genre) + d, list.size())] if genre in list else "")


func set_critic_filter(on: bool) -> void:
	critic_filter = on
	_rebuild(false)


## A view from the filter sheet; an unknown collection falls back to all games.
func set_view(v: String) -> void:
	view = v if (v in View.VIEWS or v.begins_with("collection:") or (v.begins_with("emulation:") and v.length() > 10)) else ""
	_rebuild(false)
	if is_inside_tree() and is_visible_in_tree():
		_focus_later(default_focus())


## The view's name for the heading ("" for all games).
func view_name() -> String:
	if view.begins_with("collection:"):
		return _collection_names.get(view.substr(11), "")
	if view.begins_with("emulation:"):
		for s in View.systems_in(games):
			if s["id"] == view.substr(10):
				return s["short"]
		return view.substr(10).to_upper()
	return TL.VIEW_NAMES.get(view, "")


## Collection id -> name, for the heading (main passes it with the games).
var _collection_names := {}


func set_collection_names(names: Dictionary) -> void:
	_collection_names = names
	if view.begins_with("collection:") and not _collection_names.has(view.substr(11)):
		view = ""
	_refresh_toolbar()


## The Library on what a Home shelf lists (its "See all" tile): every filter and
## the search cleared first, then that shelf's own, in one rebuild.
##   installed: Installed only        favourites / emulation: that view
##   store_<id>: that store           short: everything, shortest first
##   anything else (all, anti-cheat friendly, recent): every game
func show_shelf(shelf_id: String) -> void:
	store = ""
	view = ""
	install_filter = ""
	genre = ""
	critic_filter = false
	query = ""
	match shelf_id:
		"installed":
			install_filter = "installed"
		"favourites", "emulation":
			view = shelf_id
		"short":
			sort = "ttb"
		_:
			if shelf_id.begins_with("store_") and View.STORES.any(func(s): return s[0] == shelf_id.substr(6)):
				store = shelf_id.substr(6)
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
	return keyboard.is_open()


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
	var focused_at := -1
	if is_inside_tree():
		var f := get_viewport().gui_get_focus_owner()
		if f != null and f in _tiles:
			focused_key = f.game.get("key", "")
			# a new order or view (X, the Filter sheet) starts at the top of the grid
			focused_at = _tiles.find(f) if keep_focus else 0
	var in_view := View.filter_view(games, view)
	var picked := View.filter_meta(filter_install(View.filter_by_store(in_view, store), install_filter), genre, View.CRITIC_MIN if critic_filter else 0)
	shown = View.sort_games(View.search(picked, query), sort)
	for t in _tiles:
		Kit.drop(grid, t)
	_tiles.clear()
	# Tiles are made a page at a time (thousands of ROMs would take seconds and
	# gigabytes at once): enough to reach the remembered game, more as focus nears the end.
	var want := PAGE
	var mk := focused_key if focused_key != "" else _memory_key
	if mk != "":
		for i in shown.size():
			if shown[i].get("key", "") == mk:
				want = maxi(want, i + 1 + PAGE / 2)
				break
	_grow(want)
	_refresh_toolbar()
	_empty.visible = shown.is_empty()
	_scroll.get_parent().visible = not shown.is_empty()
	details.get_parent().visible = not shown.is_empty()
	if games.is_empty():
		_empty_text.text = "Your games will show up here once a store has some installed."
	elif in_view.is_empty() and view != "":
		_empty_text.text = {"favourites": TL.EMPTY_FAVOURITES, "hidden": TL.EMPTY_HIDDEN, "emulation": TL.EMPTY_EMULATION}.get(
			"emulation" if view.begins_with("emulation:") else view, TL.EMPTY_COLLECTION)
	elif query != "":
		_empty_text.text = "No games match \"%s\". Try fewer letters or another store." % query
	elif shown.is_empty() and (genre != "" or critic_filter):
		_empty_text.text = "No games match these filters. Clear the genre or the %d+ filter to see more." % View.CRITIC_MIN
	elif shown.is_empty() and install_filter != "":
		_empty_text.text = ("Nothing installed here yet. Clear the Installed filter to see everything you own." if install_filter == "installed"
			else "Everything here is installed. Clear the filter to see all your games.")
	elif shown.is_empty():
		_empty_text.text = "No %s games found. Pick another store or All." % View.store_name(store)
	var total := View.not_hidden(games).size() if view != "hidden" else in_view.size()
	count_label.text = ("%d of %d" % [shown.size(), total]) if shown.size() != total else ("%d games" % total if total != 1 else "1 game")
	if focused_key != "":
		for t in _tiles:
			if t.game.get("key", "") == focused_key:
				_focus_later(t)
				return
		# the focused game left the grid (hidden, uninstalled with the Installed
		# filter on): focus takes its place, or the toolbar when the grid is empty
		_focus_later(_tiles[mini(focused_at, _tiles.size() - 1)] if not _tiles.is_empty() else _current_store_button())


## Tiles made at once, and how many more each time focus nears the last row made:
## eight rows of seven, a good two screens at 1280x800. Every tile is a node tree
## made on the main thread, so opening the Library on thousands of ROMs costs what
## this page costs (140 took 330 ms and the most memory of anything on screen).
const PAGE := 56


## Makes tiles up to `count` of `shown` (never fewer than there are now).
func _grow(count: int) -> void:
	var from := _tiles.size()
	var to := mini(count, shown.size())
	if to <= from:
		return
	for i in range(from, to):
		var g: Dictionary = shown[i]
		var t: Button = Tile.new()
		t.setup(g, true, tile_size, false)
		var game: Dictionary = g
		t.pressed.connect(func(): open_requested.emit(game))
		t.focus_entered.connect(_on_tile_focus.bind(t))
		grid.add_child(t)
		_tiles.append(t)
		if tile_hook.is_valid():
			tile_hook.call(t)
	_link_grid()


func _refresh_toolbar() -> void:
	var ids: Array = View.STORES.map(func(s): return s[0])
	for i in store_buttons.size():
		store_buttons[i].set_pressed_no_signal(ids[i] == store)
	for i in filter_buttons.size():
		filter_buttons[i].set_pressed_no_signal(INSTALL_FILTERS[i][0] == install_filter)
	var vn := view_name()
	view_label.text = vn + "  ·" if vn != "" else ""
	view_label.visible = vn != ""
	search_button.text = query if query != "" else "Search"
	search_button.icon = Icons.tex("search", 20)
	genre_button.text = genre if genre != "" else "All genres"
	genre_button.visible = genre != "" or not View.top_genres(games, 1).is_empty()
	critic_button.set_pressed_no_signal(critic_filter)
	critic_button.visible = critic_filter or games.any(func(g): return View.critic_score(g) > 0)
	sort_button.text = View.SORT_NAMES[sort]
	sort_button.icon = Icons.tex("sort", 20)
	_link_toolbar()


func _toolbar() -> Array:
	var out: Array = [search_button]
	out.append_array(store_buttons)
	out.append_array(filter_buttons)
	for b in [genre_button, critic_button]:
		if b != null and b.visible:
			out.append(b)
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
	if not bar.is_empty():
		var last: Control = bar[bar.size() - 1]
		last.focus_neighbor_top = last.get_path_to(apps_button)
		apps_button.focus_neighbor_bottom = apps_button.get_path_to(last)
		apps_button.focus_neighbor_left = apps_button.get_path_to(filter_button)
		apps_button.focus_neighbor_right = apps_button.get_path_to(apps_button)
		apps_button.focus_neighbor_top = apps_button.get_path_to(top_target if top_target != null else apps_button)
		filter_button.focus_neighbor_bottom = filter_button.get_path_to(last)
		filter_button.focus_neighbor_left = filter_button.get_path_to(filter_button)
		filter_button.focus_neighbor_right = filter_button.get_path_to(apps_button)
		filter_button.focus_neighbor_top = filter_button.get_path_to(top_target if top_target != null else filter_button)


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
	if _tiles.find(t) >= _tiles.size() - grid.columns * 3 and _tiles.size() < shown.size():
		_grow(_tiles.size() + PAGE)
	show_details(t.game)
	for b in _toolbar():
		b.focus_neighbor_bottom = b.get_path_to(t)
	var row := _tiles.find(t) / grid.columns
	var pitch := tile_size.y + GAP.y
	# Whole rows only: move the window of rows_visible rows just enough to
	# hold the focused row.
	var first := roundi(_scroll.scroll_vertical / pitch)
	if row >= first + rows_visible:
		first = row - rows_visible + 1
	elif row < first:
		first = row
	var target := first * pitch
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


## The details bar: a glass card (no accent edge: the focused tile wears the
## only ring) with a solid SELECTED pill.
func _style_details(p: PanelContainer) -> void:
	var acc := ThemeLib.color("accent")
	var sb := ThemeLib.card(22, 12)
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
	# Only while a whole row waits below: never a cue pointing at nothing.
	var more := bar.max_value - bar.page - bar.value > tile_size.y * 0.5
	cue.visible = more
	_fade.visible = more


## Cut the scroll window to whole rows (with room for the focus ring above
## and below); the cue sits in the bottom padding or the band left over.
func _fit_rows() -> void:
	if _area == null or _scroll == null:
		return
	var pitch := tile_size.y + GAP.y
	var h := _area.size.y
	if h <= 0.0:
		return
	rows_visible = maxi(1, int(floorf((h - 2.0 * PAD.y + GAP.y) / pitch)))
	# a few px short of the next row's top edge, so not even its hairline shows
	var fit := 2.0 * PAD.y + rows_visible * pitch - GAP.y - 6.0
	if fit > h:
		fit = h
	_scroll.offset_bottom = -(h - fit)
	_fade.offset_top = -(h - fit) - 40.0
	_update_cue()


## LT / RT: jump to the previous / next first letter in the current order.
func jump_letter(d: int) -> void:
	if d == 0 or _tiles.is_empty() or not is_inside_tree():
		return
	d = signi(d)
	var f := get_viewport().gui_get_focus_owner()
	var i := maxi(0, _tiles.find(f))
	var cur := _initial(shown[i])
	var j := i
	while true:
		j += d
		if j < 0 or j >= shown.size():
			return
		var ini := _initial(shown[j])
		if ini != cur:
			if d < 0:
				# Land on the first tile of that letter.
				while j > 0 and _initial(shown[j - 1]) == ini:
					j -= 1
			_grow(j + 1 + PAGE / 2)   # past the tiles made so far: make them now
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


static func _focus_later(c: Control) -> void:
	if c == null:
		return
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
		var cols := clampi(int((w + GAP.x) / (Tile.SIZE.x + GAP.x)), 3, MAX_COLS)
		# Seven across at most: wider screens get bigger covers, not more.
		var want := Tile.SIZE
		if cols == MAX_COLS:
			var tw := floorf((w - 4.0 - (cols - 1) * GAP.x) / cols)
			want = Vector2(tw, roundf(tw * Tile.SIZE.y / Tile.SIZE.x)) if tw > Tile.SIZE.x else Tile.SIZE
		# Spread the leftover width into the gaps so the grid spans the row.
		var gap := clampf((w - 4.0 - cols * want.x) / maxf(1.0, cols - 1), GAP.x, GAP.x * 3.0)
		grid.add_theme_constant_override("h_separation", int(gap))
		var relink := cols != grid.columns
		grid.columns = cols
		if want != tile_size:
			tile_size = want
			_rebuild.call_deferred(true)
			_fit_rows.call_deferred()
		elif relink:
			_link_grid()
