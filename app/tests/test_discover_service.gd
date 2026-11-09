extends "res://tests/test_case.gd"
## The Discover autoload end to end with a fake http: refresh, offline
## fallback, cache ages, pause, wishlist import, alerts, persistence.

const H := preload("res://tests/fixtures/discover/helpers.gd")
const FakeHttp := preload("res://scripts/discover/fake_http.gd")
const Privacy := preload("res://scripts/system/privacy.gd")


class Events:
	var log: Array = []

	func watch(d: Node) -> void:
		for s in ["deals_changed", "calendar_changed", "wishlist_changed"]:
			d.connect(s, func(): log.append([s]))
		d.price_alert.connect(func(item, deal): log.append(["price_alert", item["key"], deal["store"]]))
		d.release_alert.connect(func(item): log.append(["release_alert", item["key"]]))
		d.status_changed.connect(func(src, st): log.append(["status", src, st]))
		d.import_done.connect(func(ok, n, err): log.append(["import", ok, n, err]))
		d.search_done.connect(func(q, r): log.append(["search", q, r]))
		d.prices_ready.connect(func(k, list): log.append(["prices", k, list]))

	func named(n: String) -> Array:
		return log.filter(func(e): return e[0] == n)


func test_full_refresh_from_fixtures() -> void:
	var dir := H.temp_dir("disc_full")
	var http = H.online_http()
	var d := H.make(http, dir)
	var ev := Events.new()
	ev.watch(d)
	d.add_to_wishlist({"title": "Borderlands 2", "appid": "49520"})
	ok(d.refresh(), "refresh started")
	eq(d.status.get("cheapshark"), "ok", "cheapshark ok")
	eq(d.status.get("steam"), "ok", "steam ok")
	eq(d.status.get("calendar"), "ok", "calendar ok")
	eq(d.deals.size(), 8, "top deals")
	var civ: Dictionary = d.deals.filter(func(x): return x["appid"] == "3900")[0]
	eq([civ["price"]["currency"], civ["price"]["amount"], civ["price"]["source"]], ["CAD", 4.39, "steam"], "Steam row priced for Canada by Steam")
	var gmg_row: Dictionary = d.deals[1]
	eq([gmg_row["price"], gmg_row["see_price"]], [null, true], "GMG in Canada: See price, no estimate")
	eq(d.calendar.size(), 8, "calendar from the downloaded file")
	eq(d.calendar_info()["built"], "2026-11-08T06:40:00Z", "calendar info")
	var w: Array = d.wishlist
	eq(w.size(), 1, "one wishlist item")
	var bl2: Dictionary = w[0]
	eq(bl2["ids"].get("cheapshark"), "88304", "CheapShark id resolved")
	eq(bl2["best_deal"]["store"], "steam", "best deal is Steam's C$2.19")
	eq(bl2["best_deal"]["price"]["amount"], 2.19, "best price")
	eq([bl2["on_sale"], bl2["savings_pct"], bl2["is_historical_low"]], [true, 90, false], "badge fields (no CAD low source)")
	eq(bl2["sale_ends_at"], 1794852000, "sale end")
	eq(bl2["historical_low"], null, "USD low not shown in Canada")
	eq(bl2["release"]["released"], true, "released per Steam")
	eq(ev.named("price_alert"), [["price_alert", "steam:49520", "steam"]], "any-drop alert once")
	eq(d.alerts_inbox.size(), 1, "inbox")
	ok(ev.named("deals_changed").size() >= 1 and ev.named("calendar_changed").size() == 1, "signals")
	ok(http.requests.size() <= 8, "a handful of requests (%d)" % http.requests.size())
	# Library tile lookup
	eq(d.deal_for_appid("49520")["price"]["amount"], 2.19, "deal_for_appid")
	eq(d.deal_for_appid(3900)["price"]["amount"], 4.39, "from top deals")
	eq(d.deal_for_appid("2482760"), {}, "a See-price-only game has no badge price")
	eq(d.deal_for_appid("1"), {}, "unknown")
	eq(d.deal_for_title("borderlands 2")["store"], "steam", "by title")
	# a second check within 6 hours does nothing, alert doesn't repeat
	var n: int = http.requests.size()
	ok(not d.refresh(), "not due")
	eq(http.requests.size(), n, "no requests")
	d.refresh(true)
	eq(ev.named("price_alert").size(), 1, "same price doesn't alert twice")
	d.mark_seen(d.alerts_inbox[0]["id"])
	eq(d.alerts_inbox.size(), 0, "marked seen")
	d.free()
	H.wipe(dir)


