extends RefCounted
## CheapShark (https://apidocs.cheapshark.com/): free, keyless price data for
## Steam and other PC stores. URL builders and parsers only; no network here.
##
## Terms we follow (checked 2026-11-08, see CREDITS.md):
## - Every deal from CheapShark data is opened through CheapShark's redirect
##   page, https://www.cheapshark.com/redirect?dealID=<id>, never a direct or
##   affiliate store link (redirect_url()).
## - A descriptive User-Agent is required (DiscoverHttp sets it).
## - Called in response to the user and a few times per refresh at most; we
##   never crawl a catalogue. 429 answers carry Retry-After, which DiscoverHttp
##   honours.
## - Prices are always USD; dates are unix seconds; flags are "0"/"1".

const JsonField := preload("res://scripts/discover/json_field.gd")

const API := "https://www.cheapshark.com/api/1.0/"
const REDIRECT := "https://www.cheapshark.com/redirect?dealID="
const SITE := "https://www.cheapshark.com"
const CURRENCY := "USD"
const LOOKUP_BATCH := 25


static func deals_url(page_size := 30) -> String:
	return API + "deals?onSale=1&sortBy=Deal%20Rating&pageSize=" + str(clampi(page_size, 1, 60))


## Games that are free to keep right now: on sale at a price of 0 (a store's
## giveaway). Always-free games have no sale, so onSale=1 leaves them out.
static func free_url(page_size := 30) -> String:
	return API + "deals?onSale=1&upperPrice=0&sortBy=Recent&pageSize=" + str(clampi(page_size, 1, 60))


static func search_url(title: String, limit := 20) -> String:
	return API + "games?title=%s&limit=%d" % [title.uri_encode(), clampi(limit, 1, 60)]


static func by_steam_url(appid: String) -> String:
	return API + "games?steamAppID=" + appid.uri_encode()


static func lookup_url(game_ids: Array) -> String:
	var ids := []
	for g in game_ids.slice(0, LOOKUP_BATCH):
		ids.append(str(g).uri_encode())
	return API + "games?ids=" + ",".join(ids)


static func stores_url() -> String:
	return API + "stores"


## The only link a CheapShark deal may be opened with. dealIDs come
## URL-encoded already (they contain %2B and %3D); they're passed through as is.
static func redirect_url(deal_id: String) -> String:
	# only URL-safe characters (they're already %-encoded); anything else = no link
	if deal_id == "" or RegEx.create_from_string("^[A-Za-z0-9%._~-]+$").search(deal_id) == null:
		return ""
	return REDIRECT + deal_id


static func _json(body: Variant) -> Variant:
	var text: String = body.get_string_from_utf8() if body is PackedByteArray else str(body)
	var j := JSON.new()
	return j.data if j.parse(text) == OK else null


static func _f(v: Variant) -> float:
	return float(_s(v)) if _s(v).is_valid_float() else 0.0


## JSON fields read without trusting their type (json_field.gd says why).
static func _i(v: Variant) -> int:
	return JsonField.i(v)


static func _s(v: Variant) -> String:
	return JsonField.s(v)


static func _appid(v: Variant) -> String:
	return "" if _s(v) in ["", "0", "null"] else _s(v)


## /stores -> {"1": {"name": "Steam", "active": true, "icon": url}}.
static func parse_stores(body: Variant) -> Dictionary:
	var d = _json(body)
	var out := {}
	if not d is Array:
		return out
	for s in d:
		if s is Dictionary and s.has("storeID"):
			var icon := ""
			if s.get("images") is Dictionary and _s(s["images"].get("icon")) != "":
				icon = SITE + _s(s["images"]["icon"])
			if _s(s["storeID"]) != "":
				out[_s(s["storeID"])] = {"name": _s(s.get("storeName")), "active": _i(s.get("isActive")) == 1, "icon": icon}
	return out


## /deals -> raw offers [{"deal_id", "store_id", "game_id", "appid", "title",
## "price", "regular_price", "savings_pct", "rating", "thumb", "released"}]
## or null when the body isn't a deals list.
static func parse_deals(body: Variant) -> Variant:
	var d = _json(body)
	if not d is Array:
		return null
	var out: Array[Dictionary] = []
	for x in d:
		if not x is Dictionary or _s(x.get("dealID")) == "":
			continue
		out.append({
			"deal_id": _s(x["dealID"]), "store_id": _s(x.get("storeID")),
			"game_id": _s(x.get("gameID")), "appid": _appid(x.get("steamAppID")),
			"title": _s(x.get("title")).strip_edges(),
			"price": _f(x.get("salePrice")), "regular_price": _f(x.get("normalPrice")),
			"savings_pct": int(round(_f(x.get("savings")))),
			"rating": _f(x.get("dealRating")) if _s(x.get("dealRating")).is_valid_float() else null,
			"thumb": _s(x.get("thumb")), "released": _i(x.get("releaseDate")),
		})
	return out


## /games?title= or ?steamAppID= -> [{"game_id", "appid", "title",
## "cheapest", "cheapest_deal_id", "thumb"}] or null.
static func parse_search(body: Variant) -> Variant:
	var d = _json(body)
	if not d is Array:
		return null
	var out: Array[Dictionary] = []
	for x in d:
		if x is Dictionary and _s(x.get("gameID")) != "":
			out.append({
				"game_id": _s(x["gameID"]), "appid": _appid(x.get("steamAppID")),
				"title": _s(x.get("external")).strip_edges(),
				"cheapest": _f(x.get("cheapest")), "cheapest_deal_id": _s(x.get("cheapestDealID")),
				"thumb": _s(x.get("thumb")),
			})
	return out


static func _lookup_one(game_id: String, x: Dictionary) -> Dictionary:
	var info: Dictionary = x.get("info", {}) if x.get("info") is Dictionary else {}
	var low = null
	if x.get("cheapestPriceEver") is Dictionary:
		var c: Dictionary = x["cheapestPriceEver"]
		low = {"price": _f(c.get("price")), "currency": CURRENCY, "date": _i(c.get("date"))}
	var offers: Array[Dictionary] = []
	for o in JsonField.list(x.get("deals")):
		if o is Dictionary and _s(o.get("dealID")) != "":
			offers.append({
				"deal_id": _s(o["dealID"]), "store_id": _s(o.get("storeID")), "game_id": game_id,
				"appid": _appid(info.get("steamAppID")), "title": _s(info.get("title")),
				"price": _f(o.get("price")), "regular_price": _f(o.get("retailPrice")),
				"savings_pct": int(round(_f(o.get("savings")))), "rating": null,
				"thumb": _s(info.get("thumb")), "released": 0,
			})
	return {"game_id": game_id, "appid": _appid(info.get("steamAppID")), "title": _s(info.get("title")),
		"thumb": _s(info.get("thumb")), "historical_low": low, "offers": offers}


## /games?ids=a,b -> {game_id: {"game_id", "appid", "title", "thumb",
## "historical_low": {"price", "currency", "date"} or null, "offers": [...]}}.
## Also accepts a single /games?id= answer (pass `single_id`).
static func parse_lookup(body: Variant, single_id := "") -> Dictionary:
	var d = _json(body)
	var out := {}
	if not d is Dictionary:
		return out
	if single_id != "" and d.has("deals"):
		out[single_id] = _lookup_one(single_id, d)
		return out
	for gid in d:
		if d[gid] is Dictionary:
			out[str(gid)] = _lookup_one(str(gid), d[gid])
	return out
