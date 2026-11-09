extends RefCounted
## Steam settings kept in local files: per-game launch options
## (userdata/<user>/config/localconfig.vdf, apps/<appid>/LaunchOptions) and the
## per-game compatibility tool (config/config.vdf, CompatToolMapping/<appid>).
## Reading is always fine. Writing only while Steam is stopped, because Steam
## writes both files back from memory when it exits (VdfWriter keeps backups).

const VDF := preload("res://scripts/launch/vdf.gd")
const VdfWriter := preload("res://scripts/steam/vdf_writer.gd")
const Proton := preload("res://scripts/launch/proton.gd")

## Where Steam writes its pid (native, then Flatpak).
const PID_FILES := ["/.steam/steam.pid", "/.var/app/com.valvesoftware.Steam/.steam/steam.pid"]
## SteamID64 of account 0; userdata/<id> folders are SteamID64 minus this.
const STEAMID64_BASE := 76561197960265728
const LOCALCONFIG_PATH := ["UserLocalConfigStore", "Software", "Valve", "Steam", "apps"]
const COMPAT_PATH := ["InstallConfigStore", "Software", "Valve", "Steam", "CompatToolMapping"]
## Priority Steam's own UI writes for a per-game choice (the global default uses 75).
const USER_PRIORITY := "250"


## True when the Steam client is running: a pid file whose process still exists
## and is called steam. `proc_root` is "/proc" except in tests.
static func is_running(home: String, proc_root := "/proc") -> bool:
	for rel in PID_FILES:
		var p: String = home + rel
		if not FileAccess.file_exists(p):
			continue
		var pid := FileAccess.get_file_as_string(p).strip_edges()
		if not pid.is_valid_int() or pid.to_int() <= 0:
			continue
		var comm_path := proc_root.path_join(pid).path_join("comm")
		if FileAccess.file_exists(comm_path) and "steam" in FileAccess.get_file_as_string(comm_path).to_lower():
			return true
	return false


## The userdata folder of the account that signed in last (loginusers.vdf
## MostRecent), else the only one, else "".
static func current_user_dir(steam_root: String) -> String:
	var users := VDF.find_ci(VDF.parse_file(steam_root.path_join("config/loginusers.vdf")), "users")
	for id64 in users:
		var u: Variant = users[id64]
		if u is Dictionary and str(VDF.get_ci(u, "MostRecent", "0")) == "1" and str(id64).is_valid_int():
			var dir := steam_root.path_join("userdata/%d" % (str(id64).to_int() - STEAMID64_BASE))
			if DirAccess.dir_exists_absolute(dir):
				return dir
	var found: Array[String] = []
	var d := DirAccess.open(steam_root.path_join("userdata"))
	if d != null:
		for sub in d.get_directories():
			if sub.is_valid_int() and sub != "0":
				found.append(steam_root.path_join("userdata").path_join(sub))
	return found[0] if found.size() == 1 else ""


static func localconfig_path(user_dir: String) -> String:
	return user_dir.path_join("config/localconfig.vdf")


static func config_path(steam_root: String) -> String:
	return steam_root.path_join("config/config.vdf")


static func _walk(root: Dictionary, keys: Array) -> Dictionary:
	var d := root
	for k in keys:
		var next: Variant = VDF.get_ci(d, k)
		if not (next is Dictionary):
			return {}
		d = next
	return d


static func launch_options(user_dir: String, appid: String) -> String:
	var apps := _walk(VDF.parse_file(localconfig_path(user_dir)), LOCALCONFIG_PATH)
	var app: Variant = VDF.get_ci(apps, appid)
	return str(VDF.get_ci(app, "LaunchOptions", "")) if app is Dictionary else ""


## Writes LaunchOptions for one game ("" removes them). Refuses while Steam runs.
static func set_launch_options(home: String, user_dir: String, appid: String, options: String, proc_root := "/proc") -> Error:
	if is_running(home, proc_root):
		return ERR_BUSY
	var path := localconfig_path(user_dir)
	if not FileAccess.file_exists(path):
		return ERR_FILE_NOT_FOUND
	# only a file that parsed cleanly, all of it, is ever written back
	var parsed: Variant = VDF.parse_file_strict(path)
	if not parsed is Dictionary or parsed.is_empty():
		return ERR_PARSE_ERROR
	var root: Dictionary = parsed
	var before := VDF.count_keys(root)
	var app := VdfWriter.ensure_path(root, LOCALCONFIG_PATH + [appid])
	if options == "":
		VdfWriter.erase_ci(app, "LaunchOptions")
	else:
		VdfWriter.set_ci(app, "LaunchOptions", options)
	if not _sane_change(before, VDF.count_keys(root)):
		return ERR_PARSE_ERROR
	return VdfWriter.save(path, root)


