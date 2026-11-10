extends RefCounted
## Writes Valve text KeyValues the way Steam does (tabs, quoted keys, two tabs
## before a value) and saves Steam config files safely: a one-time original
## copy, a backup of the previous version, a temp file, then a rename.
##
## Steam keeps localconfig.vdf and config.vdf in memory and writes them back on
## exit, so edits made while it runs are lost. Callers must check that Steam is
## stopped first (SteamConfig does).

const SettingsFile := preload("res://scripts/system/settings_file.gd")

const VDF := preload("res://scripts/launch/vdf.gd")

const BACKUP_SUFFIX := ".gamecove.bak"
const ORIGINAL_SUFFIX := ".gamecove-orig"


## Steam's escaping for a value we write: \\ \" \n \t. Values we didn't change are
## never re-escaped: dump() puts them back exactly as they were written (review 2,
## problem 7: re-escaping turned Steam's "C:\\prog\\x" into "C:\prog\x").
static func escape(s: String) -> String:
	return s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\t", "\\t")


## Nested Dictionaries of Strings back to text. Key order is kept. `raw` (from
## VDF.parse_strict_raw) holds every key and value as the file wrote it; one that
## still reads as the same string is written back verbatim.
static func dump(d: Dictionary, indent := 0, raw := {}) -> String:
	var out := ""
	var tabs := "\t".repeat(indent)
	for k in d:
		var v: Variant = d[k]
		var r: Array = raw.get(k, []) if raw.get(k) is Array else []
		var ks := str(k)
		var key_text: String = r[0] if r.size() == 2 and _as_written(r[0], ks) else escape(ks)
		if v is Dictionary:
			var sub: Dictionary = r[1] if r.size() == 2 and r[1] is Dictionary else {}
			out += "%s\"%s\"\n%s{\n%s%s}\n" % [tabs, key_text, tabs, dump(v, indent + 1, sub), tabs]
		else:
			var vs := str(v)
			var val_text: String = r[1] if r.size() == 2 and r[1] is String and _as_written(r[1], vs) else escape(vs)
			out += "%s\"%s\"\t\t\"%s\"\n" % [tabs, key_text, val_text]
	return out


static func _as_written(raw_text: String, value: String) -> bool:
	return not raw_text.begins_with(char(0)) and VDF.decode(raw_text) == value


## Saves `data` to `path`. Keeps the very first version as <path>.gamecove-orig
## and the one before this write as <path>.gamecove.bak. Returns OK or an error.
##
## Refuses (ERR_PARSE_ERROR) unless the text it would write reads back as the
## same number of keys, so a broken tree never replaces Steam's file.
## Refuses (ERR_FILE_UNRECOGNIZED) an existing file that our writer wouldn't write
## back byte for byte unchanged (dump(parse(original)) != original): its layout or
## escapes are something we don't know, so we don't touch it (review 2, problem 7).
static func save(path: String, data: Dictionary) -> Error:
	var raw := {}
	if FileAccess.file_exists(path):
		var original: Variant = VDF.read_utf8_exact(path)
		if not original is String:
			return ERR_FILE_UNRECOGNIZED
		var p: Variant = VDF.parse_strict_raw(original)
		if not p is Dictionary or dump(p["tree"], 0, p["raw"]) != original:
			return ERR_FILE_UNRECOGNIZED
		raw = p["raw"]
	var text := dump(data, 0, raw)
	var back: Variant = VDF.parse_strict(text)
	if not back is Dictionary or VDF.count_keys(back) != VDF.count_keys(data):
		return ERR_PARSE_ERROR
	if FileAccess.file_exists(path):
		if not FileAccess.file_exists(path + ORIGINAL_SUFFIX):
			var e := DirAccess.copy_absolute(path, path + ORIGINAL_SUFFIX)
			if e != OK:
				return e
		var e2 := DirAccess.copy_absolute(path, path + BACKUP_SUFFIX)
		if e2 != OK:
			return e2
	return SettingsFile.save_text(path, text)


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