func test_offline_keeps_cache_and_reports() -> void:
	var dir := H.temp_dir("disc_off")
	var d := H.make(H.online_http(), dir)
	d.add_to_wishlist({"title": "Borderlands 2", "appid": "49520"})
	d.refresh(true)
	d.free()
	# Restart offline: everything comes from user://discover
	var off = FakeHttp.new()
	var d2 := H.make(off, dir)
	eq(d2.deals.size(), 8, "deals from cache")
	eq(d2.calendar.size(), 8, "calendar from cache")
	eq(d2.wishlist[0]["best_deal"]["price"]["amount"], 2.19, "prices from cache")
	var ev := Events.new()
	ev.watch(d2)
	d2.refresh(true)
	eq(d2.status.get("cheapshark"), "offline", "offline status")
	eq(d2.status.get("calendar"), "offline", "calendar offline")
	ok(ev.named("status").size() >= 2, "status_changed emitted")
	eq(d2.deals.size(), 8, "deals kept")
	eq(d2.wishlist.size(), 1, "wishlist kept")
	eq(ev.named("price_alert"), [], "no repeat alert after restart")
	d2.free()
	H.wipe(dir)


func test_missing_calendar_file_falls_back() -> void:
	var dir := H.temp_dir("disc_404")
	var http = H.online_http()
	http.route(H.UPCOMING, {"error": "http 404", "code": 404})
	var d := H.make(http, dir)
	d.refresh(true)
	eq(d.status.get("calendar"), "missing", "404 is 'missing'")
	eq(d.calendar, [], "empty calendar, no crash")
	eq(d.deals.size(), 8, "deals still work")
	var civ: Dictionary = d.deals.filter(func(x): return x["appid"] == "3900")[0]
	eq(civ["price"]["amount"], 4.39, "prices don't depend on the calendar file")
	var n: int = http.count(H.UPCOMING)
	d.clock = func() -> int: return H.now() + 7 * 3600
	d.refresh()
	eq(http.count(H.UPCOMING), n, "404 isn't retried within a day")
	d.clock = func() -> int: return H.now() + 25 * 3600
	d.refresh()
	eq(http.count(H.UPCOMING), n + 1, "asked again the next day")
	d.free()
	H.wipe(dir)


func test_bad_calendar_download_keeps_old_copy() -> void:
	var dir := H.temp_dir("disc_bad")
	var d := H.make(H.online_http(), dir)
	d.refresh(true)
	eq(d.calendar.size(), 8, "good copy")
	var http = H.online_http()
	http.route(H.UPCOMING, {"file": H.fx("not_image.html")})
	d.http = http
	d.refresh(true)
	eq(d.status.get("calendar"), "error: unreadable file", "bad file reported")
	eq(d.calendar.size(), 8, "old copy kept")
	ok(not FileAccess.file_exists(ProjectSettings.globalize_path(dir.path_join("upcoming.json.gz.part"))), "part removed")
	d.free()
	H.wipe(dir)


