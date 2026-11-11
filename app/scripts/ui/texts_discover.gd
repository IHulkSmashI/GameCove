extends RefCounted
## Words for the Discover area (deals, release calendar, wishlist, store
## pages) and the small formatters that turn Discover data into short lines.
## Plain and short; jargon gets one line of explanation.

const MONTHS := ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
const MONTHS_SHORT := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
const WEEKDAYS_SHORT := ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

const TITLE := "Discover"
const SECTIONS := {"home": "For you", "deals": "Deals", "calendar": "Coming soon", "wishlist": "Wishlist"}

# Home
const HERO_DEAL := "Biggest deal right now"
const HERO_WISH_SALE := "On your wishlist, and on sale"
const HERO_RELEASE := "Coming soon"
const HERO_OUT_TODAY := "Out today"
const TODAY_TAG := "Today"
const SHELF_DEALS := "Top deals"
const SHELF_WISH_SALE := "From your wishlist, on sale"
const SHELF_SOON := "Coming soon"
const SHELF_FREE := "Free to keep"
## Beside a lone giveaway's featured card.
const FREE_ON := "Free on %s"
const FREE_HOW := "Claim it in the store while the giveaway runs and it stays in your library there."
const VIEW_DEAL := "View deal"
const VIEW_GAME := "Game page"
const SEE_ALL_DEALS := "All deals"

# Prices
const SEE_PRICE := "See price"
## Tiles without a real local price name the store instead of guessing one.
const PRICE_ON := "Price on %s"
## A deal's tile line when GG.deals (the user's own key) gives the game's
## real local price: its best price across official stores.
const GG_BEST := "Best price · GG.deals"
## Store names as a tile's one-line store line says them.
const STORE_SHORT := {"Epic Games Store": "Epic Games", "GreenManGaming": "Green Man Gaming", "GamersGate": "GamersGate",
	"Humble Store": "Humble Store", "Fanatical": "Fanatical", "GOG": "GOG", "Steam": "Steam"}


static func store_short(name: String) -> String:
	return str(STORE_SHORT.get(name, name))
const SEE_PRICE_WHY := "Shown on the store's own page in your currency."
const HIST_LOW := "Lowest ever"
const HIST_LOW_LONG := "Lowest price ever"
const FREE := "Free"
const KEYSHOP := "Key shop"
const SUPPORTS := "Supports GameCove"
const OFFICIAL := "Official store"
const CHECKING := "Checking prices…"
const NO_PRICES := "No store has a price for this yet."
const NO_PRICES_SOON := "Not on sale yet. Prices show up here once stores list it."

# Deals browser
const STORE_ALL := "All stores"
const SORTS := ["best", "discount", "price", "ending", "rating"]
const SORT_LABELS := {"best": "Best deals", "discount": "Biggest discount", "price": "Lowest price", "ending": "Ending soon", "rating": "Top rated"}
const STORE_LABEL := "Store"
const SORT_LABEL := "Sort"
const NO_DEALS_STORE := "No deals from this store right now."

# Calendar
const VIEW_MONTH := "Month"
const VIEW_LIST := "List"
const GROUPS := ["out", "week", "month", "later", "tba"]
const GROUP_LABELS := {"out": "Out now", "week": "This week", "month": "This month", "later": "Later", "tba": "Date not announced"}
const NOTIFY_ON := "Notifying you"
const NOTIFY_OFF := "Notify me"
const NOTIFY_LINE := "We'll tell you the day it comes out."
const UNDATED_MONTH := "Sometime this month"
const DAY_EMPTY := "Nothing on this day."
const CAL_EMPTY_TITLE := "The release calendar is on its way"
const CAL_EMPTY := "We build it every night from public game data. It shows up here after the first download, usually within a day."
const CAL_NONE_MONTH := "Nothing dated this month yet."

# Wishlist
const WISH_EMPTY_TITLE := "Your wishlist is empty"
const WISH_EMPTY := "Add games from any deal or the calendar with Y, or bring over your Steam wishlist."
const IMPORT := "Import from Steam"
const IMPORT_AGAIN := "Update from Steam"
const IMPORT_TITLE := "Bring over your Steam wishlist"
const IMPORT_WHY := "Type your Steam profile name (the part after /id/ in your profile link) or your 17-digit Steam ID."
const IMPORT_PUBLIC := "Your profile's Game details must be set to Public: on Steam, open your profile, Edit Profile, Privacy Settings."
const IMPORT_FIELD_EMPTY := "Profile name or Steam ID"
const IMPORT_TYPE := "Type it"
const IMPORT_GO := "Import"
const IMPORT_BUSY := "Importing…"
const CANCEL := "Cancel"
const TARGET := "Price alert"
const TARGET_ANY := "Any sale"
const TARGET_LINE := "We tell you when the best price drops to this or lower."
const TARGET_ANY_LINE := "We tell you whenever it goes on sale."
const ALERTS_TOGGLE := "Price alerts"
const RELEASE_TOGGLE := "Tell me when it's out"
const REMOVE := "Remove"
const REMOVE_CONFIRM := "Press again to remove"
const ALERTS_TITLE := "Alerts"
const MARK_SEEN := "Mark all seen"
const NO_PRICE_YET := "No price yet"