## Every account's launch options through fn(appid: String, options: String) -> String; only the
## ones that change are written ("" removes them). Refuses while Steam runs (it writes the file
## back from memory). Used to take GameCove's wrapper out of every game (uninstall, Repair) and to
## move old bare-path entries to the fall-through form. {"error": Error, "changed": [appid, ...]}
static func rewrite_launch_options(home: String, steam_root: String, fn: Callable, proc_root := "/proc") -> Dictionary:
	if is_running(home, proc_root):
		return {"error": ERR_BUSY, "changed": []}
	var changed: Array = []
	var err := OK
	var d := DirAccess.open(steam_root.path_join("userdata"))
	if d == null:
		return {"error": OK, "changed": []}
	for sub in d.get_directories():
		if not sub.is_valid_int() or sub == "0":
			continue
		var path := localconfig_path(steam_root.path_join("userdata").path_join(sub))
		if not FileAccess.file_exists(path):
			continue
		var parsed: Variant = VDF.parse_file_strict(path)
		if not parsed is Dictionary or parsed.is_empty():
			err = ERR_PARSE_ERROR
			continue
		var root: Dictionary = parsed
		var before := VDF.count_keys(root)
		var apps := _walk(root, LOCALCONFIG_PATH)
		var mine: Array = []
		var erased := 0
		for appid in apps:
			var app: Variant = apps[appid]
			if not app is Dictionary:
				continue
			var cur := str(VDF.get_ci(app, "LaunchOptions", ""))
			if cur == "":
				continue
			var next := str(fn.call(str(appid), cur)).strip_edges()
			if next == cur.strip_edges():
				continue
			if next == "":
				VdfWriter.erase_ci(app, "LaunchOptions")
				erased += 1
			else:
				VdfWriter.set_ci(app, "LaunchOptions", next)
			mine.append(str(appid))
		if mine.is_empty():
			continue
		# only LaunchOptions values changed or went away: anything else means a misparse
		if before - VDF.count_keys(root) != erased:
			err = ERR_PARSE_ERROR
			continue
		var e := VdfWriter.save(path, root)
		if e != OK:
			err = e
		else:
			changed.append_array(mine)
	return {"error": err, "changed": changed}


## The tool chosen for this one game ("" = Steam's default).
static func compat_tool(steam_root: String, appid: String) -> String:
	var mapping := _walk(VDF.parse_file(config_path(steam_root)), COMPAT_PATH)
	var entry: Variant = VDF.get_ci(mapping, appid)
	return str(VDF.get_ci(entry, "name", "")) if entry is Dictionary else ""


## Sets the per-game tool by internal name ("" goes back to Steam's default).
static func set_compat_tool(home: String, steam_root: String, appid: String, tool: String, proc_root := "/proc") -> Error:
	if is_running(home, proc_root):
		return ERR_BUSY
	var path := config_path(steam_root)
	if not FileAccess.file_exists(path):
		return ERR_FILE_NOT_FOUND
	var parsed: Variant = VDF.parse_file_strict(path)
	if not parsed is Dictionary or parsed.is_empty():
		return ERR_PARSE_ERROR
	var root: Dictionary = parsed
	var before := VDF.count_keys(root)
	var mapping := VdfWriter.ensure_path(root, COMPAT_PATH)
	if tool == "":
		VdfWriter.erase_ci(mapping, appid)
	else:
		var entry := VdfWriter.ensure_path(mapping, [appid])
		VdfWriter.set_ci(entry, "name", tool)
		VdfWriter.set_ci(entry, "config", "")
		VdfWriter.set_ci(entry, "priority", USER_PRIORITY)
	if not _sane_change(before, VDF.count_keys(root)):
		return ERR_PARSE_ERROR
	return VdfWriter.save(path, root)


## One setting changes a handful of keys (a path of up to 6 new folders plus up
## to 3 values, or one entry with its 3 values removed); anything more means the
## tree isn't what we think it is.
static func _sane_change(before: int, after: int) -> bool:
	return after - before <= 9 and before - after <= 4


## Internal name Steam uses for a Valve Proton it installed as an app, from the
## app's name ("Proton 9.0" -> proton_9, "Proton Experimental" ->
## proton_experimental, "Proton Hotfix" -> proton_hotfix). These names come from
## Steam's appinfo, which we don't parse; this mapping matches every Valve
## Proton so far, so treat it as a best guess. "" for anything else.
static func valve_tool_name(app_name: String) -> String:
	var low := app_name.to_lower().strip_edges()
	if low == "proton experimental":
		return "proton_experimental"
	if low == "proton hotfix":
		return "proton_hotfix"
	var m := RegEx.create_from_string("^proton (\\d+)\\.\\d+$").search(low)
	return "proton_%s" % m.get_string(1) if m else ""


## Compatibility tools Steam can use, from local files only:
## [{"id": internal name, "name": display name, "path": folder, "source": "valve|custom"}].
## `valve_apps` is [{"name", "path"}] for installed Valve Proton apps.
static func local_tools(tool_dirs: Array, valve_apps: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for app in valve_apps:
		var id := valve_tool_name(str(app.get("name", "")))
		if id != "":
			out.append({"id": id, "name": str(app["name"]), "path": str(app.get("path", "")), "source": "valve"})
	var custom := Proton.tools(tool_dirs)
	var ids := custom.keys()
	ids.sort()
	for id in ids:
		out.append({"id": str(id), "name": str(custom[id]["display_name"]), "path": str(custom[id]["dir"]), "source": "custom"})
	return out
