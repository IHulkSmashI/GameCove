extends RefCounted
## Steam libraries GameCove has seen and the games each held when it could last be read:
## user://steam_libraries.json {"<library folder>": {"apps": ["<appid>", ...], "seen": unix}}.
##
## Storage's Clean up decides a shader cache is left over when no library has the game's
## manifest. An ejected SD card's manifests can't be read, and whether Steam keeps listing
## that library in libraryfolders.vdf isn't something to rely on. So the games of every
## library we have seen stay protected while that library can't be read, listed or not.
## A library not seen for FORGET_S (a card that was sold) is let go.
##
## Fed by the Library's Steam scan (every start and rescan) and by Storage; written only
## when something changed or once a day. Static and file-based: both run on worker threads.

const SettingsFile := preload("res://scripts/system/settings_file.gd")

const PATH := "user://steam_libraries.json"
const FORGET_S := 60 * 86400
const REFRESH_S := 86400

## Where the memory is kept (tests point it at their own folder).
static var path := PATH


## {library folder: {"apps": [appid], "seen": unix}}; {} when there's none.
static func read(file := "") -> Dictionary:
	var d: Variant = SettingsFile.load_json(file if file != "" else path).get("data")
	var out := {}
	if d is Dictionary:
		for k in d:
			var e: Variant = d[k]
			if e is Dictionary and e.get("apps") is Array:
				out[str(k)] = {"apps": (e["apps"] as Array).map(func(a): return str(a)), "seen": int(e.get("seen", 0))}
	return out


## Notes the libraries readable right now: `seen` is {library folder: [appid]}. Libraries
## not in `seen` are kept as they were, until they haven't been seen for FORGET_S.
static func remember(seen: Dictionary, now: int, file := "") -> void:
	var f := file if file != "" else path
	var mem := read(f)
	var changed := false
	for lib in seen:
		var apps: Array = (seen[lib] as Array).map(func(a): return str(a))
		apps.sort()
		var old: Dictionary = mem.get(str(lib), {})
		if old.is_empty() or old["apps"] != apps or now - int(old["seen"]) >= REFRESH_S:
			mem[str(lib)] = {"apps": apps, "seen": now}
			changed = true
	for lib in mem.keys():
		if not seen.has(lib) and now - int(mem[lib]["seen"]) > FORGET_S:
			mem.erase(lib)
			changed = true
	if changed:
		DirAccess.make_dir_recursive_absolute(SettingsFile.abs_path(f).get_base_dir())
		SettingsFile.save_json(f, mem, "\t")


## Games of remembered libraries that can't be read right now: {appid: library folder}.
## A remembered library that is readable speaks for itself (its manifests are read by the
## caller if it's in `listed`; if Steam dropped it from the list its games still count).
static func away(listed: Array, now: int, file := "") -> Dictionary:
	var out := {}
	var mem := read(file)
	for lib in mem:
		if now - int(mem[lib]["seen"]) > FORGET_S:
			continue
		var readable := DirAccess.open(str(lib).path_join("steamapps")) != null
		if readable and lib in listed:
			continue
		if readable:
			for id in apps_in(str(lib)):
				out[id] = lib
		else:
			for id in mem[lib]["apps"]:
				out[str(id)] = lib
	return out


## App ids with a manifest in a library folder.
static func apps_in(lib: String) -> Array:
	var out: Array = []
	for f in DirAccess.get_files_at(lib.path_join("steamapps")):
		if f.begins_with("appmanifest_") and f.ends_with(".acf"):
			out.append(f.trim_prefix("appmanifest_").trim_suffix(".acf"))
	out.sort()
	return out
