extends VBoxContainer
## Per-game settings (Launcher.settings_for / save_settings), shared by the game
## page and the quick menu's "This game" section. Picking a quick goal sets the
## frame limit, upscaler and frame generation to that goal's preset.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Texts := preload("res://scripts/ui/texts.gd")
const ChoiceRow := preload("res://scripts/ui/choice_row.gd")

signal goal_changed(goal: String)
signal saved(settings: Dictionary)

var game_key := ""
var settings: Dictionary = {}
var rows := {}
var _launcher: Object


## Rows for settings that go into the game's launch environment.
const ENV_KEYS := ["upscaler", "frame_gen", "low_latency"]
const STEAM_ENV_NOTE := "Steam starts this game, so upscaling, frame generation and low latency can't be set from here. Set them in the game's Steam launch options."

## with_env_settings false (Steam games): no upscaler / frame generation / low
## latency rows, since we can't pass a steam:// launch any environment; one line says so.
func setup(key: String, launcher: Object, with_low_latency: bool, with_env_settings := true) -> void:
	name = "SettingsForm"
	game_key = key
	_launcher = launcher
	settings = launcher.settings_for(key)
	add_theme_constant_override("separation", 18)

	var goals: Array = Texts.GOALS
	_add(_choice("goal", goals, goals.map(func(g): return Texts.GOAL_LABELS[g])))
	var fps: Array = Texts.FPS_LIMITS.duplicate()
	if int(settings.get("fps_limit", 0)) not in fps:
		fps.append(int(settings["fps_limit"]))
		fps.sort()
	_add(_choice("fps_limit", fps, fps.map(func(f): return Texts.fps_label(f))))
	if not with_env_settings:
		var note := Kit.label(STEAM_ENV_NOTE, "QuietLabel", true)
		note.name = "SteamNote"
		add_child(note)
		return
	var ups: Array = Texts.UPSCALERS
	_add(_choice("upscaler", ups, ups.map(func(u): return Texts.UPSCALER_LABELS[u])))
	_add(ChoiceRow.bool_row("frame_gen", Texts.TITLES["frame_gen"], bool(settings.get("frame_gen", false))))
	if with_low_latency:
		_add(ChoiceRow.bool_row("low_latency", Texts.TITLES["low_latency"], bool(settings.get("low_latency", true))))


## Re-read saved settings (e.g. after the quick menu changed them) without
## rebuilding, so focus stays where it is.
func reload() -> void:
	settings = _launcher.settings_for(game_key)
	for k in rows:
		if settings.has(k):
			rows[k].set_value_quiet(settings[k])


func focusables() -> Array:
	return rows.values().map(func(r): return r.button)


func _choice(k: String, vals: Array, lbls: Array) -> VBoxContainer:
	var r: VBoxContainer = ChoiceRow.new()
	r.setup(k, Texts.TITLES[k], vals, lbls, settings.get(k))
	return r


func _add(r: VBoxContainer) -> void:
	rows[r.key] = r
	r.changed.connect(_on_changed.bind(r.key))
	add_child(r)


func _on_changed(v: Variant, k: String) -> void:
	if k == "goal":
		settings = Texts.apply_goal(settings, v)
		for f in ["fps_limit", "upscaler", "frame_gen"]:
			if rows.has(f):
				rows[f].set_value_quiet(settings[f])
	else:
		settings[k] = v
	_launcher.save_settings(game_key, settings)
	saved.emit(settings)
	if k == "goal":
		goal_changed.emit(v)
