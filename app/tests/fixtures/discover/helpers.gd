extends RefCounted
## Shared set-up for the Discover tests: a Discover node wired to a fake http,
## a throwaway data folder and a fixed clock (2026-11-08 12:00 UTC).

const DiscoverScript := preload("res://scripts/discover/discover.gd")
const FakeHttp := preload("res://scripts/discover/fake_http.gd")

const CS := "https://www.cheapshark.com/api/1.0/"
const STEAM_ITEMS := "https://api.steampowered.com/IStoreBrowseService/GetItems/"
const STEAM_WISHLIST := "https://api.steampowered.com/IWishlistService/GetWishlist/"
const UPCOMING := "https://github.com/IHulkSmashI/GameCove-data/releases/download/gamedb/upcoming.json.gz"


static func now() -> int:
	return Time.get_unix_time_from_datetime_string("2026-11-08T12:00:00")


static func fx(rel: String) -> String:
	return ProjectSettings.globalize_path("res://tests/fixtures/discover/" + rel)


## A fresh, empty folder under user://tests/.
static func temp_dir(name: String) -> String:
	var dir := "user://tests/%s_%d" % [name, randi()]
	wipe(dir)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	return dir


static func wipe(dir: String) -> void:
	var abs := ProjectSettings.globalize_path(dir)
	var d := DirAccess.open(abs)
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)
	DirAccess.remove_absolute(abs)


## Every source answering from fixtures.
static func online_http() -> RefCounted:
	var http := FakeHttp.new()
	http.route(CS + "deals", {"file": fx("cs_deals.json")})
	http.route(CS + "stores", {"file": fx("cs_stores.json")})
	http.route(CS + "games?title=", {"file": fx("cs_search.json")})
	http.route(CS + "games?ids=", {"file": fx("cs_multi.json")})
	http.route(CS + "games?steamAppID=49520", {"text": '[{"gameID":"88304","steamAppID":"49520","cheapest":"1.99","cheapestDealID":"x","external":"Borderlands 2","thumb":""}]'})
	http.route(CS + "games?steamAppID=3900", {"text": '[{"gameID":"126","steamAppID":"3900","cheapest":"2.78","cheapestDealID":"y","external":"Sid Meier\'s Civilization IV","thumb":""}]'})
	http.route(CS + "games?steamAppID=", {"text": "[]"})
	http.route(STEAM_ITEMS, {"file": fx("steam_items_ca.json")})
	http.route(STEAM_WISHLIST, {"file": fx("steam_wishlist.json")})
	http.route("https://steamcommunity.com/id/robinwalker/", {"file": fx("steam_profile.xml")})
	http.route("https://steamcommunity.com/id/", {"file": fx("steam_profile_missing.xml")})
	http.route(UPCOMING, {"file": fx("upcoming.json.gz")})
	return http


## A Discover node (not in the tree: no timers, no real network) for Canada.
static func make(http: Variant, dir: String) -> Node:
	var d: Node = DiscoverScript.new()
	d.http = http
	d.data_dir = dir
	d.privacy_path = dir.path_join("settings.cfg")          # "Background lookups" from the test's own file
	d.clock = func() -> int: return now()
	d.home = "/nonexistent"                                 # never the real home
	d.detected_region = {"country": "US", "source": "default"}
	d.load_all()
	d.set_settings({"country": "CA"})
	return d
