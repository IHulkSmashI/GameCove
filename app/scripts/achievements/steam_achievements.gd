extends RefCounted
## Steam achievements from the client's own cache, offline:
##   <steam>/appcache/stats/UserGameStatsSchema_<appid>.bin   what exists
##   <steam>/appcache/stats/UserGameStats_<accountid>_<appid>.bin   what you have
## Both are binary KeyValues (binary_kv.gd). Layout, checked against real files:
##   schema: {"<appid>": {"stats": {"<block>": {"type_int": 4 (achievements)
##           or 5 (group achievements), "bits": {"<n>": {"name": API name,
##           "bit": n, "display": {"name": {"english": ..., "<lang>": ...} or a
##           plain string, "desc": same, "hidden"/"Hidden": "0"|"1",
##           "icon": "<sha1>.jpg", "icon_gray": "<sha1>.jpg"}}}}}}, "version"}}
##   user:   {"cache": {"crc", "PendingChanges", "<block>": {"data": int32
##           bit field, achievement n unlocked when data & (1 << n),
##           "AchievementTimes": {"<n>": unix seconds}}}}
## Steam writes the user file when the client syncs your stats (after the game
## updates them, and at login), so it lags a running game by up to a few
## seconds. Same approach as Achievement Watcher / celes (which locate the
## files the same way) and Steam Achievement Manager (gibbed, zlib), which
## reads the schema file; our code is our own.
## Icons: the schema names a sha1 file; Steam keeps a copy in
## appcache/librarycache/<appid>/ once its library page showed it. Otherwise
## `icon_url` is Steam's public community CDN.

const BinaryKV := preload("res://scripts/achievements/binary_kv.gd")
const SteamStore := preload("res://scripts/library/stores/steam.gd")

const STEAMID64_BASE := 76561197960265728
const ICON_CDN := "https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/%s/%s"
const TYPE_ACHIEVEMENTS := 4
const TYPE_GROUP_ACHIEVEMENTS := 5


## The first Steam root (of steam.gd's list) that has an appcache/stats folder.
static func find_root(home: String) -> String:
	for r in SteamStore.STEAM_ROOTS:
		var p := SteamStore.expand(r, home)
		if DirAccess.dir_exists_absolute(p + "/appcache/stats"):
			return p
	return ""


## Account id (SteamID3, the userdata/ folder name) of the most recent login
## in config/loginusers.vdf; "" when unknown.
static func recent_account(steam_root: String) -> String:
	var path := steam_root + "/config/loginusers.vdf"
	if not FileAccess.file_exists(path):
		return ""
	var users: Variant = SteamStore.parse_vdf(FileAccess.get_file_as_string(path)).get("users", {})
	if not users is Dictionary:
		return ""
	var best := ""
	var best_t := -1
	for sid in users:
		var u: Variant = users[sid]
		if not u is Dictionary or not str(sid).is_valid_int():
			continue
		var t := int(u.get("timestamp", "0"))
		if str(u.get("mostrecent", "0")) == "1":
			t = 1 << 62
		if t > best_t:
			best_t = t
			best = str(int(str(sid)) - STEAMID64_BASE)
	return best


## The user stats file for this game: the most recent login's if present, else
## the newest UserGameStats_*_<appid>.bin. "" when none.
static func user_stats_path(steam_root: String, appid: String, account := "") -> String:
	var dir := steam_root + "/appcache/stats/"
	if account != "" and FileAccess.file_exists(dir + "UserGameStats_%s_%s.bin" % [account, appid]):
		return dir + "UserGameStats_%s_%s.bin" % [account, appid]
	var d := DirAccess.open(dir)
	if d == null:
		return ""
	var best := ""
	var best_t := -1
	var suffix := "_%s.bin" % appid
	for f in d.get_files():
		if f.begins_with("UserGameStats_") and not f.begins_with("UserGameStatsSchema_") and f.ends_with(suffix):
			var t := FileAccess.get_modified_time(dir + f)
			if t > best_t:
				best_t = t
				best = dir + f
	return best


static func schema_path(steam_root: String, appid: String) -> String:
	return steam_root + "/appcache/stats/UserGameStatsSchema_%s.bin" % appid


## A localized display string: the language, then English, then a plain string.
static func localized(v: Variant, lang: String) -> String:
	if v is Dictionary:
		for k in [lang, "english"]:
			var s: Variant = BinaryKV.get_ci(v, k)
			if s != null:
				return str(s)
		return ""
	return str(v) if v != null else ""


