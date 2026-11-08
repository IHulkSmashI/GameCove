extends RefCounted
## GG.deals Prices API (https://gg.deals/api/prices/): the lowest current and
## historical price across official stores (and, separately, key shops) for
## Steam app ids, in the region's own currency. Optional: each user enters
## their own free API key in settings; GameCove ships none.
##
## Terms we follow (checked 2026-11-08): the free plan is for personal, hobby
## and open-source use; GG.deals must be credited with an active link wherever
## its data is shown (ATTRIBUTION; every Deal built from it carries it); its
## referral links are never altered or removed (rows open `url` unchanged).
## Limits: 100 ids per request, 100 records a minute and 1,000 an hour per key
## (each id counts; a request over the remaining quota fails whole).

const API := "https://api.gg.deals/v1/prices/by-steam-app-id/"
const MAX_IDS := 100
const REGIONS := ["au", "be", "br", "ca", "ch", "de", "dk", "es", "eu", "fi", "fr", "gb", "ie", "it", "nl", "no", "pl", "se", "us"]
const EURO_COUNTRIES := ["AT", "CY", "EE", "GR", "HR", "LT", "LU", "LV", "MT", "PT", "SI", "SK"]
const ATTRIBUTION := {"text": "Prices by GG.deals", "url": "https://gg.deals/"}
const KEYSHOP_NOTE := "Key shops resell game keys from third parties (grey market). Cheaper, but keys can be region-locked or revoked, and the publisher may not get paid."


## GG.deals region code for a country, or "" when it has none (then no
## GG.deals prices are shown: they wouldn't be local).
static func region_for(country: String) -> String:
	var c := country.to_lower()
	if c in REGIONS:
		return c
	if country.to_upper() in EURO_COUNTRIES:
		return "eu"
	return ""


static func prices_url(appids: Array, region: String, key: String) -> String:
	var ids := []
	for a in appids.slice(0, MAX_IDS):
		ids.append(str(a).uri_encode())
	return API + "?ids=%s&region=%s&key=%s" % [",".join(ids), region.uri_encode(), key.uri_encode()]


static func _amount(v: Variant) -> Variant:
	if v == null:
		return null
	var s := str(v).strip_edges().replace(",", ".")
	return float(s) if s.is_valid_float() else null


## Answer -> {appid: {"title", "url", "currency", "retail", "retail_low",
## "keyshop", "keyshop_low"}} (amounts float or null). Ids GG.deals doesn't
## know (null) are left out. null when the body isn't a successful answer.
static func parse(body: Variant) -> Variant:
	var text: String = body.get_string_from_utf8() if body is PackedByteArray else str(body)
	var j := JSON.new()
	if j.parse(text) != OK or not j.data is Dictionary or not j.data.get("success", false) or not j.data.get("data") is Dictionary:
		return null
	var out := {}
	for id in j.data["data"]:
		var g = j.data["data"][id]
		if not g is Dictionary or not g.get("prices") is Dictionary:
			continue
		var p: Dictionary = g["prices"]
		out[str(id)] = {
			"title": str(g.get("title", "")), "url": str(g.get("url", "")),
			"currency": str(p.get("currency", "")).to_upper(),
			"retail": _amount(p.get("currentRetail")), "retail_low": _amount(p.get("historicalRetail")),
			"keyshop": _amount(p.get("currentKeyshops")), "keyshop_low": _amount(p.get("historicalKeyshops")),
		}
	return out
