extends RefCounted
## Cloud saves for Epic and GOG games: the stores' own clouds, through the tools that
## already talk to them. Everything here is pure (paths, commands, parsing, decisions) so
## tests cover it without a network; saves_service.gd runs it around a game's launch.
##
## Epic: legendary `sync-saves` (github.com/legendary-gl/legendary, cli.py sync_saves):
##   legendary -y sync-saves <app> --accept-path --skip-upload --skip-download   (look only)
##   ... --skip-upload (download if the cloud is newer) | --skip-download (upload if local is newer)
##   ... --force-download | --force-upload                                       (a conflict, decided)
## legendary computes the save folder once from the game's CloudSaveFolder and the Wine
## prefix (WINEPREFIX), then keeps it in installed.json (save_path), the same call Heroic
## makes (src/backend/save_sync.ts getDefaultLegendarySavePath). Its download empties the
## save folder first (core.py download_saves clean_dir=True), so we back it up before.
##
## GOG: heroic-gogdl `save-sync` (github.com/Heroic-Games-Launcher/heroic-gogdl, saves.py):
##   gogdl --auth-config-path <heroic>/gog_store/auth.json save-sync <folder> <id>
##         --os windows --ts <last sync> --name <location> [--skip-upload|--skip-download|
##         --force-upload|--force-download]
## gogdl prints the new sync timestamp on stdout; on a conflict it only logs one (and still
## prints a fresh timestamp, which must not be kept). Its download deletes local files the
## cloud doesn't have and its upload deletes cloud files the folder doesn't have, so we back
## up both sides before any forced choice. gogdl has no dry run, but with a --ts in the far
## future nothing counts as changed on either side, so it only lists the cloud ("look"); an
## upload that would delete cloud files the folder lacks is held until a copy of the cloud is
## kept (saves_service.gd). The save folders are Heroic's (GamesConfig
## gogSaves, already resolved), else gog_library.json's gog_save_location with GOG's
## <?VARIABLES?> resolved in the prefix (Heroic's getDefaultGogSavePaths), else GOG's remote
## config for the game's clientId (remote-config.gog.com, as Heroic's getSaveSyncLocation).
##
## Amazon: nile has no save sync (github.com/imLinguin/nile), so Amazon games aren't covered.

const Common := preload("res://scripts/library/stores/common.gd")

const HEROIC_FLATPAK_ID := "com.heroicgameslauncher.hgl"
## A clock difference smaller than this is the same moment (legendary SAME_AGE uses 60 s).
const SLACK_S := 60
## Save folders larger than this aren't backed up (a game that keeps saves in its install
## folder); a download that would empty one is refused instead.
const MAX_BACKUP_BYTES := 1024 * 1024 * 1024
## Seconds a sync may take before it's given up (coreutils `timeout`).
const TIMEOUT_S := 90
## GOG's remote config, per game client id (Heroic: component_version=2.0.45).
const GOG_REMOTE_CONFIG := "https://remote-config.gog.com/components/galaxy_client/clients/%s?component_version=2.0.45"
## GOG save-folder variables (Heroic save_sync.ts gogVariableMap, Windows games).
const GOG_VARS := {
	"INSTALL": "{install}",
	"SAVED_GAMES": "%USERPROFILE%/Saved Games",
	"APPLICATION_DATA_LOCAL": "%LOCALAPPDATA%",
	"APPLICATION_DATA_LOCAL_LOW": "%APPDATA%/../LocalLow",
	"APPLICATION_DATA_ROAMING": "%APPDATA%",
	"DOCUMENTS": "%USERPROFILE%/Documents",
}


# ---- which games -----------------------------------------------------------------------------

## "epic" | "gog" | "" for a game (installed Epic or GOG games only).
static func kind_of(entry: Dictionary) -> String:
	if not bool(entry.get("installed", false)):
		return ""
	var s := str(entry.get("store", ""))
	return s if s in ["epic", "gog"] else ""


## The Wine prefix that holds drive_c: the folder itself (umu, Wine) or its pfx/ (Proton's
## STEAM_COMPAT_DATA_PATH layout, Heroic's Proton prefixes). "" when it isn't made yet.
static func wine_prefix(prefix: String) -> String:
	if prefix == "":
		return ""
	if DirAccess.dir_exists_absolute(prefix.path_join("drive_c")):
		return prefix
	if DirAccess.dir_exists_absolute(prefix.path_join("pfx/drive_c")):
		return prefix.path_join("pfx")
	return ""


