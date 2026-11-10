extends RefCounted
## SteamGridDB API v2 (https://www.steamgriddb.com/api/v2): the requests and
## answers behind Change artwork and the automatic art fill. Same endpoints,
## styles and filters as SteamGridDB's own Decky plugin (decky-steamgriddb,
## src/hooks/useSGDB.tsx and src/constants.ts).
##
## Keys, first that's set:
##   1. the user's own key (Settings > Discover > Keys, or first-run setup),
##   2. GameCove's project key, written into res://data/project_keys.json by
##      the release workflow from the STEAMGRIDDB_API_KEY secret (never in git).
## The Decky plugin's own key is reserved for that plugin and is never used.
## Every image is credited to SteamGridDB and its author.

const API := "https://www.steamgriddb.com/api/v2/"
const PROJECT_KEYS := "res://data/project_keys.json"
const SITE := "https://www.steamgriddb.com"

## Our kinds -> SteamGridDB endpoint, default dimensions and styles.
const KINDS := {
	"cover": {"path": "grids", "dimensions": ["600x900", "342x482", "660x930"],
		"styles": ["alternate", "white_logo", "no_logo", "blurred", "material"]},
	"hero": {"path": "heroes", "dimensions": [], "styles": ["alternate", "blurred", "material"]},
	"logo": {"path": "logos", "dimensions": [], "styles": ["official", "white", "black", "custom"]},
	"icon": {"path": "icons", "dimensions": [], "styles": ["official", "custom"]},
}
## Labels for the style filter (SteamGridDB's own names; "material" is "Minimal" there).
const STYLE_NAMES := {"alternate": "Alternate", "white_logo": "White logo", "no_logo": "No logo", "blurred": "Blurred",
	"material": "Minimal", "official": "Official", "white": "White", "black": "Black", "custom": "Custom"}


## The key to use: the user's, else the project's, else "".
static func key(user_key: String, project_path := PROJECT_KEYS) -> String:
	if valid_key(user_key) and user_key != "":
		return user_key
	return project_key(project_path)


static func project_key(path := PROJECT_KEYS) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var j := JSON.new()
	if j.parse(FileAccess.get_file_as_string(path)) != OK or not j.data is Dictionary:
		return ""
	var k := str(j.data.get("steamgriddb", ""))
	return k if valid_key(k) else ""


## SteamGridDB keys are 32 hex characters.
static func valid_key(k: String) -> bool:
	return k.length() == 32 and k.is_valid_hex_number()


static func headers(k: String) -> Array:
	return ["Authorization: Bearer " + k]


## Default filters: every style, static only, no NSFW, no humour, no epilepsy warnings.
static func default_filters(kind: String) -> Dictionary:
	return {"styles": (KINDS.get(kind, KINDS["cover"])["styles"] as Array).duplicate(),
		"static": true, "animated": false, "nsfw": false, "humor": false, "epilepsy": false}


## The asset search URL. `game` is a Steam app id (by_steam) or a SteamGridDB game id.
static func assets_url(kind: String, game: String, by_steam: bool, filters := {}, page := 0) -> String:
	var k: Dictionary = KINDS.get(kind, KINDS["cover"])
	var f := default_filters(kind)
	f.merge(filters, true)
	var styles: Array = (f["styles"] as Array).filter(func(s): return s in k["styles"])
	if styles.is_empty():
		styles = k["styles"]
	var types := []
	if f["static"]:
		types.append("static")
	if f["animated"]:
		types.append("animated")
	if types.is_empty():
		types = ["static"]
	var q := ["page=%d" % maxi(page, 0), "styles=" + ",".join(styles), "types=" + ",".join(types),
		"nsfw=" + ("any" if f["nsfw"] else "false"), "humor=" + ("any" if f["humor"] else "false"),
		"epilepsy=" + ("any" if f["epilepsy"] else "false")]
	if not (k["dimensions"] as Array).is_empty():
		q.append("dimensions=" + ",".join(k["dimensions"]))
	return API + k["path"] + "/" + ("steam/" if by_steam else "game/") + game.uri_encode() + "?" + "&".join(q)


static func search_url(title: String) -> String:
	return API + "search/autocomplete/" + title.uri_encode()


static func _data(body: PackedByteArray) -> Variant:
	var j := JSON.new()
	if j.parse(body.get_string_from_utf8()) != OK or not j.data is Dictionary or not j.data.get("success", false):
		return null
	return j.data.get("data")


## Assets from an answer: [{"id", "url", "thumb", "author", "author_url", "style",
## "width", "height", "mime", "animated", "score", "nsfw", "humor"}], https URLs only.
static func parse_assets(body: PackedByteArray) -> Array:
	var data = _data(body)
	var out := []
	if not data is Array:
		return out
	for a in data:
		if not a is Dictionary:
			continue
		var url := str(a.get("url", ""))
		var thumb := str(a.get("thumb", url))
		# webm (animated video) can't be shown on a tile or in Steam's grid: left out
		if not url.begins_with("https://") or not thumb.begins_with("https://") or url.get_extension().to_lower() == "webm":
			continue
		var author = a.get("author", {})
		var name := str(author.get("name", "")) if author is Dictionary else ""
		var s64 := str(author.get("steam64", "")) if author is Dictionary else ""
		var mime := str(a.get("mime", ""))
		out.append({"id": int(a.get("id", 0)), "url": url, "thumb": thumb, "author": name,
			"author_url": ("https://www.steamgriddb.com/profile/" + s64) if s64.is_valid_int() else "",
			"style": str(a.get("style", "")), "width": int(a.get("width", 0)), "height": int(a.get("height", 0)),
			"mime": mime, "animated": bool(a.get("animated", false)) or mime == "image/apng" or (a.get("tags") is Array and "animated" in a["tags"]),
			"score": int(a.get("score", 0)), "nsfw": bool(a.get("nsfw", false)), "humor": bool(a.get("humor", false))})
	return out


## The first SteamGridDB game id in an autocomplete answer whose name matches
## `title` (letters and digits, case ignored), else the first result; 0 for none.
static func parse_game_id(body: PackedByteArray, title := "") -> int:
	var data = _data(body)
	if not data is Array or data.is_empty():
		return 0
	var norm := func(t: String) -> String: return RegEx.create_from_string("[^\\p{L}\\p{N}]+").sub(t.to_lower(), "", true)
	for g in data:
		if g is Dictionary and title != "" and norm.call(str(g.get("name", ""))) == norm.call(title):
			return int(g.get("id", 0))
	return int(data[0].get("id", 0)) if data[0] is Dictionary else 0


## The credit line for one asset ("Art by <author> on SteamGridDB").
static func credit(asset: Dictionary) -> String:
	var who := str(asset.get("author", ""))
	return ("Art by %s on SteamGridDB" % who) if who != "" else "Art from SteamGridDB"


## The best asset for an automatic fill: static, not NSFW / humour, highest score.
static func best(assets: Array) -> Dictionary:
	var ok := assets.filter(func(a): return not a["animated"] and not a["nsfw"] and not a["humor"])
	if ok.is_empty():
		return {}
	ok.sort_custom(func(a, b): return a["score"] > b["score"] if a["score"] != b["score"] else a["id"] < b["id"])
	return ok[0]
