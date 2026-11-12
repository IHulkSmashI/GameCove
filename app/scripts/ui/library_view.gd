extends RefCounted
## Pure functions that turn Library.games into what the home screen shows.
## No nodes, no services: easy to test.

## [store id, button label]. "" means every store.
const STORES := [["", "All"], ["steam", "Steam"], ["epic", "Epic"], ["gog", "GOG"], ["amazon", "Amazon"]]
## "stream": apps streamed from a PC (Stream tab), not a store of the Library.
## "app": desktop apps (scripts/library/apps.gd), not a store of the Library either.
const STORE_NAMES := {"steam": "Steam", "epic": "Epic Games", "gog": "GOG", "amazon": "Amazon", "stream": "PC", "app": "App", "emu": "Emulation"}
const RECENT_MAX := 12


static func store_name(store: String) -> String:
	return STORE_NAMES.get(store, store.capitalize())


## What a game's store line says: the store, or an emulated game's console ("SNES").
static func store_label(g: Dictionary) -> String:
	var sys := system_of(g)
	if sys != "":
		return str(g["emulated"].get("system_short", sys))
	return store_name(String(g.get("store", "")))


## ---- ordering a big list cheaply (20,000 ROMs): Library.games arrives sorted by title, so a list is
## checked for that first (one pass) and only sorted when it is not; every other order is a STABLE sort on
## top of the title order, done as one native sort of ints (the number to order by, then the position),
## so ties keep their title order and no Callable runs per comparison.

## The largest list the int sort below can place (21 bits of position).
const _POS_BITS := 21
const _POS_MASK := (1 << 21) - 1
## Order numbers must stay under this (the rest of an int64 after the position bits, with room).
const _ORDER_MAX := (1 << 40) - 1


## True when `list` is already in title_order (an empty or one-game list is).
static func title_sorted(list: Array) -> bool:
	var prev := ""
	var first := true
	for g in list:
		var t := String(g.get("title", ""))
		if not first and prev.naturalnocasecmp_to(t) > 0:
			return false
		prev = t
		first = false
	return true


## `list` in title order: itself when it already is (never copied: callers don't change it), else a sorted copy.
static func by_title(list: Array) -> Array:
	if title_sorted(list):
		return list
	var out := list.duplicate()
	out.sort_custom(title_order)
	return out


## stable_sorted() on a whole-number field of the games, no Callable per game: newest / most first when `desc`.
static func sorted_by_field(base: Array, field: String, desc := true) -> Array:
	var n := base.size()
	if n >= _POS_MASK:
		return stable_sorted(base, func(g): return (_ORDER_MAX - int(g.get(field, 0))) if desc else int(g.get(field, 0)))
	var keys := PackedInt64Array()
	keys.resize(n)
	for i in n:
		var v := clampi(int(base[i].get(field, 0)), 0, _ORDER_MAX)
		keys[i] = ((_ORDER_MAX - v if desc else v) << _POS_BITS) | i
	keys.sort()
	var out: Array = []
	out.resize(n)
	for i in n:
		out[i] = base[int(keys[i]) & _POS_MASK]
	return out


## A sorted copy of `base`: ascending `order` (a Callable giving a whole number >= 0), ties in the order
## `base` already has.
static func stable_sorted(base: Array, order: Callable) -> Array:
	var n := base.size()
	if n >= _POS_MASK:
		var slow := base.duplicate()
		slow.sort_custom(func(a, b): return int(order.call(a)) < int(order.call(b)))
		return slow
	var keys := PackedInt64Array()
	keys.resize(n)
	for i in n:
		keys[i] = (clampi(int(order.call(base[i])), 0, _ORDER_MAX) << _POS_BITS) | i
	keys.sort()
	var out: Array = []
	out.resize(n)
	for i in n:
		out[i] = base[int(keys[i]) & _POS_MASK]
	return out


static func filter_by_store(games: Array, store: String) -> Array:
	if store == "":
		return games.duplicate()
	return games.filter(func(g): return g.get("store", "") == store)


static func installed(games: Array) -> Array:
	return games.filter(func(g): return g.get("installed", false))


## Played games only, newest first; ties keep title order.
static func recently_played(games: Array, limit := RECENT_MAX) -> Array:
	var played := games.filter(func(g): return int(g.get("last_played", 0)) > 0)
	# ties by title: a stable sort over the title order (a few thousand played ROMs is no cost)
	return sorted_by_field(by_title(played), "last_played").slice(0, limit)


