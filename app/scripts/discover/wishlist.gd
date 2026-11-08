extends RefCounted
## Wishlist items: keys, the stored shape, and merging an imported Steam
## wishlist into the local one. Static only; Discover owns the list and saves
## it to user://discover/wishlist.json, so it works offline.

const GameDB := preload("res://scripts/library/gamedb.gd")


## Title key, the same one the game database uses for matching.
static func normalise(title: String) -> String:
	return GameDB.normalise(title)


## "steam:<appid>" when there's a Steam id, else "title:<normalised title>".
static func key_for(ids: Dictionary, title: String) -> String:
	var steam := str(ids.get("steam", ""))
	if steam != "" and steam != "0":
		return "steam:" + steam
	return "title:" + normalise(title)


## The stored item, every field filled. Accepts a partial dict from the UI, a
## Release, a Deal or a search result: title plus any of ids / appid.
static func make_item(src: Dictionary, now: int) -> Dictionary:
	var ids := {}
	if src.get("ids") is Dictionary:
		for k in src["ids"]:
			if str(src["ids"][k]) != "":
				ids[str(k)] = str(src["ids"][k])
	if str(src.get("appid", "")) != "" and not ids.has("steam"):
		ids["steam"] = str(src["appid"])
	if str(src.get("game_id", "")) != "" and not ids.has("cheapshark"):
		ids["cheapshark"] = str(src["game_id"])
	var title := str(src.get("title", "")).strip_edges()
	var art := {"cover": "", "hero": "", "header": ""}
	if src.get("art") is Dictionary:
		for k in src["art"]:
			art[str(k)] = str(src["art"][k])
	var target = src.get("target_price", null)
	return {
		"key": key_for(ids, title),
		"title": title,
		"ids": ids,
		"added": int(src.get("added", now)),
		"source": str(src.get("source", "manual")),
		"target_price": float(target) if target is float or target is int else null,
		"notify_price": bool(src.get("notify_price", true)),
		"notify_release": bool(src.get("notify_release", false)),
		"last_price": src.get("last_price", null) if (src.get("last_price") is float or src.get("last_price") is int) else null,
		"art": art,
	}


## Adds Steam wishlist rows ({"appid", "added"}) to `items` (key -> item) and
## returns how many were new. Existing items keep their settings; titles and
## art come later from Steam's store data (`titles`: appid -> title).
static func merge_steam(items: Dictionary, rows: Array, titles: Dictionary, now: int) -> int:
	var added := 0
	for row in rows:
		var appid := str(row.get("appid", ""))
		if appid == "":
			continue
		var key := "steam:" + appid
		if items.has(key):
			if items[key]["title"] == "" and titles.get(appid, "") != "":
				items[key]["title"] = titles[appid]
			continue
		var added_at := int(row.get("added", 0))
		items[key] = make_item({"title": titles.get(appid, ""), "ids": {"steam": appid},
			"added": added_at if added_at > 0 else now, "source": "steam"}, now)
		added += 1
	return added


## Wishlist items in display order: newest first, then title.
static func sorted(items: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for k in items:
		out.append(items[k])
	out.sort_custom(func(a, b):
		if a["added"] != b["added"]:
			return a["added"] > b["added"]
		return a["title"].naturalnocasecmp_to(b["title"]) < 0)
	return out
