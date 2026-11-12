extends RefCounted
## Favourites, hidden games and the user's own collections, for every store.
##
## Ours live in user://collections.json (written through settings_file.gd):
##   {"version": 1, "favourites": [key], "hidden": [key],
##    "unfavourite": [key], "unhide": [key],      # an imported favourite / hidden game turned off here
##    "collections": [{"id": "c1", "name": "Couch co-op", "games": [key]}],
##    "steam": true}                               # show Steam's own collections (read-only)
## Keys are Library game keys ("steam:620", "epic:Fortnite", "emu:3000000001").
##
## Steam's collections, favourites and hidden games are read (never written)
## from userdata/<user>/config/cloudstorage/cloud-storage-namespace-1.json of
## the account that signed in last: a JSON list of [key, entry] pairs; entries
## whose key starts with "user-collections." and that carry a "value" (a JSON
## string {"id", "name", "added": [app ids], "removed": [...]}) are collections.
## "favorite" and "hidden" are Steam's two built-in ones; "is_deleted" entries
## are gone; dynamic collections ("filterSpec") are Steam's own rules, which
## we can't evaluate, so they stay in Steam (counted in `dynamic`).
## Library.collect() reads the file off the main thread and calls set_imported().

signal changed

const SettingsFile := preload("res://scripts/system/settings_file.gd")
const SteamConfig := preload("res://scripts/steam/steam_config.gd")
const PATH := "user://collections.json"
const CLOUD_FILE := "config/cloudstorage/cloud-storage-namespace-1.json"
const VERSION := 1
## A collection name at most this long (it's a chip and a row title).
const NAME_MAX := 40

var path := PATH
var _data := {}
var _loaded := false
## From Steam (and from ES-DE's own favourites): {"favourites": {key: true},
## "hidden": {key: true}, "collections": [{"id", "name", "games": [key], "source"}], "dynamic": int}
var _imported := {"favourites": {}, "hidden": {}, "collections": [], "dynamic": 0}


func _init(file := PATH) -> void:
	path = file


static func empty_data() -> Dictionary:
	return {"version": VERSION, "favourites": [], "hidden": [], "unfavourite": [], "unhide": [], "collections": [], "steam": true}


func _load() -> void:
	if _loaded:
		return
	_loaded = true
	_data = empty_data()
	var res := SettingsFile.load_json(path)
	var d: Variant = res.get("data")
	if not d is Dictionary:
		return
	if int(d.get("version", VERSION)) > VERSION:
		SettingsFile.reject(path, "collections from a newer GameCove")
		return
	for k in ["favourites", "hidden", "unfavourite", "unhide"]:
		_data[k] = _keys(d.get(k))
	_data["steam"] = d.get("steam", true) != false
	var cols: Array = []
	for c in (d.get("collections") if d.get("collections") is Array else []):
		if c is Dictionary and str(c.get("id", "")) != "" and str(c.get("name", "")).strip_edges() != "":
			cols.append({"id": str(c["id"]), "name": str(c["name"]).strip_edges().left(NAME_MAX), "games": _keys(c.get("games"))})
	_data["collections"] = cols


static func _keys(v: Variant) -> Array:
	var out: Array = []
	if v is Array:
		for k in v:
			if (k is String or k is StringName) and str(k) != "" and not str(k) in out:
				out.append(str(k))
	return out


func _save() -> bool:
	var ok := SettingsFile.save_json(path, _data, "\t") == OK
	changed.emit()
	return ok


## Forget what's in memory (tests; the file changed under us).
func reload() -> void:
	_loaded = false
	_load()


# ------------------------------------------------------------ favourites / hidden

func is_favourite(key: String) -> bool:
	_load()
	if key in _data["unfavourite"]:
		return false
	return key in _data["favourites"] or _imported["favourites"].has(key)


func set_favourite(key: String, on: bool) -> bool:
	return _set_flag(key, on, "favourites", "unfavourite", _imported["favourites"].has(key))


func is_hidden(key: String) -> bool:
	_load()
	if key in _data["unhide"]:
		return false
	return key in _data["hidden"] or _imported["hidden"].has(key)


func set_hidden(key: String, on: bool) -> bool:
	return _set_flag(key, on, "hidden", "unhide", _imported["hidden"].has(key))


## Turning a flag off that came from Steam / ES-DE records an override here;
## their files stay as they are.
func _set_flag(key: String, on: bool, list: String, off_list: String, imported: bool) -> bool:
	_load()
	if key == "":
		return false
	_data[list].erase(key)
	_data[off_list].erase(key)
	if on and not imported:
		_data[list].append(key)
	elif not on and imported:
		_data[off_list].append(key)
	return _save()


