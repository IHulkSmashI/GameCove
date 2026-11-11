extends Control
## "Steam needs you for a moment": shown when a store opens its own window
## (Steam's install dialog, an uninstall confirmation, a page). Says what's
## waiting there and offers one button back. We also come back on our own once
## the store starts the job (Library.return_from_steam is called for us).

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const TG := preload("res://scripts/ui/texts_games.gd")
const GameIcons := preload("res://scripts/ui/games/game_icons.gd")

signal back_requested
## Closed and the control it was opened from is gone (rebuilt meanwhile): the
## host puts focus on the screen's own control.
signal focus_lost

var title_label: Label
var line_label: Label
var back_button: Button
var key := ""
var _dim: ColorRect
var _focus_before: Control
var _open := false


func _init() -> void:
	name = "SteamOverlay"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_dim = ColorRect.new()
	Kit.fill(_dim)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dim)
	var center := CenterContainer.new()
	Kit.fill(center)
	add_child(center)
	var p := PanelContainer.new()
	p.theme_type_variation = "GlassPanel"
	p.custom_minimum_size = Vector2(620, 0)
	center.add_child(p)
	var col := Kit.vbox(16)
	p.add_child(col)
	col.add_child(GameIcons.rect("external", 40, ThemeLib.color("accent")))
	title_label = Kit.label(TG.STEAM_NEEDS, "TitleLabel", true)
	title_label.name = "Title"
	col.add_child(title_label)
	line_label = Kit.label("", "", true)
	line_label.name = "Line"
	col.add_child(line_label)
	var tip := Kit.label(TG.STEAM_TIP, "QuietLabel", true)
	col.add_child(tip)
	back_button = Kit.button(TG.BACK_TO_COVE, "AccentButton")
	back_button.name = "Back"
	back_button.custom_minimum_size = Vector2(280, 58)
	back_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	back_button.icon = GameIcons.tex("chevron_left", 22)
	back_button.add_theme_constant_override("h_separation", 10)
	back_button.pressed.connect(func():
		close()
		back_requested.emit())
	col.add_child(back_button)
	back_button.focus_neighbor_left = back_button.get_path_to(back_button)
	back_button.focus_neighbor_right = back_button.get_path_to(back_button)
	back_button.focus_neighbor_top = back_button.get_path_to(back_button)
	back_button.focus_neighbor_bottom = back_button.get_path_to(back_button)
	_restyle()


func _restyle() -> void:
	_dim.color = Color(ThemeLib.color("scrim"), 0.78)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _dim != null:
		_restyle()


## app: steam | heroic; reason: install | uninstall | page | manage.
func show_for(game_key: String, title: String, app: String, reason: String) -> void:
	key = game_key
	title_label.text = TG.HEROIC_NEEDS if app == "heroic" else TG.STEAM_NEEDS
	var line: String = TG.STEAM_REASON.get(reason, TG.STEAM_REASON["manage"])
	line_label.text = line % (title if title != "" else "this game")
	if app == "heroic":
		line_label.text = line_label.text.replace("Steam", "Heroic")
	if not _open and is_inside_tree():
		_focus_before = get_viewport().gui_get_focus_owner()
	_open = true
	Motion.fade(self, true)
	if is_inside_tree():
		back_button.grab_focus()


func close() -> void:
	if not _open:
		return
	_open = false
	Motion.fade(self, false)
	if _focus_before != null and is_instance_valid(_focus_before) and _focus_before.is_visible_in_tree() \
			and not is_ancestor_of(_focus_before):
		_focus_before.grab_focus()
	elif is_inside_tree():
		var f := get_viewport().gui_get_focus_owner()
		if f != null and is_ancestor_of(f):
			f.release_focus()
		focus_lost.emit()


func is_open() -> bool:
	return _open


func _input(event: InputEvent) -> void:
	if _open and event.is_action_pressed("ui_cancel"):
		close()
		back_requested.emit()
		get_viewport().set_input_as_handled()
