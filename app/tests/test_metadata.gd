extends "res://tests/test_case.gd"
## Game details: every source read into one shape, the merge order, the
## background resolver (with recorded Steam appdetails answers and synthetic
## OpenCritic answers; nothing touches the network) and its privacy gates.

const Metadata := preload("res://scripts/library/meta/metadata.gd")
const Resolver := preload("res://scripts/library/meta/resolver.gd")
const OpenCritic := preload("res://scripts/library/meta/opencritic.gd")
const Privacy := preload("res://scripts/system/privacy.gd")
const FakeHttp := preload("res://scripts/discover/fake_http.gd")
const STEAM := "https://store.steampowered.com/api/appdetails"


func fx(name: String) -> String:
	return fixture("metadata/" + name)


static func tmp(name: String) -> String:
	var d := ProjectSettings.globalize_path("user://tests/meta_%s_%d" % [name, randi()])
	DirAccess.make_dir_recursive_absolute(d)
	return d


static func wipe(dir: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for sub in d.get_directories():
		wipe(dir.path_join(sub))
	for f in d.get_files():
		d.remove(f)
	DirAccess.remove_absolute(dir)


func test_steam_appdetails_layer() -> void:
	var l := Metadata.steam_layer("1145360", FileAccess.get_file_as_bytes(fx("appdetails_1145360.json")))
	eq(l["source"], "steam", "source")
	eq(l["critics"]["metacritic"], {"score": 93, "url": "https://www.metacritic.com/game/pc/hades"}, "Metacritic, tracking query dropped")
	var m: Dictionary = l["meta"]
	eq(m["genres"], ["Action", "Indie", "RPG"], "genres")
	eq(m["developers"], ["Supergiant Games"], "developer")
	eq(m["release_date"], "2020-09-17", "date")
	eq(m["controller"], "full", "controller")
	ok(m["summary"].begins_with("Defy the god of the dead"), "summary")
	ok(m["screenshots"].size() > 0 and m["screenshots"][0]["thumb"].begins_with("https://"), "screenshots")
	eq(Metadata.steam_layer("999999999", FileAccess.get_file_as_bytes(fx("appdetails_missing.json"))), {}, "no such app")
	eq(Metadata.steam_layer("1", "<html>".to_utf8_buffer()), {}, "junk")


func test_cleaning() -> void:
	eq(Metadata.steam_date("3 Aug, 2023"), "2023-08-03", "day month")
	eq(Metadata.steam_date("Sep 17, 2020"), "2020-09-17", "month day")
	eq(Metadata.steam_date("Q4 2026"), "", "vague date")
	eq(Metadata.clean_text("<b>Fast</b> &amp; fun"), "Fast & fun", "tags and entities")
	eq(Metadata.clean_metacritic({"score": 80, "url": "https://evil.example/metacritic.com"}), {"score": 80, "url": ""}, "foreign URL dropped")
	eq(Metadata.clean_metacritic({"score": 0}), null, "no score")
	eq(Metadata.clean_screens(["http://x.steamstatic.com/a.jpg", "https://evil.example/a.jpg", "https://cdn.akamai.steamstatic.com/a.jpg"]),
		[{"thumb": "https://cdn.akamai.steamstatic.com/a.jpg", "full": "https://cdn.akamai.steamstatic.com/a.jpg"}], "screens: https on known hosts only")
	eq(Metadata.metacritic_band(75), "good", "75 green")
	eq(Metadata.metacritic_band(74), "mixed", "74 yellow")
	eq(Metadata.metacritic_band(49), "bad", "49 red")


func test_local_store_layers() -> void:
	var epic := Metadata.local_layer("epic", {"metadata": {"description": "From Epic.", "developer": "Studio E"}})
	eq(epic["meta"], {"summary": "From Epic.", "developers": ["Studio E"]}, "Epic")
	var gog := Metadata.local_layer("gog", {"developer": "CD PROJEKT RED", "extra": {"about": {"shortDescription": "From GOG."},
		"genres": ["Role-playing"], "releaseDate": "2015-05-19T00:00:00+0300"}})
	eq(gog["meta"]["summary"], "From GOG.", "GOG summary")
	eq(gog["meta"]["genres"], ["Role-playing"], "GOG genres")
	eq(gog["meta"]["release_date"], "2015-05-19", "GOG date")
	var amz := Metadata.local_layer("amazon", {"product": {"productDetail": {"details": {"shortDescription": "From Amazon.",
		"developer": "Dev A", "publisher": "Pub A", "genres": ["Action"]}}}})
	eq(amz["meta"]["publishers"], ["Pub A"], "Amazon publisher")


## local -> database Steam -> live Steam -> IGDB -> Wikidata; each field from the first that has it.
func test_merge_order() -> void:
	var local := Metadata.layer("store", {"summary": "Store words."})
	var db := Metadata.gamedb_layers({
		"meta": {"steam": {"genres": ["Action"], "at": "2026-11-01"},
			"igdb": {"summary": "IGDB words.", "genres": ["Role-playing (RPG)"], "themes": ["Fantasy"], "developers": ["Dev I"]},
			"wikidata": {"publishers": ["Pub W"], "developers": ["Dev W"]}},
		"critics": {"metacritic": {"score": 88, "url": "https://www.metacritic.com/game/x"}, "igdb_critic": {"score": 85, "count": 12}}})
	var live := Metadata.layer("steam", {"developers": ["Dev S"], "screens": [{"thumb": "https://shared.akamai.steamstatic.com/t.jpg", "full": "https://shared.akamai.steamstatic.com/f.jpg"}]},
		{"metacritic": {"score": 90, "url": "https://www.metacritic.com/game/x"}})
	var oc := Metadata.layer("opencritic", {}, {"opencritic": {"score": 91, "percent_recommended": 97, "tier": "Mighty", "url": "https://opencritic.com/game/1/x", "count": 80}})
	var m := Metadata.merge(Metadata.ordered(local, db, live, oc), "42")
	eq(m["summary"], "Store words.", "store first")
	eq(m["genres"], ["Action"], "database Steam before IGDB")
	eq(m["developers"], ["Dev S"], "live Steam before IGDB and Wikidata")
	eq(m["themes"], ["Fantasy"], "IGDB fills what Steam lacks")
	eq(m["publishers"], ["Pub W"], "Wikidata last")
	eq(m["critics"]["metacritic"]["score"], 88, "database Metacritic before the live copy")
	eq(m["critics"]["igdb_critic"], {"score": 85, "count": 12}, "IGDB critic average")
	eq(m["critics"]["opencritic"]["tier"], "Mighty", "OpenCritic")
	eq(m["sources"]["summary"], "store", "source recorded")
	eq(m["sources"]["themes"], "igdb", "source recorded")
	eq(m["steam_twin"], "42", "twin")
	eq(Metadata.critic_score(m), 88, "sort score: Metacritic first")
	var names: Array = Metadata.credits(m).map(func(c): return c["text"])
	ok("Metacritic" in names and "Critic scores from OpenCritic" in names and "Game data from IGDB" in names and "Wikidata (CC0)" in names, "credits: %s" % [names])


func test_opencritic_parsing() -> void:
	eq(OpenCritic.pick(FileAccess.get_file_as_bytes(fx("opencritic_search.json")), "HADES"), 9136, "exact title, not Hades II")
	eq(OpenCritic.pick(FileAccess.get_file_as_bytes(fx("opencritic_search.json")), "Hades III"), 0, "no fuzzy guess")
	eq(OpenCritic.parse_game(FileAccess.get_file_as_bytes(fx("opencritic_game.json"))),
		{"score": 93, "percent_recommended": 98, "tier": "Mighty", "url": "https://opencritic.com/game/9136/hades", "count": 120}, "game record")
	eq(OpenCritic.parse_game(FileAccess.get_file_as_bytes(fx("opencritic_unscored.json"))), null, "-1 = no score yet")
	ok(OpenCritic.valid_key("") and not OpenCritic.valid_key("short") and OpenCritic.valid_key("a".repeat(50)), "key check")
	eq(OpenCritic.quota_left({"day": "2026-11-09", "searches": 20, "requests": 3}, "2026-11-09")["searches"], 0, "quota used")
	eq(OpenCritic.quota_left({"day": "2026-11-08", "searches": 20}, "2026-11-09")["searches"], OpenCritic.DAILY_SEARCHES, "new day")


func _resolver(http: Variant, dir: String, prefs: String) -> Node:
	var r: Node = Resolver.new()
	r.http = http
	r.cache_dir = dir
	r.prefs_path = prefs
	r.sync_mode = true
	r.clock = func() -> int: return 1_800_000_000
	return r


func _game(store: String, id: String, twin := "", title := "Hades") -> Dictionary:
	var meta := Metadata.empty()
	meta["steam_twin"] = twin
	return {"key": "%s:%s" % [store, id], "store": store, "id": id, "title": title, "info": {"meta": meta}}


func test_resolver_fetches_caches_and_merges() -> void:
	var dir := tmp("res")
	var prefs := dir.path_join("settings.cfg")
	var http := FakeHttp.new()
	http.route(STEAM, {"file": fx("appdetails_1145360.json")})
	var r := _resolver(http, dir, prefs)
	var got := []
	r.resolved.connect(func(k): got.append(k))
	# a GOG game whose database record names Steam app 1145360
	eq(r.queue_games([_game("gog", "1207664663", "1145360")]), 1, "queued")
	eq(got, ["gog:1207664663"], "resolved")
	eq(http.requests, [Resolver.STEAM_URL + "1145360"], "the Steam twin's details")
	var m := Resolver.assemble({"local": {}, "db": []}, "1145360", "Hades", dir)
	eq(m["critics"]["metacritic"]["score"], 93, "Metacritic from the twin")
	eq(m["genres"], ["Action", "Indie", "RPG"], "genres")
	# cached for a week: nothing asked again
	eq(r.queue_games([_game("gog", "1207664663", "1145360")]), 0, "fresh cache")
	r.clock = func() -> int: return 1_800_000_000 + 8 * 86400
	eq(r.jobs_for(_game("gog", "1207664663", "1145360")).size(), 1, "stale after a week")
	# a complete game wants nothing; one without a Steam id or twin can't be fetched from Steam
	var full := _game("steam", "1145360")
	full["info"]["meta"] = m
	eq(r.jobs_for(full), [], "nothing missing")
	eq(r.jobs_for(_game("epic", "abc")), [], "no Steam twin, no OpenCritic key: nothing to ask")
	r.free()
	wipe(dir)


## Review 2, low 11: a captive portal's HTTP 200 page was cached as "no such app" for a week.
func test_junk_200_is_not_cached_as_missing() -> void:
	var dir := tmp("junk")
	var prefs := dir.path_join("settings.cfg")
	var http := FakeHttp.new()
	http.route(STEAM, {"text": "<html>Sign in to the hotel Wi-Fi</html>"})
	var r := _resolver(http, dir, prefs)
	r.queue_games([_game("gog", "1", "1145360")])
	ok(not FileAccess.file_exists(Resolver.steam_cache_path(dir, "1145360")), "nothing cached")
	eq(r.jobs_for(_game("gog", "1", "1145360")).size(), 1, "asked again next time")
	ok(Metadata.steam_says_missing("9", '{"9":{"success":false}}'.to_utf8_buffer()), "Steam's own no-such-app answer")
	ok(not Metadata.steam_says_missing("9", "<html>".to_utf8_buffer()), "not a portal page")
	r.free()
	wipe(dir)


func test_resolver_privacy_gates() -> void:
	var dir := tmp("gate")
	var prefs := dir.path_join("settings.cfg")
	var http := FakeHttp.new()
	http.route(STEAM, {"file": fx("appdetails_1145360.json")})
	var r := _resolver(http, dir, prefs)
	Privacy.set_background_allowed(false, prefs)
	eq(r.queue_games([_game("steam", "1145360")]), 0, "no background fill with Background lookups off")
	eq(r.request(_game("steam", "1145360")), 1, "the page you open still asks")
	eq(http.requests.size(), 1, "one request")
	Privacy.set_metadata_allowed(false, prefs)
	r.clock = func() -> int: return 1_800_000_000 + 30 * 86400
	eq(r.request(_game("steam", "1145360")), 0, "nothing at all with Look up game details off")
	eq(http.requests.size(), 1, "still one request")
	r.free()
	wipe(dir)


func test_resolver_opencritic_with_own_key_and_quota() -> void:
	var dir := tmp("oc")
	var prefs := dir.path_join("settings.cfg")
	var http := FakeHttp.new()
	http.route(OpenCritic.BASE + "search", {"file": fx("opencritic_search.json")})
	http.route(OpenCritic.BASE + "9136", {"file": fx("opencritic_game.json")})
	var r := _resolver(http, dir, prefs)
	var g := _game("epic", "abc", "", "Hades")
	eq(r.jobs_for(g), [], "no key: OpenCritic is never asked")
	ok(not Resolver.set_opencritic_key("bad key", prefs), "bad key refused")
	ok(Resolver.set_opencritic_key("k".repeat(50), prefs), "key saved")
	r.request(g)
	eq(http.requests, [OpenCritic.search_url("Hades"), OpenCritic.game_url(9136)], "search once, then the game")
	ok(str(http.options[0]["headers"]).contains("X-RapidAPI-Key"), "the user's key goes in RapidAPI's header")
	var m := Resolver.assemble({}, "", "Hades", dir)
	eq(m["critics"]["opencritic"]["score"], 93, "score cached")
	eq(m["critics"]["opencritic"]["percent_recommended"], 98, "% recommended")
	eq(r.quota()["searches"], OpenCritic.DAILY_SEARCHES - 1, "quota counted")
	# a 429 blocks OpenCritic for the rest of the day
	http.route(OpenCritic.BASE + "search", {"error": "http 429", "code": 429})
	r.request(_game("epic", "z", "", "Other Game"))
	ok(r.quota()["blocked"], "blocked after 429")
	var before := http.requests.size()
	r.request(_game("epic", "y", "", "Third Game"))
	eq(http.requests.size(), before, "no more requests today")
	r.free()
	wipe(dir)
