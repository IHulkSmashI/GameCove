extends RefCounted
## Steam's own custom-art folder, userdata/<account>/config/grid, the way Steam
## and SteamGridDB's tools name the files:
##   <appid>p.png      portrait cover (library capsule, 600x900)
##   <appid>_hero.png  hero banner
##   <appid>_logo.png  logo
##   <appid>_icon.png  icon
##   <appid>.json      logo position: {"nVersion": 1, "logoPosition": {"pinnedPosition",
##                     "nWidthPct", "nHeightPct"}}
## (.jpg works as well as .png for the images). Steam shows changes after it
## restarts or reloads its library.
##
## Every file we replace is first copied to a backup folder, once (the first
## original is the one kept), with a manifest of what was there; reset()
## deletes our file and puts the originals back. Nothing outside the grid
## folder and the backup folder is touched.

const NAMES := {"cover": "%sp", "hero": "%s_hero", "logo": "%s_logo", "icon": "%s_icon"}
const EXTS := ["png", "jpg", "jpeg", "webp"]
const PINS := ["BottomLeft", "UpperLeft", "CenterCenter", "UpperCenter", "BottomCenter"]


static func base_name(appid: String, kind: String) -> String:
	return str(NAMES.get(kind, "")) % appid if NAMES.has(kind) and appid.is_valid_int() else ""


## Grid folders of every Steam account on this machine.
static func grid_dirs(steam_root: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(steam_root.path_join("userdata"))
	if dir == null:
		return out
	for d in dir.get_directories():
		if d.is_valid_int() and d != "0":
			out.append(steam_root.path_join("userdata").path_join(d).path_join("config/grid"))
	return out


static func _manifest_path(backup_dir: String) -> String:
	return backup_dir.path_join("manifest.json")


static func read_manifest(backup_dir: String) -> Dictionary:
	var p := _manifest_path(backup_dir)
	if not FileAccess.file_exists(p):
		return {}
	var j := JSON.new()
	if j.parse(FileAccess.get_file_as_string(p)) != OK or not j.data is Dictionary:
		return {}
	return j.data


static func _save_manifest(backup_dir: String, m: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(backup_dir)
	var f := FileAccess.open(_manifest_path(backup_dir), FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(m, "\t"))
	f.close()
	return true


## Files in `grid` that are this base name with any image extension.
static func existing(grid: String, base: String) -> Array[String]:
	var out: Array[String] = []
	for e in EXTS:
		if FileAccess.file_exists(grid.path_join(base + "." + e)):
			out.append(base + "." + e)
	return out


## Backs up whatever `base`.* (and, for logos, the position file) is in `grid`,
## once. Returns false if a backup couldn't be written (then nothing changes).
static func _backup(grid: String, backup_dir: String, entry: String, files: Array) -> bool:
	var m := read_manifest(backup_dir)
	if m.has(entry):
		return true   # the first originals are already safe
	DirAccess.make_dir_recursive_absolute(backup_dir)
	var saved := []
	for f in files:
		if FileAccess.file_exists(grid.path_join(f)):
			if DirAccess.copy_absolute(grid.path_join(f), backup_dir.path_join(f)) != OK:
				return false
			saved.append(f)
	m[entry] = {"had": saved, "at": int(Time.get_unix_time_from_system())}
	return _save_manifest(backup_dir, m)


## Puts `src` (a png / jpg / webp file) in `grid` as this game's `kind`. webp
## is converted to png (Steam doesn't read webp there). Returns the written path, or "".
static func apply(grid: String, backup_dir: String, appid: String, kind: String, src: String) -> String:
	var base := base_name(appid, kind)
	if base == "" or not FileAccess.file_exists(src):
		return ""
	DirAccess.make_dir_recursive_absolute(grid)
	if not _backup(grid, backup_dir, base, existing(grid, base)):
		return ""
	var ext := src.get_extension().to_lower()
	var tmp := grid.path_join(base + ".gamecove-part")
	if ext == "webp":
		var img := Image.new()
		if img.load_webp_from_buffer(FileAccess.get_file_as_bytes(src)) != OK or img.save_png(tmp) != OK:
			return ""
		ext = "png"
	elif ext in ["png", "jpg", "jpeg"]:
		if DirAccess.copy_absolute(src, tmp) != OK:
			return ""
	else:
		return ""
	for f in existing(grid, base):
		DirAccess.remove_absolute(grid.path_join(f))
	var dest := grid.path_join(base + "." + ext)
	if DirAccess.rename_absolute(tmp, dest) != OK:
		DirAccess.remove_absolute(tmp)
		return ""
	return dest


## Steam's logo position for this game ({} when there's no file or it's unreadable).
static func logo_position(grid: String, appid: String) -> Dictionary:
	var p := grid.path_join(appid + ".json")
	if not appid.is_valid_int() or not FileAccess.file_exists(p):
		return {}
	var j := JSON.new()
	if j.parse(FileAccess.get_file_as_string(p)) != OK or not j.data is Dictionary or not j.data.get("logoPosition") is Dictionary:
		return {}
	var lp: Dictionary = j.data["logoPosition"]
	return {"pin": str(lp.get("pinnedPosition", "BottomLeft")), "width": float(lp.get("nWidthPct", 50)), "height": float(lp.get("nHeightPct", 50))}


## Writes the logo position file (backed up first, like the images).
static func set_logo_position(grid: String, backup_dir: String, appid: String, pin: String, width_pct: float, height_pct: float) -> bool:
	if not appid.is_valid_int() or not pin in PINS:
		return false
	var name := appid + ".json"
	DirAccess.make_dir_recursive_absolute(grid)
	if not _backup(grid, backup_dir, name, [name]):
		return false
	var f := FileAccess.open(grid.path_join(name), FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"nVersion": 1, "logoPosition": {"pinnedPosition": pin,
		"nWidthPct": clampf(width_pct, 10.0, 100.0), "nHeightPct": clampf(height_pct, 10.0, 100.0)}}))
	f.close()
	return true


## Undo: removes what we wrote for `entry` (a base name from base_name(), or
## "<appid>.json") and restores the originals from the backup. True when the
## folder is back as it was (or we never changed it).
static func reset(grid: String, backup_dir: String, entry: String) -> bool:
	var m := read_manifest(backup_dir)
	if not m.has(entry):
		return true
	var ours: Array[String] = []
	if entry.ends_with(".json"):
		ours.append(entry)
	else:
		ours = existing(grid, entry)
	for f in ours:
		DirAccess.remove_absolute(grid.path_join(f))
	var ok := true
	for f in m[entry].get("had", []):
		if DirAccess.copy_absolute(backup_dir.path_join(str(f)), grid.path_join(str(f))) != OK:
			ok = false
		else:
			DirAccess.remove_absolute(backup_dir.path_join(str(f)))
	if ok:
		m.erase(entry)
		_save_manifest(backup_dir, m)
	return ok


## Where the backups for one grid folder live: <backup_root>/<account id>.
static func backup_dir_for(backup_root: String, grid: String) -> String:
	return backup_root.path_join(grid.get_base_dir().get_base_dir().get_file())