## The Windows user folder in a prefix: steamuser (Proton), else the one user that isn't Public.
static func prefix_user_dir(pfx: String) -> String:
	var users := pfx.path_join("drive_c/users")
	if DirAccess.dir_exists_absolute(users.path_join("steamuser")):
		return users.path_join("steamuser")
	for d in DirAccess.get_directories_at(users):
		if d.to_lower() != "public":
			return users.path_join(d)
	return ""


# ---- commands ----------------------------------------------------------------------------------

## How to run a store tool: native binary, or Heroic's Flatpak with its bundled one.
## {"ok", "cmd": [program, args...] before the tool's own arguments, "env": {}, "why"}.
static func tool_base(tool_name: String, entry: Dictionary, tools: Dictionary, env: Dictionary) -> Dictionary:
	var native := str(tools.get(tool_name, ""))
	var flatpak: Array = tools.get("heroic_flatpak", []) if tools.get("heroic_flatpak") is Array else []
	var use_flatpak := (bool(entry.get("heroic_flatpak", false)) or native == "") and flatpak.size() >= 1
	if native != "" and not use_flatpak:
		var cmd: Array = ["env"]
		var keys := env.keys()
		keys.sort()
		for k in keys:
			cmd.append("%s=%s" % [k, env[k]])
		cmd.append(native)
		return {"ok": true, "cmd": cmd}
	if use_flatpak:
		var cmd: Array = [str(flatpak[0]), "run", "--command=" + tool_name]
		var keys := env.keys()
		keys.sort()
		for k in keys:
			cmd.append("--env=%s=%s" % [k, env[k]])
		cmd.append(HEROIC_FLATPAK_ID)
		return {"ok": true, "cmd": cmd}
	return {"ok": false, "cmd": [], "why": "no_tool"}


## [timeout ...] + base + args, as one argv.
static func with_timeout(base: Array, args: Array, secs := TIMEOUT_S) -> Array[String]:
	var out: Array[String] = ["timeout", "-k", "5", str(secs)]
	for a in base + args:
		out.append(str(a))
	return out


## legendary's arguments for one sync step. step: check | download | upload | force_download | force_upload.
static func legendary_args(app: String, step: String) -> Array:
	var a: Array = ["-y", "sync-saves", app, "--accept-path"]
	match step:
		"check": a.append_array(["--skip-upload", "--skip-download"])
		"download": a.append("--skip-upload")
		"upload": a.append("--skip-download")
		"force_download": a.append("--force-download")
		"force_upload": a.append("--force-upload")
	return a


## A sync time later than any file's: with it gogdl finds nothing changed on either side and
## only lists the cloud's files (saves.py SyncClassifier.classify compares against --ts).
const GOG_LOOK_TS := "9999999999"


## gogdl's arguments for one location. step: pre (download only) | post (upload only) |
## force_download | force_upload | fetch (into an empty folder: everything in the cloud) |
## look (changes nothing when both sides have files: lists the cloud).
static func gogdl_args(auth: String, path: String, id: String, name: String, ts: String, step: String) -> Array:
	var a: Array = ["--auth-config-path", auth, "save-sync", path, id, "--os", "windows",
		"--ts", GOG_LOOK_TS if step == "look" else (ts if ts != "" else "0"), "--name", name]
	match step:
		"pre": a.append("--skip-upload")
		"post": a.append("--skip-download")
		"force_download": a.append("--force-download")
		"force_upload": a.append("--force-upload")
	# the cloud's file list with their times (for the conflict prompt) is only logged at debug level
	a.append("--debug")
	return a


# ---- Epic --------------------------------------------------------------------------------------

## legendary's metadata for the app (<config>/metadata/<app>.json), {} when missing.
static func epic_meta(config_dir: String, app: String) -> Dictionary:
	var m: Variant = Common.read_json(config_dir.path_join("metadata/%s.json" % app), {})
	return m if m is Dictionary else {}


## The game's cloud save folder pattern (CloudSaveFolder), "" when it has no cloud saves.
static func epic_cloud_folder(meta: Dictionary) -> String:
	var attrs: Variant = Common.dict(meta.get("metadata")).get("customAttributes", {})
	if not attrs is Dictionary:
		return ""
	return str(Common.dict(attrs.get("CloudSaveFolder")).get("value", ""))


