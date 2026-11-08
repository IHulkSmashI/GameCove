extends Control
## Puts the screens together and routes input: home, game page and the quick
## menu overlay (Guide button or F1). Screens never call services themselves
## except through what's passed in here, so they can be tested with fakes.

const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Home := preload("res://scripts/ui/home.gd")
const GamePage := preload("res://scripts/ui/game_page.gd")
const QuickMenu := preload("res://scripts/ui/quick_menu.gd")
const View := preload("res://scripts/ui/library_view.gd")
const GameSession := preload("res://scripts/launch/game_session.gd")

const LIVE_REFRESH_S := 5.0
## Wall clock running this far ahead of the monotonic clock means we were asleep.
const RESUME_GAP_S := 20.0

var home: Control
var page: Control
var quick_menu: Control
## Focus, frame limit and Auto TDP for the running game.
var session: Node
## The game launched from here most recently: what "This game" edits.
var playing: Dictionary = {}
var _live_timer: Timer
var _window_focused := true
var _focus_before_menu: Control
var _clock_mark := [0.0, 0]   # [unix seconds, ticks msec] at the last resume check


func _ready() -> void:
	theme = ThemeLib.build()
	var bg := ColorRect.new()
	bg.color = ThemeLib.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	home = Home.new()
	home.play_requested.connect(_play)
	home.open_requested.connect(_open_page)
	home.refresh_requested.connect(func(): Library.refresh())
	add_child(home)

	quick_menu = QuickMenu.new()
	quick_menu.setup({"device": Device, "power": Power, "launcher": Launcher, "gamescope": Gamescope})
	quick_menu.closed.connect(_on_menu_closed)
	add_child(quick_menu)

	session = GameSession.new()
	session.name = "GameSession"
	session.setup(Gamescope, Power, Launcher)
	session.ended.connect(_on_game_ended)
	add_child(session)

	Library.changed.connect(_on_library_changed)
	home.set_games(Library.games)
	_clock_mark = [Time.get_unix_time_from_system(), Time.get_ticks_msec()]

	_live_timer = Timer.new()
	_live_timer.wait_time = LIVE_REFRESH_S
	_live_timer.timeout.connect(_on_live_tick)
	add_child(_live_timer)
	_refresh_live()
	_update_timer()
	home.focus_later(home.default_focus())


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_window_focused = false
		_update_timer()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_window_focused = true
		_check_resume()
		_refresh_live()
		_update_timer()
	elif what == NOTIFICATION_WM_CLOSE_REQUEST and session != null:
		session.stop()


func _on_live_tick() -> void:
	_check_resume()
	_refresh_live()


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


## Power.refresh() reads over busctl on the caller's thread; run it on Power's worker.
func _power_refresh() -> void:
	if Power.has_method("_queue"):
		Power._queue("refresh", func(): Power.refresh(); return true)
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
	home.set_status(Device.display_name(), Device.battery(), clock_text(Time.get_time_dict_from_system()))
	if quick_menu.visible:
		quick_menu.refresh_live()


static func clock_text(t: Dictionary) -> String:
	var h: int = t["hour"]
	return "%d:%02d %s" % [12 if h % 12 == 0 else h % 12, t["minute"], "PM" if h >= 12 else "AM"]


# ------------------------------------------------------------ input

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
	if quick_menu.visible:
		return
	if page != null:
		if event.is_action_pressed("ui_cancel"):
			_close_page()
			get_viewport().set_input_as_handled()
	elif _shoulder(event, JOY_BUTTON_LEFT_SHOULDER, KEY_Q):
		home.cycle_store(-1)
		get_viewport().set_input_as_handled()
	elif _shoulder(event, JOY_BUTTON_RIGHT_SHOULDER, KEY_E):
		home.cycle_store(1)
		get_viewport().set_input_as_handled()
	# Focus never gets lost: any direction with nothing focused lands somewhere.
	if get_viewport().gui_get_focus_owner() == null:
		for a in ["ui_up", "ui_down", "ui_left", "ui_right", "ui_accept"]:
			if event.is_action_pressed(a):
				_screen_default_focus().grab_focus()
				get_viewport().set_input_as_handled()
				return


static func _shoulder(event: InputEvent, button: JoyButton, key: Key) -> bool:
	return QuickMenu._is_shoulder(event, button, key)


func _screen() -> Control:
	return page if page != null else home


func _screen_default_focus() -> Control:
	return _screen().default_focus()


# ------------------------------------------------------------ screens

func _play(game: Dictionary) -> void:
	playing = game
	session.begin(game, Library.launch(game))


func _on_game_ended(game: Dictionary) -> void:
	if not playing.is_empty() and playing.get("key", "") == game.get("key", ""):
		playing = {}
	_check_resume()


func _open_page(game: Dictionary) -> void:
	if page != null:
		_close_page()
	page = GamePage.new()
	page.setup(game, Launcher)
	page.play_requested.connect(_play)
	page.back_requested.connect(_close_page)
	add_child(page)
	move_child(page, quick_menu.get_index())
	home.visible = false
	page.focus_first()


func _close_page() -> void:
	if page == null:
		return
	var key: String = page.game.get("key", "")
	page.queue_free()
	page = null
	home.visible = true
	# Land back on the tile that opened the page, else the default.
	var target: Control = home.default_focus()
	for row in Home.ROWS:
		for t in home.tiles(row[0]):
			if t.game["key"] == key:
				target = t
				break
		if target != home.default_focus():
			break
	target.grab_focus()


func _open_menu() -> void:
	_focus_before_menu = get_viewport().gui_get_focus_owner()
	_screen().focus_behavior_recursive = Control.FOCUS_BEHAVIOR_DISABLED
	var g := playing
	if g.is_empty() and page != null:
		g = page.game
	if g.is_empty():
		g = home.hero_game
	quick_menu.open(g)
	_update_timer()


func _on_menu_closed() -> void:
	_screen().focus_behavior_recursive = Control.FOCUS_BEHAVIOR_INHERITED
	_update_timer()
	if page != null:
		page.form.reload()
	if _focus_before_menu != null and is_instance_valid(_focus_before_menu) and _focus_before_menu.is_visible_in_tree():
		_focus_before_menu.grab_focus()
	else:
		_screen_default_focus().grab_focus()


func _on_library_changed() -> void:
	home.set_games(Library.games)
	if not playing.is_empty():
		var fresh := View.find_by_key(Library.games, playing["key"])
		playing = fresh
	if page != null and View.find_by_key(Library.games, page.game["key"]).is_empty():
		_close_page()
