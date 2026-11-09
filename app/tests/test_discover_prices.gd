extends "res://tests/test_case.gd"
## Deal dicts, merging one game's prices across stores, link rules, and the
## rule that only real local prices are ever shown (no estimates).

const H := preload("res://tests/fixtures/discover/helpers.gd")
const CheapShark := preload("res://scripts/discover/cheapshark.gd")
const SteamApi := preload("res://scripts/discover/steam_api.gd")
const Prices := preload("res://scripts/discover/prices.gd")
const DiscoverScript := preload("res://scripts/discover/discover.gd")

const CA := {"country": "CA", "currency": "CAD", "wishlist": {}}
const US := {"country": "US", "currency": "USD", "wishlist": {}}
const KEYS := ["key", "source", "store", "store_name", "store_icon", "title", "appid", "game_id", "price",
	"see_price", "savings_pct", "on_sale", "is_historical_low", "historical_low", "sale_ends_at", "rating",
	"art", "link", "on_wishlist", "wishlist_key"]
const PRICE_KEYS := ["amount", "regular", "currency", "country", "source", "is_local", "text", "regular_text"]


func _stores() -> Dictionary:
	return CheapShark.parse_stores(FileAccess.get_file_as_bytes(H.fx("cs_stores.json")))


func _steam() -> Dictionary:
	return SteamApi.parse_items(FileAccess.get_file_as_bytes(H.fx("steam_items_ca.json")))


func _lookup() -> Dictionary:
	return CheapShark.parse_lookup(FileAccess.get_file_as_bytes(H.fx("cs_multi.json")))


func _offers() -> Array:
	return CheapShark.parse_deals(FileAccess.get_file_as_bytes(H.fx("cs_deals.json")))


func _shape(d: Dictionary, what: String) -> void:
	for k in KEYS:
		ok(d.has(k), "%s has %s" % [what, k])
	if d["price"] != null:
		for k in PRICE_KEYS:
			ok(d["price"].has(k), "%s price has %s" % [what, k])
		eq(d["price"]["is_local"], true, what + ": displayed numbers are always local")
	for gone in ["price_user", "converted", "price_user_text", "regular_user"]:
		ok(not d.has(gone), "%s has no %s" % [what, gone])


func test_non_steam_store_outside_us_is_see_price() -> void:
	var d := Prices.from_cheapshark(_offers()[1], _stores(), CA)
	_shape(d, "GMG deal in Canada")
	eq(d["store_name"], "GreenManGaming", "store name")
	eq(d["price"], null, "no CAD price exists for GMG: no number")
	eq(d["see_price"], true, "See price")
	ok(d["savings_pct"] > 0, "discount percentage still shown")
	eq(d["link"], {"kind": "url", "uri": "https://www.cheapshark.com/redirect?dealID=" + _offers()[1]["deal_id"],
		"affiliate": false, "note": ""}, "opens CheapShark's redirect, never an affiliate link")
	eq([d["historical_low"], d["is_historical_low"]], [null, false], "USD low not shown in Canada")


func test_us_gets_cheapshark_prices_as_local() -> void:
	var low = _lookup()["126"]["historical_low"]
	var d := Prices.from_cheapshark(_offers()[6], _stores(), US, low)
	_shape(d, "Steam deal via CheapShark in the US")
	eq(d["price"]["amount"], 3.99, "US price")
	eq([d["price"]["currency"], d["price"]["country"], d["price"]["source"]], ["USD", "US", "cheapshark"], "local block")
	eq(d["historical_low"], {"amount": 1.99, "currency": "USD", "date": 1688061001}, "low in the user's currency")
	eq(d["is_historical_low"], false, "3.99 is above 1.99")


func test_cheapshark_steam_row_uses_steam_price_for_canada_and_keeps_redirect() -> void:
	var d := Prices.from_cheapshark(_offers()[6], _stores(), {"country": "CA", "currency": "CAD", "wishlist": {"steam:3900": {}}},
		_lookup()["126"]["historical_low"], _steam()["3900"])
	eq(d["price"], {"amount": 4.39, "regular": 21.99, "currency": "CAD", "country": "CA", "source": "steam",
		"is_local": true, "text": "C$ 4.39", "regular_text": "C$ 21.99"}, "Steam's own Canadian price")
	eq(d["sale_ends_at"], 1795111200, "sale end from Steam")
	ok(d["link"]["uri"].begins_with("https://www.cheapshark.com/redirect?dealID="), "still CheapShark's link")
	eq(d["on_wishlist"], true, "on wishlist")
	eq(d["historical_low"], null, "no CAD historical low source")


func test_prices_for_canada_local_rows_first_then_see_price() -> void:
	var list := Prices.prices_for(_lookup()["88304"], _steam()["49520"], _stores(), CA)
	eq(list.size(), 10, "Steam's own row replaces CheapShark's Steam row")
	eq(list[0]["source"], "steam", "the only local price leads")
	eq(list[0]["link"], {"kind": "steam", "uri": "steam://store/49520", "affiliate": false, "note": ""}, "opens in the Steam client")
	eq(list[0]["price"]["amount"], 2.19, "CAD price")
	for x in list.slice(1):
		eq(x["price"], null, "%s: no estimated number" % x["store_name"])
		ok(x["link"]["uri"].begins_with("https://www.cheapshark.com/redirect?dealID="), "See price opens the redirect")
	for i in range(2, list.size()):
		ok(list[i - 1]["savings_pct"] >= list[i]["savings_pct"], "See-price rows by discount")
	eq(Prices.best(list), list[0], "best is the cheapest local price")
	for x in list:
		_shape(x, x["store_name"])