## The save folder legendary keeps for the app (installed.json save_path), "" when unset.
static func epic_save_path(config_dir: String, app: String) -> String:
	var inst: Variant = Common.read_json(config_dir.path_join("installed.json"), {})
	if not inst is Dictionary:
		return ""
	var v: Variant = Common.dict(inst.get(app)).get("save_path")
	return str(v) if v is String else ""


## What's needed to sync an Epic game: {"ok", "why", "cmd", "save_path", "needs_prefix"}.
## why: no_tool | signed_out | unsupported | not_set_up.
static func epic_plan(entry: Dictionary, tools: Dictionary) -> Dictionary:
	var cfg := str(entry.get("config_dir", ""))
	var app := str(entry.get("id", ""))
	if cfg == "" or not FileAccess.file_exists(cfg.path_join("user.json")):
		return {"ok": false, "why": "signed_out"}
	var folder := epic_cloud_folder(epic_meta(cfg, app))
	if folder == "":
		return {"ok": false, "why": "unsupported"}
	var saved := epic_save_path(cfg, app)
	var env := {"LEGENDARY_CONFIG_PATH": cfg}
	var pfx := wine_prefix(str(entry.get("prefix", "")))
	var windows := str(entry.get("platform", "windows")).to_lower() == "windows"
	var only_install := folder.to_lower().replace("\\", "/").begins_with("{installdir}")
	if saved == "" and windows and not only_install and (pfx == "" or not FileAccess.file_exists(pfx.path_join("user.reg"))):
		# legendary would guess the folder from ~/.wine and keep the wrong one: wait for the
		# prefix, which the first launch makes
		return {"ok": false, "why": "not_set_up"}
	if pfx != "":
		env["WINEPREFIX"] = pfx
	var base := tool_base("legendary", entry, tools, env)
	if not base["ok"]:
		return {"ok": false, "why": "no_tool"}
	return {"ok": true, "why": "", "cmd": base["cmd"], "save_path": saved}


## "2026-11-10 12:30:00" (UTC, as legendary prints it) -> unix seconds; 0 for N/A.
static func utc_to_unix(s: String) -> int:
	var t := s.strip_edges()
	if t.length() < 19 or t.begins_with("N/A"):
		return 0
	return int(Time.get_unix_time_from_datetime_string(t.substr(0, 10) + "T" + t.substr(11, 8)))


## legendary sync-saves output -> {"state", "local", "remote", "save_path", "acted", "error"}.
## state: same | remote_newer | local_newer | none | unsupported | no_path | offline | failed.
static func parse_legendary(out: String, code: int) -> Dictionary:
	var r := {"state": "", "local": 0, "remote": 0, "save_path": "", "acted": "", "error": ""}
	var checking := false
	for raw in out.split("\n"):
		var line := raw.strip_edges()
		var msg := line.substr(line.find(": ") + 2) if line.begins_with("[") and line.find(": ") > 0 else line
		if msg.begins_with("Checking \""):
			checking = true
		elif msg.begins_with("Computed save path: \""):
			r["save_path"] = msg.trim_prefix("Computed save path: \"").trim_suffix("\"")
		elif msg.begins_with("Overriding save path with"):
			pass
		elif msg.begins_with("Cloud save for ") and msg.ends_with("is newer:"):
			r["state"] = "remote_newer"
		elif msg.begins_with("Local save for ") and msg.ends_with("is newer"):
			r["state"] = "local_newer"
		elif msg.begins_with("Save game for ") and msg.ends_with("is up to date, skipping..."):
			r["state"] = "same"
		elif msg.begins_with("No cloud or local savegame found"):
			r["state"] = "none"
		elif msg.begins_with("- Cloud save date: "):
			r["remote"] = utc_to_unix(msg.trim_prefix("- Cloud save date: "))
		elif msg.begins_with("- Local save date: "):
			r["local"] = utc_to_unix(msg.trim_prefix("- Local save date: "))
		elif msg.begins_with("Path contains unprocessed variables") or msg.begins_with("Save path for this title has not been set"):
			r["state"] = "no_path"
		elif msg.begins_with("Downloading remote savegame"):
			r["acted"] = "download"
		elif msg.begins_with("Uploading local savegame"):
			r["acted"] = "upload"
		elif line.contains(" ERROR: ") or line.contains(" CRITICAL: ") or line.begins_with("Traceback"):
			if r["error"] == "":
				r["error"] = msg
	if code == 124 or code == 137 or _offline(out):
		r["state"] = "offline"
	elif code != 0 or r["error"] != "":
		r["state"] = "failed"
		if r["error"] == "":
			r["error"] = "legendary stopped (code %d)" % code
	elif r["state"] == "" and not checking:
		r["state"] = "unsupported"   # legendary skips games without cloud saves silently
	elif r["state"] == "":
		r["state"] = "none"
	return r


