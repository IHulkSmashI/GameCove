extends Node
## Steam insights for one game at a time (the game page's "Steam insights"
## card): players now, review summary, Steam Deck rating, the latest update
## with its notes, DLC with local prices, and the current price with the
## lowest price ever. Sources and terms: insights_api.gd (Steam's public,
## keyless endpoints) and Discover (CheapShark, Steam store prices, GG.deals).
## Never steamdb.info: SteamDB forbids scraping; we only link to it.
##
## view(appid) answers at once from what's cached (memory, then
## user://insights/<appid>.json); request(appid) fetches the parts that are
## stale and emits `changed(appid)` as each one lands. Every request goes
## through `http` (Discover's http.gd: threaded HTTPRequest, timeouts,
## per-host backoff; fake_http.gd in tests), so nothing waits on the network
## and an offline device costs nothing.
##
## Cache: players PLAYERS_TTL (10 min); reviews + Deck, news and the DLC list
## INFO_TTL (12 h); prices with the deals refresh (Discover.REFRESH_EVERY,
## 6 h). A failed part isn't retried for RETRY_S.
##
## Switches (privacy.gd): players, reviews, Deck, news and the DLC list need
## "Background lookups"; prices (current, lowest ever, DLC prices) need "Look
## up deals and prices" (Discover's price_lookups). Off: nothing is sent and
## what's already cached is still shown.

signal changed(appid: String)

const Api := preload("res://scripts/steam/insights_api.gd")
const AppId := preload("res://scripts/steam/app_id.gd")
const SteamApi := preload("res://scripts/discover/steam_api.gd")
const Money := preload("res://scripts/discover/money.gd")
const Wish := preload("res://scripts/discover/wishlist.gd")
const Privacy := preload("res://scripts/system/privacy.gd")

const PLAYERS_TTL := 600
const INFO_TTL := 12 * 3600
const PRICE_TTL := 6 * 3600
const RETRY_S := 300
const MAX_BYTES := 2 * 1024 * 1024
const MAX_DLC := 50
const PARTS := ["players", "store", "news", "dlc", "dlc_prices", "price"]

## http.gd interface (request(url, opts, done)); null = Discover's.
var http: Variant = null
## Discover service (prices, store country); null = the autoload, if any.
var discover: Object = null
var privacy_path := Privacy.PREFS_PATH
var data_dir := "user://insights"
var clock: Callable = func() -> int: return int(Time.get_unix_time_from_system())

var _docs := {}        # appid -> stored doc
var _inflight := {}    # "appid:part" -> true
var _price_wait := {}  # Wish key -> appid, while Discover fetches its prices


func _now() -> int:
	return int(clock.call())


func _discover() -> Object:
	if discover != null:
		return discover
	return get_node_or_null("/root/Discover") if is_inside_tree() else null


## The Discover service prices come from (and links open through), or null.
func discover_node() -> Object:
	return _discover()


func _http() -> Variant:
	if http != null:
		return http
	var d := _discover()
	return d.get("http") if d != null else null


func background_allowed() -> bool:
	return Privacy.background_allowed(privacy_path)


func prices_allowed() -> bool:
	var d := _discover()
	return d != null and d.has_method("prices_allowed") and bool(d.prices_allowed())


# ---- storage ---------------------------------------------------------------------

func _path(appid: String) -> String:
	return data_dir.path_join(appid + ".json")


func _doc(appid: String) -> Dictionary:
	if _docs.has(appid):
		return _docs[appid]
	var doc := {"tried": {}, "status": {}}
	var p := _path(appid)
	if FileAccess.file_exists(p):
		var j := JSON.new()
		if j.parse(FileAccess.get_file_as_string(p)) == OK and j.data is Dictionary:
			doc = j.data
			doc.merge({"tried": {}, "status": {}}, false)
	doc["status"] = {}   # a status is only about this run
	_docs[appid] = doc
	return doc


func _save(appid: String) -> void:
	DirAccess.make_dir_recursive_absolute(data_dir)
	var doc: Dictionary = _docs.get(appid, {}).duplicate()
	doc.erase("status")
	var f := FileAccess.open(_path(appid), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(doc))
		f.close()


