extends RefCounted
## Pure functions that turn Library.games into what the home screen shows.
## No nodes, no services: easy to test.

## [store id, button label]. "" means every store.
const STORES := [["", "All"], ["steam", "Steam"], ["epic", "Epic"], ["gog", "GOG"], ["amazon", "Amazon"]]
const STORE_NAMES := {"steam": "Steam", "epic": "Epic Games", "gog": "GOG", "amazon": "Amazon"}
const RECENT_MAX := 12


static func store_name(store: String) -> String:
	return STORE_NAMES.get(store, store.capitalize())


static func filter_by_store(games: Array, store: String) -> Array:
	if store == "":
		return games.duplicate()
	return games.filter(func(g): return g.get("store", "") == store)


static func installed(games: Array) -> Array:
	return games.filter(func(g): return g.get("installed", false))


## Played games only, newest first; ties keep title order.
static func recently_played(games: Array, limit := RECENT_MAX) -> Array:
	var out := games.filter(func(g): return int(g.get("last_played", 0)) > 0)
	out.sort_custom(func(a, b):
		var la := int(a["last_played"])
		var lb := int(b["last_played"])
		if la != lb:
			return la > lb
		return String(a.get("title", "")).naturalnocasecmp_to(b.get("title", "")) < 0)
	return out.slice(0, limit)


## The "Continue" hero: most recently played installed game, else the first
## installed game, else {} (empty library).
static func continue_game(games: Array) -> Dictionary:
	var recent := recently_played(installed(games), 1)
	if not recent.is_empty():
		return recent[0]
	var inst := installed(games)
	return inst[0] if not inst.is_empty() else {}


static func find_by_key(games: Array, key: String) -> Dictionary:
	for g in games:
		if g.get("key", "") == key:
			return g
	return {}
