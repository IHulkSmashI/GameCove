extends RefCounted
## Pure logic behind the Discover screens: turns Discover's deals, releases
## and wishlist items into "views" the design-system components understand
## (game-like dicts for tiles, headers and the page template), and does the
## filtering, sorting, grouping and picking. No nodes, no I/O: easy to test.
##
## A view:
##   {"key": stable game key ("steam:<appid>" when known), "title",
##    "installed": true (store tiles aren't dimmed or marked "Not installed"),
##    "art": {"cover", "hero", "logo"} local paths ("" until Art has them),
##    "art_urls": {...} the source URLs, "appid", "ids",
##    "deal": {"cut": pct} while on sale (sale badge), "wishlisted": bool,
##    "kind": "deal" | "release" | "wish", "data": the Discover dict}

const SORTS := ["best", "discount", "price", "ending", "rating"]


# ---- views -------------------------------------------------------------------

static func art_key(d: Dictionary) -> String:
	var appid := appid_of(d)
	if appid != "":
		return "steam:" + appid
	for k in ["wishlist_key", "key"]:
		var v := str(d.get(k, ""))
		if v != "" and not v.begins_with("cheapshark:"):
			return v
	return "title:" + normal_title(str(d.get("title", "")))


static func appid_of(d: Dictionary) -> String:
	var a := str(d.get("appid", ""))
	if a != "" and a != "0":
		return a
	var ids: Variant = d.get("ids", {})
	if ids is Dictionary and str(ids.get("steam", "")) != "":
		return str(ids["steam"])
	var k := str(d.get("key", ""))
	if k.begins_with("steam:"):
		return k.substr(6)
	return ""


static func normal_title(t: String) -> String:
	var out := ""
	for ch in t.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			out += ch
	return out


static func _urls(d: Dictionary) -> Dictionary:
	var a: Variant = d.get("art", {})
	var out := {"cover": "", "hero": "", "logo": "", "header": ""}
	if a is Dictionary:
		for k in out:
			out[k] = str(a.get(k, ""))
	return out


static func _base(d: Dictionary, kind: String) -> Dictionary:
	var title := str(d.get("title", ""))
	if title == "":
		title = "Untitled game"
	return {
		"key": art_key(d), "title": title, "installed": true,
		"art": {"cover": "", "hero": "", "logo": ""}, "art_urls": _urls(d),
		"appid": appid_of(d), "ids": d.get("ids", {}) if d.get("ids") is Dictionary else {},
		"wishlisted": bool(d.get("on_wishlist", false)), "kind": kind, "data": d,
	}


static func deal_view(deal: Dictionary) -> Dictionary:
	var v := _base(deal, "deal")
	var pct := int(deal.get("savings_pct", 0))
	if deal.get("on_sale", false) and pct > 0:
		v["deal"] = {"cut": pct}
	return v


static func release_view(rel: Dictionary) -> Dictionary:
	return _base(rel, "release")


static func wish_view(item: Dictionary) -> Dictionary:
	var v := _base(item, "wish")
	v["wishlisted"] = true
	var pct := int(item.get("savings_pct", 0))
	if item.get("on_sale", false) and pct > 0:
		v["deal"] = {"cut": pct}
	if (v["art_urls"]["cover"] == "") and item.get("best_deal") is Dictionary:
		var bd: Dictionary = item["best_deal"]
		if not bd.is_empty():
			v["art_urls"] = _urls(bd)
	return v


# ---- deals -------------------------------------------------------------------

static func is_free(deal: Dictionary) -> bool:
	var p: Variant = deal.get("price")
	if p is Dictionary:
		return float(p.get("amount", 1.0)) <= 0.0 and float(p.get("regular", 0.0)) > 0.0
	return int(deal.get("savings_pct", 0)) >= 100


## The Coming soon shelf: only what isn't out yet. A release out today (or
## in the calendar's two-week "Out now" tail) is a released game: it leads
## the spotlight and the calendar, never a shelf named Coming soon.
static func coming_soon(cal: Array) -> Array:
	return cal.filter(func(r): return not r.get("released", false) and (r.get("days_until") == null or int(r["days_until"]) > 0))


static func free_now(deals: Array) -> Array:
	return deals.filter(func(d): return is_free(d))


## Key-shop rows only when the user turned them on.
static func visible_deals(deals: Array, keyshops: bool) -> Array:
	return deals.filter(func(d): return keyshops or not d.get("keyshop", false))


## [[store id, store name], ...] in first-seen order, "All stores" first.
static func stores_of(deals: Array) -> Array:
	var out: Array = [["", "All stores"]]
	var seen := {}
	for d in deals:
		var id := str(d.get("store", ""))
		if id == "" or seen.has(id):
			continue
		seen[id] = true
		out.append([id, str(d.get("store_name", id))])
	return out


static func has_ratings(deals: Array) -> bool:
	return deals.any(func(d): return d.get("rating") != null)


