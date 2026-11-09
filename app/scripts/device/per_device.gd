extends RefCounted
## Settings that belong to one handheld. One GameCove install (one drive) can
## boot several handhelds, so anything that only makes sense on the hardware it
## was picked on (TDP profile and watts, charge limit, fan preset, controller
## layouts, measured frame rates) is stored under the device id
## (devices.json row id, Device.id(); "unknown" for unlisted hardware).
## Values saved before this existed belong to no device; the first device that
## reads them takes them over (a one-time move), which is the one they were
## picked on as long as the update is started on that device.
##
## ConfigFile: section "<name>@<device id>" (e.g. "profile@msi-claw-8-ex").
## Folders:    <dir>/<device id>/... (e.g. InputPlumber profiles).

const SettingsFile := preload("res://scripts/system/settings_file.gd")
const UNKNOWN := "unknown"

## A device id that is safe as a file name and a ConfigFile section suffix.
static func key(device_id: String) -> String:
	var out := ""
	for c in device_id.strip_edges().to_lower():
		out += c if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "-" or c == "_" else "-"
	return out if out != "" else "unknown"


static func section(name: String, device_id: String) -> String:
	return "%s@%s" % [name, key(device_id)]


## Moves the legacy (device-less) sections into this device's. Legacy values win
## over the device's own: they are newer (first-run setup still writes them).
## True when something moved (the caller saves).
static func migrate_cfg(cfg: ConfigFile, names: Array, device_id: String) -> bool:
	var moved := adopt_unknown_cfg(cfg, device_id)
	for n in names:
		if not cfg.has_section(n):
			continue
		for k in cfg.get_section_keys(n):
			cfg.set_value(section(n, device_id), k, cfg.get_value(n, k))
		cfg.erase_section(n)
		moved = true
	return moved


## Settings picked while devices.json didn't know this handheld (id "unknown", review M25)
## belong to it once a release adds its row: every "<name>@unknown" section moves to
## "<name>@<device>" where this device has no such section yet (one-time; its own values
## win). True when something moved (the caller saves).
static func adopt_unknown_cfg(cfg: ConfigFile, device_id: String) -> bool:
	var k := key(device_id)
	if k == UNKNOWN:
		return false
	var moved := false
	for sec in cfg.get_sections():
		if not sec.ends_with("@" + UNKNOWN):
			continue
		var dest := section(sec.trim_suffix("@" + UNKNOWN), k)
		if cfg.has_section(dest):
			continue
		for kk in cfg.get_section_keys(sec):
			cfg.set_value(dest, kk, cfg.get_value(sec, kk))
		cfg.erase_section(sec)
		moved = true
	return moved


## adopt_unknown_cfg() on a settings file, saved when something moved.
static func adopt_file(path: String, device_id: String) -> void:
	if key(device_id) == UNKNOWN or not FileAccess.file_exists(path):
		return
	SettingsFile.update_cfg(path, func(cfg: ConfigFile): return adopt_unknown_cfg(cfg, device_id))


## Files saved straight in `dir` (from before per-device folders) move into
## dir/<device id>/ once, unless that folder already has files. Returns the
## device folder.
static func migrate_dir(dir: String, device_id: String, extension := ".yaml") -> String:
	var dest := dir.path_join(key(device_id))
	# layouts made while the handheld was "unknown" move to its own folder (review M25)
	var unknown := dir.path_join(UNKNOWN)
	if key(device_id) != UNKNOWN and DirAccess.dir_exists_absolute(unknown) and \
			(not DirAccess.dir_exists_absolute(dest) or DirAccess.get_files_at(dest).is_empty()):
		if DirAccess.dir_exists_absolute(dest):
			DirAccess.remove_absolute(dest)
		DirAccess.rename_absolute(unknown, dest)
	var d := DirAccess.open(dir)
	if d == null:
		return dest
	var legacy: Array = []
	for f in d.get_files():
		if f.ends_with(extension):
			legacy.append(f)
	if legacy.is_empty():
		return dest
	var existing := DirAccess.open(dest)
	if existing != null and not existing.get_files().is_empty():
		return dest
	DirAccess.make_dir_recursive_absolute(dest)
	for f in legacy:
		DirAccess.rename_absolute(dir.path_join(f), dest.path_join(f))
	return dest
