extends "res://scripts/ui/page_template.gd"
## One game, on the shared page template: full-bleed hero, logo or title,
## badges, then the action row: the one thing to do now (Play, Install,
## Update, Pause / Resume while it downloads), Manage (everything else:
## uninstall, check files, move, launch options, compatibility tool, Steam
## pages) and Achievements. Under it a live progress line while something
## runs. Cards: Steam changes waiting (Restart Steam), then a bento of About
## this game | Achievements | Game settings. B goes back.
##
## setup(game, launcher, services): services are optional, so the page still
## works with only a launcher (tests, previews):
##   "library"      Library store API (capabilities, ...)
##   "state"        InstallState (live install state and progress)
##   "actions"      GameActions (flows with sheets, keyboard, toasts)
##   "achievements" Achievements service
##   "controls", "profiles"  Controls / Profiles for the Game settings card
##                  (the autoloads when not passed; none under tests)

const Texts := preload("res://scripts/ui/texts.gd")
const TG := preload("res://scripts/ui/texts_games.gd")
const View := preload("res://scripts/ui/library_view.gd")
const SettingsForm := preload("res://scripts/ui/settings_form.gd")
const GameIcons := preload("res://scripts/ui/games/game_icons.gd")
const ProgressLine := preload("res://scripts/ui/games/progress_line.gd")
const AchievementsCard := preload("res://scripts/ui/games/achievements_card.gd")
const GameSettingsCard := preload("res://scripts/ui/controls/game_settings_card.gd")
const Shared := preload("res://scripts/ui/controls/shared.gd")
const TC := preload("res://scripts/ui/texts_controls.gd")
const InsightsCard := preload("res://scripts/ui/games/insights_card.gd")
const SteamInsights := preload("res://scripts/steam/steam_insights.gd")
const TI := preload("res://scripts/ui/texts_insights.gd")
## Room for the top bar above the hero card (it starts where Home's does).
const TOP_INSET := 56

signal play_requested(game: Dictionary)
signal back_requested
## The primary action says "View downloads" (progress lives there).
signal downloads_requested

var play_button: Button
var manage_button: Button
## Gone from the action row (B goes back; the settings card is on screen);
## kept null for callers.
var settings_button: Button
var back_button: Button
## Jumps into the achievements grid (Steam games with achievements).
var ach_button: Button
var form: VBoxContainer
var info_lines: Array[Label] = []
var library: Object
var state: Object
var game_actions: Object
var achievements: Object
## {"id", "text", "icon"} of the primary action.
var primary: Dictionary = {}
var status_box: HBoxContainer
var status_bar: Control
var status_label: Label
var pending_card: PanelContainer
var restart_button: Button
var ach_card: VBoxContainer
## "Game settings": this game's own profile, Edit and Reset.
var game_settings: VBoxContainer
## "Steam insights" (Steam games): players, reviews, Deck, last update, prices, SteamDB link.
var insights_card: VBoxContainer
var _accent := Color(0, 0, 0, 0)


