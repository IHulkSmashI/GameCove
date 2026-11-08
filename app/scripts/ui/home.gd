extends Control
## The home screen: a spotlight naming the focused game over its art (Play and
## Game page act on it), then shelves: Recently played, Installed, Short
## games, Anti-cheat friendly, one per store, All games. Starts on the
## "Continue" game. Knows nothing about services: main.gd feeds it games and
## acts on its signals. The top bar, backdrop and hint bar belong to main.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Texts := preload("res://scripts/ui/texts.gd")
const View := preload("res://scripts/ui/library_view.gd")
const Tile := preload("res://scripts/ui/game_tile.gd")
const Shelf := preload("res://scripts/ui/shelf.gd")
const GameHeader := preload("res://scripts/ui/game_header.gd")
const Illustrations := preload("res://scripts/ui/illustrations.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const ArtColor := preload("res://theme/art_color.gd")
const Motion := preload("res://scripts/ui/motion.gd")

signal play_requested(game: Dictionary)
signal open_requested(game: Dictionary)
signal refresh_requested
## Focus moved to another game (spotlight changed): the backdrop follows.
signal game_focused(game: Dictionary)

## Kept for callers that walk rows; Home.shelves() has the real list.
const ROWS := [["recent", "Recently played"], ["installed", "Installed"], ["all", "All games"]]
const SPOTLIGHT_H := 276

var games: Array = []
## The "Continue" game: most recently played installed game.
var hero_game: Dictionary = {}
## The game the spotlight shows and Play / Game page act on.
var spotlight_game: Dictionary = {}
## Where "up" from the spotlight buttons goes (the current top-bar tab).
var top_target: Control

var header: Control
var play_button: Button
var page_button: Button
var _spotlight: VBoxContainer
var _buttons_row: HBoxContainer
var _empty: Control
var _scroll: ScrollContainer
var _rows_box: VBoxContainer
var _shelves: Array = []        # Shelf nodes, top to bottom
var _hero_buttons: Array = []
var _accent := Color(0, 0, 0, 0)


func _init() -> void:
	name = "Home"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var margin := Kit.margin(0)
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 48 - int(Shelf.PAD.x))
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 92)
	margin.add_theme_constant_override("margin_bottom", 58)
	add_child(margin)
	var root := Kit.vbox(26)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(root)

	_spotlight = Kit.vbox(16)
	_spotlight.name = "Spotlight"
	_spotlight.custom_minimum_size = Vector2(0, SPOTLIGHT_H)
	_spotlight.alignment = BoxContainer.ALIGNMENT_END
	_spotlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var spot_pad := Kit.margin(0)
	spot_pad.add_theme_constant_override("margin_left", int(Shelf.PAD.x))
	spot_pad.add_child(_spotlight)
	root.add_child(spot_pad)

	header = GameHeader.new()
	header.max_logo = Vector2(470, 150)
	_spotlight.add_child(header)

	_buttons_row = Kit.hbox(14)
	_buttons_row.name = "HeroButtons"
	play_button = Kit.button("Play", "AccentButton")
	play_button.name = "Play"
	play_button.custom_minimum_size = Vector2(196, 58)
	play_button.icon = Icons.tex("play", 22)
	play_button.add_theme_constant_override("h_separation", 12)
	play_button.pressed.connect(func(): play_requested.emit(spotlight_game))
	page_button = Kit.button("Game page")
	page_button.name = "GamePage"
	page_button.custom_minimum_size = Vector2(176, 58)
	page_button.pressed.connect(func(): open_requested.emit(spotlight_game))
	_buttons_row.add_child(play_button)
	_buttons_row.add_child(page_button)
	_spotlight.add_child(_buttons_row)

	_empty = _build_empty()
	_spotlight.add_child(_empty)

	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.follow_focus = false
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	root.add_child(_scroll)
	_rows_box = Kit.vbox(6)
	_rows_box.name = "Rows"
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_rows_box)
	set_games([])


func _build_empty() -> Control:
	var row := Kit.hbox(36)
	row.name = "Empty"
	row.add_child(Illustrations.rect("library", 200))
	var col := Kit.vbox(12)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(Kit.label("No games found yet", "TitleLabel"))
	var line := Kit.label("Installed Steam games show up here on their own. Epic, GOG and Amazon are coming next.", "QuietLabel", true)
	line.custom_minimum_size = Vector2(420, 0)
	col.add_child(line)
	var refresh := Kit.button("Look again", "AccentButton")
	refresh.name = "Refresh"
	refresh.custom_minimum_size = Vector2(200, 56)
	refresh.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	refresh.icon = Icons.tex("update", 20)
	refresh.pressed.connect(func(): refresh_requested.emit())
	col.add_child(refresh)
	row.add_child(col)
	return row


# ------------------------------------------------------------ data in

func set_games(list: Array) -> void:
	var keep := _focused_tile_ref()
	games = list
	hero_game = View.continue_game(games)
	var spot := spotlight_game
	if spot.is_empty() or View.find_by_key(games, spot.get("key", "")).is_empty():
		spot = hero_game
	else:
		spot = View.find_by_key(games, spot["key"])
	_build_rows()
	_set_spotlight(spot, "", false)
	_restore_focus(keep)


## Older call: main now puts live numbers in the top bar.
func set_status(_device_name: String, _battery: Dictionary, _clock: String) -> void:
	pass


