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


## Review 2, problem 9: native and Flatpak Steam with the same account id shared one
## backup folder; after apply then reset one root lost its original.
func test_two_steam_roots_with_one_account_keep_their_own_backups() -> void:
	var dir := tmp("tworoots")
	var native := dir.path_join("native/userdata/123/config/grid")
	var flatpak := dir.path_join("flatpak/userdata/123/config/grid")
	var a := FileAccess.get_file_as_bytes(fixture("discover/cover_jpg.bin"))
	var b := FileAccess.get_file_as_bytes(fixture("discover/hero_png.bin"))
	put(native.path_join("400p.jpg"), a)
	put(flatpak.path_join("400p.png"), b)
	put(dir.path_join("new.png"), b)
	var root := dir.path_join("backup")
	var bn := SteamGrid.backup_dir_for(root, native)
	var bf := SteamGrid.backup_dir_for(root, flatpak)
	ok(bn != bf, "one backup folder per grid folder")
	SteamGrid.apply(native, bn, "400", "cover", dir.path_join("new.png"))
	SteamGrid.apply(flatpak, bf, "400", "cover", dir.path_join("new.png"))
	ok(SteamGrid.reset(native, bn, "400p") and SteamGrid.reset(flatpak, bf, "400p"), "both reset")
	eq(FileAccess.get_file_as_bytes(native.path_join("400p.jpg")), a, "native original back")
	eq(FileAccess.get_file_as_bytes(flatpak.path_join("400p.png")), b, "flatpak original back")
	# the same folder through a symlink is the same backup
	DirAccess.open(dir).create_link(dir.path_join("native"), dir.path_join("link"))
	eq(SteamGrid.backup_dir_for(root, dir.path_join("link/userdata/123/config/grid")), bn, "symlinked path, same backup")
	wipe(dir)


func _service(http: Variant, dir: String) -> Node:
	var s: Node = ArtService.new()
	s.http = http
	s.picked_dir = dir.path_join("picked")
	s.thumbs_dir = dir.path_join("thumbs")
	s.backup_root = dir.path_join("backup")
	s.prefs_path = dir.path_join("settings.cfg")
	s.auto_tried_path = dir.path_join("auto_tried.json")
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


## Review Medium (privacy): saving a SteamGridDB key in setup filled the art of every game, ROMs
## included, so ROM titles went to SteamGridDB against docs/PRIVACY.md ("no art is looked up
## online for a ROM"). The filter lives in auto_fill, so every caller is covered.
func test_auto_fill_never_asks_about_a_rom() -> void:
	var dir := tmp("autorom")
	var http := FakeHttp.new()
	_routes(http)
	var s := _service(http, dir)
	var rom := {"key": "emu:3000000001", "store": "emu", "id": "3000000001", "title": "Moonlit Harbor",
		"emulated": {"system": "snes", "system_short": "SNES", "rom": true}, "art": {"cover": "", "hero": "", "logo": "", "icon": ""}}
	var steam_game := {"key": "steam:400", "store": "steam", "id": "400", "title": "Portal", "art": {"cover": "", "hero": "", "logo": "", "icon": ""}}
	eq(s.auto_fill([rom]), 0, "a ROM alone: nothing queued")
	eq(http.requests.size(), 0, "and nothing sent anywhere")
	eq(s.auto_fill([rom, steam_game]), 3, "next to a PC game only that one's three pictures")
	ok(not http.requests.any(func(r): return r.contains("Moonlit")), "the ROM's title was never sent")
	s.free()
	wipe(dir)


