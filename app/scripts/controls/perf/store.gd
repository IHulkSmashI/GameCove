extends RefCounted
## Where the perf controls keep their values: one ConfigFile, a section per
## scope and device ("perf/<scope>@<device id>", per_device.gd), so a drive
## that boots a Claw and an Ally keeps each one's choices. Scope "global" holds
## the device-wide settings (overlay look, shader threads); every other scope
## is a game key ("steam:976730", "epic:abc"). Thread-safe (hooks run on the
## Controls worker, the launch hook on the main thread).

const SettingsFile := preload("res://scripts/system/settings_file.gd")
const PerDevice := preload("res://scripts/device/per_device.gd")
const GLOBAL := "global"
const PREFIX := "perf/"

var path := "user://perf_controls.cfg"
var device_id := "unknown"
var _cfg: ConfigFile
var _mutex := Mutex.new()


func _init(cfg_path := "", device := "unknown") -> void:
	if cfg_path != "":
		path = cfg_path
	device_id = PerDevice.key(device)


func _section(scope: String) -> String:
	return PerDevice.section(PREFIX + scope, device_id)


func _load() -> void:
	if _cfg != null:
		return
	_cfg = SettingsFile.load_cfg(path)
	if PerDevice.adopt_unknown_cfg(_cfg, device_id):
		SettingsFile.save_cfg(_cfg, path)


func get_value(scope: String, key: String, fallback: Variant = null) -> Variant:
	_mutex.lock()
	_load()
	var v: Variant = _cfg.get_value(_section(scope), key, fallback)
	_mutex.unlock()
	return v


func has_value(scope: String, key: String) -> bool:
	_mutex.lock()
	_load()
	var h := _cfg.has_section_key(_section(scope), key)
	_mutex.unlock()
	return h


## null erases the key. Saved at once (a tiny file).
func set_value(scope: String, key: String, v: Variant) -> bool:
	_mutex.lock()
	_load()
	var s := _section(scope)
	if v == null:
		if _cfg.has_section_key(s, key):
			_cfg.erase_section_key(s, key)
	else:
		_cfg.set_value(s, key, v)
	var ok := SettingsFile.save_cfg(_cfg, path) == OK
	_mutex.unlock()
	return ok


func values(scope: String) -> Dictionary:
	_mutex.lock()
	_load()
	var out := {}
	var s := _section(scope)
	if _cfg.has_section(s):
		for k in _cfg.get_section_keys(s):
			out[k] = _cfg.get_value(s, k)
	_mutex.unlock()
	return out


## Game keys with saved values on this device.
func games() -> Array:
	_mutex.lock()
	_load()
	var out := []
	var tail := "@" + device_id
	for s in _cfg.get_sections():
		if s.begins_with(PREFIX) and s.ends_with(tail):
			var scope := s.substr(PREFIX.length(), s.length() - PREFIX.length() - tail.length())
			if scope != GLOBAL:
				out.append(scope)
	_mutex.unlock()
	out.sort()
	return out
