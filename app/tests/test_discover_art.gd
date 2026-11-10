extends "res://tests/test_case.gd"
## Art: source order, image checks, SteamGridDB only with a key, LRU cache.

const H := preload("res://tests/fixtures/discover/helpers.gd")
const ArtScript := preload("res://scripts/discover/art.gd")
const FakeHttp := preload("res://scripts/discover/fake_http.gd")
const CDN := "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/"


func _make(http: Variant, dir: String) -> Node:
	var a: Node = ArtScript.new()
	a.http = http
	a.cache_dir = dir
	a.clock = func() -> int: return H.now()
	return a


func test_steam_cdn_by_appid_and_cache_hit() -> void:
	var dir := H.temp_dir("art_cdn")
	var http := FakeHttp.new()
	http.route(CDN + "10/library_600x900.jpg", {"file": H.fx("cover_jpg.bin")})
	var a := _make(http, dir)
	var got := []
	a.art_ready.connect(func(k, kind, p): got.append([k, kind, p]))
	eq(a.request("steam:10", "cover"), "", "not cached yet")
	eq(got.size(), 1, "art_ready")
	eq([got[0][0], got[0][1]], ["steam:10", "cover"], "key and kind")
	ok(got[0][2].ends_with(".jpg") and FileAccess.file_exists(got[0][2]), "cached file")
	eq(a.request("steam:10", "cover"), got[0][2], "second ask returns the path at once")
	eq(http.requests.size(), 1, "no second download")
	eq(a.request("steam:10", "banner"), "", "unknown kind")
	a.free()
	H.wipe(dir)


func test_remembered_hashed_url_first_then_fallbacks() -> void:
	var dir := H.temp_dir("art_order")
	var http := FakeHttp.new()
	var hashed := CDN + "20/abc/library_capsule.jpg?t=1"
	http.route(hashed, {"file": H.fx("not_image.html")})          # a junk answer
	http.route(CDN + "20/library_600x900.jpg", {"error": "http 404", "code": 404})
	var a := _make(http, dir)
	a.remember("steam:20", {"cover": hashed, "nonsense": "x"})
	var got := []
	a.art_ready.connect(func(k, kind, p): got.append(p))
	a.request("steam:20", "cover")
	eq(http.requests, [hashed, CDN + "20/library_600x900.jpg"], "remembered URL, then plain pattern; no SteamGridDB without a key")
	eq(got, [""], "nothing usable: empty path")
	eq(DirAccess.get_files_at(ProjectSettings.globalize_path(dir)).size(), 0, "junk not kept")
	a.request("steam:20", "cover")
	eq(http.requests.size(), 2, "failure remembered for a day")
	a.clock = func() -> int: return H.now() + 86401
	a.request("steam:20", "cover")
	eq(http.requests.size(), 4, "tried again the next day")
	a.free()
	H.wipe(dir)


func test_steamgriddb_with_user_key() -> void:
	var dir := H.temp_dir("art_sgdb")
	var http := FakeHttp.new()
	http.route(CDN + "30/library_hero.jpg", {"error": "http 404", "code": 404})
	http.route("https://www.steamgriddb.com/api/v2/heroes/steam/30", {"file": H.fx("sgdb_grids.json")})
	http.route("https://www.steamgriddb.com/api/v2/search/autocomplete/", {"file": H.fx("sgdb_search.json")})
	http.route("https://www.steamgriddb.com/api/v2/grids/game/5551", {"file": H.fx("sgdb_grids.json")})
	http.route("https://cdn2.steamgriddb.com/grid/abc.png", {"file": H.fx("hero_png.bin")})
	var a := _make(http, dir)
	a.api_key = "user-key"
	var got := []
	a.art_ready.connect(func(k, kind, p): got.append(p))
	a.request("steam:30", "hero")
	ok(got[0].ends_with(".png"), "SteamGridDB image cached as png")
	ok(http.requests.has("https://www.steamgriddb.com/api/v2/heroes/steam/30?types=static"), "hero by Steam id")
	a.request("epic:fortnite", "cover", {"title": "Some Game"})
	ok(http.requests.any(func(u): return u.begins_with("https://www.steamgriddb.com/api/v2/search/autocomplete/Some%20Game")), "title search")
	ok(http.requests.has("https://www.steamgriddb.com/api/v2/grids/game/5551?dimensions=600x900&types=static"), "cover by SteamGridDB id")
	ok(got[1] != "", "found by title")
	eq(ArtScript.parse_sgdb('{"success":false}'.to_utf8_buffer()), "", "error answer")
	a.free()
	H.wipe(dir)


