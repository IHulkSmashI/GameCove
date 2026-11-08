extends Control
## The shell: art backdrop, top bar (tabs + status pill), the four screens
## (Home, Library, Discover, Settings), the game page, the hint bar, toasts,
## the launch splash and the quick menu overlay (Guide button or F1). Routes
## input and keeps the hint bar true to whatever has focus. Screens never call
## services themselves except through what's passed in here, so they can be
## tested with fakes.

const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Home := preload("res://scripts/ui/home.gd")
const LibraryScreen := preload("res://scripts/ui/library_screen.gd")
const DiscoverScreen := preload("res://scripts/ui/discover_screen.gd")
const SettingsScreen := preload("res://scripts/ui/settings_screen.gd")
const GamePage := preload("res://scripts/ui/game_page.gd")
const QuickMenu := preload("res://scripts/ui/quick_menu.gd")
const View := preload("res://scripts/ui/library_view.gd")
const Backdrop := preload("res://scripts/ui/backdrop.gd")
const TopBar := preload("res://scripts/ui/top_bar.gd")
const Toasts := preload("res://scripts/ui/toast.gd")
const LaunchOverlay := preload("res://scripts/ui/launch_overlay.gd")
const StatusPanel := preload("res://scripts/ui/status_panel.gd")
const Sounds := preload("res://scripts/ui/sounds.gd")
const Kit := preload("res://scripts/ui/ui_kit.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const UiPrefs := preload("res://scripts/ui/ui_prefs.gd")
const GameSession := preload("res://scripts/launch/game_session.gd")

const LIVE_REFRESH_S := 5.0
## Wall clock running this far ahead of the monotonic clock means we were asleep.
const RESUME_GAP_S := 20.0
## No input for this long: the backdrop's slow zoom stops.
const IDLE_S := 30.0
const SCREENS := ["home", "library", "discover", "settings"]

var home: Control
var library_screen: Control
var discover: Control
var settings: Control
var page: Control
var quick_menu: Control
var backdrop: Control
var top_bar: HBoxContainer
var hint_bar: HBoxContainer
var toasts: VBoxContainer
var launch_overlay: Control
var status_panel: PanelContainer
var sounds: Node
var screens := {}
var current := "home"
## Focus, frame limit and Auto TDP for the running game.
var session: Node
## The game launched from here most recently: what "This game" edits.
var playing: Dictionary = {}
## Extra UI prefs not in UiPrefs' core set.
var menu_side := "right"
var ui_sounds := "low"
var _live_timer: Timer
var _window_focused := true
var _focus_before_menu: Control
var _clock_mark := [0.0, 0]   # [unix seconds, ticks msec] at the last resume check
var _screen_layer: Control
var _hint_shade: TextureRect
var _last_input_ms := 0
var _battery_warned := false
var _seen_new := {}


func _ready() -> void:
	UiPrefs.load_prefs()
	_load_extra_prefs()
	ThemeLib.use(UiPrefs.theme, device_accent())
	theme = ThemeLib.build()

	backdrop = Backdrop.new()
	add_child(backdrop)
	backdrop.accent_changed.connect(_on_accent)

	_screen_layer = Control.new()
	_screen_layer.name = "Screens"
	_screen_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_screen_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_screen_layer)

	home = Home.new()
	home.play_requested.connect(_play)
	home.open_requested.connect(_open_page)
	home.refresh_requested.connect(func(): Library.refresh())
	home.game_focused.connect(_follow.bind("home"))
	_screen_layer.add_child(home)

	library_screen = LibraryScreen.new()
	library_screen.open_requested.connect(_open_page)
	library_screen.game_focused.connect(_follow.bind("library"))
	library_screen.visible = false
	_screen_layer.add_child(library_screen)

	discover = DiscoverScreen.new()
	discover.visible = false
	discover.open_requested.connect(_open_page)
	discover.game_focused.connect(_follow.bind("discover"))
	_screen_layer.add_child(discover)
	discover.setup({"library": Library, "open_game": _open_page, "toast": toast})

	settings = SettingsScreen.new()
	settings.visible = false
	settings.changed.connect(_on_setting_changed)
	_screen_layer.add_child(settings)
	screens = {"home": home, "library": library_screen, "discover": discover, "settings": settings}

	_hint_shade = TextureRect.new()
	_hint_shade.name = "HintShade"
	_hint_shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint_shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_hint_shade.stretch_mode = TextureRect.STRETCH_SCALE
	_hint_shade.anchor_top = 1.0
	_hint_shade.anchor_right = 1.0
	_hint_shade.anchor_bottom = 1.0
	_hint_shade.offset_top = -64
	add_child(_hint_shade)
	hint_bar = Kit.hbox(22)
	hint_bar.name = "HintBar"
	hint_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint_bar.anchor_top = 1.0
	hint_bar.anchor_right = 1.0
	hint_bar.anchor_bottom = 1.0
	hint_bar.offset_left = 48
	hint_bar.offset_right = -48
	hint_bar.offset_top = -48
	hint_bar.offset_bottom = -14
	add_child(hint_bar)

	top_bar = TopBar.new()
	top_bar.anchor_right = 1.0
	top_bar.offset_left = 40
	top_bar.offset_right = -32
	top_bar.offset_top = 16
	top_bar.offset_bottom = 64
	top_bar.tab_pressed.connect(func(id): show_screen(id))
	top_bar.status_pressed.connect(_open_status)
	add_child(top_bar)

	toasts = Toasts.new()
	add_child(toasts)
	toasts.shown.connect(func(_t): _sound("toast"))

	status_panel = StatusPanel.new()
	status_panel.setup({})
	status_panel.closed.connect(func(): top_bar.status_button.grab_focus())
	add_child(status_panel)

	launch_overlay = LaunchOverlay.new()
	launch_overlay.cancel_requested.connect(_on_launch_cancelled)
	add_child(launch_overlay)

	quick_menu = QuickMenu.new()
	quick_menu.setup({"device": Device, "power": Power, "launcher": Launcher, "gamescope": Gamescope})
	quick_menu.set_side(menu_side)
	quick_menu.closed.connect(_on_menu_closed)
	if quick_menu.has_signal("notice"):
		quick_menu.notice.connect(func(text, tone): toast(text, "check" if tone == "good" else "info", tone))
	add_child(quick_menu)

	sounds = Sounds.new()
	sounds.set_level(ui_sounds)
	add_child(sounds)

	session = GameSession.new()
	session.name = "GameSession"
	session.setup(Gamescope, Power, Launcher)
	session.ended.connect(_on_game_ended)
	if session.has_signal("started"):
		session.started.connect(func(_g): launch_overlay.finish())
	add_child(session)

	Library.changed.connect(_on_library_changed)
	_set_games(Library.games)
	_clock_mark = [Time.get_unix_time_from_system(), Time.get_ticks_msec()]
	_build_settings()
	_style_hint_shade()

	_live_timer = Timer.new()
	_live_timer.wait_time = LIVE_REFRESH_S
	_live_timer.timeout.connect(_on_live_tick)
	add_child(_live_timer)
	get_viewport().gui_focus_changed.connect(_on_focus_changed)
	_refresh_live()
	_update_timer()
	_link_top()
	_last_input_ms = Time.get_ticks_msec()
	home.focus_later(home.default_focus())


