extends "res://tests/test_case.gd"
## GG.deals (optional, user's own key) and affiliate links.

const H := preload("res://tests/fixtures/discover/helpers.gd")
const GG := preload("res://scripts/discover/ggdeals.gd")
const Affiliates := preload("res://scripts/discover/affiliates.gd")
const Prices := preload("res://scripts/discover/prices.gd")
const GG_API := "https://api.gg.deals/v1/prices/by-steam-app-id/"
const CA := {"country": "CA", "currency": "CAD", "wishlist": {}, "keyshops": false}


func _gg() -> Dictionary:
	return GG.parse(FileAccess.get_file_as_bytes(H.fx("ggdeals_ca.json")))


func test_parse_and_regions() -> void:
	var g := _gg()
	eq(g.keys().size(), 3, "unknown id (null) left out")
	eq(g["49520"], {"title": "Borderlands 2", "url": "https://gg.deals/game/borderlands-2/?ref=gamecove-test", "currency": "CAD",
		"retail": 1.98, "retail_low": 1.98, "keyshop": 1.5, "keyshop_low": 0.99}, "entry")
	eq(g["3900"]["keyshop"], null, "no keyshop price")
	eq(GG.parse(FileAccess.get_file_as_bytes(H.fx("ggdeals_429.json"))), null, "rate-limit answer")
	eq(GG.parse("<html>".to_utf8_buffer()), null, "garbage")
	eq([GG.region_for("CA"), GG.region_for("AT"), GG.region_for("JP")], ["ca", "eu", ""], "regions")
	var url := GG.prices_url(range(150), "ca", "k e y")
	eq(url.get_slice("ids=", 1).get_slice("&", 0).split(",").size(), 100, "max 100 ids")
	ok(url.ends_with("&region=ca&key=k%20e%20y"), "region and key")


func test_gg_rows_local_attributed_and_unchanged_links() -> void:
	var r := Prices.from_ggdeals("49520", _gg()["49520"], CA)
	eq(r["price"]["amount"], 1.98, "best official-store price")
	eq([r["price"]["currency"], r["price"]["source"], r["price"]["is_local"]], ["CAD", "ggdeals", true], "local")
	eq(r["link"], {"kind": "url", "uri": "https://gg.deals/game/borderlands-2/?ref=gamecove-test", "affiliate": false, "note": ""}, "GG.deals URL unchanged")
	eq(r["attribution"], {"text": "Prices by GG.deals", "url": "https://gg.deals/"}, "attribution on the row")
	eq([r["is_historical_low"], r["historical_low"]["amount"]], [true, 1.98], "historical low")
	eq(Prices.from_ggdeals("49520", _gg()["49520"], {"country": "US", "currency": "USD"}), {}, "other currency: not shown")
	var k := Prices.from_ggdeals("49520", _gg()["49520"], CA, true)
	eq([k["keyshop"], k["price"]["amount"]], [true, 1.5], "keyshop row")
	ok(k["keyshop_note"].contains("grey market"), "explained")


func test_prices_for_with_gg_and_keyshop_setting() -> void:
	var list := Prices.prices_for({}, null, {}, CA, _gg()["2482760"], "2482760")
	eq(list.size(), 1, "retail only by default")
	eq(list[0]["store"], "ggdeals", "GG.deals row")
	var ks := CA.duplicate()
	ks["keyshops"] = true
	list = Prices.prices_for({}, null, {}, ks, _gg()["2482760"], "2482760")
	eq(list.map(func(x): return x["store"]), ["ggdeals-keyshops", "ggdeals"], "keyshop row when turned on, cheapest first")


