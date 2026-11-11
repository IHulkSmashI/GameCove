extends RefCounted
## Epic Games Store, read from legendary's files (github.com/legendary-gl/legendary,
## legendary/lfs/lgndry.py): installed.json (installed games), metadata/<app>.json
## (every owned game), config.ini (per-game wine_prefix). Heroic keeps its own
## copy under <heroic>/legendaryConfig/legendary, so Heroic users need no second
## login. Windows games run through `legendary launch --no-wine --wrapper umu-run`.

const Common := preload("res://scripts/library/stores/common.gd")
const Metadata := preload("res://scripts/library/meta/metadata.gd")


## Every legendary config folder under this home, Heroic's first.
static func config_dirs(home: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for h in Common.heroic_roots(home):
		var dir: String = h["root"] + "/legendaryConfig/legendary"
		if DirAccess.dir_exists_absolute(dir):
			out.append({"dir": dir, "source": "heroic", "heroic_root": h["root"], "heroic_flatpak": h["flatpak"]})
	var own := home + "/.config/legendary"
	if DirAccess.dir_exists_absolute(own):
		out.append({"dir": own, "source": "legendary", "heroic_root": "", "heroic_flatpak": false})
	return out


## DLC and Unreal Engine marketplace assets are not games (legendary core.py skips them too).
static func is_game(meta: Dictionary) -> bool:
	var m = meta.get("metadata", {})
	if not m is Dictionary:
		return true
	if m.has("mainGameItem"):
		return false
	return m.get("namespace", "") != "ue"


## Key image URLs by Epic's type name (DieselGameBoxTall, DieselGameBox, ...).
static func key_images(meta: Dictionary) -> Dictionary:
	var out := {}
	var m = meta.get("metadata", {})
	if m is Dictionary:
		for img in Common.arr(m.get("keyImages")):
			if img is Dictionary and not out.has(img.get("type", "")):
				out[img.get("type", "")] = img.get("url", "")
	return out


## Heroic shows Epic covers and logos with this suffix, and caches that URL.
static func _heroic_urls(url: String) -> Array:
	return [url + "?h=400&resize=1&w=300", url] if url != "" else []


static func art_from_heroic(meta: Dictionary, heroic_root: String) -> Dictionary:
	var art := Common.empty_art()
	if heroic_root == "":
		return art
	var k := key_images(meta)
	var tall: String = k.get("DieselGameBoxTall", k.get("OfferImageTall", ""))
	var wide: String = k.get("DieselGameBox", k.get("OfferImageWide", ""))
	art["cover"] = Common.heroic_cached_image(heroic_root, _heroic_urls(tall))
	art["hero"] = Common.heroic_cached_image(heroic_root, [wide])
	art["logo"] = Common.heroic_cached_image(heroic_root, _heroic_urls(k.get("DieselGameBoxLogo", "")))
	return art


## IDs the game database may know this game by: the app name and the store slug.
static func ids_for(app: String, meta: Dictionary) -> Array:
	var ids := [app]
	var m = meta.get("metadata", {})
	if m is Dictionary:
		var attrs = m.get("customAttributes", {})
		var slug = attrs.get("com.epicgames.app.productSlug", {}) if attrs is Dictionary else {}
		if slug is Dictionary and str(slug.get("value", "")) != "":
			ids.append(str(slug["value"]).trim_suffix("/home"))
		if m.get("id", "") != "":
			ids.append(m["id"])
	return ids


## Value from a Python configparser file such as legendary's config.ini.
static func ini_value(path: String, section: String, key: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var current := ""
	for raw in FileAccess.get_file_as_string(path).split("\n"):
		var line := raw.strip_edges()
		if line.begins_with("[") and line.ends_with("]"):
			current = line.substr(1, line.length() - 2)
		elif current == section and (line.begins_with(key + " ") or line.begins_with(key + "=")):
			return line.substr(line.find("=") + 1).strip_edges()
	return ""


static func scan(home: String) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	var seen := {}
	for cfg in config_dirs(home):
		var dir: String = cfg["dir"]
		var installed = Common.read_json(dir + "/installed.json", {})
		if not installed is Dictionary:
			installed = {}
		var metas := {}
		var mdir := DirAccess.open(dir + "/metadata")
		if mdir != null:
			for f in mdir.get_files():
				if f.ends_with(".json"):
					var meta = Common.read_json(dir + "/metadata/" + f, null)
					if meta is Dictionary and meta.get("app_name", "") != "":
						metas[meta["app_name"]] = meta
		for app in installed:
			if not metas.has(app):
				metas[app] = {"app_name": app, "app_title": installed[app].get("title", app)}
		var playtime := Common.heroic_playtime(cfg["heroic_root"]) if cfg["heroic_root"] != "" else {}
		for app in metas:
			var meta: Dictionary = metas[app]
			var inst = installed.get(app, null)
			if not is_game(meta) or (inst is Dictionary and inst.get("is_dlc", false)) or seen.has(app):
				continue
			seen[app] = true
			var e := {
				"store": "epic", "id": app,
				"title": str(meta.get("app_title", Common.dict(meta.get("metadata")).get("title", app))),
				"installed": inst is Dictionary,
				"art": art_from_heroic(meta, cfg["heroic_root"]),
				"last_played": 0, "playtime_min": 0,
				"ids": {"epic": ids_for(app, meta)},
				"local_meta": Metadata.local_layer("epic", meta),
				"source": cfg["source"], "heroic_root": cfg["heroic_root"], "heroic_flatpak": cfg["heroic_flatpak"],
				"config_dir": dir,
				"install_path": inst.get("install_path", "") if inst is Dictionary else "",
				"platform": str(inst.get("platform", "Windows")).to_lower() if inst is Dictionary else "windows",
				"prefix": "", "proton": true, "proton_path": "",
			}
			if cfg["heroic_root"] != "":
				e.merge(Common.heroic_game_config(cfg["heroic_root"], app, home), true)
				Common.apply_heroic_playtime(e, playtime)
			else:
				var ini := dir + "/config.ini"
				e["prefix"] = ini_value(ini, app, "wine_prefix")
				if e["prefix"] == "":
					e["prefix"] = ini_value(ini, "default", "wine_prefix")
			if e["prefix"] == "":
				e["prefix"] = Common.default_prefix(home, "epic", app)
			found.append(e)
	return found


static func list_games() -> Array[Dictionary]:
	return scan(OS.get_environment("HOME"))


## The command that starts this game, as [program, args...]; [] if we can't.
## legendary handles Epic auth and launch arguments; umu-run runs it in Proton.
static func launch_command(entry: Dictionary, tools: Dictionary, extra_env := {}) -> Array[String]:
	if not entry.get("installed", false):
		return [] as Array[String]
	var wants_heroic: bool = entry.get("source", "") == "heroic" and not entry.get("proton", true)
	if not wants_heroic and tools.get("legendary", "") != "" and tools.get("umu", "") != "":
		var env := Common.umu_env(entry, "egs")
		env["LEGENDARY_CONFIG_PATH"] = entry.get("config_dir", "")
		env.merge(extra_env, true)
		return Common.with_env(env, [tools["legendary"], "launch",
			"--no-wine", "--wrapper", Common.shell_quote(tools["umu"]), "--", entry["id"]])
	if entry.get("source", "") == "heroic":
		return Common.heroic_command(entry, tools, "legendary")
	return [] as Array[String]
