extends RefCounted
## Reads installed Steam games from Steam's own local files and launches them
## through Steam (`steam steam://rungameid/<id>`), so Steam Input and shader caching apply.
## Playtime and last played come from userdata/<user>/config/localconfig.vdf;
## art from appcache/librarycache (old flat <appid>_*.jpg files and the newer
## per-app folders) with the user's own grid art (userdata/<user>/config/grid) first.

const AppId := preload("res://scripts/steam/app_id.gd")
const Acf := preload("res://scripts/steam/acf.gd")
const LibraryMemory := preload("res://scripts/system/steam_library_memory.gd")

const STEAM_ROOTS := [
	"~/.local/share/Steam",
	"~/.steam/steam",
	"~/.var/app/com.valvesoftware.Steam/.local/share/Steam",
]
## Tools and runtimes Steam lists as apps; not games.
const NOT_GAMES := ["Proton", "Steam Linux Runtime", "Steamworks Common Redistributables"]

static func _home() -> String:
	return OS.get_environment("HOME")


static func expand(path: String, home: String) -> String:
	return home + path.substr(1) if path.begins_with("~") else path


## Every library folder listed in libraryfolders.vdf, plus the root itself.
static func library_folders(steam_root: String) -> Array[String]:
	var folders: Array[String] = [steam_root]
	var vdf := steam_root + "/steamapps/libraryfolders.vdf"
	if not FileAccess.file_exists(vdf):
		return folders
	var text := FileAccess.get_file_as_string(vdf)
	var re := RegEx.new()
	re.compile("\"path\"\\s+\"([^\"]+)\"")
	for m in re.search_all(text):
		var p: String = m.get_string(1).replace("\\\\", "\\")
		if p not in folders:
			folders.append(p)
	return folders


## Pulls one quoted value out of an appmanifest, e.g. "name" or "appid".
static func acf_value(text: String, key: String) -> String:
	var re := RegEx.new()
	re.compile("\"" + key + "\"\\s+\"([^\"]*)\"")
	var m := re.search(text)
	return m.get_string(1) if m else ""


static func is_game(name: String) -> bool:
	for prefix in NOT_GAMES:
		if name.begins_with(prefix):
			return false
	return name != ""


## Parses Valve's text KeyValues (.vdf/.acf) into nested Dictionaries.
## Keys are lowercased because Steam isn't consistent ("Valve" vs "valve").
static func parse_vdf(text: String) -> Dictionary:
	var re := RegEx.create_from_string("\"((?:[^\"\\\\]|\\\\.)*)\"|([{}])")
	var root := {}
	var stack: Array[Dictionary] = [root]
	var key = null
	for m in re.search_all(text):
		var brace := m.get_string(2)
		if brace == "{":
			var child := {}
			if key != null:
				stack.back()[key] = child
			stack.append(child)
			key = null
		elif brace == "}":
			if stack.size() > 1:
				stack.pop_back()
			key = null
		elif key == null:
			key = m.get_string(1).to_lower()
		else:
			stack.back()[key] = m.get_string(1).replace("\\\\", "\\").replace("\\\"", "\"")
			key = null
	return root


## appid -> {"last_played": unix, "playtime_min": minutes} from one localconfig.vdf.
static func playtime_from_localconfig(path: String) -> Dictionary:
	var out := {}
	if not FileAccess.file_exists(path):
		return out
	var d := parse_vdf(FileAccess.get_file_as_string(path))
	for k in ["userlocalconfigstore", "software", "valve", "steam", "apps"]:
		var next = d.get(k, null)
		if not next is Dictionary:
			return out
		d = next
	for appid in d:
		var a = d[appid]
		if a is Dictionary:
			out[appid] = {"last_played": int(a.get("lastplayed", "0")), "playtime_min": int(a.get("playtime", "0"))}
	return out


