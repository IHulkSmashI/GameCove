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
	var moved := false
	for n in names:
		if not cfg.has_section(n):
			continue
		for k in cfg.get_section_keys(n):
			cfg.set_value(section(n, device_id), k, cfg.get_value(n, k))
		cfg.erase_section(n)
		moved = true
	return moved


## Files saved straight in `dir` (from before per-device folders) move into
## dir/<device id>/ once, unless that folder already has files. Returns the
## device folder.
static func migrate_dir(dir: String, device_id: String, extension := ".yaml") -> String:
	var dest := dir.path_join(key(device_id))
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
