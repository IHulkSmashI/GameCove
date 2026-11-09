extends RefCounted
## Pure functions that turn Library.games into what the home screen shows.
## No nodes, no services: easy to test.

## [store id, button label]. "" means every store.
const STORES := [["", "All"], ["steam", "Steam"], ["epic", "Epic"], ["gog", "GOG"], ["amazon", "Amazon"]]
## "stream": apps streamed from a PC (Stream tab), not a store of the Library.
const STORE_NAMES := {"steam": "Steam", "epic": "Epic Games", "gog": "GOG", "amazon": "Amazon", "stream": "PC"}
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


# ------------------------------------------------------------ shelves, sort, search

## Short games: main story at most this many hours.
const SHORT_MAX_H := 10.0
const SORTS := ["recent", "az", "playtime", "ttb"]
const SORT_NAMES := {"recent": "Recent", "az": "A to Z", "playtime": "Most played", "ttb": "Shortest first"}


static func title_order(a: Dictionary, b: Dictionary) -> bool:
	return String(a.get("title", "")).naturalnocasecmp_to(b.get("title", "")) < 0


static func main_hours(g: Dictionary) -> float:
	var info: Variant = g.get("info", {})
	if not info is Dictionary:
		return -1.0
	var t: Variant = info.get("time_to_beat")
	if not t is Dictionary:
		return -1.0
	for k in ["main_h", "extra_h", "complete_h"]:
		if t.get(k) != null and float(t[k]) > 0.0:
			return float(t[k])
	return -1.0


## Games you can finish in an evening or a weekend, shortest first.
static func short_games(games: Array, max_h := SHORT_MAX_H) -> Array:
	var out := games.filter(func(g):
		var h := main_hours(g)
		return h > 0.0 and h <= max_h)
	out.sort_custom(func(a, b):
		var ha := main_hours(a)
		var hb := main_hours(b)
		return ha < hb if ha != hb else title_order(a, b))
	return out


## Online games whose anti-cheat is known to work on Linux.
static func anticheat_friendly(games: Array) -> Array:
	return games.filter(func(g):
		var info: Variant = g.get("info", {})
		var a: Variant = info.get("anticheat") if info is Dictionary else null
		return a is Dictionary and a.get("status", "") == "works")


## Store ids that have at least one game, in STORES order.
static func stores_present(games: Array) -> Array:
	var out: Array = []
	for s in STORES:
		if s[0] != "" and games.any(func(g): return g.get("store", "") == s[0]):
			out.append(s[0])
	return out


## The home screen's shelves: [{"id", "title", "games"}], empty ones left out.
## Store shelves only when games come from more than one store.
## Home's rows never repeat each other on the first screen: the "Continue"
## game owns the spotlight, so Recently played starts after it, and Installed
## leaves out what the first RECENT_VISIBLE recent tiles already show, newest
## install first.
const RECENT_VISIBLE := 7


static func shelves(games: Array) -> Array:
	var out: Array = []
	var add := func(id: String, title: String, list: Array):
		if not list.is_empty():
			out.append({"id": id, "title": title, "games": list})
	var hero_key := str(continue_game(games).get("key", ""))
	var recent := recently_played(games).filter(func(g): return str(g.get("key", "")) != hero_key)
	add.call("recent", "Recently played", recent)
	var seen := {hero_key: true}
	for g in recent.slice(0, RECENT_VISIBLE):
		seen[str(g.get("key", ""))] = true
	var inst := installed(games).filter(func(g): return not seen.has(str(g.get("key", ""))))
	inst.sort_custom(func(a, b):
		var aa := int(a.get("added", 0))
		var ab := int(b.get("added", 0))
		return aa > ab if aa != ab else title_order(a, b))
	add.call("installed", "Installed", inst)
	add.call("short", "Short games, under %d h" % int(SHORT_MAX_H), short_games(games))
	var ac := anticheat_friendly(games)
	ac.sort_custom(title_order)
	add.call("anticheat", "Anti-cheat friendly", ac)
	var present := stores_present(games)
	if present.size() > 1:
		for s in present:
			var list := filter_by_store(games, s)
			list.sort_custom(title_order)
			add.call("store_" + s, store_name(s), list)
	var all := games.duplicate()
	all.sort_custom(title_order)
	add.call("all", "All games", all)
	return out


## Sorted copy. recent: last played (never played at the end, by title);
## az: title; playtime: most minutes first; ttb: shortest main story first
## (unknown at the end).
static func sort_games(games: Array, mode: String) -> Array:
	var out := games.duplicate()
	match mode:
		"az":
			out.sort_custom(title_order)
		"playtime":
			out.sort_custom(func(a, b):
				var pa := int(a.get("playtime_min", 0))
				var pb := int(b.get("playtime_min", 0))
				return pa > pb if pa != pb else title_order(a, b))
		"ttb":
			out.sort_custom(func(a, b):
				var ha := main_hours(a)
				var hb := main_hours(b)
				if (ha > 0.0) != (hb > 0.0):
					return ha > 0.0
				return ha < hb if ha != hb else title_order(a, b))
		_:
			out.sort_custom(func(a, b):
				var la := int(a.get("last_played", 0))
				var lb := int(b.get("last_played", 0))
				return la > lb if la != lb else title_order(a, b))
	return out


## Case- and accent-insensitive title search. Every word of the query must
## start a word of the title ("wit 3" finds "The Witcher 3"), or the query
## appears anywhere in the title.
static func search(games: Array, query: String) -> Array:
	var q := fold(query)
	if q == "":
		return games.duplicate()
	var words := q.split(" ", false)
	return games.filter(func(g):
		var t := fold(String(g.get("title", "")))
		if t.contains(q):
			return true
		var tw := Array(t.split(" ", false))
		for w in words:
			if not tw.any(func(x): return x.begins_with(w)):
				return false
		return true)


## Lower case, accents dropped, punctuation turned into spaces.
static func fold(s: String) -> String:
	var src := "àáâãäåèéêëìíîïòóôõöùúûüýÿñç"
	var dst := "aaaaaaeeeeiiiiooooouuuuyync"
	var out := ""
	for ch in s.to_lower():
		var i := src.find(ch)
		if i >= 0:
			out += dst[i]
		elif (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			out += ch
		else:
			out += " "
	return " ".join(out.split(" ", false))


## Games added (installed) in the last `days` days that the user hasn't seen.
static func newly_added(games: Array, now: int, days := 14) -> Array:
	return games.filter(func(g):
		var a := int(g.get("added", 0))
		return a > 0 and g.get("installed", false) and now - a < days * 86400)