static func _offline(out: String) -> bool:
	for w in ["Login failed", "ConnectionError", "Max retries exceeded", "NameResolutionError",
			"Temporary failure in name resolution", "Failed to establish a new connection", "Network is unreachable",
			"Read timed out", "ConnectTimeout"]:
		if out.contains(w):
			return true
	return false


## What to do with a legendary look. mode: pre (before a launch: download only) | post
## (after a game: upload only) | now (both ways). last_sync: unix time of our last good sync
## of this game (0 = never). -> none | download | upload | conflict | later.
## A side counts as changed since the last sync when its newest save is past last_sync; when
## both changed (or we never synced and both have saves), the user picks.
static func epic_decide(look: Dictionary, last_sync: int, mode: String) -> String:
	var local := int(look.get("local", 0))
	var remote := int(look.get("remote", 0))
	match str(look.get("state", "")):
		"remote_newer":
			var local_changed := local > 0 and (last_sync <= 0 or local > last_sync + SLACK_S)
			if local_changed:
				return "conflict"
			return "later" if mode == "post" else "download"
		"local_newer":
			var remote_changed := remote > 0 and (last_sync <= 0 or remote > last_sync + SLACK_S)
			if remote_changed:
				return "conflict"
			return "later" if mode == "pre" else "upload"
	return "none"


# ---- GOG ---------------------------------------------------------------------------------------

## GOG's sign-in file in Heroic's config.
static func gog_auth(entry: Dictionary) -> String:
	var root := str(entry.get("heroic_root", ""))
	return root.path_join("gog_store/auth.json") if root != "" else ""


## Save locations Heroic already resolved (GamesConfig/<id>.json gogSaves): [{name, location}].
static func heroic_gog_saves(heroic_root: String, id: String) -> Array:
	var d: Variant = Common.read_json(heroic_root.path_join("GamesConfig/%s.json" % id), {})
	var cfg: Variant = d.get(id, {}) if d is Dictionary else {}
	var out: Array = []
	for s in Common.arr(Common.dict(cfg).get("gogSaves")):
		if s is Dictionary and str(s.get("name", "")) != "" and str(s.get("location", "")) != "":
			out.append({"name": str(s["name"]), "location": str(s["location"])})
	return out


## Unresolved locations from Heroic's library cache (gog_save_location), or null when the
## game isn't there (null: ask GOG; []: no locations, use the default one).
static func heroic_gog_locations(heroic_root: String, id: String) -> Variant:
	var lib: Variant = Common.read_json(heroic_root.path_join("store_cache/gog_library.json"), {})
	for g in Common.arr(Common.dict(lib).get("games")):
		if g is Dictionary and str(g.get("app_name", "")) == id:
			if not g.has("gog_save_location") and not bool(g.get("cloud_save_enabled", false)):
				return null
			var out: Array = []
			for s in Common.arr(g.get("gog_save_location")):
				if s is Dictionary and str(s.get("name", "")) != "":
					out.append({"name": str(s["name"]), "location": str(s.get("location", ""))})
			return out
	return null


## Heroic's last sync timestamps (gog_store/saveTimestamps.json, electron-store: {id: {name: ts}}).
static func heroic_gog_timestamps(heroic_root: String, id: String) -> Dictionary:
	var d: Variant = Common.read_json(heroic_root.path_join("gog_store/saveTimestamps.json"), {})
	var v: Variant = Common.dict(d).get(id, {})
	var out := {}
	for k in Common.dict(v):
		out[str(k)] = str(v[k])
	return out


## The game's GOG client id from goggame-<id>.info, "" when missing.
static func gog_client_id(install_path: String, id: String) -> String:
	var info: Variant = Common.read_json(install_path.path_join("goggame-%s.info" % id), {})
	return str(Common.dict(info).get("clientId", ""))