func favourite_count(keys: Array) -> int:
	return keys.filter(func(k): return is_favourite(k)).size()


# ------------------------------------------------------------ collections

## Ours first (A to Z), then Steam's when "Show Steam collections" is on:
## [{"id", "name", "games": [key], "source": "" | "steam", "read_only": bool}].
func collections() -> Array:
	_load()
	var out: Array = []
	for c in _data["collections"]:
		out.append({"id": c["id"], "name": c["name"], "games": c["games"].duplicate(), "source": "", "read_only": false})
	out.sort_custom(func(a, b): return a["name"].naturalnocasecmp_to(b["name"]) < 0)
	if steam_enabled():
		var st: Array = []
		for c in _imported["collections"]:
			st.append({"id": c["id"], "name": c["name"], "games": c["games"].duplicate(), "source": c.get("source", "steam"), "read_only": true})
		st.sort_custom(func(a, b): return a["name"].naturalnocasecmp_to(b["name"]) < 0)
		out.append_array(st)
	return out


func find(id: String) -> Dictionary:
	for c in collections():
		if c["id"] == id:
			return c
	return {}


## The new collection's id ("" when the name is empty or the file can't be written).
func create(name: String) -> String:
	_load()
	var n := name.strip_edges().left(NAME_MAX)
	if n == "":
		return ""
	var i := 1
	var ids := {}
	for c in _data["collections"]:
		ids[c["id"]] = true
	while ids.has("c%d" % i):
		i += 1
	var id := "c%d" % i
	_data["collections"].append({"id": id, "name": n, "games": []})
	return id if _save() else ""


func rename(id: String, name: String) -> bool:
	var c := _own(id)
	var n := name.strip_edges().left(NAME_MAX)
	if c.is_empty() or n == "":
		return false
	c["name"] = n
	return _save()


func delete(id: String) -> bool:
	var c := _own(id)
	if c.is_empty():
		return false
	_data["collections"].erase(c)
	return _save()


func add(id: String, key: String) -> bool:
	var c := _own(id)
	if c.is_empty() or key == "":
		return false
	if not key in c["games"]:
		c["games"].append(key)
	return _save()


func remove(id: String, key: String) -> bool:
	var c := _own(id)
	if c.is_empty():
		return false
	c["games"].erase(key)
	return _save()


## One of ours (Steam's are read-only), the stored dictionary itself.
func _own(id: String) -> Dictionary:
	_load()
	for c in _data["collections"]:
		if c["id"] == id:
			return c
	return {}


## Ids of every collection `key` is in.
func collections_of(key: String) -> Array:
	return collections().filter(func(c): return key in c["games"]).map(func(c): return c["id"])


# ------------------------------------------------------------ Steam

func steam_enabled() -> bool:
	_load()
	return _data["steam"]


func set_steam_enabled(on: bool) -> bool:
	_load()
	_data["steam"] = on
	return _save()


## Steam's (and ES-DE's) favourites, hidden games and collections, as Library keys.
func set_imported(imp: Dictionary) -> void:
	var fav := {}
	var hid := {}
	for k in imp.get("favourites", []):
		fav[str(k)] = true
	for k in imp.get("hidden", []):
		hid[str(k)] = true
	var fresh := {"favourites": fav, "hidden": hid, "collections": imp.get("collections", []), "dynamic": int(imp.get("dynamic", 0))}
	if fresh == _imported:
		return   # a rescan found the same: no second rebuild of every screen
	_imported = fresh
	changed.emit()


## Keys that now name another game ({old: new}: a Steam ROM Manager shortcut
## folded into its ROM's own entry): our favourites, hidden games, overrides and
## collections move to the new key. Saved only when something moved.
func adopt_keys(map: Dictionary) -> bool:
	_load()
	var moved := false
	var lists: Array = [_data["favourites"], _data["hidden"], _data["unfavourite"], _data["unhide"]]
	for c in _data["collections"]:
		lists.append(c["games"])
	for l in lists:
		for i in range(l.size() - 1, -1, -1):
			var k := str(l[i])
			if map.has(k):
				moved = true
				if str(map[k]) in l:
					l.remove_at(i)
				else:
					l[i] = str(map[k])
	return _save() if moved else false


## How many Steam collections stay in Steam (dynamic ones).
func dynamic_count() -> int:
	return int(_imported.get("dynamic", 0))


func imported_count() -> int:
	return _imported["collections"].size()


