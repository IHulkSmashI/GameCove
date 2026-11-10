extends RefCounted
## Art GameCove uses instead of (or where there is no) store art, per game and
## kind: what the user picked in Change artwork ("user", always wins) and what
## the automatic fill found for games with none ("auto", only where the store
## has nothing). Files live in user://art/picked/, listed in index.json:
##   {"<game key>": {"<kind>": {"path", "source": "user"|"auto", "id", "author",
##                   "author_url", "steam": [grid files we wrote]}}}
## Static and file-based so the Library scan can read it on a worker thread.

const SettingsFile := preload("res://scripts/system/settings_file.gd")

const DIR := "user://art/picked"
const KINDS := ["cover", "hero", "logo", "icon"]


static func index_path(dir: String) -> String:
	return dir.path_join("index.json")


static func read(dir: String) -> Dictionary:
	var p := index_path(dir)
	if not FileAccess.file_exists(p):
		return {}
	var j := JSON.new()
	if j.parse(FileAccess.get_file_as_string(p)) != OK or not j.data is Dictionary:
		return {}
	return j.data


static func write(dir: String, index: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(dir)
	return SettingsFile.save_json(index_path(dir), index) == OK


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
	var index := read(dir)
	var game: Dictionary = index.get(key, {})
	var old = game.get(kind)
	if old is Dictionary and str(old.get("path", "")) != str(rec.get("path", "")) and FileAccess.file_exists(str(old.get("path", ""))):
		DirAccess.remove_absolute(str(old["path"]))
	game[kind] = rec
	index[key] = game
	return write(dir, index)


## Forgets an override and deletes its file; returns the record that was there ({} if none).
static func remove(dir: String, key: String, kind: String) -> Dictionary:
	var index := read(dir)
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
