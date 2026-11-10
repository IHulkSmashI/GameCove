extends RefCounted
## Play time for what GameCove starts and no store counts for us: ES-DE or
## RetroDECK opened from the Emulation page, and emulated games Steam ROM
## Manager added (Steam keeps no local play time for non-Steam shortcuts).
## user://playtime.json: {"version": 1, "games": {key: {"last_played": unix, "seconds": n}}}.
## Written once when a game ends (main.gd), never while it runs.

const SettingsFile := preload("res://scripts/system/settings_file.gd")
const PATH := "user://playtime.json"


## {key: {"last_played": unix, "playtime_min": minutes}}.
static func read(path := PATH) -> Dictionary:
	var d: Variant = SettingsFile.load_json(path).get("data")
	var out := {}
	if not (d is Dictionary and d.get("games") is Dictionary):
		return out
	for k in d["games"]:
		var e: Variant = d["games"][k]
		if e is Dictionary:
			out[str(k)] = {"last_played": int(e.get("last_played", 0)), "playtime_min": int(e.get("seconds", 0)) / 60}
	return out


## Adds one session (start..end, unix seconds). Sessions under 10 s (a launch
## that failed or was cancelled) don't count.
static func record(key: String, started: int, ended: int, path := PATH) -> bool:
	if key == "" or ended - started < 10:
		return false
	var d: Variant = SettingsFile.load_json(path).get("data")
	if not (d is Dictionary and d.get("games") is Dictionary):
		d = {"version": 1, "games": {}}
	var e: Dictionary = d["games"].get(key, {}) if d["games"].get(key) is Dictionary else {}
	e["seconds"] = int(e.get("seconds", 0)) + (ended - started)
	e["last_played"] = ended
	d["games"][key] = e
	return SettingsFile.save_json(path, d, "\t") == OK


## `entry` with GameCove's own play time: last played is the newest of the
## store's and ours, minutes add up (the store's are 0 for these games).
static func apply(entry: Dictionary, ours: Dictionary) -> void:
	var t: Variant = ours.get("%s:%s" % [entry.get("store", ""), entry.get("id", "")])
	if not t is Dictionary:
		return
	entry["last_played"] = maxi(int(entry.get("last_played", 0)), int(t["last_played"]))
	entry["playtime_min"] = int(entry.get("playtime_min", 0)) + int(t["playtime_min"])
