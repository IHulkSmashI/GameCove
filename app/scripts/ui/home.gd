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
const HeroStage := preload("res://scripts/ui/hero_stage.gd")

signal play_requested(game: Dictionary)
signal open_requested(game: Dictionary)
signal refresh_requested
## Focus moved to another game (spotlight changed): the backdrop follows.
signal game_focused(game: Dictionary)
## The spotlight game is downloading: its button opens the downloads list.
signal downloads_requested
## The Apps shelf's "All apps" tile was pressed.
signal apps_requested

## Kept for callers that walk rows; Home.shelves() has the real list.
const ROWS := [["recent", "Recently played"], ["installed", "Installed"], ["all", "All games"]]
const SPOTLIGHT_H := 330
## The hero card: from under the top bar, EDGE from the sides.
const FRAME_TOP := 76
const FRAME_H := 330
const FRAME_PAD := 32
const ProgressCard := preload("res://scripts/ui/progress_card.gd")

var games: Array = []
## The "Continue" game: most recently played installed game.
var hero_game: Dictionary = {}
## The game the spotlight shows and Play / Game page act on.
var spotlight_game: Dictionary = {}
## Where "up" from the spotlight buttons goes (the current top-bar tab).
var top_target: Control

var header: Control
var hero_stage: Control
var tips: HBoxContainer
var _welcome_art: TextureRect
var play_button: Button
var page_button: Button
var _spotlight: VBoxContainer
var _buttons_row: HBoxContainer
var _empty: Control
var _scroll: ScrollContainer
var _rows_box: VBoxContainer
var _shelves: Array = []        # Shelf nodes, top to bottom
## Pinned desktop apps (apps.gd) for the Apps shelf; [] = no shelf.
var apps: Array = []
var _hero_buttons: Array = []
var _accent := Color(0, 0, 0, 0)
## Called with every new tile (install badges and progress).
var tile_hook: Callable = Callable()
## What the spotlight's main button does: {"id", "text", "icon"}.
var spotlight_action: Dictionary = {}
## The rounded glass card the spotlight sits in.
var frame: Panel
## Achievements and battery for the spotlight game (hidden without data).
var progress: Control
## Shelf ids already shown once (their first build eased in).
var _revealed := {}


func _init() -> void:
	name = "Home"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame = Panel.new()
	frame.name = "HeroFrame"
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.anchor_right = 1.0
	frame.offset_left = ThemeLib.EDGE
	frame.offset_right = -ThemeLib.EDGE
	frame.offset_top = FRAME_TOP
	frame.offset_bottom = FRAME_TOP + FRAME_H
	add_child(frame)
	hero_stage = HeroStage.new()
	hero_stage.use_frame(ThemeLib.EDGE, FRAME_TOP, FRAME_H, ThemeLib.radius("xl"))
	add_child(hero_stage)
	var frame_edge := Panel.new()
	frame_edge.name = "HeroFrameEdge"
	frame_edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame_edge.anchor_right = 1.0
	frame_edge.offset_left = ThemeLib.EDGE
	frame_edge.offset_right = -ThemeLib.EDGE
	frame_edge.offset_top = FRAME_TOP
	frame_edge.offset_bottom = FRAME_TOP + FRAME_H
	add_child(frame_edge)
	progress = ProgressCard.new()
	progress.anchor_left = 1.0
	progress.anchor_right = 1.0
	progress.offset_right = -ThemeLib.EDGE - 24
	progress.offset_left = -ThemeLib.EDGE - 24 - ProgressCard.WIDTH
	progress.offset_bottom = FRAME_TOP + FRAME_H - 24
	progress.offset_top = FRAME_TOP + FRAME_H - 24
	progress.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(progress)
	_welcome_art = Illustrations.rect("library", 280)
	_welcome_art.anchor_left = 0.64
	_welcome_art.anchor_right = 0.64
	_welcome_art.offset_top = 84
	_welcome_art.offset_left = 0
	_welcome_art.offset_right = 280
	_welcome_art.offset_bottom = 364
	add_child(_welcome_art)
	var margin := Kit.margin(0)
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", ThemeLib.EDGE - int(Shelf.PAD.x))
	margin.add_theme_constant_override("margin_right", ThemeLib.EDGE - int(Shelf.PAD.x))
	margin.add_theme_constant_override("margin_top", FRAME_TOP)
	margin.add_theme_constant_override("margin_bottom", ThemeLib.HINT_BAR_H)
	add_child(margin)
	var root := Kit.vbox(ThemeLib.SPACE_3)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(root)

	_spotlight = Kit.vbox(ThemeLib.SPACE_5)
	_spotlight.name = "Spotlight"
	_spotlight.custom_minimum_size = Vector2(0, SPOTLIGHT_H)
	_spotlight.alignment = BoxContainer.ALIGNMENT_CENTER
	_spotlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var spot_pad := Kit.margin(0)
	spot_pad.add_theme_constant_override("margin_left", int(Shelf.PAD.x) + FRAME_PAD)
	spot_pad.add_theme_constant_override("margin_right", ProgressCard.WIDTH + 64)
	spot_pad.add_child(_spotlight)
	root.add_child(spot_pad)

	header = GameHeader.new()
	header.max_logo = Vector2(440, 130)
	_spotlight.add_child(header)

	_buttons_row = Kit.hbox(ThemeLib.SPACE_3)
	_buttons_row.name = "HeroButtons"
	play_button = Kit.primary("Play", "A", "play")
	play_button.name = "Play"
	play_button.custom_minimum_size = Vector2(176, 50)
	play_button.pressed.connect(_on_play)
	page_button = Kit.secondary("Game page", "info")
	page_button.name = "GamePage"
	page_button.custom_minimum_size = Vector2(0, 50)
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
	_rows_box = Kit.vbox(8)
	_rows_box.name = "Rows"
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_rows_box)
	tips = _build_tips()
	var tips_pad := Kit.margin(0)
	tips_pad.add_theme_constant_override("margin_left", int(Shelf.PAD.x))
	tips_pad.add_theme_constant_override("margin_right", int(Shelf.PAD.x))
	tips_pad.add_theme_constant_override("margin_top", ThemeLib.SPACE_5)
	tips_pad.add_child(tips)
	root.add_child(tips_pad)
	set_games([])