## The "Continue" hero: most recently played installed game, else the first
## installed game, else {} (empty library).
static func continue_game(all_games: Array) -> Dictionary:
	var games := not_hidden(all_games)
	return continue_game_of(games, installed(games))


## continue_game() for `games` (no hidden ones) and their installed ones, already worked out.
static func continue_game_of(_games: Array, inst: Array) -> Dictionary:
	var recent := recently_played(inst, 1)
	if not recent.is_empty():
		return recent[0]
	return inst[0] if not inst.is_empty() else {}


# ------------------------------------------------------------ favourites, hidden, collections

## The library views the filter sheet picks: "" every game you haven't hidden,
## "favourites", "hidden" (only those), "emulation" (store "emu"),
## "emulation:<system>" (one console's games), "collection:<id>". Reads the
## fields Collections.decorate() adds.
const VIEWS := ["", "favourites", "emulation", "hidden"]


static func not_hidden(games: Array) -> Array:
	return games.filter(func(g): return not g.get("hidden", false))


static func favourites(games: Array) -> Array:
	return by_title(games.filter(func(g): return g.get("favourite", false) and not g.get("hidden", false)))


static func filter_view(games: Array, view: String) -> Array:
	match view:
		"":
			return not_hidden(games)
		"favourites":
			return games.filter(func(g): return g.get("favourite", false) and not g.get("hidden", false))
		"hidden":
			return games.filter(func(g): return g.get("hidden", false))
		"emulation":
			return games.filter(func(g): return g.get("store", "") == "emu" and not g.get("hidden", false))
	if view.begins_with("emulation:"):
		var sys := view.substr(10)
		return games.filter(func(g): return system_of(g) == sys and not g.get("hidden", false))
	if view.begins_with("collection:"):
		var id := view.substr(11)
		return games.filter(func(g): return id in g.get("collections", []) and not g.get("hidden", false))
	return not_hidden(games)


## Emulated games and the frontend for the Home shelf: ES-DE / RetroDECK
## first, then what you played last, then the rest A to Z (Home shows the first
## Home.SHELF_MAX and See all).


static func emulation_shelf(games: Array) -> Array:
	return _emulation_ordered(by_title(games.filter(func(g): return g.get("store", "") == "emu")))


## The emulated games (in title order) as Home shows them: the frontend first, then newest played.
static func _emulation_ordered(emu: Array) -> Array:
	var front := emu.filter(func(g): return str(g.get("id", "")) == "frontend")
	var rest := emu if front.is_empty() else emu.filter(func(g): return str(g.get("id", "")) != "frontend")
	return sorted_by_field(front, "last_played") + sorted_by_field(rest, "last_played")


## The console an emulated game is for ("" for anything else, ES-DE itself included).
static func system_of(g: Dictionary) -> String:
	var e: Variant = g.get("emulated")
	return str(e.get("system", "")) if e is Dictionary and g.get("store", "") == "emu" else ""


## Consoles with games you haven't hidden: [{"id", "name", "short", "count"}], most games first.
static func systems_in(games: Array) -> Array:
	var by := {}
	for g in games:
		var sys := system_of(g)
		if sys == "" or g.get("hidden", false):
			continue
		if not by.has(sys):
			var e: Dictionary = g["emulated"]
			by[sys] = {"id": sys, "name": str(e.get("system_name", sys)), "short": str(e.get("system_short", sys)), "count": 0}
		by[sys]["count"] += 1
	var out := by.values()
	out.sort_custom(func(a, b): return a["count"] > b["count"] if a["count"] != b["count"] else String(a["name"]).naturalnocasecmp_to(b["name"]) < 0)
	return out


static func find_by_key(games: Array, key: String) -> Dictionary:
	for g in games:
		if g.get("key", "") == key:
			return g
	return {}


# ------------------------------------------------------------ shelves, sort, search

## Short games: main story at most this many hours.
const SHORT_MAX_H := 10.0
const SORTS := ["recent", "az", "playtime", "ttb", "critic"]
const SORT_NAMES := {"recent": "Recent", "az": "A to Z", "playtime": "Most played", "ttb": "Shortest first", "critic": "Top rated"}
## The critic filter keeps games scored at least this (Metacritic's green band).
const CRITIC_MIN := 75


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
	return stable_sorted(by_title(out), func(g): return int(main_hours(g) * 1000.0))


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
## The "Continue" game owns the spotlight, so Recently played and Installed
## both start after it. Installed lists every other installed game, newest
## install first: a game you played recently is still installed, and leaving
## it out made holes in the row and counts that didn't add up.