func test_cache_ages_and_pause() -> void:
	var dir := H.temp_dir("disc_age")
	var http = H.online_http()
	var d := H.make(http, dir)
	ok(d.refresh(), "first refresh")
	var deals_calls: int = http.count(H.CS + "deals")
	var stores_calls: int = http.count(H.CS + "stores")
	d.clock = func() -> int: return H.now() + 5 * 3600
	ok(not d.refresh(), "5 h: not due")
	d.clock = func() -> int: return H.now() + 6 * 3600 + 1
	d.game_running = true
	ok(not d.refresh(), "game running: no refresh")
	eq(http.count(H.CS + "deals"), deals_calls, "nothing fetched while playing")
	d.game_running = false
	eq(http.count(H.CS + "deals"), deals_calls + 1, "pending refresh runs when the game ends")
	eq(http.count(H.CS + "stores"), stores_calls, "store list cached for a week")
	eq(http.count(H.UPCOMING), 1, "calendar only daily")
	d.pause()
	d.clock = func() -> int: return H.now() + 13 * 3600
	ok(not d.refresh(), "paused")
	ok(d.refresh(true), "force works while paused")
	d.resume()
	d.clock = func() -> int: return H.now() + 8 * 86400
	d.refresh()
	eq(http.count(H.CS + "stores"), stores_calls + 1, "store list after a week")
	d.free()
	H.wipe(dir)


func test_rate_limited_status() -> void:
	var dir := H.temp_dir("disc_429")
	var http = H.online_http()
	http.route(H.CS + "deals", {"error": "http 429", "code": 429, "retry_after": 30})
	var d := H.make(http, dir)
	d.refresh(true)
	eq(d.status.get("cheapshark"), "rate_limited", "429 reported")
	eq(d.deals, [], "no deals yet")
	d.free()
	H.wipe(dir)


func test_import_steam_wishlist_by_vanity() -> void:
	var dir := H.temp_dir("disc_imp")
	var http = H.online_http()
	var d := H.make(http, dir)
	var ev := Events.new()
	ev.watch(d)
	d.add_to_wishlist({"title": "Borderlands 2", "appid": "49520", "target_price": 1.0})
	d.import_steam_wishlist("https://steamcommunity.com/id/robinwalker/")
	eq(ev.named("import"), [["import", true, 2, ""]], "two new games")
	ok(http.requests.any(func(u): return u.contains("steamid=76561197972611406")), "resolved id used")
	var keys: Array = d.wishlist.map(func(i): return i["key"])
	eq(keys, ["steam:49520", "steam:4530370", "steam:3900"], "newest first: the manual add (now), then by Steam date")
	var civ: Dictionary = d.get_item("steam:3900")
	eq(civ["title"], "Sid Meier's Civilization® IV", "title from Steam")
	eq(civ["source"], "steam", "source")
	eq(civ["added"], 1710000000, "Steam's added date")
	eq(d.get_item("steam:49520")["target_price"], 1.0, "existing settings kept")
	eq(d.get_settings()["steam_id"], "https://steamcommunity.com/id/robinwalker/", "remembered")
	# reload from disk
	d.free()
	var d2 := H.make(FakeHttp.new(), dir)
	eq(d2.wishlist.size(), 3, "wishlist saved")
	d2.free()
	H.wipe(dir)


func test_import_errors() -> void:
	var dir := H.temp_dir("disc_imperr")
	var http = H.online_http()
	var d := H.make(http, dir)
	var ev := Events.new()
	ev.watch(d)
	d.import_steam_wishlist("nobodyhere")
	eq(ev.named("import")[-1], ["import", false, 0, "No Steam profile with that name"], "unknown name")
	d.import_steam_wishlist("bad input !!")
	eq(ev.named("import")[-1][1], false, "junk input")
	http.route(H.STEAM_WISHLIST, {"file": H.fx("steam_wishlist_private.json")})
	d.import_steam_wishlist("76561197972611406")
	var last: Array = ev.named("import")[-1]
	eq([last[1], last[2]], [true, 0], "private wishlist: ok but empty")
	ok(last[3].contains("private"), "says why")
	var off = FakeHttp.new()
	d.http = off
	d.import_steam_wishlist("76561197972611406")
	eq(ev.named("import")[-1], ["import", false, 0, "Steam is unreachable"], "offline")
	d.free()
	H.wipe(dir)


