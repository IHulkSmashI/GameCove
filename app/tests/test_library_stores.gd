extends "res://tests/test_case.gd"
## Store readers against fixture homes in the real file formats of legendary,
## Heroic, nile and Steam (app/tests/fixtures/library/home).

const Steam := preload("res://scripts/library/stores/steam.gd")
const Epic := preload("res://scripts/library/stores/epic.gd")
const Gog := preload("res://scripts/library/stores/gog.gd")
const Amazon := preload("res://scripts/library/stores/amazon.gd")
const Common := preload("res://scripts/library/stores/common.gd")


func _home() -> String:
	return fixture("library/home")


func _by_id(list: Array[Dictionary]) -> Dictionary:
	var out := {}
	for e in list:
		out[e["id"]] = e
	return out


func test_missing_config_dirs_give_empty_lists() -> void:
	for home in ["/nonexistent/gamecove-home", fixture("library/games")]:
		eq(Steam.scan(home).size(), 0, "steam empty")
		eq(Epic.scan(home).size(), 0, "epic empty")
		eq(Gog.scan(home).size(), 0, "gog empty")
		eq(Amazon.scan(home).size(), 0, "amazon empty")
	eq(Steam.playtime_from_localconfig("/nonexistent/localconfig.vdf"), {}, "no localconfig")
	eq(Gog.primary_task("/nonexistent", "1"), {}, "no goggame info")


func test_epic_reads_legendary_and_heroic() -> void:
	var games := _by_id(Epic.scan(_home()))
	ok(not games.has("QuailDLC"), "DLC skipped")
	ok(not games.has("UEAsset"), "Unreal marketplace asset skipped")
	eq(games.size(), 4, "Celeste, Alan Wake 2, Rocket League, Winey")
	var celeste: Dictionary = games.get("Quail", {})
	eq(celeste.get("title"), "Celeste", "title from metadata")
	eq(celeste.get("installed"), true, "installed from installed.json")
	eq(celeste.get("source"), "legendary", "standalone legendary")
	eq(celeste.get("prefix"), "/prefixes/celeste", "per-game wine_prefix from config.ini")
	eq(celeste.get("ids", {}).get("epic", []).has("celeste"), true, "store slug is a candidate id")
	var owned: Dictionary = games.get("Owned1", {})
	eq(owned.get("installed"), false, "owned but not installed")
	eq(owned.get("prefix"), "/prefixes/default", "default wine_prefix")


func test_epic_heroic_art_prefix_and_playtime() -> void:
	var rl: Dictionary = _by_id(Epic.scan(_home())).get("Sugar", {})
	var root := _home() + "/.var/app/com.heroicgameslauncher.hgl/config/heroic"
	eq(rl.get("source"), "heroic", "from Heroic")
	eq(rl.get("heroic_flatpak"), true, "Flatpak Heroic")
	eq(rl.get("config_dir"), root + "/legendaryConfig/legendary", "Heroic's legendary folder")
	eq(rl.get("prefix"), _home() + "/Games/Heroic/Prefixes/default/Rocket League", "~ expanded in Heroic winePrefix")
	ok(str(rl.get("proton_path")).ends_with("/tools/proton/GE-Proton10-25"), "Heroic's Proton reused")
	eq(rl.get("playtime_min"), 754, "Heroic totalPlayed")
	eq(rl.get("last_played"), int(Time.get_unix_time_from_datetime_string("2026-11-01T20:30:00")), "Heroic lastPlayed")
	var tall := "https://cdn1.epicgames.com/offer/ns/Tall.jpg?h=400&resize=1&w=300"
	eq(rl["art"]["cover"], root + "/images-cache/" + tall.sha256_text(), "cover from Heroic image cache")
	ok(rl["art"]["hero"] != "" and rl["art"]["logo"] != "", "hero and logo cached")
	eq(rl["art"]["icon"], "", "no icon")
	eq(_by_id(Epic.scan(_home()))["Winey"]["proton"], false, "Wine-type Heroic game")