## Review 56f5255: the same wrong-type answers parse_sgdb skips used to raise inside parse_assets / parse_game_id.
func test_sgdb_answers_with_the_wrong_types_do_not_raise() -> void:
	var body := ('{"success":true,"data":[{"id":null,"url":"https://cdn2.steamgriddb.com/a.png","width":null,"height":{"x":1},'
		+ '"score":"high","nsfw":"yes","humor":null,"animated":[1]},{"id":7,"url":"https://cdn2.steamgriddb.com/b.png","width":600,"height":900}]}').to_utf8_buffer()
	var a := Sgdb.parse_assets(body)
	eq(a.size(), 2, "both entries survive")
	eq([a[0]["id"], a[0]["width"], a[0]["height"], a[0]["score"]], [0, 0, 0, 0], "odd numbers are 0")
	eq([a[0]["nsfw"], a[0]["humor"], a[0]["animated"]], [false, false, false], "odd flags are false")
	eq(a[1]["id"], 7, "a good entry is kept")
	eq(Sgdb.parse_game_id('{"success":true,"data":[{"id":null,"name":"X"}]}'.to_utf8_buffer(), "X"), 0, "a null id is none")


## Review 56f5255: Change artwork sent a ROM game's title to SteamGridDB's search.
func test_change_artwork_never_sends_a_rom_title() -> void:
	var dir := tmp("manualrom")
	var http := FakeHttp.new()
	_routes(http)
	var s := _service(http, dir)
	var rom := {"key": "emu:3000000001", "store": "emu", "id": "3000000001", "title": "Moonlit Harbor",
		"emulated": {"system": "snes", "system_short": "SNES", "rom": true}, "art": {"cover": "", "hero": "", "logo": "", "icon": ""}}
	var got := []
	s.search(rom, "cover", {}, 0, func(assets, err): got.append([assets, err]))
	eq(got.size(), 1, "answered at once")
	ok(str(got[0][1]) != "" and got[0][0].is_empty(), "with a reason and no pictures")
	eq(http.requests.size(), 0, "and nothing sent anywhere")
	s.free()
	wipe(dir)


## Review 2, low 23: the automatic fill forgot what it had tried at every start, and its
## queue kept draining after a switch went off.
func test_auto_fill_remembers_tries_and_stops_with_the_switch() -> void:
	var dir := tmp("auto2")
	var http := FakeHttp.new()
	_routes(http)
	var s := _service(http, dir)
	var steam_game := {"key": "steam:400", "store": "steam", "id": "400", "title": "Portal", "art": {"cover": "", "hero": "", "logo": "", "icon": ""}}
	eq(s.auto_fill([steam_game]), 3, "tried")
	s.free()
	var s2 := _service(http, dir)
	eq(s2.auto_fill([steam_game]), 0, "a new run remembers the tries")
	s2.clock = func() -> int: return int(Time.get_unix_time_from_system()) + 8 * 86400
	s2.free()
	var s3 := _service(http, dir)
	s3.clock = func() -> int: return int(Time.get_unix_time_from_system()) + 8 * 86400
	eq(s3.auto_fill([steam_game]), 3, "a week later it tries again")
	s3.free()
	# queued, then Background lookups goes off: the rest isn't asked
	var s4 := _service(http, dir)
	s4.sync_mode = false
	var other := {"key": "steam:401", "store": "steam", "id": "401", "title": "Portal 2", "art": {"cover": "", "hero": "", "logo": "", "icon": ""}}
	eq(s4.auto_fill([other]), 3, "queued")
	var before := http.requests.size()
	Privacy.set_background_allowed(false, s4.prefs_path)
	s4._auto_next()
	eq(http.requests.size(), before, "nothing asked after the switch went off")
	eq(s4._auto.size(), 0, "queue dropped")
	s4.free()
	wipe(dir)


func test_auto_fill_waits_behind_a_game() -> void:
	var dir := tmp("autopause")
	var http := FakeHttp.new()
	_routes(http)
	var s := _service(http, dir)
	var steam_game := {"key": "steam:400", "store": "steam", "id": "400", "title": "Portal", "art": {"cover": "", "hero": "", "logo": "", "icon": ""}}
	s.set_paused(true)
	eq(s.auto_fill([steam_game]), 3, "queued behind a game")
	eq(http.requests.size(), 0, "nothing fetched while a game runs")
	s.set_paused(false)
	ok(http.requests.size() >= 3, "the game ended: filled")
	s.free()
	wipe(dir)


