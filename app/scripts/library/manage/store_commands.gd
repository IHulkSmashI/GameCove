extends RefCounted
## What it takes to install, update, verify, move or uninstall an Epic, GOG or
## Amazon game on this machine: a plan of commands for the download queue, or a
## hand-off to Heroic, or a reason it can't be done. Pure: no files written, no
## processes; the caller passes the store entry, the tools found and a few facts.
##
## Command lines follow each tool's own CLI and what Heroic runs
## (src/backend/storeManagers/{legendary,gog,nile}/games.ts):
##   legendary install --base-path <dir> --platform Windows -y --skip-sdl -- <app>
##   legendary update -y --skip-sdl -- <app> | repair -y --skip-sdl -- <app>
##   legendary uninstall -y --skip-uninstaller -- <app> | move --skip-move -- <app> <dir>
##   gogdl --auth-config-path <auth.json> download|update|repair --platform <p> --path <dir> -- <id>
##   nile install|update|verify [--base-path <dir>] -- <id> | nile uninstall -- <id>
## The store's id (and a folder) always come last, after `--`: ids are read from
## the stores' own files, and one that began with "-" would otherwise be taken
## for an option of the tool. All three tools parse with Python's argparse,
## where `--` ends the options.
## legendary's own `move` only renames inside one drive, so we `mv` first (which
## copies across drives, e.g. to an SD card) and then tell legendary with --skip-move.
##
## Plan: {"ok", "via": legendary|gogdl|nile|heroic|"", "why": "", "steps": [step],
##        "finalize": {...}, "external": [cmd] (Heroic hand-off)}
## step: {"cmd": [program, args...], "env": {}, "parser": legendary|gogdl|nile|size|none,
##        "kind": "probe"|"main", "tool": legendary|gogdl|nile}

const SettingsFile := preload("res://scripts/system/settings_file.gd")

const Common := preload("res://scripts/library/stores/common.gd")

const ACTIONS := ["install", "uninstall", "update", "verify", "move"]
## Where GameCove records GOG games it installed with gogdl itself (Heroic keeps
## its own record, which we never write). Same shape as Heroic's gog_store/installed.json.
const GOG_RECORD: String = preload("res://scripts/library/stores/gog.gd").GOG_RECORD


static func plan(action: String, entry: Dictionary, tools: Dictionary, facts: Dictionary = {}) -> Dictionary:
	if not action in ACTIONS:
		return _no("Unknown action")
	var installed: bool = entry.get("installed", false)
	if action == "install" and installed:
		return _no("Already installed")
	if action != "install" and not installed:
		return _no("Not installed")
	match str(entry.get("store", "")):
		"epic":
			return _epic(action, entry, tools, facts)
		"gog":
			return _gog(action, entry, tools, facts)
		"amazon":
			return _amazon(action, entry, tools, facts)
	return _no("Not a store GameCove manages")


static func _no(why: String) -> Dictionary:
	return {"ok": false, "via": "", "why": why, "steps": [], "finalize": {}, "external": []}


static func _yes(via: String, steps: Array, finalize := {}) -> Dictionary:
	return {"ok": true, "via": via, "why": "", "steps": steps, "finalize": finalize, "external": []}


static func _step(cmd: Array, env: Dictionary, parser: String, tool: String, kind := "main") -> Dictionary:
	var c: Array[String] = []
	for x in cmd:
		c.append(str(x))
	return {"cmd": c, "env": env, "parser": parser, "kind": kind, "tool": tool}


## The folder a game is copied into while it moves to another drive (renamed when whole).
const MOVING_SUFFIX := ".gamecove-moving"


