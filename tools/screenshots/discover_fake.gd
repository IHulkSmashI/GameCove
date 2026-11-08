extends RefCounted
## Fake Discover and Art services with believable data for the Discover
## screenshots (invented games, Canadian prices, painted art). Same API the
## Discover screens use; nothing touches the network.

const Painter := preload("painter.gd")

const NOW_ISO := "2026-11-08T12:00:00"
const PAL := {
	"ocean": ["#0B2B4A", "#2B8C9E", "#F7D58B", "#06121F"],
	"neon": ["#1A0630", "#C2185B", "#FF9E40", "#12021F"],
	"planet": ["#050816", "#3B2A7A", "#B8A6FF", "#04040C"],
	"mountains": ["#2A1208", "#C46A2B", "#FFD27A", "#140804"],
	"city": ["#0A0B24", "#5B1A73", "#3DF5E8", "#05040F"],
	"forest": ["#0E1A2B", "#3E6E8E", "#F2E8CF", "#070D15"],
	"desert": ["#F2B263", "#E0703A", "#FFF1C9", "#4A1E10"],
	"lanterns": ["#140A1F", "#3D1E4F", "#FFB347", "#0A0510"],
	"ice": ["#DDEFFC", "#5C8DB8", "#FFFFFF", "#132A40"],
	"crimson": ["#2A0508", "#9E1B2B", "#FF8A5B", "#140203"],
	"teal": ["#06221F", "#1E7A6E", "#B8FFE6", "#03110F"],
}
## title, motif, palette, hero?
const ART := [
	["Tidebreaker", "ocean", "ocean", true], ["Saltwind", "desert", "desert", true], ["Ashen Orbit", "planet", "planet", true],
	["Lumen Deep", "ocean", "teal", false], ["Hollow Kings", "mountains", "crimson", false], ["Pixel Pilgrims", "neon", "neon", false],
	["Brass Monarch", "city", "mountains", false], ["Garden of Echoes", "forest", "teal", false], ["Orbital Crew", "planet", "city", false],
	["Kite Season", "lanterns", "lanterns", true], ["Starward Tales", "planet", "planet", true], ["Riftborne", "city", "city", false],
	["Moonlit Harbor", "ocean", "forest", false], ["Glasswing", "mountains", "ice", false], ["Winter Keep", "forest", "ice", false],
	["Frostline", "mountains", "ice", false], ["Ironveil", "city", "crimson", false], ["Echo Protocol", "neon", "neon", false],
	["Crown of Thorns", "mountains", "crimson", true], ["Neon Ronin", "city", "city", false],
]


static func now() -> int:
	return Time.get_unix_time_from_datetime_string(NOW_ISO)


static func slug(t: String) -> String:
	return t.to_lower().replace(" ", "_").validate_filename()


## Paints the art and returns {"discover": FakeDiscover, "art": FakeArt}.
static func make(tree: SceneTree, dir: String) -> Dictionary:
	var art := FakeArt.new()
	for a in ART:
		var spec := [a[0], "steam", true, 0, 0, 0, "", "", PAL[a[2]], a[1], "c", {}]
		var s := slug(a[0])
		art.paths["d:" + s + "|cover"] = await Painter._render(tree, spec, "cover", dir + "d_" + s + "_cover.png")
		if a[3]:
			art.paths["d:" + s + "|hero"] = await Painter._render(tree, spec, "hero", dir + "d_" + s + "_hero.png")
			art.paths["d:" + s + "|logo"] = await Painter._logo(tree, a[0], dir + "d_" + s + "_logo.png")
	var d := FakeDiscover.new()
	d.build()
	return {"discover": d, "art": art}


class FakeArt extends RefCounted:
	signal art_ready(key: String, kind: String, path: String)
	var paths := {}
	func request(key: String, kind: String, hints := {}) -> String:
		var t := str(hints.get("title", ""))
		return paths.get("d:" + t.to_lower().replace(" ", "_").validate_filename() + "|" + kind, "")


