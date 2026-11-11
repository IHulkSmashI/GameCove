extends Control
## The shell: art backdrop, top bar (tabs + status pill), the four screens
## (Home, Library, Discover, Settings), the game page, the hint bar, toasts,
## the launch splash and the quick menu overlay (Guide button or F1), the
## downloads list, game action sheets and the "Steam needs you" overlay. Routes
## input and keeps the hint bar true to whatever has focus. Screens never call
## services themselves except through what's passed in here, so they can be
## tested with fakes.

const SettingsFile := preload("res://scripts/system/settings_file.gd")
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
const TG := preload("res://scripts/ui/texts_games.gd")
const InstallState := preload("res://scripts/ui/games/install_state.gd")
const GameActions := preload("res://scripts/ui/games/game_actions.gd")
const CollectionActions := preload("res://scripts/ui/games/collection_actions.gd")
const EmulationPage := preload("res://scripts/ui/emulation_page.gd")
const DownloadsView := preload("res://scripts/ui/games/downloads_view.gd")
const DownloadsButton := preload("res://scripts/ui/games/downloads_button.gd")
const SteamOverlay := preload("res://scripts/ui/games/steam_overlay.gd")
const TileProgress := preload("res://scripts/ui/games/tile_progress.gd")
const SessionWiring := preload("res://scripts/ui/games/session_wiring.gd")
const GameIcons := preload("res://scripts/ui/games/game_icons.gd")
const GameCloser := preload("res://scripts/ui/games/game_closer.gd")
const SessionHealth := preload("res://scripts/system/session_health.gd")
const BackgroundMode := preload("res://scripts/system/background_mode.gd")
## First-run setup (s-settings); loaded at runtime only when it exists.
const SETUP_FLOW := "res://scripts/ui/setup/setup_flow.gd"
const Glyph := preload("res://scripts/ui/glyph.gd")
const FixesService := preload("res://scripts/device/fixes.gd")
const CommandRunner := preload("res://scripts/device/command_runner.gd")
const ControllerProvider := preload("res://scripts/controls/providers/controller.gd")
const PerfProvider := preload("res://scripts/controls/providers/perf.gd")
const StreamingScreen := preload("res://scripts/ui/streaming/streaming_screen.gd")
const StreamingService := preload("res://scripts/streaming/streaming.gd")
const SavesService := preload("res://scripts/system/saves_service.gd")
const BatteryLog := preload("res://scripts/system/battery_log.gd")
const LowBattery := preload("res://scripts/system/low_battery.gd")
const LowBatteryDialog := preload("res://scripts/ui/low_battery_dialog.gd")
const TSaves := preload("res://scripts/ui/texts_saves.gd")
const SavesCardScript := preload("res://scripts/ui/games/saves_card.gd")
const ProtonGE := preload("res://scripts/launch/proton_ge.gd")
const CardJobs := preload("res://scripts/system/card_jobs.gd")
const Recording := preload("res://scripts/system/recording.gd")
const UPower := preload("res://scripts/system/upower.gd")
const Proc := preload("res://scripts/system/proc.gd")
const AppsView := preload("res://scripts/ui/apps_view.gd")
const Apps := preload("res://scripts/library/apps.gd")
const TX := preload("res://scripts/ui/texts_extras.gd")

const LIVE_REFRESH_S := 5.0
## Wall clock running this far ahead of the monotonic clock means we were asleep.
const RESUME_GAP_S := 20.0
## No input for this long: the backdrop's slow zoom stops.
const IDLE_S := 30.0
const SCREENS := ["home", "library", "discover", "stream", "settings"]

var home: Control
var library_screen: Control
var discover: Control
## The Stream tab and its service (scripts/streaming/): games from a PC through Moonlight.
var stream_screen: Control
var streaming: Node
var settings: Control
var page: Control
var quick_menu: Control
var backdrop: Control
var top_bar: HBoxContainer
var hint_bar: HBoxContainer
## The bottom band: status text on the left, hint_bar's prompts on the right.
var hint_band: PanelContainer
var hint_status: Label
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
## Device fixes service (scripts/device/fixes.gd): quiet fix while a game runs,
## "what changed" at start. The Fixes page uses this instance.
var fixes: Node
var _resume_reapply_pending := false
var _screen_layer: Control
var _hint_shade: TextureRect
var _last_input_ms := 0
var _battery_warned := false
## Epic and GOG cloud saves around a game (saves_service.gd).
var saves: Node
## Battery history and per-game drain (battery_log.gd).
var battery_log: Node
## Sleep at low battery (low_battery.gd) and its warning while it shows.
var low_battery: Node
var low_dialog: Control
## Key of the game waiting for its cloud save before it starts ("" when none).
var _launch_wait := ""
## Key of the game whose save conflict sheet is open before its launch ("" when none).
var _conflict_for := ""
var _seen_new := {}
## Install state and live progress for every game (Library store signals).
var install_state: Node
## Install / uninstall / move / launch options... flows with sheets.
var game_actions: Node
## Favourites, hidden games and collections flows (Menu on a tile, the Library's filter sheet).
var collection_actions: Node
## When the running game started (unix), for play time GameCove keeps itself.
var _game_started_at := 0
var downloads_view: Control
var downloads_button: Button
var steam_overlay: Control
var wiring: RefCounted
## Library's store API and the Achievements service, swappable for previews.
var store_api: Object
var achievements_api: Object
## Sheets, the text keyboard and the Steam overlay: above screens and top bar,
## under the hint bar.
var _modal_layer: Control
var closer: Node
var setup_flow: Node
## Main-loop pacing: near idle while a game (or any other window) is in front.
var background: Node
## Record / Stop recording (quick menu) and the REC chip.
var recording: Node
## Desktop apps (Home's Apps shelf "All apps", the Library header's Apps).
var apps_view: Control
## Controller batteries: the last UPower read (ticks msec) and whether one is out.
var _pads_at := -1000000
var _pads_busy := false   # a UPower read is out (card_jobs.gd)


## Play the boot splash at start (screenshots and tests turn it off).
static var boot_splash := true
## The boot intro while it plays (it frees itself).
var _boot_intro: Control


