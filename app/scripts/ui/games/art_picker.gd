extends Control
## Change artwork: browse SteamGridDB's art for one game and use it in
## GameCove (and, for Steam games, in Steam's own library too). Tabs for
## Cover (portrait 600x900), Hero (banner), Logo and Icon; LB / RB switch
## them. Filters: style, animated, mature and humour (off by default). Every
## image shows its artist; the footer credits SteamGridDB. A uses the focused
## image, B closes. "Reset to default" brings back the store's art (and Steam's
## originals from the backup). Works for every store's games: Steam games by
## app id, others by their Steam twin or by title.
##
##   picker.open(game, Library.artwork)

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const Sgdb := preload("res://scripts/library/art/sgdb.gd")
const SteamGrid := preload("res://scripts/library/art/steam_grid.gd")

signal closed
## A credit's page for the phone (an artist's SteamGridDB profile).
signal link_requested(title: String, line: String, url: String)

const TABS := [["cover", "Cover"], ["hero", "Hero"], ["logo", "Logo"], ["icon", "Icon"]]
## Tile size and columns per kind.
const LAYOUT := {"cover": [Vector2(132, 198), 6], "hero": [Vector2(372, 120), 3], "logo": [Vector2(264, 112), 4], "icon": [Vector2(112, 112), 8]}
const PAGE_SIZE := 50
const PIN_NAMES := {"BottomLeft": "Bottom left", "UpperLeft": "Top left", "CenterCenter": "Centre", "UpperCenter": "Top centre", "BottomCenter": "Bottom centre"}
const STEAM_PREF := "user://settings.cfg"
const SettingsFile := preload("res://scripts/system/settings_file.gd")

var game: Dictionary = {}
var service: Object
var kind := "cover"
var filters := {}
var assets: Array = []
var tab_buttons: Array = []
var option_buttons: Array = []
var asset_buttons: Array = []
var style_button: Button
var animated_button: Button
var mature_button: Button
var steam_button: Button
var logo_pos_button: Button
var reset_button: Button
var status_label: Label
var title_label: Label
var credit_label: Label
## Also write picks into Steam's grid folder ([art] steam_grid, default on).
var to_steam := true
var prefs_path := STEAM_PREF
var _grid: GridContainer
var _scroll: ScrollContainer
var _dim: ColorRect
var _focus_before: Control
var _open := false
var _page := 0
var _more := false
var _loading := false
var _style_i := -1   # -1 = every style
var _gen := 0        # bumps on every new search, so late answers are dropped


func _init() -> void:
	name = "ArtPicker"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_dim = ColorRect.new()
	_dim.name = "Dim"
	Kit.fill(_dim)
	_dim.color = Color(ThemeLib.color("scrim"), 0.78)
	add_child(_dim)
	var panel := PanelContainer.new()
	panel.name = "Panel"
	Kit.fill(panel)
	panel.offset_left = 48
	panel.offset_right = -48
	panel.offset_top = 40
	panel.offset_bottom = -ThemeLib.HINT_BAR_H - 12
	panel.add_theme_stylebox_override("panel", ThemeLib.glass(ThemeLib.radius("xl"), 32, 26))
	add_child(panel)
	var col := Kit.vbox(14)
	panel.add_child(col)
	var head := Kit.hbox(18)
	var htxt := Kit.vbox(2)
	htxt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var eb := Kit.label("Change artwork", "EyebrowLabel")
	eb.uppercase = true
	htxt.add_child(eb)
	title_label = Kit.label("", "HeaderLabel")
	title_label.name = "Title"
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	htxt.add_child(title_label)
	head.add_child(htxt)
	var tabs := Kit.hbox(6)
	tabs.name = "Tabs"
	tabs.add_child(Kit.glyph("LB", false, true))
	for t in TABS:
		var b := Kit.button(t[1], "ChipButton")
		b.name = "Tab_" + t[0]
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(96, 44)
		var k: String = t[0]
		b.pressed.connect(func(): set_kind(k))
		tabs.add_child(b)
		tab_buttons.append(b)
	tabs.add_child(Kit.glyph("RB", false, true))
	head.add_child(tabs)
	col.add_child(head)
	var opts := Kit.hbox(8)
	opts.name = "Options"
	style_button = _opt(opts, "Style", func(): _cycle_style())
	animated_button = _opt(opts, "Animated", func(): _toggle("animated"))
	mature_button = _opt(opts, "Mature", func(): _toggle_mature())
	steam_button = _opt(opts, "Steam", func(): _toggle_steam())
	logo_pos_button = _opt(opts, "LogoPosition", func(): _cycle_logo_pos())
	opts.add_child(Kit.spacer())
	reset_button = _opt(opts, "Reset", func(): _reset())
	reset_button.text = "Reset to default"
	col.add_child(opts)
	status_label = Kit.label("", "QuietLabel", true)
	status_label.name = "Status"
	col.add_child(status_label)
	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_grid = GridContainer.new()
	_grid.name = "Grid"
	_grid.add_theme_constant_override("h_separation", 12)
	_grid.add_theme_constant_override("v_separation", 12)
	_scroll.add_child(_grid)
	col.add_child(_scroll)
	credit_label = Kit.label("Artwork from SteamGridDB (steamgriddb.com), made by its community; each image shows its artist.", "CaptionLabel", true)
	credit_label.name = "Credit"
	credit_label.add_theme_color_override("font_color", ThemeLib.color("text_3"))
	col.add_child(credit_label)