## Every game a decorated copy: g.favourite, g.hidden, g.collections (ids).
func decorate(games: Array) -> Array:
	_load()
	var member := {}
	for c in collections():
		for k in c["games"]:
			if not member.has(k):
				member[k] = []
			member[k].append(c["id"])
	var out: Array = []
	var none := []   # one empty list for every game in no collection (thousands of ROMs)
	# the flag lists as sets once, not a scan of each per game (is_favourite / is_hidden say the same per key)
	var favs := {}
	var hids := {}
	for k in _data["favourites"]:
		favs[k] = true
	for k in _data["hidden"]:
		hids[k] = true
	for k in _data["unfavourite"]:
		favs.erase(k)
	for k in _data["unhide"]:
		hids.erase(k)
	var unfav := {}
	var unhid := {}
	for k in _data["unfavourite"]:
		unfav[k] = true
	for k in _data["unhide"]:
		unhid[k] = true
	for g in games:
		var k := str(g.get("key", ""))
		var fav: bool = favs.has(k) or (_imported["favourites"].has(k) and not unfav.has(k))
		var hid: bool = hids.has(k) or (_imported["hidden"].has(k) and not unhid.has(k))
		if not fav and not hid and not member.has(k) and not g.has("favourite") and not g.has("hidden") and not g.has("collections"):
			# in nothing and not marked: every reader says .get("favourite", false), so the game itself will do
			# (20,000 ROMs were 20,000 copies on every library change)
			out.append(g)
			continue
		var d: Dictionary = g.duplicate()
		d["favourite"] = fav
		d["hidden"] = hid
		d["collections"] = member.get(k, none)
		out.append(d)
	return out


## The cloud-storage file of the Steam account that signed in last, under any
## Steam install in `home` ("" when there's none).
static func steam_cloud_file(home: String, roots: Array) -> String:
	for r in roots:
		var root := str(r)
		root = home + root.substr(1) if root.begins_with("~") else root
		if not DirAccess.dir_exists_absolute(root):
			continue
		var user := SteamConfig.current_user_dir(root)
		if user != "" and FileAccess.file_exists(user.path_join(CLOUD_FILE)):
			return user.path_join(CLOUD_FILE)
	return ""


## Steam's collections from the file's text: {"favourites": [app id], "hidden":
## [app id], "collections": [{"id", "name", "apps": [app id]}], "dynamic": n}.
## Anything it can't read is left out; a broken file gives empty lists.
static func parse_steam_cloud(text: String) -> Dictionary:
	var out := {"favourites": [], "hidden": [], "collections": [], "dynamic": 0}
	var j := JSON.new()
	if j.parse(text) != OK or not j.data is Array:
		return out
	for pair in j.data:
		if not (pair is Array and pair.size() >= 2 and pair[1] is Dictionary):
			continue
		var key := str(pair[0])
		var e: Dictionary = pair[1]
		if not key.begins_with("user-collections.") or e.get("is_deleted", false) == true or not e.get("value") is String:
			continue
		var v := JSON.new()
		if v.parse(str(e["value"])) != OK or not v.data is Dictionary:
			continue
		var c: Dictionary = v.data
		if c.has("filterSpec") and c.get("filterSpec") != null:
			out["dynamic"] += 1
			continue
		var removed := {}
		for a in (c.get("removed") if c.get("removed") is Array else []):
			removed[_app(a)] = true
		var apps: Array = []
		for a in (c.get("added") if c.get("added") is Array else []):
			var s := _app(a)
			if s != "" and not removed.has(s) and not s in apps:
				apps.append(s)
		var id := str(c.get("id", key.trim_prefix("user-collections.")))
		match id:
			"favorite":
				out["favourites"] = apps
			"hidden":
				out["hidden"] = apps
			_:
				var name := str(c.get("name", "")).strip_edges()
				if name != "":
					out["collections"].append({"id": id, "name": name, "apps": apps})
	return out


static func _app(a: Variant) -> String:
	if a is float:
		a = int(a)
	var s := str(a)
	return s if s.is_valid_int() and s.to_int() > 0 else ""


## Steam's parsed collections as Library keys. A Steam id can be a Steam game
## ("steam:<id>") or an emulated game Steam ROM Manager added as a shortcut
## ("emu:<id>"); keys no game has simply match nothing.
static func steam_to_keys(parsed: Dictionary) -> Dictionary:
	var keys := func(apps: Array) -> Array:
		var out: Array = []
		for a in apps:
			out.append("steam:" + str(a))
			out.append("emu:" + str(a))
		return out
	var cols: Array = []
	for c in parsed.get("collections", []):
		cols.append({"id": "steam-" + str(c["id"]), "name": str(c["name"]), "games": keys.call(c["apps"]), "source": "steam"})
	return {"favourites": keys.call(parsed.get("favourites", [])), "hidden": keys.call(parsed.get("hidden", [])),
		"collections": cols, "dynamic": int(parsed.get("dynamic", 0))}
