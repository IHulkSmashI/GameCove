extends RefCounted
## Affiliate links, dormant until the owner joins a program and fills in
## res://data/affiliates.json (see docs/AFFILIATES.md).
##
## Used ONLY for store links GameCove builds itself (e.g. an Epic store page
## from a calendar entry's Epic id). Never for:
## - Steam (no affiliate program; Steam links stay steam://store/<appid>),
## - CheapShark rows (their terms: their redirect links only),
## - GG.deals rows (their terms: referral links unchanged).
## A link that got an affiliate id says so ("affiliate": true, "note":
## NOTE) and the user can turn affiliate links off in settings.

const PATH := "res://data/affiliates.json"
const NOTE := "Supports GameCove"
const NEVER := ["steam", "cheapshark", "ggdeals"]


static func load_file(path := PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var j := JSON.new()
	if j.parse(FileAccess.get_file_as_string(path)) != OK or not j.data is Dictionary:
		return {}
	return j.data.get("stores", {}) if j.data.get("stores") is Dictionary else {}


## A link dict for `url` on `store`: the affiliate version when the store has
## a template and id, affiliate links are on, and the store isn't one we never
## touch; else the plain URL. Template placeholders: {url}, {url_encoded}, {id}.
static func link(store: String, url: String, stores: Dictionary, enabled: bool) -> Dictionary:
	var plain := {"kind": "url", "uri": url, "affiliate": false, "note": ""}
	if not enabled or store in NEVER or not url.begins_with("https://"):
		return plain
	var cfg = stores.get(store, {})
	if not cfg is Dictionary:
		return plain
	var tpl := str(cfg.get("template", ""))
	var id := str(cfg.get("id", ""))
	if tpl == "" or id == "":
		return plain
	var out := tpl.replace("{url_encoded}", url.uri_encode()).replace("{url}", url).replace("{id}", id.uri_encode())
	if not out.begins_with("https://"):
		return plain
	return {"kind": "url", "uri": out, "affiliate": true, "note": NOTE}
