extends RefCounted
## Local copies of a game's save folders, taken before anything may overwrite them (a cloud
## download, a restore, a forced choice in a conflict). Plain tar.gz files under
## <data>/saves/backups/<game>/ with a small JSON next to them:
##   <stamp>.json            {"time", "reason", "title", "parts": [{"name", "path", "file", "bytes"}],
##                            "fingerprint", "pinned"}
##   <stamp>-<n>.tar.gz      one per save folder, its contents relative to the folder
## Up to KEEP everyday backups per game (the copy before each cloud download) and, apart from
## those, up to KEEP pinned ones (before a conflict choice, a copy of the cloud, before a
## restore): ten launches never rotate out the one copy of a save a choice replaced. The
## oldest of each kind go first. A backup whose folders didn't change since the
## last one isn't taken again (same fingerprint). Commands go through `run`
## (func(program, args) -> {"code", "out"}), so tests use a fake or the real tar.

const SettingsFile := preload("res://scripts/system/settings_file.gd")
const CloudSaves := preload("res://scripts/system/cloud_saves.gd")

const KEEP := 10

var base_dir := ""
var run: Callable


func _init(dir: String, runner: Callable) -> void:
	base_dir = dir
	run = runner


static func game_dir_name(key: String) -> String:
	return key.validate_filename().replace(" ", "_")


func dir_for(key: String) -> String:
	return base_dir.path_join(game_dir_name(key))


## Fingerprint of the folders: files, bytes and newest change of each.
static func fingerprint(parts: Array) -> String:
	var bits := PackedStringArray()
	for p in parts:
		var s := CloudSaves.dir_stats(str(p["path"]))
		bits.append("%s:%d:%d:%d" % [str(p["name"]), s["files"], s["bytes"], s["newest"]])
	return ",".join(bits)


## Backs up `parts` ([{name, path}]). -> {"ok", "id", "skipped": "" | "empty" | "same" , "why"}.
## ok is false only when a copy was needed and couldn't be made (then nothing may overwrite
## the folders). `force` takes a copy even when the last one has the same fingerprint.
## `pinned`: counted apart from the everyday backups when the oldest are dropped.
func backup(key: String, title: String, reason: String, parts: Array, force := false, pinned := false) -> Dictionary:
	var with_files: Array = []
	for p in parts:
		var st := CloudSaves.dir_stats(str(p["path"]))
		if int(st["bytes"]) > CloudSaves.MAX_BACKUP_BYTES:
			return {"ok": false, "id": "", "skipped": "", "why": "too_big"}
		if int(st["files"]) > 0:
			with_files.append(p)
	if with_files.is_empty():
		return {"ok": true, "id": "", "skipped": "empty", "why": ""}
	var fp := fingerprint(with_files)
	var last := list(key)
	if not force and not last.is_empty() and str(last[0].get("fingerprint", "")) == fp:
		return {"ok": true, "id": str(last[0]["id"]), "skipped": "same", "why": ""}
	var dir := dir_for(key)
	DirAccess.make_dir_recursive_absolute(dir)
	var stamp := _stamp(dir)
	var out_parts: Array = []
	for i in with_files.size():
		var p: Dictionary = with_files[i]
		var file := "%s-%d.tar.gz" % [stamp, i]
		var r: Dictionary = run.call("tar", PackedStringArray(["-czf", dir.path_join(file), "-C", str(p["path"]), "."]))
		if int(r.get("code", -1)) != 0:
			for q in out_parts:
				DirAccess.remove_absolute(dir.path_join(str(q["file"])))
			DirAccess.remove_absolute(dir.path_join(file))
			return {"ok": false, "id": "", "skipped": "", "why": "tar: " + str(r.get("out", "")).strip_edges().left(200)}
		var size := 0
		var fa := FileAccess.open(dir.path_join(file), FileAccess.READ)
		if fa != null:
			size = fa.get_length()
			fa.close()
		out_parts.append({"name": str(p["name"]), "path": str(p["path"]), "file": file, "bytes": size})
	var meta := {"time": int(Time.get_unix_time_from_system()), "reason": reason, "title": title,
		"parts": out_parts, "fingerprint": fp, "pinned": pinned}
	if SettingsFile.save_json(dir.path_join(stamp + ".json"), meta, "\t") != OK:
		return {"ok": false, "id": "", "skipped": "", "why": "couldn't write the backup list"}
	prune(key)
	return {"ok": true, "id": stamp, "skipped": "", "why": ""}


