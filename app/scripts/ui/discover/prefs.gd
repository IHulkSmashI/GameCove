extends RefCounted
## Small UI choices for Discover that should survive a restart: calendar
## layout, deals sort/store, and whether the gg.deals card was dismissed.
## Tests point `path` at a temp file (or "" to keep everything in memory).

const SettingsFile := preload("res://scripts/system/settings_file.gd")

var path := "user://discover_ui.cfg"
var values := {"calendar_layout": "list", "deals_sort": "best", "deals_store": "", "gg_dismissed": false}


func _init(file := "user://discover_ui.cfg") -> void:
	path = file
	if path == "":
		return
	var c := SettingsFile.load_cfg(path)
	for k in values:
		values[k] = c.get_value("discover", k, values[k])


func get_value(k: String) -> Variant:
	return values.get(k)


func set_value(k: String, v: Variant) -> void:
	values[k] = v
	if path == "":
		return
	SettingsFile.update_cfg(path, func(c: ConfigFile):
		for key in values:
			c.set_value("discover", key, values[key]))
