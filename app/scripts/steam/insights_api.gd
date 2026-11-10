extends RefCounted
## "Steam insights" (the game page card): what SteamDB shows at a glance, built
## from Steam's own public endpoints. SteamDB has no API and forbids scraping
## (steamdb.info/faq: "please get the information from Steam itself"), so
## nothing here ever touches steamdb.info; the card only links there (a QR code).
##
## URL builders and parsers only, static, no network. Every call is keyless:
## - ISteamUserStats/GetNumberOfCurrentPlayers: players in game right now.
## - IStoreBrowseService/GetItems with include_reviews + include_platforms:
##   the review summary (score label, % positive, count) and the Steam Deck
##   compatibility category, for up to 50 apps at once. Asked with a fixed
##   country (US): reviews and Deck ratings are the same everywhere, so the
##   user's country isn't sent with this call.
## - ISteamNews/GetNewsForApp with tags=patchnotes: the latest update's date,
##   title and notes (Steam BBCode, made safe for RichTextLabel here).
## - store.steampowered.com/api/appdetails (filters=basic): the DLC app ids.
##   Their names and local prices then come from GetItems with the user's
##   country, like every other Steam price in GameCove.
## Terms: Steam Web API Terms of Use (https://steamcommunity.com/dev/apiterms):
## no key needed for these, no implied endorsement by Valve, well under the
## daily call limit (each game page asks at most once per cache period).

const AppId := preload("res://scripts/steam/app_id.gd")
const API := "https://api.steampowered.com/"
const STORE := "https://store.steampowered.com/"
const STEAMDB_APP := "https://steamdb.info/app/%s/"
const STEAMDB_CHARTS := "https://steamdb.info/app/%s/charts/"
const BATCH := 50
const NEWS_COUNT := 3
## Country GetItems is asked with for reviews and Deck ratings (they don't vary by country).
const NEUTRAL_COUNTRY := "US"

## Steam Deck compatibility categories (GetItems platforms.steam_deck_compat_category).
const DECK_UNKNOWN := 0
const DECK_UNSUPPORTED := 1
const DECK_PLAYABLE := 2
const DECK_VERIFIED := 3
const DECK := {
	0: {"text": "Unknown", "tone": "", "icon": "info"},
	1: {"text": "Unsupported", "tone": "bad", "icon": "x"},
	2: {"text": "Playable", "tone": "warn", "icon": "info"},
	3: {"text": "Verified", "tone": "good", "icon": "check"},
}


static func players_url(appid: String) -> String:
	return API + "ISteamUserStats/GetNumberOfCurrentPlayers/v1/?appid=" + appid.uri_encode()


static func store_url(appids: Array) -> String:
	var ids := []
	for a in appids.slice(0, BATCH):
		ids.append({"appid": int(str(a))})
	var body := {
		"ids": ids,
		"context": {"language": "english", "country_code": NEUTRAL_COUNTRY},
		"data_request": {"include_reviews": true, "include_platforms": true},
	}
	return API + "IStoreBrowseService/GetItems/v1/?input_json=" + JSON.stringify(body).uri_encode()


static func news_url(appid: String) -> String:
	return API + "ISteamNews/GetNewsForApp/v2/?appid=%s&count=%d&maxlength=0&tags=patchnotes&format=json" % [appid.uri_encode(), NEWS_COUNT]


static func appdetails_url(appid: String) -> String:
	return STORE + "api/appdetails?appids=%s&filters=basic&l=english" % appid.uri_encode()


## SteamDB's page for the app (only ever shown as a link / QR code), or "".
static func steamdb_url(appid: String) -> String:
	return STEAMDB_APP % appid if AppId.valid(appid) else ""


static func _json(body: Variant) -> Variant:
	var text: String = body.get_string_from_utf8() if body is PackedByteArray else str(body)
	var j := JSON.new()
	return j.data if j.parse(text) == OK else null


## Players in game now, or -1 when the answer isn't a count (result != 1:
## Steam doesn't count this app).
static func parse_players(body: Variant) -> int:
	var d = _json(body)
	if not d is Dictionary or not d.get("response") is Dictionary:
		return -1
	var r: Dictionary = d["response"]
	if int(r.get("result", 0)) != 1 or not r.has("player_count"):
		return -1
	return maxi(int(r["player_count"]), 0)