## Tiles a Home shelf shows at once (7 and the faded eighth).
const SHELF_VISIBLE := 8


static func shelves(all_games: Array) -> Array:
	# Hidden games stay out of Home (the Library's filter sheet shows them). `games` is in title order (checked
	# once, sorted only when it is not), and ONE pass sorts every game into the shelves it belongs to: each shelf
	# then needs no pass or sort of its own over thousands of ROMs (20,000 took 1.1 s, now about a twentieth).
	var games := by_title(not_hidden(all_games))
	var inst_all: Array = []
	var played_inst: Array = []
	var played: Array = []
	var favs: Array = []
	var emu: Array = []
	var short: Array = []
	var ac: Array = []
	var by_store := {}
	for g in games:
		var st := str(g.get("store", ""))
		if not by_store.has(st):
			by_store[st] = []
		by_store[st].append(g)
		var is_inst: bool = g.get("installed", false)
		if is_inst:
			inst_all.append(g)
		if int(g.get("last_played", 0)) > 0:
			played.append(g)
			if is_inst:
				played_inst.append(g)
		if g.get("favourite", false):
			favs.append(g)
		var info: Variant = g.get("info")
		if info is Dictionary:
			if info.get("time_to_beat") is Dictionary:
				var h := main_hours(g)
				if h > 0.0 and h <= SHORT_MAX_H:
					short.append(g)
			var a: Variant = info.get("anticheat")
			if a is Dictionary and a.get("status", "") == "works":
				ac.append(g)
	emu = by_store.get("emu", [])
	var out: Array = []
	var add := func(id: String, title: String, list: Array):
		if not list.is_empty():
			out.append({"id": id, "title": title, "games": list})
	var hero := {}
	if not played_inst.is_empty():
		hero = sorted_by_field(played_inst, "last_played")[0]
	elif not inst_all.is_empty():
		hero = inst_all[0]
	var hero_key := str(hero.get("key", ""))
	var recent := sorted_by_field(played, "last_played").slice(0, RECENT_MAX).filter(func(g): return str(g.get("key", "")) != hero_key)
	add.call("recent", "Recently played", recent)
	add.call("favourites", "Favourites", favs)
	var inst := sorted_by_field(inst_all.filter(func(g): return str(g.get("key", "")) != hero_key) if hero_key != "" else inst_all, "added")
	# The first slots of Installed don't repeat the posters Recently played
	# shows right above: those games move to the end of the shelf (still there).
	var on_screen := {}
	for g in recent.slice(0, SHELF_VISIBLE):
		on_screen[str(g.get("key", ""))] = true
	if not on_screen.is_empty():
		inst = inst.filter(func(g): return not on_screen.has(str(g.get("key", "")))) + inst.filter(func(g): return on_screen.has(str(g.get("key", ""))))
	add.call("installed", "Installed", inst)
	add.call("emulation", "Emulation", _emulation_ordered(emu))
	add.call("short", "Short games, under %d h" % int(SHORT_MAX_H), stable_sorted(short, func(g): return int(main_hours(g) * 1000.0)))
	add.call("anticheat", "Anti-cheat friendly", ac)
	var present: Array = []
	for s in STORES:
		if s[0] != "" and by_store.has(s[0]):
			present.append(s[0])
	if present.size() > 1:
		for st in present:
			add.call("store_" + st, store_name(st), by_store[st])
	add.call("all", "All games", games.duplicate())
	return out


## Sorted copy. recent: last played (never played at the end, by title);
## az: title; playtime: most minutes first; ttb: shortest main story first
## (unknown at the end).
static func sort_games(games: Array, mode: String) -> Array:
	var base := by_title(games)
	match mode:
		"az":
			return base.duplicate()
		"playtime":
			return sorted_by_field(base, "playtime_min")
		"critic":
			return stable_sorted(base, func(g): return 1000 - critic_score(g))
		"ttb":
			# games with a known length first, shortest first; the rest after, by title
			return stable_sorted(base, func(g):
				var h := main_hours(g)
				return int(h * 100.0) if h > 0.0 else (1 << 36) + int(h * 100.0) + 1000)
	return sorted_by_field(base, "last_played")


