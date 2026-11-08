extends RefCounted
## Helpers shared by the store readers: JSON files, Heroic's files, tool lookup
## and building launch commands. Everything takes the home folder as an
## argument so tests can point it at fixtures.

const HEROIC_FLATPAK_ID := "com.heroicgameslauncher.hgl"
## Heroic's own config folder (Electron userData): native first, then Flatpak.
const HEROIC_ROOTS := [
	{"path": "/.config/heroic", "flatpak": false},
	{"path": "/.var/app/com.heroicgameslauncher.hgl/config/heroic", "flatpak": true},
]
## Where Heroic's native packages keep their bundled legendary / gogdl / nile binaries.
const HEROIC_BIN_DIRS := [
	"/opt/Heroic/resources/app.asar.unpacked/build/bin/x64/linux",
	"/usr/lib/heroic/resources/app.asar.unpacked/build/bin/x64/linux",
]
const EMPTY_ART := {"cover": "", "hero": "", "logo": "", "icon": ""}


## Parsed JSON file, or `fallback` when the file is missing or broken. Never
## prints errors: a missing store is normal.
static func read_json(path: String, fallback: Variant = null) -> Variant:
	if not FileAccess.file_exists(path):
		return fallback
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK:
		return fallback
	return json.data


static func empty_art() -> Dictionary:
	return EMPTY_ART.duplicate()