func _on_accent(c: Color) -> void:
	home.set_accent(c)
	if page != null:
		page.set_accent(c)


## The backdrop follows focus on the screen that's showing.
func _follow(g: Dictionary, screen: String) -> void:
	if current == screen and page == null:
		backdrop.show_game(g)


## devices.json may carry an optional "accent": "#RRGGBB" for this handheld.
func device_accent() -> Color:
	var p: Variant = Device.profile if "profile" in Device else {}
	var a: Variant = p.get("accent", "") if p is Dictionary else ""
	if a is String and a != "" and Color.html_is_valid(a):
		return Color.html(a)
	return Color(0, 0, 0, 0)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_window_focused = false
		if launch_overlay != null:
			launch_overlay.finish()
		if backdrop != null:
			_pause_motion()
		_update_timer()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_window_focused = true
		_check_resume()
		_refresh_live()
		_update_timer()
	elif what == NOTIFICATION_WM_CLOSE_REQUEST and session != null:
		session.stop()


## Slow drifts (hero, backdrop) stop when idle, in a game or under Reduce motion.
func _pause_motion() -> void:
	backdrop.pause_motion()
	home.hero_stage.pause_motion()


func _resume_motion() -> void:
	backdrop.resume_motion()
	home.hero_stage.resume_motion()


## Static caches hold textures and fonts; let them go so nothing leaks at exit.
func _exit_tree() -> void:
	release_caches()


static func release_caches() -> void:
	load("res://scripts/ui/icons.gd")._cache.clear()
	load("res://scripts/ui/art_cache.gd").clear()
	ThemeLib._fonts.clear()
	ThemeLib._knobs.clear()