## The file steps of a move from `src` to `dest`/<src's name> (download_queue.gd runs them).
## facts["same_drive"]: one rename, which can't be half done. Otherwise a `mv` would copy
## and then delete, and that can't be picked up again once stopped, so it is done in steps
## that can each be run again:
##   1. cp -a into <new>.gamecove-moving   may be paused or cancelled; running it again
##                                         copies over what is there; a cancel or a failure
##                                         removes the half copy ("cleanup")
##   2. mv <new>.gamecove-moving <new>     one rename on that drive
##   (`between`: the store's own record, e.g. legendary move --skip-move)
##   3. rm -rf the old folder
## From step 2 on the job can't be stopped ("no_stop"); a step with "done_if" is skipped
## when its "gone" path isn't there and its "there" path is (a restart after it ran).
## {"ok", "why", "steps", "new_path"}.
static func move_steps(src: String, dest: String, facts: Dictionary, between: Array = []) -> Dictionary:
	if dest == "" or src == "":
		return {"ok": false, "why": "Pick a folder to move to"}
	var from := src.simplify_path()
	var home := str(facts.get("home", "")).simplify_path()
	if not from.is_absolute_path() or from.count("/") < 2 or from == home or ".." in src.split("/"):
		return {"ok": false, "why": "Won't move this folder: it doesn't look like a game's install"}
	var to := dest.path_join(src.get_file())
	var steps: Array = []
	if bool(facts.get("same_drive", false)):
		var one := _step(["mv", "-T", "--", src, to], {}, "none", "mv")
		one["no_stop"] = true
		one["done_if"] = {"gone": src, "there": to}
		steps.append(one)
		for s in between:
			s["no_stop"] = true
			steps.append(s)
	else:
		var part := to + MOVING_SUFFIX
		var copy := _step(["cp", "-a", "-T", "--", src, part], {}, "none", "cp")
		copy["cleanup"] = ["rm", "-rf", "--", part]
		var rename := _step(["mv", "-T", "--", part, to], {}, "none", "mv")
		rename["no_stop"] = true
		rename["done_if"] = {"gone": part, "there": to}
		steps.append(copy)
		steps.append(rename)
		for s in between:
			s["no_stop"] = true
			steps.append(s)
		var delete := _step(["rm", "-rf", "--", src], {}, "none", "rm")
		delete["no_stop"] = true
		steps.append(delete)
	return {"ok": true, "why": "", "steps": steps, "new_path": to}


## Install folder for a new game: options.path, else <install_root>/<store>.
static func install_base(store: String, facts: Dictionary, options: Dictionary = {}) -> String:
	if str(options.get("path", "")) != "":
		return str(options["path"])
	return str(facts.get("install_root", "")).path_join(store)


## The Heroic hand-off. Install goes through heroic://launch, which asks the user
## to install a game that isn't installed (Heroic src/backend/protocol.ts; the
## protocol knows only `launch` and `ping`). Everything else opens Heroic.
static func _heroic(action: String, entry: Dictionary, tools: Dictionary, runner: String, why_not_us: String) -> Dictionary:
	var order := ["heroic_flatpak", "heroic"] if entry.get("heroic_flatpak", false) else ["heroic", "heroic_flatpak"]
	var base: Array = tools.get(order[0], [])
	if base.is_empty():
		base = tools.get(order[1], [])
	if base.is_empty():
		return _no(why_not_us)
	var cmd: Array[String] = []
	for b in base:
		cmd.append(str(b))
	if action == "install":
		cmd.append("heroic://launch?appName=%s&runner=%s" % [str(entry["id"]).uri_encode(), runner])
	var p := _yes("heroic", [])
	p["external"] = cmd
	return p


static func _epic(action: String, entry: Dictionary, tools: Dictionary, facts: Dictionary) -> Dictionary:
	var legendary := str(tools.get("legendary", ""))
	var heroic_managed: bool = entry.get("source", "") == "heroic"
	if heroic_managed and (entry.get("heroic_flatpak", false) or legendary == ""):
		return _heroic(action, entry, tools, "legendary", "Install legendary or Heroic")
	if legendary == "":
		return _no("Install legendary (or Heroic) to manage Epic games")
	if str(entry.get("config_dir", "")) == "":
		return _no("Sign in to Epic with legendary or Heroic first")
	var env := {"LEGENDARY_CONFIG_PATH": str(entry["config_dir"])}
	var id := str(entry["id"])
	match action:
		"install":
			var base := install_base("epic", facts, facts.get("options", {}))
			return _yes("legendary", [
				_step([legendary, "info", "--json", "--", id], env, "size", "legendary", "probe"),
				_step([legendary, "install", "--base-path", base, "--platform", "Windows", "-y", "--skip-sdl", "--", id], env, "legendary", "legendary"),
			], {"base": base})
		"update":
			return _yes("legendary", [_step([legendary, "update", "-y", "--skip-sdl", "--", id], env, "legendary", "legendary")])
		"verify":
			return _yes("legendary", [_step([legendary, "repair", "-y", "--skip-sdl", "--", id], env, "legendary", "legendary")])
		"uninstall":
			return _yes("legendary", [_step([legendary, "uninstall", "-y", "--skip-uninstaller", "--", id], env, "none", "legendary")])
		"move":
			var dest := str(facts.get("options", {}).get("path", ""))
			var mv := move_steps(str(entry.get("install_path", "")), dest, facts,
				[_step([legendary, "move", "--skip-move", "--", id, dest], env, "none", "legendary")])
			if not mv["ok"]:
				return _no(mv["why"])
			return _yes("legendary", mv["steps"], {"new_path": mv["new_path"]})
	return _no("Unknown action")


