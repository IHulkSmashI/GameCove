extends Control
## Apps: every desktop app on the handheld as a grid of icon cards (A starts
## it full screen, X pins it to Home's Apps shelf or unpins it, B goes back).
## Opened from Home's Apps shelf ("All apps") and from the Library's header.
##
## Pinned apps show at once (they're saved with their icons); the full list is
## read on a WorkerThreadPool task each time the view opens (apps.gd scan and
## icon cache) and then fills in. Nothing runs while it's closed.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Tile := preload("res://scripts/ui/game_tile.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const Illustrations := preload("res://scripts/ui/illustrations.gd")
const Apps := preload("res://scripts/library/apps.gd")
const TX := preload("res://scripts/ui/texts_extras.gd")
const CardJobs := preload("res://scripts/system/card_jobs.gd")

## A was pressed on an app.
signal launch_requested(app: Dictionary)
## The pinned list changed (Home rebuilds its shelf).
signal pins_changed
## A toast: text, tone.
signal notice(text: String, tone: String)

const GAP := Vector2(18, 20)
const MAX_COLS := 7

var apps: Array = []
var tiles: Array = []
## func() -> Array: the scan (tests replace it); runs off the main thread.
var scan_fn: Callable = func() -> Array: return scan_installed()
var pins_path := Apps.PINS_PATH
var loading := false
var grid: GridContainer
var count_label: Label
var status_label: Label
var top_target: Control
var _scroll: ScrollContainer
var _empty: Control
var _gen := 0


## The real scan: .desktop files from the user's and the system's folders,
## each app's icon cached as a PNG.
static func scan_installed() -> Array:
	var env := {"home": OS.get_environment("HOME"), "xdg_data_dirs": OS.get_environment("XDG_DATA_DIRS"),
		"path_env": OS.get_environment("PATH"), "locale": OS.get_locale()}
	var out: Array = []
	for a in Apps.scan(env):
		out.append(Apps.with_art(a, Apps.cached_icon(a)))
	return out


## The last tile of Home's Apps shelf: opens this view.
const ALL_KEY := "app:__all__"


static func all_tile() -> Dictionary:
	var icon := ProjectSettings.globalize_path(Apps.ICON_CACHE).path_join("_all_apps.png")
	if not FileAccess.file_exists(icon):
		var Icons = load("res://scripts/ui/icons.gd")
		var img := Image.new()
		if img.load_svg_from_buffer(Icons.svg("apps", 24, Color(0.93, 0.95, 1.0)).to_utf8_buffer(), Apps.ICON_PX / 24.0) == OK:
			DirAccess.make_dir_recursive_absolute(icon.get_base_dir())
			img.save_png(icon)
	return {"key": ALL_KEY, "store": Apps.STORE, "id": "__all__", "title": TX.APPS_ALL, "sub": TX.APPS_ALL_LINE, "installed": true,
		"art": {"icon": icon} if FileAccess.file_exists(icon) else {}}


func _init() -> void:
	name = "AppsView"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	var margin := Kit.margin(0)
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 48)
	margin.add_theme_constant_override("margin_right", 48)
	margin.add_theme_constant_override("margin_top", 88)
	margin.add_theme_constant_override("margin_bottom", ThemeLib.HINT_BAR_H + 12)
	add_child(margin)
	var root := Kit.vbox(10)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(root)
	var head := Kit.hbox(14)
	head.add_child(Kit.label(TX.APPS_TITLE, "TitleLabel"))
	var dot := Kit.label("·", "TitleLabel")
	dot.add_theme_color_override("font_color", ThemeLib.color("text_3"))
	head.add_child(dot)
	count_label = Kit.label("", "TitleLabel")
	count_label.name = "Count"
	count_label.add_theme_color_override("font_color", ThemeLib.color("accent"))
	head.add_child(count_label)
	head.add_child(Kit.spacer())
	status_label = Kit.label("", "QuietLabel")
	status_label.name = "Status"
	status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	status_label.size_flags_vertical = Control.SIZE_FILL
	head.add_child(status_label)
	root.add_child(head)
	var line := Kit.label(TX.APPS_LINE, "QuietLabel", true)
	line.name = "Line"
	root.add_child(line)
	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.follow_focus = true
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_scroll)
	var pad := Kit.margin(12, 8, 12)
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(pad)
	grid = GridContainer.new()
	grid.name = "Grid"
	grid.columns = MAX_COLS
	grid.add_theme_constant_override("h_separation", int(GAP.x))
	grid.add_theme_constant_override("v_separation", int(GAP.y))
	pad.add_child(grid)
	_empty = Kit.hbox(28)
	_empty.name = "Empty"
	_empty.alignment = BoxContainer.ALIGNMENT_CENTER
	_empty.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_empty.visible = false
	_empty.add_child(Illustrations.rect("no_results", 160))
	var el := Kit.label(TX.APPS_EMPTY, "QuietLabel", true)
	el.custom_minimum_size = Vector2(380, 0)
	el.name = "EmptyText"
	_empty.add_child(el)
	root.add_child(_empty)


## Shows the pinned apps now and reads the full list.
func open() -> void:
	visible = true
	modulate.a = 0.0
	Motion.to(self, "modulate:a", 1.0, Motion.FAST)
	set_apps(Apps.pinned(pins_path))
	refresh()
	focus_first()


func close() -> void:
	visible = false