func test_prices_for_us_sorted_by_price() -> void:
	var list := Prices.prices_for(_lookup()["126"], null, _stores(), US)
	eq(list[0]["store"], "cs:21", "cheapest US store")
	for i in range(1, list.size()):
		ok(list[i - 1]["price"]["amount"] <= list[i]["price"]["amount"], "cheapest first")


func test_best_is_empty_without_local_price() -> void:
	var list := Prices.prices_for(_lookup()["126"], null, _stores(), CA)
	ok(list.size() > 0 and list.all(func(x): return x["see_price"]), "only See-price rows")
	eq(Prices.best(list), {}, "no best deal to show a number for")
	eq(Prices.best([]), {}, "nothing")


func test_link_commands() -> void:
	eq(DiscoverScript.link_command({"kind": "steam", "uri": "steam://store/10"}, "/usr/bin/steam"),
		["/usr/bin/steam", "steam://store/10"], "Steam link to the client")
	eq(DiscoverScript.link_command({"kind": "url", "uri": "https://www.cheapshark.com/redirect?dealID=a%3D"}, "/usr/bin/steam"),
		["/usr/bin/steam", "steam://openurl/https://www.cheapshark.com/redirect?dealID=a%3D"], "web link in Steam's browser")
	eq(DiscoverScript.link_command({"kind": "url", "uri": "https://gg.deals/game/x/"}, ""), ["xdg-open", "https://gg.deals/game/x/"], "no Steam")
	eq(DiscoverScript.link_command({"kind": "url", "uri": "https://x.org/"}, "s"), [], "unknown host: not opened")
	eq(DiscoverScript.link_command({"kind": "url", "uri": "https://gg.deals.evil.com/"}, "s"), [], "look-alike host")
	eq(DiscoverScript.link_command({"kind": "url", "uri": "https://gg.deals@evil.com/"}, "s"), [], "userinfo trick")
	eq(DiscoverScript.link_command({"kind": "url", "uri": "https://eu.gg.deals/x"}, "s"), ["s", "steam://openurl/https://eu.gg.deals/x"], "gg.deals subdomain")
	eq(DiscoverScript.link_command({"kind": "steam", "uri": "steam://store/10/../uninstall/440"}, "s"), [], "Steam link with a bad id")
	eq(DiscoverScript.link_command({"kind": "steam", "uri": "steam://run/10"}, "s"), [], "only store pages")
	eq(DiscoverScript.link_command({"kind": "url", "uri": "steam://store/10"}, "s"), [], "a steam:// uri posing as a web link")
	eq(DiscoverScript.link_command({"kind": "url", "uri": "file:///etc/passwd"}, "s"), [], "only https and steam")
	eq(DiscoverScript.link_command({}, "s"), [], "nothing to open")


func test_untrusted_steam_ids_never_reach_a_uri() -> void:
	var AppId = load("res://scripts/steam/app_id.gd")
	ok(AppId.valid("620") and AppId.valid(620), "plain digits")
	for bad in ["", "0", "620/../uninstall/440", "620//-console", "+620", "-1", "6 20", "١٢", "12345678901", null, 1.5]:
		ok(not AppId.valid(bad), "rejected: %s" % var_to_str(bad))
	eq(load("res://scripts/discover/steam_api.gd").store_uri("1/../uninstall/2"), "", "no store uri for a bad id")
	var Cal = load("res://scripts/discover/calendar.gd")
	var r: Dictionary = Cal.make_release({"title": "Evil", "date": "2027", "precision": "year",
		"ids": {"steam": "1/../uninstall/2", "wikidata": "Q1"}}, 0)
	eq(r["link"].get("kind", ""), "url", "calendar: bad Steam id falls back to the Wikidata page")
	var Prices = load("res://scripts/discover/prices.gd")
	var ctx := {"currency": "USD", "country": "US"}
	eq(Prices.from_steam({"appid": "1/../x", "price": 9.99, "title": "X"}, ctx), {}, "Steam deal with a bad id dropped")
	eq(Prices.from_ggdeals("440", {"currency": "USD", "retail": 5.0, "url": "https://evil.example/x"}, ctx), {}, "GG.deals deal with a foreign URL dropped")
	eq(Prices.from_ggdeals("44/0", {"currency": "USD", "retail": 5.0, "url": "https://gg.deals/x"}, ctx), {}, "GG.deals deal with a bad id dropped")
	ok(not Prices.from_ggdeals("440", {"currency": "USD", "retail": 5.0, "url": "https://gg.deals/x"}, ctx).is_empty(), "a good GG.deals deal stays")
	eq(load("res://scripts/discover/cheapshark.gd").redirect_url("a\"><x"), "", "CheapShark deal id with odd characters: no link")