## GOG games Heroic installed stay Heroic's (we'd have to write its installed.json).
## Games we install go through gogdl with Heroic's GOG sign-in and are recorded
## in our own file (GOG_RECORD).
static func _gog(action: String, entry: Dictionary, tools: Dictionary, facts: Dictionary) -> Dictionary:
	var gogdl := str(tools.get("gogdl", ""))
	var ours: bool = entry.get("source", "") == "gamecove"
	var auth := str(entry.get("heroic_root", "")).path_join("gog_store/auth.json") if str(entry.get("heroic_root", "")) != "" else ""
	var can_gogdl: bool = gogdl != "" and auth != "" and bool(facts.get("gog_auth_exists", false)) and not entry.get("heroic_flatpak", false)
	if not ours and (entry.get("installed", false) or not can_gogdl):
		return _heroic(action, entry, tools, "gog", "Install Heroic to manage GOG games")
	if ours and not can_gogdl and action in ["update", "verify"]:
		return _no("gogdl and a GOG sign-in in Heroic are needed")
	var id := str(entry["id"])
	var platform := str(entry.get("platform", "windows"))
	if platform == "" or platform == "osx":
		platform = "windows"
	var head: Array = [gogdl, "--auth-config-path", auth]
	match action:
		"install":
			var base := install_base("gog", facts, facts.get("options", {}))
			platform = str(facts.get("options", {}).get("platform", "windows"))
			return _yes("gogdl", [
				_step(head + ["info", "--platform", platform, "--", id], {}, "size", "gogdl", "probe"),
				_step(head + ["download", "--platform", platform, "--path", base, "--skip-dlcs", "--", id], {}, "gogdl", "gogdl"),
			], {"gog_record": "add", "base": base, "platform": platform})
		"update", "verify":
			var sub := "update" if action == "update" else "repair"
			return _yes("gogdl", [_step(head + [sub, "--platform", platform, "--path", str(entry.get("install_path", "")), "--", id], {}, "gogdl", "gogdl")])
		"uninstall":
			var path := str(entry.get("install_path", ""))
			if not safe_to_delete(path, str(facts.get("home", "")), facts.get("gog_marker_exists", false)):
				return _no("Won't delete this folder: it doesn't look like the game's install")
			return _yes("gamecove", [_step(["rm", "-rf", "--", path], {}, "none", "rm")], {"gog_record": "remove"})
		"move":
			var mv := move_steps(str(entry.get("install_path", "")), str(facts.get("options", {}).get("path", "")), facts)
			if not mv["ok"]:
				return _no(mv["why"])
			return _yes("gamecove", mv["steps"], {"gog_record": "move", "new_path": mv["new_path"]})
	return _no("Unknown action")


static func _amazon(action: String, entry: Dictionary, tools: Dictionary, facts: Dictionary) -> Dictionary:
	var nile := str(tools.get("nile", ""))
	var heroic_managed: bool = entry.get("source", "") == "heroic"
	if heroic_managed and (entry.get("heroic_flatpak", false) or nile == ""):
		return _heroic(action, entry, tools, "nile", "Install nile or Heroic")
	if nile == "":
		return _no("Install nile (or Heroic) to manage Amazon games")
	var env := {"NILE_CONFIG_PATH": str(entry.get("config_dir", "")).get_base_dir()}
	var id := str(entry["id"])
	match action:
		"install":
			var base := install_base("amazon", facts, facts.get("options", {}))
			return _yes("nile", [
				_step([nile, "install", "--info", "--json", "--", id], env, "size", "nile", "probe"),
				_step([nile, "install", "--base-path", base, "--", id], env, "nile", "nile"),
			], {"base": base})
		"update":
			return _yes("nile", [_step([nile, "update", "--", id], env, "nile", "nile")])
		"verify":
			return _yes("nile", [_step([nile, "verify", "--", id], env, "nile", "nile")])
		"uninstall":
			return _yes("nile", [_step([nile, "uninstall", "--", id], env, "none", "nile")])
		"move":
			return _no("nile can't move games; reinstall to the new folder")
	return _no("Unknown action")


