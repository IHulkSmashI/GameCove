extends RefCounted
## Values the system can't give back (night light strength and schedule, dim
## timers, the effect picked, radio states before airplane mode), saved per
## device in a ConfigFile section "<area>@<device id>" (per_device.gd), so one
## install that boots several handhelds keeps each one's own.
## ctx.config_path overrides the file (tests).

const PerDevice := preload("res://scripts/device/per_device.gd")
const DEFAULT_PATH := "user://controls_display.cfg"

var _path := DEFAULT_PATH
var _section := ""
var _cfg := ConfigFile.new()
var _mutex := Mutex.new()


func _init(ctx: Dictionary, area: String, device_id: String) -> void:
	_path = str(ctx.get("config_path", DEFAULT_PATH))
	_section = PerDevice.section(area, device_id)
	_cfg.load(_path)


func get_value(key: String, fallback: Variant = null) -> Variant:
	_mutex.lock()
	var v: Variant = _cfg.get_value(_section, key, fallback) if _cfg.has_section_key(_section, key) else fallback
	_mutex.unlock()
	return v


func set_value(key: String, v: Variant) -> bool:
	_mutex.lock()
	_cfg.set_value(_section, key, v)
	var err := _cfg.save(_path)
	_mutex.unlock()
	return err == OK
