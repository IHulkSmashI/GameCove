extends "res://scripts/ui/page_template.gd"
## Emulation: EmuDeck (or RetroDECK, or ES-DE on its own) in GameCove, on the
## shared page template. We start their tools; we don't run emulators ourselves.
##   Open ES-DE / RetroDECK   through main's launch path (launch animation,
##                            gamescope focus, quick menu, play time)
##   EmuDeck / RetroDECK settings   their own app, for emulator updates and settings
##   Add ROMs to Steam too    Steam ROM Manager, which adds each ROM to Steam's
##                            own library (ours lists every ROM already)
## Cards: Systems (each console with its game count; pick one and the Library
## opens on its games), Recently played (the ROM games you played last, each
## opening its game page; ES-DE's gamelists when ROM games are off), Your setup
## (where things are, how many emulated games the Library has). Nothing
## installed: what EmuDeck is and a QR code to its site.
##
## setup(emu, games): `emu` is Library.emulation (Emu.detect), `games` the
## decorated Library games (the "emu" ones are counted and opened).

const TL := preload("res://scripts/ui/texts_library.gd")
const TG := preload("res://scripts/ui/texts_games.gd")
const Roms := preload("res://scripts/library/stores/roms.gd")
const SKit := preload("res://scripts/ui/settings/kit.gd")
const GameIcons := preload("res://scripts/ui/games/game_icons.gd")
const QR := preload("res://scripts/ui/settings/qr.gd")
const LinkHandoff := preload("res://scripts/ui/games/link_handoff.gd")
const View := preload("res://scripts/ui/library_view.gd")
const Tile := preload("res://scripts/ui/game_tile.gd")
const CardJobs := preload("res://scripts/system/card_jobs.gd")
const ImageGuard := preload("res://scripts/ui/image_guard.gd")
const TOP_INSET := 56
## System chips shown before "+N more" (read-only chips; buttons all show).
const SYSTEMS_SHOWN := 18
## Recently played rows.
const RECENT_SHOWN := 6
## The Games card: rows of tiles made at once (more as focus nears the last row), gap.
const GRID_ROWS := 3
const GRID_GAP := 16

## Start this (the frontend, EmuDeck's app or Steam ROM Manager) the way a game starts.
signal play_requested(game: Dictionary)
signal back_requested
## Show the emulated games in the Library (its Emulation view).
signal library_requested
## Show one console's games in the Library ("emulation:<system>").
signal system_requested(system: String)
## Open this game's page.
signal game_requested(game: Dictionary)

var emu: Dictionary = {}
var frontend_game: Dictionary = {}
var emu_games: Array = []
var open_button: Button
var app_button: Button
var srm_button: Button
var library_button: Button
var get_button: Button
## System buttons (ROM games on) and recently played rows, in page order.
var system_buttons: Array = []
var recent_buttons: Array = []
## The Games card: its console picker, the picked console ("" = all, kept across
## rescans) and the tiles made so far.
var picker: HFlowContainer
var picker_buttons: Array = []
var picked_system := ""
var games_grid: GridContainer
var game_tiles: Array = []
var _grid_list: Array = []
var handoff: Control
## Kept null for main (it reloads a game page's launch settings after the quick menu).
var form: Object = null
var game_settings: Object = null


func setup(setup_info: Dictionary, games: Array) -> void:
	name = "EmulationPage"
	emu = setup_info
	emu_games = games.filter(func(g): return g.get("store", "") == "emu")
	frontend_game = {}
	for g in emu_games:
		if str(g.get("id", "")) == "frontend":
			frontend_game = g
	top_inset = TOP_INSET
	# No frontend: a stand-in with no key, so the quick menu's This game stays empty.
	var g := frontend_game if not frontend_game.is_empty() else {"key": "", "store": "emu", "id": "page", "title": TL.EMU_TITLE,
		"installed": true, "art": {"cover": "", "hero": "", "logo": "", "icon": ""}, "info": {}}
	setup_page(g, "")
	handoff = LinkHandoff.new()
	add_child(handoff)
	if str(emu.get("kind", "")) == "":
		_build_empty()
	else:
		_build_setup()
		_hero_art()
	finish()