func test_hint_url_and_sniff() -> void:
	var dir := H.temp_dir("art_hint")
	var http := FakeHttp.new()
	http.route("https://images.igdb.com/igdb/image/upload/t_cover_big/x.jpg", {"file": H.fx("cover_jpg.bin")})
	var a := _make(http, dir)
	a.request("title:x", "cover", {"url": "https://images.igdb.com/igdb/image/upload/t_cover_big/x.jpg"})
	ok(a.path_for("title:x", "cover") != "", "cached from hint url")
	eq(a.candidates("title:y", "cover", {"url": "http://insecure/x.jpg"}), ["http://insecure/x.jpg"], "candidate kept...")
	var got := []
	a.art_ready.connect(func(k, kind, p): got.append(p))
	a.request("title:y", "cover", {"url": "http://insecure/x.jpg"})
	eq(got, [""], "...but only https is downloaded")
	eq(ArtScript.sniff(PackedByteArray([0xFF, 0xD8, 0xFF, 0])), "jpg", "jpg")
	eq(ArtScript.sniff("RIFF0000WEBPVP8 ".to_utf8_buffer()), "webp", "webp")
	eq(ArtScript.sniff("<html>".to_utf8_buffer()), "", "html")
	a.free()
	H.wipe(dir)


func test_only_known_image_hosts() -> void:
	# review problem 4: a URL from upcoming.json.gz or a store answer can name any https host; only Steam's,
	# IGDB's and SteamGridDB's image CDNs are asked
	var dir := H.temp_dir("art_hosts")
	var http := FakeHttp.new()
	for u in ["https://tracker.example/x.jpg", "https://images.igdb.com.evil.example/x.jpg", "https://user@images.igdb.com/x.jpg"]:
		http.route(u, {"file": H.fx("cover_jpg.bin")})
	var a := _make(http, dir)
	var got := []
	a.art_ready.connect(func(k, kind, p): got.append(p))
	a.request("title:a", "cover", {"url": "https://tracker.example/x.jpg"})
	a.remember("title:b", {"cover": "https://images.igdb.com.evil.example/x.jpg"})
	a.request("title:b", "cover")
	a.request("title:c", "cover", {"url": "https://user@images.igdb.com/x.jpg"})
	eq(http.requests, [], "nothing asked of another host")
	eq(got, ["", "", ""], "no art")
	a.free()
	H.wipe(dir)


func test_lru_cleanup() -> void:
	var dir := H.temp_dir("art_lru")
	var http := FakeHttp.new()
	for id in ["1", "2", "3"]:
		http.route(CDN + id + "/library_600x900.jpg", {"file": H.fx("cover_jpg.bin")})
	var a := _make(http, dir)
	a.max_bytes = 160   # each fixture image is 64 bytes; clean-up goes down to 80%
	a.request("steam:1", "cover")
	a.clock = func() -> int: return H.now() + 10
	a.request("steam:2", "cover")
	a.clock = func() -> int: return H.now() + 20
	a.request("steam:1", "cover")      # touch 1: now 2 is the oldest
	a.clock = func() -> int: return H.now() + 30
	a.request("steam:3", "cover")
	ok(a.path_for("steam:1", "cover") != "", "recently used kept")
	eq(a.path_for("steam:2", "cover"), "", "least recently used removed")
	ok(a.path_for("steam:3", "cover") != "", "new one kept")
	ok(a.total_bytes() <= 128, "under 80% of the cap")
	a.free()
	# the index survives a restart
	var b := _make(FakeHttp.new(), dir)
	ok(b.path_for("steam:3", "cover") != "", "index reloaded")
	b.free()
	H.wipe(dir)