func setup(g: Dictionary, launcher: Object, services := {}) -> void:
	name = "GamePage"
	library = services.get("library")
	state = services.get("state")
	game_actions = services.get("actions")
	achievements = services.get("achievements")
	top_inset = TOP_INSET
	setup_page(g, "")
	_build_actions()
	_build_status()

	if game_actions != null and _is_steam():
		_build_pending()

	var info: Dictionary = g.get("info", {})
	# A bento under the hero: About | Achievements | Game settings, side by
	# side, so nothing sits below the fold while a column stands empty.
	var about := add_card(TG.ABOUT, "info", "", true, 0)
	_fill_about(about, g, info)

	if achievements != null and _is_steam():
		var body := add_card(TG.ACH_TITLE, "star", "", true, 1)
		ach_card = AchievementsCard.new()
		ach_card.cells_changed.connect(_relink)
		ach_card.cells_changed.connect(_refresh_ach_button)
		ach_card.cell_focused.connect(func(): _reveal(body.get_parent()))
		body.add_child(ach_card)
		columns_laid_out.connect(func(_n, inner): ach_card.fit_width(inner))
		ach_card.setup(str(g.get("id", "")), achievements)

	if InsightsCard.visible_for(g):
		_build_insights(g, services.get("insights"))

	# Game settings: this game's own profile first, then its launch settings.
	var gbody := add_card(TC.GAME_CARD, "layers", "", true, 2)
	var ctl: Object = services.get("controls", Shared.autoload("Controls"))
	if ctl != null and str(g.get("key", "")) != "":
		game_settings = GameSettingsCard.new()
		game_settings.setup(g, ctl, services.get("profiles", Shared.autoload("Profiles")))
		game_settings.relinked.connect(func(): if is_instance_valid(self): _relink())
		gbody.add_child(game_settings)
		var rule := HSeparator.new()
		rule.name = "LaunchRule"
		rule.add_theme_constant_override("separation", 10)
		gbody.add_child(rule)
	var launch := Kit.label(TG.SETTINGS_TITLE, "")
	launch.name = "LaunchTitle"
	launch.add_theme_font_override("font", ThemeLib.font("semibold"))
	gbody.add_child(launch)
	form = SettingsForm.new()
	form.setup(g.get("key", ""), launcher, true, g.get("store", "") != "steam")
	gbody.add_child(form)

	if state != null:
		state.changed.connect(_on_state_changed)
		state.progress.connect(_on_progress)
	if game_actions != null:
		game_actions.pending_changed.connect(func(_n): _refresh_pending())
	_refresh_status()
	_relink()


## The Steam insights card under About; `svc` is a SteamInsights (one is made
## for the page when none is passed).
func _build_insights(g: Dictionary, svc: Object) -> void:
	if svc == null:
		svc = SteamInsights.new()
		svc.name = "SteamInsightsService"
		add_child(svc)
	var ibody := add_card(TI.TITLE, "gauge", "", true, 0)
	insights_card = InsightsCard.new()
	insights_card.relinked.connect(func(): if is_instance_valid(self): _relink())
	insights_card.row_focused.connect(func(): _reveal(ibody.get_parent()))
	ibody.add_child(insights_card)
	insights_card.setup(g, svc, self)


## About this game: a short synopsis when the metadata has one, time to
## beat as three stat chips, anti-cheat and community reports, and the data
## credits small and dim at the foot.
func _fill_about(about: VBoxContainer, g: Dictionary, info: Dictionary) -> void:
	var summary := str(info.get("summary", g.get("summary", ""))).strip_edges()
	if summary != "" and summary != "<null>":
		var syn := Kit.label(summary, "QuietLabel", true)
		syn.name = "Synopsis"
		syn.max_lines_visible = 3
		syn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		about.add_child(syn)
	about.add_child(_ttb_chips(info))
	var ac := Texts.anticheat_badge(info)
	for s in [["shield", Texts.anticheat_line(info), "anticheat"], ["gauge", Texts.protondb_line(info), ""]]:
		var tone: String = ac.get("tone", "") if s[2] == "anticheat" else ""
		var col: Color = ThemeLib.color("text_2")
		if tone == "warn":
			col = ThemeLib.color("warn")
		elif tone == "bad":
			col = ThemeLib.color("bad")
		elif tone == "good":
			col = ThemeLib.color("good")
		var row := Kit.icon_label(s[0] if s[2] != "anticheat" else {"good": "shield", "warn": "shield_alert", "bad": "shield_x"}.get(tone, "shield"), s[1], "", col, 22)
		var l: Label = row.get_child(1)
		if tone in ["warn", "bad"]:
			l.add_theme_color_override("font_color", col)
		info_lines.append(l)
		about.add_child(row)
	var credit := Kit.label(Texts.DATA_CREDIT, "CaptionLabel", true)
	credit.name = "Credit"
	credit.add_theme_font_size_override("font_size", 12)
	credit.add_theme_color_override("font_color", ThemeLib.color("text_3"))
	info_lines.append(credit)
	about.add_child(credit)