## A launchable stand-in for one of the setup's tools ("app", "srm").
func tool_game(which: String) -> Dictionary:
	var t: Variant = emu.get(which, {})
	if not t is Dictionary or t.is_empty():
		return {}
	var title := str(t.get("name", "Steam ROM Manager"))
	return {"key": "emu:" + which, "store": "emu", "id": which, "title": title, "installed": true, "frontend": true,
		"command": t["command"], "art": {"cover": "", "hero": "", "logo": "", "icon": ""}, "info": {}}


func _build_setup() -> void:
	var kind := str(emu.get("kind", ""))
	var fe: Dictionary = emu.get("frontend", {})
	if not fe.is_empty() and not frontend_game.is_empty():
		open_button = add_action(TL.EMU_OPEN % fe["name"], "", true, "Play")
		open_button.icon = GameIcons.tex("play", 22)
		open_button.pressed.connect(func(): play_requested.emit(frontend_game))
	if not emu.get("app", {}).is_empty():
		app_button = add_action(TL.EMU_APP_RETRODECK if kind == "retrodeck" else TL.EMU_APP_EMUDECK, "", open_button == null, "App")
		app_button.icon = GameIcons.tex("wrench", 20)
		app_button.pressed.connect(func(): play_requested.emit(tool_game("app")))
	srm_button = add_action(TL.EMU_SRM, "", actions.is_empty(), "Srm")
	srm_button.icon = GameIcons.tex("plus", 20)
	srm_button.disabled = emu.get("srm", {}).is_empty()
	srm_button.focus_mode = Control.FOCUS_ALL
	srm_button.pressed.connect(func():
		if not srm_button.disabled:
			play_requested.emit(tool_game("srm")))

	var roms := str(emu.get("roms_dir", ""))
	if emu_games.any(func(g): return g.get("emulated", {}).get("rom", false)):
		_fill_games(add_card(TL.EMU_GAMES, "library", TL.EMU_GAMES_LINE))
	var sys := add_card(TL.EMU_SYSTEMS, "gamepad", TL.EMU_SYSTEMS_LINE % _short_path(roms), true, 0)
	_fill_systems(sys, roms)
	var ours := emu_games.any(func(g): return g.get("emulated", {}).get("rom", false))
	var rec := add_card(TL.EMU_RECENT_OURS if ours else TL.EMU_RECENT % (fe.get("name", "ES-DE") if not fe.is_empty() else "ES-DE"), "clock", "", true, 1)
	_fill_recent(rec, fe)
	var where := add_card(TL.EMU_SETUP, "info", "", true, 2)
	_fill_setup(where, kind, fe, roms)


