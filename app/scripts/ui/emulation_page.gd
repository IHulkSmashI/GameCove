extends "res://scripts/ui/page_template.gd"
## Emulation: EmuDeck (or RetroDECK, or ES-DE on its own) in GameCove, on the
## shared page template. We start their tools; we don't run emulators ourselves.
##   Open ES-DE / RetroDECK   through main's launch path (launch animation,
##                            gamescope focus, quick menu, play time)
##   EmuDeck / RetroDECK settings   their own app, for emulator updates and settings
##   Add or update ROMs       Steam ROM Manager, which adds each ROM to Steam
##                            (and so to our Library) with art
## Cards: Systems (ROM folders and how many games each holds), Recently played
## (ES-DE's gamelists), Your setup (where things are, how many emulated games
## the Library has). Nothing installed: what EmuDeck is and a QR code to its site.
##
## setup(emu, games): `emu` is Library.emulation (Emu.detect), `games` the
## decorated Library games (the "emu" ones are counted and opened).

const TL := preload("res://scripts/ui/texts_library.gd")
const TG := preload("res://scripts/ui/texts_games.gd")
const SKit := preload("res://scripts/ui/settings/kit.gd")
const GameIcons := preload("res://scripts/ui/games/game_icons.gd")
const QR := preload("res://scripts/ui/settings/qr.gd")
const LinkHandoff := preload("res://scripts/ui/games/link_handoff.gd")
const View := preload("res://scripts/ui/library_view.gd")
const TOP_INSET := 56
## System chips shown before "+N more".
const SYSTEMS_SHOWN := 18

## Start this (the frontend, EmuDeck's app or Steam ROM Manager) the way a game starts.
signal play_requested(game: Dictionary)
signal back_requested
## Show the emulated games in the Library (its Emulation view).
signal library_requested

var emu: Dictionary = {}
var frontend_game: Dictionary = {}
var emu_games: Array = []
var open_button: Button
var app_button: Button
var srm_button: Button
var library_button: Button
var get_button: Button
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
	var g := frontend_game if not frontend_game.is_empty() else {"key": "emu:page", "store": "emu", "id": "page", "title": TL.EMU_TITLE,
		"installed": true, "art": {"cover": "", "hero": "", "logo": "", "icon": ""}, "info": {}}
	setup_page(g, "")
	handoff = LinkHandoff.new()
	add_child(handoff)
	if str(emu.get("kind", "")) == "":
		_build_empty()
	else:
		_build_setup()
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
	var sys := add_card(TL.EMU_SYSTEMS, "gamepad", TL.EMU_SYSTEMS_LINE % _short_path(roms), true, 0)
	_fill_systems(sys, roms)
	var rec := add_card(TL.EMU_RECENT % (fe.get("name", "ES-DE") if not fe.is_empty() else "ES-DE"), "clock", "", true, 1)
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
	for s in list.slice(0, SYSTEMS_SHOWN):
		var chip := SKit.chip("%s  %d" % [s["short"], int(s["count"])], "", "")
		chip.name = "System_" + str(s["id"]).validate_node_name()
		chip.tooltip_text = "%s · %s" % [s["name"], TL.EMU_SYSTEM_COUNT % [int(s["count"]), TL.plural(int(s["count"]))]]
		flow.add_child(chip)
	if list.size() > SYSTEMS_SHOWN:
		flow.add_child(SKit.chip("+%d" % (list.size() - SYSTEMS_SHOWN), "", ""))
	body.add_child(flow)
	var total := int(emu.get("rom_total", 0))
	var line := Kit.label(TL.EMU_SYSTEM_COUNT % [total, TL.plural(total)] + " · " + "%d system%s" % [list.size(), TL.plural(list.size())], "CaptionLabel")
	line.name = "RomTotal"
	line.add_theme_color_override("font_color", ThemeLib.color("text_3"))
	body.add_child(line)


func _fill_recent(body: VBoxContainer, fe: Dictionary) -> void:
	var list: Array = emu.get("recent", [])
	if list.is_empty():
		body.add_child(Kit.label(TL.EMU_NO_RECENT % fe.get("name", "ES-DE"), "QuietLabel", true))
		return
	var now := int(Time.get_unix_time_from_system())
	for r in list:
		var row := Kit.hbox(12)
		row.name = "Recent"
		var t := Kit.label(str(r["title"]), "")
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.add_child(t)
		var meta := Kit.label("%s · %s" % [r["system"], TG.ago(int(r["last_played"]), now)], "CaptionLabel")
		meta.add_theme_color_override("font_color", ThemeLib.color("text_2"))
		row.add_child(meta)
		body.add_child(row)


func _fill_setup(body: VBoxContainer, kind: String, fe: Dictionary, roms: String) -> void:
	body.add_child(SKit.fact(TL.EMU_FACT_SETUP, TL.EMU_KIND.get(kind, kind), 130))
	body.add_child(SKit.fact(TL.EMU_FACT_FRONTEND, str(fe.get("name", "")) if not fe.is_empty() else "-", 130))
	body.add_child(SKit.fact(TL.EMU_FACT_ROMS, _short_path(roms), 130))
	if fe.is_empty():
		body.add_child(SKit.note(TL.EMU_NO_FRONTEND, "info", "NoFrontend"))
	if emu.get("srm", {}).is_empty():
		body.add_child(SKit.note(TL.EMU_SRM_MISSING, "info", "NoSrm"))
	var n := emu_games.filter(func(g): return str(g.get("id", "")) != "frontend").size()
	body.add_child(Kit.label(TL.EMU_IN_LIBRARY, "LeadLabel"))
	body.add_child(Kit.label((TL.EMU_IN_LIBRARY_LINE % [n, TL.plural(n)]) if n > 0 else TL.EMU_IN_LIBRARY_NONE, "QuietLabel", true))
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
	qr.texture = QR.texture(TL.EMUDECK_URL, 5)
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
	return []