func _on_live_tick() -> void:
	_check_resume()
	_refresh_live()
	if Time.get_ticks_msec() - _last_input_ms > IDLE_S * 1000.0:
		_pause_motion()


## Godot has no suspend/resume notification on Linux (NOTIFICATION_APPLICATION_RESUMED
## is Android/iOS only), so we compare clocks: the monotonic clock stops while the
## device sleeps, the wall clock doesn't. After a sleep, read power values again
## (firmware may have reset the TDP or charge limit). Runs only on ticks we
## already have and when our window comes back; never polls on its own.
func _check_resume() -> void:
	var now := [Time.get_unix_time_from_system(), Time.get_ticks_msec()]
	if resumed_between(_clock_mark, now, RESUME_GAP_S):
		_power_refresh()
	_clock_mark = now


static func resumed_between(before: Array, after: Array, gap_s: float) -> bool:
	if before[1] == 0:
		return false
	var wall: float = after[0] - before[0]
	var mono: float = (after[1] - before[1]) / 1000.0
	return wall - mono > gap_s


## Power.refresh() reads over busctl, so it runs on Power's worker.
func _power_refresh() -> void:
	if Power.has_method("request_refresh"):
		Power.request_refresh()
	else:
		Power.refresh()


## Live numbers only tick while someone can see them: our window has focus or
## the quick menu is showing over a game. Nothing runs per frame.
func _update_timer() -> void:
	if _live_timer == null:
		return
	var want := _window_focused or quick_menu.visible
	if want and _live_timer.is_stopped():
		_live_timer.start()
	elif not want:
		_live_timer.stop()


func _refresh_live() -> void:
	var b: Dictionary = Device.battery()
	top_bar.set_status(Device.display_name(), b, clock_text(Time.get_time_dict_from_system()))
	status_panel.set_battery(Device.display_name(), b)
	if TopBar.is_low(b):
		if not _battery_warned:
			_battery_warned = true
			toast("Battery low: %d%%" % int(b["percent"]), "alert", "bad", "Plug in soon, or pick Longest battery in the quick menu.")
	else:
		_battery_warned = false
	if quick_menu.visible:
		quick_menu.refresh_live()


static func clock_text(t: Dictionary) -> String:
	var h: int = t["hour"]
	return "%d:%02d %s" % [12 if h % 12 == 0 else h % 12, t["minute"], "PM" if h >= 12 else "AM"]


## A toast in the top-right corner. Never takes focus.
func toast(text: String, icon := "info", tone := "", detail := "") -> void:
	toasts.show_toast(text, icon, tone, detail)


func _sound(kind: String) -> void:
	if sounds != null:
		sounds.play(kind)


# ------------------------------------------------------------ input

func _input(event: InputEvent) -> void:
	if event is InputEventJoypadButton or event is InputEventKey or event is InputEventJoypadMotion:
		if event.is_pressed():
			if Time.get_ticks_msec() - _last_input_ms > IDLE_S * 1000.0:
				_resume_motion()
			_last_input_ms = Time.get_ticks_msec()


func _unhandled_input(event: InputEvent) -> void:
	var guide: bool = (event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_GUIDE) \
		or (event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F1)
	if guide:
		if quick_menu.visible:
			quick_menu.close()
		else:
			_open_menu()
		get_viewport().set_input_as_handled()
		return
	if quick_menu.visible or launch_overlay.visible:
		return
	if event.is_action_pressed("ui_accept"):
		_sound("select")
	if status_panel.visible:
		if event.is_action_pressed("ui_cancel"):
			status_panel.close()
			_sound("back")
			get_viewport().set_input_as_handled()
		return
	if page != null:
		if event.is_action_pressed("ui_cancel"):
			_sound("back")
			_close_page()
			get_viewport().set_input_as_handled()
	elif _shoulder(event, JOY_BUTTON_LEFT_SHOULDER, KEY_Q):
		cycle_screen(-1)
		get_viewport().set_input_as_handled()
	elif _shoulder(event, JOY_BUTTON_RIGHT_SHOULDER, KEY_E):
		cycle_screen(1)
		get_viewport().set_input_as_handled()
	elif current == "library" and _trigger(event) != 0:
		library_screen.jump_letter(_trigger(event))
		get_viewport().set_input_as_handled()
	elif current == "library" and _pressed(event, JOY_BUTTON_Y, KEY_SLASH):
		library_screen.open_search()
		get_viewport().set_input_as_handled()
	elif current == "library" and _pressed(event, JOY_BUTTON_X, KEY_S):
		library_screen.cycle_sort(1)
		toast("Sorted by %s" % View.SORT_NAMES[library_screen.sort].to_lower(), "sort", "")
		get_viewport().set_input_as_handled()
	elif current != "home" and event.is_action_pressed("ui_cancel"):
		_sound("back")
		show_screen("home")
		get_viewport().set_input_as_handled()
	# Focus never gets lost: any direction with nothing focused lands somewhere.
	if get_viewport().gui_get_focus_owner() == null:
		for a in ["ui_up", "ui_down", "ui_left", "ui_right", "ui_accept"]:
			if event.is_action_pressed(a):
				var f := _screen_default_focus()
				if f != null:
					f.grab_focus()
				get_viewport().set_input_as_handled()
				return