func _fill_systems(body: VBoxContainer, roms: String) -> void:
	var list: Array = emu.get("systems", [])
	if list.is_empty():
		body.add_child(Kit.label(TL.EMU_NO_ROMS % _short_path(roms), "QuietLabel", true))
		return
	var flow := HFlowContainer.new()
	flow.name = "Systems"
	flow.add_theme_constant_override("h_separation", 8)
	flow.add_theme_constant_override("v_separation", 8)
	# With ROM games in the Library every console with games there is a button
	# (all of them: it's how you get to that console's games); else read-only chips.
	var in_lib := {}
	for g in emu_games:
		var sys := View.system_of(g)
		if sys != "":
			in_lib[sys] = true
	var shown: Array = list if not in_lib.is_empty() else list.slice(0, SYSTEMS_SHOWN)
	for s in shown:
		var id := str(s["id"])
		var what := "%s · %s" % [s["name"], TL.EMU_SYSTEM_COUNT % [int(s["count"]), TL.plural(int(s["count"]))]]
		if not (s.get("roots", []) as Array).is_empty():
			what += " · " + ", ".join(s["roots"].map(func(r): return _short_path(str(r))))
		if not s.get("known", true):
			what += " · " + TL.EMU_UNKNOWN_SYSTEM
		if in_lib.has(id):
			var b := Button.new()
			b.name = "System_" + id.validate_node_name()
			b.theme_type_variation = "ChipButton"
			b.text = "%s  %d" % [s["short"], int(s["count"])]
			b.icon = GameIcons.tex("gamepad", 18)
			b.custom_minimum_size = Vector2(0, 44)
			b.focus_mode = Control.FOCUS_ALL
			b.tooltip_text = what
			b.pressed.connect(func(): system_requested.emit(id))
			flow.add_child(b)
			system_buttons.append(b)
		else:
			var chip := SKit.chip("%s  %d" % [s["short"], int(s["count"])], "", "")
			chip.name = "System_" + id.validate_node_name()
			chip.tooltip_text = what
			flow.add_child(chip)
	if shown.size() < list.size():
		flow.add_child(SKit.chip("+%d" % (list.size() - shown.size()), "", ""))
	body.add_child(flow)
	add_focusables(system_buttons)
	var total := int(emu.get("rom_total", 0))
	var line := Kit.label(TL.EMU_SYSTEM_COUNT % [total, TL.plural(total)] + " · " + "%d system%s" % [list.size(), TL.plural(list.size())], "CaptionLabel")
	line.name = "RomTotal"
	line.add_theme_color_override("font_color", ThemeLib.color("text_3"))
	body.add_child(line)
	for s in list:
		var sid := str(s["id"]).validate_node_name()
		for note in [["Capped", bool(s.get("capped", false)), TL.EMU_CAPPED % [str(Roms.SYSTEM_MAX), s["name"]]],
				["Gamelist", bool(s.get("gamelist_skipped", false)), TL.EMU_GAMELIST_BIG % s["name"]]]:
			if note[1]:
				var l := Kit.label(note[2], "CaptionLabel", true)
				l.name = "RomNote%s_%s" % [note[0], sid]
				l.add_theme_color_override("font_color", ThemeLib.color("text_3"))
				body.add_child(l)


func _fill_recent(body: VBoxContainer, fe: Dictionary) -> void:
	var roms := emu_games.filter(func(g): return g.get("emulated", {}).get("rom", false))
	if not roms.is_empty():
		_fill_recent_games(body, roms)
		return
	var list: Array = emu.get("recent", [])
	if list.is_empty():
		body.add_child(Kit.label(TL.EMU_NO_RECENT % fe.get("name", "ES-DE"), "QuietLabel", true))
		return
	var now := int(Time.get_unix_time_from_system())
	for r in list:
		var row := _title_meta(str(r["title"]), "%s · %s" % [r["system"], TG.ago(int(r["last_played"]), now)])
		row.name = "Recent"
		body.add_child(row)


## A list row: the title on its own line with the whole width (cut only when it
## truly doesn't fit), the console and when under it.
func _title_meta(title: String, meta_text: String) -> VBoxContainer:
	var col := Kit.vbox(0)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var t := Kit.label(title, "")
	t.name = "Title"
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(t)
	var meta := Kit.label(meta_text, "CaptionLabel")
	meta.name = "Meta"
	meta.add_theme_color_override("font_color", ThemeLib.color("text_2"))
	meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(meta)
	return col


# ------------------------------------------------------------ the hero

## Covers in the hero collage at most, and the height it's drawn at (its width
## follows the hero frame's shape, so the frame never crops a cover off its edge).
const COLLAGE_MAX := 8
const COLLAGE_H := 420
## The collage starts this far across (the shared scrim fades it in from there).
const COLLAGE_FROM := 0.5
## Its left edge fades in over this part of the width (no hard cut beside the buttons).
const COLLAGE_FADE := 0.14
## Tests: draw the collage at once instead of on a worker.
static var _sync_jobs := false


