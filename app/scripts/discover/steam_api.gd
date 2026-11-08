extends RefCounted
## Steam's public store and wishlist endpoints: URL builders and parsers.
## Static only, no network: Discover and Art make the requests through their
## http object and hand the bytes here. Terms: Steam Web API Terms of Use
## (https://steamcommunity.com/dev/apiterms). All three calls below work
## without an API key, so no key ships with GameCove.
##
## - IStoreBrowseService/GetItems: name, regional price (country_code), sale
##   end date, release state and art file names for up to BATCH apps at once.
## - IWishlistService/GetWishlist: a public profile's wishlist (appid,
##   priority, date_added). A private wishlist answers {"response": {}}.
## - steamcommunity.com/id/<name>/?xml=1: resolves a custom profile name to the
##   64-bit SteamID (ISteamUser/ResolveVanityURL would need a key).

const Cal := preload("res://scripts/discover/calendar.gd")

const API := "https://api.steampowered.com/"
const CDN := "https://shared.akamai.steamstatic.com/store_item_assets/"
const BATCH := 50
## Steam's display setting for an unreleased date -> our precision.
const PRECISION := {
	"date_full": "day", "date_month": "month", "date_quarter": "quarter", "date_year": "year",
	"text_comingsoon": "tba", "text_tba": "tba",
}


static func items_url(appids: Array, country: String) -> String:
	var ids := []
	for a in appids:
		ids.append({"appid": int(str(a))})
	var body := {
		"ids": ids,
		"context": {"language": "english", "country_code": country.to_upper()},
		"data_request": {"include_assets": true, "include_release": true},
	}
	return API + "IStoreBrowseService/GetItems/v1/?input_json=" + JSON.stringify(body).uri_encode()


static func wishlist_url(steam_id64: String) -> String:
	return API + "IWishlistService/GetWishlist/v1/?steamid=" + steam_id64.uri_encode()


static func profile_xml_url(vanity: String) -> String:
	return "https://steamcommunity.com/id/%s/?xml=1" % vanity.uri_encode()


## Store page in the Steam client.
static func store_uri(appid: String) -> String:
	return "steam://store/" + appid


## What the user typed in "Import Steam wishlist": {"steam_id": "7656..."} when
## it already holds a 64-bit id, {"vanity": "name"} when it needs resolving,
## or {} when it can't be either.
static func parse_profile_input(text: String) -> Dictionary:
	var t := text.strip_edges()
	var re_id := RegEx.create_from_string("(?:^|/profiles/)(7656119\\d{10})(?:/|$)")
	var m := re_id.search(t)
	if m:
		return {"steam_id": m.get_string(1)}
	var re_vanity := RegEx.create_from_string("steamcommunity\\.com/id/([A-Za-z0-9_-]{2,32})")
	m = re_vanity.search(t)
	if m:
		return {"vanity": m.get_string(1)}
	if RegEx.create_from_string("^[A-Za-z0-9_-]{2,32}$").search(t):
		return {"vanity": t}
	return {}


## steamID64 from a community profile XML page, or "".
static func parse_profile_xml(body: String) -> String:
	var m := RegEx.create_from_string("<steamID64>\\s*(7656119\\d{10})\\s*</steamID64>").search(body)
	return m.get_string(1) if m else ""


static func _json(body: Variant) -> Variant:
	var text: String = body.get_string_from_utf8() if body is PackedByteArray else str(body)
	var j := JSON.new()
	return j.data if j.parse(text) == OK else null


## Wishlist rows [{"appid": "123", "priority": 0, "added": unix}], or null when
## the body isn't a GetWishlist answer. A private or empty wishlist gives [].
static func parse_wishlist(body: Variant) -> Variant:
	var d = _json(body)
	if not d is Dictionary or not d.get("response") is Dictionary:
		return null
	var out: Array[Dictionary] = []
	for it in d["response"].get("items", []):
		if it is Dictionary and it.has("appid"):
			out.append({"appid": str(int(it["appid"])), "priority": int(it.get("priority", 0)),
				"added": int(it.get("date_added", 0))})
	return out