func _ready() -> void:
	background = BackgroundMode.new()
	add_child(background)
	get_window().size_changed.connect(_fit_density)
	_fit_density()
	UiPrefs.load_prefs()
	_load_extra_prefs()
	if Device.has_method("glyph_set"):
		Glyph.use_set(str(Device.glyph_set()))
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
	home.downloads_requested.connect(open_downloads)
	home.apps_requested.connect(open_apps)
	home.tile_hook = _hook_tile
	_screen_layer.add_child(home)

	library_screen = LibraryScreen.new()
	library_screen.open_requested.connect(_open_page)
	library_screen.game_focused.connect(_follow.bind("library"))
	library_screen.downloads_requested.connect(open_downloads)
	library_screen.filter_requested.connect(open_library_filter)
	library_screen.apps_requested.connect(open_apps)
	library_screen.tile_hook = _hook_tile
	library_screen.visible = false
	_screen_layer.add_child(library_screen)

	discover = DiscoverScreen.new()
	discover.visible = false
	discover.open_requested.connect(_open_page)
	discover.game_focused.connect(_follow.bind("discover"))
	_screen_layer.add_child(discover)
	discover.setup({"library": Library, "open_game": _open_page, "toast": toast})

	streaming = StreamingService.new()
	streaming.name = "Streaming"
	add_child(streaming)   # in the tree first: its jobs then run off the main thread
	streaming.setup(_streaming_ctx())
	stream_screen = StreamingScreen.new()
	stream_screen.visible = false
	_screen_layer.add_child(stream_screen)
	stream_screen.setup({"streaming": streaming, "toast": toast, "play": _play_stream})

	settings = SettingsScreen.new()
	settings.visible = false
	settings.changed.connect(_on_setting_changed)
	if settings.has_signal("setup_requested"):
		settings.setup_requested.connect(_on_setup_requested)
	if settings.has_signal("game_settings_requested"):
		settings.game_settings_requested.connect(_open_game_settings)
	settings.app_launch_requested.connect(_play_app)
	_screen_layer.add_child(settings)
	screens = {"home": home, "library": library_screen, "discover": discover, "stream": stream_screen, "settings": settings}

	_hint_shade = TextureRect.new()
	_hint_shade.name = "HintShade"
	_hint_shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint_shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_hint_shade.stretch_mode = TextureRect.STRETCH_SCALE
	_hint_shade.anchor_top = 1.0
	_hint_shade.anchor_right = 1.0
	_hint_shade.anchor_bottom = 1.0
	_hint_shade.offset_top = -ThemeLib.HINT_BAR_H - 40
	add_child(_hint_shade)
	hint_band = PanelContainer.new()
	hint_band.name = "HintBand"
	hint_band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint_band.anchor_top = 1.0
	hint_band.anchor_right = 1.0
	hint_band.anchor_bottom = 1.0
	hint_band.offset_top = -ThemeLib.HINT_BAR_H
	add_child(hint_band)
	var band_row := Kit.hbox(ThemeLib.SPACE_4)
	band_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint_band.add_child(band_row)
	hint_status = Kit.micro("")
	hint_status.name = "HintStatus"
	hint_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	band_row.add_child(hint_status)
	band_row.add_child(Kit.spacer())
	hint_bar = Kit.hbox(22)
	hint_bar.name = "HintBar"
	hint_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint_bar.alignment = BoxContainer.ALIGNMENT_END
	band_row.add_child(hint_bar)

	top_bar = TopBar.new()
	top_bar.anchor_right = 1.0
	top_bar.offset_left = ThemeLib.EDGE
	top_bar.offset_right = -ThemeLib.EDGE
	top_bar.offset_top = 10
	top_bar.offset_bottom = ThemeLib.TOP_BAR_H - 10
	top_bar.tab_pressed.connect(func(id): show_screen(id))
	top_bar.status_pressed.connect(_open_status)
	top_bar.search_pressed.connect(open_search)
	add_child(top_bar)
	downloads_button = DownloadsButton.new()
	downloads_button.pressed.connect(open_downloads)
	top_bar.add_child(downloads_button)
	top_bar.move_child(downloads_button, top_bar.status_button.get_index())

	# Modals sit above the screens and the top bar, under the hint bar.
	_modal_layer = Control.new()
	_modal_layer.name = "Modals"
	_modal_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_modal_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_modal_layer)
	move_child(_hint_shade, -1)
	move_child(hint_band, -1)

	toasts = Toasts.new()
	add_child(toasts)
	toasts.shown.connect(func(_t): _sound("toast"))

	status_panel = StatusPanel.new()
	status_panel.setup({})
	status_panel.closed.connect(func(): top_bar.status_button.grab_focus())
	add_child(status_panel)

	launch_overlay = LaunchOverlay.new()
	launch_overlay.cancel_requested.connect(_on_launch_cancelled)
	launch_overlay.revealing.connect(_launch_reveal)
	add_child(launch_overlay)

	recording = Recording.new()
	add_child(recording)
	recording.changed.connect(func(): top_bar.set_recording(recording.is_recording()))
	recording.saved.connect(func(path: String, info: Dictionary):
		toast(TX.REC_SAVED % (str(info.get("game", "")) if str(info.get("game", "")) != "" else path.get_file()), "check", "good",
			Recording.clock(int(info.get("seconds", 0))) + " · " + path.get_base_dir().replace(OS.get_environment("HOME"), "~")))
	recording.failed.connect(func(kind: String, detail: String):
		toast(str(TX.REC_ERRORS.get(kind, TX.REC_ERRORS["failed"])), "alert", "bad", detail))

	quick_menu = QuickMenu.new()
	var qm_services := {"recording": recording, "device": Device, "power": Power, "launcher": Launcher, "gamescope": Gamescope, "perf": _svc("PerfMonitor"), "controller": _svc("Controller")}
	if _svc("Controls") != null:
		qm_services["controls"] = _svc("Controls")
		qm_services["profiles"] = _svc("Profiles")
	qm_services["collections"] = Library.collections
	quick_menu.setup(qm_services)
	if quick_menu.has_signal("settings_requested"):
		quick_menu.settings_requested.connect(_open_settings_category)
	quick_menu.set_side(menu_side)
	quick_menu.closed.connect(_on_menu_closed)
	# full speed from the moment it shows (open() sets visible before building its first frame)
	quick_menu.visibility_changed.connect(func(): background.set_menu(quick_menu.visible))
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
		session.started.connect(_on_game_started)
	add_child(session)
	wiring = SessionWiring.new()
	wiring.setup({"perf": _svc("PerfMonitor"), "achievements": _svc("Achievements"), "updates": _svc("Updates"),
		"controller": _svc("Controller"), "discover": _svc("Discover"), "launcher": Launcher, "library": _svc("Library"),
		"controls": _svc("Controls"), "profiles": _svc("Profiles")})
	_wire_games()
	_wire_services()
	_wire_controls()
	_wire_saves_and_battery()
	_clean_ge_leftovers()
	closer = GameCloser.new()
	closer.name = "GameCloser"
	add_child(closer)
	# heartbeat for the session client's hang check, and why it left GameCove last time
	var health := SessionHealth.new()
	health.name = "SessionHealth"
	health.game_running = func() -> bool: return session != null and session.is_active()
	add_child(health)
	health.watch_session(session)
	if quick_menu.has_method("attach_session"):
		quick_menu.attach_session(session)
	if quick_menu.has_signal("exit_game_requested"):
		quick_menu.exit_game_requested.connect(exit_game)

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
	home.set_apps(_pinned_apps())
	Input.joy_connection_changed.connect(func(_d, _c): read_pads(true))
	read_pads(true)
	_last_input_ms = Time.get_ticks_msec()
	home.focus_later(home.default_focus())
	open_setup(false)
	var fallback_notice := SessionHealth.take_fallback_notice(SessionHealth.data_dir())
	if fallback_notice != "":
		toast(fallback_notice, "info", "warn")
	# Last, after the heartbeat is set up: the intro waits for nothing and nothing waits for it.
	if boot_splash and DisplayServer.get_name() != "headless":
		_boot_intro = load("res://scripts/ui/boot_splash.gd").play(self)


## Closes the running game (quick menu "Exit game", whose signal passes the game). Never blocks.
func exit_game(_game: Dictionary = {}) -> void:
	if quick_menu.visible:
		quick_menu.close()
	if streaming != null and str(session.game.get("store", "")) == StreamingService.STORE:
		streaming.stop_stream()   # Moonlight's Flatpak sits outside our scope
	if not closer.close(session):
		toast("No game is running", "info", "", "")


## Settings > Run setup again (it names a step; setup opens at the first unfinished one).
func _on_setup_requested(step: String = "") -> void:
	open_setup(true, step)


## First-run setup from the settings work, when that file is in this build.
## force: Settings asked to run it again (at `step`, e.g. "art" from Settings > Discover).
func open_setup(force: bool, step := "") -> void:
	if not ResourceLoader.exists(SETUP_FLOW):
		return
	var flow_script: Script = load(SETUP_FLOW)
	var svc := {"setup": _svc("Setup"), "device": Device, "discover": _svc("Discover"), "photo": _svc("DevicePhoto"), "library": _svc("Library")}
	var flow: Variant = null
	if force and _script_has(flow_script, "open"):
		flow = flow_script.call("open", self, svc, step)
	elif not force and _script_has(flow_script, "open_if_first_run"):
		flow = flow_script.call("open_if_first_run", self, svc)
	if flow is Node:
		setup_flow = flow
		if flow.has_signal("setting_changed"):
			flow.setting_changed.connect(_on_setting_changed)


static func _script_has(sc: Script, method: String) -> bool:
	for m in sc.get_script_method_list():
		if m["name"] == method:
			return true
	return false


## An autoload by name, or null (some are missing in previews).
func _svc(n: String) -> Node:
	return get_node_or_null("/root/" + n)


## Install state, game actions, downloads list and the Steam overlay.
func _wire_games() -> void:
	store_api = Library
	set_achievements(_svc("Achievements"))
	install_state = InstallState.new()
	install_state.name = "InstallState"
	add_child(install_state)
	install_state.changed.connect(_on_install_changed)
	install_state.progress.connect(_on_install_progress)
	install_state.finished.connect(_on_install_finished)
	game_actions = GameActions.new()
	add_child(game_actions)
	game_actions.setup(store_api, install_state, toast, _modal_layer, _svc("Storage"))
	game_actions.open_game.connect(func(g):
		close_downloads()
		_open_page(g))
	game_actions.modal_changed.connect(func(_o): _update_hints.call_deferred())
	collection_actions = CollectionActions.new()
	add_child(collection_actions)
	collection_actions.setup(Library.collections, game_actions)
	collection_actions.open_game.connect(_open_page)
	collection_actions.open_emulation.connect(open_emulation)
	game_actions.collection_actions = collection_actions
	Library.collections.changed.connect(_on_collections_changed)
	steam_overlay = SteamOverlay.new()
	steam_overlay.back_requested.connect(func(): store_api.return_from_steam())
	_modal_layer.add_child(steam_overlay)
	if Library.has_signal("action_failed"):
		Library.action_failed.connect(_on_action_failed)
	if Library.has_signal("external_window_needed"):
		Library.external_window_needed.connect(_on_external_window)
	install_state.attach(store_api)
	_refresh_downloads_indicators()


## One Achievements service (and its cache) for Home's progress card and the
## game page, so both always show the same numbers for a game.
func set_achievements(svc: Object) -> void:
	achievements_api = svc
	home.set_achievements(svc)


## Previews and tests: use another store API (a fake with Library's store
## methods and signals) and Achievements service.
func use_store_api(api: Object, achievements: Object = null) -> void:
	store_api = api
	if achievements != null:
		set_achievements(achievements)
	game_actions.library = api
	if api.has_signal("action_failed"):
		api.action_failed.connect(_on_action_failed)
	if api.has_signal("external_window_needed"):
		api.external_window_needed.connect(_on_external_window)
	install_state.attach(api)


## Power's "can't reach target" and the Controller's special buttons.
func _wire_services() -> void:
	var power: Node = _svc("Power")
	if power != null and power.has_signal("autotune_limit"):
		power.autotune_limit.connect(_on_autotune_limit)
	if power != null and power.has_signal("resumed"):
		power.resumed.connect(_on_power_resumed)
	# The s-hw Controller service may emit ui_action("home" | "quick_menu" | "osk")
	# for Guide / QuickAccess / Keyboard buttons it intercepts in InputPlumber.
	var ctl: Node = _svc("Controller")
	if ctl != null and ctl.has_signal("ui_action"):
		ctl.ui_action.connect(on_ui_action)


