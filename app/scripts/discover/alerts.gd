extends RefCounted
## When a wishlist item deserves a price or release alert. Static and pure: the
## caller passes the item, what we know now and the `seen` map (persisted in
## user://discover/state.json) and gets back the alert to emit, or {}.
##
## Once-only rules:
## - Price, with a target: fires when the best price is at or below the target
##   and lower than the price we last alerted for. Once the price goes back
##   above the target the memory is cleared, so the next sale alerts again.
## - Price, "any drop" (no target): fires when the best deal is on sale and
##   lower than the last alerted price; cleared when the sale ends.
## - Release: fires once when a "notify me" game comes out (Steam says it's
##   released, or its day-precision date has arrived).
## Prices are the stores' own prices for the user's country (deal.price.amount);
## a "See price" deal (no local price) never alerts.


## seen["price:<key>"] = last alerted price; seen["release:<key>"] = unix time.
static func check_price(item: Dictionary, deal: Dictionary, seen: Dictionary) -> Dictionary:
	var skey: String = "price:" + str(item.get("key", ""))
	if not item.get("notify_price", true) or deal.is_empty() or not deal.get("price") is Dictionary:
		return {}
	var price := float(deal["price"]["amount"])
	var target = item.get("target_price", null)
	var qualifies: bool
	if target != null:
		qualifies = price <= float(target) + 0.0001
	else:
		qualifies = int(deal.get("savings_pct", 0)) > 0
	if not qualifies:
		seen.erase(skey)
		return {}
	if seen.has(skey) and price >= float(seen[skey]) - 0.0001:
		return {}
	seen[skey] = price
	return {"id": "%s:%d" % [skey, int(round(price * 100))], "kind": "price", "key": item["key"],
		"title": item.get("title", ""), "amount": price, "currency": deal["price"].get("currency", ""),
		"target_price": target}


## `release` is the item's release state: {"released": bool, ...} or {}.
static func check_release(item: Dictionary, release: Dictionary, seen: Dictionary, now: int) -> Dictionary:
	var skey: String = "release:" + str(item.get("key", ""))
	if not item.get("notify_release", false) or release.is_empty() or seen.has(skey):
		return {}
	if not release.get("released", false):
		return {}
	seen[skey] = now
	return {"id": skey, "kind": "release", "key": item["key"], "title": item.get("title", "")}