## The hero: your own ROM covers side by side, through the page template's hero
## art and its shared scrims (dark at the left behind the title, fading out);
## before any ROM has art, a pattern of your consoles (FallbackArt.set_pattern).
## Never console makers' art or logos.
func _hero_art() -> void:
	var covers := collage_covers(emu_games)
	# Drawn at the frame's shape and clear of the buttons: again once it has its size.
	var sized := frame.size.x >= 2.0 and frame.size.y >= 2.0
	if not sized and not frame.resized.is_connected(_hero_art):
		frame.resized.connect(_hero_art, CONNECT_ONE_SHOT)
	# The buttons grow as they're styled and laid out: the art moves with them.
	if actions_row != null and not actions_row.sort_children.is_connected(_on_actions_laid_out):
		actions_row.sort_children.connect(_on_actions_laid_out)
	var from := art_from()
	_art_from_used = from
	if covers.is_empty():
		var shorts: Array = View.systems_in(emu_games).map(func(sy): return sy["short"])
		if shorts.is_empty():
			shorts = (emu.get("systems", []) as Array).map(func(sy): return sy["short"])
		if not shorts.is_empty() and hero_fallback != null:
			hero_fallback.pattern_from = from
			hero_fallback.set_pattern(shorts)
		return
	if not sized:
		return
	var size := collage_size(frame.size)
	# Off the main thread, owned by CardJobs: the page never waits for it, and a page that's gone is skipped.
	CardJobs.shared().run_for(self, func(): return collage(covers, size, from), "_collage_done", [], not _sync_jobs)


var _art_from_used := -1.0


## The buttons row was laid out: draw the hero art again only if it must move.
func _on_actions_laid_out() -> void:
	if frame != null and frame.size.x >= 2.0 and absf(art_from() - _art_from_used) > 0.01:
		_hero_art()


## Where the hero art may start across the frame (0..1): past the buttons row
## with room to spare, never left of COLLAGE_FROM (at 1280x800 the buttons
## reach past the middle).
func art_from() -> float:
	if frame == null or frame.size.x < 2.0 or actions_row == null:
		return COLLAGE_FROM
	# The buttons' real right edge once laid out (styled buttons outgrow their first minimum).
	var row := actions_row.get_combined_minimum_size().x
	for c in actions_row.get_children():
		if c is Control and c.visible:
			row = maxf(row, c.position.x + c.size.x)
	var right := 32.0 + row + 48.0   # the hero column starts 32 px into the frame
	return clampf(right / frame.size.x, COLLAGE_FROM, 0.75)


## The collage's size for a hero frame of `frame_size`: COLLAGE_H tall, as wide
## as the frame's shape asks (the hero fills the frame without cutting a side).
static func collage_size(frame_size: Vector2) -> Vector2i:
	return Vector2i(maxi(COLLAGE_H, int(round(COLLAGE_H * frame_size.x / maxf(frame_size.y, 1.0)))), COLLAGE_H)


## Covers for the collage: the ROM games played last first, then A to Z.
static func collage_covers(games: Array) -> Array:
	var roms := games.filter(func(g): return g.get("emulated", {}).get("rom", false) and not g.get("hidden", false))
	var out: Array = []
	for g in View.sort_games(roms, "recent"):
		var c := str(g.get("art", {}).get("cover", ""))
		if c != "" and FileAccess.file_exists(c) and not c in out:
			out.append(c)
			if out.size() >= COLLAGE_MAX:
				break
	return out