## Controls, Profiles and the device fixes around the game session. Each signal
## is connected once here (session start/end go through _on_game_started /
## _on_game_ended, connected in _ready before GameSession joins the tree, so they
## run before Profiles' own handlers).
func _wire_controls() -> void:
	var profiles := _svc("Profiles")
	if profiles != null and profiles.has_method("attach_session"):
		profiles.attach_session(session)   # no-op when it already found it
	fixes = FixesService.new()
	fixes.name = "Fixes"
	add_child(fixes)
	fixes.setup({"sys_root": "", "runner": CommandRunner.new(), "home": OS.get_environment("HOME"), "device": Device})
	fixes.check_changes()
	if quick_menu != null and "fixes" in quick_menu:
		quick_menu.fixes = fixes


## Cloud saves, battery history and Sleep at low battery: each follows events that happen
## anyway (a game starts or ends, the charger, a wake, Power's 15 s battery check).
func _wire_saves_and_battery() -> void:
	saves = SavesService.new()
	saves.name = "CloudSaves"
	saves.setup_library(_svc("Library"))
	saves.game_running = func() -> bool: return session != null and session.is_active()
	# no uninstall, move, update or verify of an Epic, GOG or Amazon game while it runs
	var lib_store: Variant = _svc("Library").get("store") if _svc("Library") != null else null
	if lib_store is Object and "game_running" in lib_store:
		lib_store.game_running = func(key: String) -> bool: return session != null and session.runs(key)
	saves.finished.connect(_on_saves_finished)
	add_child(saves)
	battery_log = BatteryLog.new()
	battery_log.name = "BatteryLog"
	if Device.get("root") is String:
		battery_log.sys_root = str(Device.get("root"))
	battery_log.attach_power(_svc("Power"))
	battery_log.attach_session(session)
	add_child(battery_log)
	low_battery = LowBattery.new()
	low_battery.name = "LowBattery"
	low_battery.setup(_svc("Power"), _svc("Controls"))
	low_battery.warn_requested.connect(_on_low_battery)
	low_battery.warn_cancelled.connect(func():
		if low_dialog != null and is_instance_valid(low_dialog):
			low_dialog.dismiss()
		_low_dialog_closed())
	low_battery.sleeping.connect(func(): battery_log.record("suspend"))
	add_child(low_battery)


## A cloud save job ended: after a game, only trouble is worth a toast (the page shows the rest).
func _on_saves_finished(key: String, phase: String, state: String) -> void:
	if phase != "post":
		return
	var g := View.find_by_key(_decorated(), key)
	var title := str(g.get("title", key))
	if state == "conflict":
		toast(TSaves.CONFLICT_TOAST % title, "alert", "warn")
	elif state in ["failed", "offline", "backup_failed"]:
		toast(TSaves.SYNC_FAILED_TOAST % title, "alert", "warn")


## Sleep at low battery: the 30 s warning, over a running game too.
func _on_low_battery(percent: int) -> void:
	if low_dialog != null and is_instance_valid(low_dialog):
		return
	low_dialog = LowBatteryDialog.open(_modal_layer, percent)
	low_dialog.decided.connect(func(stay: bool):
		if stay:
			low_battery.cancel()
		else:
			low_battery.confirm()
		_low_dialog_closed())
	background.set_menu(true)
	if session.is_active() and not quick_menu.visible:
		Gamescope.set_overlay(true)
	_update_hints.call_deferred()


func _low_dialog_closed() -> void:
	low_dialog = null
	background.set_menu(quick_menu.visible)
	if session.is_active() and not quick_menu.visible:
		Gamescope.set_overlay(false)
	_update_hints.call_deferred()


## The game is the scope of the per-game controls (perf.*): set it, then detect
## again so availability, options and values follow the game. Both run on the
## Controls worker in order, before Profiles applies the game's layers.
func _controls_follow_game(game: Dictionary) -> void:
	var controls := _svc("Controls")
	if controls == null or not controls.has_method("detect_all"):
		return
	var g := game.duplicate()
	if controls.has_method("run_on_worker"):
		controls.run_on_worker(func(): PerfProvider.set_game(controls.ctx, g))
	else:
		PerfProvider.set_game(controls.ctx, g)
	controls.detect_all()


## Firmware resets some controller lights over sleep: put them back once the
## pad is up again (HueSync waits 5 s). Forced: the controls still hold our values.
func _schedule_resume_reapply() -> void:
	if _resume_reapply_pending or not is_inside_tree():
		return
	_resume_reapply_pending = true
	get_tree().create_timer(ControllerProvider.RESUME_DELAY_S).timeout.connect(_reapply_after_resume, CONNECT_ONE_SHOT)


func _reapply_after_resume() -> void:
	_resume_reapply_pending = false
	var controls := _svc("Controls")
	if controls == null or not controls.has_method("apply"):
		return
	var vals := {}
	for id in ControllerProvider.REAPPLY_AFTER_RESUME:
		var v: Variant = controls.value(id)
		if v != null:
			vals[id] = v
	if not vals.is_empty():
		controls.apply(vals, true)


func _on_autotune_limit(cant_reach: bool, info: Dictionary) -> void:
	var m := TG.autotune_message(cant_reach, info)
	if not m.is_empty():
		toast(m[0], "bolt", "warn", m[1])


## Guide -> Home, QuickAccess -> quick menu, Keyboard -> search keyboard.
func on_ui_action(action: String) -> void:
	match action:
		"home":
			# In a game: Guide toggles between the game and GameCove's home,
			# the way Steam's button does.
			if session != null and session.is_active():
				if not _window_focused and not quick_menu.visible:
					session.bring_home()
				elif current == "home" and not quick_menu.visible and session.return_to_game():
					if wiring != null:
						wiring.sync_focus()
					return
			if quick_menu.visible:
				quick_menu.close()
			if steam_overlay.is_open():
				steam_overlay.close()
			close_downloads()
			_close_page()
			show_screen("home")
		"quick_menu":
			if quick_menu.visible:
				quick_menu.close()
			else:
				_open_menu()
		"osk":
			if not (game_actions.is_modal() or quick_menu.visible):
				close_downloads()
				_close_page()
				if current != "library":
					show_screen("library")
				library_screen.open_search()
	# InputPlumber switches itself to Always when Guide is pressed in Pass:
	# say again who has the controller now.
	if wiring != null:
		wiring.sync_focus()


func _on_action_failed(key: String, action: String, message: String) -> void:
	if not game_actions.should_toast_failure(key, action):
		return
	var g := View.find_by_key(Library.games, key)
	toast(TG.failed(action, str(g.get("title", ""))), "alert", "bad", message)


func _on_external_window(key: String, app: String, reason: String) -> void:
	var g := View.find_by_key(Library.games, key)
	steam_overlay.show_for(key, str(g.get("title", "")), app, reason)
	_update_hints.call_deferred()


func _hook_tile(t: Control) -> void:
	TileProgress.apply(t, install_state)


## Install state changed (queued, started, finished...): badges and the
## downloads indicators follow. Tiles are rebuilt only here, never per tick.
func _on_install_changed() -> void:
	_set_games(Library.games)
	_refresh_downloads_indicators()
	if steam_overlay.is_open() and install_state.is_busy(steam_overlay.key):
		steam_overlay.close()


## New numbers for one job: only the tiles showing it and the indicators.
func _on_install_progress(key: String) -> void:
	for t in _tiles_for(key):
		TileProgress.apply(t, install_state)
	_refresh_downloads_indicators()


func _tiles_for(key: String) -> Array:
	var out: Array = []
	for s in home.shelves():
		for t in s.tiles:
			if t.game.get("key", "") == key:
				out.append(t)
	for t in library_screen.tiles():
		if t.game.get("key", "") == key:
			out.append(t)
	return out


func _refresh_downloads_indicators() -> void:
	var jobs: int = install_state.queue.size()
	var all_paused: bool = jobs > 0 and install_state.queue.all(func(d): return str(d.get("state", "")) == "paused")
	downloads_button.set_progress(jobs > 0, install_state.overall_fraction(), jobs, all_paused)
	library_screen.set_downloads(jobs, install_state.overall_fraction())


func _on_install_finished(key: String, action: String, ok: bool) -> void:
	if not ok:
		return
	var g := View.find_by_key(Library.games, key)
	var title := str(g.get("title", ""))
	if action in ["install", "update", "verify"] and not g.is_empty():
		_prepare_upscaling(g)
	if action == "install" and title != "":
		toast("%s is ready to play" % title, "check", "good", "")
	elif action in ["update", "move", "uninstall", "verify"] and title != "":
		toast("%s: %s" % [title, TG.ACTION_DONE[action].to_lower()], "check", "good", "")


## Upscaling is set up when a game lands (installed, updated, files checked),
## not at its first start: one short helper run on the Controls worker. While a
## game is running nothing is started; that game is set up at its next look.
func _prepare_upscaling(g: Dictionary) -> void:
	var controls := _svc("Controls")
	if controls == null or not controls.has_method("run_on_worker") or not ("ctx" in controls):
		return
	var prepare: Variant = controls.ctx.get("prepare_installed")
	if not (prepare is Callable and (prepare as Callable).is_valid()):
		return
	var game := g.duplicate()
	var now: bool = not (session != null and session.is_active())
	controls.run_on_worker(func(): (prepare as Callable).call(game, now))


