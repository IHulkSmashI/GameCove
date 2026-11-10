extends RefCounted
## OpenCritic's official API, served through RapidAPI ("opencritic-api"), with
## the USER'S OWN key only. Its terms (RapidAPI's terms of use, which bind
## consumers to the provider's terms, and OpenCritic's API listing) license the
## data to the key holder and give no right to republish it, so GameCove never
## puts OpenCritic data in its public game database and ships no key. The free
## plan allows about 25 searches and 200 requests a day; we stay under
## DAILY_SEARCHES / DAILY_REQUESTS and stop for the day on a 429.
##
## Two calls per game, ever: a search by title (once, the match is cached) and
## the game record (refreshed at most weekly). Credit: "Critic scores from
## OpenCritic" with a link to the game's OpenCritic page wherever a score shows.

const Metadata := preload("res://scripts/library/meta/metadata.gd")
const HOST := "opencritic-api.p.rapidapi.com"
const BASE := "https://opencritic-api.p.rapidapi.com/game/"
const DAILY_SEARCHES := 20
const DAILY_REQUESTS := 180
const SITE := "https://opencritic.com/game/"


static func headers(key: String) -> Array:
	return ["X-RapidAPI-Key: " + key, "X-RapidAPI-Host: " + HOST]


static func search_url(title: String) -> String:
	return BASE + "search?criteria=" + title.uri_encode()


static func game_url(id: int) -> String:
	return BASE + str(id)


## A key as RapidAPI issues them: 50 letters and digits (we accept 30-80).
static func valid_key(k: String) -> bool:
	return k == "" or RegEx.create_from_string("^[A-Za-z0-9]{30,80}$").search(k) != null


static func _norm(t: String) -> String:
	return RegEx.create_from_string("[^\\p{L}\\p{N}]+").sub(t.to_lower(), "", true)


## The OpenCritic id from a search answer whose name matches `title` exactly
## (letters and digits, case ignored); 0 when none does. Never a fuzzy guess.
static func pick(body: PackedByteArray, title: String) -> int:
	var j := JSON.new()
	if j.parse(body.get_string_from_utf8()) != OK or not j.data is Array:
		return 0
	var want := _norm(title)
	for r in j.data:
		if r is Dictionary and (r.get("id") is float or r.get("id") is int) and _norm(str(r.get("name", ""))) == want:
			return int(r["id"])
	return 0


## The game record -> critics.opencritic ({"score", "percent_recommended",
## "tier", "url", "count"}), or null when it has no top-critic score yet
## (OpenCritic sends -1 until enough reviews are in).
static func parse_game(body: PackedByteArray) -> Variant:
	var j := JSON.new()
	if j.parse(body.get_string_from_utf8()) != OK or not j.data is Dictionary:
		return null
	var d: Dictionary = j.data
	var id := int(d.get("id", 0)) if d.get("id") is float or d.get("id") is int else 0
	var url := str(d.get("url", "")) if d.get("url") is String else ""
	if url == "" and id > 0:
		var slug := RegEx.create_from_string("[^a-z0-9]+").sub(str(d.get("name", "")).to_lower(), "-", true).strip_edges().trim_prefix("-").trim_suffix("-")
		url = SITE + str(id) + "/" + slug
	return Metadata.clean_opencritic({
		"score": d.get("topCriticScore"),
		"percent_recommended": d.get("percentRecommended"),
		"tier": d.get("tier", ""),
		"url": url,
		"count": d.get("numTopCriticReviews", d.get("numReviews", 0)),
	})


## Today's use from a quota record ({"day", "searches", "requests", "blocked"}).
static func quota_left(q: Dictionary, today: String) -> Dictionary:
	if str(q.get("day", "")) != today:
		return {"searches": DAILY_SEARCHES, "requests": DAILY_REQUESTS, "blocked": false}
	return {"searches": DAILY_SEARCHES - int(q.get("searches", 0)), "requests": DAILY_REQUESTS - int(q.get("requests", 0)),
		"blocked": bool(q.get("blocked", false))}
