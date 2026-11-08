extends Control
## The home screen: top bar with live device numbers, a "Continue" hero, a
## store filter and three rows (Recently played, Installed, All games).
## Knows nothing about services: main.gd feeds it games and status and acts on
## its signals.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Texts := preload("res://scripts/ui/texts.gd")
const View := preload("res://scripts/ui/library_view.gd")
const Tile := preload("res://scripts/ui/game_tile.gd")

signal play_requested(game: Dictionary)
signal open_requested(game: Dictionary)
signal refresh_requested

const ROWS := [["recent", "Recently played"], ["installed", "Installed"], ["all", "All games"]]

var games: Array = []
var store := ""
var hero_game: Dictionary = {}

var device_label: Label
var battery_label: Label
var clock_label: Label
var _scroll: ScrollContainer
var _hero_box: Control
var _hero_buttons: Array = []
var _filter_buttons: Array = []
var _rows_box: VBoxContainer
var _empty_filter: Label
## row id -> Array of tiles; row id -> last focused index (TV-style memory).
var _tiles := {}
var _row_memory := {}
var _row_order: Array = []


func _init() -> void:
	name = "Home"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 32)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 12)
	add_child(margin)
	var root := Kit.vbox(14)
	margin.add_child(root)

	root.add_child(_build_top_bar())

	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.follow_focus = true
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_scroll)
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 6)
	_scroll.add_child(pad)
	var content := Kit.vbox(22)
	content.name = "Content"
	pad.add_child(content)

	_hero_box = Kit.vbox(0)
	_hero_box.name = "HeroBox"
	content.add_child(_hero_box)
	content.add_child(_build_filter_bar())
	_empty_filter = Kit.label("", "QuietLabel", true)
	_empty_filter.name = "EmptyFilter"
	content.add_child(_empty_filter)
	_rows_box = Kit.vbox(20)
	_rows_box.name = "Rows"
	content.add_child(_rows_box)

	root.add_child(Kit.label("A  Open    ·    B  Back    ·    LB / RB  Store    ·    Guide or F1  Quick menu", "QuietLabel"))
	set_games([])


func _build_top_bar() -> Control:
	var bar := Kit.hbox(14)
	bar.name = "TopBar"
	var logo := TextureRect.new()
	logo.texture = load("res://icon.svg")
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.custom_minimum_size = Vector2(40, 40)
	bar.add_child(logo)
	var name_label := Kit.label("GameCove", "HeaderLabel")
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bar.add_child(name_label)
	bar.add_child(Kit.spacer())
	device_label = Kit.label("", "QuietLabel")
	device_label.name = "DeviceName"
	battery_label = Kit.label("")
	battery_label.name = "Battery"
	clock_label = Kit.label("")
	clock_label.name = "Clock"
	for l in [device_label, battery_label, clock_label]:
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.size_flags_vertical = Control.SIZE_FILL
		bar.add_child(l)
	return bar


func _build_filter_bar() -> Control:
	var bar := Kit.hbox(8)
	bar.name = "StoreFilter"
	var l := Kit.label("Store", "QuietLabel")
	l.custom_minimum_size = Vector2(64, 0)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.size_flags_vertical = Control.SIZE_FILL
	bar.add_child(l)
	for s in View.STORES:
		var b := Kit.button(s[1], "TabButton")
		b.name = "Store_" + (s[0] if s[0] != "" else "all")
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(104, 44)
		var id: String = s[0]
		b.pressed.connect(func(): set_store(id))
		b.focus_entered.connect(_aim_filter_down.bind(b))
		bar.add_child(b)
		_filter_buttons.append(b)
	Kit.link_horizontal(_filter_buttons)
	return bar


# ------------------------------------------------------------ data in

func set_games(list: Array) -> void:
	var keep := _focused_tile_ref()
	games = list
	_build_hero()
	_build_rows()
	_restore_focus(keep)


## Live numbers for the top bar. `battery` is Device.battery()'s shape.
func set_status(device_name: String, battery: Dictionary, clock: String) -> void:
	device_label.text = device_name
	var parts: Array[String] = []
	if int(battery.get("percent", -1)) >= 0:
		var charging: bool = battery.get("status", "") == "Charging"
		parts.append("%s%d%%" % ["⚡" if charging else "", battery["percent"]])
	if float(battery.get("watts", -1.0)) >= 0.0:
		parts.append("%.1f W" % battery["watts"])
	battery_label.text = "   ".join(parts)
	battery_label.visible = not parts.is_empty()
	clock_label.text = clock