func open_downloads() -> void:
	if quick_menu.visible:
		quick_menu.close()
	if page != null:
		_close_page()
	if downloads_view == null:
		downloads_view = DownloadsView.new()
		downloads_view.setup(install_state, game_actions, func(k: String) -> Dictionary: return View.find_by_key(Library.games, k))
		downloads_view.open_game.connect(func(g):
			close_downloads()
			_open_page(g))
		downloads_view.browse_requested.connect(func():
			close_downloads()
			show_screen("library")
			library_screen.set_install_filter("not_installed"))
		add_child(downloads_view)
		move_child(downloads_view, top_bar.get_index())
	downloads_view.visible = false
	screens[current].visible = false
	downloads_view.open()
	_link_top()
	_sound("select")
	_update_hints.call_deferred()


func close_downloads() -> void:
	if downloads_view == null or not downloads_view.visible:
		return
	downloads_view.visible = false
	var s: Control = screens[current]
	s.visible = true
	s.modulate.a = 0.0
	Motion.to(s, "modulate:a", 1.0, Motion.FAST)
	_link_top()
	if downloads_button.is_visible_in_tree():
		downloads_button.grab_focus()
	_update_hints.call_deferred()


func _downloads_open() -> bool:
	return downloads_view != null and downloads_view.visible


# ------------------------------------------------------------ apps

## Pinned apps for Home's Apps shelf (saved with their icons: no scan at start).
func _pinned_apps() -> Array:
	return Apps.pinned()


## The Apps view over the current screen (desktop apps; A starts one, X pins it).
func open_apps() -> void:
	if quick_menu.visible:
		quick_menu.close()
	if page != null:
		_close_page()
	close_downloads()
	if apps_view == null:
		apps_view = AppsView.new()
		apps_view.launch_requested.connect(func(app: Dictionary):
			close_apps()
			_play_app(app))
		apps_view.pins_changed.connect(func(): home.set_apps(_pinned_apps()))
		apps_view.notice.connect(func(text: String, tone: String): toast(text, "check" if tone == "good" else "info", tone))
		add_child(apps_view)
		move_child(apps_view, top_bar.get_index())
	apps_view.top_target = top_bar.tabs[current]
	screens[current].visible = false
	apps_view.open()
	_link_top()
	_sound("select")
	_update_hints.call_deferred()


func close_apps() -> void:
	if not _apps_open():
		return
	apps_view.close()
	var s: Control = screens[current]
	s.visible = true
	s.modulate.a = 0.0
	Motion.to(s, "modulate:a", 1.0, Motion.FAST)
	_link_top()
	var f := _screen_default_focus()
	if f != null:
		f.grab_focus()
	_update_hints.call_deferred()


func _apps_open() -> bool:
	return apps_view != null and apps_view.visible


## Starts a desktop app or a clip's player like a game.
func _play_app(app: Dictionary) -> void:
	if session.runs(str(app.get("key", ""))):
		session.return_to_game()
		return
	var launched: Dictionary = Library.launch(app)
	if not bool(launched.get("ok", false)):
		toast(TX.APPS_FAILED % str(app.get("title", "")), "alert", "bad")
		return
	playing = app
	launch_overlay.show_for(app, backdrop.current_accent())
	_pause_motion()
	session.begin(app, launched)


# ------------------------------------------------------------ controller batteries

## Reads the controllers' batteries from UPower on a worker. `now`: an event
## (focus back, quick menu, a pad connected); else only when the last read is
## older than UPower.READ_EVERY_S (the live refresh, which only runs while
## GameCove is in front). Never behind a game.
func read_pads(now: bool) -> void:
	if _pads_busy or DisplayServer.get_name() == "headless":
		return
	if not now and Time.get_ticks_msec() - _pads_at < UPower.READ_EVERY_S * 1000:
		return
	_pads_at = Time.get_ticks_msec()
	_pads_busy = true
	# on card_jobs.gd's pool: the result comes back by instance id on the main
	# thread, and the busctl calls end at exit (its stop group)
	var jobs: RefCounted = CardJobs.shared()
	var r: RefCounted = jobs.runner()
	jobs.run_for(self, func(): return UPower.pads(r), "_on_pads")


func _on_pads(list: Array) -> void:
	_pads_busy = false
	top_bar.set_pads(list)


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
	if what == NOTIFICATION_THEME_CHANGED:
		# The band and its shade bake theme colours: any theme switch (not only
		# apply_theme) restyles them, or Light would keep a dark band.
		if hint_band != null and _hint_shade != null:
			_style_hint_shade()
		return
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_window_focused = false
		if background != null:
			background.set_front(false)
		if wiring != null:
			wiring.home_in_front(false)
		if launch_overlay != null:
			launch_overlay.finish()
		# the game took the screen: the quick menu's This game catches up with
		# what changed since it started, once, so the first press is quick
		if session != null and session.is_active() and not playing.is_empty() and quick_menu != null \
				and not quick_menu.visible and quick_menu.has_method("prepare"):
			quick_menu.prepare(playing)
		if _boot_intro != null and is_instance_valid(_boot_intro):
			_boot_intro.skip(true)   # a game (or anything) in front: gone, nothing left playing
		if backdrop != null:
			_pause_motion()
		_update_timer()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_window_focused = true
		if background != null:
			background.set_front(true)   # first: everything below runs at full speed
		if wiring != null:
			wiring.home_in_front(true)
		_check_resume()
		_refresh_live()
		_update_timer()
		read_pads(true)
	elif what == NOTIFICATION_WM_CLOSE_REQUEST and session != null:
		session.stop()


## Slow drifts (hero, backdrop) stop when idle, in a game or under Reduce motion.
func _pause_motion() -> void:
	backdrop.pause_motion()
	home.hero_stage.pause_motion()


func _resume_motion() -> void:
	backdrop.resume_motion()
	home.hero_stage.resume_motion()


## Big screens get more room instead of just bigger pixels: past 1280x800
## the scale grows at half the rate (1920x1200 lays out at 1536x960, 1.25x),
## which keeps text about the size it is on a 7" 800p handheld.
func _fit_density() -> void:
	var w := get_window()
	if w == null or w.content_scale_mode == Window.CONTENT_SCALE_MODE_DISABLED:
		return
	w.content_scale_size = base_size_for(w.size)


static func base_size_for(win: Vector2i) -> Vector2i:
	var s := minf(win.x / 1280.0, win.y / 800.0)
	if s <= 1.0:
		return Vector2i(1280, 800)
	var eff := 1.0 + (s - 1.0) * 0.5
	return Vector2i(roundi(win.x / eff), roundi(win.y / eff))


## An interrupted GE-Proton install or removal (power off, app killed) left files in
## compatibilitytools.d/.gamecove-download (never where Steam looks): they go now, on
## the card jobs' worker. One folder check on the main thread; nothing when clean.
func _clean_ge_leftovers() -> void:
	var dir := ProtonGE.compat_dir(OS.get_environment("HOME"))
	if not ProtonGE.has_leftovers(dir):
		return
	var jobs: RefCounted = CardJobs.shared()
	var g: String = jobs.group
	jobs.start("ge_proton", "cleanup", func(): return ProtonGE.cleanup(dir, g), "_on_cleaned")


## Static caches hold textures and fonts; let them go so nothing leaks at exit.
func _exit_tree() -> void:
	release_caches()


static func release_caches() -> void:
	# real exit: the cards' downloads and scans end first (their programs are
	# stopped), so the wait for their threads is short
	load("res://scripts/system/card_jobs.gd").shutdown_shared()
	load("res://scripts/system/cache_prune.gd").wait_all()
	load("res://scripts/ui/icons.gd")._cache.clear()
	load("res://scripts/ui/games/game_icons.gd").clear()
	load("res://scripts/ui/art_cache.gd").shutdown()
	ThemeLib._fonts.clear()
	ThemeLib._knobs.clear()
	ThemeLib._gradients.clear()
	Kit._art_cache.clear()
	Backdrop._glow_tex = null


func _on_live_tick() -> void:
	_check_resume()
	_refresh_live()
	read_pads(false)
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
		call_deferred("_wake_fade")   # after the resume handling, purely visual
	_clock_mark = now


static func resumed_between(before: Array, after: Array, gap_s: float) -> bool:
	if before[1] == 0:
		return false
	var wall: float = after[0] - before[0]
	var mono: float = (after[1] - before[1]) / 1000.0
	return wall - mono > gap_s


## Power noticed a sleep itself (its 15 s check, review M19) or finished ours: the
## controller lights follow, and our own clock mark moves so we don't report it twice.
func _on_power_resumed() -> void:
	_clock_mark = [Time.get_unix_time_from_system(), Time.get_ticks_msec()]
	_schedule_resume_reapply()
	call_deferred("_wake_fade")


## Back from sleep: the screen comes up out of a soft dark (and the screens
## settle from a touch smaller), only when it's ours that shows. Never before a
## suspend, never in the way of the resume work (it's called after it), never
## blocks input, once per wake.
const WAKE_FADE_S := 0.2
var _wake_shade: ColorRect
var _last_wake_ms := -1_000_000


