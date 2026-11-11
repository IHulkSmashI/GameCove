extends RefCounted
## Install folders and free space. Default install folder is ~/Games/<store>;
## removable drives (SD cards, USB) are the folders mounted under /run/media
## (udisks2 mounts them at /run/media/<user>/<label>; SteamOS also uses
## /run/media/<label> such as /run/media/mmcblk0p1). Reads only; quick enough for
## the main thread (statvfs and a directory listing).


## Free bytes on the drive holding `path` (or its nearest existing parent). -1 if unknown.
static func free_bytes(path: String) -> int:
	var p := path.simplify_path()
	while p != "" and not DirAccess.dir_exists_absolute(p):
		var up := p.get_base_dir()
		if up == p:
			break
		p = up
	var d := DirAccess.open(p if p != "" else "/")
	if d == null:
		return -1
	return d.get_space_left()


static func human(bytes: int) -> String:
	if bytes < 0:
		return "?"
	var units := ["B", "KB", "MB", "GB", "TB"]
	var v := float(bytes)
	var i := 0
	while v >= 1024.0 and i < units.size() - 1:
		v /= 1024.0
		i += 1
	return ("%d %s" % [int(v), units[i]]) if i == 0 else ("%.1f %s" % [v, units[i]])


## Mounted removable drives under `media_root` for `user` (and SteamOS-style
## direct mounts): [{"path", "label"}].
static func removable_mounts(media_root: String, user: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var roots: Array[String] = []
	if user != "":
		roots.append(media_root.path_join(user))
	roots.append(media_root)
	for root in roots:
		var d := DirAccess.open(root)
		if d == null:
			continue
		for sub in d.get_directories():
			var p := root.path_join(sub)
			if root == media_root and sub == user:
				continue
			# A user folder under /run/media holds mounts itself; skip folders that only hold folders of mounts.
			if root == media_root and DirAccess.open(p) != null and _looks_like_user_dir(p):
				continue
			out.append({"path": p, "label": sub})
	return out


static func _looks_like_user_dir(p: String) -> bool:
	# udisks2 creates /run/media/<user> as root:root 0750 with an ACL; a mounted
	# filesystem root normally has files or lost+found. Treat a folder that holds
	# only folders, none of them lost+found, and no files, as another user's folder.
	var d := DirAccess.open(p)
	if d == null:
		return true
	return d.get_files().is_empty() and not d.get_directories().is_empty() and not "lost+found" in d.get_directories() \
		and not "steamapps" in d.get_directories() and not "Games" in d.get_directories()


## Where games can go: the default folder first, then each removable drive's
## Games folder. [{"path", "label", "free", "removable"}]
static func locations(install_root: String, media_root: String, user: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = [{"path": install_root, "label": "Internal", "free": free_bytes(install_root), "removable": false}]
	for m in removable_mounts(media_root, user):
		var p := str(m["path"]).path_join("Games")
		out.append({"path": p, "label": m["label"], "free": free_bytes(m["path"]), "removable": true})
	return out


static func is_removable(path: String, media_root := "/run/media") -> bool:
	return path.simplify_path().begins_with(media_root.simplify_path() + "/")


## The mount point holding `path`, from the text of /proc/self/mounts ("" when unknown).
static func mount_of(path: String, mounts_text: String) -> String:
	var p := path.simplify_path()
	var best := ""
	for line in mounts_text.split("\n", false):
		var cols := line.split(" ", false)
		if cols.size() < 2:
			continue
		# the kernel writes a space in a mount point as \040 (tab \011, newline \012, backslash \134)
		var target := cols[1].replace("\\040", " ").replace("\\011", "\t").replace("\\012", "\n").replace("\\134", "\\")
		if (p == target or target == "/" or p.begins_with(target + "/")) and target.length() > best.length():
			best = target
	return best


## True when both paths sit under the same mount point, so a move between them is one
## rename. False when that can't be told (then the move copies, which is always right).
## `mounts_text`: /proc/self/mounts (read here when not given).
static func same_drive(a: String, b: String, mounts_text: Variant = null) -> bool:
	var text: String = mounts_text if mounts_text is String else _read_all("/proc/self/mounts")
	var ma := mount_of(a, text)
	return ma != "" and ma == mount_of(b, text)


## A file read to its real end (/proc files report a size of 0).
static func _read_all(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var buf := PackedByteArray()
	while buf.size() < 4 * 1024 * 1024:
		var chunk := f.get_buffer(65536)
		buf.append_array(chunk)
		if chunk.size() < 65536:
			break
	return buf.get_string_from_utf8()