## Final review, medium (other data): art the user set in Steam after GameCove's pick is
## theirs. A second pick backs it up (it used to be overwritten with no copy) and Reset
## leaves it alone (it used to be deleted and replaced by the older original).
func test_art_the_user_set_in_steam_later_is_kept() -> void:
	var dir := tmp("grid_later")
	var grid := dir.path_join("steam/userdata/123/config/grid")
	var backup := dir.path_join("backup/123")
	var cover := FileAccess.get_file_as_bytes(fixture("discover/cover_jpg.bin"))
	var hero := FileAccess.get_file_as_bytes(fixture("discover/hero_png.bin"))
	var users := hero.duplicate()
	users.append_array(PackedByteArray([1, 2, 3]))   # stands for another image the user chose later
	put(grid.path_join("400p.png"), hero)                      # the original, before GameCove
	put(dir.path_join("pick1.jpg"), cover)
	put(dir.path_join("pick2.jpg"), cover)
	SteamGrid.apply(grid, backup, "400", "cover", dir.path_join("pick1.jpg"))
	# in Steam the user replaces GameCove's cover with one of their own
	DirAccess.remove_absolute(grid.path_join("400p.jpg"))
	put(grid.path_join("400p.png"), users)
	# a second pick in GameCove: the user's later art is what Reset must bring back
	SteamGrid.apply(grid, backup, "400", "cover", dir.path_join("pick2.jpg"))
	eq(FileAccess.get_file_as_bytes(backup.path_join("400p.png")), users, "the user's later art was backed up before the second pick")
	ok(SteamGrid.reset(grid, backup, "400p"), "reset")
	eq(FileAccess.get_file_as_bytes(grid.path_join("400p.png")), users, "and Reset puts the user's later art back")
	ok(not FileAccess.file_exists(grid.path_join("400p.jpg")), "ours is gone")
	# Reset when the user changed it after the pick: their art stays, nothing older comes back
	put(grid.path_join("400p.png"), hero)
	SteamGrid.apply(grid, backup, "400", "cover", dir.path_join("pick1.jpg"))
	DirAccess.remove_absolute(grid.path_join("400p.jpg"))
	put(grid.path_join("400p.jpg"), users)                     # same name as ours, different picture
	ok(SteamGrid.reset(grid, backup, "400p"), "reset")
	eq(FileAccess.get_file_as_bytes(grid.path_join("400p.jpg")), users, "the user's art is left exactly as it is")
	ok(not FileAccess.file_exists(grid.path_join("400p.png")), "the older original isn't put on top of it")
	eq(SteamGrid.read_manifest(backup), {}, "and we no longer track that game")
	# the user removed the art in Steam after our pick: Reset doesn't bring the old one back either
	put(grid.path_join("500p.png"), hero)
	SteamGrid.apply(grid, backup, "500", "cover", dir.path_join("pick1.jpg"))
	DirAccess.remove_absolute(grid.path_join("500p.jpg"))
	ok(SteamGrid.reset(grid, backup, "500p"), "reset")
	eq(SteamGrid.existing(grid, "500p"), [] as Array[String], "no art, as the user left it")
	# the logo position file follows the same rule
	ok(SteamGrid.set_logo_position(grid, backup, "400", "UpperCenter", 60, 40), "logo position")
	put(grid.path_join("400.json"), "{\"nVersion\":1,\"logoPosition\":{\"pinnedPosition\":\"BottomLeft\",\"nWidthPct\":33,\"nHeightPct\":33}}".to_utf8_buffer())
	ok(SteamGrid.reset(grid, backup, "400.json"), "reset")
	eq(SteamGrid.logo_position(grid, "400")["pin"], "BottomLeft", "the position the user set in Steam stays")
	wipe(dir)