func _wake_fade() -> void:
	if Motion.reduce or not _window_focused or not is_inside_tree():
		return
	var now := Time.get_ticks_msec()
	if now - _last_wake_ms < 10_000:
		return
	_last_wake_ms = now
	if _wake_shade == null or not is_instance_valid(_wake_shade):
		_wake_shade = ColorRect.new()
		_wake_shade.name = "WakeShade"
		_wake_shade.color = Color("#05070B")
		Kit.fill(_wake_shade)
		_wake_shade.mouse_filter = Control.MOUSE_FILTER_IGNORE   # the first tap after a wake goes through
		add_child(_wake_shade)
	move_child(_wake_shade, -1)
	_wake_shade.visible = true
	var t := Motion.enter(_wake_shade, "modulate:a", 0.9, 0.0, WAKE_FADE_S, 0.0, Tween.TRANS_SINE, Tween.EASE_OUT)
	if t != null:
		t.finished.connect(_wake_shade.hide)
	_screen_layer.pivot_offset = size / 2.0
	Motion.enter(_screen_layer, "scale", Vector2.ONE * 0.985, Vector2.ONE, WAKE_FADE_S + 0.04, 0.0, Tween.TRANS_QUART, Tween.EASE_OUT)


## After a sleep: Power re-reads on its worker, puts the TDP back and emits
## `resumed` (the power controls re-apply on that); the controller lights follow
## 5 s later.
func _power_refresh() -> void:
	if Power.has_method("request_resumed"):
		Power.request_resumed()
	elif Power.has_method("request_refresh"):
		Power.request_refresh()
	else:
		Power.refresh()
	_schedule_resume_reapply()


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
	top_bar.set_telemetry(telemetry())
	home.set_battery_left(battery_left_text(b, _battery_full_wh()))
	status_panel.set_battery(Device.display_name(), b)
	_refresh_hint_status()
	if TopBar.is_low(b):
		if not _battery_warned:
			_battery_warned = true
			toast("Battery low: %d%%" % int(b["percent"]), "alert", "bad", "Plug in soon, or pick Longest battery in the quick menu.")
	else:
		_battery_warned = false
	if quick_menu.visible:
		quick_menu.refresh_live()


## What the top bar's telemetry pill shows: TDP and power profile when a power
## backend is there, CPU temperature while a game is measured. -1 / "" = hide.
func telemetry() -> Dictionary:
	var out := {"tdp_w": -1.0, "profile": "", "temp_c": -1.0}
	if Power.has_method("state"):
		var st: Dictionary = Power.state()
		if float(st.get("tdp_w", -1.0)) > 0.0:
			out["tdp_w"] = float(st["tdp_w"])
			out["profile"] = str(st.get("profile", ""))
	var perf := _svc("PerfMonitor")
	if perf != null and perf.has_method("is_active") and perf.is_active() and "latest" in perf:
		var l: Dictionary = perf.latest
		out["temp_c"] = float(l.get("cpu_temp", -1.0))
	return out


var _full_wh := -2.0

## The battery's full capacity in Wh from Device.info() (read once), -1 if unknown.
func _battery_full_wh() -> float:
	if _full_wh < -1.0:
		_full_wh = -1.0
		if Device.has_method("battery_path") and Device.battery_path() != "":
			var e := str(Device.read_text(Device.battery_path() + "energy_full"))
			if e.is_valid_int() and e.to_int() > 0:
				_full_wh = e.to_int() / 1_000_000.0
	return _full_wh


## "~2 h 45 min" while discharging with a known draw and capacity, else "".
static func battery_left_text(b: Dictionary, full_wh: float) -> String:
	var pct := int(b.get("percent", -1))
	var w := float(b.get("watts", -1.0))
	if b.get("status", "") != "Discharging" or pct < 0 or w <= 0.5 or full_wh <= 0.0:
		return ""
	var minutes := int(full_wh * pct / 100.0 / w * 60.0)
	if minutes < 1:
		return ""
	return "~%d h %02d min" % [minutes / 60, minutes % 60] if minutes >= 60 else "~%d min" % minutes


## Left of the hint bar: the app and version, the device, a running game.
func _refresh_hint_status() -> void:
	if hint_status == null:
		return
	var parts: Array[String] = ["● GameCove " + _version().trim_prefix("v")]
	if not playing.is_empty() and session != null and session.has_method("is_active") and session.is_active():
		parts.append("Playing " + str(playing.get("title", "")))
	else:
		var dn := str(Device.display_name())
		if dn != "":
			parts.append(dn)
	hint_status.text = "   ".join(parts)


## The top bar's search: Library with its search keyboard open.
func open_search() -> void:
	show_screen("library")
	if library_screen.has_method("open_search"):
		library_screen.open_search.call_deferred()


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
			# the first press after a wake notices it at once (two clock reads, at most every 2 s)
			if _last_input_ms - int(_clock_mark[1]) > 2000:
				_check_resume()


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
	if quick_menu.visible or launch_overlay.is_open():
		return
	if event.is_action_pressed("ui_accept"):
		_sound("select")
	# Sheets, the text keyboard and the Steam overlay handle their own input.
	if game_actions.is_modal() or steam_overlay.is_open():
		return
	if _downloads_open():
		if event.is_action_pressed("ui_cancel"):
			_sound("back")
			close_downloads()
			get_viewport().set_input_as_handled()
		elif _overlay_shoulder(event):
			get_viewport().set_input_as_handled()
		elif _pressed(event, JOY_BUTTON_X, KEY_P):
			downloads_view.toggle_focused()
			get_viewport().set_input_as_handled()
		return
	if _apps_open():
		if event.is_action_pressed("ui_cancel"):
			_sound("back")
			close_apps()
			get_viewport().set_input_as_handled()
		elif _overlay_shoulder(event):
			get_viewport().set_input_as_handled()
		elif _pressed(event, JOY_BUTTON_X, KEY_X):
			apps_view.toggle_focused()
			_update_hints()
			get_viewport().set_input_as_handled()
		return
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
		elif _overlay_shoulder(event):
			get_viewport().set_input_as_handled()
	elif _shoulder(event, JOY_BUTTON_LEFT_SHOULDER, KEY_Q):
		cycle_screen(-1)
		get_viewport().set_input_as_handled()
	elif _shoulder(event, JOY_BUTTON_RIGHT_SHOULDER, KEY_E):
		cycle_screen(1)
		get_viewport().set_input_as_handled()
	elif current in ["library", "settings"] and _trigger_once(event) != 0:
		# Read the trigger once: _trigger() tracks the press edge, so a second
		# call for the same event would read 0.
		var d := _last_trigger
		if current == "library":
			library_screen.jump_letter(d)
		else:
			settings.cycle_tabs(d)
		get_viewport().set_input_as_handled()
	elif current in ["home", "library"] and _pressed(event, JOY_BUTTON_START, KEY_M) and _focused_tile() != null:
		collection_actions.options(_focused_tile().game)
		get_viewport().set_input_as_handled()
	elif current == "library" and _pressed(event, JOY_BUTTON_BACK, KEY_F):
		open_library_filter()
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


## The game tile with focus on Home or in the Library, or null.
func _focused_tile() -> Control:
	var f := get_viewport().gui_get_focus_owner()
	if f is Button and f.theme_type_variation == "TileButton" and f.get("game") is Dictionary and not f.game.is_empty():
		return f
	return null


## LB / RB on the game page or Downloads: the top bar is showing, so they
## switch tabs like everywhere else (the page closes first). True if handled.
func _overlay_shoulder(event: InputEvent) -> bool:
	var d := -1 if _shoulder(event, JOY_BUTTON_LEFT_SHOULDER, KEY_Q) else (1 if _shoulder(event, JOY_BUTTON_RIGHT_SHOULDER, KEY_E) else 0)
	if d == 0:
		return false
	cycle_screen(d)
	return true


static func _shoulder(event: InputEvent, button: JoyButton, key: Key) -> bool:
	return QuickMenu._is_shoulder(event, button, key)


var _trigger_held := {}
var _last_trigger := 0


## _trigger() for this event, remembered in _last_trigger.
func _trigger_once(event: InputEvent) -> int:
	_last_trigger = _trigger(event)
	return _last_trigger

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
	if _downloads_open():
		return downloads_view
	if _apps_open():
		return apps_view
	return page if page != null else screens[current]


func _screen_default_focus() -> Control:
	var f: Control = _screen().default_focus()
	return f if f != null else top_bar.tabs[current]


# ------------------------------------------------------------ screens

## LB / RB: the next tab along, wrapping (RB from Settings slides Home in from
## the right, the way the press went).
func cycle_screen(d: int) -> void:
	show_screen(SCREENS[posmod(SCREENS.find(current) + d, SCREENS.size())], d)


## Switch tabs: the new screen slides in from the side the press went (`dir`:
## +1 RB, -1 LB; 0 = from where it sits in the tab row), the old one drifts the
## other way as it fades. Never holds input: the new screen takes focus at once,
## and a press mid-way just retargets both (Motion kills the earlier tweens).
func show_screen(id: String, dir := 0) -> void:
	if not screens.has(id):
		return
	# A tab picked from the top bar over the game page or Downloads.
	if page != null:
		_close_page()
	close_downloads()
	close_apps()
	var old: Control = screens[current]
	var d := float(signi(dir)) if dir != 0 else signf(SCREENS.find(id) - SCREENS.find(current))
	current = id
	top_bar.select(id)
	var new: Control = screens[id]
	if old != new:
		_screen_out(old, d)
		_screen_in(new, d)
		_sound("move")
	if id == "library":
		_mark_new_seen()
	_link_top()
	var f := _screen_default_focus()
	if is_inside_tree() and f != null:
		Home.focus_later(f)
	if id == "home":
		backdrop.show_game(home.spotlight_game)