## Everything for one game. `rarity` is {api name: percent} (may be empty).
## {"appid", "unlocked", "total", "items": [{"id", "name", "description",
## "hidden", "icon", "icon_gray", "icon_url", "icon_gray_url", "unlocked",
## "unlock_time", "rarity"}], "source": "steam-local" | ""}.
static func read_game(steam_root: String, appid: String, account := "", lang := "english", rarity := {}) -> Dictionary:
	var out := {"appid": appid, "unlocked": 0, "total": 0, "items": [], "source": ""}
	if steam_root == "" or not appid.is_valid_int():
		return out
	var schema := BinaryKV.parse_file(schema_path(steam_root, appid))
	var game: Variant = schema.get(appid, null)
	if not game is Dictionary:
		for k in schema:  # some schemas key the game by a different id string
			if schema[k] is Dictionary and schema[k].has("stats"):
				game = schema[k]
				break
	if not game is Dictionary:
		return out
	var stats: Variant = BinaryKV.get_ci(game, "stats", {})
	if not stats is Dictionary:
		return out
	var user_path := user_stats_path(steam_root, appid, account)
	var user: Variant = BinaryKV.get_ci(BinaryKV.parse_file(user_path), "cache", {})
	if not user is Dictionary:
		user = {}
	var cache := steam_root + "/appcache/librarycache/" + appid
	var blocks: Array = stats.keys()
	blocks.sort_custom(func(a, b): return str(a).to_int() < str(b).to_int())
	for block_id in blocks:
		var block: Variant = stats[block_id]
		if not block is Dictionary:
			continue
		var kind := int(str(BinaryKV.get_ci(block, "type_int", BinaryKV.get_ci(block, "type", "0"))))
		if kind != TYPE_ACHIEVEMENTS and kind != TYPE_GROUP_ACHIEVEMENTS:
			continue
		var bits: Variant = BinaryKV.get_ci(block, "bits", {})
		if not bits is Dictionary:
			continue
		var ub: Variant = user.get(str(block_id), {})
		var data := int(BinaryKV.get_ci(ub, "data", 0)) if ub is Dictionary else 0
		var times: Variant = BinaryKV.get_ci(ub, "AchievementTimes", {}) if ub is Dictionary else {}
		var keys: Array = bits.keys()
		keys.sort_custom(func(a, b): return str(a).to_int() < str(b).to_int())
		for bk in keys:
			var a: Variant = bits[bk]
			if not a is Dictionary:
				continue
			var bit := int(BinaryKV.get_ci(a, "bit", str(bk).to_int()))
			var disp: Variant = BinaryKV.get_ci(a, "display", {})
			var api := str(BinaryKV.get_ci(a, "name", ""))
			var icon := str(BinaryKV.get_ci(disp, "icon", ""))
			var icon_gray := str(BinaryKV.get_ci(disp, "icon_gray", ""))
			var got := bit >= 0 and bit < 32 and (data & (1 << bit)) != 0
			var when := 0
			if got and times is Dictionary:
				when = int(BinaryKV.get_ci(times, str(bit), 0))
			out["items"].append({
				"id": api,
				"name": localized(BinaryKV.get_ci(disp, "name"), lang),
				"description": localized(BinaryKV.get_ci(disp, "desc"), lang),
				"hidden": str(BinaryKV.get_ci(disp, "hidden", "0")) == "1",
				"icon": local_icon(cache, icon),
				"icon_gray": local_icon(cache, icon_gray),
				"icon_url": ICON_CDN % [appid, icon] if icon != "" else "",
				"icon_gray_url": ICON_CDN % [appid, icon_gray] if icon_gray != "" else "",
				"unlocked": got,
				"unlock_time": when,
				"rarity": float(rarity.get(api, -1.0)),
			})
			if got:
				out["unlocked"] += 1
	out["total"] = out["items"].size()
	out["source"] = "steam-local" if out["total"] > 0 else ""
	return out


## The cached copy of an achievement icon, or "".
static func local_icon(cache_dir: String, icon: String) -> String:
	if icon == "" or icon.contains("/") or icon.contains(".."):
		return ""
	if FileAccess.file_exists(cache_dir + "/" + icon):
		return cache_dir + "/" + icon
	var d := DirAccess.open(cache_dir)
	if d == null:
		return ""
	for sub in d.get_directories():
		if FileAccess.file_exists(cache_dir + "/" + sub + "/" + icon):
			return cache_dir + "/" + sub + "/" + icon
	return ""


## {api name: percent} from GetGlobalAchievementPercentagesForApp's JSON
## ({"achievementpercentages": {"achievements": [{"name", "percent"}]}};
## percent is a string in v0002). {} when it isn't that.
static func parse_rarity(text: String) -> Dictionary:
	var out := {}
	var json := JSON.new()  # instance parse: bad input returns an error, prints nothing
	if json.parse(text) != OK:
		return out
	var j: Variant = json.data
	if not j is Dictionary:
		return out
	var ap: Variant = j.get("achievementpercentages", {})
	if not ap is Dictionary or not ap.get("achievements", null) is Array:
		return out
	for a in ap["achievements"]:
		if a is Dictionary and a.has("name") and a.has("percent"):
			var pct := float(str(a["percent"]))
			out[str(a["name"])] = clampf(pct, 0.0, 100.0)
	return out