## Final review, low: two threads changing art at once (the automatic fill and a pick) each
## read the manifest, added their entry and wrote it back; one entry was lost and with it
## the way to put that game's original back.
func test_grid_manifest_survives_two_threads() -> void:
	var dir := tmp("grid_threads")
	var grid := dir.path_join("steam/userdata/123/config/grid")
	var backup := dir.path_join("backup/123")
	var cover := FileAccess.get_file_as_bytes(fixture("discover/cover_jpg.bin"))
	put(dir.path_join("pick.jpg"), cover)
	var per := 40
	for i in per * 4:
		put(grid.path_join("%dp.png" % (1000 + i)), cover)
	var threads: Array = []
	for t in 4:
		var th := Thread.new()
		th.start(func():
			for i in per:
				SteamGrid.apply(grid, backup, str(1000 + t * per + i), "cover", dir.path_join("pick.jpg")))
		threads.append(th)
	for th in threads:
		th.wait_to_finish()
	eq(SteamGrid.read_manifest(backup).size(), per * 4, "every game's original is still listed")
	wipe(dir)


## Final review, low: a damaged index.json read as "no picks", and the next pick wrote an
## index with just that one, dropping every other game's art for good.
func test_a_damaged_art_index_doesnt_drop_the_other_picks() -> void:
	var dir := tmp("index")
	var a := dir.path_join("a.png")
	var b := dir.path_join("b.png")
	var c := dir.path_join("c.png")
	for p in [a, b, c]:
		put(p, PackedByteArray([1, 2, 3]))
	ok(Overrides.set_override(dir, "steam:1", "cover", {"path": a, "source": "user"}), "first pick")
	ok(Overrides.set_override(dir, "steam:2", "cover", {"path": b, "source": "user"}), "second pick")
	# a power cut or a full disk leaves half an index
	var f := FileAccess.open(Overrides.index_path(dir), FileAccess.WRITE)
	f.store_string("{\"steam:1\": {\"cover\": {\"pa")
	f.close()
	var got := Overrides.read(dir)
	ok(got.has("steam:1"), "the picks from the last good index are still read")
	ok(Overrides.set_override(dir, "steam:3", "cover", {"path": c, "source": "user"}), "a new pick")
	var after := Overrides.read(dir)
	eq(after.keys().size(), 3, "and nobody's art was dropped by it")
	ok(after.has("steam:1") and after.has("steam:2") and after.has("steam:3"), "all three games")
	ok(FileAccess.file_exists(Overrides.index_path(dir) + ".bad"), "the damaged file is kept for a look")
	# both the index and its copy unreadable: nothing is written over them
	for p in [Overrides.index_path(dir), Overrides.index_path(dir) + ".bak"]:
		f = FileAccess.open(p, FileAccess.WRITE)
		f.store_string("not json")
		f.close()
	eq(Overrides.read(dir), {}, "nothing can be read")
	ok(not Overrides.set_override(dir, "steam:4", "cover", {"path": c, "source": "user"}), "and a pick isn't saved over what can't be read")
	eq(FileAccess.get_file_as_string(Overrides.index_path(dir) + ".bak"), "not json", "the copy is left for repair")
	wipe(dir)


## Review nit: a pick whose index could not be written was reported as done.
func test_a_pick_that_cannot_be_saved_is_not_reported_as_done() -> void:
	var dir := tmp("apply_fail")
	var f := FileAccess.open(Overrides.index_path(dir), FileAccess.WRITE)
	f.store_string("not json")
	f.close()
	f = FileAccess.open(Overrides.index_path(dir) + ".bak", FileAccess.WRITE)
	f.store_string("not json")
	f.close()
	var s: Node = ArtService.new()
	var got := []
	var changed := []
	s.art_changed.connect(func(k): changed.append(k))
	s._apply_finish(dir, "steam:1", "cover", {"path": dir.path_join("a.png")}, [], func(good: bool, msg: String): got.append([good, msg]))
	eq(got.size(), 1, "told once")
	eq(got[0][0], false, "not ok")
	eq(changed, [], "and nobody is told the art changed")
	s.free()
	wipe(dir)