## Main / Extras / 100% as three chips with a mono label over the hours,
## and how many players the numbers come from.
func _ttb_chips(info: Dictionary) -> Control:
	var col := Kit.vbox(6)
	col.name = "TimeToBeat"
	var t: Variant = info.get("time_to_beat")
	if typeof(t) != TYPE_DICTIONARY:
		var none := Kit.icon_label("clock", Texts.ttb_line(info), "", ThemeLib.color("text_2"), 22)
		info_lines.append(none.get_child(1))
		col.add_child(none)
		return col
	var row := Kit.hbox(8)
	for spec in [[TG.TTB_MAIN, t.get("main_h")], [TG.TTB_EXTRAS, t.get("extra_h")], [TG.TTB_ALL, t.get("complete_h")]]:
		var p := PanelContainer.new()
		p.name = "Ttb_" + str(spec[0]).validate_node_name()
		p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		p.add_theme_stylebox_override("panel", ThemeLib.box(ThemeLib.soft(0.06), ThemeLib.radius("m"), 12, 8))
		var c := Kit.vbox(2)
		c.add_child(Kit.micro(str(spec[0])))
		var v := Kit.label(Texts.format_hours(spec[1]), "LeadLabel")
		v.add_theme_font_override("font", ThemeLib.font("semibold", true))
		c.add_child(v)
		p.add_child(c)
		row.add_child(p)
	col.add_child(row)
	var n := int(t.get("count", 0)) if t.get("count") != null else 0
	if n > 0:
		var who := Kit.label(TG.TTB_FROM % [n, "player" if n == 1 else "players"], "CaptionLabel")
		who.add_theme_color_override("font_color", ThemeLib.color("text_3"))
		col.add_child(who)
	return col


func _is_steam() -> bool:
	return str(game.get("store", "")) == "steam"


func _key() -> String:
	return str(game.get("key", ""))


func _caps() -> Dictionary:
	return library.capabilities(game) if library != null else {}


func _state() -> String:
	return state.state_of(_key()) if state != null else ""


# ------------------------------------------------------------ actions

## The one thing to do now, from install state and capabilities.
static func primary_for(g: Dictionary, st: String, caps: Dictionary) -> Dictionary:
	var installed: bool = g.get("installed", false)
	var have_caps := not caps.is_empty()
	if st in TG.BUSY:
		if st == "paused":
			if not have_caps or caps.get("resume", false):
				return {"id": "resume", "text": TG.RESUME, "icon": "play"}
		elif st != "queued" and (not have_caps or caps.get("pause", false)):
			return {"id": "pause", "text": TG.PAUSE, "icon": "pause"}
		return {"id": "downloads", "text": TG.DL_TITLE, "icon": "download"}
	if installed and st == "update_required" and (not have_caps or caps.get("update", false)):
		return {"id": "update", "text": TG.UPDATE, "icon": "update"}
	if installed:
		return {"id": "play", "text": "Play", "icon": "play"}
	return {"id": "install", "text": "Install", "icon": "download"}


func _build_actions() -> void:
	for b in actions_row.get_children():
		Kit.drop(actions_row, b)
	actions.clear()
	primary = primary_for(game, _state(), _caps())
	play_button = add_action(primary["text"], "", true, "Play")
	play_button.icon = GameIcons.tex(primary["icon"], 22)
	play_button.pressed.connect(_on_primary)
	manage_button = add_action(TG.MANAGE, "dots", false, "Manage")
	manage_button.pressed.connect(func():
		if game_actions != null:
			game_actions.manage(game))
	manage_button.visible = game_actions != null
	if not manage_button.visible:
		actions.erase(manage_button)
	# No Back here (B does it) and no jump to the settings card (it's on
	# screen): Achievements jumps into the grid when the game has some.
	settings_button = null
	back_button = null
	if achievements != null and _is_steam():
		ach_button = add_action(TG.ACH_TITLE, "star", false, "AchievementsJump")
		ach_button.pressed.connect(_jump_to_achievements)
		ach_button.visible = ach_card != null and not ach_card.cells.is_empty()
		if not ach_button.visible:
			actions.erase(ach_button)
	if _accent.a > 0.0:
		set_accent(_accent)


