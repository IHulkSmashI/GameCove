extends RefCounted
## Game details ("metadata") for every library game, whatever the store: pure
## functions that read each source into one shape and merge them. No nodes,
## no network, safe on any thread.
##
## The merged shape is `info.meta` in docs/CONTRACTS.md ("Game details"):
##   {"summary", "genres", "themes", "modes", "developers", "publishers",
##    "release_date" ("YYYY-MM-DD" or ""), "controller" ("full" | "partial" | ""),
##    "screenshots": [{"thumb", "full"}],
##    "critics": {"metacritic": {"score", "url"} | null,
##                "opencritic": {"score", "percent_recommended", "tier", "url", "count"} | null,
##                "igdb_critic": {"score", "count"} | null},
##    "sources": {field: source id}, "steam_twin": Steam app id used for a non-Steam game or ""}
##
## A layer is {"source": id, "meta": {field: value}, "critics": {...}}. Merging
## fills each field from the first layer that has it, in this order:
##   1. "store"    what the store itself wrote locally (Epic, GOG, Amazon files)
##   2. "steam"    the Steam store details baked into the nightly game database
##   3. "steam"    a live Steam store fetch (appdetails), cached a week
##   4. "igdb"     IGDB's details from the game database
##   5. "wikidata" Wikidata's genres / companies from the game database
## OpenCritic only ever fills critics.opencritic. A non-Steam game uses its
## Steam twin's data (the same game record in the database lists a Steam id).

const LISTS := ["genres", "themes", "modes", "developers", "publishers"]
const TEXTS := ["summary", "release_date", "controller"]
const FIELDS := ["summary", "genres", "themes", "modes", "developers", "publishers", "release_date", "controller", "screenshots"]
const CRITICS := ["metacritic", "opencritic", "igdb_critic"]
const SUMMARY_MAX := 600
const LIST_MAX := 6
const SCREENS_MAX := 8
## Who to credit for each source (the UI shows these next to the data).
const SOURCE_NAMES := {"store": "", "steam": "Steam", "igdb": "IGDB", "wikidata": "Wikidata", "opencritic": "OpenCritic"}
## Image hosts screenshot URLs may point at.
const IMAGE_HOSTS := ["steamstatic.com", "akamaihd.net", "images.igdb.com"]
## Metacritic's own colour bands (score 75+ green, 50-74 yellow, under 50 red).
const MC_GOOD := 75
const MC_MIXED := 50


static func empty() -> Dictionary:
	return {"summary": "", "genres": [], "themes": [], "modes": [], "developers": [], "publishers": [],
		"release_date": "", "controller": "", "screenshots": [],
		"critics": {"metacritic": null, "opencritic": null, "igdb_critic": null},
		"sources": {}, "steam_twin": ""}


# ------------------------------------------------------------ cleaning

static func clean_text(v: Variant, limit := 80) -> String:
	if not v is String:
		return ""
	var s: String = v
	s = RegEx.create_from_string("<[^>]+>").sub(s, " ", true)
	s = s.replace("&amp;", "&").replace("&quot;", "\"").replace("&#39;", "'").replace("&lt;", "<").replace("&gt;", ">").replace("&nbsp;", " ")
	s = RegEx.create_from_string("\\s+").sub(s, " ", true).strip_edges()
	return s.substr(0, limit).strip_edges()


## A synopsis cut at a sentence end near SUMMARY_MAX.
static func clean_summary(v: Variant) -> String:
	var s := clean_text(v, 100000)
	if s.length() <= SUMMARY_MAX:
		return s
	var cut := s.substr(0, SUMMARY_MAX)
	var end := maxi(cut.rfind(". "), maxi(cut.rfind("! "), cut.rfind("? ")))
	if end >= SUMMARY_MAX / 2:
		return cut.substr(0, end + 1)
	return cut.substr(0, cut.rfind(" ")) + "…"


static func clean_list(v: Variant, limit := LIST_MAX) -> Array:
	var out := []
	var seen := {}
	if not v is Array:
		return out
	for x in v:
		var s := clean_text(x)
		if s != "" and not seen.has(s.to_lower()):
			seen[s.to_lower()] = true
			out.append(s)
		if out.size() >= limit:
			break
	return out


static func clean_date(v: Variant) -> String:
	var s := str(v) if v is String else ""
	return s.substr(0, 10) if RegEx.create_from_string("^\\d{4}-\\d{2}-\\d{2}").search(s) != null else ""


