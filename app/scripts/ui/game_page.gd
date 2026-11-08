extends "res://scripts/ui/page_template.gd"
## One game, on the shared page template: full-bleed hero, logo or title,
## badges, Play / Install, then "About this game" (time to beat, anti-cheat,
## ProtonDB) and the per-game settings. B goes back.

const Texts := preload("res://scripts/ui/texts.gd")
const View := preload("res://scripts/ui/library_view.gd")
const SettingsForm := preload("res://scripts/ui/settings_form.gd")

signal play_requested(game: Dictionary)
signal back_requested

var play_button: Button
var settings_button: Button
var back_button: Button
var form: VBoxContainer
var info_lines: Array[Label] = []


func setup(g: Dictionary, launcher: Object) -> void:
	name = "GamePage"
	setup_page(g, "")
	var info: Dictionary = g.get("info", {})
	var installed: bool = g.get("installed", false)
	play_button = add_action("Play" if installed else "Install", "play" if installed else "download", true, "Play")
	play_button.pressed.connect(func(): play_requested.emit(game))
	settings_button = add_action("Settings", "settings", false, "SettingsJump")
	back_button = add_action("Back", "chevron_left", false, "Back")
	back_button.pressed.connect(func(): back_requested.emit())

	var about := add_card("About this game", "info")
	var specs := [["clock", Texts.ttb_line(info), ""], ["shield", Texts.anticheat_line(info), "anticheat"], ["gauge", Texts.protondb_line(info), ""]]
	var ac := Texts.anticheat_badge(info)
	for s in specs:
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

	var body := add_card("Settings for this game", "settings", "Saved for this game and used every time it starts.")
	form = SettingsForm.new()
	form.setup(g.get("key", ""), launcher, true, g.get("store", "") != "steam")
	body.add_child(form)
	add_focusables(form.focusables())
	var first: Control = form.focusables()[0] if not form.focusables().is_empty() else play_button
	settings_button.pressed.connect(func(): first.grab_focus())
	finish()


func default_focus() -> Control:
	return play_button


## Focus Play once the layout has settled, so the page opens scrolled to the top.
func focus_first() -> void:
	if is_inside_tree():
		await get_tree().process_frame
	if is_instance_valid(play_button) and play_button.is_inside_tree():
		play_button.grab_focus()
		scroll.scroll_vertical = 0