static func _shoulder(event: InputEvent, button: JoyButton, key: Key) -> bool:
	return QuickMenu._is_shoulder(event, button, key)


var _trigger_held := {}

## -1 for LT (or Page Up), +1 for RT (or Page Down), on the press only.
func _trigger(event: InputEvent) -> int:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_PAGEUP:
			return -1
		if event.keycode == KEY_PAGEDOWN:
			return 1
	if event is InputEventJoypadMotion and event.axis in [JOY_AXIS_TRIGGER_LEFT, JOY_AXIS_TRIGGER_RIGHT]:
		var down: bool = event.axis_value > 0.6
		var was: bool = _trigger_held.get(event.axis, false)
		_trigger_held[event.axis] = down if (down or event.axis_value < 0.3) else was
		if down and not was:
			return -1 if event.axis == JOY_AXIS_TRIGGER_LEFT else 1
	return 0


static func _pressed(event: InputEvent, button: JoyButton, key: Key) -> bool:
	return QuickMenu._is_shoulder(event, button, key)


func _screen() -> Control:
	return page if page != null else screens[current]


func _screen_default_focus() -> Control:
	var f: Control = _screen().default_focus()
	return f if f != null else top_bar.tabs[current]


# ------------------------------------------------------------ screens

func cycle_screen(d: int) -> void:
	show_screen(SCREENS[posmod(SCREENS.find(current) + d, SCREENS.size())])


## Switch tabs: the old screen fades out, the new one slides in from the side
## it sits on in the tab row.
func show_screen(id: String) -> void:
	if not screens.has(id):
		return
	var old: Control = screens[current]
	var dir := signf(SCREENS.find(id) - SCREENS.find(current))
	current = id
	top_bar.select(id)
	var new: Control = screens[id]
	if old != new:
		Motion.fade(old, false, Motion.FAST)
		new.visible = true
		new.modulate.a = 0.0
		new.position.x = Motion.slide(28.0) * dir
		Motion.to(new, "modulate:a", 1.0, Motion.BASE)
		Motion.to(new, "position:x", 0.0, Motion.BASE)
		_sound("move")
	if id == "library":
		_mark_new_seen()
	_link_top()
	var f := _screen_default_focus()
	if is_inside_tree() and f != null:
		Home.focus_later(f)
	if id == "home":
		backdrop.show_game(home.spotlight_game)


func _link_top() -> void:
	var tab: Control = top_bar.tabs[current]
	for s in screens.values():
		if s.has_method("set_top_target"):
			s.set_top_target(tab)
	var f: Control = _screen().default_focus() if page == null else null
	for t in top_bar.tab_buttons():
		t.focus_neighbor_bottom = t.get_path_to(f if f != null else t)
		t.focus_neighbor_top = t.get_path_to(t)
	top_bar.link_bar()
	top_bar.status_button.focus_neighbor_bottom = top_bar.status_button.get_path_to(f if f != null else top_bar.tabs[current])
	top_bar.status_button.focus_neighbor_top = top_bar.status_button.get_path_to(top_bar.status_button)


func _play(game: Dictionary) -> void:
	playing = game
	launch_overlay.show_for(game, backdrop.current_accent())
	_pause_motion()
	session.begin(game, Library.launch(game))


func _on_launch_cancelled(_game: Dictionary) -> void:
	_sound("back")
	if session.is_active():
		session.stop()


func _on_game_ended(game: Dictionary) -> void:
	if not playing.is_empty() and playing.get("key", "") == game.get("key", ""):
		playing = {}
	launch_overlay.finish()
	_check_resume()
	_return_home()