## GOG remote config JSON -> locations [{name, location}] (Windows), [] when cloud storage is
## on with no locations listed, null when the game has no cloud saves.
static func parse_gog_remote(text: String) -> Variant:
	var j := JSON.new()
	if j.parse(text) != OK or not j.data is Dictionary:
		return null
	var win: Dictionary = Common.dict(Common.dict(j.data.get("content")).get("Windows"))
	var cs: Dictionary = Common.dict(win.get("cloudStorage"))
	if not bool(cs.get("enabled", false)):
		return null
	var out: Array = []
	for s in Common.arr(cs.get("locations")):
		if s is Dictionary and str(s.get("name", "")) != "":
			out.append({"name": str(s["name"]), "location": str(s.get("location", ""))})
	return out


## The folder GOG Galaxy uses when a game lists none (Heroic: %LocalAppData%/GOG.com/...).
static func gog_default_location(client_id: String) -> Dictionary:
	return {"name": "__default", "location": "%%LOCALAPPDATA%%/GOG.com/Galaxy/Applications/%s/Storage/Shared/Files" % client_id}


## A GOG location (<?VAR?> and %VAR%) as a folder on this machine, in the Wine prefix `pfx`.
## "" when it can't be resolved (unknown variable, no prefix yet).
static func resolve_gog_location(location: String, install_path: String, pfx: String) -> String:
	var p := location.replace("\\", "/")
	var rx := RegEx.create_from_string("<\\?(\\w+)\\?>")
	for m in rx.search_all(p):
		var v := m.get_string(1)
		if not GOG_VARS.has(v):
			return ""
		p = p.replace(m.get_string(0), str(GOG_VARS[v]))
	p = p.replace("{install}", install_path)
	if p.contains("%"):
		if pfx == "":
			return ""
		var user := prefix_user_dir(pfx)
		if user == "":
			return ""
		var map := {"USERPROFILE": user, "LOCALAPPDATA": user.path_join("AppData/Local"),
			"APPDATA": user.path_join("AppData/Roaming")}
		var vx := RegEx.create_from_string("%(\\w+)%")
		for m in vx.search_all(p):
			var key := m.get_string(1).to_upper()
			if not map.has(key):
				return ""
			p = p.replace(m.get_string(0), map[key])
	if not p.begins_with("/"):
		return ""
	return case_insensitive(p.simplify_path())


## Matches each existing folder of `path` case-insensitively (Windows games' paths, on a
## case-sensitive disk), like legendary's case_insensitive_path_search. The rest stays as is.
static func case_insensitive(path: String) -> String:
	var parts := path.split("/", false)
	var cur := ""
	for i in parts.size():
		var want := parts[i]
		var nxt := cur + "/" + want
		if not DirAccess.dir_exists_absolute(nxt) and DirAccess.dir_exists_absolute(cur if cur != "" else "/"):
			for d in DirAccess.get_directories_at(cur if cur != "" else "/"):
				if d.to_lower() == want.to_lower():
					nxt = cur + "/" + d
					break
		cur = nxt
	return cur if cur != "" else "/"


## What's needed to sync a GOG game. `remote` is GOG's answer for its client id when already
## asked (null = not asked). {"ok", "why", "cmd", "auth", "locations": [{name, path, heroic:
## true when the folder is the one Heroic syncs}], "client_id", "ask_remote"}; why: no_tool | signed_out | unsupported | linux | not_set_up | ask.
static func gog_plan(entry: Dictionary, tools: Dictionary, remote: Variant = null) -> Dictionary:
	var auth := gog_auth(entry)
	if auth == "" or not FileAccess.file_exists(auth):
		return {"ok": false, "why": "signed_out"}
	if str(entry.get("platform", "windows")).to_lower() != "windows":
		return {"ok": false, "why": "linux"}
	var id := str(entry.get("id", ""))
	var root := str(entry.get("heroic_root", ""))
	var install := str(entry.get("install_path", ""))
	var pfx := wine_prefix(str(entry.get("prefix", "")))
	var base := tool_base("gogdl", entry, tools, {})
	if not base["ok"]:
		return {"ok": false, "why": "no_tool"}
	var resolved := heroic_gog_saves(root, id) if root != "" else []
	var locations: Array = []
	if not resolved.is_empty():
		for s in resolved:
			locations.append({"name": s["name"], "path": s["location"], "heroic": true})
	else:
		var raw: Variant = heroic_gog_locations(root, id) if root != "" else null
		var client := gog_client_id(install, id)
		if raw == null:
			if remote == null:
				if client == "":
					return {"ok": false, "why": "unsupported"}
				return {"ok": false, "why": "ask", "client_id": client}
			raw = remote
		if raw is String and raw == "none":
			return {"ok": false, "why": "unsupported"}
		var list: Array = raw if raw is Array else []
		if list.is_empty():
			if client == "":
				return {"ok": false, "why": "unsupported"}
			list = [gog_default_location(client)]
		for s in list:
			var path := resolve_gog_location(str(s["location"]), install, pfx)
			if path == "":
				return {"ok": false, "why": "not_set_up"}
			locations.append({"name": str(s["name"]), "path": path})
	return {"ok": true, "why": "", "cmd": base["cmd"], "auth": auth, "locations": locations}