## One critic score for a game (Metacritic, else OpenCritic, else IGDB's critics), -1 if none.
static func critic_score(g: Dictionary) -> int:
	var info: Variant = g.get("info")
	if not info is Dictionary or info.get("meta") == null:
		return -1   # a ROM or a game with no details yet: nothing to look up
	return preload("res://scripts/library/meta/metadata.gd").critic_score(info.get("meta"))


static func genres(g: Dictionary) -> Array:
	var info: Variant = g.get("info")
	if not info is Dictionary or info.get("meta") == null:
		return []
	return preload("res://scripts/library/meta/metadata.gd").genres_of(info.get("meta"))


## Genres present in `games`, most common first (ties A to Z), at most `limit`.
static func top_genres(games: Array, limit := 10) -> Array:
	var n := {}
	for g in games:
		for x in genres(g):
			n[x] = int(n.get(x, 0)) + 1
	var out := n.keys()
	out.sort_custom(func(a, b): return n[a] > n[b] if n[a] != n[b] else String(a).naturalnocasecmp_to(b) < 0)
	return out.slice(0, limit)


## Games of a genre ("" keeps all) and, with `critic_min` > 0, scored at least that.
static func filter_meta(games: Array, genre: String, critic_min := 0) -> Array:
	return games.filter(func(g):
		return (genre == "" or genre in genres(g)) and (critic_min <= 0 or critic_score(g) >= critic_min))


## Case- and accent-insensitive title search. Every word of the query must
## start a word of the title ("wit 3" finds "The Witcher 3"), or the query
## appears anywhere in the title.
static func search(games: Array, query: String) -> Array:
	var q := fold(query)
	if q == "":
		return games.duplicate()
	var words := q.split(" ", false)
	return games.filter(func(g):
		var t := folded(String(g.get("title", "")))
		if t.contains(q):
			return true
		var tw := Array(t.split(" ", false))
		for w in words:
			if not tw.any(func(x): return x.begins_with(w)):
				return false
		return true)


const FOLD_CACHE_MAX := 100000
static var _fold_cache := {}


## fold() of a title, kept: the search re-reads every title on every key, and folding 20k titles each time was
## the cost (a title folds once; the list is a few MB at most).
static func folded(title: String) -> String:
	var f: Variant = _fold_cache.get(title)
	if f == null:
		if _fold_cache.size() >= FOLD_CACHE_MAX:
			_fold_cache.clear()
		f = fold(title)
		_fold_cache[title] = f
	return f


## True for a character that is punctuation, a symbol or a space in any script (so it separates words); every
## other character above ASCII is a letter of some script and is kept, so Japanese, Korean, Cyrillic and Greek
## titles can be searched too.
static func _is_separator(cp: int) -> bool:
	return (cp >= 0x80 and cp <= 0xBF) or cp == 0xD7 or cp == 0xF7 \
		or (cp >= 0x2000 and cp <= 0x2BFF) or (cp >= 0x3000 and cp <= 0x3004) \
		or (cp >= 0x3008 and cp <= 0x3020) or cp == 0x30FB \
		or (cp >= 0xFF01 and cp <= 0xFF0F) or (cp >= 0xFF1A and cp <= 0xFF20) \
		or (cp >= 0xFF3B and cp <= 0xFF40) or (cp >= 0xFF5B and cp <= 0xFF65) \
		or (cp >= 0xFE30 and cp <= 0xFE6F)


## Lower case, accents dropped, punctuation turned into spaces. Letters of other scripts stay as they are.
static func fold(s: String) -> String:
	var src := "àáâãäåèéêëìíîïòóôõöùúûüýÿñç"
	var dst := "aaaaaaeeeeiiiiooooouuuuyync"
	var out := ""
	for ch in s.to_lower():
		var i := src.find(ch)
		if i >= 0:
			out += dst[i]
		elif ch == "ß":
			out += "ss"
		elif ch == "æ":
			out += "ae"
		elif ch == "ø":
			out += "o"
		elif ch == "œ":
			out += "oe"
		elif (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			out += ch
		elif ch.unicode_at(0) >= 0x80 and not _is_separator(ch.unicode_at(0)):
			out += ch
		else:
			out += " "
	return " ".join(out.split(" ", false))


## Games added (installed) in the last `days` days that the user hasn't seen.
static func newly_added(games: Array, now: int, days := 14) -> Array:
	return games.filter(func(g):
		var a := int(g.get("added", 0))
		return a > 0 and g.get("installed", false) and now - a < days * 86400)