## True when `path` is `folder` or somewhere inside it.
static func is_inside(path: String, folder: String) -> bool:
	var p := path.simplify_path()
	var f := folder.simplify_path()
	return f != "" and p != "" and (p == f or p.begins_with(f + "/"))


## Only delete a folder that is clearly a game install: absolute, at least three
## levels deep, not the home folder itself, and holding the store's marker file.
static func safe_to_delete(path: String, home: String, has_marker: bool) -> bool:
	var p := path.simplify_path()
	if not p.is_absolute_path() or p.count("/") < 3 or p == home.simplify_path() or ".." in p.split("/"):
		return false
	return has_marker


## Our GOG install record: {"installed": [{"appName", "install_path", "platform", "title"}]}.
static func read_gog_record(home: String) -> Array:
	var d: Variant = Common.read_json(home + GOG_RECORD, {})
	var list: Variant = d.get("installed", []) if d is Dictionary else []
	return list if list is Array else []


static func write_gog_record(home: String, list: Array) -> Error:
	var path := home + GOG_RECORD
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	return SettingsFile.save_text(path, JSON.stringify({"installed": list}, "\t"))


## The record with `item` added (replacing the same appName) or removed.
static func gog_record_with(list: Array, item: Dictionary, remove := false) -> Array:
	var out: Array = []
	for i in list:
		if i is Dictionary and str(i.get("appName", "")) != str(item.get("appName", "")):
			out.append(i)
	if not remove:
		out.append(item)
	return out


## Marker we leave in a GOG folder we installed, so uninstall can prove whose it is.
const GOG_OWNER_FILE := ".gamecove-gog-%s"


## True only when `path` is proven to be GOG game `id`'s folder: it holds
## goggame-<id>.info (Windows builds), our own .gamecove-gog-<id> marker, or a
## Linux gameinfo file with the id on one of its lines. start.sh or a bare
## gameinfo prove nothing (every Linux game has them).
static func gog_folder_is(path: String, id: String) -> bool:
	if path == "" or not id.is_valid_int():
		return false
	if FileAccess.file_exists(path.path_join("goggame-%s.info" % id)):
		return true
	if FileAccess.file_exists(path.path_join(GOG_OWNER_FILE % id)):
		return true
	return gameinfo_has_id(path.path_join("gameinfo"), id)


## GOG's Linux installers write a `gameinfo` text file (title, version, ids one
## per line). True when one line is exactly `id`.
static func gameinfo_has_id(file: String, id: String) -> bool:
	if not FileAccess.file_exists(file):
		return false
	for line in FileAccess.get_file_as_string(file).split("\n"):
		if line.strip_edges() == id:
			return true
	return false


## Folder names directly under `base`, sorted.
static func list_dirs(base: String) -> Array:
	var d := DirAccess.open(base)
	if d == null:
		return []
	var out := Array(d.get_directories())
	out.sort()
	return out


## The folder gogdl created under `base` for game `id`, or "" when it can't be
## proven. First a subfolder that proves itself (gog_folder_is). Otherwise, with
## `before` (the folder names before the download): the one folder that is new,
## looks like a GOG Linux install (gameinfo or .gogdl-linux-manifest), and isn't
## `taken` (folders already recorded for other games) or proven to be another
## game's (goggame-<other>.info). Two candidates = "" (never guess).
static func find_gog_install(base: String, id: String, before: Variant = null, taken: Array = []) -> String:
	if not id.is_valid_int():
		return ""
	var names := list_dirs(base)
	for sub in names:
		if gog_folder_is(base.path_join(sub), id):
			return base.path_join(sub)
	if not before is Array:
		return ""
	var fresh: Array = []
	for sub in names:
		var p := base.path_join(sub)
		if sub in before or p in taken or _other_gog_info(p, id):
			continue
		if FileAccess.file_exists(p.path_join("gameinfo")) or FileAccess.file_exists(p.path_join(".gogdl-linux-manifest")):
			fresh.append(p)
	return fresh[0] if fresh.size() == 1 else ""


static func _other_gog_info(path: String, id: String) -> bool:
	var d := DirAccess.open(path)
	if d == null:
		return false
	for f in d.get_files():
		if f.begins_with("goggame-") and f.ends_with(".info") and f != "goggame-%s.info" % id:
			return true
	return false