## Coming back from a game: the screens settle in from slightly smaller.
func _return_home() -> void:
	_resume_motion()
	_screen_layer.pivot_offset = size / 2.0
	_screen_layer.scale = Vector2.ONE * (1.0 if Motion.reduce else 0.97)
	_screen_layer.modulate.a = 0.0
	Motion.to(_screen_layer, "scale", Vector2.ONE, Motion.SLOW)
	Motion.to(_screen_layer, "modulate:a", 1.0, Motion.SLOW)


func _open_page(game: Dictionary) -> void:
	if page != null:
		_close_page()
	page = GamePage.new()
	page.setup(game, Launcher)
	page.play_requested.connect(_play)
	page.back_requested.connect(_close_page)
	add_child(page)
	move_child(page, _hint_shade.get_index())
	page.modulate.a = 0.0
	Motion.to(page, "modulate:a", 1.0, Motion.BASE)
	screens[current].visible = false
	top_bar.visible = false
	backdrop.show_game(game)
	page.set_accent(backdrop.current_accent())
	page.focus_first()
	_sound("select")


func _close_page() -> void:
	if page == null:
		return
	var key: String = page.game.get("key", "")
	page.queue_free()
	page = null
	top_bar.visible = true
	var s: Control = screens[current]
	s.visible = true
	s.modulate.a = 0.0
	Motion.to(s, "modulate:a", 1.0, Motion.FAST)
	# Land back on the tile that opened the page, else the default.
	var target: Control = null
	if current == "home":
		target = home.tile_for(key)
	elif current == "library":
		for t in library_screen.tiles():
			if t.game.get("key", "") == key:
				target = t
				break
	if target == null:
		target = _screen_default_focus()
	if target != null:
		target.grab_focus()


func _open_menu() -> void:
	_focus_before_menu = get_viewport().gui_get_focus_owner()
	_screen().focus_behavior_recursive = Control.FOCUS_BEHAVIOR_DISABLED
	top_bar.focus_behavior_recursive = Control.FOCUS_BEHAVIOR_DISABLED
	var g := playing
	if g.is_empty() and page != null:
		g = page.game
	if g.is_empty():
		g = home.spotlight_game if not home.spotlight_game.is_empty() else home.hero_game
	quick_menu.open(g)
	_sound("select")
	_update_timer()


func _on_menu_closed() -> void:
	_screen().focus_behavior_recursive = Control.FOCUS_BEHAVIOR_INHERITED
	top_bar.focus_behavior_recursive = Control.FOCUS_BEHAVIOR_INHERITED
	_update_timer()
	_sound("back")
	if page != null:
		page.form.reload()
	if _focus_before_menu != null and is_instance_valid(_focus_before_menu) and _focus_before_menu.is_visible_in_tree():
		_focus_before_menu.grab_focus()
	else:
		var f := _screen_default_focus()
		if f != null:
			f.grab_focus()


func _open_status() -> void:
	status_panel.set_battery(top_bar.device_name, top_bar.battery)
	status_panel.open()
	var f: Control = status_panel.first_focus()
	if f != null:
		f.grab_focus()


func _set_games(list: Array) -> void:
	home.set_games(list)
	library_screen.set_games(list)
	var fresh := View.newly_added(list, int(Time.get_unix_time_from_system()))
	top_bar.set_dot("library", fresh.any(func(g): return not _seen_new.has(g.get("key", ""))))


func _mark_new_seen() -> void:
	for g in View.newly_added(library_screen.games, int(Time.get_unix_time_from_system())):
		_seen_new[g.get("key", "")] = true
	top_bar.set_dot("library", false)


func _on_library_changed() -> void:
	_set_games(Library.games)
	if not playing.is_empty():
		var fresh := View.find_by_key(Library.games, playing["key"])
		playing = fresh
	if page != null and View.find_by_key(Library.games, page.game["key"]).is_empty():
		_close_page()
	_link_top()


# ------------------------------------------------------------ hint bar

func _on_focus_changed(f: Control) -> void:
	_update_hints(f)
	_sound("move")


func _update_hints(f: Control = null) -> void:
	if f == null:
		f = get_viewport().gui_get_focus_owner()
	var ctx := {"screen": current, "page": page != null, "kind": focus_kind(f), "label": f.text if f is Button else ""}
	for c in hint_bar.get_children():
		hint_bar.remove_child(c)
		c.queue_free()
	hint_bar.add_child(Kit.prompts(hints_for(ctx)))