func _build_empty() -> Control:
	var col := Kit.vbox(16)
	col.name = "Empty"
	col.add_child(Kit.label("Welcome to GameCove", "AccentLabel"))
	col.add_child(Kit.label("No games found yet", "DisplayLabel"))
	var line := Kit.label("Installed Steam games show up here on their own. Epic, GOG and Amazon are coming next.", "QuietLabel", true)
	line.custom_minimum_size = Vector2(520, 0)
	line.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	col.add_child(line)
	var refresh := Kit.button("Look again", "AccentButton")
	refresh.name = "Refresh"
	refresh.custom_minimum_size = Vector2(208, 56)
	refresh.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	refresh.icon = Icons.tex("update", 20)
	refresh.add_theme_constant_override("h_separation", 10)
	refresh.pressed.connect(func(): refresh_requested.emit())
	col.add_child(refresh)
	return col


## First launch: three short cards where the shelves will be.
func _build_tips() -> HBoxContainer:
	var row := Kit.hbox(16)
	row.name = "Tips"
	for spec in [["store", "Steam is found for you", "Games installed through Steam appear in a few seconds."],
			["download", "More stores next", "Epic, GOG and Amazon libraries join the same shelves."],
			["dots", "Quick menu", "Press the Guide button (or F1) for power, screen and device settings."]]:
		var p := PanelContainer.new()
		p.theme_type_variation = "CardPanel"
		p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var c := Kit.vbox(8)
		c.add_child(Kit.icon_label(spec[0], spec[1], "LeadLabel", ThemeLib.color("accent"), 22))
		c.add_child(Kit.label(spec[2], "QuietLabel", true))
		p.add_child(c)
		row.add_child(p)
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
	header.set_tag_color(c)


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
	tips.get_parent().visible = empty
	_welcome_art.visible = empty
	_scroll.visible = not empty
	if empty:
		hero_stage.show_welcome()
		progress.show_game({})
	else:
		hero_stage.show_game(g)
	header.visible = not empty
	_buttons_row.visible = not empty
	_hero_buttons = [_empty.find_child("Refresh", true, false)] if empty else [play_button, page_button]
	if not empty:
		if line == "":
			line = "Jump back in" if g.get("key", "") == hero_game.get("key", "-") and int(g.get("last_played", 0)) > 0 else ""
		header.show_game(g, line, animate)
		progress.show_game(g)
		spotlight_action = action_for(g)
		play_button.text = spotlight_action["text"]
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
	play_button.icon = load("res://scripts/ui/games/game_icons.gd").tex(spotlight_action.get("icon", "play"), 20)


func _style_frame() -> void:
	var r := ThemeLib.radius("xl")
	var bg := ThemeLib.box(Color(ThemeLib.color("glass"), 0.55 if ThemeLib.is_dark() else 0.75), r, 0, 0)
	frame.add_theme_stylebox_override("panel", bg)
	var edge := StyleBoxFlat.new()
	edge.draw_center = false
	edge.border_color = ThemeLib.color("line_2")
	edge.set_border_width_all(1)
	edge.set_corner_radius_all(r)
	edge.anti_aliasing = true
	frame.get_parent().get_node("HeroFrameEdge").add_theme_stylebox_override("panel", edge)


## Achievements service for the progress card (Achievements autoload or a fake).
func set_achievements(svc: Object) -> void:
	progress.set_service(svc)


## "~2 h 45 min" of battery left, or "" when unknown (main.gd works it out).
func set_battery_left(text: String) -> void:
	progress.set_battery_left(text)