func _opt(box: Control, id: String, fn: Callable) -> Button:
	var b := Kit.button("", "ChipButton")
	b.name = "Opt_" + id
	b.custom_minimum_size = Vector2(0, 44)
	b.pressed.connect(fn)
	box.add_child(b)
	option_buttons.append(b)
	return b


func is_open() -> bool:
	return _open


func open(g: Dictionary, svc: Object) -> void:
	game = g
	service = svc
	title_label.text = str(g.get("title", ""))
	var cfg := ConfigFile.new()
	to_steam = bool(cfg.get_value("art", "steam_grid", true)) if cfg.load(prefs_path) == OK else true
	_open = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	if is_inside_tree():
		_focus_before = get_viewport().gui_get_focus_owner()
		Motion.fade(self, true)
	else:
		visible = true
	set_kind("cover")


func close() -> void:
	if not _open:
		return
	_open = false
	_gen += 1
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if is_inside_tree():
		Motion.fade(self, false)
		if is_instance_valid(_focus_before) and _focus_before.is_inside_tree():
			_focus_before.grab_focus()
	else:
		visible = false
	closed.emit()


func _is_steam() -> bool:
	return str(game.get("store", "")) == "steam"


func set_kind(k: String) -> void:
	kind = k
	filters = Sgdb.default_filters(k)
	_style_i = -1
	for i in TABS.size():
		tab_buttons[i].set_pressed_no_signal(TABS[i][0] == k)
	_search(true)


func cycle_kind(d: int) -> void:
	var ids: Array = TABS.map(func(t): return t[0])
	set_kind(ids[posmod(ids.find(kind) + d, ids.size())])
	if is_inside_tree():
		Kit.focus_later(asset_buttons[0] if not asset_buttons.is_empty() else tab_buttons[ids.find(kind)])


func _styles() -> Array:
	return Sgdb.KINDS[kind]["styles"]


func _cycle_style() -> void:
	_style_i = _style_i + 1
	if _style_i >= _styles().size():
		_style_i = -1
	filters["styles"] = _styles().duplicate() if _style_i < 0 else [_styles()[_style_i]]
	_search(true)


func _toggle(f: String) -> void:
	filters[f] = not filters.get(f, false)
	if not filters["animated"]:
		filters["static"] = true
	_search(true)


func _toggle_mature() -> void:
	var on: bool = not filters.get("nsfw", false)
	filters["nsfw"] = on
	filters["humor"] = on
	_search(true)


func _toggle_steam() -> void:
	to_steam = not to_steam
	var on := to_steam
	SettingsFile.update_cfg(prefs_path, func(cfg: ConfigFile): cfg.set_value("art", "steam_grid", on))
	_refresh_options()


