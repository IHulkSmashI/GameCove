extends RefCounted
## Writes Valve text KeyValues the way Steam does (tabs, quoted keys, two tabs
## before a value) and saves Steam config files safely: a one-time original
## copy, a backup of the previous version, a temp file, then a rename.
##
## Steam keeps localconfig.vdf and config.vdf in memory and writes them back on
## exit, so edits made while it runs are lost. Callers must check that Steam is
## stopped first (SteamConfig does).

const VDF := preload("res://scripts/launch/vdf.gd")

const BACKUP_SUFFIX := ".gamecove.bak"
const ORIGINAL_SUFFIX := ".gamecove-orig"


static func escape(s: String) -> String:
	return s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\t", "\\t")


## Nested Dictionaries of Strings back to text. Key order is kept.
static func dump(d: Dictionary, indent := 0) -> String:
	var out := ""
	var tabs := "\t".repeat(indent)
	for k in d:
		var v: Variant = d[k]
		if v is Dictionary:
			out += "%s\"%s\"\n%s{\n%s%s}\n" % [tabs, escape(str(k)), tabs, dump(v, indent + 1), tabs]
		else:
			out += "%s\"%s\"\t\t\"%s\"\n" % [tabs, escape(str(k)), escape(str(v))]
	return out


## Saves `data` to `path`. Keeps the very first version as <path>.gamecove-orig
## and the one before this write as <path>.gamecove.bak. Returns OK or an error.
static func save(path: String, data: Dictionary) -> Error:
	if FileAccess.file_exists(path):
		if not FileAccess.file_exists(path + ORIGINAL_SUFFIX):
			var e := DirAccess.copy_absolute(path, path + ORIGINAL_SUFFIX)
			if e != OK:
				return e
		var e2 := DirAccess.copy_absolute(path, path + BACKUP_SUFFIX)
		if e2 != OK:
			return e2
	var tmp := path + ".gamecove.tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(dump(data))
	f.close()
	return DirAccess.rename_absolute(tmp, path)


## Puts the .gamecove.bak copy back. Returns OK or an error.
static func restore_backup(path: String) -> Error:
	if not FileAccess.file_exists(path + BACKUP_SUFFIX):
		return ERR_FILE_NOT_FOUND
	return DirAccess.copy_absolute(path + BACKUP_SUFFIX, path)


## The child Dictionary at `keys` (matched ignoring case, created with the given
## spelling when missing). Steam spells keys inconsistently ("Valve"/"valve").
static func ensure_path(root: Dictionary, keys: Array) -> Dictionary:
	var d := root
	for k in keys:
		var found: Variant = null
		for existing in d:
			if str(existing).to_lower() == str(k).to_lower() and d[existing] is Dictionary:
				found = d[existing]
				break
		if found == null:
			found = {}
			d[k] = found
		d = found
	return d


## Removes `key` (ignoring case) from `d`. True if something was removed.
static func erase_ci(d: Dictionary, key: String) -> bool:
	for k in d.keys():
		if str(k).to_lower() == key.to_lower():
			d.erase(k)
			return true
	return false


## Sets `key` to `value`, reusing an existing key's spelling.
static func set_ci(d: Dictionary, key: String, value: Variant) -> void:
	for k in d:
		if str(k).to_lower() == key.to_lower():
			d[k] = value
			return
	d[key] = value