## The covers in a row from the right edge, each cut to fill a 3:4 cell (no
## stretching), as far left as `start` (the last one cut there and faded in);
## clear elsewhere. Off the main thread.
static func collage(paths: Array, size: Vector2i, start := COLLAGE_FROM) -> Image:
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))   # the theme's own card shows through where the title sits
	var ch := size.y
	var cw := int(ch * 0.75)
	var gap := 10
	var x := size.x - cw
	var start_px := int(size.x * start)
	for p in paths:
		if x + cw <= start_px:
			break   # the left of the hero stays clear for the title and buttons
		var src := _load_image(str(p))
		if src == null or src.is_empty():
			continue
		src.convert(Image.FORMAT_RGBA8)
		var sc := maxf(float(cw) / src.get_width(), float(ch) / src.get_height())
		src.resize(maxi(cw, int(ceil(src.get_width() * sc))), maxi(ch, int(ceil(src.get_height() * sc))), Image.INTERPOLATE_BILINEAR)
		var from := Vector2i((src.get_width() - cw) / 2, (src.get_height() - ch) / 2)
		img.blit_rect(src, Rect2i(from, Vector2i(cw, ch)), Vector2i(x, 0))
		x -= cw + gap
	# Fade the collage in from its left end (a cover reaching past `start` is cut there, faded).
	var left := maxi(start_px, x + cw + gap)
	img.fill_rect(Rect2i(0, 0, clampi(left, 0, size.x), size.y), Color(0, 0, 0, 0))
	var fade := int(size.x * COLLAGE_FADE)
	for px in range(maxi(0, left), mini(size.x, left + fade)):
		var k := smoothstep(0.0, 1.0, float(px - left) / fade)
		for py in size.y:
			var c := img.get_pixel(px, py)
			c.a *= k
			img.set_pixel(px, py, c)
	return img


## A PNG, JPEG or WebP file as an Image; null for anything else (a broken
## download stays out of the collage without an error in the log) and for a
## file whose header names a picture too big to decode (image_guard.gd).
static func _load_image(path: String) -> Image:
	return ImageGuard.load_known(path)


func _collage_done(img: Image) -> void:
	if img != null and is_instance_valid(hero):
		_show_hero(ImageTexture.create_from_image(img))


# ------------------------------------------------------------ the games, on the page

## The Games card: a console picker (All and every console with games, with
## counts) and that console's games as Library tiles, from the same list and
## filters as the Library's Emulation view (View.filter_view "emulation" /
## "emulation:<system>"). A plays, Menu opens the game page. Tiles are made a
## page at a time as focus nears the last row.
func _fill_games(body: VBoxContainer) -> void:
	picker = HFlowContainer.new()
	picker.name = "Picker"
	picker.add_theme_constant_override("h_separation", 8)
	picker.add_theme_constant_override("v_separation", 8)
	body.add_child(picker)
	var all_n := View.filter_view(emu_games, "emulation").filter(func(g): return g.get("emulated", {}).get("rom", false)).size()
	var choices: Array = [["", TL.EMU_ALL_SYSTEMS, all_n]]
	var known := {}
	for sy in View.systems_in(emu_games):
		choices.append([sy["id"], sy["short"], sy["count"]])
		known[sy["id"]] = true
	if not known.has(picked_system):
		picked_system = ""
	for c in choices:
		var b := Button.new()
		b.name = "Pick_" + (str(c[0]) if c[0] != "" else "all").validate_node_name()
		b.theme_type_variation = "ChipButton"
		b.toggle_mode = true
		b.button_pressed = c[0] == picked_system
		b.text = "%s  %d" % [c[1], int(c[2])]
		b.custom_minimum_size = Vector2(0, 44)
		b.focus_mode = Control.FOCUS_ALL
		var id: String = c[0]
		b.pressed.connect(func(): pick_system(id))
		picker.add_child(b)
		picker_buttons.append(b)
	games_grid = GridContainer.new()
	games_grid.name = "Games"
	games_grid.columns = clampi(int((Tile.row_width() - 2.0 * ThemeLib.EDGE - 120.0 + GRID_GAP) / (Tile.SIZE.x + GRID_GAP)), 4, 9)
	games_grid.add_theme_constant_override("h_separation", GRID_GAP)
	games_grid.add_theme_constant_override("v_separation", GRID_GAP)
	body.add_child(games_grid)
	add_focusables([_current_pick()])
	_fill_grid()


