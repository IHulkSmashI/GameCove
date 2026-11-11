extends "res://tests/test_case.gd"
## Parsing every Discover source from real responses captured 2026-11-08.

const H := preload("res://tests/fixtures/discover/helpers.gd")
const CheapShark := preload("res://scripts/discover/cheapshark.gd")
const SteamApi := preload("res://scripts/discover/steam_api.gd")
const Money := preload("res://scripts/discover/money.gd")
const Http := preload("res://scripts/discover/http.gd")


func _bytes(rel: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(H.fx(rel))


func test_cheapshark_deals() -> void:
	var deals: Array = CheapShark.parse_deals(_bytes("cs_deals.json"))
	eq(deals.size(), 8, "all deals read")
	var f: Dictionary = deals[0]
	eq(f["title"], "Flotsam", "title")
	eq(f["appid"], "821250", "steam appid")
	eq(f["store_id"], "25", "store")
	eq([f["price"], f["regular_price"], f["savings_pct"]], [0.0, 24.99, 100], "a free giveaway: 100% off")
	eq(deals[6]["savings_pct"], 80, "savings rounded to int")
	eq(deals[2]["appid"], "", "null steamAppID becomes empty")
	eq(deals[6]["store_id"], "1", "steam row")
	eq(CheapShark.parse_deals("<html>blocked</html>".to_utf8_buffer()), null, "garbage")
	eq(CheapShark.parse_deals("[]".to_utf8_buffer()), [], "empty list")


## Final review (Low): CheapShark sends null for what it doesn't know. int(null)
## was a script error inside the parser, which stopped the request's callback
## and left the Discover refresh waiting for ever.
func test_cheapshark_null_fields_never_stop_the_parser() -> void:
	var deals: Variant = CheapShark.parse_deals(('[{"dealID":"a1","storeID":null,"gameID":null,"steamAppID":null,"title":null,'
		+ '"salePrice":null,"normalPrice":null,"savings":null,"dealRating":null,"thumb":null,"releaseDate":null},'
		+ '{"dealID":null,"title":"no id"},{"dealID":"b2","title":"Fine","salePrice":"1.50","normalPrice":"3.00","savings":"50.0",'
		+ '"releaseDate":{"odd":1},"thumb":["x"],"storeID":7}]').to_utf8_buffer())
	ok(deals is Array, "still a list")
	eq(deals.size(), 2, "the entry without an id is left out, the others stay")
	eq([deals[0]["deal_id"], deals[0]["store_id"], deals[0]["title"], deals[0]["thumb"], deals[0]["released"], deals[0]["price"], deals[0]["rating"]],
		["a1", "", "", "", 0, 0.0, null], "nulls read as empty, never as \"<null>\"")
	eq([deals[1]["released"], deals[1]["thumb"], deals[1]["store_id"], deals[1]["price"]], [0, "", "7", 1.5], "odd types too")
	var stores := CheapShark.parse_stores('[{"storeID":"1","storeName":null,"isActive":null,"images":null},{"storeID":null},{"storeID":2,"storeName":"B","isActive":1,"images":{"icon":null}}]'.to_utf8_buffer())
	eq(stores, {"1": {"name": "", "active": false, "icon": ""}, "2": {"name": "B", "active": true, "icon": ""}}, "stores with nulls")
	var found: Variant = CheapShark.parse_search('[{"gameID":"5","steamAppID":null,"external":null,"cheapest":null,"cheapestDealID":null,"thumb":null},{"gameID":null}]'.to_utf8_buffer())
	eq(found, [{"game_id": "5", "appid": "", "title": "", "cheapest": 0.0, "cheapest_deal_id": "", "thumb": ""}] as Array[Dictionary], "search with nulls")
	var look := CheapShark.parse_lookup('{"7":{"info":{"title":null,"steamAppID":null,"thumb":null},"cheapestPriceEver":{"price":null,"date":null},"deals":null},"8":{"info":null,"cheapestPriceEver":null,"deals":[null,{"dealID":null},{"dealID":"d","storeID":null,"price":null,"retailPrice":null,"savings":null}]}}'.to_utf8_buffer())
	eq(look["7"], {"game_id": "7", "appid": "", "title": "", "thumb": "", "historical_low": {"price": 0.0, "currency": "USD", "date": 0}, "offers": [] as Array[Dictionary]}, "a lookup whose deals are null")
	eq(look["8"]["offers"].size(), 1, "null entries in the list are skipped")
	eq(look["8"]["offers"][0]["store_id"], "", "and a null store reads as empty")
	# Steam's own answers get the same care
	var SteamApi = load("res://scripts/discover/steam_api.gd")
	var items: Dictionary = SteamApi.parse_items('{"response":{"store_items":[{"success":1,"appid":10,"name":null,"is_free":null,"assets":null,"release":{"steam_release_date":null,"is_coming_soon":null},"best_purchase_option":{"final_price_in_cents":"999","original_price_in_cents":null,"discount_pct":null,"active_discounts":null,"formatted_final_price":null}},{"success":null,"appid":11}]}}'.to_utf8_buffer())
	eq(items.keys(), ["10"], "an item full of nulls still parses; one without success is left out")
	eq([items["10"]["price"], items["10"]["regular_price"], items["10"]["savings_pct"], items["10"]["title"], items["10"]["free"]], [9.99, 9.99, 0, "", false], "with what it does know")
	eq(SteamApi.parse_items('{"response":{"store_items":null}}'.to_utf8_buffer()), {}, "no item list")
	eq(SteamApi.parse_wishlist('{"response":{"items":[{"appid":20,"priority":null,"date_added":null},{"appid":null},null]}}'.to_utf8_buffer()),
		[{"appid": "20", "priority": 0, "added": 0}] as Array[Dictionary], "a wishlist with nulls")
	eq(SteamApi.parse_wishlist('{"response":{"items":null}}'.to_utf8_buffer()), [] as Array[Dictionary], "a null wishlist is an empty one")


func test_cheapshark_stores_search_lookup() -> void:
	var stores := CheapShark.parse_stores(_bytes("cs_stores.json"))
	eq(stores["1"]["name"], "Steam", "store name")
	eq(stores["1"]["icon"], "https://www.cheapshark.com/img/stores/icons/0.png", "icon is absolute")
	ok(stores.has("4") and not stores["4"]["active"], "inactive store flagged")
	var found: Array = CheapShark.parse_search(_bytes("cs_search.json"))
	eq(found[0]["title"], "Hades", "search title")
	eq(found[0]["game_id"], "196149", "game id")
	eq(found[0]["appid"], "1145360", "appid")
	eq(found[2]["appid"], "", "no appid")
	var multi := CheapShark.parse_lookup(_bytes("cs_multi.json"))
	eq(multi.keys().size(), 2, "two games")
	eq(multi["88304"]["historical_low"], {"price": 1.99, "currency": "USD", "date": 1793651134}, "historical low")
	eq(multi["88304"]["offers"].size(), 10, "every store's offer")
	eq(multi["126"]["offers"][1]["store_id"], "1", "steam offer")
	var single := CheapShark.parse_lookup(_bytes("cs_game_88304.json"), "88304")
	eq(single["88304"]["appid"], "49520", "single lookup")
	eq(CheapShark.parse_lookup("nope".to_utf8_buffer()), {}, "garbage lookup")


func test_cheapshark_urls_and_redirect() -> void:
	var id := "y9vH5Xf2O3lmQzX8IprLnYJ8PT7C2MafD4gPIMz7y%2Fs%3D"
	eq(CheapShark.redirect_url(id), "https://www.cheapshark.com/redirect?dealID=" + id, "redirect keeps the encoded id")
	ok(CheapShark.search_url("half life 2").contains("title=half%20life%202"), "title encoded")
	eq(CheapShark.lookup_url(range(30)).count(","), 24, "lookup capped at 25 ids")
	ok(CheapShark.deals_url(500).ends_with("pageSize=60"), "page size capped")


func test_steam_items_regional_prices_and_art() -> void:
	var info := SteamApi.parse_items(_bytes("steam_items_ca.json"))
	eq(info.keys().size(), 3, "unknown app left out")
	var civ: Dictionary = info["3900"]
	eq(civ["price"], 4.39, "final price")
	eq(civ["regular_price"], 21.99, "original price")
	eq(civ["savings_pct"], 80, "discount")
	eq(civ["price_text"], "C$ 4.39", "Steam's own label")
	eq(civ["sale_ends_at"], 1795111200, "sale end")
	eq(civ["release"]["released"], true, "released")
	var hades: Dictionary = info["1145360"]
	eq(hades["price"], 32.5, "full price")
	eq(hades["savings_pct"], 0, "no discount")
	eq(hades["sale_ends_at"], null, "no sale end")
	ok(hades["art"]["cover"].begins_with("https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/1145360/library_600x900.jpg"), "cover from assets")
	ok(hades["art"].has("hero") and hades["art"].has("header"), "hero and header")
	eq(SteamApi.parse_items("{}".to_utf8_buffer()), {}, "empty answer")


func test_steam_release_states() -> void:
	var r := SteamApi.release_from({"steam_release_date": 1798704000, "coming_soon_display": "date_quarter"}, true)
	eq(r, {"released": false, "date": "2026-Q4", "precision": "quarter"}, "quarter")
	r = SteamApi.release_from({"is_coming_soon": true, "coming_soon_display": "text_tba"}, false)
	eq(r, {"released": false, "date": "", "precision": "tba"}, "tba")
	r = SteamApi.release_from({"steam_release_date": 1796025600, "coming_soon_display": "date_month"}, true)
	eq(r["date"], "2026-11", "month")
	r = SteamApi.release_from(null, false)
	eq(r["released"], true, "no block, not coming soon")


func test_steam_art_hashed_paths_and_fallback() -> void:
	var art := SteamApi.art_from_assets({"asset_url_format": "steam/apps/7/${FILENAME}?t=1", "library_capsule": "abc/library_capsule.jpg"})
	eq(art, {"cover": "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/7/abc/library_capsule.jpg?t=1"}, "hashed path kept")
	eq(SteamApi.art_from_assets(null), {}, "no assets")
	eq(SteamApi.fallback_art("10")["logo"], "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/10/logo.png", "plain pattern")


func test_steam_wishlist_and_profile() -> void:
	var rows: Array = SteamApi.parse_wishlist(_bytes("steam_wishlist.json"))
	eq(rows.size(), 3, "rows")
	eq(rows[0], {"appid": "49520", "priority": 1, "added": 1700000000}, "row shape")
	eq(SteamApi.parse_wishlist(_bytes("steam_wishlist_private.json")), [], "private wishlist is empty")
	eq(SteamApi.parse_wishlist("<html>".to_utf8_buffer()), null, "garbage")
	eq(SteamApi.parse_profile_xml(_bytes("steam_profile.xml").get_string_from_utf8()), "76561197972611406", "xml id")
	eq(SteamApi.parse_profile_xml(_bytes("steam_profile_missing.xml").get_string_from_utf8()), "", "missing profile")
	eq(SteamApi.parse_profile_input("76561197972611406"), {"steam_id": "76561197972611406"}, "raw id")
	eq(SteamApi.parse_profile_input("https://steamcommunity.com/profiles/76561197972611406/"), {"steam_id": "76561197972611406"}, "profile url")
	eq(SteamApi.parse_profile_input("https://steamcommunity.com/id/robinwalker"), {"vanity": "robinwalker"}, "vanity url")
	eq(SteamApi.parse_profile_input(" robinwalker "), {"vanity": "robinwalker"}, "bare name")
	eq(SteamApi.parse_profile_input("not a name!"), {}, "junk")
	ok(SteamApi.items_url(["1", 2], "ca").contains("%22country_code%22%3A%22CA%22"), "country in request")
	ok(not SteamApi.items_url(["1"], "CA").contains("key="), "no key")


func test_money_labels_only() -> void:
	eq(Money.format(4.5, "CAD"), "C$4.50", "two decimals")
	eq(Money.format(1200, "JPY"), "¥1200", "no decimals")
	eq(Money.format(null, "USD"), "", "no amount")
	eq(Money.currency_for_country("ca"), "CAD", "Canada")
	eq(Money.currency_for_country("AR"), "USD", "unlisted -> USD")
	ok(not Money.new().has_method("convert"), "no conversion exists")


func test_http_classify_and_user_agent() -> void:
	var r := Http.classify(HTTPRequest.RESULT_SUCCESS, 429, PackedStringArray(["Retry-After: 120"]))
	eq([r["ok"], r["error"], r["retry_after"]], [false, "http 429", 120], "429 with Retry-After")
	r = Http.classify(HTTPRequest.RESULT_CANT_RESOLVE, 0, PackedStringArray())
	eq(r["error"], "offline", "no DNS = offline")
	r = Http.classify(HTTPRequest.RESULT_TIMEOUT, 0, PackedStringArray())
	eq(r["error"], "timeout", "timeout")
	ok(Http.classify(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray())["ok"], "200 ok")
	ok(Http.user_agent().begins_with("GameCove/") and Http.user_agent().ends_with("(+https://github.com/IHulkSmashI/GameCove)"), "user agent")
	eq(Http.host_of("https://www.cheapshark.com/api/1.0/deals"), "www.cheapshark.com", "host")


# ---- final review (Low): hosts are checked on every redirect hop, nothing is uncapped -----------------

## http.gd with its next request recorded instead of started.
class RecHttp extends "res://scripts/discover/http.gd":
	var started: Array = []
	func _start(url: String, opts: Dictionary, done: Callable) -> void:
		started.append([url, opts])
		_opts_of[done] = opts
		_active += 1


func test_http_checks_the_host_on_every_redirect_hop() -> void:
	var HttpScript := load("res://scripts/discover/http.gd")
	var hosts := ["steamstatic.com", "images.igdb.com"]
	for good in ["https://steamstatic.com/a.jpg", "https://shared.akamai.steamstatic.com/x/a.jpg", "https://images.igdb.com/igdb/a.jpg",
			"https://cdn.steamstatic.com:443/a.jpg"]:
		ok(HttpScript.host_allowed(good, hosts), "allowed: " + good)
	for bad in ["http://steamstatic.com/a.jpg", "https://steamstatic.com.evil.example/a.jpg", "https://evilsteamstatic.com/a.jpg",
			"https://evil.example/steamstatic.com/a.jpg", "https://steamstatic.com@evil.example/a.jpg", "https://evil.example?x=.steamstatic.com",
			"https://evil.example#.steamstatic.com", "https://steamstatic.com:8443/a.jpg", "https://igdb.com/a.jpg", "ftp://steamstatic.com/a", ""]:
		ok(not HttpScript.host_allowed(bad, hosts), "refused: " + bad)
	# the first address
	var h = RecHttp.new()
	var got := []
	var done := func(res: Dictionary) -> void: got.append(res)
	h.request("https://evil.example/a.jpg", {"hosts": hosts}, done)
	eq([got.size(), got[0]["error"], h.started.size()], [1, "redirect", 0], "an address off the list is never asked")
	# a redirect to an allowed host is followed (by hand), one to any other host stops
	got.clear()
	h.request("https://cdn.steamstatic.com/a.jpg", {"hosts": hosts, "download_file": "/nonexistent/x.part"}, done)
	eq(h.started.size(), 1, "started")
	var req := HTTPRequest.new()
	req.max_redirects = 0
	h._on_done(HTTPRequest.RESULT_SUCCESS, 302, PackedStringArray(["Location: https://images.igdb.com/b.jpg"]), PackedByteArray(), req, "https://cdn.steamstatic.com/a.jpg", done)
	eq([h.started.size(), got.size()], [2, 0], "a hop to an allowed host is followed")
	eq(h.started[1][0], "https://images.igdb.com/b.jpg", "to where it points")
	eq(h.started[1][1].get("hosts"), hosts, "under the same rule")
	var req2 := HTTPRequest.new()
	req2.max_redirects = 0
	h._on_done(HTTPRequest.RESULT_SUCCESS, 301, PackedStringArray(["Location: https://evil.example/c.jpg"]), PackedByteArray(), req2, "https://images.igdb.com/b.jpg", done)
	eq(h.started.size(), 2, "a hop off the list is not followed")
	eq([got.size(), got[0]["ok"], got[0]["error"]], [1, false, "redirect"], "the request fails with \"redirect\"")
	var req3 := HTTPRequest.new()
	req3.max_redirects = 0
	got.clear()
	h.request("https://cdn.steamstatic.com/a.jpg", {"hosts": hosts}, done)
	h._on_done(HTTPRequest.RESULT_SUCCESS, 302, PackedStringArray(["Location: http://cdn.steamstatic.com/a.jpg"]), PackedByteArray(), req3, "https://cdn.steamstatic.com/a.jpg", done)
	eq(got[0]["error"], "redirect", "a downgrade to http is refused too")
	h.free()
	var src := FileAccess.get_file_as_string("res://scripts/discover/http.gd")
	ok("opts.get(\"hosts\", []) as Array).is_empty():\n\t\treq.max_redirects = 0" in src, "a request with hosts never lets HTTPRequest follow redirects itself")
	# caps: nothing goes out uncapped
	eq(HttpScript.cap_for({}), HttpScript.DEFAULT_MAX_BYTES, "an answer kept in memory: default cap")
	eq(HttpScript.cap_for({"download_file": "/x"}), HttpScript.DEFAULT_MAX_DOWNLOAD, "a download: its own default")
	eq(HttpScript.cap_for({"max_bytes": 1000, "download_file": "/x"}), 1000, "the caller's cap wins")
	eq(HttpScript.cap_for({"max_bytes": 0}), HttpScript.DEFAULT_MAX_BYTES, "0 no longer means no cap")
	ok("req.body_size_limit = cap_for(opts)" in src, "and every HTTPRequest gets one")


## Pictures: the callers that trust only certain hosts say so to http.gd.
func test_picture_downloads_name_their_hosts() -> void:
	var FakeHttp := load("res://scripts/discover/fake_http.gd")
	var ArtScript := load("res://scripts/discover/art.gd")
	var http = FakeHttp.new()
	var png := Image.create_empty(4, 4, false, Image.FORMAT_RGBA8).save_png_to_buffer()
	http.route("https://shared.akamai.steamstatic.com/", {"bytes": png})
	var a: Node = ArtScript.new()
	a.http = http
	a.cache_dir = "user://tests/art_hosts_%d" % randi()
	var out := []
	a._download("steam:10", "cover", "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/10/library_600x900.jpg", func(p): out.append(p))
	eq(http.options.size(), 1, "asked")
	eq(http.options[0].get("hosts"), ArtScript.IMAGE_HOSTS, "Discover art: IMAGE_HOSTS on every hop")
	eq(http.options[0].get("max_bytes"), ArtScript.MAX_FILE_BYTES, "and capped while it downloads, not only checked after")
	ok(out.size() == 1 and out[0] != "", "the picture was kept")
	for f in DirAccess.get_files_at(ProjectSettings.globalize_path(a.cache_dir)):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(a.cache_dir).path_join(f))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(a.cache_dir))
	a.free()
	for f in ["res://scripts/library/meta/resolver.gd", "res://scripts/library/art/art_service.gd", "res://scripts/device/photo.gd"]:
		var text := FileAccess.get_file_as_string(f)
		for line in text.split("\n"):
			if "http.request(" in line and "download_file" in line:
				ok("\"hosts\":" in line and "\"max_bytes\":" in line, "%s: a download names its hosts and its cap (%s)" % [f.get_file(), line.strip_edges().substr(0, 60)])
	# review 9 L8: every curl these two files run has a size cap (curl stops at it)
	for f in ["res://scripts/system/updates.gd", "res://scripts/launch/proton_ge.gd"]:
		var lines := FileAccess.get_file_as_string(f).split("\n")
		for i in lines.size():
			if "\"curl\"" in lines[i] and ("runner.run(" in lines[i] or "_low(" in lines[i]):
				ok("max-filesize" in lines[i] or "max-filesize" in lines[mini(i + 1, lines.size() - 1)], "%s:%d: a curl call names --max-filesize" % [f.get_file(), i + 1])
	var gamedb := FileAccess.get_file_as_string("res://scripts/library/gamedb.gd")
	ok("\"max_bytes\": MAX_PACKED" in gamedb and "\"hosts\": HOSTS" in gamedb and not "HTTPRequest.new()" in gamedb, "the game database download goes through http.gd, capped and on GitHub's hosts")