## The art accent of the spotlight game (from the backdrop), used for Play.
func set_accent(c: Color) -> void:
	_accent = c
	_style_play()
	header.eyebrow.add_theme_color_override("font_color", c if c.a > 0.0 else ThemeLib.color("accent"))


func default_focus() -> Control:
	if games.is_empty():
		return _empty.find_child("Refresh", true, false)
	return play_button


func tiles(row_id: String) -> Array:
	for s in _shelves:
		if s.id == row_id:
			return s.tiles
	return []


func shelves() -> Array:
	return _shelves


func shelf_ids() -> Array:
	return _shelves.map(func(s): return s.id)


## Every tile showing `key`, first match per shelf.
func tile_for(key: String) -> Control:
	for s in _shelves:
		for t in s.tiles:
			if t.game.get("key", "") == key:
				return t
	return null


# ------------------------------------------------------------ spotlight

func _set_spotlight(g: Dictionary, line: String, animate: bool) -> void:
	spotlight_game = g
	var empty := games.is_empty()
	_empty.visible = empty
	header.visible = not empty
	_buttons_row.visible = not empty
	_hero_buttons = [_empty.find_child("Refresh", true, false)] if empty else [play_button, page_button]
	if not empty:
		if line == "":
			line = "Jump back in" if g.get("key", "") == hero_game.get("key", "-") and int(g.get("last_played", 0)) > 0 else ""
		header.show_game(g, line, animate)
		var installed: bool = g.get("installed", false)
		play_button.text = "Play" if installed else "Install"
		_style_play()
	Kit.link_horizontal(_hero_buttons)
	for b in _hero_buttons:
		b.focus_neighbor_top = b.get_path_to(top_target if top_target != null else b)
		var down: Control = _shelves[0].remembered() if not _shelves.is_empty() else b
		b.focus_neighbor_bottom = b.get_path_to(down)
		if not b.focus_entered.is_connected(_on_hero_focus):
			b.focus_entered.connect(_on_hero_focus)
	if is_inside_tree():
		game_focused.emit(g)


func set_top_target(c: Control) -> void:
	top_target = c
	for b in _hero_buttons:
		b.focus_neighbor_top = b.get_path_to(c)


func _style_play() -> void:
	Kit.accent_button(play_button, _accent)
	play_button.icon = Icons.tex("play" if spotlight_game.get("installed", true) else "download", 22)


func _on_hero_focus() -> void:
	# Show the whole spotlight and the first shelf.
	_scroll_to(0.0)


# ------------------------------------------------------------ shelves

func _build_rows() -> void:
	for c in _rows_box.get_children():
		Kit.drop(_rows_box, c)
	var memory := {}
	for s in _shelves:
		memory[s.id] = s.memory
	_shelves.clear()
	for spec in View.shelves(games):
		var s: VBoxContainer = Shelf.new()
		s.setup(spec["id"], spec["title"], spec["games"])
		s.memory = mini(memory.get(spec["id"], 0), s.tiles.size() - 1)
		s.tile_focused.connect(_on_tile_focus.bind(s))
		s.tile_pressed.connect(func(g): open_requested.emit(g))
		_rows_box.add_child(s)
		_shelves.append(s)
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 240)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rows_box.add_child(spacer)


func _on_tile_focus(g: Dictionary, i: int, s: Control) -> void:
	var r := _shelves.find(s)
	var t: Control = s.tiles[i]
	var up: Control = _shelves[r - 1].remembered() if r > 0 else play_button
	var down: Control = _shelves[r + 1].remembered() if r + 1 < _shelves.size() else t
	t.focus_neighbor_top = t.get_path_to(up)
	t.focus_neighbor_bottom = t.get_path_to(down)
	for b in _hero_buttons:
		b.focus_neighbor_bottom = b.get_path_to(t)
	_scroll_to(s.position.y)
	_set_spotlight(g, "", true)


func _scroll_to(y: float) -> void:
	if not is_inside_tree():
		return
	Motion.method(_scroll, "vscroll", func(v: float): _scroll.scroll_vertical = int(v),
		float(_scroll.scroll_vertical), y, Motion.BASE)


# ------------------------------------------------------------ focus

## [row id, game key] of the focused tile, or [] if focus isn't on a tile.
func _focused_tile_ref() -> Array:
	if not is_inside_tree():
		return []
	var f := get_viewport().gui_get_focus_owner()
	for s in _shelves:
		for t in s.tiles:
			if t == f:
				return [s.id, t.game["key"]]
	return []


func _restore_focus(ref: Array) -> void:
	if not is_inside_tree() or not is_visible_in_tree():
		return
	if not ref.is_empty():
		for t in tiles(ref[0]):
			if t.game["key"] == ref[1]:
				focus_later(t)
				return
	var f := get_viewport().gui_get_focus_owner()
	if f == null or not is_instance_valid(f) or f.is_queued_for_deletion():
		focus_later(default_focus())


## Grabs focus next frame, skipping controls that were freed or left the tree
## in between (tiles are rebuilt when the library finishes loading).
static func focus_later(c: Control) -> void:
	if c == null:
		return
	var ref: WeakRef = weakref(c)
	(func():
		var n: Control = ref.get_ref()
		if n != null and n.is_inside_tree() and n.is_visible_in_tree():
			n.grab_focus()
	).call_deferred()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and play_button != null:
		_style_play()
		page_button.icon = null