## The games the grid shows: the picked console's (all of them for ""), what you
## played last first, then A to Z (the Library's "Recent" order).
func grid_games() -> Array:
	var view := "emulation" if picked_system == "" else "emulation:" + picked_system
	var list := View.filter_view(emu_games, view).filter(func(g): return g.get("emulated", {}).get("rom", false))
	return View.sort_games(list, "recent")


## Shows another console's games (focus stays on the picker).
func pick_system(id: String) -> void:
	picked_system = id
	for b in picker_buttons:
		b.set_pressed_no_signal(b.name == "Pick_" + (id if id != "" else "all").validate_node_name())
	_fill_grid()
	_link_games()


func _fill_grid() -> void:
	for t in game_tiles:
		Kit.drop(games_grid, t)
	game_tiles.clear()
	_grid_list = grid_games()
	_grow_grid(games_grid.columns * GRID_ROWS)


func _grow_grid(count: int) -> void:
	var to := mini(count, _grid_list.size())
	for i in range(game_tiles.size(), to):
		var g: Dictionary = _grid_list[i]
		var t: Button = Tile.new()
		t.setup(g, true, Tile.SIZE, false)
		t.pressed.connect(func(): play_requested.emit(g))
		t.gui_input.connect(func(ev: InputEvent):
			if (ev is InputEventJoypadButton and ev.pressed and ev.button_index == JOY_BUTTON_START) \
					or (ev is InputEventKey and ev.pressed and not ev.echo and ev.keycode == KEY_M):
				t.accept_event()
				game_requested.emit(g))
		t.focus_entered.connect(func():
			if game_tiles.find(t) >= game_tiles.size() - games_grid.columns and game_tiles.size() < _grid_list.size():
				_grow_grid(game_tiles.size() + games_grid.columns * GRID_ROWS)
				_link_games())
		games_grid.add_child(t)
		game_tiles.append(t)


func _current_pick() -> Control:
	for b in picker_buttons:
		if b.button_pressed:
			return b
	return picker_buttons[0] if not picker_buttons.is_empty() else null


## The picker and grid in the page's focus chain: across the picker, down into
## the grid, around the grid, and on down to the cards below.
func _link_games() -> void:
	if picker_buttons.is_empty():
		return
	Kit.link_horizontal(picker_buttons)
	var i := focusables.find(_current_pick())
	if i < 0:
		for b in picker_buttons:
			i = maxi(i, focusables.find(b))
	var below: Control = focusables[i + 1] if i >= 0 and i + 1 < focusables.size() else null
	var top: Control = actions[0] if not actions.is_empty() else null
	var cols := games_grid.columns
	for b in picker_buttons:
		if top != null:
			b.focus_neighbor_top = b.get_path_to(top)
		var down: Control = game_tiles[0] if not game_tiles.is_empty() else below
		b.focus_neighbor_bottom = b.get_path_to(down if down != null else b)
	for k in game_tiles.size():
		var t: Control = game_tiles[k]
		var up: Control = game_tiles[k - cols] if k >= cols else _current_pick()
		var dn: Control = game_tiles[k + cols] if k + cols < game_tiles.size() else \
			(game_tiles[game_tiles.size() - 1] if k / cols < (game_tiles.size() - 1) / cols else (below if below != null else t))
		t.focus_neighbor_top = t.get_path_to(up)
		t.focus_neighbor_bottom = t.get_path_to(dn)
		t.focus_neighbor_left = t.get_path_to(game_tiles[k - 1] if k % cols > 0 else t)
		t.focus_neighbor_right = t.get_path_to(game_tiles[k + 1] if k % cols < cols - 1 and k + 1 < game_tiles.size() else t)
	if below != null:
		var last_row_start := ((game_tiles.size() - 1) / cols) * cols if not game_tiles.is_empty() else -1
		below.focus_neighbor_top = below.get_path_to(game_tiles[last_row_start] if last_row_start >= 0 else _current_pick())
	if top != null:
		top.focus_neighbor_bottom = top.get_path_to(_current_pick())


