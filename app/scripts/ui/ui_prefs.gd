extends RefCounted
## Look-and-feel preferences: theme, accent from game art, reduce motion,
## interface size (ui_scale.gd).
## Saved in user://ui.cfg. Applying them is main.gd's job (apply_theme);
## this file only stores and validates.

const SettingsFile := preload("res://scripts/system/settings_file.gd")
const Themes := preload("res://theme/themes.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const UiScale := preload("res://scripts/ui/ui_scale.gd")

const PATH := "user://ui.cfg"
const DEFAULTS := {"theme": "cove", "match_art": true, "reduce_motion": false, "interface_size": "default"}

static var theme := "cove"
static var match_art := true
## "small" | "default" | "large" | "largest": multiplies the automatic scale.
static var interface_size := "default"
static var path := PATH


static func load_prefs(from := "") -> void:
	if from != "":
		path = from
	if not FileAccess.file_exists(path):
		set_values(DEFAULTS)
		return
	var cfg := SettingsFile.load_cfg(path)
	if cfg.get_sections().is_empty():
		set_values(DEFAULTS)
		return
	set_values({
		"theme": cfg.get_value("ui", "theme", DEFAULTS["theme"]),
		"match_art": cfg.get_value("ui", "match_art", DEFAULTS["match_art"]),
		"reduce_motion": cfg.get_value("ui", "reduce_motion", DEFAULTS["reduce_motion"]),
		"interface_size": cfg.get_value("ui", "interface_size", DEFAULTS["interface_size"]),
	})


static func save_prefs() -> void:
	# main.gd keeps more keys in [ui]: update, never replace the file
	SettingsFile.update_cfg(path, func(cfg: ConfigFile):
		for k in values():
			cfg.set_value("ui", k, values()[k]))


static func values() -> Dictionary:
	return {"theme": theme, "match_art": match_art, "reduce_motion": Motion.reduce, "interface_size": interface_size}


static func set_values(v: Dictionary) -> void:
	var t: String = str(v.get("theme", theme))
	theme = t if Themes.has_theme(t) else "cove"
	match_art = bool(v.get("match_art", match_art))
	Motion.reduce = bool(v.get("reduce_motion", Motion.reduce))
	var sz := str(v.get("interface_size", interface_size))
	interface_size = sz if sz in UiScale.SIZES else "default"