## Screen change timings: the new screen slides SCREEN_SLIDE_PX in from the
## side the press went over SCREEN_IN_S with a strong ease-out (most of the
## move lands in the first frames, so the direction reads even at a glance)
## and is opaque within SCREEN_FADE_IN_S; the old one slides the same distance
## the other way and is gone within SCREEN_OUT_S, so they barely overlap.
const SCREEN_IN_S := 0.16
const SCREEN_FADE_IN_S := 0.12
const SCREEN_OUT_S := 0.09
const SCREEN_SLIDE_PX := 36.0


func _screen_in(s: Control, d: float) -> void:
	if not s.visible:
		s.modulate.a = 0.0
	s.visible = true   # a screen still fading out (pressed back quickly) turns around from where it is
	s.scale = Vector2.ONE
	s.position.x = Motion.slide(SCREEN_SLIDE_PX) * d
	Motion.to(s, "modulate:a", 1.0, SCREEN_FADE_IN_S, Tween.TRANS_LINEAR, Tween.EASE_OUT)
	Motion.to(s, "position:x", 0.0, SCREEN_IN_S, Tween.TRANS_EXPO, Tween.EASE_OUT)


func _screen_out(s: Control, d: float) -> void:
	var t := Motion.to(s, "modulate:a", 0.0, SCREEN_OUT_S)
	Motion.to(s, "position:x", -Motion.slide(SCREEN_SLIDE_PX) * d, SCREEN_OUT_S, Tween.TRANS_CUBIC, Tween.EASE_OUT)
	if t == null:
		_screen_hidden(s)
	else:
		t.finished.connect(_screen_hidden.bind(s))


## The old screen's fade ended: hide it, back in place (unless it came back meanwhile).
func _screen_hidden(s: Control) -> void:
	if not is_instance_valid(s) or s == screens.get(current) or s.modulate.a > 0.01:
		return
	s.visible = false
	Motion.to(s, "position:x", 0.0, 0.0)


func _link_top() -> void:
	var tab: Control = top_bar.tabs[current]
	for s in screens.values():
		if s.has_method("set_top_target"):
			s.set_top_target(tab)
	# The game page and Downloads keep the top bar: down from it goes into them.
	var f: Control = _screen().default_focus()
	for extra in [page, downloads_view, apps_view]:
		if extra != null and is_instance_valid(extra) and extra.has_method("set_top_target"):
			extra.set_top_target(tab)
	for t in top_bar.tab_buttons():
		t.focus_neighbor_bottom = t.get_path_to(f if f != null else t)
		t.focus_neighbor_top = t.get_path_to(t)
	top_bar.link_bar()
	# The downloads button sits between the tabs and the status pill.
	Kit.link_horizontal([top_bar.tabs["home"], top_bar.tabs["library"], top_bar.tabs["discover"], top_bar.tabs["stream"], downloads_button, top_bar.status_button, top_bar.tabs["settings"]])
	downloads_button.focus_neighbor_bottom = downloads_button.get_path_to(f if f != null else top_bar.tabs[current])
	downloads_button.focus_neighbor_top = downloads_button.get_path_to(downloads_button)
	top_bar.status_button.focus_neighbor_bottom = top_bar.status_button.get_path_to(f if f != null else top_bar.tabs[current])
	top_bar.status_button.focus_neighbor_top = top_bar.status_button.get_path_to(top_bar.status_button)


## Home's and the page's main button. Owned games that aren't installed get
## installed; ones waiting for an update get updated; the rest start.
func _play(game: Dictionary) -> void:
	if str(game.get("store", "")) == Apps.STORE:
		_play_app(game)
		return
	if not game.get("installed", false):
		game_actions.install(game)
		return
	if install_state.state_of(str(game.get("key", ""))) == "update_required":
		game_actions.update(game)
		return
	if install_state.is_busy(str(game.get("key", ""))):
		open_downloads()
		return
	if session.runs(str(game.get("key", ""))):
		session.return_to_game()   # already running: back to it, no second launch
		return
	if _launch_wait != "":
		return   # another game is still getting its cloud save
	playing = game
	launch_overlay.show_for(game, backdrop.current_accent(), _launch_source(game))
	_launch_recede()
	_pause_motion()
	if saves == null or not saves.applies(game):
		_launch_now(game)
		return
	# Epic / GOG: the newest cloud save comes down first (never while the game runs)
	_launch_wait = str(game.get("key", ""))
	launch_overlay.status.text = TSaves.SYNC_LAUNCH
	saves.before_launch(game, func(r: Dictionary): _after_cloud_check(game, r))


## The cloud save check before a launch finished: start, or let the user pick a side first.
func _after_cloud_check(game: Dictionary, r: Dictionary) -> void:
	if _launch_wait != str(game.get("key", "")):
		return   # cancelled meanwhile
	if r.has("conflict"):
		launch_overlay.finish()
		var key := str(game.get("key", ""))
		_conflict_for = key
		game_actions.open_menu(TSaves.CONFLICT_TITLE, TSaves.CONFLICT_LINE % str(game.get("title", "")),
			SavesCardScript.conflict_rows(r["conflict"], int(Time.get_unix_time_from_system()), true),
			func(id: String) -> void:
				_conflict_for = ""
				launch_overlay.show_for(game, backdrop.current_accent(), _launch_source(game))
				if id in ["local", "cloud"]:
					launch_overlay.status.text = TSaves.SYNC_LAUNCH
					saves.resolve(game, id, func(_st): _start_after_sync(game))
				else:
					_start_after_sync(game))
		game_actions.sheet.closed.connect(func(): call_deferred("_conflict_closed", key), CONNECT_ONE_SHOT)
		return
	_start_after_sync(game)


## The conflict sheet closed: without a pick (B), the game doesn't start.
func _conflict_closed(key: String) -> void:
	if _conflict_for != key:
		return
	_conflict_for = ""
	if _launch_wait == key:
		_launch_wait = ""
		playing = {}
		_resume_motion()


func _start_after_sync(game: Dictionary) -> void:
	if _launch_wait != str(game.get("key", "")):
		return
	_launch_wait = ""
	if not launch_overlay.is_open():
		launch_overlay.show_for(game, backdrop.current_accent(), _launch_source(game))   # its timeout ran out meanwhile
	launch_overlay.status.text = "Launching…"
	_launch_now(game)


func _launch_now(game: Dictionary) -> void:
	var launched: Dictionary = Library.launch(game)
	session.begin(game, launched)
	if not bool(launched.get("ok", false)):
		launch_overlay.back()   # Library says why (action_failed)
		_resume_motion()


## Under the launch zoom the screen it started on steps back: a short drop
## and a quick fade (it's covered within ~0.2 s anyway).
const LAUNCH_RECEDE_PX := 32.0
const LAUNCH_RECEDE_S := 0.12
var _receded: Control


func _launch_recede() -> void:
	_receded = _screen()
	if _receded == null or not launch_overlay.is_open():
		return
	Motion.to(_receded, "modulate:a", 0.0, LAUNCH_RECEDE_S)
	Motion.to(_receded, "position:y", Motion.slide(LAUNCH_RECEDE_PX), LAUNCH_RECEDE_S, Tween.TRANS_CUBIC, Tween.EASE_OUT)


## The splash is on its way back (failed or cancelled launch, timeout) or the
## game came back: the screen is in place at once (the zoom goes back into its
## art) and fades back up.
func _launch_reveal() -> void:
	var n := _receded
	_receded = null
	if n == null or not is_instance_valid(n):
		return
	Motion.to(n, "position:y", 0.0, 0.0)
	Motion.to(n, "modulate:a", 1.0, launch_overlay.BACK_S)


## Where the launch zoom starts: the art Play was pressed on (Home's hero, the
## game page's hero, the focused cover). {} = it grows from the middle.
func _launch_source(game: Dictionary) -> Dictionary:
	var s := _screen()
	if s != null and s.has_method("launch_source"):
		var d: Dictionary = s.launch_source(game)
		if not d.is_empty():
			return d
	var f := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	if f != null and f.has_method("launch_source") and f.get("game") is Dictionary \
			and str(f.game.get("key", "")) == str(game.get("key", "")):
		return f.launch_source()
	return {}


## A stream from the Stream tab: Moonlight starts, then the GameSession follows
## it like a game (focus, Guide to home and back, quick menu, Exit game).
func _play_stream(game: Dictionary, host_id: String, app: Dictionary) -> void:
	if session.runs(str(game.get("key", ""))):
		session.return_to_game()
		return
	var launched: Dictionary = streaming.launch(host_id, app)
	if not bool(launched.get("ok", false)):
		toast(str(launched.get("why", "")), "alert", "bad")
		return
	playing = game
	launch_overlay.show_for(game, backdrop.current_accent(), _launch_source(game))
	_launch_recede()
	_pause_motion()
	session.begin(game, launched)