# ---- fetching --------------------------------------------------------------------

func _fresh(doc: Dictionary, part: String, ttl: int) -> bool:
	var d = doc.get(part)
	return d is Dictionary and _now() - int(d.get("at", 0)) < ttl


func _may_try(doc: Dictionary, part: String) -> bool:
	return _now() - int(doc["tried"].get(part, 0)) >= RETRY_S


static func _status_of(res: Dictionary) -> String:
	if res.get("ok", false):
		return "ok"
	return "offline" if str(res.get("error", "")) in ["offline", "backoff", "timeout"] else "error"


## Fetches what's stale for this game (players, reviews + Deck, news, DLC,
## prices), each part only when its switch allows it. `force` ignores the
## retry pause after a failure (the user pressed Refresh), never the switches.
func request(appid: String, force := false) -> void:
	if not AppId.valid(appid):
		return
	var doc := _doc(appid)
	if force:
		doc["tried"] = {}
	var net = _http()
	if net != null and background_allowed():
		_get_part(net, appid, "players", PLAYERS_TTL, Api.players_url(appid), func(body) -> Variant:
			var j = Api._json(body)
			return {"value": Api.parse_players(body)} if j is Dictionary and j.get("response") is Dictionary else null)
		_get_part(net, appid, "store", INFO_TTL, Api.store_url([appid]), func(body) -> Variant:
			var j = Api._json(body)
			if not j is Dictionary or not j.get("response") is Dictionary:
				return null
			return Api.parse_store(body).get(appid, {"reviews": {}, "deck": Api.DECK_UNKNOWN, "free": false, "title": ""}))
		_get_part(net, appid, "news", INFO_TTL, Api.news_url(appid), func(body) -> Variant:
			var items = Api.parse_news(body)
			return {"items": items.slice(0, Api.NEWS_COUNT)} if items != null else null)
		_get_part(net, appid, "dlc", INFO_TTL, Api.appdetails_url(appid), func(body) -> Variant:
			var ids = Api.parse_dlc_ids(body, appid)
			return {"ids": ids} if ids != null else null, func(): _request_dlc_prices(appid))
	if _fresh(doc, "dlc", INFO_TTL):
		_request_dlc_prices(appid)
	_request_price(appid)


## One part: skipped while fresh, in flight or resting after a failure.
## `parse(body)` returns the part's dict (stored with "at") or null (bad answer).
func _get_part(net: Variant, appid: String, part: String, ttl: int, url: String, parse: Callable, then := Callable()) -> void:
	var doc := _doc(appid)
	var key := appid + ":" + part
	if _fresh(doc, part, ttl) or _inflight.has(key) or not _may_try(doc, part):
		return
	_inflight[key] = true
	doc["status"][part] = "loading"
	net.request(url, {"max_bytes": MAX_BYTES, "timeout": 15.0}, func(res: Dictionary):
		_inflight.erase(key)
		var got = parse.call(res["body"]) if res["ok"] else null
		if got is Dictionary:
			got["at"] = _now()
			doc[part] = got
			doc["status"][part] = "ok"
			doc["tried"].erase(part)
		else:
			doc["tried"][part] = _now()
			doc["status"][part] = _status_of(res) if not res["ok"] else "error"
		_save(appid)
		changed.emit(appid)
		if got is Dictionary and then.is_valid():
			then.call())