func test_target_price_alert_and_switches() -> void:
	var dir := H.temp_dir("disc_target")
	var d := H.make(H.online_http(), dir)
	var ev := Events.new()
	ev.watch(d)
	var key: String = d.add_to_wishlist({"title": "Borderlands 2", "appid": "49520"})
	d.set_target_price(key, 2.0)
	d.refresh(true)
	eq(ev.named("price_alert"), [], "C$2.19 is above a C$2.00 target")
	d.set_target_price(key, 2.5)
	d.check_alerts()
	eq(ev.named("price_alert").size(), 1, "target raised: alert")
	d.check_alerts()
	eq(ev.named("price_alert").size(), 1, "once")
	d.set_settings({"alerts": false})
	d.set_target_price(key, 3.0)
	d.check_alerts()
	eq(ev.named("price_alert").size(), 1, "alerts off")
	d.set_settings({"alerts": true})
	d.set_notify(key, false)
	d.check_alerts()
	eq(ev.named("price_alert").size(), 1, "item's price alerts off")
	d.remove_from_wishlist(key)
	eq(d.wishlist, [], "removed")
	d.free()
	H.wipe(dir)


func test_notify_me_release_alert() -> void:
	var dir := H.temp_dir("disc_notify")
	var http = H.online_http()
	var d := H.make(http, dir)
	var ev := Events.new()
	ev.watch(d)
	d.refresh(true)
	var cal: Array = d.calendar
	var fm: Dictionary = cal.filter(func(r): return r["title"] == "Football Manager 27")[0]
	var key: String = d.notify_me(fm)
	eq(key, "steam:4530370", "added by Steam id")
	var item: Dictionary = d.get_item(key)
	eq([item["notify_release"], item["source"]], [true, "calendar"], "release alert on")
	eq(item["release"]["days_until"], 2, "releases in 2 days")
	ok(d.calendar.filter(func(r): return r["key"] == key)[0]["on_wishlist"], "calendar shows it wishlisted")
	d.check_alerts()
	eq(ev.named("release_alert"), [], "not out yet")
	d.clock = func() -> int: return H.now() + 3 * 86400
	d.check_alerts()
	eq(ev.named("release_alert"), [["release_alert", key]], "out: alert")
	d.check_alerts()
	eq(ev.named("release_alert").size(), 1, "once")
	var old: Dictionary = cal.filter(func(r): return r["title"] == "Out Last Week")[0]
	d.notify_me(old)
	d.check_alerts()
	eq(ev.named("release_alert").size(), 1, "already-out game doesn't alert")
	d.free()
	H.wipe(dir)


func test_search_and_request_prices() -> void:
	var dir := H.temp_dir("disc_search")
	var http = H.online_http()
	var d := H.make(http, dir)
	var ev := Events.new()
	ev.watch(d)
	d.search("hades")
	var s: Array = ev.named("search")
	eq(s.size(), 1, "search_done")
	var results: Array = s[0][2]
	eq(results.size(), 5, "results")
	eq(results[0]["title"], "Hades", "title")
	eq(results[0]["ids"], {"cheapshark": "196149", "steam": "1145360"}, "ids")
	eq(results[0]["best_deal"]["source"], "steam", "Steam's Canadian price")
	eq(results[0]["best_deal"]["price"]["amount"], 32.5, "C$32.50")
	eq(results[2]["best_deal"], {}, "no Steam id, CheapShark's USD cheapest isn't shown in Canada")
	eq(results[0]["on_wishlist"], false, "not wishlisted")
	d.request_prices({"store": "steam", "id": "49520", "title": "Borderlands 2"})
	var p: Array = ev.named("prices")
	eq(p[0][1], "steam:49520", "key")
	eq(p[0][2].size(), 10, "every store")
	eq(d.prices_for("49520").size(), 10, "cached for prices_for")
	eq(d.is_wishlisted({"appid": "49520"}), false, "not wishlisted")
	d.search("  ")
	eq(ev.named("search")[-1][2], [], "empty query")
	d.free()
	H.wipe(dir)