func refresh() -> void:
	if loading:
		return
	loading = true
	status_label.text = TX.APPS_LOADING
	_gen += 1
	var gen := _gen
	var fn := scan_fn
	if not is_inside_tree():
		_on_scanned(fn.call(), gen)
		return
	# the scan belongs to card_jobs.gd: leaving the view never waits for it, and
	# the result finds us by instance id (on the main thread) if we're still here
	CardJobs.shared().run_for(self, fn, "_on_scanned", [gen])


func _on_scanned(list: Array, gen: int) -> void:
	if gen != _gen:
		return
	loading = false
	status_label.text = ""
	var before := Apps.pinned(pins_path)
	var after := Apps.refresh_pins(list, pins_path)
	if before != after:
		pins_changed.emit()
	var keep := _focused_key()
	set_apps(list)
	if keep != "" and visible:
		for t in tiles:
			if t.game.get("key", "") == keep:
				Kit.focus_later(t)
				return
	if visible and (get_viewport() == null or get_viewport().gui_get_focus_owner() == null or not is_ancestor_of(get_viewport().gui_get_focus_owner())):
		focus_first()


func _focused_key() -> String:
	if not is_inside_tree():
		return ""
	var f := get_viewport().gui_get_focus_owner()
	return str(f.game.get("key", "")) if f != null and is_ancestor_of(f) and "game" in f else ""


## Builds the grid (pinned ones first, then A to Z).
func set_apps(list: Array) -> void:
	apps = order(list, Apps.pinned(pins_path))
	for t in tiles:
		Kit.drop(grid, t)
	tiles.clear()
	var size := tile_size()
	grid.columns = columns()
	var pinned_keys := {}
	for p in Apps.pinned(pins_path):
		pinned_keys[p["key"]] = true
	for a in apps:
		var t: Button = Tile.new()
		t.setup(a, false, size)
		if pinned_keys.has(a["key"]):
			t.set_status_pill({"kind": "state", "text": TX.APPS_PIN, "short": "Pinned", "tone": "good", "icon": "pin"})
		var app: Dictionary = a
		t.pressed.connect(func(): launch_requested.emit(app))
		grid.add_child(t)
		tiles.append(t)
	_link()
	count_label.text = str(apps.size())
	_empty.visible = apps.is_empty() and not loading
	_scroll.visible = not apps.is_empty()


## Pinned first (in pin order), then the rest A to Z; one each.
static func order(list: Array, pinned: Array) -> Array:
	var by_key := {}
	for a in list:
		by_key[a["key"]] = a
	var out: Array = []
	var seen := {}
	for p in pinned:
		var a: Dictionary = by_key.get(p["key"], p)
		out.append(a)
		seen[a["key"]] = true
	var rest := list.filter(func(a): return not seen.has(a["key"]))
	rest.sort_custom(func(a, b): return str(a["title"]).naturalnocasecmp_to(str(b["title"])) < 0)
	out.append_array(rest)
	return out


func columns() -> int:
	return MAX_COLS


func tile_size() -> Vector2:
	var w := (Tile.row_width() - 24.0 - GAP.x * (MAX_COLS - 1)) / MAX_COLS
	w = maxf(120.0, floorf(w))
	return Vector2(w, roundf(w * Tile.SIZE.y / Tile.SIZE.x))


func _link() -> void:
	var cols := grid.columns
	for i in tiles.size():
		var t: Control = tiles[i]
		t.focus_neighbor_left = t.get_path_to(tiles[i - 1]) if i % cols > 0 else t.get_path_to(t)
		t.focus_neighbor_right = t.get_path_to(tiles[i + 1]) if i % cols < cols - 1 and i + 1 < tiles.size() else t.get_path_to(t)
		t.focus_neighbor_top = t.get_path_to(tiles[i - cols]) if i >= cols else (t.get_path_to(top_target) if top_target != null else t.get_path_to(t))
		# down: the tile below, or the last one when the row below is shorter; the last row stays
		var below: Control = t
		if i + cols < tiles.size():
			below = tiles[i + cols]
		elif i / cols < (tiles.size() - 1) / cols:
			below = tiles[tiles.size() - 1]
		t.focus_neighbor_bottom = t.get_path_to(below)


func default_focus() -> Control:
	return tiles[0] if not tiles.is_empty() else null


func set_top_target(c: Control) -> void:
	top_target = c
	_link()


func focus_first() -> void:
	if not tiles.is_empty() and is_inside_tree():
		Kit.focus_later(tiles[0])


## X on a tile: pin it to Home, or unpin it.
func toggle_pin(app: Dictionary) -> void:
	var on := not Apps.is_pinned(str(app.get("key", "")), pins_path)
	if Apps.set_pinned(app, on, pins_path):
		notice.emit((TX.APPS_PINNED if on else TX.APPS_UNPINNED) % str(app.get("title", "")), "good")
		pins_changed.emit()
		var keep := str(app.get("key", ""))
		set_apps(apps)
		for t in tiles:
			if t.game.get("key", "") == keep:
				Kit.focus_later(t)


func toggle_focused() -> void:
	var f := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	if f != null and is_ancestor_of(f) and "game" in f:
		toggle_pin(f.game)


func hints_for_focus(f: Control) -> Array:
	var out: Array = [["A", TX.APPS_PROMPT_OPEN]]
	if f != null and is_ancestor_of(f) and "game" in f:
		out.append(["X", TX.APPS_UNPIN if Apps.is_pinned(str(f.game.get("key", "")), pins_path) else TX.APPS_PIN])
	out.append(["B", "Back"])
	out.append(["GUIDE", "Quick menu"])
	return out