## Names (always) and local prices (with "Look up deals and prices") of the
## first MAX_DLC DLC. Prices are Steam's own for the user's store country;
## with prices off, names come from the neutral review call instead.
func _request_dlc_prices(appid: String) -> void:
	var doc := _doc(appid)
	var ids: Array = doc.get("dlc", {}).get("ids", [])
	var net = _http()
	if ids.is_empty() or net == null:
		return
	var batch := ids.slice(0, MAX_DLC)
	var d := _discover()
	if prices_allowed() and d != null and d.has_method("country"):
		var country: String = d.country()
		var cur: Dictionary = doc.get("dlc_prices", {})
		if _fresh(doc, "dlc_prices", PRICE_TTL) and cur.get("country", "") == country and cur.get("priced", false):
			return
		_get_part(net, appid, "dlc_prices", 0 if cur.get("country", "") != country or not cur.get("priced", false) else PRICE_TTL,
			SteamApi.items_url(batch, country), func(body) -> Variant:
				var info := SteamApi.parse_items(body)
				var j = Api._json(body)
				return {"country": country, "currency": Money.currency_for_country(country), "priced": true,
					"items": _dlc_rows(batch, info)} if j is Dictionary else null)
	elif background_allowed():
		if doc.has("dlc_prices"):
			return   # names known (priced or not); prices stay as they were
		_get_part(net, appid, "dlc_prices", INFO_TTL, Api.store_url(batch), func(body) -> Variant:
			var info := Api.parse_store(body)
			var j = Api._json(body)
			return {"country": "", "currency": "", "priced": false, "items": _dlc_rows(batch, info)} if j is Dictionary else null)


static func _dlc_rows(ids: Array, info: Dictionary) -> Array:
	var rows := []
	for id in ids:
		var it: Dictionary = info.get(str(id), {})
		if it.is_empty() or str(it.get("title", "")) == "":
			continue
		rows.append({"appid": str(id), "title": it["title"], "free": bool(it.get("free", false)),
			"price_text": str(it.get("price_text", "")), "regular_text": str(it.get("regular_text", "")),
			"savings_pct": int(it.get("savings_pct", 0))})
	return rows


## Current price and lowest ever come from Discover (its own caches and
## request_prices, behind "Look up deals and prices"), asked again with the
## deals refresh.
func _request_price(appid: String) -> void:
	var d := _discover()
	if d == null or not prices_allowed() or not d.has_method("request_prices"):
		return
	var doc := _doc(appid)
	var key := Wish.key_for({"steam": appid}, "")
	if _fresh(doc, "price", PRICE_TTL) or _price_wait.has(key) or not _may_try(doc, "price"):
		return
	if not d.prices_ready.is_connected(_on_prices_ready):
		d.prices_ready.connect(_on_prices_ready)
	_price_wait[key] = appid
	doc["status"]["price"] = "loading"
	d.request_prices(appid)


func _on_prices_ready(game_key: String, _deals: Array) -> void:
	if not _price_wait.has(game_key):
		return
	var appid: String = _price_wait[game_key]
	_price_wait.erase(game_key)
	var doc := _doc(appid)
	doc["price"] = {"at": _now()}
	doc["status"]["price"] = "ok"
	_save(appid)
	changed.emit(appid)


# ---- the view --------------------------------------------------------------------

## Everything the card shows for a game, from cache only:
## {"appid", "steamdb", "background", "prices_on",
##  "players": int (-1 unknown), "reviews": {label, percent, count, score} | {},
##  "deck": int (-1 unknown), "news": [{title, date, url, author, body}],
##  "dlc": [{appid, title, free, price_text, regular_text, savings_pct}],
##  "dlc_count": int, "dlc_priced": bool,
##  "price": {"text", "regular_text", "savings_pct", "free"} | {},
##  "low": {"text", "date", "local": bool, "note"} | {},
##  "attributions": [{text, url}], "state": {part: "ok"|"loading"|"offline"|"error"|"off"|"none"},
##  "summary": "loading" | "data" | "offline" | "off"}
func view(appid: String) -> Dictionary:
	var doc := _doc(appid) if AppId.valid(appid) else {"tried": {}, "status": {}}
	var bg := background_allowed()
	var pr := prices_allowed()
	var v := {"appid": appid, "steamdb": Api.steamdb_url(appid), "background": bg, "prices_on": pr,
		"players": -1, "reviews": {}, "deck": -1, "news": [], "dlc": [], "dlc_count": 0, "dlc_priced": false,
		"price": {}, "low": {}, "attributions": [], "state": {}}
	if doc.get("players") is Dictionary:
		v["players"] = int(doc["players"].get("value", -1))
	if doc.get("store") is Dictionary:
		var rv: Dictionary = doc["store"].get("reviews", {}) if doc["store"].get("reviews") is Dictionary else {}
		if not rv.is_empty():   # numbers come back from JSON as floats
			rv = {"label": str(rv.get("label", "")), "percent": int(rv.get("percent", 0)),
				"count": int(rv.get("count", 0)), "score": int(rv.get("score", 0))}
		v["reviews"] = rv
		v["deck"] = int(doc["store"].get("deck", Api.DECK_UNKNOWN))
	if doc.get("news") is Dictionary:
		v["news"] = doc["news"].get("items", [])
	if doc.get("dlc") is Dictionary:
		v["dlc_count"] = doc["dlc"].get("ids", []).size()
	if doc.get("dlc_prices") is Dictionary:
		v["dlc"] = doc["dlc_prices"].get("items", [])
		var d0 := _discover()
		v["dlc_priced"] = pr and bool(doc["dlc_prices"].get("priced", false)) and d0 != null \
			and str(doc["dlc_prices"].get("country", "")) == str(d0.country())
		if not v["dlc_priced"]:
			for row in v["dlc"]:
				row["price_text"] = ""   # another country's, or prices are off
				row["regular_text"] = ""
				row["savings_pct"] = 0
	if pr:
		_fill_price(appid, v)   # off: no prices at all, as in Discover
	for part in ["players", "store", "news", "dlc"]:
		v["state"][part] = _state(doc, part, bg)
	v["state"]["price"] = _state(doc, "price", pr) if pr else "off"
	v["summary"] = _summary(v["state"], doc)
	return v