## Every Steam user's folder under userdata/ (one per account that signed in here).
static func user_dirs(steam_root: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(steam_root + "/userdata")
	if dir == null:
		return out
	for d in dir.get_directories():
		if d.is_valid_int() and d != "0":
			out.append(steam_root + "/userdata/" + d)
	return out


## Playtime across every user on this machine (the highest value wins).
static func playtime(steam_root: String) -> Dictionary:
	var out := {}
	for u in user_dirs(steam_root):
		var p := playtime_from_localconfig(u + "/config/localconfig.vdf")
		for appid in p:
			var cur: Dictionary = out.get(appid, {"last_played": 0, "playtime_min": 0})
			out[appid] = {"last_played": maxi(cur["last_played"], p[appid]["last_played"]),
				"playtime_min": maxi(cur["playtime_min"], p[appid]["playtime_min"])}
	return out


static func _first_file(dir: String, names: Array) -> String:
	for n in names:
		if FileAccess.file_exists(dir + "/" + n):
			return dir + "/" + n
	return ""


## Local art for one app: custom grid art, then the per-app librarycache
## folder (and its hashed subfolders), then the old flat librarycache names.
static func art_for(steam_root: String, appid: String, users: Array[String] = []) -> Dictionary:
	var art := {"cover": "", "hero": "", "logo": "", "icon": ""}
	var want := {
		"cover": [["%sp.png", "%sp.jpg"], ["library_600x900.jpg", "library_capsule.jpg", "library_600x900_2x.jpg"], ["%s_library_600x900.jpg"]],
		"hero": [["%s_hero.png", "%s_hero.jpg"], ["library_hero.jpg"], ["%s_library_hero.jpg"]],
		"logo": [["%s_logo.png"], ["logo.png"], ["%s_logo.png"]],
		"icon": [["%s_icon.png", "%s_icon.jpg"], [], ["%s_icon.jpg"]],
	}
	var cache := steam_root + "/appcache/librarycache"
	var app_dirs: Array[String] = [cache + "/" + appid]
	var sub := DirAccess.open(cache + "/" + appid)
	if sub != null:
		for d in sub.get_directories():
			app_dirs.append(cache + "/" + appid + "/" + d)
	var hash_icon := RegEx.create_from_string("^[0-9a-f]{40}\\.(jpg|png)$")
	for kind in want:
		var names: Array = want[kind]
		for u in users:
			if art[kind] == "":
				art[kind] = _first_file(u + "/config/grid", names[0].map(func(n): return n % appid))
		for d in app_dirs:
			if art[kind] == "":
				art[kind] = _first_file(d, names[1])
		if art[kind] == "" and kind == "icon" and sub != null:
			for f in sub.get_files():
				if hash_icon.search(f):
					art[kind] = cache + "/" + appid + "/" + f
					break
		if art[kind] == "":
			art[kind] = _first_file(cache, names[2].map(func(n): return n % appid))
	return art


static func scan(home: String) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	var seen := {}
	var libraries := {}   # library folder -> its app ids, for Storage's Clean up (steam_library_memory.gd)
	for root in STEAM_ROOTS:
		var steam_root := expand(root, home)
		if not DirAccess.dir_exists_absolute(steam_root):
			continue
		var users := user_dirs(steam_root)
		var played := playtime(steam_root)
		for folder in library_folders(steam_root):
			var apps := folder + "/steamapps"
			var dir := DirAccess.open(apps)
			if dir == null:
				continue
			var ids: Array = libraries.get(folder, [])
			libraries[folder] = ids
			for file in dir.get_files():
				if not (file.begins_with("appmanifest_") and file.ends_with(".acf")):
					continue
				ids.append(file.trim_prefix("appmanifest_").trim_suffix(".acf"))
				var m := Acf.parse(FileAccess.get_file_as_string(apps + "/" + file))
				var appid: String = m.get("appid", "")
				var name: String = m.get("name", "")
				if appid == "" or seen.has(appid) or not is_game(name):
					continue
				seen[appid] = true
				var p: Dictionary = played.get(appid, {"last_played": 0, "playtime_min": 0})
				var flags: int = m["flags"]
				found.append({"store": "steam", "id": appid, "title": name,
					# A first install in progress already has a manifest; it isn't playable yet.
					"installed": Acf.is_installed(flags),
					"art": art_for(steam_root, appid, users), "ids": {"steam": appid},
					"last_played": p["last_played"], "playtime_min": p["playtime_min"],
					"state_flags": flags, "busy": Acf.is_busy(flags), "library_folder": folder,
					"install_path": folder.path_join("steamapps/common").path_join(m["installdir"]) if m["installdir"] != "" else ""})
	if not libraries.is_empty():
		LibraryMemory.remember(libraries, int(Time.get_unix_time_from_system()))
	return found


## Every installed Steam game, as store entries (see docs/CONTRACTS.md).
static func list_installed() -> Array[Dictionary]:
	return scan(_home())


## The command that asks the running Steam client to start a game.
static func launch_args(appid: String) -> PackedStringArray:
	if not AppId.valid(appid):
		return PackedStringArray()
	return PackedStringArray(["steam://rungameid/" + appid])


## `steam` on PATH, or "" (Flatpak Steam).
static func steam_bin() -> String:
	var path := OS.get_environment("PATH")
	for dir in path.split(":", false):
		if FileAccess.file_exists(dir.path_join("steam")):
			return dir.path_join("steam")
	return ""


## Hands any steam:// URI to the running client the same way launch() does.
static func open_uri(uri: String, steam_bin_path := "") -> bool:
	if steam_bin_path != "" and OS.create_process(steam_bin_path, PackedStringArray([uri])) > 0:
		return true
	return OS.shell_open(uri) == OK


## Starts a game through Steam. Runs `steam steam://rungameid/<id>` (handed to
## the running client, returns at once) because the session has no desktop for
## xdg-open to ask; falls back to OS.shell_open when `steam` isn't on PATH.
## `steam_bin` is the full path from Common.which, or "".
static func launch(appid: String, steam_bin := "") -> bool:
	if not AppId.valid(appid):
		return false
	if steam_bin != "" and OS.create_process(steam_bin, launch_args(appid)) > 0:
		return true
	return OS.shell_open("steam://rungameid/" + appid) == OK
