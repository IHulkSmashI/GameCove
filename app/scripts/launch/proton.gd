extends RefCounted
## Which Proton a game runs with and which flavour it is (Valve Proton, GE-Proton,
## Proton-CachyOS), read from Steam's own files. Read-only.
##
## Steam keeps the per-game choice in config/config.vdf (CompatToolMapping: appid ->
## internal tool name, "0" = the default for every Windows game). Custom builds live
## in compatibilitytools.d, each with a compatibilitytool.vdf naming its internal name.

const VDF := preload("res://scripts/launch/vdf.gd")

const STEAM_ROOTS := [
	"~/.local/share/Steam",
	"~/.steam/steam",
	"~/.steam/root",
	"~/.var/app/com.valvesoftware.Steam/.local/share/Steam",
]
## CachyOS's proton-cachyos package and other system-wide builds install here.
const SYSTEM_TOOL_DIRS := [
	"/usr/share/steam/compatibilitytools.d",
	"/usr/local/share/steam/compatibilitytools.d",
]
## Newest Valve Proton major we know of. "Proton - Experimental", "Proton Hotfix" and
## an unset mapping are treated as this. Bump when Valve ships a new major.
const VALVE_LATEST_MAJOR := 11
## Non-Steam stores launch through umu-run, whose default is UMU-Proton (Valve-based).
const UMU_DEFAULT := "UMU-Proton"


## {"flavour": valve|ge|cachyos|other|native, "major": int, "minor": int, "name": String}.
## major/minor are -1 when the name carries no version.
static func classify(name: String) -> Dictionary:
	var out := {"flavour": "other", "major": -1, "minor": -1, "name": name}
	var low := name.to_lower().strip_edges()
	if low == "" or low.begins_with("steamlinuxruntime") or low.begins_with("steam linux runtime"):
		out["flavour"] = "native"
		return out
	var re := RegEx.new()
	if "cachyos" in low:
		out["flavour"] = "cachyos"
		re.compile("(\\d+)\\.(\\d+)")
		var m := re.search(low)
		if m:
			out["major"] = m.get_string(1).to_int()
			out["minor"] = m.get_string(2).to_int()
		return out
	re.compile("ge-proton(\\d+)-(\\d+)")
	var ge := re.search(low)
	if ge:
		out["flavour"] = "ge"
		out["major"] = ge.get_string(1).to_int()
		out["minor"] = ge.get_string(2).to_int()
		return out
	re.compile("proton-(\\d+)\\.(\\d+)-ge")
	ge = re.search(low)
	if ge:
		out["flavour"] = "ge"
		out["major"] = ge.get_string(1).to_int()
		out["minor"] = ge.get_string(2).to_int()
		return out
	if "experimental" in low or "hotfix" in low or low == "umu-proton" or low.begins_with("umu-proton"):
		out["flavour"] = "valve"
		out["major"] = VALVE_LATEST_MAJOR
		out["minor"] = 0
		return out
	# proton_11, "Proton 11.0", "proton-11.0-1" (Valve's version file)
	re.compile("^(?:\\d+\\s+)?proton[ _-]+(\\d+)(?:\\.(\\d+))?")
	var v := re.search(low)
	if v:
		out["flavour"] = "valve"
		out["major"] = v.get_string(1).to_int()
		out["minor"] = v.get_string(2).to_int() if v.get_string(2) != "" else 0
	return out


static func expand(path: String, home: String) -> String:
	return home + path.substr(1) if path.begins_with("~") else path


## Every custom tool: internal name -> {"dir", "display_name"}.
static func tools(dirs: Array) -> Dictionary:
	var found := {}
	for base in dirs:
		var dir := DirAccess.open(base)
		if dir == null:
			continue
		for sub in dir.get_directories():
			var path: String = base.path_join(sub)
			var vdf := VDF.parse_file(path.path_join("compatibilitytool.vdf"))
			var compat := VDF.find_ci(vdf, "compat_tools")
			if compat.is_empty():
				found[sub] = {"dir": path, "display_name": sub}
				continue
			for internal in compat:
				if found.has(internal) or not (compat[internal] is Dictionary):
					continue
				found[internal] = {"dir": path, "display_name": str(VDF.get_ci(compat[internal], "display_name", sub))}
	return found


## Internal tool name Steam uses for this appid ("" = none set: Steam's default Proton).
static func mapped_tool(config_vdf: Dictionary, appid: String) -> String:
	var mapping := VDF.find_ci(config_vdf, "CompatToolMapping")
	for key in [appid, "0"]:
		var entry: Variant = VDF.get_ci(mapping, key)
		if entry is Dictionary:
			var tool := str(VDF.get_ci(entry, "name", ""))
			if tool != "":
				return tool
	return ""


## Best classification of an internal tool name: the name, then the display name,
## then the folder, then its version file.
static func resolve(tool: String, known_tools: Dictionary) -> Dictionary:
	if tool == "":
		var d := classify("proton_experimental")
		d["name"] = ""
		d["source"] = "steam-default"
		return d
	var candidates: Array[String] = [tool]
	var info: Dictionary = known_tools.get(tool, {})
	if not info.is_empty():
		candidates.append(str(info.get("display_name", "")))
		candidates.append(str(info.get("dir", "")).get_file())
		var version_file := str(info.get("dir", "")).path_join("version")
		if FileAccess.file_exists(version_file):
			candidates.append(FileAccess.get_file_as_string(version_file).strip_edges())
	var best := classify(tool)
	for c in candidates:
		var r := classify(c)
		if r["flavour"] == "other" or r["flavour"] == "native":
			continue
		if best["flavour"] in ["other", "native"] or (best["major"] < 0 and r["major"] >= 0 and r["flavour"] == best["flavour"]):
			best = r
		if best["major"] >= 0:
			break
	best["name"] = tool
	best["source"] = "compatibilitytools.d" if not info.is_empty() else "steam"
	return best


## Proton for a game. Steam games: Steam's mapping. Others: game["proton"] or umu's default.
static func for_game(game: Dictionary, steam_root: String, tool_dirs: Array) -> Dictionary:
	var known := tools(tool_dirs)
	if str(game.get("store", "")) != "steam":
		var name := str(game.get("proton", ""))
		if name == "":
			var d := classify(UMU_DEFAULT)
			d["source"] = "umu-default"
			return d
		return resolve(name, known)
	var config := VDF.parse_file(steam_root.path_join("config/config.vdf"))
	return resolve(mapped_tool(config, str(game.get("id", ""))), known)


## First Steam root that exists under this home, or "".
static func steam_root(home: String) -> String:
	for r in STEAM_ROOTS:
		var p := expand(r, home)
		if DirAccess.dir_exists_absolute(p):
			return p
	return ""


static func tool_dirs(steam_root_path: String, root_prefix := "") -> Array:
	var dirs: Array = []
	if steam_root_path != "":
		dirs.append(steam_root_path.path_join("compatibilitytools.d"))
	for d in SYSTEM_TOOL_DIRS:
		dirs.append(root_prefix + d)
	return dirs
