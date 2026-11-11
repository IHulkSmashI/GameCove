extends RefCounted
## What "Remove GameCove" does with the app's own data folder (user://) when "Keep my
## settings" is off (final review, high 9). Two things in there aren't GameCove's to throw
## away with its settings:
##
##   saves/backups       copies of game saves, taken before a cloud download or a restore
##                       could overwrite them. They stay unless the user turns on "Delete
##                       save backups too", which names how many there are and their size.
##   art/steam_backup    the art that was in Steam's grid folders before GameCove replaced
##                       it. Each one is put back first (SteamGrid.reset, entry by entry);
##                       an original that couldn't be put back (its Steam folder isn't
##                       there right now) keeps its backup folder.
##
## Everything else in the folder is deleted.

const SteamGrid := preload("res://scripts/library/art/steam_grid.gd")
const Steam := preload("res://scripts/library/stores/steam.gd")

const SAVE_BACKUPS := "saves/backups"
const ART_BACKUPS := "art/steam_backup"


## {"backups": int, "games": int, "bytes": int} for <user_dir>/saves/backups: one backup per
## <stamp>.json (save_backup.gd), every file's size counted.
static func save_backup_stats(user_dir: String) -> Dictionary:
	var out := {"backups": 0, "games": 0, "bytes": 0}
	var root := user_dir.path_join(SAVE_BACKUPS)
	if not DirAccess.dir_exists_absolute(root):
		return out
	for game in DirAccess.get_directories_at(root):
		var n := 0
		for f in DirAccess.get_files_at(root.path_join(game)):
			if f.ends_with(".json"):
				n += 1
			out["bytes"] += _size(root.path_join(game).path_join(f))
		if n > 0:
			out["games"] += 1
			out["backups"] += n
	return out


static func _size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	return int(f.get_length()) if f != null else 0


## "1.3 GB", "240 MB", "12 KB".
static func size_text(bytes: int) -> String:
	if bytes >= 1024 * 1024 * 1024:
		return "%.1f GB" % (bytes / 1073741824.0)
	if bytes >= 1024 * 1024:
		return "%d MB" % int(round(bytes / 1048576.0))
	return "%d KB" % int(maxf(1.0, ceil(bytes / 1024.0)))


## Steam's install folders under `home` (native, Flatpak, ...), as the art service finds them.
static func steam_roots(home: String) -> Array:
	var out: Array = []
	for r in Steam.STEAM_ROOTS:
		var p: String = Steam.expand(r, home)
		if not p in out:
			out.append(p)
	return out


## Puts every original back in Steam's grid folders. -> {"restored": entries put back,
## "left": entries still only in the backup (failed, or their grid folder isn't there)}.
static func restore_steam_art(user_dir: String, roots: Array) -> Dictionary:
	var backup_root := user_dir.path_join(ART_BACKUPS)
	var restored := 0
	if DirAccess.dir_exists_absolute(backup_root):
		for root in roots:
			for grid in SteamGrid.grid_dirs(str(root)):
				var dir := SteamGrid.backup_dir_for(backup_root, grid)
				for entry in SteamGrid.read_manifest(dir).keys():
					if SteamGrid.reset(grid, dir, str(entry)):
						restored += 1
	var left := 0
	for d in (DirAccess.get_directories_at(backup_root) if DirAccess.dir_exists_absolute(backup_root) else PackedStringArray()):
		left += SteamGrid.read_manifest(backup_root.path_join(d)).size()
	return {"restored": restored, "left": left}


## Deletes everything in `dir` (which must be under `under`) except the relative paths in
## `keep` and the folders leading to them. Links are removed, never followed. Returns the kept
## paths that exist. `dir` itself goes when nothing was kept.
static func remove_except(dir: String, under: String, keep: Array) -> Array:
	var kept: Array = []
	if under.length() < 2 or not dir.begins_with(under + "/") or ".." in dir:
		return kept
	_remove_except(dir, "", keep, kept)
	return kept


static func _remove_except(dir: String, rel: String, keep: Array, kept: Array) -> bool:
	var d := DirAccess.open(dir)
	if d == null:
		return false
	d.include_hidden = true
	var empty := true
	for sub in d.get_directories():
		var r := sub if rel == "" else rel + "/" + sub
		if d.is_link(sub):
			DirAccess.remove_absolute(dir + "/" + sub)
		elif r in keep:
			kept.append(r)
			empty = false
		elif keep.any(func(k): return str(k).begins_with(r + "/")):
			if not _remove_except(dir + "/" + sub, r, keep, kept):
				empty = false
		else:
			_remove_except(dir + "/" + sub, r, [], kept)
	for f in d.get_files():
		DirAccess.remove_absolute(dir + "/" + f)
	if empty:
		return DirAccess.remove_absolute(dir) == OK
	return false
