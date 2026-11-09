extends RefCounted
## Builds fixture trees (fake / and $HOME) in user:// and the ctx the display,
## audio and system providers get, so tests never touch real paths.

const Fake := preload("res://tests/fixtures/ctl_display/fake_system.gd")
const DeviceScript := preload("res://scripts/device/device.gd")
const BASE := "user://test_ctl_display"


static func rm_rf(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	for d in DirAccess.get_directories_at(path):
		rm_rf(path.path_join(d))
	DirAccess.remove_absolute(path)


## A fresh tree: {"rel/path": "content"}; returns its absolute root.
static func tree(name: String, files: Dictionary) -> String:
	var root := ProjectSettings.globalize_path(BASE).path_join(name)
	rm_rf(root)
	DirAccess.make_dir_recursive_absolute(root)
	for rel in files:
		var p: String = root.path_join(rel)
		DirAccess.make_dir_recursive_absolute(p.get_base_dir())
		var f := FileAccess.open(p, FileAccess.WRITE)
		f.store_string(str(files[rel]))
		f.close()
	return root


## The devices.json row with this id ({} when unknown).
static func row(id: String) -> Dictionary:
	for r in DeviceScript.load_table():
		if r.get("id") == id:
			return r
	return {}


static func all_rows() -> Array:
	return DeviceScript.load_table()


## A fake system with gamescope running and a ctx around it.
static func make(name: String, device_id: String, files := {}, env := {}) -> Dictionary:
	var root := tree(name, files)
	var fake = Fake.new()
	fake.root = root
	fake.props = {"GAMESCOPE_FOCUSABLE_APPS": "769, 413091", "GAMESCOPE_FOCUSED_APP": "769"}
	var e := {"GAMESCOPE_WAYLAND_DISPLAY": "", "CUSTOM_REFRESH_RATES": "", "STEAM_DISPLAY_REFRESH_LIMITS": ""}
	e.merge(env, true)
	var ctx := {"sys_root": root, "runner": fake, "home": root.path_join("home/deck"),
		"device": row(device_id), "env": e, "config_path": root.path_join("controls.cfg")}
	return {"root": root, "fake": fake, "ctx": ctx}


## Session script present (gamescope-session-plus), so environment.d settings apply.
const SESSION := {"usr/share/gamescope-session-plus/gamescope-session-plus": "#!/bin/bash\n"}
