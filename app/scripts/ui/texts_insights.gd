extends RefCounted
## Words for the game page's "Steam insights" card and its overlays. Kept in
## their own file so the game page's other texts don't collide with these.

const TITLE := "Steam insights"
const LOADING := "Asking Steam…"
const OFFLINE := "Can't reach Steam right now. What's shown is from the last time it could."
const OFFLINE_EMPTY := "Can't reach Steam right now. Try again when you're online."
const OFF := "Steam insights are off: Background lookups is turned off in Settings > About > Network and privacy."
const PRICES_OFF := "Prices are off (Look up deals and prices)."

const PLAYERS := "Players now"
const REVIEWS := "Reviews"
const DECK := "Steam Deck"
const NOT_COUNTED := "Not counted"
const NO_REVIEWS := "No reviews yet"
const DASH := "—"

const UPDATE := "Last update"
const NO_UPDATE := "No patch notes on Steam yet"
const UPDATE_HINT := "Read the notes"
const PRICE := "Price on Steam"
const LOWEST := "Lowest ever"
const LOWEST_NONE := "No price history yet"
const DLC := "DLC"
const DLC_NONE := "No DLC"
const DLC_COUNT := "%d DLC"
const DLC_SEE := "See the list"
const DLC_MORE := "Showing the first %d of %d."
const DLC_PRICES_OFF := "Prices are off (Look up deals and prices)."
const FREE := "Free"
const STEAMDB := "Open on SteamDB"
const STEAMDB_LINE := "Price history, player charts and depots on SteamDB. Scan with your phone to open it there."
const STEAMDB_NOTE := "GameCove doesn't read SteamDB: everything on this card comes from Steam itself."
const SOURCE_STEAM := "Players, reviews, Deck rating and updates from Steam."
const NOTES_SOURCE := "From the game's news on Steam"
const CLOSE := "Close"
const SCROLL := "Scroll"


## "16,544" / "1.2M" style count for the players chip.
static func players(n: int) -> String:
	if n < 0:
		return NOT_COUNTED
	if n >= 1000000:
		return "%.1fM" % (n / 1000000.0)
	return preload("res://scripts/steam/insights_api.gd").group(n)


## "16 Dec 2025" from a unix time, "" for 0.
static func date(unix: int) -> String:
	if unix <= 0:
		return ""
	var d := Time.get_datetime_dict_from_unix_time(unix)
	const M := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	return "%d %s %d" % [d["day"], M[int(d["month"]) - 1], d["year"]]


## "Mar 2024" for the lowest-ever date.
static func month(unix: int) -> String:
	if unix <= 0:
		return ""
	var d := Time.get_datetime_dict_from_unix_time(unix)
	const M := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	return "%s %d" % [M[int(d["month"]) - 1], d["year"]]


## "C$ 47.99  −40%  (was C$ 79.99)" / "C$ 79.99" / "Free to play".
static func price_line(p: Dictionary) -> String:
	if p.is_empty():
		return ""
	var t := str(p.get("text", ""))
	var pct := int(p.get("savings_pct", 0))
	if pct > 0:
		t += "  −%d%%" % pct
		if str(p.get("regular_text", "")) != "":
			t += "  (was %s)" % p["regular_text"]
	return t


## "C$ 29.99 · Mar 2024" / "$23.99 USD · US store · Mar 2024".
static func low_line(l: Dictionary) -> String:
	if l.is_empty():
		return LOWEST_NONE
	var parts := [str(l.get("text", ""))]
	if str(l.get("note", "")) != "":
		parts.append(str(l["note"]))
	if month(int(l.get("date", 0))) != "":
		parts.append(month(int(l["date"])))
	return " · ".join(parts)
