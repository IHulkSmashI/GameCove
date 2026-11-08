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


func _tmp_cache() -> String:
	var dir := OS.get_cache_dir().path_join("gamecove-test-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join("gamedb.json.gz")


func test_good_download_is_parsed_once_and_handed_on() -> void:
	var path := _tmp_cache()
	var good := FileAccess.get_file_as_bytes(fixture("library/gamedb.json.gz"))
	var f := FileAccess.open(path + ".part", FileAccess.WRITE)
	f.store_buffer(good)
	f.close()
	var db: Node = GameDB.new()
	db.cache_path = path
	var fired := [0]
	db.updated.connect(func(): fired[0] += 1)
	db._on_downloaded(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), PackedByteArray())
	eq(fired[0], 1, "updated emitted")
	ok(FileAccess.file_exists(path) and not FileAccess.file_exists(path + ".part"), "part renamed to the cache")
	var h: Dictionary = GameDB._handoff
	eq(h.get("path"), path, "parsed document waits for the library scan")
	var first := GameDB.load_file(path)
	ok(is_same(first, h.get("doc")), "library gets the already parsed document")
	eq(first.get("games", []).size(), 6, "and it's the right one")
	eq(GameDB._handoff, {}, "hand-off used up")
	var second := GameDB.load_file(path)
	ok(not is_same(second, first) and second == first, "later loads read the file again")
	db.free()
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(path.get_base_dir())


func test_bad_or_missing_download_keeps_old_copy() -> void:
	var path := _tmp_cache()
	var old := FileAccess.get_file_as_bytes(fixture("library/gamedb.json.gz"))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(old)
	f.close()
	var db: Node = GameDB.new()
	db.cache_path = path
	var fired := [0]
	db.updated.connect(func(): fired[0] += 1)
	# 404: GitHub's error page lands in the .part file
	f = FileAccess.open(path + ".part", FileAccess.WRITE)
	f.store_string("Not Found")
	f.close()
	db._on_downloaded(HTTPRequest.RESULT_SUCCESS, 404, PackedStringArray(), PackedByteArray())
	ok(not FileAccess.file_exists(path + ".part"), "404 part deleted")
	# offline
	db._on_downloaded(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray())
	# 200 but junk
	f = FileAccess.open(path + ".part", FileAccess.WRITE)
	f.store_string("<html>maintenance</html>")
	f.close()
	db._on_downloaded(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), PackedByteArray())
	ok(not FileAccess.file_exists(path + ".part"), "junk part deleted")
	eq(fired[0], 0, "nothing new, no signal")
	eq(FileAccess.get_file_as_bytes(path), old, "old copy untouched")
	eq(GameDB.load_file(path).get("games", []).size(), 6, "still works offline")
	db.free()
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(path.get_base_dir())


func test_unpack_cap_is_sane() -> void:
	ok(GameDB.MAX_UNPACKED <= 128 * 1024 * 1024, "a bad download can't take more than 128 MB")
