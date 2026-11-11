extends "res://tests/test_case.gd"
## Steam achievements from crafted binary KeyValues fixtures
## (tests/fixtures/achievements/make_fixtures.py). No network: the rarity
## fetcher is a fake.

const BinaryKV := preload("res://scripts/achievements/binary_kv.gd")
const Steam := preload("res://scripts/achievements/steam_achievements.gd")
const AchievementsScript := preload("res://scripts/achievements/achievements.gd")


func _root() -> String:
	return fixture("achievements/steam")


func _scratch(test_name: String) -> String:
	var d := ProjectSettings.globalize_path("user://test_achievements/" + test_name)
	DirAccess.make_dir_recursive_absolute(d)
	var dir := DirAccess.open(d)
	for f in dir.get_files():
		DirAccess.remove_absolute(d + "/" + f)
	return d


func _by_id(result: Dictionary) -> Dictionary:
	var out := {}
	for it in result["items"]:
		out[it["id"]] = it
	return out


func test_binary_kv_every_type() -> void:
	var d := BinaryKV.parse_file(fixture("achievements/types.bin"))
	var r: Dictionary = d.get("root", {})
	eq(r.get("s"), "text", "string")
	eq(r.get("i"), -5, "int32")
	eq(r.get("f"), 1.5, "float32")
	eq(r.get("u"), 76561197960266729, "uint64")
	eq(r.get("w"), "wide", "UTF-16 wide string")
	eq(r["nested"]["deep"]["x"], 1, "nested maps")


func test_binary_kv_bad_input_gives_nothing() -> void:
	eq(BinaryKV.parse_file(fixture("achievements/truncated.bin")), {}, "truncated file")
	eq(BinaryKV.parse(PackedByteArray([0x09, 0x41, 0x00, 1, 2])), {}, "unknown type byte")
	eq(BinaryKV.parse(PackedByteArray()), {}, "empty")
	eq(BinaryKV.parse_file("/nonexistent/file.bin"), {}, "missing file")
	eq(BinaryKV.get_ci({"Hidden": "1"}, "hidden"), "1", "case-insensitive lookup")
	eq(BinaryKV.get_ci({"a": 1}, "b", 7), 7, "fallback")


func test_reads_unlocks_times_and_names() -> void:
	var r := Steam.read_game(_root(), "4242", Steam.recent_account(_root()))
	eq(r["total"], 4, "three in block 1, one in block 2; the plain stat is not an achievement")
	eq(r["unlocked"], 3, "bits 0 and 2 of block 1, bit 0 of block 2")
	eq(r["source"], "steam-local", "source")
	var a := _by_id(r)
	eq(a["ACH_START"]["name"], "First Steps", "English name")
	eq(a["ACH_START"]["description"], "Finish the tutorial", "description")
	eq(a["ACH_START"]["unlock_time"], 1700000000, "unlock time")
	ok(not a["ACH_BOSS"]["unlocked"], "bit 1 not set")
	eq(a["ACH_BOSS"]["unlock_time"], 0, "no time while locked")
	ok(a["ACH_SECRET"]["hidden"], "Hidden=1 (capital H)")
	eq(a["ACH_PLAIN"]["name"], "Plain Name", "display name may be a plain string")
	eq(a["ACH_PLAIN"]["unlock_time"], 1700001000, "second block's time")
	eq(r["items"][0]["id"], "ACH_START", "schema order")
	eq(a["ACH_START"]["rarity"], -1.0, "rarity unknown until fetched")


func test_account_choice() -> void:
	eq(Steam.recent_account(_root()), "1001", "MostRecent login's SteamID64 -> account id")
	var other := Steam.read_game(_root(), "4242", "2002")
	eq(other["unlocked"], 3, "another account's file when asked (bits 0-2 of block 1)")
	var scratch := _scratch("fallback") + "/appcache/stats"
	DirAccess.make_dir_recursive_absolute(scratch)
	for f in ["UserGameStatsSchema_4242.bin", "UserGameStats_2002_4242.bin"]:
		DirAccess.copy_absolute(_root() + "/appcache/stats/" + f, scratch + "/" + f)
	var root := scratch.get_base_dir().get_base_dir()
	ok(Steam.user_stats_path(root, "4242", "1001").ends_with("UserGameStats_2002_4242.bin"), "no file for the login: newest other file")


func test_language_and_icons() -> void:
	var r := Steam.read_game(_root(), "4242", "1001", "german")
	var a := _by_id(r)
	eq(a["ACH_START"]["name"], "First Steps (de)", "localized name")
	eq(a["ACH_START"]["description"], "Finish the tutorial", "English when the language is missing")
	ok(a["ACH_START"]["icon"].ends_with("librarycache/4242/" + "%040x.jpg" % 1), "cached icon in librarycache/<appid>/")
	ok(a["ACH_BOSS"]["icon"].ends_with("librarycache/4242/abc/" + "%040x.jpg" % 2), "or one folder down")
	eq(a["ACH_SECRET"]["icon"], "", "not cached: no local path")
	eq(a["ACH_SECRET"]["icon_url"], Steam.ICON_CDN % ["4242", "%040x.jpg" % 3], "CDN url always given")
	eq(a["ACH_PLAIN"]["icon_url"], "", "no icon, no url")
	eq(Steam.local_icon(_root() + "/appcache/librarycache/4242", "../x.jpg"), "", "no path tricks")


