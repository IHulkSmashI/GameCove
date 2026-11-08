extends "res://tests/test_case.gd"
## Game database parsing and matching, and the merged library from fixtures.

const GameDB := preload("res://scripts/library/gamedb.gd")
const LibraryScript := preload("res://scripts/library/library.gd")


func _index() -> Dictionary:
	return GameDB.build_index(GameDB.load_file(fixture("library/gamedb.json.gz")))


func test_parse_fixture_and_bad_input() -> void:
	var doc := GameDB.load_file(fixture("library/gamedb.json.gz"))
	eq(doc.get("games", []).size(), 6, "games read from gzip")
	eq(GameDB.parse_gz(PackedByteArray()), {}, "empty bytes")
	eq(GameDB.parse_gz("not gzip at all, just text".to_utf8_buffer()), {}, "garbage")
	eq(GameDB.parse_gz("[1,2]".to_utf8_buffer().compress(FileAccess.COMPRESSION_GZIP)), {}, "not a document")
	eq(GameDB.load_file("/nonexistent/gamedb.json.gz"), {}, "no cache")
	eq(GameDB.find(GameDB.build_index({}), {"steam": "1"}, "Hades"), {}, "empty index finds nothing")


func test_normalise() -> void:
	eq(GameDB.normalise("DOOM™ Eternal®"), "doometernal", "trademarks and case")
	eq(GameDB.normalise("The Witcher 3: Wild Hunt – Game of the Year Edition"),
		GameDB.normalise("The Witcher 3 Wild Hunt - Game Of The Year Edition"), "punctuation and dashes")
	eq(GameDB.normalise("Pokémon"), "pokémon", "letters with accents kept")


func test_id_beats_title() -> void:
	var idx := GameDB.build_index({"games": [
		{"title": "Stardew Valley", "ids": {}},
		{"title": "SDV (renamed)", "ids": {"gog": "1453375253"}, "released": 2016},
	]})
	eq(GameDB.find(idx, {"gog": "1453375253"}, "Stardew Valley").get("title"), "SDV (renamed)", "gog id wins")
	eq(GameDB.find(idx, {"gog": "999"}, "Stardew Valley™").get("title"), "Stardew Valley", "title fallback")
	var real := _index()
	eq(GameDB.find(real, {"epic": ["Quail", "celeste"]}, "x").get("wikidata"), "Q2", "epic slug candidate")
	eq(GameDB.find(real, {}, "Alan Wake 2™").get("wikidata"), "Q1", "title without ™")


func test_info_fills_missing_keys_as_null() -> void:
	eq(GameDB.info_for({}), {"released": null, "time_to_beat": null, "anticheat": null, "protondb": null}, "empty record")
	var halo := GameDB.info_for(GameDB.find(_index(), {"steam": "976730"}, ""))
	eq(halo["released"], 2014, "year as int")
	eq(halo["protondb"], "platinum", "protondb tier")
	eq(halo["time_to_beat"], {"main_h": 10.0, "extra_h": null, "complete_h": null, "count": 17, "source": "igdb"}, "omitted hours are null")
	var rl := GameDB.info_for(GameDB.find(_index(), {}, "Rocket League®"))
	eq(rl["anticheat"], {"status": "works", "anticheats": []}, "omitted anticheat list is empty")
	eq(GameDB.info_for({"protondb": "excellent"})["protondb"], null, "unknown tier ignored")


func test_stale_once_a_day() -> void:
	ok(GameDB.is_stale(0, 1000), "no cache is stale")
	ok(not GameDB.is_stale(100000, 100000 + 3600), "an hour old is fresh")
	ok(GameDB.is_stale(100000, 100000 + 86400), "a day old is stale")


func test_collect_merges_all_stores() -> void:
	var r := LibraryScript.collect(fixture("library/home"), fixture("library/gamedb.json.gz"))
	var games: Array[Dictionary] = r["games"]
	var keys := games.map(func(g): return g["key"])
	for k in ["steam:976730", "steam:1145360", "epic:Quail", "epic:Sugar", "gog:1207664663", "gog:1453375253",
			"amazon:amzn1.adg.product.aaaa-1111"]:
		ok(k in keys, "has " + k)
	eq(keys.size(), 11, "2 Steam + 4 Epic + 3 GOG + 2 Amazon, no duplicates")
	var titles := games.map(func(g): return g["title"])
	var sorted := titles.duplicate()
	sorted.sort_custom(func(a, b): return a.naturalnocasecmp_to(b) < 0)
	eq(titles, sorted, "sorted by title")
	for g in games:
		eq(g.keys(), ["key", "store", "id", "title", "installed", "art", "info", "last_played", "playtime_min"], g["key"] + " has exactly the contract keys")
		eq(g["art"].keys(), ["cover", "hero", "logo", "icon"], g["key"] + " art keys")
	var e: Dictionary = r["entries"]
	eq(e["steam:976730"]["info"]["protondb"], "platinum", "steam matched by id")
	eq(e["gog:1207664663"]["info"]["released"], 2016, "gog matched by id")
	eq(e["gog:1207664663"]["umu_id"], "umu-292030", "umu GAMEID from the matched Steam id")
	eq(e["amazon:amzn1.adg.product.aaaa-1111"]["info"]["protondb"], "gold", "amazon matched via Steam link")
	eq(e["epic:Quail"]["info"]["released"], 2018, "epic matched by slug")
	ok(not e["steam:976730"].has("umu_id"), "Steam games launch through Steam")


func test_collect_without_anything() -> void:
	var r := LibraryScript.collect("/nonexistent/home", "/nonexistent/gamedb.json.gz")
	eq(r["games"].size(), 0, "no stores, no database -> empty library")