func _state(doc: Dictionary, part: String, allowed: bool) -> String:
	var s := str(doc["status"].get(part, ""))
	if s != "":
		return s
	if doc.get(part) is Dictionary:
		return "ok"
	return "off" if not allowed else "loading"


static func _summary(state: Dictionary, doc: Dictionary) -> String:
	var any_data := false
	for part in ["players", "store", "news", "dlc"]:
		if doc.get(part) is Dictionary:
			any_data = true
	if any_data:
		return "data"
	var vals := []
	for part in ["players", "store", "news", "dlc"]:
		vals.append(state[part])
	if vals.all(func(s): return s == "off"):
		return "off"
	if vals.has("loading"):
		return "loading"
	return "offline"


## Current Steam price (the user's country) and the lowest ever: GG.deals'
## or CheapShark's when it's in the user's own currency, else CheapShark's US
## price labelled as USD. Never converted, never made up.
func _fill_price(appid: String, v: Dictionary) -> void:
	var d := _discover()
	if d == null or not d.has_method("prices_for"):
		return
	var info: Dictionary = d.steam_info(appid) if d.has_method("steam_info") else {}
	var deals: Array = d.prices_for(appid)
	var steam_deal := {}
	for x in deals:
		if x.get("source") == "steam" and x.get("price") != null:
			steam_deal = x
			break
	if not steam_deal.is_empty():
		var p: Dictionary = steam_deal["price"]
		v["price"] = {"text": str(p.get("text", "")), "regular_text": str(p.get("regular_text", "")),
			"savings_pct": int(steam_deal.get("savings_pct", 0)), "free": false}
	elif bool(info.get("free", false)):
		v["price"] = {"text": "Free to play", "regular_text": "", "savings_pct": 0, "free": true}
	var low = steam_deal.get("historical_low") if not steam_deal.is_empty() else null
	if low == null:
		for x in deals:
			if x.get("historical_low") is Dictionary:
				low = x["historical_low"]
				break
	var cur := str(d.user_currency()) if d.has_method("user_currency") else ""
	if low is Dictionary and str(low.get("currency", "")) == cur and cur != "":
		v["low"] = {"text": Money.format(float(low["amount"]), cur), "date": int(low.get("date", 0)), "local": true, "note": ""}
	elif d.has_method("cheapest_ever"):
		var cs = d.cheapest_ever(appid)
		if cs is Dictionary:
			v["low"] = {"text": Money.format(float(cs["price"]), "USD") + " USD", "date": int(cs.get("date", 0)),
				"local": cur == "USD", "note": "" if cur == "USD" else "US store"}
	if not v["price"].is_empty() or not v["low"].is_empty():
		v["attributions"] = d.attributions() if d.has_method("attributions") else []