func _cycle_logo_pos() -> void:
	if service == null or not _is_steam():
		return
	var cur: Dictionary = service.logo_position(str(game.get("id", "")))
	var pins: Array = SteamGrid.PINS
	var next: String = pins[(pins.find(str(cur.get("pin", "BottomLeft"))) + 1) % pins.size()]
	if service.set_logo_position(str(game.get("id", "")), next, float(cur.get("width", 50.0)), float(cur.get("height", 50.0))):
		_say("Steam shows the logo at the %s after it restarts." % PIN_NAMES[next].to_lower())
	_refresh_options()


func _reset() -> void:
	if service == null:
		return
	var ok: bool = service.reset(game, kind)
	_say(("%s is back to the store's own." if ok else "Couldn't put Steam's original %s back; the backup is in GameCove's art folder.") % TABS[TABS.map(func(t): return t[0]).find(kind)][1].to_lower())


func _say(t: String, tone := "") -> void:
	status_label.text = t
	status_label.add_theme_color_override("font_color", ThemeLib.color(tone) if tone != "" else ThemeLib.color("text_2"))


func _refresh_options() -> void:
	style_button.text = "Style: " + ("All" if _style_i < 0 else Sgdb.STYLE_NAMES.get(_styles()[_style_i], _styles()[_style_i]))
	animated_button.text = "Animated: " + ("On" if filters.get("animated", false) else "Off")
	mature_button.text = "Mature and humour: " + ("On" if filters.get("nsfw", false) else "Off")
	steam_button.visible = _is_steam() and kind != "icon"
	steam_button.text = "Also change in Steam: " + ("On" if to_steam else "Off")
	logo_pos_button.visible = _is_steam() and kind == "logo" and service != null
	if logo_pos_button.visible:
		var p: Dictionary = service.logo_position(str(game.get("id", "")))
		logo_pos_button.text = "Logo position: " + PIN_NAMES.get(str(p.get("pin", "BottomLeft")), "Bottom left")
	var o: Dictionary = service.override_for(game, kind) if service != null else {}
	reset_button.disabled = o.is_empty() and not _is_steam()
	var shown: Array = option_buttons.filter(func(b): return b.visible)
	Kit.link_horizontal(shown)
	_link()


func _search(fresh: bool) -> void:
	_refresh_options()
	if fresh:
		_page = 0
		assets.clear()
		for b in asset_buttons:
			Kit.drop(_grid, b)
		asset_buttons.clear()
		_scroll.scroll_vertical = 0
	var lay: Array = LAYOUT[kind]
	_grid.columns = lay[1]
	if service == null:
		_say("Artwork isn't available in this build.", "warn")
		return
	var why: String = service.unavailable_reason()
	if why != "":
		_say(why, "warn")
		_link()
		return
	_gen += 1
	var gen := _gen
	_loading = true
	_say("Looking on SteamGridDB…")
	service.search(game, kind, filters, _page, func(list: Array, err: String):
		if gen != _gen or not is_instance_valid(self):
			return
		_loading = false
		_more = list.size() >= PAGE_SIZE
		if err != "":
			_say(err, "warn")
		elif list.is_empty() and assets.is_empty():
			_say("Nothing here with these filters. Try another style, or turn on Animated.")
		else:
			_say("%d to choose from. A uses the one you're on." % (assets.size() + list.size()))
		_add(list))


func _add(list: Array) -> void:
	var lay: Array = LAYOUT[kind]
	var size: Vector2 = lay[0]
	for a in list:
		assets.append(a)
		var b := Button.new()
		b.name = "Asset%d" % int(a["id"])
		b.theme_type_variation = "ChipButton"
		b.focus_mode = Control.FOCUS_ALL
		b.custom_minimum_size = size + Vector2(0, 26)
		var v := Kit.vbox(4)
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.set_anchors_preset(Control.PRESET_FULL_RECT)
		v.offset_left = 5
		v.offset_right = -5
		v.offset_top = 5
		v.offset_bottom = -4
		var tr := TextureRect.new()
		tr.name = "Thumb"
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tr.size_flags_vertical = Control.SIZE_EXPAND_FILL
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		v.add_child(tr)
		var who := Kit.label(("by " + str(a["author"])) if str(a["author"]) != "" else "SteamGridDB", "CaptionLabel")
		who.name = "Author"
		who.add_theme_font_size_override("font_size", 12)
		who.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		who.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(who)
		b.add_child(v)
		var asset: Dictionary = a
		b.pressed.connect(func(): _use(asset))
		b.focus_entered.connect(func(): _on_asset_focus(b))
		_grid.add_child(b)
		asset_buttons.append(b)
		service.thumb(asset, func(path: String):
			if path != "" and is_instance_valid(tr):
				tr.texture = Kit.load_art(path, Vector2i(int(size.x) * 2, int(size.y) * 2)))
	_link()
	if is_inside_tree() and _open and _page == 0 and not asset_buttons.is_empty():
		var f := get_viewport().gui_get_focus_owner()
		if f == null or not is_ancestor_of(f):
			Kit.focus_later(asset_buttons[0])