## The review block of one store item: {"label", "percent", "count", "score"}
## (all-language, filtered summary, as the store page shows), or {} when the
## app has no reviews yet.
static func reviews_from(it: Dictionary) -> Dictionary:
	var rv = it.get("reviews")
	if not rv is Dictionary:
		return {}
	var s = rv.get("summary_filtered", rv.get("summary_unfiltered"))
	if not s is Dictionary or int(s.get("review_count", 0)) <= 0:
		return {}
	return {"label": str(s.get("review_score_label", "")), "percent": clampi(int(s.get("percent_positive", 0)), 0, 100),
		"count": int(s["review_count"]), "score": int(s.get("review_score", 0))}


## Deck category of one store item (DECK_* ), DECK_UNKNOWN when it isn't there.
static func deck_from(it: Dictionary) -> int:
	var p = it.get("platforms")
	if not p is Dictionary:
		return DECK_UNKNOWN
	var c := int(p.get("steam_deck_compat_category", 0))
	return c if DECK.has(c) else DECK_UNKNOWN


## GetItems (reviews + platforms) -> {appid: {"reviews": {...}, "deck": int,
## "free": bool, "title": String}}. Apps Steam doesn't know are left out.
static func parse_store(body: Variant) -> Dictionary:
	var d = _json(body)
	var out := {}
	if not d is Dictionary or not d.get("response") is Dictionary:
		return out
	for it in d["response"].get("store_items", []):
		if not it is Dictionary or int(it.get("success", 0)) != 1:
			continue
		var appid := str(int(it.get("appid", it.get("id", 0))))
		out[appid] = {"reviews": reviews_from(it), "deck": deck_from(it), "free": bool(it.get("is_free", false)),
			"title": str(it.get("name", "")).strip_edges()}
	return out


## GetNewsForApp -> [{"title", "date", "url", "author", "body"}] newest first
## (body: raw Steam BBCode), or null when the body isn't a news answer.
static func parse_news(body: Variant) -> Variant:
	var d = _json(body)
	if not d is Dictionary or not d.get("appnews") is Dictionary:
		return null
	var out: Array[Dictionary] = []
	for n in d["appnews"].get("newsitems", []):
		if not n is Dictionary or str(n.get("title", "")).strip_edges() == "":
			continue
		var url := str(n.get("url", ""))
		out.append({"title": str(n["title"]).strip_edges(), "date": int(n.get("date", 0)),
			"url": url if url.begins_with("https://") else "", "author": str(n.get("author", "")),
			"body": str(n.get("contents", ""))})
	out.sort_custom(func(a, b): return a["date"] > b["date"])
	return out


## appdetails -> the DLC app ids (valid ids only, store order), or null when
## the body isn't a successful answer for `appid`.
static func parse_dlc_ids(body: Variant, appid: String) -> Variant:
	var d = _json(body)
	if not d is Dictionary or not d.get(appid) is Dictionary or not d[appid].get("success", false):
		return null
	var data = d[appid].get("data")
	var out: Array[String] = []
	if data is Dictionary:
		for x in data.get("dlc", []):
			var id := str(int(x)) if (x is int or x is float) else str(x)
			if AppId.valid(id) and not id in out:
				out.append(id)
	return out


# ---- labels ------------------------------------------------------------------