## The spotlight button for a game: Play, Install, Update, or the download's
## progress while one runs (opens the downloads list). Reads the fields
## InstallState.decorate() adds.
static func action_for(g: Dictionary) -> Dictionary:
	var st := str(g.get("install_state", ""))
	var TG = load("res://scripts/ui/texts_games.gd")
	if st in TG.BUSY:
		var dl: Variant = g.get("download")
		var text: String = TG.STATE_SHORT.get(st, "Working")
		if dl is Dictionary and dl.has("progress") and st in TG.RUNNING:
			text = "%s %d%%" % [TG.STATE_LABEL.get(st, "Downloading"), roundi(float(dl["progress"]) * 100.0)]
		return {"id": "downloads", "text": text, "icon": "download"}
	if g.get("installed", false) and (st == "update_required" or g.get("update_available", false)) and st != "":
		return {"id": "update", "text": "Update", "icon": "update"}
	if g.get("installed", false):
		return {"id": "play", "text": "Play", "icon": "play"}
	return {"id": "install", "text": "Install", "icon": "download"}


## Where Play's launch zoom starts: the hero card and its art, when it shows `g`.
func launch_source(g: Dictionary) -> Dictionary:
	if g.get("key", "") != spotlight_game.get("key", "-") or not frame.is_visible_in_tree():
		return {}
	return {"node": frame, "tex": hero_stage.front_texture(), "radius": float(ThemeLib.radius("xl"))}


func _on_play() -> void:
	if spotlight_action.get("id", "play") == "downloads":
		downloads_requested.emit()
	else:
		play_requested.emit(spotlight_game)


func _on_hero_focus() -> void:
	# Show the whole spotlight and the first shelf.
	_scroll_to(0.0)


# ------------------------------------------------------------ shelves

func _build_rows() -> void:
	var memory := {}
	for s in _shelves:
		if is_instance_valid(s):
			memory[s.id] = s.memory
	for c in _rows_box.get_children():
		Kit.drop(_rows_box, c)
	_shelves.clear()
	var fresh := 0
	for spec in shelf_specs(games, apps):
		var s: VBoxContainer = Shelf.new()
		s.setup(spec["id"], spec["title"], spec["games"])
		s.memory = mini(memory.get(spec["id"], 0), s.tiles.size() - 1)
		s.tile_focused.connect(_on_tile_focus.bind(s))
		if spec["id"] == "apps":
			s.count_label.text = "%d %s" % [apps.size(), "app" if apps.size() == 1 else "apps"]
			s.tile_pressed.connect(_on_app_pressed)
		else:
			s.tile_pressed.connect(func(g): open_requested.emit(g))
		_rows_box.add_child(s)
		_shelves.append(s)
		# A shelf seen for the first time eases in (rebuilds after an install don't).
		if not _revealed.has(s.id):
			_revealed[s.id] = true
			if is_visible_in_tree() and fresh < 4:
				s.reveal(fresh * Shelf.REVEAL_SHELF_STAGGER_S)
				fresh += 1
		if tile_hook.is_valid():
			for t in s.tiles:
				tile_hook.call(t)
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 240)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rows_box.add_child(spacer)


## Library shelves, with the Apps shelf (pinned apps, then All apps) when
## anything is pinned: after Recently played, Favourites, Installed and
## Emulation (whichever of them show), before the rest.
const BEFORE_APPS := ["recent", "favourites", "installed", "emulation"]


static func shelf_specs(list: Array, pinned: Array) -> Array:
	var specs: Array = View.shelves(list)
	if not pinned.is_empty():
		var AppsView = load("res://scripts/ui/apps_view.gd")
		var TX = load("res://scripts/ui/texts_extras.gd")
		var at := 0
		for i in specs.size():
			if specs[i]["id"] in BEFORE_APPS:
				at = i + 1
		specs.insert(at, {"id": "apps", "title": TX.APPS_SHELF, "games": pinned + [AppsView.all_tile()]})
	return specs


## Pinned apps for the Apps shelf (main.gd: at start and when pins change).
func set_apps(list: Array) -> void:
	var keep := _focused_tile_ref()
	apps = list
	_build_rows()
	_restore_focus(keep)


func _on_app_pressed(g: Dictionary) -> void:
	if str(g.get("key", "")) == "app:__all__":
		apps_requested.emit()
	else:
		play_requested.emit(g)


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
	# an app isn't a game: the spotlight keeps the last game
	if str(g.get("store", "")) != "app":
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


## Rebuilds the rows after the screen size changed the cover size.
func _refit_rows() -> void:
	set_games(games)


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
		_style_frame()
	elif what == NOTIFICATION_RESIZED and not _shelves.is_empty():
		# Covers size to the screen (Tile.PER_ROW across): rebuild if that changed.
		if Tile.size_for(Tile.row_width(), Shelf.GAP) != _shelves[0].tile_size:
			call_deferred("_refit_rows")