## What the Streaming service needs from this handheld: how to run things, its
## GPU family, and its screen (asked again whenever the Stream tab opens).
func _streaming_ctx() -> Dictionary:
	var prof: Dictionary = Device.profile if Device.get("profile") is Dictionary else {}
	return {"runner": CommandRunner.new(), "home": OS.get_environment("HOME"), "path_env": OS.get_environment("PATH"),
		"runtime_dir": OS.get_environment("XDG_RUNTIME_DIR"), "display": stream_display(),
		"display_fn": stream_display, "gpu_family": str(prof.get("gpu_family", ""))}


## The panel's size, top refresh rate and whether HDR is on now (display.hdr).
func stream_display() -> Dictionary:
	var prof: Dictionary = Device.profile if Device.get("profile") is Dictionary else {}
	var panel: Variant = prof.get("panel")
	var res: Array = panel.get("resolution", []) if panel is Dictionary and panel.get("resolution") is Array else []
	var hz: Array = prof.get("panel_hz", []) if prof.get("panel_hz") is Array else []
	var win := DisplayServer.screen_get_size() if DisplayServer.get_name() != "headless" else Vector2i(1280, 800)
	var controls := _svc("Controls")
	var hdr := false
	if controls != null and controls.has_method("has") and controls.has("display.hdr"):
		hdr = controls.value("display.hdr") == true
	return {"width": int(res[0]) if res.size() == 2 else win.x, "height": int(res[1]) if res.size() == 2 else win.y,
		"hz": int(hz[hz.size() - 1]) if not hz.is_empty() else 60, "hdr": hdr}


func _on_launch_cancelled(_game: Dictionary) -> void:
	_sound("back")
	if _launch_wait != "":
		_launch_wait = ""   # still getting the cloud save: the game won't start
		playing = {}
	_resume_motion()
	if session.is_active():
		session.stop()


## GameSession follows the game now. The launch splash stays until the game's
## window takes the screen (focus out) and hides then.
func _on_game_started(game: Dictionary) -> void:
	_game_started_at = int(Time.get_unix_time_from_system())
	if streaming != null:
		streaming.set_game_running(true)
	wiring.game_started(game, int(session.app_id))
	if fixes != null:
		fixes.set_game_running(true)
	_controls_follow_game(game)
	# the quick menu's This game, built once now so every press over the game only shows it
	# (deferred: after the menu's own `started` handler has seen the session)
	if quick_menu != null and quick_menu.has_method("prepare"):
		quick_menu.prepare.call_deferred(game)


func _on_game_ended(game: Dictionary) -> void:
	wiring.game_ended(game)
	if _game_started_at > 0 and Library.has_method("record_playtime"):
		Library.record_playtime(game, _game_started_at, int(Time.get_unix_time_from_system()))
	_game_started_at = 0
	if saves != null:
		saves.after_exit(game)   # what the game just saved goes up
	# a clip belongs to its game: the game ending stops (and saves) it
	if recording != null and recording.is_recording():
		recording.stop()
	if streaming != null:
		streaming.set_game_running(false)
	if fixes != null:
		fixes.set_game_running(false)
	# after Profiles has put the pre-game values back (its handler runs after ours)
	_controls_follow_game.call_deferred({})
	if not playing.is_empty() and playing.get("key", "") == game.get("key", ""):
		playing = {}
	_check_resume()
	if launch_overlay.is_open():
		launch_overlay.back()   # it never got the screen: back into the art it came from
		_resume_motion()
	elif launch_overlay.phase == "closing":
		_resume_motion()        # cancelled: already on its way back
	else:
		_return_home()


## Coming back from a game: the screens settle in from slightly smaller.
func _return_home() -> void:
	_resume_motion()
	if _receded != null and is_instance_valid(_receded):
		Motion.to(_receded, "position:y", 0.0, 0.0)
		Motion.to(_receded, "modulate:a", 1.0, 0.0)
	_receded = null
	_screen_layer.pivot_offset = size / 2.0
	_screen_layer.scale = Vector2.ONE * (1.0 if Motion.reduce else 0.97)
	_screen_layer.modulate.a = 0.0
	Motion.to(_screen_layer, "scale", Vector2.ONE, Motion.SLOW)
	Motion.to(_screen_layer, "modulate:a", 1.0, Motion.SLOW)


## Quick menu "All settings" → the matching Settings page.
func _open_settings_category(category: String, part: String) -> void:
	if quick_menu != null and quick_menu.visible:
		quick_menu.close()
	if page != null:
		_close_page()
	show_screen("settings")
	if settings.has_method("open_category"):
		# after show_screen's own deferred focus (the category it was last on), or
		# that lands later and switches Settings back to it, focus lost
		settings.open_category.call_deferred(category, part)


## Edit a game's settings: the quick menu opened on that game.
func _open_game_settings(game: Dictionary) -> void:
	if quick_menu != null:
		quick_menu.open(game)


func _open_page(game: Dictionary) -> void:
	# ES-DE / RetroDECK's tile opens the Emulation page.
	if str(game.get("store", "")) == "emu" and str(game.get("id", "")) in ["frontend", "page"]:
		open_emulation()
		return
	if page != null:
		_close_page()
	close_downloads()
	var f := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	_page_return = f if f != null and screens[current].is_ancestor_of(f) else null
	page = GamePage.new()
	var g := View.find_by_key(_decorated(), str(game.get("key", "")))
	page.setup(g if not g.is_empty() else game, Launcher, {"library": store_api, "state": install_state, "actions": game_actions,
		"achievements": achievements_api, "collections": collection_actions, "saves": saves, "battery": battery_log})
	page.play_requested.connect(_play)
	page.back_requested.connect(_close_page)
	page.downloads_requested.connect(open_downloads)
	if page.game_settings != null and page.game_settings.has_signal("edit_requested"):
		page.game_settings.edit_requested.connect(_open_game_settings)
	add_child(page)
	move_child(page, top_bar.get_index())
	# Opened from Home's hero on the same game: the hero stays put (the page's
	# hero card is drawn where Home's was, so nothing fades out and back in)
	# and only the cards slide up. From anywhere else the page fades in
	# quickly with the same card slide.
	if _page_shares_hero(game):
		page.modulate.a = 1.0
		Motion.enter(page.frame, "offset_bottom", home.frame.offset_bottom, page.frame.offset_bottom, PAGE_IN_S,
			0.0, Tween.TRANS_EXPO, Tween.EASE_OUT)
		_pin_page_header()
	else:
		page.modulate.a = 0.0
		Motion.to(page, "modulate:a", 1.0, PAGE_FADE_S)
	page.slide_cards(PAGE_CARDS_PX, PAGE_IN_S)
	screens[current].visible = false
	_link_top()
	backdrop.show_game(game)
	page.set_accent(backdrop.current_accent())
	page.focus_first()
	_sound("select")


## The Emulation page (EmuDeck, RetroDECK or ES-DE), from the Library's filter
## sheet or ES-DE's tile. Its buttons start things through _play.
func open_emulation() -> void:
	if page != null:
		_close_page()
	close_downloads()
	page = EmulationPage.new()
	page.setup(Library.emulation, _decorated())
	page.play_requested.connect(_play)
	page.library_requested.connect(func():
		_close_page()
		show_screen("library")
		library_screen.set_view("emulation"))
	add_child(page)
	move_child(page, top_bar.get_index())
	# Rises in like the game page.
	page.modulate.a = 0.0
	page.position.y = Motion.slide(PAGE_RISE_PX)
	Motion.to(page, "modulate:a", 1.0, SCREEN_IN_S)
	Motion.to(page, "position:y", 0.0, SCREEN_IN_S, Tween.TRANS_QUART, Tween.EASE_OUT)
	screens[current].visible = false
	_link_top()
	backdrop.show_game(page.game)
	page.set_accent(backdrop.current_accent())
	page.focus_first()
	_sound("select")


## The Library's Filter sheet (its header button, or View).
func open_library_filter() -> void:
	collection_actions.filter(library_screen)


## Favourites, hidden or collections changed: every screen shows it.
func _on_collections_changed() -> void:
	_set_games.call_deferred(Library.games)
	if page != null and page.has_method("refresh_favourite"):
		page.refresh_favourite.call_deferred()


## The game page rises this far as it opens; the screen under it settles back
## from a touch smaller when it closes.
const PAGE_RISE_PX := 22.0
const PAGE_BACK_SCALE := 0.985

## The game page: its cards slide up PAGE_CARDS_PX over PAGE_IN_S as it opens
## (the page fades in over PAGE_FADE_S unless it shares Home's hero); on Back
## the screen under it is there at once and the page's cards drop
## PAGE_CARDS_PX as it fades over PAGE_OUT_S.
const PAGE_CARDS_PX := 48.0
const PAGE_IN_S := 0.22
const PAGE_FADE_S := 0.14
const PAGE_OUT_S := 0.14
## What had focus when the page opened (Home's Game page button, a tile), so
## Back lands exactly there and the screen under it doesn't scroll away.
var _page_return: Variant = null