func set_store(id: String) -> void:
	var had := _focused_tile_ref()
	store = id
	_build_rows()
	if not is_inside_tree() or had.is_empty():
		return
	for t in tiles(had[0]):
		if t.game["key"] == had[1]:
			_focus_later(t)
			return
	_focus_later(_current_filter_button())


func cycle_store(d: int) -> void:
	var ids: Array = View.STORES.map(func(s): return s[0])
	set_store(ids[posmod(ids.find(store) + d, ids.size())])
	if is_inside_tree():
		_current_filter_button().grab_focus()


func default_focus() -> Control:
	return _hero_buttons[0] if not _hero_buttons.is_empty() else _current_filter_button()


func tiles(row_id: String) -> Array:
	return _tiles.get(row_id, [])


# ------------------------------------------------------------ hero

func _build_hero() -> void:
	for c in _hero_box.get_children():
		_hero_box.remove_child(c)
		c.queue_free()
	_hero_buttons.clear()
	hero_game = View.continue_game(games)

	var panel := PanelContainer.new()
	panel.name = "Hero"
	panel.custom_minimum_size = Vector2(0, 224)
	panel.clip_contents = true
	_hero_box.add_child(panel)
	var row := Kit.hbox(28)
	panel.add_child(row)

	var info := Kit.vbox(10)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.alignment = BoxContainer.ALIGNMENT_CENTER

	if hero_game.is_empty():
		info.add_child(Kit.label("WELCOME", "AccentLabel"))
		info.add_child(Kit.label("No games found yet", "TitleLabel"))
		info.add_child(Kit.label("Installed Steam games show up here on their own. Epic, GOG and Amazon are coming next.", "QuietLabel", true))
		var refresh := Kit.button("Look again")
		refresh.name = "Refresh"
		refresh.custom_minimum_size = Vector2(200, 52)
		refresh.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		refresh.pressed.connect(func(): refresh_requested.emit())
		info.add_child(refresh)
		_hero_buttons = [refresh]
		row.add_child(info)
	else:
		var hero_tex := Kit.load_art(hero_game["art"].get("hero", ""), Vector2i(1280, 400))
		if hero_tex != null:
			var bg := TextureRect.new()
			bg.name = "HeroArt"
			bg.texture = hero_tex
			bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
			bg.modulate = Color(0.45, 0.45, 0.45)
			bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
			panel.add_child(bg)
			panel.move_child(bg, 0)
		var cover := Tile.new()
		cover.setup(hero_game, false)
		cover.focus_mode = Control.FOCUS_NONE
		cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cover.custom_minimum_size = Vector2(142, 213)
		cover.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(cover)
		row.add_child(info)
		info.add_child(Kit.label("CONTINUE", "AccentLabel"))
		var title := Kit.label(hero_game["title"], "TitleLabel", true)
		title.name = "HeroTitle"
		title.max_lines_visible = 2
		info.add_child(title)
		var sub: Array[String] = [View.store_name(hero_game["store"]),
			Texts.last_played_text(int(hero_game["last_played"]), int(Time.get_unix_time_from_system()))]
		var pt := Texts.playtime_text(int(hero_game["playtime_min"]))
		if pt != "":
			sub.append(pt)
		info.add_child(Kit.label("   ·   ".join(sub), "QuietLabel", true))
		var badges := Kit.hbox(8)
		for b in Tile.badge_specs(hero_game):
			badges.add_child(Kit.badge(b["text"], b["tone"]))
		info.add_child(badges)
		var buttons := Kit.hbox(12)
		var play := Kit.button("Play", "AccentButton")
		play.name = "Play"
		play.custom_minimum_size = Vector2(200, 56)
		var g := hero_game
		play.pressed.connect(func(): play_requested.emit(g))
		var page := Kit.button("Game page")
		page.name = "GamePage"
		page.custom_minimum_size = Vector2(180, 56)
		page.pressed.connect(func(): open_requested.emit(g))
		buttons.add_child(play)
		buttons.add_child(page)
		info.add_child(buttons)
		_hero_buttons = [play, page]

	Kit.link_horizontal(_hero_buttons)
	for b in _hero_buttons:
		b.focus_neighbor_top = b.get_path_to(b)
		b.focus_entered.connect(_aim_hero_down.bind(b))


# ------------------------------------------------------------ rows