## A name that sorts by time and never collides within a second.
func _stamp(dir: String) -> String:
	var t := Time.get_datetime_string_from_system(true).replace("-", "").replace(":", "").replace("T", "-")
	var s := t
	var n := 1
	while FileAccess.file_exists(dir.path_join(s + ".json")):
		n += 1
		s = "%s_%d" % [t, n]
	return s


## Backups of a game, newest first: [{"id", "time", "reason", "title", "parts", "bytes", "fingerprint"}].
func list(key: String) -> Array:
	var dir := dir_for(key)
	var out: Array = []
	if not DirAccess.dir_exists_absolute(dir):
		return out
	for f in DirAccess.get_files_at(dir):
		if not f.ends_with(".json"):
			continue
		var j: Variant = SettingsFile.load_json(dir.path_join(f)).get("data")
		if not j is Dictionary or not j.get("parts") is Array:
			continue
		var total := 0
		for p in j["parts"]:
			total += int(Dictionary(p).get("bytes", 0)) if p is Dictionary else 0
		var e: Dictionary = j.duplicate()
		e["id"] = f.trim_suffix(".json")
		e["bytes"] = total
		out.append(e)
	out.sort_custom(func(x, y): return str(x["id"]) > str(y["id"]))
	return out


func find(key: String, id: String) -> Dictionary:
	for b in list(key):
		if str(b["id"]) == id:
			return b
	return {}


## Puts a backup back: each folder becomes exactly what the backup holds (files made since
## don't stay; callers back the current state up first). The backup is unpacked next to the
## folder and swapped in, so a backup that can't be unpacked changes nothing.
## -> {"ok", "why"}.
func restore(key: String, id: String) -> Dictionary:
	var b := find(key, id)
	if b.is_empty():
		return {"ok": false, "why": "missing"}
	var dir := dir_for(key)
	for p in b["parts"]:
		var path := str(p["path"]).simplify_path()
		var staged := path + ".gamecove-restore"
		var old := path + ".gamecove-old"
		remove_tree(staged)
		if DirAccess.make_dir_recursive_absolute(staged) != OK:
			return {"ok": false, "why": "couldn't make a folder next to the saves"}
		var r: Dictionary = run.call("tar", PackedStringArray(["-xzf", dir.path_join(str(p["file"])), "-C", staged]))
		if int(r.get("code", -1)) != 0:
			remove_tree(staged)
			return {"ok": false, "why": "tar: " + str(r.get("out", "")).strip_edges().left(200)}
		remove_tree(old)
		var had := DirAccess.dir_exists_absolute(path)
		if had and DirAccess.rename_absolute(path, old) != OK:
			# a folder that can't be renamed (a mount point): emptied and filled in place
			empty_dir(path)
			var m: Dictionary = run.call("tar", PackedStringArray(["-xzf", dir.path_join(str(p["file"])), "-C", path]))
			remove_tree(staged)
			if int(m.get("code", -1)) != 0:
				return {"ok": false, "why": "tar: " + str(m.get("out", "")).strip_edges().left(200)}
			continue
		if DirAccess.rename_absolute(staged, path) != OK:
			if had:
				DirAccess.rename_absolute(old, path)
			remove_tree(staged)
			return {"ok": false, "why": "couldn't put the saves in place"}
		remove_tree(old)
	return {"ok": true, "why": ""}


## Deletes a folder tree. A symlink is removed as a link, never followed (a Wine prefix
## links folders out to the home folder).
static func remove_tree(path: String) -> void:
	var parent := DirAccess.open(path.get_base_dir())
	if parent != null and parent.is_link(path.get_file()):
		DirAccess.remove_absolute(path)
		return
	empty_dir(path)
	DirAccess.remove_absolute(path)


## Deletes everything inside a folder and keeps the folder (links removed, not followed).
static func empty_dir(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.include_hidden = true
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	for sub in d.get_directories():
		if d.is_link(sub):
			DirAccess.remove_absolute(path.path_join(sub))
		else:
			remove_tree(path.path_join(sub))


## Keeps the newest `keep` everyday backups of a game and the newest `keep` pinned ones.
func prune(key: String, keep := KEEP) -> void:
	var dir := dir_for(key)
	var seen := {false: 0, true: 0}
	for b in list(key):
		var kind := bool(b.get("pinned", false))
		seen[kind] += 1
		if seen[kind] <= keep:
			continue
		for p in b["parts"]:
			DirAccess.remove_absolute(dir.path_join(str(p["file"])))
		DirAccess.remove_absolute(dir.path_join(str(b["id"]) + ".json"))