func _on_primary() -> void:
	match primary.get("id", "play"):
		"play":
			play_requested.emit(game)
		"install":
			if game_actions != null:
				game_actions.install(game)
			else:
				play_requested.emit(game)
		"update":
			if game_actions != null:
				game_actions.update(game)
		"pause":
			if game_actions != null:
				game_actions.pause(game)
		"resume":
			if game_actions != null:
				game_actions.resume(game)
		"downloads":
			downloads_requested.emit()


func _jump_to_settings() -> void:
	var f: Array = form.focusables() if form != null else []
	if not f.is_empty():
		f[0].grab_focus()


## The Achievements jump shows only while there's a grid to jump into.
func _refresh_ach_button() -> void:
	if ach_button == null or not is_instance_valid(ach_button):
		return
	var want: bool = ach_card != null and not ach_card.cells.is_empty()
	if want == ach_button.visible:
		return
	ach_button.visible = want
	if want and not ach_button in actions:
		actions.append(ach_button)
	elif not want:
		actions.erase(ach_button)
	_relink()


func _jump_to_achievements() -> void:
	if ach_card != null and not ach_card.cells.is_empty():
		ach_card.cells[0].grab_focus()


func set_accent(c: Color) -> void:
	_accent = c
	super.set_accent(c)
	if status_bar != null and c.a > 0.0:
		status_bar.fill_color = c
		status_bar.queue_redraw()


## The Library rescanned: take the fresh copy of this game.
func update_game(g: Dictionary) -> void:
	if g.is_empty():
		return
	var was_installed: bool = game.get("installed", false)
	game = g
	if was_installed != g.get("installed", false):
		header.show_game(g, "")
	_refresh_actions()


func _refresh_actions() -> void:
	var want := primary_for(game, _state(), _caps())
	if want == primary:
		return
	var had_focus := is_inside_tree() and get_viewport().gui_get_focus_owner() in actions
	_build_actions()
	_relink()
	if had_focus:
		play_button.grab_focus()


# ------------------------------------------------------------ live status

func _build_status() -> void:
	# One line under the actions: mono progress text, then the bar.
	status_box = Kit.hbox(18)
	status_box.name = "Status"
	status_box.custom_minimum_size = Vector2(0, 0)
	status_label = Kit.label("", "MonoLabel")
	status_label.name = "Line"
	status_label.add_theme_font_override("font", ThemeLib.mono(true, 1))
	status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	status_box.add_child(status_label)
	status_bar = ProgressLine.new(8.0)
	status_bar.name = "Bar"
	status_bar.custom_minimum_size = Vector2(300, 8)
	status_bar.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	status_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	status_box.add_child(status_bar)
	var col := actions_row.get_parent()
	col.add_child(status_box)
	col.move_child(status_box, actions_row.get_index() + 1)


func _on_state_changed() -> void:
	_refresh_actions()
	_refresh_status()


func _on_progress(key: String) -> void:
	if key == _key():
		_refresh_status()


## The line under the actions: progress while busy, or why the main action
## can't run here.
func _refresh_status() -> void:
	var st := _state()
	var c := _caps()
	if st in TG.BUSY:
		status_box.visible = true
		var p: Dictionary = state.progress_of(_key())
		var f: float = state.fraction(_key())
		status_bar.visible = true
		status_bar.set_value(f if st != "queued" else -1.0)
		status_bar.set_color(ThemeLib.color("text_3") if st == "paused" else _accent)
		var head: String = TG.STATE_LABEL.get(st, "")
		if st in TG.RUNNING and f >= 0.0:
			head = "%s %d%%" % [TG.ACTION_ING.get(state.action_of(_key()), head), roundi(f * 100.0)]
		var nums := TG.progress_line(p) if st in TG.RUNNING else ""
		status_label.text = head + ("  ·  " + nums if nums != "" else "")
		status_label.add_theme_color_override("font_color", _accent if _accent.a > 0.0 else ThemeLib.color("accent"))
		return
	status_bar.visible = false
	var cap: String = {"install": "install", "update": "update"}.get(primary.get("id", ""), "")
	if cap != "" and not c.is_empty() and not c.get(cap, false):
		status_box.visible = true
		status_label.text = TG.why(c, cap)
		status_label.add_theme_color_override("font_color", ThemeLib.color("warn"))
		return
	if st == "failed":
		status_box.visible = true
		status_label.text = TG.STATE_LABEL["failed"]
		status_label.add_theme_color_override("font_color", ThemeLib.color("bad"))
		return
	status_box.visible = false


