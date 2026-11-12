extends Control
## The quick menu: a glass sheet over the game (Guide / Quick Access or F1
## opens it, B / Esc closes it, LB / RB or Q / E switch tabs, Y opens the
## full settings for the tab). Tabs: This game, Power, Display, Audio,
## Controller, Device. Always opens on This game.
##
## Every setting is a Control (Controls autoload) drawn by control_list.gd /
## control_view.gd, so each shows only where this handheld supports it and
## says when a value comes from a profile, is being applied, or didn't take.
## The most used ones come first; everything else is one press away in
## Settings ("All settings", Y).
##
## This game: "Use settings for this game" (a per-game profile in Profiles),
## overlay, frame limit, TDP, Auto TDP, upscaler and frame generation, Reset
## this game, Record / Stop recording (the Recording service, when one is
## passed), how long you've played and Exit game (press twice).
##
## Above the rows, on every tab: the Shortcuts strip (scripts/ui/quick/
## shortcut_strip.gd, when an action runner is passed), one press each for the
## keyboard, a screenshot, recording, sending a key and so on.

const FocusScroll := preload("res://scripts/ui/focus_scroll.gd")
const FadeMask := preload("res://scripts/ui/fade_mask.gd")
const Kit := preload("res://scripts/ui/ui_kit.gd")
const Drawer := preload("res://scripts/ui/drawer.gd")
const Texts := preload("res://scripts/ui/texts.gd")
const TS := preload("res://scripts/ui/texts_settings.gd")
const TC := preload("res://scripts/ui/texts_controls.gd")
const TD := preload("res://scripts/ui/texts_device.gd")
const ChoiceRow := preload("res://scripts/ui/choice_row.gd")
const ActionRow := preload("res://scripts/ui/settings/action_row.gd")
const BgCommand := preload("res://scripts/ui/bg_command.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const CIcons := preload("res://scripts/ui/controls/cicons.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const Services := preload("res://scripts/ui/settings/services.gd")
const Model := preload("res://scripts/ui/controls/model.gd")
const ControlList := preload("res://scripts/ui/controls/control_list.gd")
const Catalog := preload("res://scripts/ui/controls/catalog.gd")
const SteamInput := preload("res://scripts/ui/controls/steam_input.gd")
const Shared := preload("res://scripts/ui/controls/shared.gd")
const ControlScript := preload("res://scripts/controls/control.gd")
const Caps := preload("res://scripts/device/capabilities.gd")
const BrandMark := preload("res://scripts/ui/brand_mark.gd")
const AppMixer := preload("res://scripts/ui/controls/app_mixer.gd")
const MediaCard := preload("res://scripts/ui/controls/media_card.gd")
const TX := preload("res://scripts/ui/texts_extras.gd")
const TL := preload("res://scripts/ui/texts_library.gd")
const ShortcutStrip := preload("res://scripts/ui/quick/shortcut_strip.gd")

signal closed
## A result worth a toast: text, tone (good / bad).
signal notice(text: String, tone: String)
## "Exit game" was confirmed for `game`. The host closes it (main.gd owns the
## running game); the button only shows while something listens.
signal exit_game_requested(game: Dictionary)
## "All settings" (Y, or a tab's last row): open Settings on `category`
## (texts_controls CATEGORY_GROUPS ids, "device"...) at `part` ("fixes", "").
## main.gd: connect it to close the menu, show Settings and call
## settings.open_category(category, part). Without a listener the menu does
## that itself through its parent's show_screen() / settings.
signal settings_requested(category: String, part: String)

const SECTIONS := TC.TABS
const SECTION_ICONS := TC.TAB_ICONS
const WIDTH := 580
## The sheet runs the full height: the scrim dims the top and hint bars, so
## the sheet's own battery pill and prompts are the only ones that read.
const TOP_INSET := Drawer.MARGIN
## How dark the full-screen scrim is (it covers the top bar and hint bar too).
const SCRIM_ALPHA := Drawer.SCRIM_ALPHA
const SUPPORT_TEXT := {
	"full": "Tested on hardware: the GameCove team runs it on this device.",
	"beta": "Beta: testers confirmed it works; we haven't tested it ourselves yet.",
	"partial": TS.QM_SUPPORT_PARTIAL,
	"generic": "Basic support: device-specific settings stay hidden until someone tests this device.",
}
const SESSION_SELECT := "/usr/bin/gamecove-session-select"
## Review M8: a session switch that hasn't taken GameCove away gave up or hung; the controller is
## handed back to GameCove's UI so Guide works again. Two waits (final review, session: one 20 s
## wait from the start was shorter than a slow switch, which first restores the everyday values,
## up to 40 s, then the root values and closes Steam, 10 s each):
##   SWITCH_LIMIT_S   from the start, for a gamecove-session-select that never comes back;
##   SWITCH_REARM_S   from the moment it finished without an error, for a logout that never came.
const SWITCH_LIMIT_S := 75.0
const SWITCH_REARM_S := 20.0

var device: Object
var power: Object
var launcher: Object
var gamescope: Object
## Optional: PerfMonitor, the running GameSession, InputPlumber (Controller).
var perf: Object
var session: Object
var controller: Object
## Controls and Profiles (autoloads or fakes) and the Fixes service.
var controls: Object
var profiles: Object
var fixes: Object
var model: Object
## The Recording service (scripts/system/recording.gd), or null: no Record row.
var recording: Object
## The action runner (scripts/actions/runner.gd), or null: no Shortcuts strip.
var actions: Object
## The Shortcuts strip above the rows (scripts/ui/quick/shortcut_strip.gd).
var strip: VBoxContainer

var section := 0
var game: Dictionary = {}
var tabs: Array[Button] = []
var body: VBoxContainer
var live_label: Label
var live_icon: TextureRect
var head_art: TextureRect
var head_title: Label
var head_caption: Label
var panel: PanelContainer
var dim: ColorRect
var prompts: HBoxContainer
## Which edge the panel floats against: "right" or "left" (Settings).
var side := "right"
var status_label: Label
## Runs the Steam session switch off the main thread; tests give it a fake runner.
var commands: Node
## Opens steam:// URIs (tests replace it).
var open_uri: Callable
var _parts: Array = []        # Controls (focusable) and ControlLists, top to bottom
var _focusables: Array = []
var _steam_armed := false
var _steam_button: Button
var _desktop_armed := false
var _desktop_button: Button
var _switch_rearm := false    # intercept was on before the switch released it
var _switch_gen := 0          # one per switch, so a late timer can't touch the next one
var _power_left := false      # Power was told a switch is under way (request_leave)
var _exit_armed := false
var _exit_button: Button
var _reset_armed := false
var _reset_row: VBoxContainer
var _session_key := ""
var _session_start_ms := 0
var _limit := {"cant_reach": false, "info": {}}


## services: {"device", "power", "launcher", "gamescope"} (the autoloads, or
## fakes in tests), optional "perf", "controller", "session", "controls",
## "profiles", "fixes" and "command_runner" (a fake for bg_command.gd).
## Controls and Profiles come from the autoloads when not passed.
## Favourites (scripts/library/collections.gd): This game's Favourite switch; null hides it.
var collections: RefCounted


func setup(services: Dictionary) -> void:
	name = "QuickMenu"
	commands = BgCommand.new()
	commands.name = "Commands"
	if services.has("command_runner"):
		commands.runner = services["command_runner"]
	add_child(commands)
	device = services.get("device")
	power = services.get("power")
	launcher = services.get("launcher")
	gamescope = services.get("gamescope")
	perf = services.get("perf")
	controller = services.get("controller")
	fixes = services.get("fixes")
	collections = services.get("collections")
	recording = services.get("recording")
	actions = services.get("actions")
	if recording != null and recording.has_signal("changed"):
		recording.changed.connect(_update_record_row)
	if services.has("session"):
		attach_session(services["session"])
	if services.has("controls"):
		use_controls(services["controls"], services.get("profiles"))
	if power != null:
		if power.has_signal("changed"):
			power.changed.connect(func(_st): if visible: refresh_live())
		if power.has_signal("autotune_limit"):
			power.autotune_limit.connect(_on_autotune_limit)
		if power.has_signal("autotune_changed"):
			power.autotune_changed.connect(func(_on): _update_autotune_line())
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false
	_build_frame()


## Points the menu at a Controls registry and Profiles (the autoloads, or
## fakes for tests and screenshots).
func use_controls(registry: Object, prof: Object = null) -> void:
	controls = registry
	profiles = prof
	model = Model.new()
	model.setup(controls, profiles)
	model.add_local(_autotune_control())
	if actions != null:
		actions.model = model


func _build_frame() -> void:
	dim = ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(0, 0, 0, SCRIM_ALPHA)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed:
			close())
	add_child(dim)

	panel = PanelContainer.new()
	panel.name = "Panel"
	panel.theme_type_variation = "GlassPanel"
	add_child(panel)
	_place_panel()
	var col := Kit.vbox(12)
	panel.add_child(col)

	var head := Kit.hbox(14)
	head_art = TextureRect.new()
	head_art.name = "HeadArt"
	head_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	head_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	head_art.custom_minimum_size = Vector2(38, 50)
	head_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head_art.visible = false
	head.add_child(head_art)
	var titles := Kit.vbox(2)
	titles.alignment = BoxContainer.ALIGNMENT_CENTER
	head_title = Kit.label(TC.QM_TITLE, "HeaderLabel")
	head_title.name = "HeadTitle"
	head_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	head_title.add_theme_font_size_override("font_size", ThemeLib.SIZE_LEAD)
	titles.add_child(head_title)
	head_caption = Kit.label("", "MicroLabel")
	head_caption.name = "HeadCaption"
	head_caption.visible = false
	titles.add_child(head_caption)
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(titles)
	var live_pill := PanelContainer.new()
	live_pill.name = "LivePill"
	live_pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	live_pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var live_row := Kit.hbox(6)
	live_pill.add_child(live_row)
	live_icon = TextureRect.new()
	live_icon.name = "LiveIcon"
	live_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	live_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	live_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	live_row.add_child(live_icon)
	live_label = Kit.label("", "MonoLabel")
	live_label.name = "Live"
	live_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	live_label.size_flags_vertical = Control.SIZE_FILL
	live_row.add_child(live_label)
	head.add_child(live_pill)
	col.add_child(head)

	# Tabs: icons in a track; the open one is filled and shows its name.
	var tab_row := Kit.hbox(2)
	tab_row.name = "Tabs"
	var tab_track := PanelContainer.new()
	tab_track.name = "TabTrack"
	tab_track.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_track.add_child(tab_row)
	for i in SECTIONS.size():
		var t := Kit.button("", "SectionTab")
		t.name = "Tab%d" % i
		t.toggle_mode = true
		t.custom_minimum_size = Vector2(44, 38)
		t.tooltip_text = SECTIONS[i]
		t.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		t.pressed.connect(show_section.bind(i))
		tab_row.add_child(t)
		tabs.append(t)
	Kit.link_horizontal(tabs)
	for t in tabs:
		t.focus_neighbor_top = t.get_path_to(t)
	var tabs_line := Kit.hbox(8)
	tabs_line.add_child(Kit.glyph("LB"))
	tabs_line.add_child(tab_track)
	tabs_line.add_child(Kit.glyph("RB"))
	col.add_child(tabs_line)
	if actions != null:
		strip = ShortcutStrip.new()
		strip.setup(actions, self)
		strip.relinked.connect(_link_strip)
		col.add_child(strip)
	var rule := ColorRect.new()
	rule.name = "Rule"
	rule.custom_minimum_size = Vector2(0, 1)
	rule.color = ThemeLib.color("line")
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(rule)

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	_scroll = scroll
	FocusScroll.attach(scroll)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)
	# A 20 px alpha fade at the foot: the next card's top edge never pokes
	# out above the prompts.
	scroll_mask = FadeMask.wrap(scroll, 20.0)
	# A card only a sliver of which shows is cut off whole instead of faded.
	scroll_mask.cut_fn = _cut_cards
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side_name in ["left", "right"]:
		pad.add_theme_constant_override("margin_" + side_name, 8)
	for side_name in ["top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side_name, 10)
	scroll.add_child(pad)
	# This game's rows live in their own box, kept (hidden) while another tab
	# shows or the menu is closed; the other tabs share one box, built each time.
	var bodies := Kit.vbox(0)
	bodies.name = "Bodies"
	bodies.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_child(bodies)
	_game_body = Kit.vbox(8)
	_game_body.name = "GameBody"
	_game_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_game_body.visible = false
	bodies.add_child(_game_body)
	_tab_body = Kit.vbox(8)
	_tab_body.name = "Body"
	_tab_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bodies.add_child(_tab_body)
	body = _tab_body

	status_label = Kit.label("", "AccentLabel", true)
	status_label.name = "Status"
	col.add_child(status_label)
	_set_prompts(["LR", "Change"])
	col.add_child(prompts)
	_style_head()


## "right" (default) or "left": which edge the panel floats against.
func set_side(s: String) -> void:
	side = "left" if s == "left" else "right"
	if panel != null:
		_place_panel()


func _place_panel() -> void:
	Drawer.place(panel, WIDTH, side)


# ------------------------------------------------------------ open / close

## `for_game` is the game "This game" is about ({} for none).
func open(for_game: Dictionary) -> void:
	game = for_game
	var found := Services.from_tree(self)
	if perf == null:
		perf = found.get("perf")
	if model == null and found.has("controls"):
		use_controls(found["controls"], found.get("profiles"))
	if fixes == null:
		fixes = Shared.fixes(self)
	if model != null:
		model.set_game(game)
	visible = true
	_set_header(for_game)
	_animate_in()
	if strip != null:
		strip.refresh()
	if gamescope != null:
		gamescope.set_overlay(true)
	show_section(0, "", true)
	refresh_live()
	var vp := get_viewport()
	if vp != null and not vp.gui_focus_changed.is_connected(_on_focus_changed):
		vp.gui_focus_changed.connect(_on_focus_changed)
	_on_focus_changed(vp.gui_get_focus_owner() if vp != null else null)


## The prompts' last item says what changes the focused row: left / right on a
## slider or stepper, A on a switch or segmented row (only on a focus change).
var _change_prompt: Array = []


func _set_prompts(change: Array) -> void:
	_change_prompt = change
	var old := prompts
	prompts = Kit.prompts([["B", "Close"], [["LB", "RB"], "Tabs"], ["Y", TC.ALL_SETTINGS], change])
	prompts.name = "Prompts"
	if old != null and old.get_parent() != null:
		var at := old.get_index()
		var parent := old.get_parent()
		parent.remove_child(old)
		old.queue_free()
		parent.add_child(prompts)
		parent.move_child(prompts, at)


func _on_focus_changed(f: Control) -> void:
	if not visible or f == null or not is_ancestor_of(f):
		return
	var want := Kit.change_hint(f)
	if want != _change_prompt:
		_set_prompts(want)


func close() -> void:
	if not visible:
		return
	var vp := get_viewport()
	if vp != null and vp.gui_focus_changed.is_connected(_on_focus_changed):
		vp.gui_focus_changed.disconnect(_on_focus_changed)
	if strip != null:
		strip.close_sheet()
	visible = false
	if gamescope != null:
		gamescope.set_overlay(false)
	closed.emit()


## Slim header: the game's mini cover and title when there is one.
func _set_header(g: Dictionary) -> void:
	var rule := panel.find_child("Rule", true, false) as ColorRect
	if rule != null:
		rule.color = ThemeLib.color("line")
	var a: Variant = g.get("art", {})
	var cover: String = a.get("cover", "") if a is Dictionary else ""
	var AC = load("res://scripts/ui/art_cache.gd")
	var tex: Texture2D = AC.cached("cover", cover) if cover != "" else null
	head_art.texture = tex
	head_art.visible = tex != null
	# Not on screen anywhere yet (Home no longer repeats the spotlight game in
	# its rows): load it off the main thread and show it when it lands.
	if tex == null and AC.usable(cover):
		var want := cover
		AC.request("cover", cover, func(t):
			if is_instance_valid(head_art) and t != null and str(game.get("art", {}).get("cover", "")) == want:
				head_art.texture = t
				head_art.visible = true, self)
	head_caption.visible = not g.is_empty()
	var secs := session_seconds()
	head_caption.text = (TS.QM_SESSION % TS.session_time(secs).to_lower()) if secs >= 60 else TC.QM_TITLE
	if model != null and not g.is_empty() and model.per_game():
		head_caption.text += "  ·  " + TC.OWN_SETTINGS
	head_title.text = g.get("title", TC.QM_TITLE) if not g.is_empty() else TC.QM_TITLE
	_style_head()


func _style_head() -> void:
	# Near-opaque glass: the hint bar and shelves mustn't ghost through the rows.
	panel.add_theme_stylebox_override("panel", Drawer.glass())
	var lp := panel.find_child("LivePill", true, false) as PanelContainer
	if lp != null:
		lp.add_theme_stylebox_override("panel", ThemeLib.pill(ThemeLib.color("accent", 0.08), ThemeLib.color("accent", 0.35), 12, 5))
		live_label.add_theme_color_override("font_color", ThemeLib.color("accent"))
		live_label.add_theme_font_override("font", ThemeLib.mono(true, 1))
	var tt := panel.find_child("TabTrack", true, false) as PanelContainer
	if tt != null:
		var sb := ThemeLib.box(ThemeLib.soft(0.04), ThemeLib.radius("m"), 5, 5)
		sb.border_color = ThemeLib.color("line")
		sb.set_border_width_all(1)
		tt.add_theme_stylebox_override("panel", sb)


func _style_tabs() -> void:
	for t in tabs.size():
		var on := t == section
		tabs[t].set_pressed_no_signal(on)
		tabs[t].text = SECTIONS[t] if on else ""
		tabs[t].size_flags_stretch_ratio = 3.2 if on else 1.0
		tabs[t].icon_alignment = HORIZONTAL_ALIGNMENT_LEFT if on else HORIZONTAL_ALIGNMENT_CENTER
		var col: Color = ThemeLib.color("accent") if on else ThemeLib.color("text_2")
		tabs[t].icon = CIcons.tex(SECTION_ICONS[t], 20, col)


func _animate_in() -> void:
	dim.color = Drawer.scrim()
	dim.modulate.a = 0.0
	Motion.to(dim, "modulate:a", 1.0, Motion.FAST)
	var dx := Motion.slide(40.0) * (1.0 if side == "right" else -1.0)
	panel.modulate.a = 0.0
	_place_panel()
	var base_left := panel.offset_left
	var base_right := panel.offset_right
	panel.offset_left = base_left + dx
	panel.offset_right = base_right + dx
	Motion.to(panel, "modulate:a", 1.0, Motion.FAST)
	Motion.to(panel, "offset_left", base_left, Motion.BASE)
	Motion.to(panel, "offset_right", base_right, Motion.BASE)


func _unhandled_input(event: InputEvent) -> void:
	if not visible or (strip != null and strip.sheet_open()):
		return
	if event.is_action_pressed("ui_cancel"):
		close()
	elif _is_shoulder(event, JOY_BUTTON_LEFT_SHOULDER, KEY_Q):
		switch_tab(-1)
	elif _is_shoulder(event, JOY_BUTTON_RIGHT_SHOULDER, KEY_E):
		switch_tab(1)
	elif _is_shoulder(event, JOY_BUTTON_Y, KEY_Y):
		open_all_settings()
	else:
		return
	if get_viewport() != null:
		get_viewport().set_input_as_handled()


static func _is_shoulder(event: InputEvent, button: JoyButton, key: Key) -> bool:
	if event is InputEventJoypadButton:
		return event.pressed and event.button_index == button
	if event is InputEventKey:
		return event.pressed and not event.echo and event.keycode == key
	return false


# ------------------------------------------------------------ tabs

var _scroll: ScrollContainer
var scroll_mask: TextureRect
## A tab's cards fade in this fast when LB / RB switch tabs.
const TAB_FADE_S := 0.14


## LB / RB: the next tab, its cards fading in (every tab the same; opening
## the menu doesn't, the panel's own slide is the motion there).
func switch_tab(d: int) -> void:
	_switching = true
	show_section(posmod(section + d, SECTIONS.size()), "", true)
	_switching = false


var _switching := false


## `reuse`: This game may come back as it was last built when nothing it's
## built from changed (opening the menu, LB / RB); a plain call builds afresh.
func show_section(i: int, keep_focus := "", reuse := false) -> void:
	var switching := _switching and is_inside_tree()
	section = i
	status_label.text = ""
	_exit_armed = false
	_exit_button = null
	_steam_armed = false
	_steam_button = null
	_desktop_armed = false
	_desktop_button = null
	_reset_armed = false
	_reset_row = null
	_record = null
	_style_tabs()
	var tab: String = TC.TAB_IDS[i]
	_free_rows(_tab_body)
	_parts.clear()
	_game_body.visible = tab == "game"
	_tab_body.visible = tab != "game"
	body = _game_body if tab == "game" else _tab_body
	if not (reuse and tab == "game" and _reuse_game_tab()):
		if tab == "game":
			_free_rows(_game_body)
			_game_sig = ""
		if model == null:
			_line(TC.NO_CONTROLS, "QuietLabel", "NoControls")
		match tab:
			"game": _build_game()
			"power": _build_power()
			"display": _build_list("display")
			"audio": _build_audio()
			"controller": _build_controller()
			"device": _build_device()
		if tab == "game":
			_keep_game_tab()
	_relink()
	if switching:
		Motion.enter(body, "modulate:a", 0.0, 1.0, TAB_FADE_S, 0.0, Tween.TRANS_SINE, Tween.EASE_OUT)
	else:
		Motion.to(body, "modulate:a", 1.0, 0.0)
	# A new tab opens at its top (the old tab's scroll would carry over).
	if _scroll != null:
		_scroll.scroll_vertical = 0
	if is_visible_in_tree():
		focus_target(keep_focus).grab_focus()


# ------------------------------------------------------------ This game, kept

## Opening the menu over a game must feel instant, so This game (the tab it
## always opens on) isn't built again on every press: its rows stay in their
## own box, hidden while another tab shows or the menu is closed, and the next
## open shows them again as long as nothing they're built from changed
## (_game_tab_sig). Hidden, they do no work: a control row that hears of a
## change only notes it and reads the value again when it's shown
## (control_view.gd). main.gd builds it once when a game starts (prepare), so
## the first press over the game is quick too.
var _game_body: VBoxContainer
var _tab_body: VBoxContainer
var _game_sig := ""          # what This game was built from ("" = not built)
var _game_kept := {}         # This game's parts, exit, reset and record rows


## Everything This game's rows are built from (values the rows read
## themselves when they're shown are left out).
func _game_tab_sig() -> String:
	var key := str(game.get("key", ""))
	var on := model != null and not game.is_empty()
	return var_to_str([key, str(game.get("title", "")), game.is_empty(), model != null,
		model.per_game() if on else false, model.editing_profile() if on else false,
		bool(collections.is_favourite(key)) if collections != null and key != "" else false,
		session_seconds() >= 0, exit_game_requested.get_connections().size(),
		recording != null, power != null and power.has_method("autotune_active"),
		ThemeLib.theme_id, ThemeLib.tokens.hash()])   # rows bake theme colours (a theme switch rebuilds)


func _free_rows(box: VBoxContainer) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()


func _keep_game_tab() -> void:
	_game_sig = _game_tab_sig()
	_game_kept = {"parts": _parts.duplicate(), "exit": _exit_button, "reset": _reset_row, "record": _record}


## Shows the kept This game when it's still right; false = build it.
func _reuse_game_tab() -> bool:
	if _game_sig == "" or _game_sig != _game_tab_sig() or _game_body.get_child_count() == 0:
		return false
	var k := _game_kept
	_parts = (k.get("parts", []) as Array).filter(func(p): return is_instance_valid(p))
	_exit_button = k.get("exit") if is_instance_valid(k.get("exit")) else null
	_reset_row = k.get("reset") if is_instance_valid(k.get("reset")) else null
	_record = k.get("record") if is_instance_valid(k.get("record")) else null
	# what changes between opens without changing the rows
	if _exit_button != null:
		_exit_button.text = TS.QM_EXIT
	if _reset_row != null:
		_reset_row.title_label.text = TC.RESET_GAME
	var st := body.get_node_or_null("SessionTime") as Label
	var secs := session_seconds()
	if st != null and secs >= 0:
		st.text = TS.QM_SESSION % TS.session_time(secs).to_lower() if secs >= 60 else TS.session_time(secs)
	_update_autotune_line()
	_update_record_row()
	return true


## Builds This game for `for_game` out of sight, or brings the kept one up to
## date, so a press of the quick menu over the game only has to show it.
## main.gd calls it when a game starts and when its window takes the screen
## (one-time work then; nothing of it runs while the game plays).
func prepare(for_game: Dictionary) -> void:
	if visible or body == null:
		return
	game = for_game
	if model == null:
		var found := Services.from_tree(self)
		if found.has("controls"):
			use_controls(found["controls"], found.get("profiles"))
	if model != null:
		model.set_game(game, false)   # main.gd has Controls detect again for the game already
	show_section(0, "", true)
	# Rows that heard of a change while hidden (Controls detecting for the
	# game, its profile applied) read it now rather than on the first press.
	_catch_up(_game_body)
	# Shape every label's text now (a Label shapes on its first size query),
	# so the first press doesn't pay for it; line breaks at the real width are
	# all that's left for its first frame.
	_shape_text(_game_body)


static func _catch_up(n: Node) -> void:
	for c in n.get_children():
		if c.has_method("catch_up"):
			c.catch_up()
		_catch_up(c)


static func _shape_text(n: Node) -> void:
	for c in n.get_children():
		if c is Control:
			(c as Control).get_combined_minimum_size()
		_shape_text(c)


## The current tab's focus chain, top to bottom.
func _relink() -> void:
	_focusables.clear()
	for p in _parts:
		if not is_instance_valid(p):
			continue
		if "button" in p and p.button != null:
			_focusables.append(p.button)
		elif p.has_method("focusables"):
			_focusables.append_array(p.focusables())
		elif p is Control:
			_focusables.append(p)
	_focusables = _focusables.filter(func(f): return is_instance_valid(f))
	Kit.link_vertical(_focusables, tabs[section])
	for t in tabs:
		t.focus_neighbor_bottom = t.get_path_to(_focusables[0] if not _focusables.is_empty() else t)
	_link_strip()


## The Shortcuts strip sits between the tabs and the rows: Up from the first
## row lands on it, Up again on the open tab.
func _link_strip() -> void:
	if strip == null or strip.entry() == null:
		return
	var first: Control = _focusables[0] if not _focusables.is_empty() else null
	strip.link(tabs[section], first)
	var into: Control = strip.entry()
	if first != null:
		first.focus_neighbor_top = first.get_path_to(into)
	for t in tabs:
		t.focus_neighbor_bottom = t.get_path_to(into)


## Where focus goes in the current tab: the setting called `keep` (after a
## rebuild), else the first control, else the tab.
func focus_target(keep := "") -> Control:
	if keep != "":
		for f in _focusables:
			var n: Node = f
			while n != null and n != body:
				if String(n.name) == keep or ("key" in n and str(n.get("key")) == keep):
					return f
				n = n.get_parent()
	return _focusables[0] if not _focusables.is_empty() else tabs[section]


func focusables() -> Array:
	return _focusables


## The cards in the drawer, a control list's rows one by one (for the foot
## mask's cut).
func _cut_cards() -> Array:
	var out: Array = []
	if not is_instance_valid(body):
		return out
	for c in body.get_children():
		if c is ControlList:
			out.append_array(c.get_children())
		else:
			out.append(c)
	return out


func _add(c: Control) -> Control:
	body.add_child(c)
	_parts.append(c)
	return c


func _line(text: String, variation := "", node_name := "") -> Label:
	var l := Kit.label(text, variation, true)
	if node_name != "":
		l.name = node_name
	body.add_child(l)
	return l


func _section_label(text: String, node_name := "") -> void:
	var l := Kit.micro(text)
	l.add_theme_color_override("font_color", ThemeLib.color("text_3"))
	if node_name != "":
		l.name = node_name
	body.add_child(l)


## A list of the tab's quick controls; only what this handheld can use.
func _list(ids: Array, list_name := "List") -> VBoxContainer:
	var l: VBoxContainer = ControlList.new()
	l.setup(model, ids, [], {"hide_unavailable": true, "titles": Catalog.SHORT_TITLES, "icons": Catalog.ICONS,
		"name": list_name, "dialog_host": self})
	l.rebuilt.connect(_relink)
	_add(l)
	return l


func _build_list(tab: String) -> void:
	if model == null:
		return
	var l := _list(Catalog.QUICK[tab])
	if l.focusables().is_empty():
		_line(TC.NOTHING_HERE, "QuietLabel", "Nothing")
	_all_link(tab)


## Audio: the quick sound controls, what's playing in the background, then
## each app's own volume.
func _build_audio() -> void:
	if model == null:
		return
	var l := _list(Catalog.QUICK["audio"])
	var media: PanelContainer = MediaCard.new()
	media.setup(controls)
	media.rebuilt.connect(_relink)
	media.failed.connect(func(t: String): status_label.text = t)
	_add(media)
	var mixer: VBoxContainer = AppMixer.new()
	mixer.setup(controls)
	mixer.rebuilt.connect(_relink)
	mixer.failed.connect(func(t: String): status_label.text = t)
	_add(mixer)
	if l.focusables().is_empty() and mixer.focusables().is_empty():
		_line(TC.NOTHING_HERE, "QuietLabel", "Nothing")
	_all_link("audio")


## The last row of a tab: "All power settings ›".
func _all_link(tab: String) -> void:
	var cat: String = TC.TAB_CATEGORY.get(tab, "")
	if cat == "":
		return
	var r: VBoxContainer = ActionRow.new()
	var title: String = TC.ALL_IN % str(TC.CATEGORY_NAMES[cat]).to_lower() if TC.CATEGORY_NAMES.has(cat) else TC.ALL_SETTINGS
	r.setup("AllSettings", title, "", "", "settings")
	r.pressed.connect(open_all_settings)
	_add(r)


## Y / the last row: Settings on the category for this tab.
func open_all_settings(part := "") -> void:
	var cat: String = TC.TAB_CATEGORY.get(TC.TAB_IDS[section], "power")
	request_settings(cat, part)


func request_settings(cat: String, part := "") -> void:
	if not settings_requested.get_connections().is_empty():
		settings_requested.emit(cat, part)
		close()
		return
	# Fallback until the host connects settings_requested: its own screens.
	var host := get_parent()
	close()
	if host != null and host.has_method("show_screen") and "settings" in host and host.settings != null:
		host.show_screen("settings")
		if host.settings.has_method("open_category"):
			host.settings.open_category(cat, part)


# ------------------------------------------------------------ This game

func _build_game() -> void:
	if game.is_empty():
		var empty := Kit.vbox(8)
		empty.name = "NoGame"
		empty.add_child(CIcons.rect("game", 40, ThemeLib.color("text_3")))
		empty.add_child(Kit.label(TC.NO_GAME, "HeaderLabel"))
		empty.add_child(Kit.label(TC.NO_GAME_LINE, "QuietLabel", true))
		body.add_child(empty)
		_record_row()
		_build_session()
		return
	if model == null:
		_record_row()
		_build_session()
		return
	var per: bool = model.per_game()
	var title := str(game.get("title", ""))
	var use: VBoxContainer = ChoiceRow.bool_row("UseGame", TC.USE_GAME, per, "")
	use.set_explainer(func(v): return TC.USE_GAME_ON % title if v else TC.USE_GAME_OFF)
	use.collapse_hint = false
	use.changed.connect(func(v):
		model.set_per_game(bool(v))
		_set_header(game)
		show_section(0, "UseGame"))
	_style_use_row(use, per)
	_add(use)
	if per and model.editing_profile():
		var n := SKitNote.make(TC.USE_GAME_EDIT, "info")
		body.add_child(n)
	_list(Catalog.QUICK["game"])
	_favourite_row()
	_autotune_line()
	if per:
		_reset_row = ActionRow.new()
		_reset_row.setup("ResetGame", TC.RESET_GAME, "", TC.RESET_GAME_LINE, "reset", false)
		_reset_row.pressed.connect(_on_reset_pressed)
		_reset_row.button.focus_exited.connect(_disarm_reset)
		_add(_reset_row)
	_record_row()
	_all_link("game")
	_build_session()


## "Favourite": puts the game on Home's Favourites shelf (any store, emulated games too).
func _favourite_row() -> void:
	if collections == null or str(game.get("key", "")) == "":
		return
	var key := str(game["key"])
	var fav := ChoiceRow.bool_row("Favourite", TL.QM_FAVOURITE, bool(collections.is_favourite(key)), "")
	fav.set_explainer(func(v): return TL.QM_FAVOURITE_ON if v else TL.QM_FAVOURITE_OFF)
	fav.changed.connect(func(v): collections.set_favourite(key, bool(v)))
	_add(fav)


## The per-game switch reads as the tab's headline: a tinted card when on.
func _style_use_row(r: VBoxContainer, on: bool) -> void:
	r.title_label.add_theme_font_override("font", ThemeLib.font("semibold"))
	if on:
		# A quiet tint of the accent (the switch and tab bar's colour), not
		# the violet gradient that read as a second theme.
		var acc := ThemeLib.color("accent")
		var sb := ThemeLib.box(Color(acc, 0.06) if ThemeLib.is_dark() else Color(acc, 0.08), ThemeLib.radius("m"), 18, 10)
		sb.border_color = Color(acc, 0.25)
		sb.set_border_width_all(1)
		r.card_box = sb
		r.button.add_theme_stylebox_override("normal", sb)
		r.button.add_theme_stylebox_override("hover", sb)
		r._refresh_focus()


func _on_reset_pressed() -> void:
	if not _reset_armed:
		_reset_armed = true
		_reset_row.title_label.text = TC.RESET_CONFIRM
		return
	_reset_armed = false
	model.reset_game()
	status_label.text = TC.RESET_DONE % str(game.get("title", ""))
	show_section(0, "UseGame")
	status_label.text = TC.RESET_DONE % str(game.get("title", ""))


func _disarm_reset() -> void:
	if _reset_armed and _reset_row != null and is_instance_valid(_reset_row):
		_reset_armed = false
		_reset_row.title_label.text = TC.RESET_GAME


## Auto TDP for this game: Launcher's goal says whether it runs (Longest
## battery / Balanced do, Smoothest doesn't); while the game runs, Power
## starts or stops it at once.
func _autotune_control() -> RefCounted:
	return ControlScript.make({"id": "power.autotune", "group": "power", "kind": "toggle", "title": TC.AUTO_TDP,
			"help": TC.AUTO_TDP_HELP, "per_game": false},
		func(_c):
			if launcher == null or not launcher.has_method("auto_tdp_for") or power == null or not power.has_method("request_autotune"):
				return "Not available"
			if str(game.get("key", "")) == "":
				return "Pick a game first"
			if model != null and model.has("power.tdp") and not bool(model.describe("power.tdp").get("available", false)):
				return "Needs a TDP control"
			return "",
		func(_c): return bool(launcher.auto_tdp_for(str(game.get("key", "")))),
		func(_c, v):
			var key := str(game.get("key", ""))
			launcher.save_settings(key, {"goal": "balanced" if v else "smooth"})
			if _session_key == key:
				power.request_autotune(bool(v), key)
			return true)


func _on_autotune_limit(cant_reach: bool, info: Dictionary) -> void:
	_limit = {"cant_reach": cant_reach, "info": info}
	_update_autotune_line()


## While Auto TDP runs and can't hold the frame rate: what to do about it.
func _autotune_line() -> void:
	if power == null or not power.has_method("autotune_active"):
		return
	var l := Kit.label("", "QuietLabel", true)
	l.name = "AutoTdpLimit"
	l.add_theme_color_override("font_color", ThemeLib.tone("warn"))
	body.add_child(l)
	_update_autotune_line()


func _update_autotune_line() -> void:
	var l := body.get_node_or_null("AutoTdpLimit") as Label if body != null else null
	if l == null:
		return
	var text := ""
	if power.autotune_active():
		var info: Dictionary = _limit["info"]
		var cant: bool = _limit["cant_reach"]
		if info.is_empty() and power.has_method("autotune_limit_info"):
			info = power.autotune_limit_info()
			cant = bool(info.get("cant_reach", false))
		text = TS.autotune_line(cant, info)
	l.text = text
	l.visible = text != ""


# ------------------------------------------------------------ recording

var _record: VBoxContainer


## Record / Stop recording / Set up recording, by what the Recording service says.
func _record_row() -> void:
	_record = null
	if recording == null or not recording.has_method("row_state"):
		return
	_record = ActionRow.new()
	_record.setup("Record", TX.REC_START, "", "", "record", false)
	_record.pressed.connect(_on_record_pressed)
	_add(_record)
	_update_record_row()


func _update_record_row() -> void:
	if _record == null or not is_instance_valid(_record) or recording == null:
		return
	var st: String = recording.row_state()
	match st:
		"record":
			_record.title_label.text = TX.REC_START
			_record.set_value("")
			_record.set_hint(TX.REC_START_HINT)
		"stop":
			_record.title_label.text = TX.REC_STOP
			_record.set_value("● " + recording.clock(recording.elapsed_s()), "bad")
			_record.set_hint(TX.REC_STOP_HINT)
		"busy":
			_record.title_label.text = TX.REC_STOP if recording.state == "stopping" else TX.REC_START
			_record.set_value(TX.REC_SAVING if recording.state == "stopping" else TX.REC_STARTING, "muted")
			_record.set_hint("")
		"set_up":
			_record.title_label.text = TX.REC_SET_UP
			_record.set_value("")
			_record.set_hint(TX.REC_SET_UP_HINT)


func _on_record_pressed() -> void:
	match recording.row_state():
		"record":
			if recording.start(game if session_seconds() >= 0 else {}):
				notice.emit(TX.REC_STARTED, "good")
				close()
		"stop":
			recording.stop()
		"set_up":
			request_settings("media", "")


# ------------------------------------------------------------ running game

## Follows the host's GameSession for "Playing for" and Exit game.
## main.gd: quick_menu.attach_session(session) after making it.
func attach_session(s: Object) -> void:
	session = s
	if s == null:
		return
	if s.has_signal("started"):
		s.started.connect(func(g: Dictionary):
			_session_key = str(g.get("key", ""))
			_session_start_ms = Time.get_ticks_msec())
	if s.has_signal("ended"):
		s.ended.connect(func(_g):
			_session_key = ""
			_session_start_ms = 0)
	if s.has_method("is_active") and s.is_active() and "game" in s:
		_session_key = str(s.game.get("key", ""))
		_session_start_ms = Time.get_ticks_msec()


## Seconds the open game has run this session, or -1 if it isn't running.
func session_seconds() -> int:
	if _session_key == "" or _session_key != str(game.get("key", "")):
		return -1
	return int((Time.get_ticks_msec() - _session_start_ms) / 1000)


func _build_session() -> void:
	var secs := session_seconds()
	if secs < 0:
		return
	_line(TS.QM_SESSION % TS.session_time(secs).to_lower() if secs >= 60 else TS.session_time(secs), "AccentLabel", "SessionTime")
	if exit_game_requested.get_connections().is_empty():
		return
	var box := Kit.vbox(4)
	box.name = "ExitGame"
	_exit_button = Kit.button(TS.QM_EXIT)
	_exit_button.name = "Button"
	_exit_button.icon = Icons.tex("power", 22, ThemeLib.color("text"))
	_exit_button.custom_minimum_size = Vector2(0, 54)
	_exit_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_exit_button.pressed.connect(_on_exit_pressed)
	_exit_button.focus_exited.connect(_disarm_exit)
	box.add_child(_exit_button)
	body.add_child(box)
	_parts.append(_exit_button)


func _on_exit_pressed() -> void:
	if not _exit_armed:
		_exit_armed = true
		_exit_button.text = TS.QM_EXIT_CONFIRM
		status_label.text = TS.QM_EXIT_LINE
		return
	_exit_armed = false
	status_label.text = TS.QM_EXITING
	exit_game_requested.emit(game)
	close()


func _disarm_exit() -> void:
	if not _exit_armed or _exit_button == null:
		return
	_exit_armed = false
	_exit_button.text = TS.QM_EXIT
	status_label.text = ""


# ------------------------------------------------------------ Power

func _build_power() -> void:
	var strip := _live_strip()
	if strip.get_child_count() > 0:
		body.add_child(strip)
	else:
		strip.free()
	if model == null:
		return
	_list(Catalog.QUICK["power"])
	_autotune_line()
	_all_link("power")


## Live numbers at the top of Power: battery, draw, TDP (mono tiles).
func _live_strip() -> HBoxContainer:
	var row := Kit.hbox(8)
	row.name = "PowerLive"
	for k in _live_keys():
		var p := PanelContainer.new()
		p.name = "Stat_" + k
		p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sb := ThemeLib.box(ThemeLib.soft(0.05), ThemeLib.radius("m"), 14, 8)
		sb.border_color = ThemeLib.color("line")
		sb.set_border_width_all(1)
		p.add_theme_stylebox_override("panel", sb)
		var c := Kit.vbox(0)
		c.name = "Col"
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var t := Kit.micro({"battery": "Battery", "draw": "Drawing", "tdp": "TDP"}[k])
		t.add_theme_color_override("font_color", ThemeLib.color("text_3"))
		c.add_child(t)
		var v := Kit.label("—")
		v.name = "Value"
		v.add_theme_font_override("font", ThemeLib.mono(true, 0))
		v.add_theme_font_size_override("font_size", ThemeLib.SIZE_LEAD)
		c.add_child(v)
		p.add_child(c)
		row.add_child(p)
	_fill_strip(row)
	return row


## Which live tiles this device has. No battery (a Steam Machine, a mini PC) means
## no Battery and no Drawing tile; TDP stays only where the power service offers it.
func _live_keys() -> Array[String]:
	var has_bat: bool = device == null or not device.has_method("has_battery") or device.has_battery()
	if has_bat:
		return ["battery", "draw", "tdp"]
	var tdp: Dictionary = model.describe("power.tdp") if model != null else {}
	return ["tdp"] if bool(tdp.get("available", false)) else []


func _fill_strip(row: Node) -> void:
	var b: Dictionary = device.battery() if device != null and device.has_method("battery") else {}
	var pct := int(b.get("percent", -1))
	var st := str(b.get("status", ""))
	var v := row.get_node_or_null("Stat_battery/Col/Value") as Label
	if v != null:
		v.text = ("%d%%" % pct + (" ⚡" if st in ["Charging", "Full"] else "")) if pct >= 0 else "—"
	v = row.get_node_or_null("Stat_draw/Col/Value") as Label
	if v != null:
		v.text = "%.1f W" % float(b["watts"]) if float(b.get("watts", -1.0)) >= 0.0 else "—"
	v = row.get_node_or_null("Stat_tdp/Col/Value") as Label
	if v != null:
		var tdp: Dictionary = model.describe("power.tdp") if model != null else {}
		v.text = Model.value_label(tdp) if bool(tdp.get("available", false)) else "—"


## Called every few seconds by main while the menu is open.
func refresh_live() -> void:
	var b: Dictionary = device.battery() if device != null and device.has_method("battery") else {}
	live_label.text = _battery_text(b).replace("   ·   ", " · ")
	var pct := int(b.get("percent", -1))
	live_icon.visible = pct >= 0
	if pct >= 0:
		var charging: bool = b.get("status", "") in ["Charging", "Full"]
		live_icon.texture = Icons.battery(pct, charging, 22, ThemeLib.color("text"), ThemeLib.color("good") if charging else ThemeLib.color("text"))
	var strip := body.get_node_or_null("PowerLive")
	if strip != null:
		_fill_strip(strip)
	_update_record_row()


static func _battery_text(b: Dictionary, long := false) -> String:
	var parts: Array[String] = []
	if int(b.get("percent", -1)) >= 0:
		var st: String = b.get("status", "")
		parts.append(("Battery %d%%" if long else "%d%%") % b["percent"] + (", %s" % st.to_lower() if long and st != "" else ""))
	if float(b.get("watts", -1.0)) >= 0.0:
		parts.append(("drawing %.1f W" if long else "%.1f W") % b["watts"])
	if parts.is_empty():
		return "Battery readings aren't available on this device." if long else ""
	return "   ·   ".join(parts)


# ------------------------------------------------------------ Controller

func _build_controller() -> void:
	if model == null:
		return
	var l := _list(Catalog.QUICK["controller"])
	if model.has("controller.gyro") or model.has("controller.gyro_aim"):
		_gyro_note()
	if l.focusables().is_empty() and body.get_node_or_null("GyroSteam") == null:
		_line(TC.NOTHING_HERE, "QuietLabel", "Nothing")
	_all_link("controller")


## Gyro aiming lives in Steam: say so, and open its controller settings for
## the game in focus when it's a Steam game.
func _gyro_note() -> void:
	var box := PanelContainer.new()
	box.name = "GyroSteam"
	var c: Color = ThemeLib.tone("info")
	var sb := ThemeLib.box(Color(c, 0.10), ThemeLib.radius("m"), 16, 12)
	sb.border_color = Color(c, 0.32)
	sb.set_border_width_all(1)
	box.add_theme_stylebox_override("panel", sb)
	var col := Kit.vbox(8)
	var head := Kit.hbox(10)
	var steam_logo := BrandMark.rect("steam", 22, c)
	head.add_child(steam_logo if steam_logo != null else CIcons.rect("steam", 22, c))
	var t := Kit.label(TC.GYRO_STEAM_TITLE)
	t.add_theme_font_override("font", ThemeLib.font("semibold"))
	head.add_child(t)
	col.add_child(head)
	col.add_child(Kit.label(TC.GYRO_STEAM_LINE, "QuietLabel", true))
	box.add_child(col)
	body.add_child(box)
	if SteamInput.uri_for(game) != "":
		var b := Kit.secondary(TC.GYRO_STEAM_OPEN, "gamepad")
		b.name = "OpenSteamInput"
		b.custom_minimum_size = Vector2(0, 48)
		b.pressed.connect(_open_steam_input)
		col.add_child(b)
		_parts.append(b)
	else:
		var n := Kit.label(SteamInput.why_not(game), "QuietLabel", true)
		n.name = "NoSteamInput"
		n.add_theme_color_override("font_color", ThemeLib.color("text_3"))
		col.add_child(n)


func _open_steam_input() -> void:
	if SteamInput.open(game, open_uri):
		status_label.text = TC.GYRO_STEAM_OPENING
		# In the app the hand-off (ui/steam_trip.gd) closes the menu the moment Steam's
		# screen is in front, and opens it here again afterwards: closing now would give
		# the pad to the game under it while Steam is still getting its window up.
		if open_uri.is_valid() or not SteamInput.handoff.is_valid():
			close()
	else:
		status_label.text = TC.GYRO_STEAM_FAILED


# ------------------------------------------------------------ Device

func _build_device() -> void:
	if device == null:
		return
	var p: Dictionary = device.profile if "profile" in device else {}
	var level: String = device.support_level() if device.has_method("support_level") else "generic"
	var head := Kit.hbox(12)
	head.name = "DeviceHead"
	var maker := BrandMark.rect(maker_name(p, device.display_name()), 24)
	if maker != null:
		head.add_child(maker)
	var names := Kit.vbox(2)
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var dn := Kit.label(device.display_name(), "HeaderLabel")
	dn.name = "DeviceName"
	dn.add_theme_font_size_override("font_size", ThemeLib.SIZE_LEAD)
	names.add_child(dn)
	var facts := Kit.label("%s · %s" % [p.get("chip", "Unknown chip"), p.get("gpu", "Unknown graphics")], "QuietLabel", true)
	facts.name = "Facts"
	names.add_child(facts)
	head.add_child(names)
	head.add_child(Kit.chip(TD.SUPPORT_LABELS.get(level, level.capitalize()), "check" if level == "full" else "info", "good" if level == "full" else ("warn" if level == "partial" else ""), true))
	body.add_child(head)
	var support := _line(SUPPORT_TEXT.get(level, SUPPORT_TEXT["generic"]), "QuietLabel", "Support")
	support.add_theme_color_override("font_color", ThemeLib.color("text_3"))
	var unverified: Variant = p.get("unverified", [])
	if level != "generic" and unverified is Array and not unverified.is_empty():
		_line(TS.unverified_line(unverified), "QuietLabel", "Unverified")
	_works_chips(p)

	var fx := ActionRow.new()
	fx.setup("Fixes", TC.DEVICE_FIXES, fixes_summary(), TC.FIXES_OPEN + ".", "wrench")
	fx.pressed.connect(func(): request_settings("device", "fixes"))
	_add(fx)
	if model != null and bool(model.describe("network.bluetooth").get("available", false)):
		var bt := ActionRow.new()
		bt.setup("BluetoothDevices", TX.BT_TITLE, "", TX.BT_QUICK_HINT, "bluetooth")
		bt.pressed.connect(func(): request_settings("system", "bluetooth"))
		_add(bt)
	if model != null:
		_section_label(TC.QUICK_TOGGLES, "TogglesLabel")
		_list(Catalog.QUICK["device"], "Toggles")

	var steam := Kit.vbox(4)
	steam.name = "SteamMode"
	_steam_button = Kit.button(Texts.STEAM_TITLE)
	_steam_button.name = "Button"
	_steam_button.custom_minimum_size = Vector2(0, 54)
	_steam_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_steam_button.pressed.connect(_on_steam_pressed)
	_steam_button.focus_exited.connect(_disarm_steam)
	steam.add_child(_steam_button)
	steam.add_child(Kit.label(Texts.STEAM_EXPLAIN, "QuietLabel", true))
	body.add_child(steam)
	_parts.append(_steam_button)

	# Always a way to the real desktop (the installer's Repair / Uninstall live there).
	var desk := Kit.vbox(4)
	desk.name = "DesktopMode"
	_desktop_button = Kit.button(Texts.DESKTOP_TITLE)
	_desktop_button.name = "Button"
	_desktop_button.custom_minimum_size = Vector2(0, 54)
	_desktop_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_desktop_button.pressed.connect(_on_desktop_pressed)
	_desktop_button.focus_exited.connect(_disarm_desktop)
	desk.add_child(_desktop_button)
	desk.add_child(Kit.label(Texts.DESKTOP_EXPLAIN, "QuietLabel", true))
	body.add_child(desk)
	_parts.append(_desktop_button)


## What works here, as small chips (the same answer About this device gives:
## Capabilities over devices.json and live Controls detection). Hardware this
## model doesn't have is left out; unconfirmed things get a warn chip.
func _works_chips(p: Dictionary) -> void:
	var f: Dictionary = device.features() if device.has_method("features") else {}
	if f.is_empty():
		return
	var unv: Array = p.get("unverified", []) if p.get("unverified") is Array else []
	var flow := HFlowContainer.new()
	flow.name = "WhatWorks"
	flow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flow.add_theme_constant_override("h_separation", 6)
	flow.add_theme_constant_override("v_separation", 6)
	for st in Caps.states(f, unv, controls):
		if st["state"] == "absent":
			continue
		var ok: bool = st["state"] == "yes"
		var chip := Kit.chip(TC.WORKS_SHORT.get(st["key"], st["key"]), "check" if ok else "alert", "good" if ok else "warn")
		chip.tooltip_text = st["note"]
		flow.add_child(chip)
	if flow.get_child_count() > 0:
		body.add_child(flow)
	else:
		flow.free()


## The maker to show a logo for: the row's maker or DMI vendor, else the
## first word of the device's name ("MSI Claw 8 EX" -> "MSI").
static func maker_name(profile: Dictionary, display: String) -> String:
	var m := str(profile.get("maker", profile.get("vendor", ""))).strip_edges()
	if m != "":
		return m
	var words := display.strip_edges().split(" ", false)
	return words[0] if not words.is_empty() else ""


## "3 applied, all good" from the Fixes service, else how many fixes the
## devices.json row lists.
func fixes_summary() -> String:
	if fixes != null and fixes.has_method("counts"):
		var rows: Array = fixes.rows() if fixes.has_method("rows") else []
		if rows.is_empty():
			return TC.FIXES_NONE
		return TC.fixes_line(fixes.counts())
	var n: int = (device.profile.get("fixes", []) as Array).size() if device != null and "profile" in device else 0
	return TC.FIXES_COUNT_ONLY % n if n > 0 else TC.FIXES_NONE


func _on_steam_pressed() -> void:
	if not _steam_armed:
		_steam_armed = true
		_steam_button.text = Texts.STEAM_CONFIRM
		status_label.text = Texts.STEAM_CONFIRM_LINE
		return
	_steam_armed = false
	_steam_button.text = Texts.STEAM_TITLE
	_begin_switch("steam")


## The Shortcuts strip's Power sheet, already confirmed: "steam" or "desktop".
func switch_session(target: String) -> void:
	_begin_switch("steam" if target == "steam" else "desktop")


## Hands the controller back (InterceptMode 0 on every device; gamecove-session-select does it
## too), then runs the switch off the main thread. If it worked, the session logs out and
## GameCove goes. If it fails, its reason shows and GameCove takes the controller again; if
## GameCove is still here SWITCH_REARM_S later, the same (review M8).
func _begin_switch(target: String) -> void:
	_switch_gen += 1
	# a second switch while the first one's release stands: intercept already reads off, but it was on
	_switch_rearm = _switch_rearm or (controller != null and controller.has_method("intercept_state") \
		and bool(controller.intercept_state().get("active", false)))
	if controller != null and controller.has_method("release_intercept"):
		controller.release_intercept(_quiet_power_then_switch.bind(target, _switch_gen))
	else:
		_quiet_power_then_switch(target, _switch_gen)


## Final review, session: Auto TDP, the charge hold, the thermald hold and the 15 s check kept
## writing while the session's restores ran, so a game's limit or a held thermald could land
## after them and stay for Steam or the desktop. Power stops all of it first (on its worker),
## then the switch runs; a switch that fails or times out turns it back on (_rearm_after_switch).
func _quiet_power_then_switch(target: String, gen: int) -> void:
	if power != null and power.has_method("request_leave"):
		_power_left = true
		power.request_leave(_run_switch.bind(target, gen))
	else:
		_run_switch(target, gen)


func _run_switch(target: String, gen: int) -> void:
	if gen != _switch_gen:
		return
	if not commands.finished.is_connected(_on_switch_finished):
		commands.finished.connect(_on_switch_finished)
	if commands.busy("session_switch"):
		return
	status_label.text = Texts.STEAM_SWITCHING if target == "steam" else Texts.DESKTOP_SWITCHING
	if not commands.run("session_switch", SESSION_SELECT, PackedStringArray([target])):
		return
	if is_inside_tree() and gen == _switch_gen:
		get_tree().create_timer(SWITCH_LIMIT_S).timeout.connect(switch_timed_out.bind(gen))


## The switch is taking too long and GameCove is still here (see SWITCH_LIMIT_S and
## SWITCH_REARM_S): give the controller back.
func switch_timed_out(gen: int) -> void:
	if gen != _switch_gen:
		return
	_switch_gen += 1
	status_label.text = Texts.SWITCH_STUCK
	_rearm_after_switch()


func _on_switch_finished(id: String, code: int, output: String) -> void:
	if id != "session_switch":
		return
	if code == 0:
		# the logout is on its way; if GameCove is still here SWITCH_REARM_S from now, it never came
		if is_inside_tree():
			get_tree().create_timer(SWITCH_REARM_S).timeout.connect(switch_timed_out.bind(_switch_gen))
		return
	var reason := BgCommand.error_line(output)
	if reason == "":
		var lines := output.strip_edges().split("\n", false)
		reason = lines[-1].strip_edges().trim_prefix("gamecove-session-select: ") if not lines.is_empty() else ""
	if reason == "" and (code == 127 or not FileAccess.file_exists(SESSION_SELECT)):
		reason = "gamecove-session-select isn't installed"
	status_label.text = Texts.SWITCH_FAILED % reason if reason != "" else Texts.SWITCH_FAILED_NO_REASON
	_switch_gen += 1   # the timer has nothing left to do
	_rearm_after_switch()


## gamecove-session-select's mark of "a switch of ours just left the session" (its `leave` does nothing for
## two minutes after one). GameCove is still here, so that switch didn't happen: a logout a minute later must
## still hand the buttons back, and the mark would stop it (review at ff76ca4, session Low 6).
static func forget_left_mark() -> void:
	var run := OS.get_environment("XDG_RUNTIME_DIR")
	var base := run if run != "" else (OS.get_environment("XDG_DATA_HOME") if OS.get_environment("XDG_DATA_HOME") != "" \
		else OS.get_environment("HOME").path_join(".local/share")).path_join("gamecove")
	var mark := base.path_join("gamecove-left")
	if FileAccess.file_exists(mark):
		DirAccess.remove_absolute(mark)


func _rearm_after_switch() -> void:
	forget_left_mark()
	if _switch_rearm and controller != null and controller.has_method("start_intercept"):
		controller.start_intercept()
	_switch_rearm = false
	# GameCove stays: Power writes again and puts our own values back
	if _power_left and power != null and power.has_method("request_cancel_leave"):
		power.request_cancel_leave()
	_power_left = false


func _on_desktop_pressed() -> void:
	if not _desktop_armed:
		_desktop_armed = true
		_desktop_button.text = Texts.DESKTOP_CONFIRM
		status_label.text = Texts.DESKTOP_CONFIRM_LINE
		return
	_desktop_armed = false
	_desktop_button.text = Texts.DESKTOP_TITLE
	_begin_switch("desktop")


func _disarm_desktop() -> void:
	if not _desktop_armed or _desktop_button == null:
		return
	_desktop_armed = false
	_desktop_button.text = Texts.DESKTOP_TITLE
	status_label.text = ""


func _disarm_steam() -> void:
	if not _steam_armed or _steam_button == null:
		return
	_steam_armed = false
	_steam_button.text = Texts.STEAM_TITLE
	status_label.text = ""


## A small tinted note (info / warn) that never takes focus.
class SKitNote:
	static func make(text: String, tone: String) -> PanelContainer:
		return load("res://scripts/ui/settings/kit.gd").note(text, tone, "EditNote")