## What kind of control has focus, for the hint bar.
func focus_kind(f: Control) -> String:
	if f == null:
		return ""
	if f is Button and f.theme_type_variation == "TileButton":
		return "tile"
	if f is HSlider:
		return "slider"
	if f is Button and f.theme_type_variation == "RowButton":
		return "row"
	if f is Button and (f.theme_type_variation == "TabButton") and top_bar.is_ancestor_of(f):
		return "status" if f == top_bar.status_button else "tab"
	if f is Button and f.name == "Play":
		return "play"
	return "button"


## The hints for a context {"screen", "page": bool, "kind", "label"}:
## [[button(s), text], ...], primary action first.
static func hints_for(ctx: Dictionary) -> Array:
	var kind: String = ctx.get("kind", "")
	var out: Array = []
	match kind:
		"tile": out.append(["A", "Open"])
		"play": out.append(["A", ctx.get("label", "Play")])
		"row": out.append(["LR", "Change"])
		"slider": out.append(["LR", "Adjust"])
		"tab": out.append(["A", "Open"])
		"status": out.append(["A", "Status"])
		"": pass
		_: out.append(["A", "Select"])
	if ctx.get("page", false):
		out.append(["B", "Back"])
	else:
		var screen: String = ctx.get("screen", "home")
		if screen == "library":
			out.append(["Y", "Search"])
			out.append(["X", "Sort"])
			out.append([["LT", "RT"], "Jump"])
		if screen != "home":
			out.append(["B", "Home"])
		out.append([["LB", "RB"], "Sections"])
	out.append(["GUIDE", "Quick menu"])
	return out


func _style_hint_shade() -> void:
	var g := Gradient.new()
	var sc: Color = ThemeLib.color("scrim")
	g.colors = PackedColorArray([Color(sc, 0.0), Color(sc, 0.7)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 4
	t.height = 64
	t.fill_to = Vector2(0, 1)
	_hint_shade.texture = t


# ------------------------------------------------------------ settings

func _load_extra_prefs() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(UiPrefs.path) == OK:
		menu_side = str(cfg.get_value("ui", "menu_side", "right"))
		ui_sounds = str(cfg.get_value("ui", "ui_sounds", "low"))


func _save_prefs() -> void:
	UiPrefs.save_prefs()
	var cfg := ConfigFile.new()
	cfg.load(UiPrefs.path)
	cfg.set_value("ui", "menu_side", menu_side)
	cfg.set_value("ui", "ui_sounds", ui_sounds)
	cfg.save(UiPrefs.path)


func _settings_values() -> Dictionary:
	var v := UiPrefs.values()
	v["menu_side"] = menu_side
	v["ui_sounds"] = ui_sounds
	return v


func _build_settings() -> void:
	var p: Dictionary = Device.profile if "profile" in Device else {}
	settings.setup(_settings_values(), [
		["Device", Device.display_name()],
		["Chip", p.get("chip", "Unknown")],
		["Support", Device.support_level().capitalize()],
		["GameCove", _version()],
	])
	settings.set_top_target(top_bar.tabs["settings"])


static func _version() -> String:
	var v := str(ProjectSettings.get_setting("application/config/version", ""))
	return v if v != "" else "Development build"


func _on_setting_changed(key: String, value: Variant) -> void:
	match key:
		"theme", "match_art":
			var v := UiPrefs.values()
			v[key] = value
			UiPrefs.set_values(v)
			apply_theme()
		"reduce_motion":
			Motion.reduce = bool(value)
			if Motion.reduce:
				_pause_motion()
			else:
				_resume_motion()
		"menu_side":
			menu_side = str(value)
			quick_menu.set_side(menu_side)
		"ui_sounds":
			ui_sounds = str(value)
			sounds.set_level(ui_sounds)
			_sound("select")
	_save_prefs()


## Apply the current theme everywhere, live. Screens rebuild their tiles so
## every baked colour follows; focus returns to the same setting.
func apply_theme() -> void:
	ThemeLib.use(UiPrefs.theme, device_accent())
	theme = ThemeLib.build()
	_style_hint_shade()
	_set_games(home.games)
	var keep := ""
	var f := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	if f != null and settings.is_ancestor_of(f):
		keep = String(f.get_parent().name)
	_build_settings()
	if keep != "" and settings.rows.has(keep):
		Home.focus_later(settings.rows[keep].button)
	_on_accent(backdrop.current_accent())
	_update_hints()