## `url` if it's https on one of `hosts` (or a subdomain), else "".
static func https_on(url: Variant, hosts: Array) -> String:
	if not url is String or not (url as String).begins_with("https://") or (url as String).length() > 600:
		return ""
	var host := (url as String).substr(8).split("/", true, 1)[0].split("?", true, 1)[0].to_lower()
	if host.contains("@") or host.contains(":"):
		return ""
	for h in hosts:
		if host == h or host.ends_with("." + str(h)):
			return url
	return ""


static func _score(v: Variant) -> int:
	if (v is int or v is float) and float(v) > 0.0 and float(v) <= 100.0:
		return roundi(float(v))
	return 0


static func clean_metacritic(v: Variant) -> Variant:
	if not v is Dictionary or _score(v.get("score")) == 0:
		return null
	var url := str(v.get("url", "")) if v.get("url") is String else ""
	if url.begins_with("http://"):
		url = "https://" + url.substr(7)
	url = https_on(url.split("?")[0], ["metacritic.com"])
	return {"score": _score(v.get("score")), "url": url}


static func clean_igdb_critic(v: Variant) -> Variant:
	if not v is Dictionary or _score(v.get("score")) == 0:
		return null
	return {"score": _score(v.get("score")), "count": maxi(0, int(v.get("count", 0)) if v.get("count") is float or v.get("count") is int else 0)}


static func clean_opencritic(v: Variant) -> Variant:
	if not v is Dictionary or _score(v.get("score")) == 0:
		return null
	var pct = v.get("percent_recommended")
	return {"score": _score(v.get("score")),
		"percent_recommended": roundi(float(pct)) if (pct is float or pct is int) and float(pct) >= 0.0 and float(pct) <= 100.0 else -1,
		"tier": clean_text(v.get("tier", ""), 20),
		"url": https_on(v.get("url", ""), ["opencritic.com"]),
		"count": maxi(0, int(v.get("count", 0)) if v.get("count") is float or v.get("count") is int else 0)}


static func clean_screens(v: Variant) -> Array:
	var out := []
	if not v is Array:
		return out
	for s in v:
		var thumb := ""
		var full := ""
		if s is String:
			thumb = https_on(s, IMAGE_HOSTS)
			full = thumb
		elif s is Dictionary:
			thumb = https_on(s.get("thumb", ""), IMAGE_HOSTS)
			full = https_on(s.get("full", ""), IMAGE_HOSTS)
			if thumb == "":
				thumb = full
			if full == "":
				full = thumb
		if thumb != "":
			out.append({"thumb": thumb, "full": full})
		if out.size() >= SCREENS_MAX:
			break
	return out


## A raw {field: value} map from any source, checked and cleaned.
static func clean_meta(m: Variant) -> Dictionary:
	var out := {}
	if not m is Dictionary:
		return out
	var s := clean_summary(m.get("summary", ""))
	if s != "":
		out["summary"] = s
	for k in LISTS:
		var l := clean_list(m.get(k, []))
		if not l.is_empty():
			out[k] = l
	var d := clean_date(m.get("release_date", ""))
	if d != "":
		out["release_date"] = d
	if m.get("controller", "") in ["full", "partial"]:
		out["controller"] = m["controller"]
	var sc := clean_screens(m.get("screens", m.get("screenshots", [])))
	if not sc.is_empty():
		out["screenshots"] = sc
	return out


static func layer(source: String, meta: Variant, critics := {}) -> Dictionary:
	var c := {}
	if critics.get("metacritic") != null:
		var mc = clean_metacritic(critics["metacritic"])
		if mc != null:
			c["metacritic"] = mc
	if critics.get("igdb_critic") != null:
		var ic = clean_igdb_critic(critics["igdb_critic"])
		if ic != null:
			c["igdb_critic"] = ic
	if critics.get("opencritic") != null:
		var oc = clean_opencritic(critics["opencritic"])
		if oc != null:
			c["opencritic"] = oc
	return {"source": source, "meta": clean_meta(meta), "critics": c}


# ------------------------------------------------------------ sources

## The game database record's layers: [steam, igdb, wikidata] (empty ones left out).
static func gamedb_layers(rec: Dictionary) -> Array:
	var block = rec.get("meta", {})
	var critics = rec.get("critics", {})
	if not block is Dictionary:
		block = {}
	if not critics is Dictionary:
		critics = {}
	var out := []
	var st = block.get("steam", {})
	out.append(layer("steam", st, {"metacritic": critics.get("metacritic")}))
	out.append(layer("igdb", block.get("igdb", {}), {"igdb_critic": critics.get("igdb_critic")}))
	out.append(layer("wikidata", block.get("wikidata", {})))
	return out.filter(func(l): return not l["meta"].is_empty() or not l["critics"].is_empty())


