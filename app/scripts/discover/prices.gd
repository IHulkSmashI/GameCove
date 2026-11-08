extends RefCounted
## Builds the contract's Deal dicts from CheapShark offers and Steam store data,
## and merges one game's prices across stores. Static only.
##
## Linking rule (CheapShark's terms): a Deal built from CheapShark data opens
## CheapShark's redirect URL, even when the store is Steam. A Deal built from
## Steam's own store data opens steam://store/<appid> in the Steam client. When
## both exist for one game, prices_for() keeps Steam's own row and drops
## CheapShark's Steam row, so nothing from CheapShark is opened around its
## redirect.

const CheapShark := preload("res://scripts/discover/cheapshark.gd")
const Money := preload("res://scripts/discover/money.gd")
const Wish := preload("res://scripts/discover/wishlist.gd")
const SteamApi := preload("res://scripts/discover/steam_api.gd")

const STEAM_STORE_ID := "1"


## ctx: {"currency": user currency, "fx": ECB doc or {}, "wishlist": key -> true}
static func _finish(deal: Dictionary, ctx: Dictionary) -> Dictionary:
	var user_cur: String = ctx.get("currency", "USD")
	var fx: Dictionary = ctx.get("fx", {})
	deal["user_currency"] = user_cur
	deal["price_user"] = Money.convert(deal["price"], deal["currency"], user_cur, fx)
	deal["regular_user"] = Money.convert(deal["regular_price"], deal["currency"], user_cur, fx)
	deal["converted"] = deal["currency"] != user_cur and deal["price_user"] != null
	if deal["price_text"] == "":
		deal["price_text"] = Money.format(deal["price"], deal["currency"])
	if deal["regular_text"] == "":
		deal["regular_text"] = Money.format(deal["regular_price"], deal["currency"])
	deal["price_user_text"] = Money.format(deal["price_user"], user_cur, deal["converted"])
	deal["on_sale"] = deal["savings_pct"] > 0
	var wkey := Wish.key_for({"steam": deal["appid"]}, deal["title"])
	deal["wishlist_key"] = wkey
	deal["on_wishlist"] = ctx.get("wishlist", {}).has(wkey)
	return deal


static func _is_low(usd_price: Variant, low: Variant) -> bool:
	return usd_price != null and low is Dictionary and float(usd_price) <= float(low.get("price", -1.0)) + 0.005


## A Deal from a CheapShark offer. `stores` is parse_stores(); `low` the game's
## historical low (USD) or null; `steam` the game's Steam store info (regional
## price) or null, used for CheapShark's Steam rows.
static func from_cheapshark(o: Dictionary, stores: Dictionary, ctx: Dictionary, low: Variant = null, steam: Variant = null) -> Dictionary:
	var sid: String = o.get("store_id", "")
	var store: Dictionary = stores.get(sid, {})
	var appid: String = o.get("appid", "")
	var thumb: String = o.get("thumb", "")
	var art := {"cover": "", "hero": "", "header": "", "thumb": thumb}
	if appid != "":
		var fb := SteamApi.fallback_art(appid)
		art.merge({"cover": fb["cover"], "hero": fb["hero"], "header": fb["header"]}, true)
	var deal := {
		"key": "cheapshark:" + str(o.get("deal_id", "")), "source": "cheapshark",
		"store": "steam" if sid == STEAM_STORE_ID else "cs:" + sid,
		"store_name": store.get("name", "Steam" if sid == STEAM_STORE_ID else "Store " + sid),
		"store_icon": store.get("icon", ""),
		"title": o.get("title", ""), "appid": appid, "game_id": o.get("game_id", ""),
		"price": float(o.get("price", 0.0)), "regular_price": float(o.get("regular_price", 0.0)),
		"currency": CheapShark.CURRENCY, "price_text": "", "regular_text": "",
		"savings_pct": int(o.get("savings_pct", 0)),
		"is_historical_low": _is_low(o.get("price"), low), "historical_low": low,
		"sale_ends_at": null, "rating": o.get("rating", null), "art": art,
		"link": {"kind": "url", "uri": CheapShark.redirect_url(str(o.get("deal_id", "")))},
	}
	if sid == STEAM_STORE_ID and steam is Dictionary and steam.get("price") != null:
		# Same Steam offer, priced in the user's region by Steam itself.
		deal["price"] = steam["price"]
		deal["regular_price"] = steam["regular_price"]
		deal["currency"] = ctx.get("steam_currency", ctx.get("currency", "USD"))
		deal["price_text"] = steam.get("price_text", "")
		deal["regular_text"] = steam.get("regular_text", "")
		deal["savings_pct"] = int(steam.get("savings_pct", 0))
		deal["sale_ends_at"] = steam.get("sale_ends_at", null)
	if steam is Dictionary and steam.get("art") is Dictionary:
		for k in steam["art"]:
			if art.has(k) and str(steam["art"][k]) != "":
				art[k] = steam["art"][k]
	return _finish(deal, ctx)


## A Deal from Steam's own store data (GetItems), or {} when it has no price.
## `usd_price` is CheapShark's Steam USD price if known, for the historical low.
static func from_steam(info: Dictionary, ctx: Dictionary, low: Variant = null, usd_price: Variant = null) -> Dictionary:
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
	var deal := {
		"key": "steam:" + appid, "source": "steam", "store": "steam", "store_name": "Steam", "store_icon": "",
		"title": info.get("title", ""), "appid": appid, "game_id": "",
		"price": info["price"], "regular_price": info.get("regular_price", info["price"]),
		"currency": ctx.get("steam_currency", ctx.get("currency", "USD")),
		"price_text": info.get("price_text", ""), "regular_text": info.get("regular_text", ""),
		"savings_pct": int(info.get("savings_pct", 0)),
		"is_historical_low": int(info.get("savings_pct", 0)) > 0 and _is_low(usd_price, low),
		"historical_low": low, "sale_ends_at": info.get("sale_ends_at", null), "rating": null, "art": art,
		"link": {"kind": "steam", "uri": SteamApi.store_uri(appid)},
	}
	return _finish(deal, ctx)


## Every store's price for one game, cheapest first (in the user's currency;
## prices that can't be converted go last). `lookup` is one entry of
## CheapShark.parse_lookup() or {}; `steam` the game's Steam info or null.
static func prices_for(lookup: Dictionary, steam: Variant, stores: Dictionary, ctx: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var low = lookup.get("historical_low", null)
	var steam_usd = null
	for o in lookup.get("offers", []):
		if o.get("store_id") == STEAM_STORE_ID:
			steam_usd = o.get("price")
	var steam_deal := from_steam(steam, ctx, low, steam_usd) if steam is Dictionary else {}
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
		var pa = a.get("price_user")
		var pb = b.get("price_user")
		if (pa == null) != (pb == null):
			return pa != null
		if pa != null and not is_equal_approx(float(pa), float(pb)):
			return float(pa) < float(pb)
		if a["savings_pct"] != b["savings_pct"]:
			return a["savings_pct"] > b["savings_pct"]
		return a["store_name"] < b["store_name"])


## The cheapest comparable Deal of a sorted list, or {}.
static func best(list: Array) -> Dictionary:
	return list[0] if not list.is_empty() else {}