func finish() -> void:
	super.finish()
	_link_games()


## ROM games you played last (ours and ES-DE's times), each opening its game page.
func _fill_recent_games(body: VBoxContainer, roms: Array) -> void:
	var played := View.recently_played(roms.filter(func(g): return not g.get("hidden", false)), RECENT_SHOWN)
	if played.is_empty():
		body.add_child(Kit.label(TL.EMU_NOTHING_PLAYED, "QuietLabel", true))
		return
	var now := int(Time.get_unix_time_from_system())
	for g in played:
		var b := Button.new()
		b.name = "Recent"
		b.theme_type_variation = "RowButton"
		b.focus_mode = Control.FOCUS_ALL
		b.custom_minimum_size = Vector2(0, 60)
		var row := _title_meta(str(g.get("title", "")), "%s · %s" % [g.get("emulated", {}).get("system_short", ""), TG.ago(int(g["last_played"]), now)])
		row.set_anchors_preset(Control.PRESET_FULL_RECT)
		row.offset_left = 14
		row.offset_right = -14
		row.offset_top = 7
		row.offset_bottom = -7
		b.add_child(row)
		var game: Dictionary = g
		b.pressed.connect(func(): game_requested.emit(game))
		body.add_child(b)
		recent_buttons.append(b)
	add_focusables(recent_buttons)


func _fill_setup(body: VBoxContainer, kind: String, fe: Dictionary, roms: String) -> void:
	body.add_child(SKit.fact(TL.EMU_FACT_SETUP, TL.EMU_KIND.get(kind, kind), 130))
	body.add_child(SKit.fact(TL.EMU_FACT_FRONTEND, str(fe.get("name", "")) if not fe.is_empty() else "-", 130))
	var roots: Array = emu.get("roots", [])
	if roots.is_empty():
		body.add_child(SKit.fact(TL.EMU_FACT_ROMS, _short_path(roms), 130))
	for r in roots:
		var where := _short_path(str(r["path"]))
		if not r.get("online", true):
			where += " · " + TL.EMU_ROOT_OFFLINE
		else:
			var n := (emu.get("systems", []) as Array).filter(func(sy): return str(r["path"]) in sy.get("roots", [])).size()
			if n > 0:
				where += " · %d system%s" % [n, TL.plural(n)]
		var f := SKit.fact(TL.EMU_FACT_ROMS, where, 130)
		f.name = "Root"
		body.add_child(f)
	if fe.is_empty():
		body.add_child(SKit.note(TL.EMU_NO_FRONTEND, "info", "NoFrontend"))
	if emu.get("srm", {}).is_empty():
		body.add_child(SKit.note(TL.EMU_SRM_MISSING, "info", "NoSrm"))
	var n := emu_games.filter(func(g): return str(g.get("id", "")) != "frontend").size()
	var shown_roms: bool = emu.get("roms_shown", false)
	body.add_child(Kit.label(TL.EMU_IN_LIBRARY, "LeadLabel"))
	var line: String = TL.EMU_IN_LIBRARY_NONE
	if shown_roms and n > 0:
		line = TL.EMU_IN_LIBRARY_LINE % [n, TL.plural(n)]
	elif not shown_roms and n > 0:
		line = (TL.EMU_IN_LIBRARY_SRM % [n, TL.plural(n)]) + " " + TL.EMU_IN_LIBRARY_OFF
	elif not shown_roms:
		line = TL.EMU_IN_LIBRARY_OFF
	var in_lib := Kit.label(line, "QuietLabel", true)
	in_lib.name = "InLibrary"
	body.add_child(in_lib)
	if n > 0:
		library_button = SKit.action(TL.EMU_SHOW_IN_LIBRARY, "library", "ShowInLibrary")
		library_button.pressed.connect(func(): library_requested.emit())
		body.add_child(library_button)
		add_focusables([library_button])
	var legal := Kit.label(TL.EMU_LEGAL, "CaptionLabel", true)
	legal.add_theme_color_override("font_color", ThemeLib.color("text_3"))
	body.add_child(legal)


