extends RefCounted
## Reads installed Steam games from Steam's own local files and launches them
## through Steam (steam://rungameid/), so Steam Input and shader caching apply.

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


static func scan(home: String) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	var seen := {}
	for root in STEAM_ROOTS:
		var steam_root := expand(root, home)
		if not DirAccess.dir_exists_absolute(steam_root):
			continue
		for folder in library_folders(steam_root):
			var apps := folder + "/steamapps"
			var dir := DirAccess.open(apps)
			if dir == null:
				continue
			for file in dir.get_files():
				if not (file.begins_with("appmanifest_") and file.ends_with(".acf")):
					continue
				var text := FileAccess.get_file_as_string(apps + "/" + file)
				var appid := acf_value(text, "appid")
				var name := acf_value(text, "name")
				if appid == "" or seen.has(appid) or not is_game(name):
					continue
				seen[appid] = true
				found.append({"store": "steam", "id": appid, "title": name, "installed": true})
	return found


## Every installed Steam game, as store entries (see docs/CONTRACTS.md).
static func list_installed() -> Array[Dictionary]:
	return scan(_home())


static func launch(appid: String) -> void:
	OS.shell_open("steam://rungameid/" + appid)