# ------------------------------------------------------------ Steam changes

func _build_pending() -> void:
	pending_card = PanelContainer.new()
	pending_card.name = "Card_Pending"
	pending_card.theme_type_variation = "CardPanel"
	var row := Kit.hbox(18)
	pending_card.add_child(row)
	row.add_child(GameIcons.rect("restart", 28, ThemeLib.color("warn")))
	var col := Kit.vbox(4)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(Kit.label(TG.PENDING_TITLE, "LeadLabel"))
	col.add_child(Kit.label(TG.PENDING_LINE, "QuietLabel", true))
	row.add_child(col)
	restart_button = Kit.button(TG.RESTART_STEAM)
	restart_button.name = "RestartSteam"
	restart_button.custom_minimum_size = Vector2(0, 54)
	restart_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	restart_button.icon = GameIcons.tex("restart", 20)
	restart_button.add_theme_constant_override("h_separation", 10)
	restart_button.pressed.connect(func(): game_actions.restart_steam())
	row.add_child(restart_button)
	cards_box.add_child(pending_card)
	pending_card.visible = game_actions.pending_count() > 0


func _refresh_pending() -> void:
	if pending_card == null:
		return
	var want: bool = game_actions.pending_count() > 0
	if want != pending_card.visible:
		var had := is_inside_tree() and get_viewport().gui_get_focus_owner() == restart_button
		pending_card.visible = want
		_relink()
		if had:
			play_button.grab_focus()


# ------------------------------------------------------------ focus

## Rebuilds the focus chain from what's showing: actions, Restart Steam,
## achievements grid (as one stop that opens into a 2D grid), settings rows.
func _relink() -> void:
	var list: Array = []
	if pending_card != null and pending_card.visible:
		list.append(restart_button)
	var first_cell: Control = null
	if ach_card != null and not ach_card.cells.is_empty():
		first_cell = ach_card.cells[0]
		list.append(first_cell)
	if insights_card != null:
		list.append_array(insights_card.focusables())
	if form != null:
		list.append_array(form.focusables())
	if game_settings != null:
		list.append_array(game_settings.focusables())
	focusables = list
	finish()
	if first_cell != null:
		var i := list.find(first_cell)
		var above: Control = list[i - 1] if i > 0 else actions[0]
		var below: Control = list[i + 1] if i + 1 < list.size() else first_cell
		ach_card.link_edges(above, below)
		above.focus_neighbor_bottom = above.get_path_to(first_cell)
		if below != first_cell:
			below.focus_neighbor_top = below.get_path_to(first_cell)


## Scrolls so the whole card is on screen (above the bottom fade), gliding.
func _reveal(card: Control) -> void:
	if not is_inside_tree() or scroll == null:
		return
	var content: Control = scroll.get_child(0)
	var top := card.global_position.y - content.global_position.y
	var bottom := top + card.size.y
	var view := scroll.size.y
	# The card's bottom clears the "More below" fade, but its top never leaves the screen.
	var target := clampf(bottom - view + 110.0, 0.0, maxf(top - 24.0, 0.0))
	Motion.method(scroll, "vscroll", func(v: float): scroll.scroll_vertical = int(v), float(scroll.scroll_vertical), target, Motion.BASE)


func default_focus() -> Control:
	return play_button


## Hints for the focused control when the page knows better than main.
func hints_for_focus(f: Control) -> Array:
	if f != null and ach_card != null and f in ach_card.cells:
		return [["DPAD", "Browse"], ["B", "Back"]]
	if f == manage_button:
		return [["A", TG.MANAGE], ["B", "Back"]]
	return []


## Focus Play once the layout has settled, so the page opens scrolled to the top.
func focus_first() -> void:
	if is_inside_tree():
		await get_tree().process_frame
	if is_instance_valid(play_button) and play_button.is_inside_tree():
		play_button.grab_focus()
		scroll.scroll_vertical = 0