class FakeDiscover extends Node:
	signal deals_changed
	signal calendar_changed
	signal wishlist_changed
	signal settings_changed
	signal prices_ready(game_key: String, deals: Array)
	signal search_done(query: String, results: Array)
	signal import_done(ok: bool, added: int, error: String)
	signal price_alert(item: Dictionary, deal: Dictionary)
	signal release_alert(item: Dictionary)
	signal status_changed(source: String, status: String)

	var deals: Array = []
	var calendar: Array = []
	var status := {"cheapshark": "ok", "steam": "ok", "calendar": "ok"}
	var alerts_inbox: Array = []
	var settings := {"country": "CA", "steam_id": "", "ggdeals_key": "", "ggdeals_keyshops": false, "alerts": true, "affiliate_links": true}
	var items := {}
	var clock: Callable = func() -> int: return Time.get_unix_time_from_datetime_string("2026-11-08T12:00:00")
	var opened: Array = []
	var stores := {}

	var wishlist: Array:
		get: return _wish_view()

	func _t() -> int:
		return clock.call()

	func _art(t: String) -> Dictionary:
		return {"cover": "https://example.invalid/%s.jpg" % t, "hero": "", "header": ""}

	func _deal(t: String, appid: String, store: String, store_name: String, amount: Variant, regular: float, pct: int, extra := {}) -> Dictionary:
		var price: Variant = null
		if amount != null:
			price = {"amount": float(amount), "regular": regular, "currency": "CAD", "country": "CA", "source": "steam", "is_local": true,
				"text": "C$ %.2f" % float(amount), "regular_text": "C$ %.2f" % regular}
		var key := "steam:" + appid if appid != "" else "title:" + t.to_lower().replace(" ", "")
		var d := {"key": ("steam:" if store == "steam" else "cheapshark:") + appid + store, "source": "steam" if store == "steam" else "cheapshark",
			"store": store, "store_name": store_name, "store_icon": "", "title": t, "appid": appid, "game_id": "",
			"price": price, "see_price": price == null, "savings_pct": pct, "on_sale": pct > 0, "is_historical_low": false,
			"historical_low": null, "sale_ends_at": null, "rating": null, "art": _art(t),
			"link": {"kind": "steam" if store == "steam" else "url", "uri": "steam://store/" + appid, "affiliate": false, "note": ""},
			"attribution": null, "keyshop": false, "ggdeals": null, "on_wishlist": false, "wishlist_key": key}
		d.merge(extra, true)
		return d

	func _rel(t: String, appid: String, date: String, precision: String, extra := {}) -> Dictionary:
		var du: Variant = null
		var unix: Variant = null
		var released := false
		var now := _t()
		if precision == "day":
			unix = Time.get_unix_time_from_datetime_string(date + "T00:00:00")
			du = int(floor((float(unix) - float(now - now % 86400)) / 86400.0))
			released = du < 0
		elif precision == "month":
			unix = Time.get_unix_time_from_datetime_string(date + "-01T00:00:00")
		elif precision == "quarter":
			unix = Time.get_unix_time_from_datetime_string(date.left(4) + "-01-01T00:00:00")
		var r := {"key": "steam:" + appid if appid != "" else "title:" + t.to_lower().replace(" ", ""), "title": t, "date": date,
			"precision": precision, "date_unix": unix, "days_until": du, "released": released,
			"ids": {"steam": appid} if appid != "" else {"igdb": "1"}, "art": _art(t),
			"link": {"kind": "steam", "uri": "steam://store/" + appid} if appid != "" else {}, "sources": ["steam"] if appid != "" else ["igdb"], "on_wishlist": false}
		r.merge(extra, true)
		return r

	func build() -> void:
		var now := _t()
		deals = [
			_deal("Tidebreaker", "701", "steam", "Steam", 8.99, 44.99, 80, {"is_historical_low": true, "historical_low": {"amount": 8.99, "currency": "CAD"}, "sale_ends_at": now + 3 * 86400 + 4000, "rating": 9.6}),
			_deal("Ashen Orbit", "702", "steam", "Steam", 23.99, 59.99, 60, {"sale_ends_at": now + 6 * 86400, "rating": 9.1, "historical_low": {"amount": 17.99, "currency": "CAD"}}),
			_deal("Neon Ronin", "1385", "cs:3", "GreenManGaming", null, 0.0, 45, {"rating": 8.8}),
			_deal("Saltwind", "703", "steam", "Steam", 13.49, 26.99, 50, {"sale_ends_at": now + 20 * 3600, "rating": 8.5}),
			_deal("Hollow Kings", "", "cs:25", "Epic Games Store", null, 0.0, 60, {"rating": 8.2}),
			_deal("Lumen Deep", "704", "steam", "Steam", 4.19, 20.99, 80, {"is_historical_low": true, "historical_low": {"amount": 4.19, "currency": "CAD"}, "sale_ends_at": now + 9 * 86400, "rating": 9.3}),
			_deal("Pixel Pilgrims", "705", "cs:15", "Fanatical", null, 0.0, 70, {"rating": 7.9}),
			_deal("Brass Monarch", "706", "cs:11", "Humble Store", null, 0.0, 33, {"rating": 7.4}),
			_deal("Garden of Echoes", "", "cs:25", "Epic Games Store", null, 0.0, 100, {"rating": 9.0}),
			_deal("Orbital Crew", "707", "steam", "Steam", 0.0, 19.99, 100, {"sale_ends_at": now + 2 * 86400}),
		]
		calendar = [
			_rel("Ironveil", "801", "2026-11-01", "day"),
			_rel("Kite Season", "802", "2026-11-08", "day"),
			_rel("Starward Tales", "803", "2026-11-10", "day"),
			_rel("Riftborne", "804", "2026-11-13", "day"),
			_rel("Moonlit Harbor", "805", "2026-11-13", "day"),
			_rel("Glasswing", "806", "2026-11-20", "day"),
			_rel("Frostline", "", "2026-11", "month"),
			_rel("Winter Keep", "807", "2026-12-04", "day"),
			_rel("Echo Protocol", "808", "2026-12-18", "day"),
			_rel("Crown of Thorns", "809", "2027-Q1", "quarter"),
			_rel("Untitled Heist Game", "", "", "tba"),
		]
		calendar[9]["date_unix"] = Time.get_unix_time_from_datetime_string("2027-01-01T00:00:00")
		calendar[10]["date_unix"] = null
		for t in [["Saltwind", "703", 15.0, true, false], ["Lumen Deep", "704", null, true, false], ["Starward Tales", "803", null, true, true],
				["Crown of Thorns", "809", null, true, true], ["Ashen Orbit", "702", 20.0, true, false]]:
			items["steam:" + t[1]] = {"key": "steam:" + t[1], "title": t[0], "ids": {"steam": t[1]}, "added": now - items.size() * 86400,
				"source": "steam", "target_price": t[2], "notify_price": t[3], "notify_release": t[4], "last_price": null, "art": _art(t[0])}
		alerts_inbox = [
			{"id": "a1", "kind": "price", "key": "steam:703", "title": "Saltwind", "at": now - 2 * 3600, "amount": 13.49, "currency": "CAD", "target_price": 15.0},
			{"id": "a2", "kind": "release", "key": "steam:802", "title": "Kite Season", "at": now - 5 * 3600},
		]
		_mark()

	func _mark() -> void:
		for d in deals:
			d["on_wishlist"] = items.has(d["wishlist_key"])
		for r in calendar:
			r["on_wishlist"] = items.has(r["key"])

	func _wish_view() -> Array:
		var out: Array = []
		for k in items:
			var it: Dictionary = items[k].duplicate(true)
			var best := {}
			for d in deals:
				if d["wishlist_key"] == k and d["price"] != null:
					best = d
			it["best_deal"] = best
			it["on_sale"] = not best.is_empty() and best["on_sale"]
			it["savings_pct"] = int(best.get("savings_pct", 0))
			it["is_historical_low"] = best.get("is_historical_low", false)
			it["historical_low"] = best.get("historical_low")
			it["sale_ends_at"] = best.get("sale_ends_at")
			it["release"] = {}
			for r in calendar:
				if r["key"] == k:
					it["release"] = {"released": r["released"], "date": r["date"], "precision": r["precision"], "days_until": r["days_until"], "date_unix": r["date_unix"]}
			it["on_wishlist"] = true
			if it["art"]["cover"] == "" and not best.is_empty():
				it["art"] = best["art"]
			out.append(it)
		return out

	func get_settings() -> Dictionary:
		var s := settings.duplicate()
		s["country_effective"] = "CA"
		s["currency_effective"] = "CAD"
		return s

	func set_settings(p: Dictionary) -> void:
		settings.merge(p, true)
		settings_changed.emit()

	func user_currency() -> String:
		return "CAD"

	func attributions() -> Array:
		var out := [{"text": "Price data by CheapShark", "url": "https://www.cheapshark.com/"}]
		if settings["ggdeals_key"] != "":
			out.append({"text": "Prices by GG.deals", "url": "https://gg.deals/"})
		return out

	func prices_for(game: Variant) -> Array:
		var t := str(game.get("title", "")) if game is Dictionary else str(game)
		var list := deals.filter(func(d): return d["title"] == t)
		if t == "Tidebreaker":
			list.append(_deal("Tidebreaker", "701", "cs:3", "GreenManGaming", null, 0.0, 74))
			list.append(_deal("Tidebreaker", "701", "cs:15", "Fanatical", null, 0.0, 70))
			list.append(_deal("Tidebreaker", "701", "cs:7", "GOG", null, 0.0, 65))
		return list

	func request_prices(game: Variant) -> void:
		var q: Dictionary = game
		prices_ready.emit("steam:" + str(q.get("appid", "")), prices_for(game))

	func add_to_wishlist(g: Dictionary) -> String:
		var k := str(g.get("wishlist_key", g.get("key", "")))
		if k.begins_with("cheapshark:") or k == "":
			k = "steam:" + str(g.get("appid", ""))
		if not items.has(k):
			items[k] = {"key": k, "title": g.get("title", ""), "ids": {"steam": g.get("appid", "")}, "added": _t(), "source": "manual",
				"target_price": null, "notify_price": true, "notify_release": false, "last_price": null, "art": g.get("art", {})}
		_mark()
		wishlist_changed.emit()
		deals_changed.emit()
		return k

	func remove_from_wishlist(k: String) -> void:
		items.erase(k)
		_mark()
		wishlist_changed.emit()

	func set_target_price(k: String, p: Variant) -> void:
		if items.has(k):
			items[k]["target_price"] = p
			wishlist_changed.emit()

	func set_notify(k: String, price: Variant = null, release: Variant = null) -> void:
		if items.has(k):
			if price != null:
				items[k]["notify_price"] = price
			if release != null:
				items[k]["notify_release"] = release
			wishlist_changed.emit()

	func notify_me(r: Dictionary) -> String:
		var k: String = r["key"]
		if not items.has(k):
			items[k] = {"key": k, "title": r["title"], "ids": r["ids"], "added": _t(), "source": "calendar", "target_price": null,
				"notify_price": true, "notify_release": true, "last_price": null, "art": r["art"]}
		items[k]["notify_release"] = true
		_mark()
		wishlist_changed.emit()
		return k

	func is_wishlisted(g: Variant) -> bool:
		return g is Dictionary and (items.has(str(g.get("wishlist_key", ""))) or items.has(str(g.get("key", ""))))

	func get_item(k: String) -> Dictionary:
		return items.get(k, {})

	func import_steam_wishlist(profile := "") -> void:
		settings["steam_id"] = profile
		import_done.emit(true, 3, "")

	func mark_seen(id := "") -> void:
		alerts_inbox = alerts_inbox.filter(func(a): return id != "" and a["id"] != id)
		wishlist_changed.emit()

	func calendar_info() -> Dictionary:
		return {} if calendar.is_empty() else {"built": "2026-11-08T06:40:00Z", "sources": {}, "credits": ""}

	func open_link(link: Dictionary) -> bool:
		opened.append(link)
		return true

	func refresh(_force := false) -> bool:
		return false
