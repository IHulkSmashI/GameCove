extends RefCounted
## GOG, read from Heroic's files: gog_store/installed.json (installed games,
## written by Heroic around heroic-gogdl) and store_cache/gog_library.json (every
## owned game). gogdl itself keeps no library of its own
## (github.com/Heroic-Games-Launcher/heroic-gogdl).
## Native Linux games run their start.sh directly. Windows games run the primary
## play task from goggame-<id>.info through umu-run, the same task gogdl's
## `launch` picks (gogdl/launch.py), so no GOG login or gogdl binary is needed.

const Common := preload("res://scripts/library/stores/common.gd")
## GameCove's own record of GOG games it installed with gogdl (see StoreCommands).
const GOG_RECORD := "/.local/share/gamecove/gog/installed.json"


static func art_from_heroic(item: Dictionary, heroic_root: String) -> Dictionary:
	var art := Common.empty_art()
	art["cover"] = Common.heroic_cached_image(heroic_root, [item.get("art_square", "")])
	art["hero"] = Common.heroic_cached_image(heroic_root, [item.get("art_background", ""), item.get("art_cover", "")])
	var logo := str(item.get("art_logo", ""))
	art["logo"] = Common.heroic_cached_image(heroic_root, [logo + "?h=400&resize=1&w=300", logo] if logo != "" else [])
	art["icon"] = Common.heroic_cached_image(heroic_root, [item.get("art_icon", "")])
	return art


## Skips DLC and Heroic's "Galaxy Common Redistributables" pseudo-game.
static func is_game(item: Dictionary) -> bool:
	var id := str(item.get("app_name", ""))
	var inst = item.get("install", {})
	var dlc: bool = item.get("is_dlc", false) or (inst is Dictionary and inst.get("is_dlc", false))
	return id != "" and id != "gog-redist" and not dlc


## Our own install record: appName -> {"appName", "install_path", "platform", "title"}.
static func own_installs(home: String) -> Dictionary:
	var out := {}
	var d: Variant = Common.read_json(home + GOG_RECORD, {})
	var list: Variant = d.get("installed", []) if d is Dictionary else []
	if list is Array:
		for i in list:
			if i is Dictionary and str(i.get("appName", "")) != "":
				out[str(i["appName"])] = i
	return out


static func scan(home: String) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	var seen := {}
	var ours := own_installs(home)
	var titles := {}
	var auth_root := ""
	var auth_flatpak := false
	for h in Common.heroic_roots(home):
		var root: String = h["root"]
		var inst_doc = Common.read_json(root + "/gog_store/installed.json", {})
		var installed := {}
		if inst_doc is Dictionary:
			for i in Common.arr(inst_doc.get("installed")):
				if i is Dictionary and str(i.get("appName", "")) != "" and not i.get("is_dlc", false):
					installed[str(i["appName"])] = i
		var lib_doc = Common.read_json(root + "/store_cache/gog_library.json", {})
		var library := {}
		if lib_doc is Dictionary:
			for g in Common.arr(lib_doc.get("games")):
				if g is Dictionary and is_game(g):
					library[str(g["app_name"])] = g
		for id in installed:
			if not library.has(id):
				library[id] = {"app_name": id, "title": str(installed[id].get("install_path", id)).get_file()}
		var playtime := Common.heroic_playtime(root)
		if auth_root == "":
			auth_root = root
			auth_flatpak = h["flatpak"]
		for id in library:
			titles[id] = library[id]
			var inst = installed.get(id, null)
			if inst == null and ours.has(id):
				continue
			var platform := str(inst.get("platform", "windows")).to_lower() if inst is Dictionary else "windows"
			if seen.has(id) or platform == "osx":
				continue
			seen[id] = true
			var e := {
				"store": "gog", "id": id, "title": str(library[id].get("title", id)),
				"installed": inst is Dictionary,
				"art": art_from_heroic(library[id], root),
				"last_played": 0, "playtime_min": 0,
				"ids": {"gog": id},
				"source": "heroic", "heroic_root": root, "heroic_flatpak": h["flatpak"],
				"install_path": inst.get("install_path", "") if inst is Dictionary else "",
				"platform": platform,
				"prefix": "", "proton": true, "proton_path": "",
			}
			e.merge(Common.heroic_game_config(root, id, home), true)
			if e["prefix"] == "":
				e["prefix"] = Common.default_prefix(home, "gog", id)
			Common.apply_heroic_playtime(e, playtime)
			found.append(e)
	for id in ours:
		if seen.has(id):
			continue
		seen[id] = true
		var rec: Dictionary = ours[id]
		var lib: Dictionary = titles.get(id, {})
		var e := {
			"store": "gog", "id": id, "title": str(lib.get("title", rec.get("title", id))),
			"installed": true,
			"art": art_from_heroic(lib, auth_root) if auth_root != "" else Common.empty_art(),
			"last_played": 0, "playtime_min": 0,
			"ids": {"gog": id},
			# heroic_root: where the GOG sign-in (gog_store/auth.json) lives, for gogdl.
			"source": "gamecove", "heroic_root": auth_root, "heroic_flatpak": auth_flatpak,
			"install_path": str(rec.get("install_path", "")),
			"platform": str(rec.get("platform", "windows")).to_lower(),
			"prefix": Common.default_prefix(home, "gog", id), "proton": true, "proton_path": "",
		}
		found.append(e)
	return found


static func list_games() -> Array[Dictionary]:
	return scan(OS.get_environment("HOME"))


## The primary play task of a Windows install, read from goggame-<id>.info like
## gogdl does: {"exe", "args", "cwd"} as absolute paths, or {} if missing.
static func primary_task(install_path: String, id: String) -> Dictionary:
	var info = Common.read_json(install_path + "/goggame-" + id + ".info", null)
	if not info is Dictionary:
		return {}
	var task = null
	for t in Common.arr(info.get("playTasks")):
		if t is Dictionary and t.get("isPrimary", false):
			task = t
			break
	if task == null:
		return {}
	var args = task.get("arguments", [])
	if args is String:
		args = Common.shell_split(args.replace("\\", "/"))
	var wd := str(task.get("workingDir", "")).replace("\\", "/")
	return {
		"exe": install_path.path_join(str(task.get("path", "")).replace("\\", "/")),
		"args": args if args is Array else [],
		"cwd": install_path.path_join(wd) if wd != "" else install_path,
	}


## The command that starts this game, as [program, args...]; [] if we can't.
## `task` comes from primary_task() for Windows installs.
static func launch_command(entry: Dictionary, tools: Dictionary, task: Dictionary, extra_env := {}) -> Array[String]:
	if not entry.get("installed", false):
		return [] as Array[String]
	var path: String = entry.get("install_path", "")
	if entry.get("platform", "") == "linux":
		return Common.with_env(extra_env, [path.path_join("start.sh")], path)
	var wants_heroic: bool = entry.get("source", "") == "heroic" and not entry.get("proton", true)
	if not wants_heroic and tools.get("umu", "") != "" and not task.is_empty():
		var env := Common.umu_env(entry, "gog")
		env.merge(extra_env, true)
		return Common.with_env(env, [tools["umu"], task["exe"]] + task["args"], task["cwd"])
	return Common.heroic_command(entry, tools, "gog")