func test_gog_reads_heroic() -> void:
	var games := _by_id(Gog.scan(_home()))
	ok(not games.has("1234567890"), "DLC skipped")
	ok(not games.has("gog-redist"), "redist skipped")
	eq(games.size(), 3, "Witcher, Stardew, Cyberpunk")
	var w: Dictionary = games.get("1207664663", {})
	eq(w.get("installed"), true, "Witcher installed")
	eq(w.get("platform"), "windows", "Windows build")
	eq(w.get("playtime_min"), 3000, "playtime")
	ok(str(w["art"]["cover"]).contains("/images-cache/"), "cover cached")
	eq(w.get("prefix"), _home() + "/Games/umu/gog-1207664663", "fallback prefix without GamesConfig")
	eq(games["1453375253"]["platform"], "linux", "native Linux build")
	eq(games["1495134320"]["installed"], false, "owned only")


func test_gog_primary_task_like_gogdl() -> void:
	var dir := fixture("library/games/witcher3")
	var t := Gog.primary_task(dir, "1207664663")
	eq(t.get("exe"), dir + "/bin/x64/witcher3.exe", "primary task path, backslashes fixed")
	eq(t.get("cwd"), dir + "/bin/x64", "working dir")
	eq(t.get("args"), ["-skipLauncher", "-lang", "en US"], "arguments shell-split")


func test_amazon_reads_nile_once() -> void:
	var list := Amazon.scan(_home())
	var games := _by_id(list)
	eq(list.size(), 2, "Heroic copy wins over the duplicate in ~/.config/nile")
	var f: Dictionary = games.get("amzn1.adg.product.aaaa-1111", {})
	eq(f.get("installed"), true, "installed")
	eq(f.get("install_path"), "/home/deck/Games/nile/Fallout 3", "path from installed.json")
	eq(f.get("ids"), {"steam": "22370"}, "Steam id from Amazon's websites")
	eq(games["amzn1.adg.product.bbbb-2222"]["installed"], false, "owned only")


func test_steam_playtime_and_art() -> void:
	var games := _by_id(Steam.scan(_home()))
	ok(not games.has("2805730"), "Proton is not a game")
	var halo: Dictionary = games.get("976730", {})
	eq(halo.get("playtime_min"), 1234, "Playtime minutes")
	eq(halo.get("last_played"), 1762000000, "LastPlayed")
	var cache := _home() + "/.local/share/Steam/appcache/librarycache"
	eq(halo["art"], {"cover": cache + "/976730_library_600x900.jpg", "hero": cache + "/976730_library_hero.jpg",
		"logo": cache + "/976730_logo.png", "icon": cache + "/976730_icon.jpg"}, "old flat layout")
	var hades: Dictionary = games.get("1145360", {})
	eq(hades.get("playtime_min"), 90, "highest playtime across users")
	eq(hades.get("last_played"), 1760000000, "latest LastPlayed across users")
	ok(str(hades["art"]["cover"]).ends_with("/userdata/12345678/config/grid/1145360p.png"), "custom grid art first")
	eq(hades["art"]["hero"], cache + "/1145360/library_hero.jpg", "new per-app folder")
	eq(hades["art"]["logo"], cache + "/1145360/logo.png", "new logo")
	eq(hades["art"]["icon"], cache + "/1145360/0123456789abcdef0123456789abcdef01234567.jpg", "hashed icon")


func test_vdf_parser() -> void:
	var d := Steam.parse_vdf("\"A\"\n{\n\t\"Key\"\t\t\"va\\\"lue\"\n\t\"Sub\" { \"x\" \"1\" }\n}")
	eq(d, {"a": {"key": "va\"lue", "sub": {"x": "1"}}}, "nested, lowercased keys, escapes")


func test_shell_helpers() -> void:
	eq(Common.shell_split("a 'b c' \"d \\\"e\\\"\" f\\ g"), ["a", "b c", "d \"e\"", "f g"], "shlex-like split")
	eq(Common.shell_quote("/usr/bin/umu-run"), "/usr/bin/umu-run", "plain path unquoted")
	eq(Common.shell_quote("/opt/my tools/umu-run"), "'/opt/my tools/umu-run'", "spaces quoted")