# ---- review L32: credentials stay with their host ------------------------------------------------

func test_http_drops_auth_on_cross_host_redirects() -> void:
	var HttpScript := load("res://scripts/discover/http.gd")
	var hs := ["User-Agent: x", "Authorization: Bearer KEY"]
	ok(HttpScript.has_auth(hs) and not HttpScript.has_auth(["Accept: */*"]), "credentialed requests are spotted")
	eq(HttpScript.redirect_headers(hs, "https://www.steamgriddb.com/api/v2/grids/1", "https://www.steamgriddb.com/api/v2/grids/2"), hs, "same host: kept")
	eq(HttpScript.redirect_headers(hs, "https://www.steamgriddb.com/api/v2/x", "https://cdn2.steamgriddb.com/file/a.png"), ["User-Agent: x"], "another host: dropped")
	eq(HttpScript.redirect_headers(hs, "https://www.steamgriddb.com/a", "http://www.steamgriddb.com/a"), ["User-Agent: x"], "downgrade to http: dropped")
	eq(HttpScript.location_of(PackedStringArray(["Location: /api/v2/y"]), "https://www.steamgriddb.com/api/v2/x"), "https://www.steamgriddb.com/api/v2/y", "relative Location")
	eq(HttpScript.location_of(PackedStringArray(["location: https://cdn.example/a.png"]), "https://a.example/"), "https://cdn.example/a.png")
	eq(HttpScript.location_of(PackedStringArray(["Content-Type: x"]), "https://a.example/"), "", "no Location")
	var src := FileAccess.get_file_as_string("res://scripts/discover/http.gd")
	ok("req.max_redirects = 0" in src and "redirect_headers(" in src, "credentialed requests follow redirects by hand")