## gogdl save-sync output -> {"action", "ts", "cloud_newest", "error", "offline", "refused",
## "cloud_count", "cloud_files"}.
## action: upload | download | conflict | none | refused | failed. refused: "upload" (the
## cloud is newer and this run could only upload) | "download" | "". cloud_count: files GOG
## holds for the game (-1 when the log didn't say); cloud_files: [{name, hash}] of them, null
## when the list wasn't in the log.
static func parse_gogdl(out: String, code: int) -> Dictionary:
	var r := {"action": "none", "ts": "", "cloud_newest": 0, "error": "", "offline": false, "refused": "",
		"cloud_count": -1, "cloud_files": null}
	for raw in out.split("\n"):
		var line := raw.strip_edges()
		if line.contains("Files in conflict"):
			r["action"] = "conflict"
		elif line.contains("Refused to upload") or line.contains("Refused to download"):
			r["action"] = "refused"
			r["refused"] = "upload" if line.contains("Refused to upload") else "download"
		elif line.contains("Files in cloud: "):
			r["cloud_count"] = line.get_slice("Files in cloud: ", 1).to_int()
		elif line.contains("DEBUG: Files: ["):
			r["cloud_files"] = parse_gog_listing(line.substr(line.find("Files: [") + 7))
		elif line.contains("No files in cloud, uploading") or line.contains("Uploading files") or line.contains("Forcing upload"):
			if r["action"] != "conflict":
				r["action"] = "upload"
		elif line.contains("No files locally, downloading") or line.contains("Downloading files") or line.contains("Forcing download"):
			if r["action"] != "conflict":
				r["action"] = "download"
		elif line.contains("Downloading file failed") or line.contains("There was an error uploading") or line.contains("Failed to commit") \
				or line.contains("] ERROR: ") or line.begins_with("Traceback"):
			if r["error"] == "":
				r["error"] = line
	var lm := RegEx.create_from_string("'last_modified':\\s*'([^']+)'")
	for m in lm.search_all(out):
		r["cloud_newest"] = maxi(int(r["cloud_newest"]), iso_to_unix(m.get_string(1)))
	# the timestamp is gogdl's stdout, written last (no newline), possibly glued to a log line
	var tx := RegEx.create_from_string("(?<![\\w.])(\\d{10}(?:\\.\\d+)?)(?![\\w.])")
	var all := tx.search_all(out)
	if not all.is_empty():
		r["ts"] = all[all.size() - 1].get_string(1)
	if code == 124 or code == 137 or _offline(out):
		r["offline"] = true
		r["action"] = "failed"
	elif code != 0 or r["error"] != "":
		r["action"] = "failed"
		if r["error"] == "":
			r["error"] = "gogdl stopped (code %d)" % code
	return r


## The cloud's file list as gogdl logs it at debug level (a Python list of dicts:
## [{'name': 'saves/slot1.sav', 'hash': '...', 'last_modified': '...'}, ...]) ->
## [{name, hash}], or null when it doesn't read as one (then nothing may be assumed).
static func parse_gog_listing(text: String) -> Variant:
	var t := text.strip_edges()
	if not t.begins_with("[") or not t.ends_with("]"):
		return null
	var out: Array = []
	var inner := t.substr(1, t.length() - 2).strip_edges()
	if inner == "":
		return out
	var item := RegEx.create_from_string("\\{[^{}]*\\}")
	var name_rx := RegEx.create_from_string("'name':\\s*(?:'([^'\\\\]*)'|\"([^\"\\\\]*)\")")
	var hash_rx := RegEx.create_from_string("'hash':\\s*'([^']*)'")
	var covered := 0
	for m in item.search_all(inner):
		var n := name_rx.search(m.get_string(0))
		if n == null:
			return null   # a name with escapes: not guessed at
		var h := hash_rx.search(m.get_string(0))
		out.append({"name": n.get_string(1) if n.get_string(1) != "" else n.get_string(2), "hash": h.get_string(1) if h != null else ""})
		covered += m.get_string(0).length()
	# everything between the dicts must be ", ": anything else and the list isn't what we think
	if inner.length() - covered != maxi(0, out.size() - 1) * 2:
		return null
	return out