## Heroic config folders that exist under this home.
static func heroic_roots(home: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for r in HEROIC_ROOTS:
		var p: String = home + r["path"]
		if DirAccess.dir_exists_absolute(p):
			out.append({"root": p, "flatpak": r["flatpak"]})
	return out


## Heroic caches every image it shows as images-cache/<sha256 of the URL>
## (src/backend/images_cache.ts). Returns the first cached file for these URLs.
static func heroic_cached_image(heroic_root: String, urls: Array) -> String:
	if heroic_root == "":
		return ""
	for u in urls:
		if typeof(u) != TYPE_STRING or u == "":
			continue
		var p: String = heroic_root + "/images-cache/" + (u as String).sha256_text()
		if FileAccess.file_exists(p):
			return p
	return ""


## Heroic's play tracking: store/timestamp.json, keyed by app name, with
## lastPlayed (ISO date) and totalPlayed (minutes).
static func heroic_playtime(heroic_root: String) -> Dictionary:
	var data = read_json(heroic_root + "/store/timestamp.json", {})
	return data if data is Dictionary else {}


static func iso_to_unix(iso: String) -> int:
	if iso.length() < 19:
		return 0
	return int(Time.get_unix_time_from_datetime_string(iso.substr(0, 19)))


static func apply_heroic_playtime(entry: Dictionary, playtime: Dictionary) -> void:
	var t = playtime.get(entry["id"], {})
	if not t is Dictionary:
		return
	entry["last_played"] = iso_to_unix(str(t.get("lastPlayed", "")))
	entry["playtime_min"] = int(t.get("totalPlayed", 0))


## Wine prefix and Proton for a game installed by Heroic, from
## GamesConfig/<app>.json. `proton` is false when Heroic runs it with plain
## Wine, in which case we hand the launch back to Heroic.
static func heroic_game_config(heroic_root: String, app: String, home: String) -> Dictionary:
	var out := {"prefix": "", "proton": true, "proton_path": ""}
	var data = read_json(heroic_root + "/GamesConfig/" + app + ".json", {})
	var cfg = data.get(app, {}) if data is Dictionary else {}
	if not cfg is Dictionary:
		return out
	var prefix := str(cfg.get("winePrefix", ""))
	if prefix.begins_with("~"):
		prefix = home + prefix.substr(1)
	out["prefix"] = prefix
	var wine = cfg.get("wineVersion", {})
	if wine is Dictionary and wine.has("type"):
		out["proton"] = wine["type"] == "proton"
		var bin := str(wine.get("bin", ""))
		if out["proton"] and bin != "":
			out["proton_path"] = bin.get_base_dir()
	return out


## Fallback prefix for games we launch with umu-run ourselves.
static func default_prefix(home: String, store: String, id: String) -> String:
	return "%s/Games/umu/%s-%s" % [home, store, id.validate_filename()]


## First executable called `name` on PATH, or "".
static func which(name: String, path_env: String) -> String:
	for dir in path_env.split(":", false):
		var p := dir.path_join(name)
		if FileAccess.file_exists(p):
			return p
	return ""


## Store tools and launchers available on this machine.
static func find_tools(home: String, path_env: String) -> Dictionary:
	var tools := {"umu": which("umu-run", path_env), "legendary": which("legendary", path_env),
		"nile": which("nile", path_env), "gogdl": which("gogdl", path_env), "heroic": [], "heroic_flatpak": []}
	for dir in HEROIC_BIN_DIRS:
		for name in ["legendary", "nile", "gogdl"]:
			if tools[name] == "" and FileAccess.file_exists(dir + "/" + name):
				tools[name] = dir + "/" + name
	var heroic := which("heroic", path_env)
	if heroic != "":
		tools["heroic"] = [heroic]
	var flatpak := which("flatpak", path_env)
	if flatpak != "" and DirAccess.dir_exists_absolute(home + "/.var/app/" + HEROIC_FLATPAK_ID):
		tools["heroic_flatpak"] = [flatpak, "run", HEROIC_FLATPAK_ID]
	return tools


## Wraps a command in `env [-C dir] K=V ...` so OS.create_process can set the
## environment and working folder. Keys are sorted so the result is stable.
static func with_env(env: Dictionary, cmd: Array, cwd := "") -> Array[String]:
	var out: Array[String] = ["env"]
	if cwd != "":
		out.append_array(["-C", cwd])
	var keys := env.keys()
	keys.sort()
	for k in keys:
		out.append("%s=%s" % [k, env[k]])
	for c in cmd:
		out.append(str(c))
	return out


## Environment umu-run needs: GAMEID picks protonfixes (umu-<steam appid> when
## the game database knows one), STORE names the storefront, WINEPREFIX keeps
## each game in its own prefix (or Heroic's), PROTONPATH reuses Heroic's Proton.
static func umu_env(entry: Dictionary, store: String) -> Dictionary:
	var env := {"GAMEID": entry.get("umu_id", "umu-default"), "STORE": store, "WINEPREFIX": entry.get("prefix", "")}
	if entry.get("proton_path", "") != "":
		env["PROTONPATH"] = entry["proton_path"]
	return env


## Launch through Heroic itself (`heroic://launch`, the same URL Heroic puts in
## its Steam shortcuts). Used when Heroic runs the game with plain Wine or when
## the store's CLI isn't available outside Heroic's Flatpak.
static func heroic_command(entry: Dictionary, tools: Dictionary, runner: String) -> Array[String]:
	var order := ["heroic_flatpak", "heroic"] if entry.get("heroic_flatpak", false) else ["heroic", "heroic_flatpak"]
	var base: Array = tools.get(order[0], [])
	if base.is_empty():
		base = tools.get(order[1], [])
	var out: Array[String] = []
	if base.is_empty():
		return out
	for b in base:
		out.append(str(b))
	out.append_array(["--no-gui", "--no-sandbox",
		"heroic://launch?appName=%s&runner=%s" % [str(entry["id"]).uri_encode(), runner]])
	return out


## Quotes one word for tools that shlex-split an argument (legendary/nile --wrapper).
static func shell_quote(s: String) -> String:
	var safe := RegEx.create_from_string("^[A-Za-z0-9_./+:=-]+$")
	if safe.search(s) != null:
		return s
	return "'" + s.replace("'", "'\"'\"'") + "'"


## Splits a command line like Python's shlex.split (quotes and backslashes).
static func shell_split(s: String) -> Array[String]:
	var out: Array[String] = []
	var cur := ""
	var has := false
	var quote := ""
	var i := 0
	while i < s.length():
		var c := s[i]
		if quote != "":
			if c == quote:
				quote = ""
			elif c == "\\" and quote == "\"" and i + 1 < s.length() and s[i + 1] in ["\"", "\\"]:
				i += 1
				cur += s[i]
			else:
				cur += c
		elif c == "'" or c == "\"":
			quote = c
			has = true
		elif c == "\\" and i + 1 < s.length():
			i += 1
			cur += s[i]
			has = true
		elif c == " " or c == "\t" or c == "\n":
			if has or cur != "":
				out.append(cur)
			cur = ""
			has = false
		else:
			cur += c
		i += 1
	if has or cur != "":
		out.append(cur)
	return out