static func _strings(v: Variant) -> Array:
	if v is String:
		return [v] if v != "" else []
	if v is Array:
		return v.filter(func(x): return x is String)
	return []


static func _names(v: Variant) -> Array:
	var out := []
	if v is Array:
		for x in v:
			if x is String:
				out.append(x)
			elif x is Dictionary:
				out.append(str(x.get("description", x.get("name", ""))))
	return out


## What a store's own files say about a game. `raw` is the store's record:
##   epic:   legendary's metadata/<app>.json ({"metadata": {"description", "developer", ...}})
##   gog:    Heroic's gog_library.json game ({"developer", "extra": {"about": {...}, "genres", "releaseDate"}})
##   amazon: nile's library.json entry ({"product": {"productDetail": {"details": {...}}}})
static func local_layer(store: String, raw: Variant) -> Dictionary:
	var m := {}
	if not raw is Dictionary:
		return layer("store", m)
	match store:
		"epic":
			var md = raw.get("metadata", {})
			if md is Dictionary:
				m["summary"] = md.get("description", "")
				m["developers"] = _strings(md.get("developer", ""))
				var shots := []
				for img in md.get("keyImages", []) if md.get("keyImages") is Array else []:
					if img is Dictionary and str(img.get("type", "")) == "Screenshot":
						shots.append(str(img.get("url", "")))
				m["screens"] = shots
		"gog":
			var extra = raw.get("extra", {})
			var about = extra.get("about", {}) if extra is Dictionary else {}
			if about is Dictionary:
				m["summary"] = about.get("shortDescription", "") if str(about.get("shortDescription", "")) != "" else about.get("description", "")
			if str(m.get("summary", "")) == "":
				m["summary"] = raw.get("description", "")
			m["developers"] = _strings(raw.get("developer", ""))
			if extra is Dictionary:
				m["genres"] = _names(extra.get("genres", []))
				m["release_date"] = str(extra.get("releaseDate", "")) if extra.get("releaseDate") is String else ""
		"amazon":
			var product = raw.get("product", {})
			var pd = product.get("productDetail", {}) if product is Dictionary else {}
			var d = pd.get("details", {}) if pd is Dictionary else {}
			if d is Dictionary:
				m["summary"] = d.get("shortDescription", d.get("description", ""))
				m["developers"] = _strings(d.get("developer", ""))
				m["publishers"] = _strings(d.get("publisher", ""))
				m["genres"] = _names(d.get("genres", []))
				m["release_date"] = str(d.get("releaseDate", "")) if d.get("releaseDate") is String else ""
				m["screens"] = _strings(d.get("screenshots", []))
	return layer("store", m)


## A Steam store appdetails answer for `appid` as a layer, or {} if Steam has
## no such app or the answer is junk.
static func steam_layer(appid: String, body: PackedByteArray) -> Dictionary:
	var j := JSON.new()
	if j.parse(body.get_string_from_utf8()) != OK or not j.data is Dictionary:
		return {}
	var entry = j.data.get(appid)
	if not entry is Dictionary or not entry.get("success", false) or not entry.get("data") is Dictionary:
		return {}
	var d: Dictionary = entry["data"]
	var cats := {}
	for c in d.get("categories", []) if d.get("categories") is Array else []:
		if c is Dictionary:
			cats[int(c.get("id", 0))] = true
	var ctl := str(d.get("controller_support", "")) if d.get("controller_support") is String else ""
	if not ctl in ["full", "partial"]:
		ctl = "full" if cats.has(28) else ("partial" if cats.has(18) else "")
	var shots := []
	for s in d.get("screenshots", []) if d.get("screenshots") is Array else []:
		if s is Dictionary:
			shots.append({"thumb": s.get("path_thumbnail", ""), "full": s.get("path_full", "")})
	var rd = d.get("release_date", {})
	var m := {
		"summary": d.get("short_description", ""),
		"genres": _names(d.get("genres", [])),
		"developers": _strings(d.get("developers", [])),
		"publishers": _strings(d.get("publishers", [])),
		"release_date": steam_date(str(rd.get("date", "")) if rd is Dictionary else ""),
		"controller": ctl,
		"screens": shots,
	}
	return layer("steam", m, {"metacritic": d.get("metacritic")})


const MONTHS := ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]


