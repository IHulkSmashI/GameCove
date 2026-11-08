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
	eq(SteamApi.parse_profile_xml(_bytes("steam_profile.xml").get_string_from_utf8()), "76561197960435530", "xml id")
	eq(SteamApi.parse_profile_xml(_bytes("steam_profile_missing.xml").get_string_from_utf8()), "", "missing profile")
	eq(SteamApi.parse_profile_input("76561197960435530"), {"steam_id": "76561197960435530"}, "raw id")
	eq(SteamApi.parse_profile_input("https://steamcommunity.com/profiles/76561197960435530/"), {"steam_id": "76561197960435530"}, "profile url")
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
