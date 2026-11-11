extends RefCounted
## Which shortcuts the quick menu's strip shows, and in what order. Saved in
## user://ui.cfg ([quick_menu] order, hidden) through settings_file.gd.
##
## `order` always lists every strip action once (new ones join at the end,
## hidden), so the settings list and the strip agree after an update.

const SettingsFile := preload("res://scripts/system/settings_file.gd")
const Registry := preload("res://scripts/actions/registry.gd")
const UiPrefs := preload("res://scripts/ui/ui_prefs.gd")

const SECTION := "quick_menu"

static var order: Array = []
static var hidden: Array = []
static var _loaded_from := ""


static func _path() -> String:
	return UiPrefs.path


## The usual strip: STRIP_DEFAULT shown in its order, the rest hidden after it.
static func defaults() -> Dictionary:
	var all := Registry.strip_ids()
	var o: Array = Registry.STRIP_DEFAULT.filter(func(i): return i in all)
	var h: Array = []
	for id in all:
		if not id in o:
			o.append(id)
			h.append(id)
	return {"order": o, "hidden": h}


## Any saved lists made whole: unknown ids dropped, doubles dropped, missing
## actions added at the end, hidden.
static func clean(saved_order: Variant, saved_hidden: Variant) -> Dictionary:
	var all := Registry.strip_ids()
	var o: Array = []
	var h: Array = []
	if saved_order is Array:
		for id in saved_order:
			if str(id) in all and not str(id) in o:
				o.append(str(id))
	if saved_hidden is Array:
		for id in saved_hidden:
			if str(id) in o and not str(id) in h:
				h.append(str(id))
	if o.is_empty():
		return defaults()
	for id in all:
		if not id in o:
			o.append(id)
			h.append(id)
	return {"order": o, "hidden": h}


static func load_prefs() -> void:
	_loaded_from = _path()
	var d := defaults()
	if FileAccess.file_exists(_path()):
		var cfg := SettingsFile.load_cfg(_path())
		if cfg.has_section_key(SECTION, "order"):
			d = clean(cfg.get_value(SECTION, "order", []), cfg.get_value(SECTION, "hidden", []))
	order = d["order"]
	hidden = d["hidden"]


static func _ensure() -> void:
	if order.is_empty() or _loaded_from != _path():
		load_prefs()


static func save_prefs() -> void:
	var o := order.duplicate()
	var h := hidden.duplicate()
	SettingsFile.update_cfg(_path(), func(cfg: ConfigFile):
		cfg.set_value(SECTION, "order", o)
		cfg.set_value(SECTION, "hidden", h))


## Every strip action, in the user's order.
static func all() -> Array:
	_ensure()
	return order.duplicate()


## The ones the strip shows, in order.
static func shown() -> Array:
	_ensure()
	return order.filter(func(i): return not i in hidden)


static func is_shown(id: String) -> bool:
	_ensure()
	return id in order and not id in hidden


static func set_shown(id: String, on: bool) -> void:
	_ensure()
	if not id in order:
		return
	hidden.erase(id)
	if not on:
		hidden.append(id)
	save_prefs()


## Moves `id` one place up (-1) or down (+1). False at the end of the list.
static func move(id: String, d: int) -> bool:
	_ensure()
	var i := order.find(id)
	var j := i + (1 if d > 0 else -1)
	if i < 0 or j < 0 or j >= order.size():
		return false
	order[i] = order[j]
	order[j] = id
	save_prefs()
	return true


static func reset() -> void:
	var d := defaults()
	order = d["order"]
	hidden = d["hidden"]
	_loaded_from = _path()
	save_prefs()
