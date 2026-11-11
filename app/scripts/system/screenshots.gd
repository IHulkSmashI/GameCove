extends RefCounted
## The screenshots GameCove took (gamescope's screenshot, saved by the
## system.screenshot Control as Pictures/Screenshots/GameCove_<date>_<time>.png)
## for Settings > Media: list, small pictures, delete. Only GameCove's own
## files are listed or deleted; other pictures in that folder aren't ours.
## File work: call from a worker thread.

const DIR := "Pictures/Screenshots"
const PREFIX := "GameCove_"
const THUMB_W := 256


static func root(home: String) -> String:
	return home.path_join(DIR)


## Newest first: [{"path", "game": "", "name", "size", "mtime"}] (the shape clip rows read).
static func list(dir: String) -> Array:
	var out: Array = []
	if not DirAccess.dir_exists_absolute(dir):
		return out
	for f in DirAccess.get_files_at(dir):
		if not f.begins_with(PREFIX) or f.get_extension().to_lower() != "png":
			continue
		var p := dir.path_join(f)
		var size := FileAccess.get_size(p)
		if size <= 0:
			continue
		out.append({"path": p, "game": "", "name": f.get_basename(), "size": size, "mtime": FileAccess.get_modified_time(p)})
	out.sort_custom(func(a, b): return int(a["mtime"]) > int(b["mtime"]) if int(a["mtime"]) != int(b["mtime"]) else str(a["path"]) > str(b["path"]))
	return out


## A small copy of the picture for a row, or null.
static func thumb(path: String) -> Image:
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	if img == null or img.is_empty() or img.get_width() <= 0:
		return null
	if img.get_width() > THUMB_W:
		img.resize(THUMB_W, maxi(1, int(round(float(img.get_height()) * THUMB_W / img.get_width()))), Image.INTERPOLATE_BILINEAR)
	return img


## Deletes one of GameCove's screenshots (only inside `dir`).
static func delete(dir: String, path: String) -> bool:
	var r := dir.simplify_path()
	var p := path.simplify_path()
	if p.get_base_dir() != r or not p.get_file().begins_with(PREFIX) or not FileAccess.file_exists(p):
		return false
	return DirAccess.remove_absolute(p) == OK
