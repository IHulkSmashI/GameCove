extends RefCounted
## Builds the contract's Deal dicts and merges one game's prices across stores.
## Static only.
##
## Every number shown is a store's real price for the user's country:
## - Steam rows: Steam's own store data for that country (GetItems with
##   country_code).
## - CheapShark rows: CheapShark's prices are the US stores' USD prices, so they
##   count as local only when the country is US. Elsewhere a CheapShark row
##   keeps its store, discount percentage and link but has "price": null; the
##   UI shows "See price" and opens the link. No currency conversion anywhere.
##
## Linking rule (CheapShark's terms): a Deal built from CheapShark data opens
## CheapShark's redirect URL, even when the store is Steam. A Deal built from
## Steam's own data opens steam://store/<appid>. When both exist for one game,
## prices_for() keeps Steam's row and drops CheapShark's Steam row.

const CheapShark := preload("res://scripts/discover/cheapshark.gd")
const Money := preload("res://scripts/discover/money.gd")
const Wish := preload("res://scripts/discover/wishlist.gd")
const SteamApi := preload("res://scripts/discover/steam_api.gd")

const STEAM_STORE_ID := "1"
const CHEAPSHARK_COUNTRY := "US"


## The contract's price block. Only ever built from a store's own local price.
static func price_block(amount: float, regular: float, currency: String, country: String, source: String,
		text := "", regular_text := "") -> Dictionary:
	return {
		"amount": amount, "regular": maxf(regular, amount), "currency": currency, "country": country,
		"source": source, "is_local": true,
		"text": text if text != "" else Money.format(amount, currency),
		"regular_text": regular_text if regular_text != "" else Money.format(maxf(regular, amount), currency),
	}


## ctx: {"country": "CA", "currency": "CAD", "wishlist": key -> item}
static func _finish(deal: Dictionary, ctx: Dictionary) -> Dictionary:
	deal["see_price"] = deal["price"] == null
	deal["on_sale"] = deal["savings_pct"] > 0
	var wkey := Wish.key_for({"steam": deal["appid"]}, deal["title"])
	deal["wishlist_key"] = wkey
	deal["on_wishlist"] = ctx.get("wishlist", {}).has(wkey)
	return deal


## The historical low only when it's in the user's own currency and country
## (CheapShark's lows are US prices), else null.
static func local_low(low: Variant, ctx: Dictionary) -> Variant:
	if low is Dictionary and ctx.get("country", "") == CHEAPSHARK_COUNTRY:
		return {"amount": float(low.get("price", 0.0)), "currency": "USD", "date": int(low.get("date", 0))}
	return null


static func _is_low(amount: Variant, low: Variant) -> bool:
	return amount != null and low is Dictionary and float(amount) <= float(low["amount"]) + 0.005


## A Deal from a CheapShark offer. `stores` is parse_stores(); `low` CheapShark's
## historical low or null; `steam` the game's Steam info for the user's country
## or null (used for CheapShark's Steam rows).
static func from_cheapshark(o: Dictionary, stores: Dictionary, ctx: Dictionary, low: Variant = null, steam: Variant = null) -> Dictionary:
	var sid: String = o.get("store_id", "")
	var store: Dictionary = stores.get(sid, {})
	var appid: String = o.get("appid", "")
	var art := {"cover": "", "hero": "", "header": "", "thumb": str(o.get("thumb", ""))}
	if appid != "":
		var fb := SteamApi.fallback_art(appid)
		art.merge({"cover": fb["cover"], "hero": fb["hero"], "header": fb["header"]}, true)
	var country: String = ctx.get("country", "US")
	var price = null
	var savings := int(o.get("savings_pct", 0))
	var ends = null
	if sid == STEAM_STORE_ID and steam is Dictionary and steam.get("price") != null:
		price = price_block(steam["price"], steam["regular_price"], ctx.get("currency", ""), country, "steam",
			steam.get("price_text", ""), steam.get("regular_text", ""))
		savings = int(steam.get("savings_pct", 0))
		ends = steam.get("sale_ends_at", null)
	elif country == CHEAPSHARK_COUNTRY:
		price = price_block(float(o.get("price", 0.0)), float(o.get("regular_price", 0.0)), CheapShark.CURRENCY,
			CHEAPSHARK_COUNTRY, "cheapshark")
	if steam is Dictionary and steam.get("art") is Dictionary:
		for k in steam["art"]:
			if art.has(k) and str(steam["art"][k]) != "":
				art[k] = steam["art"][k]
	var hl = local_low(low, ctx)
	var deal := {
		"key": "cheapshark:" + str(o.get("deal_id", "")), "source": "cheapshark",
		"store": "steam" if sid == STEAM_STORE_ID else "cs:" + sid,
		"store_name": store.get("name", "Steam" if sid == STEAM_STORE_ID else ("Store " + sid if sid != "" else "")),
		"store_icon": store.get("icon", ""),
		"title": o.get("title", ""), "appid": appid, "game_id": o.get("game_id", ""),
		"price": price, "savings_pct": savings,
		"is_historical_low": price != null and price["currency"] == "USD" and _is_low(price["amount"], hl),
		"historical_low": hl, "sale_ends_at": ends, "rating": o.get("rating", null), "art": art,
		"link": {"kind": "url", "uri": CheapShark.redirect_url(str(o.get("deal_id", "")))},
	}
	return _finish(deal, ctx)


