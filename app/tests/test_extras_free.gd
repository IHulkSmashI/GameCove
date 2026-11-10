extends "res://tests/test_case.gd"
## The Free to keep shelf in Discover: CheapShark's sales at 0 (fake http),
## under the "Look up deals and prices" switch, opened through CheapShark's link.

const CheapShark := preload("res://scripts/discover/cheapshark.gd")
const Model := preload("res://scripts/ui/discover/model.gd")
const H := preload("res://tests/fixtures/discover/helpers.gd")
const TD := preload("res://scripts/ui/texts_discover.gd")


func test_free_url_asks_for_giveaways_only() -> void:
	var u := CheapShark.free_url()
	ok(u.begins_with("https://www.cheapshark.com/api/1.0/deals?") and u.contains("upperPrice=0") and u.contains("onSale=1"), "on sale at 0: free to keep, not free to play")


const FREE_JSON := '[{"dealID":"free%2B1","storeID":"25","gameID":"1","steamAppID":"821250","title":"Flotsam","salePrice":"0.00","normalPrice":"24.99","savings":"100.000000","dealRating":"9.0","thumb":"","releaseDate":0},' \
	+ '{"dealID":"f2p","storeID":"1","gameID":"2","steamAppID":"440","title":"Always Free","salePrice":"0.00","normalPrice":"0.00","savings":"0","dealRating":"0","thumb":"","releaseDate":0}]'


func test_discover_fetches_the_free_list_under_the_deals_switch() -> void:
	var dir := H.temp_dir("disc_free")
	var http = H.online_http()
	http.route(CheapShark.free_url(), {"text": FREE_JSON})
	var d := H.make(http, dir)
	ok(d.refresh(), "refresh")
	eq(http.count(CheapShark.free_url()), 1, "one request per refresh")
	eq(d.free_deals.size(), 1, "an always-free game isn't a giveaway")
	eq(d.free_deals[0]["title"], "Flotsam", "Flotsam")
	eq(d.free_deals[0]["link"]["uri"], CheapShark.REDIRECT + "free%2B1", "opened through CheapShark's link to the store (its terms)")
	var shelf := Model.free_to_keep(d.deals, d.free_deals)
	eq(shelf.filter(func(x): return x["title"] == "Flotsam").size(), 1, "each game once, even when the top deals list it too")
	# the switch off: no request at all
	d.set_settings({"price_lookups": false})
	http.requests.clear()
	d.refresh(true)
	eq(http.count(CheapShark.free_url()), 0, "Look up deals and prices off: nothing asked")
	d.free()
	H.wipe(dir)


func test_free_shelf_name() -> void:
	eq(TD.SHELF_FREE, "Free to keep", "says what it is")


func test_a_giveaway_reads_free_in_any_currency() -> void:
	var Prices = load("res://scripts/discover/prices.gd")
	var o := {"deal_id": "x", "store_id": "25", "game_id": "1", "appid": "", "title": "Flotsam", "price": 0.0, "regular_price": 24.99, "savings_pct": 100}
	var d: Dictionary = Prices.from_cheapshark(o, {"25": {"name": "Epic Games Store"}}, {"country": "CA", "currency": "CAD"})
	ok(d["price"] != null and float(d["price"]["amount"]) == 0.0, "a price of 0 even outside the US")
	ok(Model.is_free(d), "shows as Free, not See price")
	var paid := o.duplicate()
	paid["price"] = 4.99
	ok(Prices.from_cheapshark(paid, {}, {"country": "CA", "currency": "CAD"})["price"] == null, "a paid deal outside the US still says See price")