func _on_asset_focus(b: Button) -> void:
	_scroll.ensure_control_visible(b)
	var i := asset_buttons.find(b)
	var a: Dictionary = assets[i] if i >= 0 and i < assets.size() else {}
	if not a.is_empty():
		_say("%s · %s%s. A to use it." % [Sgdb.credit(a), Sgdb.STYLE_NAMES.get(a["style"], a["style"].capitalize()), (", %d×%d" % [a["width"], a["height"]]) if a["width"] > 0 else ""])
	# near the end: the next page
	if _more and not _loading and i >= asset_buttons.size() - int(LAYOUT[kind][1]):
		_page += 1
		_search(false)


func _use(asset: Dictionary) -> void:
	if service == null:
		return
	_say("Getting it…")
	service.apply(game, kind, asset, to_steam and _is_steam(), func(ok: bool, msg: String):
		if is_instance_valid(self):
			_say(msg, "good" if ok else "warn")
			_refresh_options())


## Focus: tabs, then options, then the grid (row by row); nothing leaves the picker.
func _link() -> void:
	var opts: Array = option_buttons.filter(func(b): return b.visible)
	Kit.link_horizontal(tab_buttons)
	var cols: int = LAYOUT[kind][1]
	var first_row: Control = opts[0] if not opts.is_empty() else tab_buttons[0]
	for t in tab_buttons:
		t.focus_neighbor_top = t.get_path_to(t)
		t.focus_neighbor_bottom = t.get_path_to(first_row)
	for o in opts:
		o.focus_neighbor_top = o.get_path_to(tab_buttons[TABS.map(func(x): return x[0]).find(kind)])
		o.focus_neighbor_bottom = o.get_path_to(asset_buttons[0] if not asset_buttons.is_empty() else o)
	if not opts.is_empty():
		opts[0].focus_neighbor_left = opts[0].get_path_to(opts[0])
		opts[-1].focus_neighbor_right = opts[-1].get_path_to(opts[-1])
	tab_buttons[0].focus_neighbor_left = tab_buttons[0].get_path_to(tab_buttons[0])
	tab_buttons[-1].focus_neighbor_right = tab_buttons[-1].get_path_to(tab_buttons[-1])
	var n := asset_buttons.size()
	for i in n:
		var b: Button = asset_buttons[i]
		b.focus_neighbor_left = b.get_path_to(asset_buttons[i - 1] if i % cols > 0 else b)
		b.focus_neighbor_right = b.get_path_to(asset_buttons[i + 1] if i % cols < cols - 1 and i + 1 < n else b)
		b.focus_neighbor_top = b.get_path_to(asset_buttons[i - cols] if i >= cols else first_row)
		b.focus_neighbor_bottom = b.get_path_to(asset_buttons[mini(i + cols, n - 1)] if i + cols < n or (i / cols) < (n - 1) / cols else b)
		b.focus_next = b.get_path_to(asset_buttons[(i + 1) % n])
		b.focus_previous = b.get_path_to(asset_buttons[(i - 1 + n) % n])


func _input(event: InputEvent) -> void:
	if not _open:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
	elif (event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_LEFT_SHOULDER) \
			or (event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_Q):
		cycle_kind(-1)
		get_viewport().set_input_as_handled()
	elif (event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_RIGHT_SHOULDER) \
			or (event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_E):
		cycle_kind(1)
		get_viewport().set_input_as_handled()


static func hints() -> Array:
	return [["A", "Use"], ["LR", "Cover, hero, logo, icon"], ["B", "Close"]]