func _build_rows() -> void:
	for c in _rows_box.get_children():
		_rows_box.remove_child(c)
		c.queue_free()
	_tiles.clear()
	_row_order.clear()
	for b in _filter_buttons:
		b.set_pressed_no_signal(b.name == _current_filter_button().name)

	var shown := View.filter_by_store(games, store)
	var lists := {
		"recent": View.recently_played(shown),
		"installed": View.installed(shown),
		"all": shown,
	}
	for r in ROWS:
		var list: Array = lists[r[0]]
		if list.is_empty():
			continue
		_rows_box.add_child(_build_row(r[0], r[1], list))

	_empty_filter.visible = _row_order.is_empty()
	if games.is_empty():
		_empty_filter.text = "Your games will appear in rows here."
	elif _row_order.is_empty():
		_empty_filter.text = "No %s games found. Pick another store or All." % View.store_name(store)


func _build_row(id: String, title: String, list: Array) -> Control:
	var box := Kit.vbox(8)
	box.name = "Row_" + id
	var head := Kit.hbox(12)
	head.add_child(Kit.label(title, "HeaderLabel"))
	var count := Kit.label(str(list.size()), "QuietLabel")
	count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	count.size_flags_vertical = Control.SIZE_FILL
	head.add_child(count)
	box.add_child(head)

	var scroll := ScrollContainer.new()
	scroll.follow_focus = true
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll.custom_minimum_size = Vector2(0, Tile.SIZE.y + 14)
	box.add_child(scroll)
	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 7)
	scroll.add_child(pad)
	var strip := Kit.hbox(16)
	strip.name = "Tiles"
	pad.add_child(strip)

	var row_tiles: Array = []
	for g in list:
		var t := Tile.new()
		t.setup(g)
		var game: Dictionary = g
		t.pressed.connect(func(): open_requested.emit(game))
		t.focus_entered.connect(_on_tile_focus.bind(id, row_tiles.size()))
		strip.add_child(t)
		row_tiles.append(t)
	Kit.link_horizontal(row_tiles)
	_tiles[id] = row_tiles
	_row_order.append(id)
	_row_memory[id] = mini(_row_memory.get(id, 0), row_tiles.size() - 1)
	return box


# ------------------------------------------------------------ focus

## Each row remembers where you were, so up/down returns you there.
func _remembered(id: String) -> Control:
	var list: Array = _tiles[id]
	return list[clampi(_row_memory.get(id, 0), 0, list.size() - 1)]


func _on_tile_focus(id: String, i: int) -> void:
	_row_memory[id] = i
	var t: Control = _tiles[id][i]
	var r := _row_order.find(id)
	var up: Control = _remembered(_row_order[r - 1]) if r > 0 else _current_filter_button()
	var down: Control = _remembered(_row_order[r + 1]) if r + 1 < _row_order.size() else t
	t.focus_neighbor_top = t.get_path_to(up)
	t.focus_neighbor_bottom = t.get_path_to(down)


func _aim_filter_down(b: Control) -> void:
	var down: Control = _remembered(_row_order[0]) if not _row_order.is_empty() else b
	b.focus_neighbor_bottom = b.get_path_to(down)
	b.focus_neighbor_top = b.get_path_to(default_focus())


func _aim_hero_down(b: Control) -> void:
	b.focus_neighbor_bottom = b.get_path_to(_current_filter_button())
	# Show the whole hero, not just the button follow_focus would settle for.
	if is_inside_tree():
		await get_tree().process_frame
		_scroll.scroll_vertical = 0


func _current_filter_button() -> Button:
	var ids: Array = View.STORES.map(func(s): return s[0])
	return _filter_buttons[maxi(0, ids.find(store))]


## [row id, game key] of the focused tile, or [] if focus isn't on a tile.
func _focused_tile_ref() -> Array:
	if not is_inside_tree():
		return []
	var f := get_viewport().gui_get_focus_owner()
	for id in _tiles:
		for t in _tiles[id]:
			if t == f:
				return [id, t.game["key"]]
	return []


func _restore_focus(ref: Array) -> void:
	if not is_inside_tree() or not is_visible_in_tree():
		return
	if not ref.is_empty() and _tiles.has(ref[0]):
		for t in _tiles[ref[0]]:
			if t.game["key"] == ref[1]:
				_focus_later(t)
				return
	var f := get_viewport().gui_get_focus_owner()
	if f == null or not is_instance_valid(f) or f.is_queued_for_deletion() or not is_ancestor_of(f):
		_focus_later(default_focus())


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


func _focus_later(c: Control) -> void:
	focus_later(c)