## Sorts available for this list (no "Top rated" without ratings).
static func sorts_for(deals: Array) -> Array:
	return SORTS.filter(func(s): return s != "rating" or has_ratings(deals))


static func filter_store(deals: Array, store: String) -> Array:
	if store == "":
		return deals.duplicate()
	return deals.filter(func(d): return str(d.get("store", "")) == store)


static func _amount(d: Dictionary) -> float:
	var p: Variant = d.get("price")
	return float(p.get("amount", INF)) if p is Dictionary else INF


## Stable sort; "best" keeps Discover's own order (CheapShark's deal rating).
static func sort_deals(deals: Array, how: String) -> Array:
	var idx := {}
	for i in deals.size():
		idx[deals[i]] = i
	var out := deals.duplicate()
	match how:
		"discount":
			out.sort_custom(func(a, b): return _cmp(-int(a.get("savings_pct", 0)), -int(b.get("savings_pct", 0)), idx[a], idx[b]))
		"price":
			# Rows with a price first, cheapest first; See-price rows after, by discount.
			out.sort_custom(func(a, b):
				var pa := _amount(a)
				var pb := _amount(b)
				if pa != pb:
					return pa < pb
				return _cmp(-int(a.get("savings_pct", 0)), -int(b.get("savings_pct", 0)), idx[a], idx[b]))
		"ending":
			out.sort_custom(func(a, b):
				var ea: float = float(a["sale_ends_at"]) if a.get("sale_ends_at") != null else INF
				var eb: float = float(b["sale_ends_at"]) if b.get("sale_ends_at") != null else INF
				if ea != eb:
					return ea < eb
				return idx[a] < idx[b])
		"rating":
			out.sort_custom(func(a, b):
				var ra: float = float(a["rating"]) if a.get("rating") != null else -1.0
				var rb: float = float(b["rating"]) if b.get("rating") != null else -1.0
				if ra != rb:
					return ra > rb
				return idx[a] < idx[b])
	return out


static func _cmp(a: int, b: int, ia: int, ib: int) -> bool:
	return a < b if a != b else ia < ib


## `views` with every view whose key is in `seen` moved to the end, so the
## first tiles are ones not already on screen (`n`: how many the caller wants
## fresh; a short list keeps the repeats rather than going empty).
static func push_back(views: Array, seen: Dictionary, _n: int) -> Array:
	var fresh: Array = views.filter(func(v): return not seen.has(str(v.get("key", ""))))
	var again: Array = views.filter(func(v): return seen.has(str(v.get("key", ""))))
	return fresh + again


static func on_sale_wishlist(items: Array) -> Array:
	return items.filter(func(i): return i.get("on_sale", false) and i.get("best_deal") is Dictionary and not i["best_deal"].is_empty())


## What the hero shows: a wishlisted game on sale, else the biggest real-price
## deal, else a big release in the next two weeks, else the first deal.
## {"kind": "deal" | "wish" | "release", "data": dict, "line": text key} or {}.
static func pick_hero(deals: Array, wishlist: Array, calendar: Array) -> Dictionary:
	var ws := on_sale_wishlist(wishlist)
	if not ws.is_empty():
		var best: Dictionary = ws[0]
		for i in ws:
			if int(i.get("savings_pct", 0)) > int(best.get("savings_pct", 0)):
				best = i
		return {"kind": "wish", "data": best, "line": "wish_sale"}
	var today := calendar.filter(func(r): return r.get("days_until") != null and int(r["days_until"]) == 0)
	if not today.is_empty():
		return {"kind": "release", "data": today[0], "line": "out_today"}
	var priced := deals.filter(func(d): return d.get("price") is Dictionary and not is_free(d) and appid_of(d) != "")
	if priced.is_empty():
		priced = deals.filter(func(d): return d.get("price") is Dictionary and not is_free(d))
	if not priced.is_empty():
		var best: Dictionary = priced[0]
		for d in priced:
			if int(d.get("savings_pct", 0)) > int(best.get("savings_pct", 0)):
				best = d
		return {"kind": "deal", "data": best, "line": "deal"}
	var soon := calendar.filter(func(r): return r.get("days_until") != null and int(r["days_until"]) > 0 and int(r["days_until"]) <= 14)
	if not soon.is_empty():
		var pick: Dictionary = soon[0]
		for r in soon:
			if r.get("on_wishlist", false):
				pick = r
				break
		return {"kind": "release", "data": pick, "line": "release"}
	if not deals.is_empty():
		return {"kind": "deal", "data": deals[0], "line": "deal"}
	return {}


# ---- calendar ----------------------------------------------------------------

static func ymd(unix: int) -> Dictionary:
	return Time.get_datetime_dict_from_unix_time(unix)


static func days_in_month(year: int, month: int) -> int:
	var next := Time.get_unix_time_from_datetime_dict({"year": year + (1 if month == 12 else 0), "month": 1 if month == 12 else month + 1, "day": 1})
	var first := Time.get_unix_time_from_datetime_dict({"year": year, "month": month, "day": 1})
	return int((next - first) / 86400)