func test_missing_files_give_empty() -> void:
	var empty := {"appid": "999", "unlocked": 0, "total": 0, "items": [], "source": ""}
	eq(Steam.read_game(_root(), "999"), empty, "no schema for this game")
	eq(Steam.read_game("", "4242")["total"], 0, "no Steam")
	eq(Steam.read_game(_root(), "abc")["total"], 0, "not an app id")
	var scratch := _scratch("schema_only") + "/appcache/stats"
	DirAccess.make_dir_recursive_absolute(scratch)
	DirAccess.copy_absolute(_root() + "/appcache/stats/UserGameStatsSchema_4242.bin", scratch + "/UserGameStatsSchema_4242.bin")
	var locked := Steam.read_game(scratch.get_base_dir().get_base_dir(), "4242")
	eq(locked["total"], 4, "schema without stats: all listed")
	eq(locked["unlocked"], 0, "none unlocked")


func test_rarity_parse_and_merge() -> void:
	var pct := Steam.parse_rarity(FileAccess.get_file_as_string(fixture("achievements/rarity_4242.json")))
	eq(pct["ACH_START"], 91.5, "string percent (v0002)")
	eq(pct["ACH_SECRET"], 3.25, "number percent")
	eq(Steam.parse_rarity("<html>"), {}, "not JSON")
	eq(Steam.parse_rarity("{\"achievementpercentages\":{}}"), {}, "no list")
	var a := _by_id(Steam.read_game(_root(), "4242", "1001", "english", pct))
	eq(a["ACH_BOSS"]["rarity"], 40.2, "merged by API name")
	eq(a["ACH_PLAIN"]["rarity"], -1.0, "missing stays unknown")


func test_service_caches_and_fetches_rarity_once_a_day() -> void:
	var svc: Node = AchievementsScript.new()
	svc.steam_root = _root()
	svc.rarity_dir = _scratch("rarity")
	var urls := []
	svc.fetcher = func(url: String, appid: String): urls.append([url, appid])
	var changed := []
	svc.changed.connect(func(id): changed.append(id))
	var r: Dictionary = svc.achievements_for(4242)
	eq(r["unlocked"], 3, "local result at once")
	eq(urls.size(), 1, "rarity asked for")
	eq(urls[0][0], AchievementsScript.RARITY_URL % "4242", "Steam's public endpoint, no key")
	svc.achievements_for("4242")
	eq(urls.size(), 1, "in flight: not asked twice")
	svc.rarity_arrived("4242", FileAccess.get_file_as_string(fixture("achievements/rarity_4242.json")))
	eq(changed, ["4242"], "changed fires")
	var a := _by_id(svc.achievements_for("4242"))
	eq(a["ACH_START"]["rarity"], 91.5, "rarity in the result")
	eq(urls.size(), 1, "fetched today: not again")
	var now := int(Time.get_unix_time_from_system())
	ok(not svc.should_fetch("4242", 4, now + 3600), "an hour later: no")
	ok(svc.should_fetch("4242", 4, now + AchievementsScript.DAY_S + 1), "a day later: yes")
	ok(not svc.should_fetch("999", 0, now), "games without achievements never fetch")
	svc.fetch_rarity = false
	ok(not svc.should_fetch("4242", 4, now + AchievementsScript.DAY_S * 2), "switched off")
	svc.free()


func test_the_rarity_request_goes_through_the_gateway_capped_and_on_steams_host() -> void:
	var svc: Node = AchievementsScript.new()
	var fake := preload("res://scripts/discover/fake_http.gd").new()
	fake.route(AchievementsScript.RARITY_URL.get_slice("?", 0), {"text": FileAccess.get_file_as_string(fixture("achievements/rarity_4242.json"))})
	svc._http = fake
	var got := []
	svc.rarity_dir = _scratch("rarity_gw")
	svc.changed.connect(func(id): got.append(id))
	svc._http_fetch(AchievementsScript.RARITY_URL % "4242", "4242")
	eq(fake.options.size(), 1, "one request, through http.gd's interface")
	eq(fake.options[0].get("hosts", []), ["api.steampowered.com"], "names Steam's API host (redirects checked)")
	var cap: int = int(fake.options[0].get("max_bytes", 0))
	ok(cap > 0 and cap <= 4 * 1024 * 1024, "has a size cap")
	eq(got, ["4242"], "the body came back to rarity_arrived")


func test_failed_fetch_waits_a_day_too() -> void:
	var svc: Node = AchievementsScript.new()
	svc.steam_root = _root()
	svc.rarity_dir = _scratch("rarity_fail")
	var urls := []
	svc.fetcher = func(url: String, appid: String): urls.append(url)
	svc.achievements_for("4242")
	svc.rarity_arrived("4242", "")
	svc.achievements_for("4242")
	eq(urls.size(), 1, "one try per day even when it failed")
	eq(_by_id(svc.achievements_for("4242"))["ACH_START"]["rarity"], -1.0, "still unknown")
	var loaded := []
	svc.loaded.connect(func(id, res): loaded.append([id, res["total"]]))
	svc.request(4242)
	eq(loaded, [["4242", 4]], "request() answers through loaded")
	svc.free()
