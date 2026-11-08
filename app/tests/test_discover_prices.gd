extends "res://tests/test_case.gd"
## Deal dicts, merging one game's prices across stores, and link rules.

const H := preload("res://tests/fixtures/discover/helpers.gd")
const CheapShark := preload("res://scripts/discover/cheapshark.gd")
const SteamApi := preload("res://scripts/discover/steam_api.gd")
const Prices := preload("res://scripts/discover/prices.gd")
const DiscoverScript := preload("res://scripts/discover/discover.gd")

const FX := {"base": "EUR", "rates": {"USD": 1.1165, "CAD": 1.5705}}


func _ctx(wishlist := {}) -> Dictionary:
	return {"currency": "CAD", "steam_currency": "CAD", "fx": FX, "wishlist": wishlist}


func _stores() -> Dictionary:
	return CheapShark.parse_stores(FileAccess.get_file_as_bytes(H.fx("cs_stores.json")))


func _steam() -> Dictionary:
	return SteamApi.parse_items(FileAccess.get_file_as_bytes(H.fx("steam_items_ca.json")))


func _lookup() -> Dictionary:
	return CheapShark.parse_lookup(FileAccess.get_file_as_bytes(H.fx("cs_multi.json")))


const KEYS := ["key", "source", "store", "store_name", "store_icon", "title", "appid", "game_id", "price",
	"regular_price", "currency", "price_text", "regular_text", "price_user", "regular_user", "user_currency",
	"converted", "price_user_text", "savings_pct", "on_sale", "is_historical_low", "historical_low",
	"sale_ends_at", "rating", "art", "link", "on_wishlist", "wishlist_key"]


func _has_all_keys(d: Dictionary, what: String) -> void:
	for k in KEYS:
		ok(d.has(k), "%s has %s" % [what, k])


func test_cheapshark_deal_shape_and_redirect() -> void:
	var offers: Array = CheapShark.parse_deals(FileAccess.get_file_as_bytes(H.fx("cs_deals.json")))
	var d := Prices.from_cheapshark(offers[1], _stores(), _ctx())
	_has_all_keys(d, "cheapshark deal")
	eq(d["store_name"], "GreenManGaming", "store name")
	eq(d["store"], "cs:3", "store id")
	eq(d["currency"], "USD", "CheapShark is USD")
	eq(d["converted"], true, "converted to CAD")
	ok(d["price_user_text"].begins_with("~C$"), "estimate label")
	eq(d["link"], {"kind": "url", "uri": "https://www.cheapshark.com/redirect?dealID=" + offers[1]["deal_id"]}, "CheapShark redirect")
	eq(d["sale_ends_at"], null, "CheapShark has no sale end")
	eq(d["is_historical_low"], false, "unknown low")
	ok(d["art"]["cover"].ends_with("/2482760/library_600x900.jpg"), "Steam cover by appid")


func test_cheapshark_steam_row_uses_regional_price_but_keeps_redirect() -> void:
	var offers: Array = CheapShark.parse_deals(FileAccess.get_file_as_bytes(H.fx("cs_deals.json")))
	var civ_offer: Dictionary = offers[6]
	var low = _lookup()["126"]["historical_low"]
	var d := Prices.from_cheapshark(civ_offer, _stores(), _ctx({"steam:3900": {}}), low, _steam()["3900"])
	eq([d["price"], d["currency"], d["price_text"]], [4.39, "CAD", "C$ 4.39"], "Steam's CAD price")
	eq(d["converted"], false, "no conversion needed")
	eq(d["sale_ends_at"], 1795111200, "sale end from Steam")
	ok(d["link"]["uri"].begins_with("https://www.cheapshark.com/redirect?dealID="), "still CheapShark's link")
	eq(d["on_wishlist"], true, "on wishlist")
	eq(d["is_historical_low"], false, "3.99 USD is above the 1.99 low")
	ok(d["art"]["cover"].contains("store_item_assets/steam/apps/3900/"), "art from Steam data")


func test_prices_for_merges_stores_cheapest_first() -> void:
	var lookup: Dictionary = _lookup()["88304"]
	var list := Prices.prices_for(lookup, _steam()["49520"], _stores(), _ctx())
	eq(list.size(), 10, "Steam's own row replaces CheapShark's Steam row")
	var steam_rows := list.filter(func(x): return x["store"] == "steam")
	eq(steam_rows.size(), 1, "one Steam row")
	eq(steam_rows[0]["source"], "steam", "from Steam data")
	eq(steam_rows[0]["link"], {"kind": "steam", "uri": "steam://store/49520"}, "opens in the Steam client")
	eq(steam_rows[0]["price"], 2.19, "CAD price")
	eq(steam_rows[0]["is_historical_low"], true, "Steam USD 1.99 equals the low")
	eq(list[0]["store"], "steam", "C$2.19 beats ~C$4.07 (2.89 USD)")
	for i in range(1, list.size()):
		ok(list[i - 1]["price_user"] <= list[i]["price_user"], "sorted by price in CAD")
	for x in list.slice(1):
		ok(x["link"]["uri"].begins_with("https://www.cheapshark.com/redirect?dealID="), "others via redirect")
	eq(Prices.best(list), list[0], "best is first")
	eq(Prices.best([]), {}, "no prices")


func test_prices_without_rates_put_unconvertible_last() -> void:
	var lookup: Dictionary = _lookup()["126"]
	var ctx := {"currency": "CAD", "steam_currency": "CAD", "fx": {}, "wishlist": {}}
	var list := Prices.prices_for(lookup, _steam()["3900"], _stores(), ctx)
	eq(list[0]["source"], "steam", "the only comparable price leads")
	eq(list[0]["price_user"], 4.39, "CAD as is")
	eq(list[1]["price_user"], null, "USD can't convert without rates")
	eq(list[1]["converted"], false, "not marked converted")


func test_prices_for_game_without_steam() -> void:
	var lookup: Dictionary = _lookup()["126"]
	var list := Prices.prices_for(lookup, null, _stores(), _ctx())
	eq(list[0]["store"], "cs:21", "cheapest USD store")
	ok(list.any(func(x): return x["store"] == "steam" and x["source"] == "cheapshark"), "CheapShark Steam row kept")
	eq(list.filter(func(x): return x["is_historical_low"]).size(), 0, "2.78 is above the 1.99 low")


func test_link_commands() -> void:
	eq(DiscoverScript.link_command({"kind": "steam", "uri": "steam://store/10"}, "/usr/bin/steam"),
		["/usr/bin/steam", "steam://store/10"], "Steam link to the client")
	eq(DiscoverScript.link_command({"kind": "url", "uri": "https://www.cheapshark.com/redirect?dealID=a%3D"}, "/usr/bin/steam"),
		["/usr/bin/steam", "steam://openurl/https://www.cheapshark.com/redirect?dealID=a%3D"], "web link in Steam's browser")
	eq(DiscoverScript.link_command({"kind": "url", "uri": "https://x.org/"}, ""), ["xdg-open", "https://x.org/"], "no Steam")
	eq(DiscoverScript.link_command({"kind": "url", "uri": "file:///etc/passwd"}, "s"), [], "only https and steam")
	eq(DiscoverScript.link_command({}, "s"), [], "nothing to open")