## The page's title, meta and Play start where Home's are and settle into
## the page's own place with the cards (the art doesn't move). The page is
## laid out now (its containers sorted at once) so nothing shows misplaced.
func _pin_page_header() -> void:
	if Motion.reduce or page.play_button == null:
		return
	_sort_now(page)
	var dy: float = page.play_button.get_global_rect().position.y - home.play_button.get_global_rect().position.y
	if absf(dy) < 1.0 or absf(dy) > 200.0:
		return
	var y: float = page.scroll.position.y
	Motion.enter(page.scroll, "position:y", y - dy, y, PAGE_IN_S, 0.0, Tween.TRANS_EXPO, Tween.EASE_OUT)


## Lay a freshly built tree out now instead of over the next deferred passes.
static func _sort_now(n: Node) -> void:
	if n is Container:
		n.notification(Container.NOTIFICATION_SORT_CHILDREN)
	for c in n.get_children():
		_sort_now(c)


## Home's hero shows this game right now, where the page's hero card goes.
func _page_shares_hero(game: Dictionary) -> bool:
	return current == "home" and home.visible and home.frame.is_visible_in_tree() \
		and str(home.spotlight_game.get("key", "-")) == str(game.get("key", ""))


func _close_page() -> void:
	if page == null:
		return
	var key: String = page.game.get("key", "")
	var leaving: Control = page
	page = null
	_link_top()
	var s: Control = screens[current]
	s.visible = true
	s.modulate.a = 1.0
	s.position = Vector2.ZERO
	s.scale = Vector2.ONE
	# The page drops its cards and fades over the screen, which is already
	# there and taking input; nothing on it can take focus on the way out.
	leaving.name = "GamePageLeaving"
	leaving.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Only its cards leave: its backdrop, hero, title and actions go at once,
	# so the screen under it (Home's own hero) shows straight away.
	for c in leaving.get_children():
		if c is CanvasItem and c != leaving.scroll:
			(c as CanvasItem).visible = false
	for c in [leaving.header, leaving.actions_row]:
		if c != null:
			c.modulate.a = 0.0
	leaving.set_process_input(false)
	leaving.set_process_unhandled_input(false)
	var out := Motion.to(leaving, "modulate:a", 0.0, PAGE_OUT_S, Tween.TRANS_CUBIC, Tween.EASE_IN)
	if out == null:
		leaving.queue_free()
	else:
		leaving.slide_cards(PAGE_CARDS_PX, PAGE_OUT_S, true)
		out.finished.connect(leaving.queue_free)
	# Land back on what opened the page, else its game's tile, else the default.
	var target: Control = null
	var back_to: Variant = _page_return
	_page_return = null
	if is_instance_valid(back_to) and back_to is Control and (back_to as Control).is_visible_in_tree() \
			and s.is_ancestor_of(back_to) and (back_to as Control).focus_mode != Control.FOCUS_NONE:
		target = back_to
	elif current == "home":
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
	if g.is_empty() and page != null and str(page.game.get("key", "")) != "":
		g = page.game   # not the Emulation page's stand-in when nothing is installed
	if g.is_empty():
		g = home.spotlight_game if not home.spotlight_game.is_empty() else home.hero_game
	quick_menu.open(g)
	read_pads(true)
	if wiring != null:
		wiring.menu_over_game(true)
	_sound("select")
	_update_timer()


func _on_menu_closed() -> void:
	if wiring != null:
		wiring.menu_over_game(false)
	_screen().focus_behavior_recursive = Control.FOCUS_BEHAVIOR_INHERITED
	top_bar.focus_behavior_recursive = Control.FOCUS_BEHAVIOR_INHERITED
	_update_timer()
	_sound("back")
	if page != null and page.get("form") != null:
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


func _decorated() -> Array:
	var list: Array = install_state.decorate(Library.games) if install_state != null else Library.games
	return Library.collections.decorate(list)


func _set_games(list: Array) -> void:
	if install_state != null:
		list = install_state.decorate(list)
	list = Library.collections.decorate(list)
	var names := {}
	for c in Library.collections.collections():
		names[c["id"]] = c["name"]
	library_screen.set_collection_names(names)
	home.set_games(list)
	library_screen.set_games(list)
	var fresh := View.newly_added(list, int(Time.get_unix_time_from_system()))
	top_bar.set_dot("library", fresh.any(func(g): return not _seen_new.has(g.get("key", ""))))
	var shown := View.not_hidden(list).size()
	top_bar.set_count("library", shown if shown > 0 else -1)


func _mark_new_seen() -> void:
	for g in View.newly_added(library_screen.games, int(Time.get_unix_time_from_system())):
		_seen_new[g.get("key", "")] = true
	top_bar.set_dot("library", false)


func _on_library_changed() -> void:
	_set_games(Library.games)
	if not playing.is_empty():
		var fresh := View.find_by_key(Library.games, playing["key"])
		playing = fresh
	if page != null and page.has_method("refresh_from"):
		page.refresh_from(Library.emulation, _decorated())
	elif page != null:
		var fresh_page := View.find_by_key(Library.games, page.game["key"])
		if fresh_page.is_empty():
			_close_page()
		else:
			page.update_game(Library.collections.decorate(install_state.decorate([fresh_page]))[0])
	_link_top()


# ------------------------------------------------------------ hint bar

func _on_focus_changed(f: Control) -> void:
	# Inside the quick menu the hint bar sits under its scrim (the sheet shows
	# its own prompts): no rebuilding it on every move there, nor on the menu's
	# first frame. Closing the menu puts focus back, which updates it.
	if not (quick_menu != null and quick_menu.visible and f != null and quick_menu.is_ancestor_of(f)):
		_update_hints(f)
	_sound("move")


func _update_hints(f: Control = null) -> void:
	if f == null:
		f = get_viewport().gui_get_focus_owner()
	var ctx := {"screen": current, "page": page != null, "kind": focus_kind(f), "label": f.text if f is Button else ""}
	var list := hints_for(ctx)
	var special := _special_hints(f)
	if not special.is_empty():
		list = special.duplicate()
		var has_guide := false
		for h in special:
			if h[0] is String and h[0] == "GUIDE":
				has_guide = true
		if not has_guide:
			list.append(["GUIDE", "Quick menu"])
	for c in hint_bar.get_children():
		hint_bar.remove_child(c)
		c.queue_free()
	hint_bar.add_child(Kit.prompts(list))


## Hints from whatever sits on top: a sheet, the Steam overlay, the downloads
## list, or the game page's own (achievement grid, Manage). [] = the usual.
func _special_hints(f: Control) -> Array:
	if low_dialog != null and is_instance_valid(low_dialog):
		return LowBatteryDialog.hints()
	if game_actions != null and game_actions.is_modal():
		return game_actions.modal_hints()
	if steam_overlay != null and steam_overlay.is_open():
		return [["A", TG.BACK_TO_COVE]]
	if _downloads_open():
		return downloads_view.hints_for_focus(f)
	if _apps_open():
		return apps_view.hints_for_focus(f)
	if page != null and page.has_method("hints_for_focus"):
		return page.hints_for_focus(f)
	if page == null and screens[current].has_method("hints"):
		var h: Variant = screens[current].hints(f)
		if h is Array:
			return h
	return []


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
		"tile":
			out.append(["A", "Open"])
			if not ctx.get("page", false):
				out.append(["MENU", "Options"])
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
			out.append(["VIEW", "Filter"])
			out.append([["LT", "RT"], "Jump"])
		if screen != "home":
			out.append(["B", "Home"])
		out.append([["LB", "RB"], "Sections"])
	out.append(["GUIDE", "Quick menu"])
	return out


func _style_hint_shade() -> void:
	var g := Gradient.new()
	var sc: Color = ThemeLib.color("scrim")
	g.colors = PackedColorArray([Color(sc, 0.0), Color(sc, 0.75)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 4
	t.height = 64
	t.fill_to = Vector2(0, 1)
	_hint_shade.texture = t
	# The band: dark glass with a hairline on top, the screen's edge margins.
	var band := ThemeLib.box(Color(ThemeLib.color("glass"), 0.72 if ThemeLib.is_dark() else 0.85), 0, ThemeLib.EDGE, 0)
	band.border_color = ThemeLib.color("line")
	band.border_width_top = 1
	hint_band.add_theme_stylebox_override("panel", band)


# ------------------------------------------------------------ settings

func _load_extra_prefs() -> void:
	var cfg := SettingsFile.load_cfg(UiPrefs.path)
	if true:
		menu_side = str(cfg.get_value("ui", "menu_side", "right"))
		ui_sounds = str(cfg.get_value("ui", "ui_sounds", "low"))


func _save_prefs() -> void:
	UiPrefs.save_prefs()
	SettingsFile.update_cfg(UiPrefs.path, func(cfg: ConfigFile):
		cfg.set_value("ui", "menu_side", menu_side)
		cfg.set_value("ui", "ui_sounds", ui_sounds))


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
	if settings.has_method("set_services"):
		settings.set_services({"device": Device, "power": Power, "library": Library, "discover": _svc("Discover"),
			"perf": _svc("PerfMonitor"), "achievements": _svc("Achievements"), "setup": _svc("Setup"),
			"updates": _svc("Updates"), "storage": _svc("Storage"), "controller": _svc("Controller"),
			"photo": _svc("DevicePhoto"), "saves": saves, "battery": battery_log,
			"game_running": func() -> bool: return session != null and session.is_active(), "recording": recording})


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
	# Settings built its category list again: the top bar's "down" pointed at a freed button
	_link_top()
