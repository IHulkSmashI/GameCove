extends "res://tests/test_case.gd"
## Change artwork: SteamGridDB requests and answers (synthetic answers in the
## API's shape), keys, GameCove's picked art, Steam's grid folder with backup
## and restore, the automatic fill and its gates. No network.

const Sgdb := preload("res://scripts/library/art/sgdb.gd")
const SteamGrid := preload("res://scripts/library/art/steam_grid.gd")
const Overrides := preload("res://scripts/library/art/art_overrides.gd")
const ArtService := preload("res://scripts/library/art/art_service.gd")
const Privacy := preload("res://scripts/system/privacy.gd")
const FakeHttp := preload("res://scripts/discover/fake_http.gd")
const KEY := "0123456789abcdef0123456789abcdef"


func fx(name: String) -> String:
	return fixture("metadata/" + name)


static func tmp(name: String) -> String:
	var d := ProjectSettings.globalize_path("user://tests/art_%s_%d" % [name, randi()])
	DirAccess.make_dir_recursive_absolute(d)
	return d


static func wipe(dir: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for sub in d.get_directories():
		wipe(dir.path_join(sub))
	for f in d.get_files():
		d.remove(f)
	DirAccess.remove_absolute(dir)


static func put(path: String, bytes: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()


func test_urls_and_filters() -> void:
	var u := Sgdb.assets_url("cover", "1145360", true)
	ok(u.begins_with(Sgdb.API + "grids/steam/1145360?"), u)
	ok(u.contains("dimensions=600x900,342x482,660x930") and u.contains("types=static") and u.contains("nsfw=false") and u.contains("humor=false"), "defaults: portrait, static, no NSFW/humour")
	var h := Sgdb.assets_url("hero", "5247", false, {"styles": ["blurred", "white_logo"], "animated": true, "static": false}, 2)
	ok(h.begins_with(Sgdb.API + "heroes/game/5247?page=2") and h.contains("styles=blurred&") and h.contains("types=animated"), h)
	ok(Sgdb.assets_url("logo", "1", true).begins_with(Sgdb.API + "logos/steam/1?"), "logos")
	ok(Sgdb.assets_url("icon", "1", true).begins_with(Sgdb.API + "icons/steam/1?"), "icons")


func test_parse_and_best() -> void:
	var a := Sgdb.parse_assets(FileAccess.get_file_as_bytes(fx("sgdb_grids.json")))
	eq(a.map(func(x): return x["id"]), [101, 102, 103], "webm and http left out")
	eq(a[0]["author"], "ArtistOne", "author")
	eq(a[0]["author_url"], "https://www.steamgriddb.com/profile/76561198000000001", "author page")
	eq(Sgdb.credit(a[0]), "Art by ArtistOne on SteamGridDB", "credit")
	eq(Sgdb.best(a)["id"], 102, "top score that's not NSFW")
	eq(Sgdb.parse_game_id(FileAccess.get_file_as_bytes(fx("sgdb_search.json")), "Hades"), 5247, "exact name over the first hit")
	eq(Sgdb.parse_assets(FileAccess.get_file_as_bytes(fx("sgdb_error.json"))), [], "error answer")


func test_only_the_users_own_key() -> void:
	eq(Sgdb.key(""), "", "no key: nothing to fall back on (none ships with GameCove)")
	eq(Sgdb.key(KEY), KEY, "the user's key")
	eq(Sgdb.key(" " + KEY + "\n"), KEY, "pasted with spaces")
	eq(Sgdb.key("not-a-key"), "", "a bad key is ignored")
	ok(not "PROJECT_KEYS" in Sgdb.new().get_script().get_script_constant_map(), "no project key path")


func test_steam_grid_backup_and_restore() -> void:
	var dir := tmp("grid")
	var grid := dir.path_join("steam/userdata/123/config/grid")
	var backup := dir.path_join("backup/123")
	var cover := FileAccess.get_file_as_bytes(fixture("discover/cover_jpg.bin"))
	var hero := FileAccess.get_file_as_bytes(fixture("discover/hero_png.bin"))
	put(grid.path_join("400p.png"), hero)                      # the user's own earlier art
	put(dir.path_join("new.jpg"), cover)
	var w := SteamGrid.apply(grid, backup, "400", "cover", dir.path_join("new.jpg"))
	eq(w, grid.path_join("400p.jpg"), "written as jpg")
	ok(not FileAccess.file_exists(grid.path_join("400p.png")), "old file out of the way")
	eq(FileAccess.get_file_as_bytes(backup.path_join("400p.png")), hero, "original backed up")
	# a second pick keeps the first original in the backup
	put(dir.path_join("other.png"), hero)
	SteamGrid.apply(grid, backup, "400", "cover", dir.path_join("other.png"))
	eq(SteamGrid.read_manifest(backup)["400p"]["had"], ["400p.png"], "manifest keeps the original")
	# logo position file
	ok(SteamGrid.set_logo_position(grid, backup, "400", "UpperCenter", 60, 40), "logo position")
	eq(SteamGrid.logo_position(grid, "400"), {"pin": "UpperCenter", "width": 60.0, "height": 40.0}, "read back")
	ok(not SteamGrid.set_logo_position(grid, backup, "400", "Nowhere", 50, 50), "unknown pin refused")
	# reset puts everything back as it was
	ok(SteamGrid.reset(grid, backup, "400p"), "reset cover")
	eq(FileAccess.get_file_as_bytes(grid.path_join("400p.png")), hero, "original restored")
	ok(not FileAccess.file_exists(grid.path_join("400p.jpg")), "ours removed")
	ok(SteamGrid.reset(grid, backup, "400.json"), "reset logo position")
	ok(not FileAccess.file_exists(grid.path_join("400.json")), "position file gone (there was none)")
	eq(SteamGrid.read_manifest(backup), {}, "manifest empty")
	ok(SteamGrid.reset(grid, backup, "400_hero"), "reset of something never changed is fine")
	eq(SteamGrid.base_name("40a", "cover"), "", "only numeric app ids")
	wipe(dir)


func _service(http: Variant, dir: String) -> Node:
	var s: Node = ArtService.new()
	s.http = http
	s.picked_dir = dir.path_join("picked")
	s.thumbs_dir = dir.path_join("thumbs")
	s.backup_root = dir.path_join("backup")
	s.prefs_path = dir.path_join("settings.cfg")
	s.steam_roots = [dir.path_join("steam")]
	s.user_key_fn = func() -> String: return KEY
	s.sync_mode = true
	return s


func _routes(http: Variant) -> void:
	http.route(Sgdb.API + "grids/steam/400", {"file": fx("sgdb_grids.json")})
	http.route(Sgdb.API + "grids/game/5247", {"file": fx("sgdb_grids.json")})
	http.route(Sgdb.API + "heroes/steam/400", {"file": fx("sgdb_grids.json")})
	http.route(Sgdb.API + "logos/steam/400", {"file": fx("sgdb_grids.json")})
	http.route(Sgdb.API + "search/autocomplete/", {"file": fx("sgdb_search.json")})
	http.route("https://cdn2.steamgriddb.com/", {"file": fixture("discover/cover_jpg.bin")})


func test_pick_applies_to_gamecove_and_steam_then_resets() -> void:
	var dir := tmp("svc")
	var hero := FileAccess.get_file_as_bytes(fixture("discover/hero_png.bin"))
	var grid := dir.path_join("steam/userdata/77/config/grid")
	put(grid.path_join("400p.png"), hero)
	var http := FakeHttp.new()
	_routes(http)
	var s := _service(http, dir)
	var game := {"key": "steam:400", "store": "steam", "id": "400", "title": "Portal", "art": {"cover": "", "hero": "", "logo": "", "icon": ""}}
	var found := []
	s.search(game, "cover", {}, 0, func(a, e): found.append([a, e]))
	eq(found[0][1], "", "no error")
	eq(found[0][0].size(), 3, "assets")
	ok(str(http.options[0]["headers"]).contains("Bearer " + KEY), "key in the bearer header")
	var changed := []
	s.art_changed.connect(func(k): changed.append(k))
	var res := []
	s.apply(game, "cover", found[0][0][0], true, func(ok_, msg): res.append([ok_, msg]))
	ok(res[0][0], "applied: %s" % [res[0]])
	eq(changed, ["steam:400"], "art_changed")
	var o: Dictionary = s.override_for(game, "cover")
	eq([o["source"], o["author"]], ["user", "ArtistOne"], "credited pick")
	ok(FileAccess.file_exists(o["path"]), "file in GameCove's art")
	ok(FileAccess.file_exists(grid.path_join("400p.jpg")) and not FileAccess.file_exists(grid.path_join("400p.png")), "and in Steam's grid")
	eq(Overrides.apply({"cover": "/nope.jpg"}, Overrides.read(ProjectSettings.globalize_path(s.picked_dir))["steam:400"])["cover"], o["path"], "the pick wins")
	ok(s.reset(game, "cover"), "reset")
	ok(FileAccess.file_exists(grid.path_join("400p.png")) and not FileAccess.file_exists(grid.path_join("400p.jpg")), "Steam's original back")
	eq(s.override_for(game, "cover"), {}, "pick forgotten")
	ok(not FileAccess.file_exists(o["path"]), "file deleted")
	# Steam left alone when the option is off
	s.apply(game, "cover", found[0][0][1], false, func(_a, _b): pass)
	ok(FileAccess.file_exists(grid.path_join("400p.png")) and not FileAccess.file_exists(grid.path_join("400p.jpg")), "Steam untouched")
	s.free()
	wipe(dir)


func test_non_steam_game_by_title_and_auto_fill() -> void:
	var dir := tmp("auto")
	var http := FakeHttp.new()
	_routes(http)
	var s := _service(http, dir)
	var epic := {"key": "epic:Hades", "store": "epic", "id": "Hades", "title": "Hades", "info": {"meta": {"steam_twin": ""}},
		"art": {"cover": "", "hero": "", "logo": "", "icon": ""}}
	var got := []
	s.search(epic, "cover", {}, 0, func(a, _e): got.append(a.size()))
	eq(got, [3], "found by title")
	ok(http.requests[0].begins_with(Sgdb.API + "search/autocomplete/Hades"), "SteamGridDB search")
	ok(http.requests[1].begins_with(Sgdb.API + "grids/game/5247"), "then that game's grids")
	# auto fill: needs both switches
	Privacy.set_background_allowed(false, s.prefs_path)
	eq(s.auto_fill([epic]), 0, "off with Background lookups off")
	Privacy.set_background_allowed(true, s.prefs_path)
	Privacy.set_metadata_allowed(false, s.prefs_path)
	eq(s.auto_fill([epic]), 0, "off with Look up game details off")
	ok(s.unavailable_reason().contains("Look up game details"), "reason")
	Privacy.set_metadata_allowed(true, s.prefs_path)
	var steam_game := {"key": "steam:400", "store": "steam", "id": "400", "title": "Portal", "art": {"cover": "", "hero": "", "logo": "", "icon": ""}}
	eq(s.auto_fill([steam_game]), 3, "cover, hero and logo missing")
	var o: Dictionary = s.override_for(steam_game, "cover")
	eq([o["source"], o["id"]], ["auto", 102], "top-rated, safe asset")
	ok(not DirAccess.dir_exists_absolute(dir.path_join("steam/userdata")), "the automatic fill never writes to Steam")
	eq(s.auto_fill([steam_game]), 0, "tried once a week")
	var art := Overrides.apply({"cover": "", "hero": "", "logo": "", "icon": ""}, Overrides.read(ProjectSettings.globalize_path(s.picked_dir))["steam:400"])
	ok(art["cover"] != "" and art["hero"] != "" and art["logo"] != "", "filled")
	ok(Overrides.apply({"cover": art["cover"]}, {"cover": {"path": "/elsewhere.jpg", "source": "auto"}})["cover"] == art["cover"], "auto never replaces existing art")
	s.user_key_fn = func() -> String: return ""
	ok(s.unavailable_reason().contains("SteamGridDB key"), "no key: says how to add one")
	s.free()
	wipe(dir)
