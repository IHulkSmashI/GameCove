extends RefCounted
## Quiet sysfs helpers: a missing folder or file is just "nothing there" (no
## engine errors), and files are read line by line because sysfs reports a
## size (4096) that doesn't match what a read returns.


static func read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var lines := PackedStringArray()
	while true:
		var l := f.get_line()
		if f.eof_reached() and l == "":
			break
		lines.append(l)
		if f.eof_reached():
			break
	return "\n".join(lines).strip_edges()


static func read_int(path: String) -> int:
	var s := read_text(path)
	return s.to_int() if s.is_valid_int() else -1


## Names in a folder (sub-folders and files: sysfs class entries are symlinks), sorted.
static func entries(dir: String) -> Array:
	if not DirAccess.dir_exists_absolute(dir):
		return []
	var out := Array(DirAccess.get_directories_at(dir))
	for f in DirAccess.get_files_at(dir):
		if not out.has(f):
			out.append(f)
	out.sort()
	return out
