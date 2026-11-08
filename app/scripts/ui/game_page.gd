extends Control
## One game: art, title, store, time to beat, anti-cheat and ProtonDB lines,
## Play, and the per-game settings. B goes back home.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Texts := preload("res://scripts/ui/texts.gd")
const View := preload("res://scripts/ui/library_view.gd")
const Tile := preload("res://scripts/ui/game_tile.gd")
const SettingsForm := preload("res://scripts/ui/settings_form.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")

signal play_requested(game: Dictionary)
signal back_requested

var game: Dictionary = {}
var play_button: Button
var back_button: Button
var form: VBoxContainer
var info_lines: Array[Label] = []
var _scroll: ScrollContainer


func setup(g: Dictionary, launcher: Object) -> void:
	name = "GamePage"
	game = g
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var info: Dictionary = g.get("info", {})

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 40)
	margin.add_theme_constant_override("margin_top", 28)
	margin.add_theme_constant_override("margin_bottom", 12)
	add_child(margin)
	var outer := Kit.vbox(12)
	margin.add_child(outer)
	var row := Kit.hbox(36)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(row)
	outer.add_child(Kit.label("A  Select    ·    ← →  Change setting    ·    B  Back", "QuietLabel"))

	var left := Kit.vbox(0)
	var cover := Tile.new()
	cover.setup(g, false)
	cover.focus_mode = Control.FOCUS_NONE
	cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cover.custom_minimum_size = Vector2(264, 396)
	left.add_child(cover)
	row.add_child(left)

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.follow_focus = true
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(scroll)
	_scroll = scroll
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 6)
	scroll.add_child(pad)
	var col := Kit.vbox(14)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_child(col)

	var title := Kit.label(g.get("title", ""), "TitleLabel", true)
	title.name = "Title"
	col.add_child(title)
	var sub: Array[String] = [View.store_name(g.get("store", ""))]
	if info.get("released") != null:
		sub.append(str(info["released"]))
	var pt := Texts.playtime_text(int(g.get("playtime_min", 0)))
	if pt != "":
		sub.append(pt)
	col.add_child(Kit.label("   ·   ".join(sub), "QuietLabel"))

	var buttons := Kit.hbox(12)
	play_button = Kit.button("Play" if g.get("installed", false) else "Install", "AccentButton")
	play_button.name = "Play"
	play_button.custom_minimum_size = Vector2(220, 58)
	play_button.pressed.connect(func(): play_requested.emit(game))
	back_button = Kit.button("Back")
	back_button.name = "Back"
	back_button.custom_minimum_size = Vector2(140, 58)
	back_button.pressed.connect(func(): back_requested.emit())
	buttons.add_child(play_button)
	buttons.add_child(back_button)
	col.add_child(buttons)

	var facts := PanelContainer.new()
	facts.theme_type_variation = "RaisedPanel"
	var facts_col := Kit.vbox(8)
	facts.add_child(facts_col)
	for line in [Texts.ttb_line(info), Texts.anticheat_line(info), Texts.protondb_line(info)]:
		var l := Kit.label(line, "", true)
		info_lines.append(l)
		facts_col.add_child(l)
	var ac := Texts.anticheat_badge(info)
	if ac.get("tone", "") in ["warn", "bad"]:
		info_lines[1].add_theme_color_override("font_color", ThemeLib.WARN if ac["tone"] == "warn" else ThemeLib.BAD)
	col.add_child(facts)

	col.add_child(Kit.label("Settings for this game", "HeaderLabel"))
	col.add_child(Kit.label("Saved for this game and used every time it starts.", "QuietLabel", true))
	form = SettingsForm.new()
	form.setup(g.get("key", ""), launcher, true)
	col.add_child(form)

	var chain: Array = [play_button]
	chain.append_array(form.focusables())
	Kit.link_vertical(chain)
	play_button.focus_neighbor_right = play_button.get_path_to(back_button)
	back_button.focus_neighbor_left = back_button.get_path_to(play_button)
	back_button.focus_neighbor_right = back_button.get_path_to(back_button)
	back_button.focus_neighbor_top = back_button.get_path_to(back_button)
	back_button.focus_neighbor_bottom = back_button.get_path_to(chain[1] if chain.size() > 1 else back_button)


func default_focus() -> Control:
	return play_button


## Focus Play once the layout has settled, so the page opens scrolled to the top.
func focus_first() -> void:
	if is_inside_tree():
		await get_tree().process_frame
	if is_instance_valid(play_button) and play_button.is_inside_tree():
		play_button.grab_focus()
		_scroll.scroll_vertical = 0