func _build_empty() -> void:
	get_button = add_action(TL.EMU_GET, "", true, "GetEmuDeck")
	get_button.icon = GameIcons.tex("external", 20)
	get_button.pressed.connect(func(): handoff.open("EmuDeck", TL.EMU_EMPTY_QR, TL.EMUDECK_URL))
	var body := add_card(TL.EMU_EMPTY_TITLE, "gamepad", TL.EMU_EMPTY_LINE)
	var row := Kit.hbox(28)
	row.name = "EmptyRow"
	var qr := TextureRect.new()
	qr.name = "Qr"
	QR.show_on(qr, TL.EMUDECK_URL, 5)
	qr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	qr.custom_minimum_size = Vector2(180, 180)
	qr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	row.add_child(qr)
	var steps := Kit.vbox(10)
	steps.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	steps.alignment = BoxContainer.ALIGNMENT_CENTER
	for i in TL.EMU_EMPTY_STEPS.size():
		var s := Kit.label("%d.  %s" % [i + 1, TL.EMU_EMPTY_STEPS[i]], "", true)
		steps.add_child(s)
	var cap := Kit.label(TL.EMU_EMPTY_QR, "CaptionLabel", true)
	cap.add_theme_color_override("font_color", ThemeLib.color("text_3"))
	steps.add_child(cap)
	row.add_child(steps)
	body.add_child(row)
	var legal := Kit.label(TL.EMU_LEGAL, "CaptionLabel", true)
	legal.add_theme_color_override("font_color", ThemeLib.color("text_3"))
	body.add_child(legal)


func _short_path(p: String) -> String:
	var home := OS.get_environment("HOME")
	return "~" + p.substr(home.length()) if home != "" and p.begins_with(home) else p


## The Library rescanned: rebuild with what it found (keeps the page open).
func refresh_from(setup_info: Dictionary, games: Array) -> void:
	var had := is_inside_tree() and get_viewport().gui_get_focus_owner() != null and is_ancestor_of(get_viewport().gui_get_focus_owner())
	for c in get_children():
		remove_child(c)
		c.queue_free()
	actions.clear()
	focusables.clear()
	_column_cards.clear()
	columns = null
	open_button = null
	app_button = null
	srm_button = null
	library_button = null
	get_button = null
	system_buttons.clear()
	recent_buttons.clear()
	picker_buttons.clear()
	game_tiles.clear()
	picker = null
	games_grid = null
	setup(setup_info, games)
	if is_instance_valid(top_target):
		set_top_target(top_target)
	if had:
		focus_first()


func update_game(_g: Dictionary) -> void:
	pass


func default_focus() -> Control:
	return actions[0] if not actions.is_empty() else null


func focus_first() -> void:
	if is_inside_tree():
		await get_tree().process_frame
	var f := default_focus()
	if is_instance_valid(f) and f.is_inside_tree():
		f.grab_focus()
		scroll.scroll_vertical = 0


func hints_for_focus(f: Control) -> Array:
	if handoff != null and handoff.is_open():
		return LinkHandoff.hints()
	if f == srm_button and srm_button.disabled:
		return [["B", "Back"]]
	if f in game_tiles:
		return [["A", TL.EMU_HINT_PLAY], ["MENU", TL.EMU_HINT_PAGE], ["B", "Back"]]
	return []