## 835755 -> "835,755".
static func group(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(s.length() - 3)
	return ("-" if n < 0 else "") + s + out


## "Very Positive · 93% of 835,755", or "" without reviews.
static func review_line(r: Dictionary) -> String:
	if r.is_empty():
		return ""
	var label := str(r.get("label", ""))
	var tail := "%d%% of %s" % [int(r.get("percent", 0)), group(int(r.get("count", 0)))]
	return tail if label == "" else label + " · " + tail


## Pill text for small spaces: "93% positive".
static func review_short(r: Dictionary) -> String:
	return "" if r.is_empty() else "%d%% positive" % int(r.get("percent", 0))


## Tone for a review score (Steam's 1..9 scale): good from Mostly Positive up.
static func review_tone(r: Dictionary) -> String:
	var s := int(r.get("score", 0))
	return "good" if s >= 7 else ("warn" if s >= 5 else ("bad" if s >= 1 else ""))


static func deck_info(cat: int) -> Dictionary:
	return DECK.get(cat, DECK[0])


# ---- Steam BBCode -> RichTextLabel ----------------------------------------------

const _HEAD_SIZE := {"h1": 26, "h2": 23, "h3": 20, "h4": 18, "h5": 18}
## Steam tags shown with the same RichTextLabel tag.
const _SAME := {"b": "b", "i": "i", "u": "u", "strike": "s", "s": "s", "code": "code"}
## Tags whose content isn't text (pictures, videos).
const _DROP_CONTENT := ["img", "previewyoutube", "video", "dynamiclink"]
const _ENTITIES := {"&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "}


static func _text(s: String) -> String:
	var t := s
	for e in _ENTITIES:
		t = t.replace(e, _ENTITIES[e])
	return t.replace("[", "[lb]")


## Steam's news BBCode (or the HTML some feeds carry) as BBCode a
## RichTextLabel shows safely: headings, bold/italic/underline/strike, lists
## as bullets, tables as rows; pictures, videos and links' targets dropped
## (nothing in the overlay opens anything); every other "[" escaped, so the
## text can't inject RichTextLabel tags (urls, images, fonts).
static func bbcode_to_rich(src: String) -> String:
	var s := src.replace("\r\n", "\n").replace("\r", "\n")
	s = RegEx.create_from_string("\\{STEAM_[A-Z_]+\\}\\S*").sub(s, "", true)
	# HTML feeds: line breaks and paragraphs become newlines, other tags go
	s = RegEx.create_from_string("(?i)<br\\s*/?>|</p>|</li>|</h[1-6]>").sub(s, "\n", true)
	s = RegEx.create_from_string("(?i)<li[^>]*>").sub(s, "\n• ", true)
	s = RegEx.create_from_string("<[^>\n]{1,200}>").sub(s, "", true)
	var re := RegEx.create_from_string("\\[(/?)([a-zA-Z0-9*]+)(?:=[^\\]\\n]*)?\\]")
	var out := ""
	var stack: Array[String] = []   # open RichTextLabel tags, innermost last
	var drop := 0                   # inside a picture/video
	var pos := 0
	for m in re.search_all(s):
		if drop == 0:
			out += _text(s.substr(pos, m.get_start() - pos))
		pos = m.get_end()
		var closing := m.get_string(1) == "/"
		var tag := m.get_string(2).to_lower()
		if tag in _DROP_CONTENT:
			drop = maxi(drop - 1, 0) if closing else drop + 1
			continue
		if drop > 0:
			continue
		if _SAME.has(tag) or _HEAD_SIZE.has(tag):
			var open: String = "b" if _HEAD_SIZE.has(tag) else _SAME[tag]
			if not closing:
				if _HEAD_SIZE.has(tag):
					out += "\n[b][font_size=%d]" % _HEAD_SIZE[tag]
					stack.append("b")
					stack.append("font_size")
				else:
					out += "[%s]" % open
					stack.append(open)
			else:
				var want: Array = ["font_size", "b"] if _HEAD_SIZE.has(tag) else [open]
				for w in want:
					if not stack.is_empty() and stack.back() == w:
						out += "[/%s]" % stack.pop_back()
				if _HEAD_SIZE.has(tag):
					out += "\n"
			continue
		match tag:
			"p":
				if closing:
					out += "\n"
			"*":
				out += "\n• "
			"list", "olist", "ul", "ol", "table":
				out += "\n"
			"tr":
				if closing:
					out += "\n"
			"td", "th":
				if closing:
					out += "   "
			"hr":
				out += "\n"
			"quote":
				if not closing:
					out += "[i]"
					stack.append("i")
				elif not stack.is_empty() and stack.back() == "i":
					out += "[/%s]\n" % stack.pop_back()
			_:
				pass   # url, spoiler, noparse, ...: keep the text, drop the tag
	if drop == 0:
		out += _text(s.substr(pos))
	while not stack.is_empty():
		out += "[/%s]" % stack.pop_back()
	# at most one blank line in a row, no leading/trailing blank lines
	out = RegEx.create_from_string("[ \\t]+\\n").sub(out, "\n", true)
	out = RegEx.create_from_string("• [ \\t]+").sub(out, "• ", true)
	out = RegEx.create_from_string("\\n•[ \\t]*\\n").sub(out, "\n", true)   # empty bullets
	out = RegEx.create_from_string("\\n{3,}").sub(out, "\n\n", true)
	return out.strip_edges()