func test_settings_country_override_and_currency() -> void:
	var dir := H.temp_dir("disc_set")
	var d := H.make(H.online_http(), dir)
	eq([d.get_settings()["currency_effective"], d.get_settings()["country_source"]], ["CAD", "settings"], "Canada -> CAD")
	d.refresh(true)
	d.set_settings({"country": "US", "currency": "EUR", "bogus": 1})
	eq(d.get_settings()["currency_effective"], "USD", "currency follows the country")
	ok(not d.get_settings().has("bogus") and not d.get_settings().has("currency"), "unknown keys ignored")
	var gmg: Dictionary = d.deals[1]
	eq([gmg["price"]["currency"], gmg["price"]["country"], gmg["price"]["source"]], ["USD", "US", "cheapshark"], "US: CheapShark prices are local")
	d.set_settings({"country": ""})
	d.detected_region = {"country": "GB", "source": "timezone"}
	eq([d.country(), d.get_settings()["country_source"], d.user_currency()], ["GB", "timezone", "GBP"], "detected when not set")
	d.free()
	var d2 := H.make(FakeHttp.new(), dir)
	eq(d2.get_settings()["country"], "CA", "saved (helpers set CA)")
	d2.free()
	H.wipe(dir)


# ---- review M22: the network switches -----------------------------------------------------------

func test_background_lookups_off_sends_nothing_by_itself() -> void:
	var dir := H.temp_dir("disc_privacy_bg")
	var http = H.online_http()
	var d := H.make(http, dir)
	d.add_to_wishlist({"title": "Borderlands 2", "appid": "49520"})
	ok(Privacy.set_background_allowed(false, d.privacy_path), "switch saved")
	ok(not d.refresh(), "no background refresh")
	eq(http.requests.size(), 0, "nothing requested")
	ok(d.refresh(true), "the user asking still works")
	ok(http.requests.size() > 0, "requested when asked")
	d.free()


func test_price_lookups_off_never_calls_deal_sources() -> void:
	var dir := H.temp_dir("disc_privacy_prices")
	var http = H.online_http()
	var d := H.make(http, dir)
	var ev := Events.new()
	ev.watch(d)
	d.add_to_wishlist({"title": "Borderlands 2", "appid": "49520"})
	eq(d.get_settings()["price_lookups"], true, "on by default")
	d.set_settings({"price_lookups": false})
	d.refresh(true)
	d.request_prices({"title": "Borderlands 2", "appid": "49520"})
	d.search("borderlands")
	var deal_calls: Array = http.requests.filter(func(u): return "cheapshark" in u or "steampowered" in u or "gg.deals" in u)
	eq(deal_calls, [], "no CheapShark, Steam store or GG.deals request")
	ok(http.requests.all(func(u): return "github.com" in u), "only the calendar file (GameCove's own release)")
	eq(ev.named("search").size(), 1, "search answers (empty) at once")
	d.set_settings({"price_lookups": true})
	d.refresh()
	ok(http.requests.any(func(u): return "cheapshark" in u), "back on: prices are looked up again")
	d.free()



func test_discover_files_are_private() -> void:
	# review L32: settings.json holds the user's API keys
	var dir := H.temp_dir("disc_private")
	var d := H.make(FakeHttp.new(), dir)
	d.set_settings({"ggdeals_key": "abcdefghij12345"})
	var p := ProjectSettings.globalize_path(dir.path_join("settings.json"))
	ok(FileAccess.file_exists(p), "saved")
	eq(FileAccess.get_unix_permissions(p) & 511, 384, "settings.json is 0600")
	d.free()
