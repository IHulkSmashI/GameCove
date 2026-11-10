extends VBoxContainer
## The game page's "Game settings" card body. One switch row on top,
## "Custom settings for this game", then:
##   off  a read-only summary of the everyday profile it runs with
##        ("Everyday profile  Balanced · 17 W · 60 fps"), nothing to clip
##   on   the main values saved for it and Edit (the quick menu's This game
##        tab for it, where every change saves for this game); the page shows
##        the game's launch settings under the card
## Turning it off forgets the game's own settings (a Profiles game layer and
## its launch settings), so it asks first: the first press says what it does,
## the second does it. Steam games also get Steam's controller settings.
##
## setup(game, controls, profiles, launcher = null); signal edit_requested(game).
## Without a listener, Edit opens the scene's QuickMenu itself.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const TC := preload("res://scripts/ui/texts_controls.gd")
const Model := preload("res://scripts/ui/controls/model.gd")
const SteamInput := preload("res://scripts/ui/controls/steam_input.gd")
const BrandMark := preload("res://scripts/ui/brand_mark.gd")
const ChoiceRow := preload("res://scripts/ui/choice_row.gd")

signal edit_requested(game: Dictionary)
## The buttons changed (or custom settings went on / off); the page relinks
## its focus chain and shows or hides the launch settings.
signal relinked

const SHOW := 4
## Shown first when saved, in this order.
const PRIORITY := ["power.tdp", "display.fps_limit", "perf.overlay", "perf.upscaler", "perf.frame_gen",
	"perf.lsfg", "power.autotune_target", "display.refresh_rate", "power.fan_mode"]
## The everyday summary: power profile, TDP, frame limit (those that exist).
const SUMMARY := ["power.profile", "power.tdp", "display.fps_limit"]

var model: Object
var game: Dictionary = {}
## "Custom settings for this game".
var toggle: VBoxContainer
var edit_button: Button
## Gone: turning the switch off is the reset (it asks first). Kept for callers.
var reset_button: Button
## Steam games: gyro aiming, button layouts and the rest of Steam Input live
## in Steam's controller settings for the game; this opens them.
var steam_button: Button
## Launcher (launch settings): "custom" also counts launch settings that
## differ from the device's defaults, and off puts them back.
var launcher: Object
## `opener(uri) -> bool` instead of asking Steam (tests).
var open_uri := Callable()
var _armed := false


func setup(g: Dictionary, controls: Object, profiles: Object, launch: Object = null) -> void:
	name = "GameSettings"
	game = g
	launcher = launch
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
	for b in [toggle.button if toggle != null else null, edit_button, steam_button]:
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


## Does the game have its own settings: a Profiles game layer, or launch
## settings that differ from the device's defaults?
func custom() -> bool:
	return model.per_game() or _launch_custom()


func _launch_defaults() -> Dictionary:
	if launcher == null or not launcher.has_method("settings_for"):
		return {}
	if launcher.has_method("defaults_for") and launcher.has_method("profile"):
		return launcher.defaults_for(launcher.profile())
	return {}


func _launch_custom() -> bool:
	var d := _launch_defaults()
	return not d.is_empty() and launcher.settings_for(str(game.get("key", ""))) != d


## "Balanced · 17 W · 60 fps": the everyday values this game runs with.
func everyday_summary() -> String:
	var everyday: Dictionary = model.profiles.layer("", "") if model.profiles != null and model.profiles.has_method("layer") else {}
	var parts: Array[String] = []
	for id in SUMMARY:
		if not model.has(id):
			continue
		var d: Dictionary = model.describe(id)
		if d.is_empty() or not bool(d.get("available", true)):
			continue
		var v: Variant = everyday.get(id, d.get("value"))
		if v == null:
			continue
		parts.append(Model.value_label(d, v))
	return " · ".join(parts)


