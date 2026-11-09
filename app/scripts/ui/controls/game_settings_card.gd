extends VBoxContainer
## The game page's "Game settings" card body: whether the game has its own
## settings (a Profiles game layer), the main values saved for it, Edit (the
## quick menu's This game tab for it, where every change saves for this
## game) and Reset (asks first). Without its own settings: one button to
## give it some (starts from the current everyday values).
##
## setup(game, controls, profiles); signal edit_requested(game). Without a
## listener, Edit opens the scene's QuickMenu itself.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const TC := preload("res://scripts/ui/texts_controls.gd")
const Model := preload("res://scripts/ui/controls/model.gd")
const SteamInput := preload("res://scripts/ui/controls/steam_input.gd")
const BrandMark := preload("res://scripts/ui/brand_mark.gd")

signal edit_requested(game: Dictionary)
## The buttons changed; the page relinks its focus chain.
signal relinked

const SHOW := 4
## Shown first when saved, in this order.
const PRIORITY := ["power.tdp", "display.fps_limit", "perf.overlay", "perf.upscaler", "perf.frame_gen",
	"perf.lsfg", "power.autotune_target", "display.refresh_rate", "power.fan_mode"]

var model: Object
var game: Dictionary = {}
var edit_button: Button
var reset_button: Button
## Steam games: gyro aiming, button layouts and the rest of Steam Input live
## in Steam's controller settings for the game; this opens them.
var steam_button: Button
## `opener(uri) -> bool` instead of asking Steam (tests).
var open_uri := Callable()
var _armed := false


func setup(g: Dictionary, controls: Object, profiles: Object) -> void:
	name = "GameSettings"
	game = g
	add_theme_constant_override("separation", 12)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	model = Model.new()
	model.setup(controls, profiles)
	model.game = g   # not set_game(): the page mustn't move Controls' game context
	if profiles != null and profiles.has_signal("changed"):
		profiles.changed.connect(_on_profiles_changed)
	rebuild()


func _exit_tree() -> void:
	if model != null and model.profiles != null and model.profiles.is_connected("changed", _on_profiles_changed):
		model.profiles.disconnect("changed", _on_profiles_changed)


func _on_profiles_changed() -> void:
	if is_instance_valid(self):
		rebuild()


func focusables() -> Array:
	var out := []
	for b in [edit_button, reset_button, steam_button]:
		if b != null and is_instance_valid(b) and b.visible:
			out.append(b)
	return out


## The values saved for the game, merged (any source, then battery / plugged in).
func saved() -> Dictionary:
	var out := {}
	if model.profiles == null:
		return out
	for s in ["", "battery", "ac"]:
		out.merge(model.profiles.layer(str(game.get("key", "")), s), false)
	return out


func rebuild() -> void:
	var had: Control = get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	var focus_reset := had != null and had == reset_button
	for c in get_children():
		remove_child(c)
		c.queue_free()
	edit_button = null
	reset_button = null
	steam_button = null
	_armed = false
	var on: bool = model.per_game()
	var state := Kit.chip(TC.GAME_CARD_ON if on else TC.GAME_CARD_OFF, "layers" if on else "sliders", "accent" if on else "", false)
	state.name = "State"
	add_child(state)
	if on:
		var vals := saved()
		var grid := GridContainer.new()
		grid.name = "Values"
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 18)
		grid.add_theme_constant_override("v_separation", 6)
		var ids: Array = PRIORITY.filter(func(i): return vals.has(i))
		var rest: Array = vals.keys().filter(func(i): return not i in PRIORITY and model.has(i))
		rest.sort()
		ids.append_array(rest)
		var shown := 0
		for id in ids:
			if shown >= SHOW:
				break
			var d: Dictionary = model.describe(id)
			if d.is_empty():
				continue
			var k := Kit.label(str(d.get("title", id)), "QuietLabel")
			grid.add_child(k)
			var v := Kit.label(Model.value_label(d, vals[id]))
			v.add_theme_font_override("font", ThemeLib.mono(true, 0))
			v.add_theme_color_override("font_color", ThemeLib.color("accent"))
			grid.add_child(v)
			shown += 1
		add_child(grid)
		if vals.size() > shown:
			var more := Kit.label(TC.GAME_CARD_MORE % (vals.size() - shown), "QuietLabel")
			more.name = "More"
			more.add_theme_color_override("font_color", ThemeLib.color("text_3"))
			add_child(more)
	else:
		add_child(Kit.label(TC.GAME_CARD_OFF_LINE, "QuietLabel", true))
	var row := Kit.hbox(12)
	row.name = "Buttons"
	edit_button = Kit.secondary(TC.GAME_CARD_EDIT if on else TC.GAME_CARD_ON_BUTTON, "sliders")
	edit_button.name = "Edit"
	edit_button.custom_minimum_size = Vector2(0, 48)
	edit_button.pressed.connect(_on_edit)
	row.add_child(edit_button)
	if on:
		reset_button = Kit.secondary(TC.GAME_CARD_RESET, "reset")
		reset_button.name = "Reset"
		reset_button.custom_minimum_size = Vector2(0, 48)
		reset_button.pressed.connect(_on_reset)
		reset_button.focus_exited.connect(func():
			if _armed and is_instance_valid(reset_button):
				_armed = false
				reset_button.text = TC.GAME_CARD_RESET)
		row.add_child(reset_button)
	add_child(row)
	if SteamInput.uri_for(game) != "":
		steam_button = Kit.secondary(TC.GAME_CARD_STEAM_INPUT, "gamepad")
		steam_button.name = "SteamInput"
		steam_button.custom_minimum_size = Vector2(0, 48)
		steam_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		# A small monochrome Steam mark (a full-colour logo outweighed every
		# other button on the page).
		var logo := BrandMark.texture("steam", 18, ThemeLib.color("text_2"))
		if logo != null:
			steam_button.icon = logo
			steam_button.expand_icon = false
			steam_button.add_theme_constant_override("icon_max_width", 18)
		steam_button.tooltip_text = TC.GYRO_STEAM_LINE
		steam_button.pressed.connect(_on_steam_input)
		add_child(steam_button)
	relinked.emit()
	if had != null and is_inside_tree():
		(reset_button if focus_reset and reset_button != null else edit_button).grab_focus.call_deferred()


func _on_edit() -> void:
	if not model.per_game():
		model.set_per_game(true)
		rebuild()
		return
	edit_requested.emit(game)
	if edit_requested.get_connections().is_empty() and is_inside_tree():
		var qm := get_tree().root.find_child("QuickMenu", true, false)
		if qm != null and qm.has_method("open"):
			qm.open(game)


func _on_reset() -> void:
	if not _armed:
		_armed = true
		reset_button.text = TC.RESET_CONFIRM
		return
	_armed = false
	model.reset_game()
	rebuild()


func _on_steam_input() -> void:
	if steam_button == null:
		return
	steam_button.text = TC.GYRO_STEAM_OPENING if SteamInput.open(game, open_uri) else TC.GYRO_STEAM_FAILED
