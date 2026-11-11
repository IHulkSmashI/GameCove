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
## Every file we replace is first copied to a backup folder with a manifest of
## what was there and what we wrote (name and sha256); reset() deletes our file
## and puts the originals back. While the file in the grid folder is still the
## one we wrote, a second pick keeps the first originals. When it isn't (the
## user set their own art in Steam after our pick, or removed ours), that is
## the user's choice: a second pick backs it up as the new original, and
## reset() leaves it alone instead of deleting it for an older picture.
## Nothing outside the grid folder and the backup folder is touched.
##
## The manifest's read-modify-write runs under one lock: the automatic fill
## and a pick work on different threads.

const ImageGuard := preload("res://scripts/ui/image_guard.gd")
const NAMES := {"cover": "%sp", "hero": "%s_hero", "logo": "%s_logo", "icon": "%s_icon"}
const EXTS := ["png", "jpg", "jpeg", "webp"]
const PINS := ["BottomLeft", "UpperLeft", "CenterCenter", "UpperCenter", "BottomCenter"]

static var _lock := Mutex.new()


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
	# atomic: a torn manifest would forget which originals to put back (review 2, low 23)
	return preload("res://scripts/system/settings_file.gd").save_json(_manifest_path(backup_dir), m, "\t") == OK


## Files in `grid` that are this base name with any image extension.
static func existing(grid: String, base: String) -> Array[String]:
	var out: Array[String] = []
	for e in EXTS:
		if FileAccess.file_exists(grid.path_join(base + "." + e)):
			out.append(base + "." + e)
	return out


## True when what's in `grid` for `entry` is exactly what we wrote last (same file, same
## bytes). A manifest from before we recorded that can't tell: it counts as ours.
static func _still_ours(grid: String, rec: Dictionary, now: Array) -> bool:
	var ours: Variant = rec.get("ours")
	if not ours is Dictionary:
		return true
	return now.size() == 1 and str(now[0]) == str(ours.get("file", "")) \
		and FileAccess.get_sha256(grid.path_join(str(now[0]))) == str(ours.get("sha", ""))


## Backs up `now` (the files in `grid` that are about to be replaced) for `entry` unless
## the first originals are already safe and the files there are still ours. Returns false
## if a backup couldn't be written (then nothing changes). Call with the lock held.
static func _backup(grid: String, backup_dir: String, entry: String, now: Array, m: Dictionary) -> bool:
	if m.has(entry) and _still_ours(grid, m[entry], now):
		return true   # the first originals are already safe
	DirAccess.make_dir_recursive_absolute(backup_dir)
	var saved := []
	for f in now:
		if FileAccess.file_exists(grid.path_join(f)):
			if DirAccess.copy_absolute(grid.path_join(f), backup_dir.path_join(f)) != OK:
				return false
			saved.append(f)
	m[entry] = {"had": saved, "at": int(Time.get_unix_time_from_system())}
	return _save_manifest(backup_dir, m)


## Notes what we wrote for `entry`, so a later pick or reset can tell our file from one
## the user put there since.
static func _note_ours(grid: String, backup_dir: String, entry: String, file: String, m: Dictionary) -> void:
	if m.has(entry):
		m[entry]["ours"] = {"file": file, "sha": FileAccess.get_sha256(grid.path_join(file))}
		_save_manifest(backup_dir, m)


## Puts `src` (a png / jpg / webp file) in `grid` as this game's `kind`. webp
## is converted to png (Steam doesn't read webp there). Returns the written path, or "".
static func apply(grid: String, backup_dir: String, appid: String, kind: String, src: String) -> String:
	var base := base_name(appid, kind)
	if base == "" or not FileAccess.file_exists(src):
		return ""
	_lock.lock()
	var out := _apply(grid, backup_dir, base, src)
	_lock.unlock()
	return out


