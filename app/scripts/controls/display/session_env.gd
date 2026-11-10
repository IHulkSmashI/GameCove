extends RefCounted
## Session settings gamescope only reads at start: gamescope-session-plus
## sources ~/.config/environment.d/*.conf (set -a) before it builds gamescope's
## command line, so ORIENTATION, CUSTOM_REFRESH_RATES and ENABLE_GAMESCOPE_HDR /
## ENABLE_GAMESCOPE_WSI there take effect the next time the session starts
## (OpenGamingCollective/gamescope-session usr/share/gamescope-session-plus/
## gamescope-session-plus). We keep ours in one file of our own; a user's own
## higher-numbered file still wins. The file goes away when it's empty.

const SettingsFile := preload("res://scripts/system/settings_file.gd")

const REL_PATH := ".config/environment.d/80-gamecove-display.conf"
const HEADER := "# Written by GameCove (Display settings). Read by gamescope-session-plus at session start.\n"
const SESSION_SCRIPT := "/usr/share/gamescope-session-plus/gamescope-session-plus"


static func path(ctx: Dictionary) -> String:
	return str(ctx.get("home", "")).path_join(REL_PATH)


## True when the session that reads this file is installed.
static func supported(ctx: Dictionary) -> bool:
	return FileAccess.file_exists(str(ctx.get("sys_root", "")) + SESSION_SCRIPT)


static func read(ctx: Dictionary) -> Dictionary:
	var out := {}
	var f := FileAccess.open(path(ctx), FileAccess.READ)
	if f == null:
		return out
	for line in f.get_as_text().split("\n"):
		var l := line.strip_edges()
		if l == "" or l.begins_with("#") or not "=" in l:
			continue
		var k := l.get_slice("=", 0).strip_edges()
		var v := l.substr(l.find("=") + 1).strip_edges()
		if v.length() >= 2 and v.begins_with("\"") and v.ends_with("\""):
			v = v.substr(1, v.length() - 2)
		out[k] = v
	return out


static func get_value(ctx: Dictionary, key: String) -> String:
	return str(read(ctx).get(key, ""))


## Sets (or with "" removes) keys. Values are checked: only [A-Za-z0-9,._-].
static func set_values(ctx: Dictionary, values: Dictionary) -> bool:
	var cur := read(ctx)
	for k in values:
		var v := str(values[k])
		if not _safe(k) or (v != "" and not _safe(v)):
			return false
		if v == "":
			cur.erase(k)
		else:
			cur[k] = v
	var p := path(ctx)
	if cur.is_empty():
		if FileAccess.file_exists(p):
			return DirAccess.remove_absolute(p) == OK
		return true
	DirAccess.make_dir_recursive_absolute(p.get_base_dir())
	var keys := cur.keys()
	keys.sort()
	var text := HEADER
	for k in keys:
		text += "%s=%s\n" % [k, cur[k]]
	return SettingsFile.save_text(p, text) == OK


static func _safe(s: String) -> bool:
	if s == "":
		return false
	for ch in s:
		if not (ch.is_valid_int() or (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or ch in [",", ".", "_", "-"]):
			return false
	return true
