extends "res://tests/test_case.gd"
## Play time after a game ends (library.gd record_playtime): every store's game
## is read again so Home's Jump back in and the Recent sort show the session.
## Games GameCove starts itself (umu-run for Epic / GOG / Amazon, emulators) are
## counted by us; Steam's and Heroic's launches are counted by the store, never twice.

const LibraryScript := preload("res://scripts/library/library.gd")
const Playtime := preload("res://scripts/library/playtime.gd")


## The Library without its scans: re-reads asked for are only noted.
class Lib extends "res://scripts/library/library.gd":
	var refreshed: Array = []

	func refresh_store(store_name: String) -> void:
		refreshed.append(store_name)


func _lib(keys: Array) -> Lib:
	var l := Lib.new()
	for k in keys:
		l._entries[k] = {"store": str(k).get_slice(":", 0), "id": str(k).get_slice(":", 1)}
	return l


func _clean() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Playtime.PATH))


func test_steam_game_ending_rereads_steam() -> void:
	_clean()
	var l := _lib(["steam:1145360"])
	l.record_playtime({"key": "steam:1145360", "store": "steam"}, 1000, 1600)
	eq(l.refreshed, ["steam"], "Steam wrote its play time: Steam's files are read again")
	eq(Playtime.read(), {}, "and we don't count it a second time")
	l.free()


func test_umu_launched_epic_game_counted_by_us() -> void:
	_clean()
	var l := _lib(["epic:Salt", "gog:1", "amazon:a"])
	for k in ["epic:Salt", "gog:1", "amazon:a"]:
		l.record_playtime({"key": k, "store": k.get_slice(":", 0)}, 1000, 1600)
	eq(l.refreshed, ["epic", "gog", "amazon"], "each store read again")
	var t := Playtime.read()
	eq(t.get("epic:Salt"), {"last_played": 1600, "playtime_min": 10}, "ten minutes of Rocket League counted")
	ok(t.has("gog:1") and t.has("amazon:a"), "GOG and Amazon too")
	_clean()
	l.free()


func test_heroic_launch_counted_by_heroic() -> void:
	_clean()
	var l := _lib(["epic:Salt"])
	l._heroic_launched["epic:Salt"] = true
	l.record_playtime({"key": "epic:Salt", "store": "epic"}, 1000, 1600)
	eq(l.refreshed, ["epic"], "Heroic's own count read again")
	eq(Playtime.read(), {}, "not counted by us as well")
	ok(not l._heroic_launched.has("epic:Salt"), "the next launch decides afresh")
	l.free()


func test_short_or_unknown_sessions() -> void:
	_clean()
	var l := _lib(["emu:frontend"])
	l.record_playtime({"key": "emu:frontend", "store": "emu"}, 1000, 1005)
	eq(l.refreshed, [], "a 5 s launch that failed: nothing to show")
	l.record_playtime({"key": "steam:9", "store": "steam"}, 1000, 1600)
	eq(l.refreshed, [], "a game the Library doesn't have: nothing read")
	l.free()