static func _apply(grid: String, backup_dir: String, base: String, src: String) -> String:
	DirAccess.make_dir_recursive_absolute(grid)
	var m := read_manifest(backup_dir)
	if not _backup(grid, backup_dir, base, existing(grid, base), m):
		return ""
	var ext := src.get_extension().to_lower()
	var tmp := grid.path_join(base + ".gamecove-part")
	if ext == "webp":
		var img := ImageGuard.load_known(src)   # a picture the header of which names a huge canvas isn't decoded
		if img == null or img.save_png(tmp) != OK:
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
	_note_ours(grid, backup_dir, base, dest.get_file(), m)
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
	_lock.lock()
	DirAccess.make_dir_recursive_absolute(grid)
	var m := read_manifest(backup_dir)
	var now: Array = [name] if FileAccess.file_exists(grid.path_join(name)) else []
	var f: FileAccess = FileAccess.open(grid.path_join(name), FileAccess.WRITE) if _backup(grid, backup_dir, name, now, m) else null
	if f == null:
		_lock.unlock()
		return false
	f.store_string(JSON.stringify({"nVersion": 1, "logoPosition": {"pinnedPosition": pin,
		"nWidthPct": clampf(width_pct, 10.0, 100.0), "nHeightPct": clampf(height_pct, 10.0, 100.0)}}))
	f.close()
	_note_ours(grid, backup_dir, name, name, m)
	_lock.unlock()
	return true


## Undo: removes what we wrote for `entry` (a base name from base_name(), or
## "<appid>.json") and restores the originals from the backup. True when the
## folder is back as it was (or we never changed it). When what's there is no
## longer what we wrote (the user set or removed art in Steam since), it is left
## exactly as it is and we only stop tracking the game: the user's later choice
## beats the older original.
static func reset(grid: String, backup_dir: String, entry: String) -> bool:
	_lock.lock()
	var ok := _reset(grid, backup_dir, entry)
	_lock.unlock()
	return ok


static func _reset(grid: String, backup_dir: String, entry: String) -> bool:
	var m := read_manifest(backup_dir)
	if not m.has(entry):
		return true
	var ours: Array[String] = []
	if entry.ends_with(".json"):
		if FileAccess.file_exists(grid.path_join(entry)):
			ours.append(entry)
	else:
		ours = existing(grid, entry)
	if not _still_ours(grid, m[entry], ours):
		m.erase(entry)
		return _save_manifest(backup_dir, m)
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


## Where the backups for one grid folder live: <backup_root>/<account id>-<hash of the
## grid folder's resolved path>. Native and Flatpak Steam can share an account id, so
## the id alone made the two folders share (and overwrite) one backup (review 2,
## problem 9). A backup from before, keyed by the id alone, is taken over by the
## first folder that asks for it.
static func backup_dir_for(backup_root: String, grid: String) -> String:
	var id := grid.get_base_dir().get_base_dir().get_file()
	var dir := backup_root.path_join("%s-%s" % [id, resolve(grid).sha256_text().substr(0, 12)])
	var legacy := backup_root.path_join(id)
	if not DirAccess.dir_exists_absolute(dir) and FileAccess.file_exists(_manifest_path(legacy)):
		DirAccess.rename_absolute(legacy, dir)
	return dir


## `path` with every symlink in it followed (~/.steam/steam -> ~/.local/share/Steam),
## so one folder reached two ways gets one backup.
static func resolve(path: String) -> String:
	var parts := path.simplify_path().split("/", false)
	var out := ""
	var hops := 0
	var i := 0
	while i < parts.size():
		var parent := out if out != "" else "/"
		var name := parts[i]
		var da := DirAccess.open(parent)
		if da != null and da.is_link(name) and hops < 40:
			hops += 1
			var target := da.read_link(name)
			var rest := parts.slice(i + 1)
			var base := target if target.begins_with("/") else parent.path_join(target)
			parts = PackedStringArray(base.simplify_path().split("/", false)) + rest
			out = ""
			i = 0
			continue
		out += "/" + name
		i += 1
	return out if out != "" else "/"
