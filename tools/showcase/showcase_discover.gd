extends RefCounted
## The showcase's Discover: GameCove's real Discover service (deals, prices,
## wishlist, alerts and the release calendar all go through its own code),
## fed from snapshot/ (recorded once with record_discover.gd from the live
## sources) and set to Canada, on a throwaway data folder. Its clock is the
## recording time, so "ends in 2 days" and "in 5 days" read as they did then.

const DiscoverScript := preload("res://scripts/discover/discover.gd")
const SnapshotHttp := preload("snapshot_http.gd")

## Real games this profile wants: two on sale now, two full price, three not
## out yet (from the calendar).
const WISHLIST := [
	{"title": "Disco Elysium - The Final Cut", "appid": "632470", "target_price": null},
	{"title": "Kingdom Come: Deliverance II", "appid": "1771300", "target_price": 40.0},
	{"title": "Ghost of Tsushima DIRECTOR'S CUT", "appid": "2215430", "target_price": null},
	{"title": "Frostpunk", "appid": "323190", "target_price": null},
	{"title": "Fable", "appid": "2769570", "release": true},
	{"title": "METRO 2039", "appid": "2590240", "release": true},
	{"title": "Persona 4 Revival", "appid": "2963950", "release": true},
]


static func here() -> String:
	return (preload("snapshot_http.gd") as Script).resource_path.get_base_dir()


static func pinned() -> Dictionary:
	var h := here()
	return {"https://www.cheapshark.com/api/1.0/deals?": h.path_join("pinned/cs_deals.json"),
		"https://www.cheapshark.com/api/1.0/deals?onSale=1&upperPrice=0&": h.path_join("pinned/cs_free.json"),
		"https://github.com/IHulkSmashI/GameCove-data/releases/download/gamedb/upcoming.json.gz": h.path_join("pinned/upcoming.json.gz")}


## mode "record" (live, saves snapshot/) or "replay" (snapshot only).
static func make(mode: String) -> Node:
	var snap := here().path_join("snapshot")
	var http := SnapshotHttp.new(mode, snap, pinned())
	var now := int(Time.get_unix_time_from_system()) if mode == "record" else int(http.manifest.get("now", 0))
	var dir := OS.get_cache_dir().path_join("gamecove-showcase-discover")
	_wipe(dir)
	DirAccess.make_dir_recursive_absolute(dir)
	var d: Node = DiscoverScript.new()
	d.http = http
	d.data_dir = dir
	d.privacy_path = dir.path_join("privacy.cfg")
	d.clock = func() -> int: return now
	d.home = "/nonexistent"
	d.detected_region = {"country": "CA", "source": "timezone"}
	d.load_all()
	d.set_settings({"country": "CA"})
	for w in WISHLIST:
		var k: String = d.add_to_wishlist({"title": w["title"], "appid": w["appid"]})
		if w.get("target_price") != null:
			d.set_target_price(k, w["target_price"])
		if w.get("release", false):
			d.set_notify(k, true, true)
	# MAX_RESOLVE wishlist ids per refresh: refresh until all are resolved.
	for i in 3:
		d.refresh(true)
	if mode == "record":
		http.save_manifest({"now": now, "recorded": Time.get_datetime_string_from_unix_time(now, true) + "Z"})
	d.set_meta("snapshot_http", http)
	return d


static func _wipe(dir: String) -> void:
	var da := DirAccess.open(dir)
	if da == null:
		return
	for f in da.get_files():
		da.remove(f)
