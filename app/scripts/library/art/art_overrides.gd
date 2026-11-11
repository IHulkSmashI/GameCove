extends RefCounted
## Art GameCove uses instead of (or where there is no) store art, per game and
## kind: what the user picked in Change artwork ("user", always wins) and what
## the automatic fill found for games with none ("auto", only where the store
## has nothing). Files live in user://art/picked/, listed in index.json (with a second
## copy, index.json.bak, so one damaged file never costs every game's pick):
##   {"<game key>": {"<kind>": {"path", "source": "user"|"auto", "id", "author",
##                   "author_url", "steam": [grid files we wrote]}}}
## Static and file-based so the Library scan can read it on a worker thread.

const SettingsFile := preload("res://scripts/system/settings_file.gd")

const DIR := "user://art/picked"
const KINDS := ["cover", "hero", "logo", "icon"]


static func index_path(dir: String) -> String:
	return dir.path_join("index.json")


## The index, {} when there is none. A damaged index.json isn't "no picks": the copy
## written next to it at every save (index.json.bak) is read instead, and the damaged file
## is kept as index.json.bad.
static func read(dir: String) -> Dictionary:
	return load_index(dir)["index"]


## {"ok", "index"}: ok is false only when an index exists and neither it nor its copy can
## be read. Then nothing may be written (a new index would drop every other game's pick).
static func load_index(dir: String) -> Dictionary:
	var p := index_path(dir)
	var main: Variant = _parse(p)
	if main != null:
		return {"ok": true, "index": main}
	if not FileAccess.file_exists(p + ".bad"):
		DirAccess.copy_absolute(p, p + ".bad")
	var copy: Variant = _parse(p + ".bak") if FileAccess.file_exists(p + ".bak") else null
	if copy != null:
		return {"ok": true, "index": copy}
	return {"ok": false, "index": {}}


## A JSON object file: {} when missing or empty, null when it's there and doesn't read.
static func _parse(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	if text.strip_edges() == "":
		return {}
	var j := JSON.new()
	if j.parse(text) != OK or not j.data is Dictionary:
		return null
	return j.data


## Saves the index, then the same again as index.json.bak (both atomic).
static func write(dir: String, index: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(dir)
	if SettingsFile.save_json(index_path(dir), index) != OK:
		return false
	SettingsFile.save_json(index_path(dir) + ".bak", index)
	return true


## The art to show: `store_art` with this game's overrides applied.
static func apply(store_art: Dictionary, overrides: Dictionary) -> Dictionary:
	var art := store_art.duplicate()
	for kind in KINDS:
		var o = overrides.get(kind)
		if not o is Dictionary or not FileAccess.file_exists(str(o.get("path", ""))):
			continue
		var have := str(art.get(kind, ""))
		if o.get("source", "") == "user" or have == "" or not FileAccess.file_exists(have):
			art[kind] = str(o["path"])
	return art


static func file_base(key: String, kind: String) -> String:
	return "%s_%s" % [key.sha1_text().substr(0, 20), kind]


## Records an override (replacing the old file for that game and kind).
static func set_override(dir: String, key: String, kind: String, rec: Dictionary) -> bool:
	var loaded := load_index(dir)
	if not loaded["ok"]:
		return false
	var index: Dictionary = loaded["index"]
	var game: Dictionary = index.get(key, {})
	var old = game.get(kind)
	if old is Dictionary and str(old.get("path", "")) != str(rec.get("path", "")) and FileAccess.file_exists(str(old.get("path", ""))):
		DirAccess.remove_absolute(str(old["path"]))
	game[kind] = rec
	index[key] = game
	return write(dir, index)


## Forgets an override and deletes its file; returns the record that was there ({} if none).
static func remove(dir: String, key: String, kind: String) -> Dictionary:
	var loaded := load_index(dir)
	if not loaded["ok"]:
		return {}
	var index: Dictionary = loaded["index"]
	var game: Dictionary = index.get(key, {})
	var old = game.get(kind, {})
	if not old is Dictionary or old.is_empty():
		return {}
	if FileAccess.file_exists(str(old.get("path", ""))):
		DirAccess.remove_absolute(str(old["path"]))
	game.erase(kind)
	if game.is_empty():
		index.erase(key)
	else:
		index[key] = game
	write(dir, index)
	return old