# Store page
const BUY := "Buy"
const WISHLIST_ADD := "Wishlist"
const WISHLISTED := "Wishlisted"
const OPEN_LIBRARY := "Open in library"
const BACK := "Back"
const PRICES_CARD := "Prices"
const PRICES_SUB := "Every store we know of, cheapest first. Prices are what each store charges in your country."
const RELEASE_CARD := "Release"
const OWNED := "In your library"

# Keys, offline, credits
const GG_TITLE := "Want real prices from every store?"
const GG_BODY := "Without it, only Steam shows a price in your currency; other stores show the discount and a See price button. A free gg.deals key fixes that. Get one at gg.deals/api, then add it in Settings, Discover."
const GG_GET := "Open gg.deals/api"
const GG_LATER := "Not now"
const GG_URL := "https://gg.deals/api/"
const GG_BAD := "gg.deals didn't accept your key. Check it in Settings, Discover."
const OFFLINE_TITLE := "You're offline"
const OFFLINE := "Deals and prices come back when you're connected. Your wishlist and the calendar still work."
const OFFLINE_PILL := "Offline: saved prices"
const RATE_LIMITED := "Stores asked us to slow down. Trying again later."
const LOADING_TITLE := "Finding deals…"
const LOADING := "Checking the stores. This takes a few seconds the first time."
const RETRY := "Try again"
const CREDITS_LEAD := "Credits"
## IGDB's attribution (review M24): wherever IGDB data (release dates, time to beat) shows, with a link.
const IGDB_CREDIT := "Game data from IGDB"
const IGDB_URL := "https://www.igdb.com"

# Toasts
const TOAST_IMPORTED := "Imported %d games from Steam"
const TOAST_IMPORTED_NONE := "Your Steam wishlist is up to date"
const TOAST_ADDED := "Added to your wishlist"
const TOAST_REMOVED := "Removed from your wishlist"
const TOAST_NOTIFY := "We'll tell you when it's out"
const TOAST_NOTIFY_OFF := "Release alert off"
const TOAST_OPENING := "Opening in Steam"
const TOAST_NO_STEAM := "Couldn't open that. Is Steam running?"

# Hints
const HINT_OPEN := "Open"
const HINT_VIEWS := "Views"
const HINT_BACK := "Back"
const HINT_HOME := "Home"
const HINT_WISH := "Wishlist"
const HINT_UNWISH := "Unwishlist"
const HINT_NOTIFY := "Notify me"
const HINT_UNNOTIFY := "Stop notifying"
const HINT_SORT := "Sort"
const HINT_LAYOUT := "Month / list"
const HINT_CHANGE := "Change"
const HINT_BUY := "Buy"
const HINT_SELECT := "Select"
const HINT_LINK := "Open link"


## "C$ 4.39" for a Deal with a local price, "Free" at zero, "" without one.
static func price(deal: Dictionary) -> String:
	var p: Variant = deal.get("price")
	if not p is Dictionary:
		return ""
	if float(p.get("amount", 0.0)) <= 0.0:
		return FREE
	return str(p.get("text", ""))


static func regular(deal: Dictionary) -> String:
	var p: Variant = deal.get("price")
	if not p is Dictionary or float(p.get("regular", 0.0)) <= float(p.get("amount", 0.0)):
		return ""
	return str(p.get("regular_text", ""))


static func cut(pct: int) -> String:
	return "-%d%%" % pct if pct > 0 else ""


## "Ends in 3 days", "Ends in 5 h", "Ends soon"; "" without an end.
static func ends(at: Variant, now: int) -> String:
	if at == null or int(at) <= 0:
		return ""
	var left := int(at) - now
	if left <= 0:
		return ""
	if left < 3600:
		return "Ends soon"
	if left < 86400:
		return "Ends in %d h" % int(left / 3600.0)
	var d := int(left / 86400.0)
	return "Ends tomorrow" if d == 1 else "Ends in %d days" % d


## "Lowest ever: C$ 1.99" when the low is in the user's currency, else "".
static func hist_low(deal_or_item: Dictionary, currency: String) -> String:
	var h: Variant = deal_or_item.get("historical_low")
	if not h is Dictionary or h.get("amount") == null:
		return ""
	if str(h.get("currency", "")) != currency:
		return ""
	return "%s %s" % [HIST_LOW + ":", money(float(h["amount"]), currency)]