func rebuild() -> void:
	var had: Control = get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	var focus_toggle: bool = had != null and toggle != null and had == toggle.button
	for c in get_children():
		remove_child(c)
		c.queue_free()
	toggle = null
	edit_button = null
	reset_button = null
	steam_button = null
	_armed = false
	var on := custom()
	toggle = ChoiceRow.bool_row("custom", TC.GAME_CARD_TOGGLE, on)
	toggle.name = "Custom"
	# A narrow column wraps the title onto a second line (the row grows with
	# it) rather than cutting it or pushing the switch out of the card.
	var tl: Label = toggle.title_label
	tl.clip_text = false
	tl.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	tl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var btn: Button = toggle.button
	tl.resized.connect(func():
		if is_instance_valid(tl) and is_instance_valid(btn):
			btn.custom_minimum_size.y = maxf(52.0, tl.get_minimum_size().y + 20.0))
	toggle.collapse_hint = true
	toggle.set_explainer(func(v): return _toggle_line(bool(v)))
	toggle.changed.connect(_on_toggle)
	toggle.button.focus_exited.connect(func():
		if _armed and is_instance_valid(toggle):
			_armed = false
			toggle.set_explainer(func(v): return _toggle_line(bool(v))))
	add_child(toggle)
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
		if shown > 0:
			add_child(grid)
		else:
			grid.free()
		if vals.size() > shown:
			var more := Kit.label(TC.GAME_CARD_MORE % (vals.size() - shown), "QuietLabel")
			more.name = "More"
			more.add_theme_color_override("font_color", ThemeLib.color("text_3"))
			add_child(more)
	else:
		# Read-only: what it runs with now. Nothing to focus, nothing to clip.
		var sum := everyday_summary()
		var box := PanelContainer.new()
		box.name = "Everyday"
		box.add_theme_stylebox_override("panel", ThemeLib.box(ThemeLib.soft(0.05), ThemeLib.radius("m"), 16, 12))
		var col := Kit.vbox(4)
		col.add_child(Kit.micro(TC.GAME_CARD_EVERYDAY))
		var v := Kit.label(sum if sum != "" else TC.GAME_CARD_OFF, "")
		v.name = "Summary"
		v.add_theme_font_override("font", ThemeLib.mono(true, 0))
		v.add_theme_color_override("font_color", ThemeLib.color("text"))
		v.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		col.add_child(v)
		box.add_child(col)
		add_child(box)
	var row := Kit.hbox(12)
	row.name = "Buttons"
	if on:
		edit_button = Kit.secondary(TC.GAME_CARD_EDIT, "sliders")
		edit_button.name = "Edit"
		edit_button.custom_minimum_size = Vector2(0, 48)
		edit_button.pressed.connect(_on_edit)
		row.add_child(edit_button)
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
		row.add_child(steam_button)
	if row.get_child_count() > 0:
		add_child(row)
	else:
		row.free()
	relinked.emit()
	if had != null and is_inside_tree():
		Kit.focus_later(toggle.button if focus_toggle or edit_button == null else edit_button)


func _toggle_line(on: bool) -> String:
	if _armed:
		return TC.GAME_CARD_OFF_CONFIRM
	return TC.GAME_CARD_ON_LINE if on else TC.GAME_CARD_OFF_LINE


## On: starts from the current everyday values. Off forgets the game's own
## settings, so the first press only says so.
func _on_toggle(v: Variant) -> void:
	if bool(v):
		model.set_per_game(true)
		rebuild()
		return
	if not _armed:
		_armed = true
		toggle.set_value_quiet(true)
		toggle.set_explainer(func(x): return _toggle_line(bool(x)))
		return
	_armed = false
	model.set_per_game(false)
	var d := _launch_defaults()
	if not d.is_empty():
		launcher.save_settings(str(game.get("key", "")), d)
	rebuild()


func _on_edit() -> void:
	if not model.per_game():
		model.set_per_game(true)
	edit_requested.emit(game)
	if edit_requested.get_connections().is_empty() and is_inside_tree():
		var qm := get_tree().root.find_child("QuickMenu", true, false)
		if qm != null and qm.has_method("open"):
			qm.open(game)


func _on_steam_input() -> void:
	if steam_button == null:
		return
	steam_button.text = TC.GYRO_STEAM_OPENING if SteamInput.open(game, open_uri) else TC.GYRO_STEAM_FAILED