## Which list group a release falls in: out | week | month | later | tba.
static func group_of(rel: Dictionary, now: int) -> String:
	var p := str(rel.get("precision", "tba"))
	if p == "tba" or p == "" or rel.get("date_unix") == null:
		return "tba"
	var du: Variant = rel.get("days_until")
	if du != null and int(du) == 0:
		return "week"          # out today: shown with this week, highlighted
	if rel.get("released", false) or (du != null and int(du) < 0):
		return "out"
	var t := ymd(now)
	if du != null:
		if int(du) <= 6:
			return "week"
		var d := ymd(int(rel["date_unix"]))
		if int(d["year"]) == int(t["year"]) and int(d["month"]) == int(t["month"]):
			return "month"
		return "later"
	if p == "month":
		var d := ymd(int(rel["date_unix"]))
		if int(d["year"]) == int(t["year"]) and int(d["month"]) == int(t["month"]):
			return "month"
	return "later"


## [[group id, [releases]], ...] in display order, empty groups left out.
static func group_calendar(cal: Array, now: int) -> Array:
	var by := {}
	for r in cal:
		var g := group_of(r, now)
		if not by.has(g):
			by[g] = []
		by[g].append(r)
	var out: Array = []
	for g in ["out", "week", "month", "later", "tba"]:
		if by.has(g):
			out.append([g, by[g]])
	return out


## Releases in a month: {"days": {day: [rel]}, "undated": [rel]} (month-precision
## entries for that month go to "undated").
static func month_map(cal: Array, year: int, month: int) -> Dictionary:
	var days := {}
	var undated: Array = []
	for r in cal:
		if r.get("date_unix") == null:
			continue
		var d := ymd(int(r["date_unix"]))
		if int(d["year"]) != year or int(d["month"]) != month:
			continue
		if str(r.get("precision", "")) == "day":
			var day := int(d["day"])
			if not days.has(day):
				days[day] = []
			days[day].append(r)
		elif str(r.get("precision", "")) == "month":
			undated.append(r)
	return {"days": days, "undated": undated}


## Cells of a Monday-first month grid: 0 for padding, else the day number.
static func month_cells(year: int, month: int) -> Array:
	var first := Time.get_unix_time_from_datetime_dict({"year": year, "month": month, "day": 1, "hour": 12})
	var wd := int(ymd(first)["weekday"])            # 0 = Sunday
	var lead := posmod(wd - 1, 7)
	var out: Array = []
	for i in lead:
		out.append(0)
	for d in days_in_month(year, month):
		out.append(d + 1)
	while out.size() % 7 != 0:
		out.append(0)
	return out


static func shift_month(year: int, month: int, by: int) -> Vector2i:
	var m := (year * 12 + (month - 1)) + by
	return Vector2i(int(m / 12.0), posmod(m, 12) + 1)


# ---- wishlist ----------------------------------------------------------------

## Target price choices in the user's currency: null (any sale) plus a few
## round steps under the regular price, the lowest-ever price when known, and
## the current target so it's always selectable. Ascending after null.
static func target_choices(item: Dictionary, currency: String) -> Array:
	var base := 0.0
	var bd: Variant = item.get("best_deal", {})
	if bd is Dictionary and bd.get("price") is Dictionary:
		var p: Dictionary = bd["price"]
		base = maxf(float(p.get("regular", 0.0)), float(p.get("amount", 0.0)))
	if base <= 0.0 and item.get("last_price") != null:
		base = float(item["last_price"])
	var vals := {}
	if base > 0.0:
		for f in [0.75, 0.5, 0.25]:
			var v := _nice(base * f)
			if v > 0.0:
				vals[v] = true
		var h: Variant = item.get("historical_low")
		if h is Dictionary and h.get("amount") != null and str(h.get("currency", "")) == currency:
			vals[snappedf(float(h["amount"]), 0.01)] = true
	if item.get("target_price") != null:
		vals[snappedf(float(item["target_price"]), 0.01)] = true
	var list: Array = vals.keys()
	list.sort()
	return [null] + list


## Round down to a price people type: whole units under 20, else steps of 5.
static func _nice(v: float) -> float:
	if v < 1.0:
		return snappedf(v, 0.01)
	if v < 20.0:
		return floorf(v)
	return floorf(v / 5.0) * 5.0


static func best_price_line(item: Dictionary) -> Dictionary:
	var bd: Variant = item.get("best_deal", {})
	if not bd is Dictionary or bd.is_empty():
		return {}
	return bd


# ---- library -----------------------------------------------------------------

## The library game for a view, or {} if the user doesn't own it.
static func owned_game(v: Dictionary, games: Array) -> Dictionary:
	var appid := str(v.get("appid", ""))
	var nt := normal_title(str(v.get("title", "")))
	for g in games:
		if appid != "" and str(g.get("key", "")) == "steam:" + appid:
			return g
	if nt == "":
		return {}
	for g in games:
		if normal_title(str(g.get("title", ""))) == nt:
			return g
	return {}