func test_discover_uses_gg_with_user_key_only() -> void:
	var dir := H.temp_dir("disc_gg")
	var http = H.online_http()
	http.route(GG_API, {"file": H.fx("ggdeals_ca.json")})
	var d := H.make(http, dir)
	d.add_to_wishlist({"title": "Borderlands 2", "appid": "49520"})
	d.refresh(true)
	eq(http.count(GG_API), 0, "no key: GG.deals never called")
	eq(d.attributions().size(), 1, "only CheapShark credited")
	d.set_settings({"ggdeals_key": "user-key"})
	d.refresh(true)
	eq(http.count(GG_API), 1, "one batched request")
	ok(http.requests.any(func(u): return u.begins_with(GG_API) and u.contains("region=ca") and u.contains("key=user-key")), "region and user's key")
	eq(d.status.get("ggdeals"), "ok", "status")
	var item: Dictionary = d.wishlist[0]
	eq(item["best_deal"]["source"], "ggdeals", "C$1.98 via GG.deals beats Steam's C$2.19")
	eq(item["historical_low"], {"amount": 1.98, "currency": "CAD", "date": 0}, "CAD historical low")
	var gmg: Dictionary = d.deals[1]
	eq(gmg["price"], null, "the GMG row itself still has no number")
	eq(gmg["ggdeals"]["price"]["amount"], 31.49, "but carries GG.deals' best local price")
	eq(gmg["ggdeals"]["keyshop"], null, "keyshop off by default")
	ok(d.attributions().has(GG.ATTRIBUTION), "GG.deals credited")
	d.refresh(true)
	eq(http.count(GG_API), 1, "cached for 6 h")
	d.clock = func() -> int: return H.now() + 6 * 3600 + 5
	d.refresh(true)
	eq(http.count(GG_API), 2, "fetched again after 6 h")
	d.free()
	H.wipe(dir)


func test_gg_rate_limit_and_bad_key() -> void:
	var dir := H.temp_dir("disc_gg429")
	var http = H.online_http()
	http.route(GG_API, {"file": H.fx("ggdeals_429.json"), "code": 429})
	var d := H.make(http, dir)
	d.set_settings({"ggdeals_key": "k"})
	d.refresh(true)
	eq(d.status.get("ggdeals"), "rate_limited", "429")
	http.route(GG_API, {"error": "http 401", "code": 401})
	d.refresh(true)
	eq(d.status.get("ggdeals"), "error: key not accepted", "bad key")
	d.set_settings({"country": "JP"})
	var n: int = http.count(GG_API)
	d.refresh(true)
	eq(http.count(GG_API), n, "no GG.deals region for Japan: not called")
	d.free()
	H.wipe(dir)


func test_affiliate_links() -> void:
	var cfg := {"epic": {"template": "https://example.org/aff?u={url_encoded}&id={id}", "id": "gc"}, "humble": {"template": "", "id": ""}}
	var url := "https://store.epicgames.com/p/some-game"
	eq(Affiliates.link("epic", url, cfg, true), {"kind": "url", "uri": "https://example.org/aff?u=" + url.uri_encode() + "&id=gc",
		"affiliate": true, "note": "Supports GameCove"}, "affiliate link with note")
	eq(Affiliates.link("epic", url, cfg, false)["uri"], url, "setting off")
	eq(Affiliates.link("humble", url, cfg, true)["affiliate"], false, "no id: plain")
	for never in ["steam", "cheapshark", "ggdeals"]:
		var c := {never: {"template": "https://x.org/{url}", "id": "1"}}
		eq(Affiliates.link(never, url, c, true)["affiliate"], false, never + " is never touched")
	var shipped := Affiliates.load_file()
	ok(shipped.has("epic") and shipped.values().all(func(s): return s["id"] == ""), "shipped file is empty")


func test_calendar_epic_link_gets_affiliate_only_when_configured() -> void:
	var dir := H.temp_dir("disc_aff")
	var http = H.FakeHttp.new()
	var doc := {"schema": 1, "releases": [{"title": "Epic Only", "date": "2026-12-01", "precision": "day", "ids": {"epic": "epic-only"}, "sources": ["wikidata"]},
		{"title": "On Steam", "date": "2026-12-02", "precision": "day", "ids": {"steam": "5", "epic": "on-steam"}, "sources": ["steam"]}]}
	http.route(H.UPCOMING, {"bytes": JSON.stringify(doc).to_utf8_buffer().compress(FileAccess.COMPRESSION_GZIP)})
	var d := H.make(http, dir)
	d.refresh(true)
	var cal: Array = d.calendar
	eq(cal[0]["link"], {"kind": "url", "uri": "https://store.epicgames.com/p/epic-only", "affiliate": false, "note": "", "store": "epic"}, "plain while the file is empty")
	d.affiliates = {"epic": {"template": "https://example.org/a?u={url_encoded}", "id": "gc"}}
	d.set_settings({"country": "CA"})
	cal = d.calendar
	eq([cal[0]["link"]["affiliate"], cal[0]["link"]["note"]], [true, "Supports GameCove"], "affiliate once configured")
	eq(cal[1]["link"], {"kind": "steam", "uri": "steam://store/5", "affiliate": false, "note": ""}, "Steam never")
	d.set_settings({"affiliate_links": false})
	d.set_settings({"country": "US"})
	eq(d.calendar[0]["link"]["affiliate"], false, "user turned them off")
	d.free()
	H.wipe(dir)