## GOG marks a file deleted in the cloud with this content hash (saves.py skips them).
const GOG_DELETED_HASH := "aadd86936a80ee8a369579c3926f1b3c"


## Files of location `name` the cloud holds and `folder` doesn't: what an upload from
## `folder` would delete in the cloud (saves.py: not_existing_locally). null when the
## listing is unknown.
static func gog_cloud_only(listing: Variant, name: String, folder: String) -> Variant:
	if not listing is Array:
		return null
	var have := {}
	for rel in rel_files(folder):
		have[rel] = true
	var out: Array = []
	for f in listing:
		var n := str(f["name"])
		if not n.begins_with(name) or str(f["hash"]) == GOG_DELETED_HASH:
			continue
		# as gogdl: the first "<name>/" taken out
		var at := n.find(name + "/")
		var rel := n if at < 0 else n.substr(0, at) + n.substr(at + name.length() + 1)
		if not have.has(rel):
			out.append(rel)
	return out


## ISO 8601 with an offset ("2026-11-10T10:00:00+01:00", "...Z") -> unix seconds; 0 when not.
static func iso_to_unix(iso: String) -> int:
	var s := iso.strip_edges()
	if s.length() < 19:
		return 0
	var t := int(Time.get_unix_time_from_datetime_string(s.substr(0, 19)))
	var rest := s.substr(19)
	var dot := 0
	while dot < rest.length() and (rest[dot] == "." or rest[dot].is_valid_int()):
		dot += 1
	rest = rest.substr(dot)
	if rest.length() >= 6 and (rest[0] == "+" or rest[0] == "-"):
		var off := rest.substr(1, 2).to_int() * 3600 + rest.substr(4, 2).to_int() * 60
		t -= off if rest[0] == "+" else -off
	return t


# ---- local folders -----------------------------------------------------------------------------

## {"files", "bytes", "newest"} of everything under `path` (newest: latest file mtime).
## Stops counting past MAX_BACKUP_BYTES (only "too big" matters then).
static func dir_stats(path: String) -> Dictionary:
	var r := {"files": 0, "bytes": 0, "newest": 0}
	if path == "" or not DirAccess.dir_exists_absolute(path):
		return r
	_walk(path, r, 0)
	return r


## Every file under `path`, relative to it with "/" between folders.
static func rel_files(path: String, base := "", depth := 0) -> Array:
	var out: Array = []
	var d := DirAccess.open(path) if path != "" and depth <= 24 else null
	if d == null:
		return out
	d.include_hidden = true
	for f in d.get_files():
		out.append(base + f)
	for sub in d.get_directories():
		out.append_array(rel_files(path.path_join(sub), base + sub + "/", depth + 1))
	return out


## The newest file under `path` ("" when there is none).
static func newest_file(path: String) -> String:
	var best := ""
	var t := -1
	for rel in rel_files(path):
		var m := int(FileAccess.get_modified_time(path.path_join(rel)))
		if m > t:
			t = m
			best = path.path_join(rel)
	return best


static func _walk(path: String, r: Dictionary, depth: int) -> void:
	if depth > 24 or int(r["bytes"]) > MAX_BACKUP_BYTES:
		return
	var d := DirAccess.open(path)
	if d == null:
		return
	d.include_hidden = true
	for f in d.get_files():
		var p := path.path_join(f)
		var fa := FileAccess.open(p, FileAccess.READ)
		if fa != null:
			r["bytes"] = int(r["bytes"]) + fa.get_length()
			fa.close()
		r["files"] = int(r["files"]) + 1
		r["newest"] = maxi(int(r["newest"]), int(FileAccess.get_modified_time(p)))
	for sub in d.get_directories():
		_walk(path.path_join(sub), r, depth + 1)