static func money(amount: float, currency: String) -> String:
	return load("res://scripts/discover/money.gd").format(amount, currency)


## When a release comes out, as short as the precision allows.
static func release_when(rel: Dictionary, now: int) -> String:
	var date := str(rel.get("date", ""))
	var precision := str(rel.get("precision", "tba"))
	var year_now := int(Time.get_datetime_dict_from_unix_time(now)["year"])
	var parts := date.split("-")
	match precision:
		"day":
			if parts.size() < 3:
				return date
			var m := int(parts[1])
			var s := "%s %d" % [MONTHS_SHORT[clampi(m - 1, 0, 11)], int(parts[2])]
			return s if int(parts[0]) == year_now else "%s, %s" % [s, parts[0]]
		"month":
			if parts.size() < 2:
				return date
			return "%s %s" % [MONTHS[clampi(int(parts[1]) - 1, 0, 11)], parts[0]]
		"quarter":
			if parts.size() < 2:
				return date
			return "%s %s" % [parts[1], parts[0]]
		"year":
			return date
	return "Date not announced"


## The pill on a calendar entry: "Out today", "Tomorrow", "In 5 days",
## "Out now", or the month for vaguer dates.
static func countdown(rel: Dictionary, now: int) -> String:
	var r: Variant = rel.get("release", rel)
	if not r is Dictionary or r.is_empty():
		return ""
	var du: Variant = r.get("days_until")
	if r.get("released", false) and (du == null or int(du) < 0):
		return "Out now"
	if du != null:
		var d := int(du)
		if d < 0:
			return "Out now"
		if d == 0:
			return "Out today"
		if d == 1:
			return "Tomorrow"
		return "In %d days" % d
	var p := str(r.get("precision", "tba"))
	if p == "tba" or p == "":
		return "TBA"
	return release_when(r, now)


static func countdown_tone(rel: Dictionary) -> String:
	var r: Variant = rel.get("release", rel)
	if not r is Dictionary:
		return ""
	var du: Variant = r.get("days_until")
	if du != null and int(du) == 0:
		return "good"
	if r.get("released", false) or (du != null and int(du) < 0):
		return "good"
	if du != null and int(du) <= 7:
		return "new"
	return "info"


static func month_title(year: int, month: int) -> String:
	return "%s %d" % [MONTHS[clampi(month - 1, 0, 11)], year]


static func day_title(year: int, month: int, day: int) -> String:
	var unix := Time.get_unix_time_from_datetime_dict({"year": year, "month": month, "day": day, "hour": 12})
	var wd := int(Time.get_datetime_dict_from_unix_time(unix)["weekday"])   # 0 = Sunday
	return "%s, %s %d" % [WEEKDAYS_SHORT[posmod(wd - 1, 7)], MONTHS_SHORT[clampi(month - 1, 0, 11)], day]


static func target_label(target: Variant, currency: String) -> String:
	if target == null:
		return TARGET_ANY
	return "%s or less" % money(float(target), currency)


static func alert_line(a: Dictionary) -> String:
	var title := str(a.get("title", ""))
	if title == "":
		title = "A wishlisted game"
	if a.get("kind", "") == "release":
		return "%s is out now" % title
	if a.get("amount") != null and a.get("currency", "") != "":
		return "%s dropped to %s" % [title, money(float(a["amount"]), str(a["currency"]))]
	return "%s is on sale" % title


static func ago(at: int, now: int) -> String:
	var s := now - at
	if s < 3600:
		return "Just now"
	if s < 86400:
		return "%d h ago" % int(s / 3600.0)
	var d := int(s / 86400.0)
	return "Yesterday" if d == 1 else "%d days ago" % d


static func wishlist_count(n: int) -> String:
	return "1 game" if n == 1 else "%d games" % n


## Toast for a price alert: [title, detail].
static func price_toast(item: Dictionary, deal: Dictionary) -> Array:
	var title := str(item.get("title", deal.get("title", "")))
	var pct := int(deal.get("savings_pct", 0))
	var head := "%s is %d%% off" % [title, pct] if pct > 0 else "%s dropped in price" % title
	var where := str(deal.get("store_name", ""))
	var p := price(deal)
	var detail := "%s on %s" % [p, where] if p != "" and where != "" else "On your wishlist"
	if item.get("target_price") != null:
		detail += ", under your target"
	return [head, detail + "."]


static func release_toast(item: Dictionary) -> Array:
	return ["%s is out now" % str(item.get("title", "A wishlisted game")), "From your wishlist."]