## A Deal from Steam's own store data for the user's country, or {} when it
## has no price.
static func from_steam(info: Dictionary, ctx: Dictionary, low: Variant = null) -> Dictionary:
	if info.get("price") == null:
		return {}
	var appid: String = info.get("appid", "")
	var art := {"cover": "", "hero": "", "header": "", "thumb": ""}
	var fb := SteamApi.fallback_art(appid)
	art.merge({"cover": fb["cover"], "hero": fb["hero"], "header": fb["header"]}, true)
	if info.get("art") is Dictionary:
		for k in info["art"]:
			art[k] = info["art"][k]
	art["thumb"] = art.get("capsule", "")
	art.erase("capsule")
	var price := price_block(info["price"], info.get("regular_price", info["price"]), ctx.get("currency", ""),
		ctx.get("country", ""), "steam", info.get("price_text", ""), info.get("regular_text", ""))
	var hl = local_low(low, ctx)
	var deal := {
		"key": "steam:" + appid, "source": "steam", "store": "steam", "store_name": "Steam", "store_icon": "",
		"title": info.get("title", ""), "appid": appid, "game_id": "",
		"price": price, "savings_pct": int(info.get("savings_pct", 0)),
		"is_historical_low": price["currency"] == "USD" and int(info.get("savings_pct", 0)) > 0 and _is_low(price["amount"], hl),
		"historical_low": hl, "sale_ends_at": info.get("sale_ends_at", null), "rating": null, "art": art,
		"link": {"kind": "steam", "uri": SteamApi.store_uri(appid)},
	}
	return _finish(deal, ctx)


## Every store's offer for one game: rows with a local price first, cheapest
## first, then "See price" rows by discount. `lookup` is one entry of
## CheapShark.parse_lookup() or {}; `steam` the game's Steam info or null.
static func prices_for(lookup: Dictionary, steam: Variant, stores: Dictionary, ctx: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var low = lookup.get("historical_low", null)
	var steam_deal := from_steam(steam, ctx, low) if steam is Dictionary else {}
	if not steam_deal.is_empty():
		out.append(steam_deal)
	for o in lookup.get("offers", []):
		if o.get("store_id") == STEAM_STORE_ID and not steam_deal.is_empty():
			continue
		var st: Dictionary = stores.get(o.get("store_id", ""), {})
		if not st.is_empty() and not st.get("active", true):
			continue
		out.append(from_cheapshark(o, stores, ctx, low, null))
	sort_deals(out)
	return out


static func sort_deals(list: Array) -> void:
	list.sort_custom(func(a, b):
		var pa = a.get("price")
		var pb = b.get("price")
		if (pa == null) != (pb == null):
			return pa != null
		if pa != null and not is_equal_approx(float(pa["amount"]), float(pb["amount"])):
			return float(pa["amount"]) < float(pb["amount"])
		if a["savings_pct"] != b["savings_pct"]:
			return a["savings_pct"] > b["savings_pct"]
		return a["store_name"] < b["store_name"])


## The cheapest Deal with a local price in a sorted list, or {}.
static func best(list: Array) -> Dictionary:
	return list[0] if not list.is_empty() and list[0].get("price") != null else {}
