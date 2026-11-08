extends RefCounted
## Amazon Games, read from nile's files (github.com/imLinguin/nile): library.json
## (every owned game, as Amazon entitlements) and installed.json ({id, version,
## path, size}). nile's folder is $NILE_CONFIG_PATH/nile, ~/.config/nile by
## default; Heroic keeps its copy in <heroic>/nile_config/nile.
## Games run through `nile launch <id> --no-wine --wrapper umu-run`.

const Common := preload("res://scripts/library/stores/common.gd")


static func config_dirs(home: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for h in Common.heroic_roots(home):
		var dir: String = h["root"] + "/nile_config/nile"
		if DirAccess.dir_exists_absolute(dir):
			out.append({"dir": dir, "source": "heroic", "heroic_root": h["root"], "heroic_flatpak": h["flatpak"]})
	var own := home + "/.config/nile"
	if DirAccess.dir_exists_absolute(own):
		out.append({"dir": own, "source": "nile", "heroic_root": "", "heroic_flatpak": false})
	return out


static func _details(game: Dictionary) -> Dictionary:
	var product = game.get("product", {})
	var pd = product.get("productDetail", {}) if product is Dictionary else {}
	var d = pd.get("details", {}) if pd is Dictionary else {}
	var out: Dictionary = d.duplicate() if d is Dictionary else {}
	out["iconUrl"] = pd.get("iconUrl", "") if pd is Dictionary else ""
	return out


## Heroic's nile mapping (storeManagers/nile/library.ts): art_square = iconUrl,
## art_cover = backgroundUrl2 or iconUrl, art_logo = logoUrl.
static func art_from_heroic(game: Dictionary, heroic_root: String) -> Dictionary:
	var art := Common.empty_art()
	if heroic_root == "":
		return art
	var d := _details(game)
	art["cover"] = Common.heroic_cached_image(heroic_root, [d.get("iconUrl", "")])
	art["hero"] = Common.heroic_cached_image(heroic_root, [d.get("backgroundUrl1", ""), d.get("backgroundUrl2", "")])
	art["logo"] = Common.heroic_cached_image(heroic_root, [d.get("logoUrl", "")])
	return art


## Amazon lists the game's Steam page among its websites; its app id lets the
## game database match by id instead of by title.
static func ids_for(game: Dictionary) -> Dictionary:
	var sites = _details(game).get("websites", {})
	var ids := {}
	if sites is Dictionary and sites.get("steam") is String:
		var m := RegEx.create_from_string("/app/(\\d+)").search(sites["steam"])
		if m:
			ids["steam"] = m.get_string(1)
	return ids


static func scan(home: String) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	var seen := {}
	for cfg in config_dirs(home):
		var dir: String = cfg["dir"]
		var installed := {}
		var inst_doc = Common.read_json(dir + "/installed.json", [])
		if inst_doc is Array:
			for i in inst_doc:
				if i is Dictionary and str(i.get("id", "")) != "":
					installed[str(i["id"])] = i
		var library := {}
		var lib_doc = Common.read_json(dir + "/library.json", [])
		if lib_doc is Array:
			for g in lib_doc:
				if g is Dictionary and g.get("product") is Dictionary and str(g["product"].get("id", "")) != "":
					library[str(g["product"]["id"])] = g
		for id in installed:
			if not library.has(id):
				library[id] = {"product": {"id": id, "title": str(installed[id].get("path", id)).get_file()}}
		var playtime := Common.heroic_playtime(cfg["heroic_root"]) if cfg["heroic_root"] != "" else {}
		for id in library:
			if seen.has(id):
				continue
			seen[id] = true
			var game: Dictionary = library[id]
			var inst = installed.get(id, null)
			var e := {
				"store": "amazon", "id": id, "title": str(game["product"].get("title", id)),
				"installed": inst is Dictionary,
				"art": art_from_heroic(game, cfg["heroic_root"]),
				"last_played": 0, "playtime_min": 0,
				"ids": ids_for(game),
				"source": cfg["source"], "heroic_root": cfg["heroic_root"], "heroic_flatpak": cfg["heroic_flatpak"],
				"config_dir": dir,
				"install_path": inst.get("path", "") if inst is Dictionary else "",
				"platform": "windows",
				"prefix": "", "proton": true, "proton_path": "",
			}
			if cfg["heroic_root"] != "":
				e.merge(Common.heroic_game_config(cfg["heroic_root"], id, home), true)
				Common.apply_heroic_playtime(e, playtime)
			if e["prefix"] == "":
				e["prefix"] = Common.default_prefix(home, "amazon", id)
			found.append(e)
	return found


static func list_games() -> Array[Dictionary]:
	return scan(OS.get_environment("HOME"))


## The command that starts this game, as [program, args...]; [] if we can't.
## nile reads fuel.json and sets Amazon's FUEL_DIR; umu-run runs it in Proton.
## nile appends "/nile" to NILE_CONFIG_PATH, so we pass the parent folder.
static func launch_command(entry: Dictionary, tools: Dictionary, extra_env := {}) -> Array[String]:
	if not entry.get("installed", false):
		return [] as Array[String]
	var wants_heroic: bool = entry.get("source", "") == "heroic" and not entry.get("proton", true)
	if not wants_heroic and tools.get("nile", "") != "" and tools.get("umu", "") != "":
		var env := Common.umu_env(entry, "amazon")
		env["NILE_CONFIG_PATH"] = str(entry.get("config_dir", "")).get_base_dir()
		env.merge(extra_env, true)
		return Common.with_env(env, [tools["nile"], "launch", entry["id"],
			"--no-wine", "--wrapper", Common.shell_quote(tools["umu"])])
	if entry.get("source", "") == "heroic":
		return Common.heroic_command(entry, tools, "nile")
	return [] as Array[String]