## Art URLs from a store item's "assets" block: {"cover", "hero", "header",
## "capsule"}; newer apps keep their files under hashed folders, so these are
## the only reliable URLs for them.
static func art_from_assets(assets: Variant) -> Dictionary:
	var out := {}
	if not assets is Dictionary or not assets.has("asset_url_format"):
		return out
	var fmt: String = assets["asset_url_format"]
	for pair in [["cover", "library_capsule"], ["hero", "library_hero"], ["header", "header"], ["capsule", "main_capsule"]]:
		if str(assets.get(pair[1], "")) != "":
			out[pair[0]] = CDN + fmt.replace("${FILENAME}", assets[pair[1]])
	return out


## The plain CDN URLs every older app has (newer ones 404 here; use
## art_from_assets when GetItems has been asked).
static func fallback_art(appid: String) -> Dictionary:
	var base := CDN + "steam/apps/%s/" % appid
	return {"cover": base + "library_600x900.jpg", "hero": base + "library_hero.jpg",
		"header": base + "header.jpg", "logo": base + "logo.png"}


## Release state from a store item's "release" block:
## {"released": bool, "date": "YYYY-MM-DD"|"YYYY-MM"|"YYYY-Qn"|"YYYY"|"", "precision": ...}.
static func release_from(rel: Variant, is_coming_soon: bool) -> Dictionary:
	var r: Dictionary = rel if rel is Dictionary else {}
	var soon := is_coming_soon or bool(r.get("is_coming_soon", false))
	var stamp := int(r.get("steam_release_date", 0))
	var precision: String = PRECISION.get(str(r.get("coming_soon_display", "")), "day" if stamp > 0 else "tba")
	if stamp <= 0:
		precision = "tba"
	return {"released": not soon, "date": Cal.date_label(stamp, precision) if stamp > 0 else "",
		"precision": precision}


## GetItems answer -> {appid: info}. info = {"appid", "title", "price": float or
## null (null: free, not for sale or unknown), "regular_price", "savings_pct",
## "price_text", "regular_text", "sale_ends_at": unix or null, "art": {...},
## "release": {...}, "free": bool}. Prices are in the currency of the
## country asked for. Apps Steam doesn't know (success != 1) are left out.
static func parse_items(body: Variant) -> Dictionary:
	var d = _json(body)
	var out := {}
	if not d is Dictionary or not d.get("response") is Dictionary:
		return out
	for it in d["response"].get("store_items", []):
		if not it is Dictionary or int(it.get("success", 0)) != 1:
			continue
		var appid := str(int(it.get("appid", it.get("id", 0))))
		var info := {
			"appid": appid, "title": str(it.get("name", "")).strip_edges(),
			"price": null, "regular_price": null, "savings_pct": 0, "price_text": "", "regular_text": "",
			"sale_ends_at": null, "free": bool(it.get("is_free", false)),
			"art": art_from_assets(it.get("assets")),
			"release": release_from(it.get("release"), bool(it.get("is_coming_soon", false))),
		}
		var bpo = it.get("best_purchase_option")
		if bpo is Dictionary and bpo.has("final_price_in_cents"):
			var final := int(str(bpo["final_price_in_cents"])) / 100.0
			var orig := int(str(bpo.get("original_price_in_cents", bpo["final_price_in_cents"]))) / 100.0
			info["price"] = final
			info["regular_price"] = maxf(orig, final)
			info["price_text"] = str(bpo.get("formatted_final_price", ""))
			info["regular_text"] = str(bpo.get("formatted_original_price", info["price_text"]))
			info["savings_pct"] = int(bpo.get("discount_pct", 0))
			if info["savings_pct"] == 0 and orig > final and orig > 0:
				info["savings_pct"] = int(round((1.0 - final / orig) * 100.0))
			for disc in bpo.get("active_discounts", []):
				if disc is Dictionary and int(disc.get("discount_end_date", 0)) > 0:
					var end := int(disc["discount_end_date"])
					info["sale_ends_at"] = end if info["sale_ends_at"] == null else mini(info["sale_ends_at"], end)
		out[appid] = info
	return out