## Steam's English release date ("3 Aug, 2023", "Sep 17, 2020") as YYYY-MM-DD, or "".
static func steam_date(text: String) -> String:
	var t := text.strip_edges()
	if clean_date(t) == t and t != "":
		return t
	var m := RegEx.create_from_string("^(\\d{1,2}) ([A-Za-z]{3})[a-z]*\\.?,? (\\d{4})$").search(t)
	var day := ""
	var mon := ""
	var year := ""
	if m:
		day = m.get_string(1)
		mon = m.get_string(2)
		year = m.get_string(3)
	else:
		m = RegEx.create_from_string("^([A-Za-z]{3})[a-z]*\\.? (\\d{1,2}),? (\\d{4})$").search(t)
		if m == null:
			return ""
		mon = m.get_string(1)
		day = m.get_string(2)
		year = m.get_string(3)
	var mi := MONTHS.find(mon.to_lower())
	if mi < 0 or int(day) < 1 or int(day) > 31:
		return ""
	return "%s-%02d-%02d" % [year, mi + 1, int(day)]


# ------------------------------------------------------------ merging

## Fills every field from the first layer that has it (see the order at the
## top). Critic scores: each from the first layer that has that score.
static func merge(layers: Array, steam_twin := "") -> Dictionary:
	var out := empty()
	out["steam_twin"] = steam_twin
	for l in layers:
		if not l is Dictionary:
			continue
		var m: Dictionary = l.get("meta", {})
		var src := str(l.get("source", ""))
		for k in FIELDS:
			if not m.has(k):
				continue
			var have = out[k]
			if (have is String and have == "") or (have is Array and have.is_empty()):
				out[k] = m[k].duplicate() if m[k] is Array else m[k]
				out["sources"][k] = src
		var c: Dictionary = l.get("critics", {})
		for k in CRITICS:
			if c.get(k) != null and out["critics"][k] == null:
				out["critics"][k] = c[k].duplicate()
				out["sources"][k] = src
	return out


## The merge order: store, the database's Steam details, a live Steam fetch,
## IGDB, Wikidata, then OpenCritic for its own score.
static func ordered(local: Dictionary, db_layers: Array, live_steam: Dictionary, opencritic: Dictionary) -> Array:
	var by := {}
	for l in db_layers:
		by[l["source"]] = l
	var out := []
	for l in [local, by.get("steam", {}), live_steam, by.get("igdb", {}), by.get("wikidata", {}), opencritic]:
		if l is Dictionary and not l.is_empty():
			out.append(l)
	return out


## What's still missing that a live Steam fetch could fill.
static func wants_steam(meta: Dictionary) -> bool:
	return meta.get("summary", "") == "" or (meta.get("genres", []) as Array).is_empty() \
		or (meta.get("screenshots", []) as Array).is_empty() or meta.get("critics", {}).get("metacritic") == null \
		or (meta.get("developers", []) as Array).is_empty() or meta.get("release_date", "") == ""


# ------------------------------------------------------------ for the UI and sorting

## "good" (75+), "mixed" (50-74) or "bad" (under 50): Metacritic's colours.
static func metacritic_band(score: int) -> String:
	if score >= MC_GOOD:
		return "good"
	if score >= MC_MIXED:
		return "mixed"
	return "bad"


## One critic number for sorting and filtering: Metacritic, else OpenCritic,
## else IGDB's critic average; -1 when there's none.
static func critic_score(meta: Variant) -> int:
	if not meta is Dictionary:
		return -1
	var c = meta.get("critics", {})
	if not c is Dictionary:
		return -1
	for k in ["metacritic", "opencritic", "igdb_critic"]:
		if c.get(k) is Dictionary and int(c[k].get("score", 0)) > 0:
			return int(c[k]["score"])
	return -1


## Genres for filters: the merged genres (store wording first), then themes.
static func genres_of(meta: Variant) -> Array:
	if not meta is Dictionary:
		return []
	return (meta.get("genres", []) as Array).duplicate()


## The credits line for what a meta block shows: every source it used, named
## the way each asks ("Game data from IGDB", "Metacritic", "OpenCritic", ...).
static func credits(meta: Dictionary) -> Array:
	var used := {}
	for k in meta.get("sources", {}):
		used[meta["sources"][k]] = true
	var out := []
	var c: Dictionary = meta.get("critics", {})
	if c.get("metacritic") != null:
		out.append({"text": "Metacritic", "url": str(c["metacritic"].get("url", "")) if str(c["metacritic"].get("url", "")) != "" else "https://www.metacritic.com"})
	if c.get("opencritic") != null:
		out.append({"text": "Critic scores from OpenCritic", "url": str(c["opencritic"].get("url", "")) if str(c["opencritic"].get("url", "")) != "" else "https://opencritic.com"})
	if used.has("igdb"):
		out.append({"text": "Game data from IGDB", "url": "https://www.igdb.com"})
	if used.has("steam"):
		out.append({"text": "Steam", "url": ""})
	if used.has("wikidata"):
		out.append({"text": "Wikidata (CC0)", "url": "https://www.wikidata.org"})
	return out
