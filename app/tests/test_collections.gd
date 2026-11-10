extends "res://tests/test_case.gd"
## Favourites, hidden games and collections (scripts/library/collections.gd),
## Steam's collections read from its cloud-storage file (never written), the
## Library views and Home shelves that use them, and the flows on the sheet.

const Collections := preload("res://scripts/library/collections.gd")
const LibraryScript := preload("res://scripts/library/library.gd")
const View := preload("res://scripts/ui/library_view.gd")
const Badges := preload("res://scripts/ui/badges.gd")
const LibraryScreen := preload("res://scripts/ui/library_screen.gd")
const CollectionActions := preload("res://scripts/ui/games/collection_actions.gd")
const GameActions := preload("res://scripts/ui/games/game_actions.gd")
const SettingsFile := preload("res://scripts/system/settings_file.gd")
const Logic := preload("res://tests/test_ui_logic.gd")
const TL := preload("res://scripts/ui/texts_library.gd")

const BASE := "user://test_collections"

## Steam's cloud-storage file: favourites (one removed again), hidden, a
## collection, a deleted one, a dynamic one and an unrelated key.
const CLOUD := """[
 ["user-collections.favorite", {"key": "user-collections.favorite", "timestamp": 1700000000, "value": "{\\"id\\":\\"favorite\\",\\"added\\":[620,440,570],\\"removed\\":[570]}", "version": "12"}],
 ["user-collections.hidden", {"key": "user-collections.hidden", "timestamp": 1700000000, "value": "{\\"id\\":\\"hidden\\",\\"added\\":[730],\\"removed\\":[]}", "version": "3"}],
 ["user-collections.uc-AbC123", {"key": "user-collections.uc-AbC123", "timestamp": 1700000000, "value": "{\\"id\\":\\"uc-AbC123\\",\\"name\\":\\"Couch co-op\\",\\"added\\":[620,3000000001],\\"removed\\":[]}", "version": "5", "conflictResolutionMethod": "custom", "strMethodId": "union-collections"}],
 ["user-collections.uc-Gone", {"key": "user-collections.uc-Gone", "timestamp": 1700000000, "is_deleted": true, "version": "6"}],
 ["user-collections.uc-Dyn", {"key": "user-collections.uc-Dyn", "timestamp": 1700000000, "value": "{\\"id\\":\\"uc-Dyn\\",\\"name\\":\\"Short\\",\\"added\\":[],\\"removed\\":[],\\"filterSpec\\":{\\"nFormatVersion\\":2}}", "version": "7"}],
 ["showcases.news", {"key": "showcases.news", "timestamp": 1, "value": "{}"}]
]"""


func _dir(name: String) -> String:
	var p := ProjectSettings.globalize_path(BASE).path_join(name)
	_rm(p)
	DirAccess.make_dir_recursive_absolute(p)
	return p


func _rm(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.include_hidden = true
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	for sub in d.get_directories():
		_rm(path.path_join(sub))
	DirAccess.remove_absolute(path)


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _store(name: String) -> RefCounted:
	SettingsFile.reset_for_tests()
	return Collections.new(_dir(name).path_join("collections.json"))


## A home with Steam signed in as account 1 (loginusers.vdf MostRecent) and its cloud file.
func _steam_home(name: String) -> String:
	var home := _dir(name)
	var steam := home.path_join(".local/share/Steam")
	_write(steam.path_join("config/loginusers.vdf"), "\"users\"\n{\n\t\"76561197960265729\"\n\t{\n\t\t\"AccountName\"\t\"a\"\n\t\t\"MostRecent\"\t\"1\"\n\t}\n}\n")
	_write(steam.path_join("userdata/1/config/cloudstorage/cloud-storage-namespace-1.json"), CLOUD)
	# another account's file must not be read
	_write(steam.path_join("userdata/2/config/cloudstorage/cloud-storage-namespace-1.json"), "[]")
	return home


# ------------------------------------------------------------ our own lists

func test_favourites_and_hidden_are_saved() -> void:
	var c := _store("fav")
	var fired := [0]
	c.changed.connect(func(): fired[0] += 1)
	ok(not c.is_favourite("epic:Sugar"), "nothing yet")
	ok(c.set_favourite("epic:Sugar", true), "saved")
	ok(c.set_hidden("gog:1", true), "hidden saved")
	eq(fired[0], 2, "each change tells the screens")
	var again := Collections.new(c.path)
	ok(again.is_favourite("epic:Sugar") and again.is_hidden("gog:1"), "read back from collections.json")
	again.set_favourite("epic:Sugar", false)
	again.set_hidden("gog:1", false)
	var third := Collections.new(c.path)
	ok(not third.is_favourite("epic:Sugar") and not third.is_hidden("gog:1"), "turned off for good")
	var doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(c.path))
	eq(int(doc["version"]), 1, "versioned file")


func test_collections_create_rename_delete() -> void:
	var c := _store("cols")
	eq(c.create("   "), "", "no empty names")
	var id: String = c.create("  Couch co-op  ")
	eq(id, "c1", "first id")
	eq(c.create("Backlog"), "c2", "next id")
	ok(c.add(id, "steam:620") and c.add(id, "emu:3000000001") and c.add(id, "steam:620"), "added (twice is once)")
	eq(c.find(id)["games"], ["steam:620", "emu:3000000001"], "members, emulated games too")
	eq(c.find(id)["name"], "Couch co-op", "name trimmed")
	eq(c.collections_of("steam:620"), [id], "which collections a game is in")
	ok(c.rename(id, "Party"), "renamed")
	ok(not c.rename(id, ""), "never to an empty name")
	eq(c.collections().map(func(x): return x["name"]), ["Backlog", "Party"], "A to Z")
	ok(c.remove(id, "steam:620"), "removed")
	ok(c.delete("c2"), "deleted")
	ok(not c.delete("c2"), "only once")
	var again := Collections.new(c.path)
	eq(again.collections().map(func(x): return [x["name"], x["games"]]), [["Party", ["emu:3000000001"]]], "kept on disk")
	eq(c.create("A name much longer than forty characters for sure, really").length(), 2, "long names fit")
	eq(c.find("c2")["name"].length(), Collections.NAME_MAX, "cut to NAME_MAX")


func test_damaged_file_is_never_replaced() -> void:
	var c := _store("bad")
	_write(c.path, "{not json")
	expect_error("couldn't be read", 0)
	ok(not c.is_favourite("x"), "reads as empty")
	ok(not c.set_favourite("x", true), "save refused this run")
	ok(FileAccess.file_exists(c.path + ".bad"), "the damaged file kept aside")
	SettingsFile.reset_for_tests()


# ------------------------------------------------------------ Steam

func test_parse_steam_cloud() -> void:
	var p := Collections.parse_steam_cloud(CLOUD)
	eq(p["favourites"], ["620", "440"], "favourites minus removed")
	eq(p["hidden"], ["730"], "hidden")
	eq(p["collections"], [{"id": "uc-AbC123", "name": "Couch co-op", "apps": ["620", "3000000001"]}], "static collections only; deleted ones gone")
	eq(p["dynamic"], 1, "dynamic collections counted, not guessed")
	eq(Collections.parse_steam_cloud("not json")["collections"], [], "broken file: nothing")
	eq(Collections.parse_steam_cloud("{}")["favourites"], [], "wrong shape: nothing")
	var k := Collections.steam_to_keys(p)
	ok("steam:620" in k["favourites"] and "emu:620" in k["favourites"], "a Steam id can be a Steam game or an SRM shortcut")
	eq(k["collections"][0]["id"], "steam-uc-AbC123", "Steam ids kept apart from ours")


func test_steam_import_is_read_only() -> void:
	var home := _steam_home("steamhome")
	var file := Collections.steam_cloud_file(home, ["~/.local/share/Steam", "~/.steam/steam"])
	ok(file.ends_with("userdata/1/config/cloudstorage/cloud-storage-namespace-1.json"), "the signed-in account's file")
	var before := FileAccess.get_file_as_string(file)
	var r := LibraryScript.collect(home, "/nonexistent/gamedb.json.gz")
	var c := _store("steamimport")
	c.set_imported(r["imported"])
	ok(c.is_favourite("steam:620") and c.is_hidden("steam:730"), "Steam's favourites and hidden games")
	var steam_cols: Array = c.collections().filter(func(x): return x["read_only"])
	eq(steam_cols.map(func(x): return x["name"]), ["Couch co-op"], "Steam's collection shows")
	ok(not c.add(steam_cols[0]["id"], "epic:Sugar") and not c.rename(steam_cols[0]["id"], "x") and not c.delete(steam_cols[0]["id"]), "and can't be changed here")
	ok(c.set_favourite("steam:620", false), "unfavourite a Steam favourite")
	ok(not c.is_favourite("steam:620"), "off here")
	eq(FileAccess.get_file_as_string(file), before, "Steam's file untouched")
	c.set_favourite("steam:620", true)
	ok(c.is_favourite("steam:620"), "and back on (the override dropped)")
	ok(c.set_steam_enabled(false), "switch off")
	eq(c.collections().filter(func(x): return x["read_only"]).size(), 0, "Steam's collections gone when off")
	eq(c.dynamic_count(), 1, "dynamic count for the settings note")


# ------------------------------------------------------------ views, shelves, badges

var last_store: RefCounted


func _games() -> Array:
	var c := _store("views")
	last_store = c
	c.set_favourite("epic:2", true)
	c.set_hidden("gog:3", true)
	var id: String = c.create("Party")
	c.add(id, "steam:1")
	var list := [Logic.g("steam", "1", "Alpha", true, 100), Logic.g("epic", "2", "Bravo", true, 300),
		Logic.g("gog", "3", "Charlie", true, 900), Logic.g("emu", "3000000001", "Super Game", true, 0)]
	list[3]["emulated"] = {"system": "snes", "system_name": "Nintendo SNES (Super Nintendo)", "system_short": "SNES", "emulator": "RetroArch", "via": "emudeck"}
	return c.decorate(list)


func test_views_and_shelves() -> void:
	var g := _games()
	var titles := func(l: Array) -> Array: return l.map(func(x): return x["title"])
	eq(titles.call(View.filter_view(g, "")), ["Alpha", "Bravo", "Super Game"], "all: hidden left out")
	eq(titles.call(View.filter_view(g, "favourites")), ["Bravo"], "favourites")
	eq(titles.call(View.filter_view(g, "hidden")), ["Charlie"], "hidden only")
	eq(titles.call(View.filter_view(g, "emulation")), ["Super Game"], "emulation")
	eq(titles.call(View.filter_view(g, "collection:c1")), ["Alpha"], "a collection")
	eq(View.continue_game(g)["title"], "Bravo", "a hidden game never takes the spotlight (Charlie was played last)")
	var shelves := View.shelves(g)
	var ids: Array = shelves.map(func(s): return s["id"])
	ok("favourites" in ids and ids.find("favourites") < ids.find("all"), "Favourites shelf on Home")
	ok("emulation" in ids, "Emulation shelf on Home")
	for s in shelves:
		ok(not s["games"].any(func(x): return x["title"] == "Charlie"), "hidden game on no shelf: " + s["id"])
	var none := View.shelves(_store("noviews").decorate([Logic.g("steam", "1", "Alpha")]))
	ok(not none.any(func(s): return s["id"] == "favourites"), "no Favourites shelf while it's empty")
	var by := {}
	for b in Badges.for_game(g[3]):
		by[b["kind"]] = b
	eq(by["system"]["short"], "SNES", "system badge on emulated games")
	var fav := {}
	for b in Badges.for_game(g[1]):
		fav[b["kind"]] = b
	eq(fav["favourite"]["icon"], "star", "favourite badge")
	eq(Badges.for_tile(g[3])["strip"][0]["kind"], "system", "the focused tile shows the system first")


func test_library_screen_views() -> void:
	var l: Control = LibraryScreen.new()
	l.set_collection_names({"c1": "Party"})
	l.set_games(_games())
	eq(l.tiles().size(), 3, "hidden game not in the grid")
	eq(l.count_label.text, "3 games", "count leaves hidden games out")
	l.set_view("favourites")
	eq(l.tiles().map(func(t): return t.game["title"]), ["Bravo"], "favourites view")
	eq(l.view_label.text, "Favourites  ·", "heading names the view")
	l.set_view("collection:c1")
	eq(l.view_label.text, "Party  ·", "collection name in the heading")
	l.set_view("hidden")
	eq(l.tiles().map(func(t): return t.game["title"]), ["Charlie"], "hidden view")
	l.set_view("collection:nope")
	eq(l.view, "collection:nope", "kept until the names say otherwise")
	l.set_collection_names({})
	eq(l.view, "", "a deleted collection's view falls back to all")
	var fired := [0]
	l.filter_requested.connect(func(): fired[0] += 1)
	l.sort_button.pressed.emit()
	eq(fired[0], 1, "the order chip opens the Filter sheet")
	l.set_games(_store("emptyfav").decorate([Logic.g("steam", "1", "Alpha")]))
	l.set_view("favourites")
	eq(l.find_child("EmptyFilter", true, false).text, TL.EMPTY_FAVOURITES, "empty favourites says how to add one")
	l.free()


# ------------------------------------------------------------ flows on the sheet

class FakeActions extends Node:
	var menus: Array = []
	var keyboard_cb := Callable()
	var toasts: Array = []
	var toast: Callable = func(t, _i = "", tone = "", _d = ""): toasts.append([t, tone])
	func open_menu(title: String, sub: String, rows: Array, cb: Callable) -> void:
		menus.append({"title": title, "sub": sub, "rows": rows, "cb": cb})
	func open_keyboard(_t: String, _d: String, _text: String, done: Callable) -> void:
		keyboard_cb = done
	func pick(id: String) -> void:
		var m: Dictionary = menus[menus.size() - 1]
		m["cb"].call(id)


func test_flows() -> void:
	var c := _store("flows")
	var fa := FakeActions.new()
	var ca: Node = CollectionActions.new()
	ca.setup(c, fa)
	var game := Logic.g("epic", "2", "Bravo")
	ca.options(game)
	eq(fa.menus[0]["rows"].map(func(r): return r["id"]), ["page", "favourite", "collections", "hide"], "Menu on a tile")
	fa.pick("favourite")
	ok(c.is_favourite("epic:2"), "favourited from the sheet")
	eq(fa.toasts[0][0], TL.FAVOURITE_ADDED % "Bravo", "and says so")
	ca.options(game)
	eq(fa.menus[1]["rows"][1]["text"], TL.REMOVE_FAVOURITE, "the row flips")
	fa.pick("collections")
	eq(fa.menus[2]["rows"][0]["id"], "+new", "New collection first")
	fa.pick("+new")
	fa.keyboard_cb.call("Backlog")
	eq(c.collections().map(func(x): return [x["name"], x["games"]]), [["Backlog", ["epic:2"]]], "made and added in one go")
	ca.pick_collection(game)
	eq(fa.menus[3]["rows"][1]["current"], true, "ticked when in it")
	fa.pick("c1")
	eq(c.find("c1")["games"], [], "picking again takes it out")
	ca.options(game)
	fa.pick("hide")
	ok(c.is_hidden("epic:2"), "hidden")
	eq(fa.toasts[fa.toasts.size() - 1][0], TL.HIDDEN_TOAST % "Bravo", "with how to get it back")
	ca.options(game)
	eq(fa.menus[fa.menus.size() - 1]["rows"][3]["id"], "unhide", "Show this game again")
	ca.manage()
	fa.pick("c1")
	fa.pick("rename")
	fa.keyboard_cb.call("Later")
	eq(c.find("c1")["name"], "Later", "renamed")
	ca.manage()
	fa.pick("c1")
	fa.pick("delete")
	eq(fa.menus[fa.menus.size() - 1]["rows"][0]["id"], "no", "deleting asks first, Keep it focused")
	fa.pick("yes")
	eq(c.collections().size(), 0, "deleted")
	ca.manage()
	ok(fa.menus[fa.menus.size() - 1]["rows"][0]["disabled"], "nothing to manage says so")
	ca.free()
	fa.free()


func test_filter_sheet() -> void:
	var games := _games()
	var fa := FakeActions.new()
	var ca: Node = CollectionActions.new()
	ca.setup(last_store, fa)
	var l: Control = LibraryScreen.new()
	l.set_games(games)
	var opened := [0]
	ca.open_emulation.connect(func(): opened[0] += 1)
	ca.filter(l)
	var rows: Array = fa.menus[0]["rows"]
	var ids: Array = rows.map(func(r): return r["id"])
	eq(ids, ["", "favourites", "collection:c1", "emulation", "hidden", "+sort", "+emulation_page", "+manage"], "every view, then order, Emulation page, manage")
	eq(rows[0]["value"], "3", "counts")
	ok(rows[0]["current"], "the current view ticked")
	fa.pick("favourites")
	eq(l.view, "favourites", "picked a view")
	ca.filter(l)
	fa.pick("+sort")
	fa.pick("az")
	eq(l.sort, "az", "order from the sheet")
	ca.filter(l)
	fa.pick("+emulation_page")
	eq(opened[0], 1, "Emulation page from the sheet")
	l.free()
	ca.free()
	fa.free()


func test_manage_menu_lists_collections() -> void:
	var c := _store("manage")
	var fa := FakeActions.new()
	var ca: Node = CollectionActions.new()
	ca.setup(c, fa)
	var rows: Array = ca.game_rows(Logic.g("steam", "1", "Alpha"), false)
	eq(rows.map(func(r): return r["id"]), ["favourite", "collections", "hide"], "the game page's Manage adds these")
	eq(GameActions.manage_rows(Logic.g("emu", "5", "Super Game"), {}, ""), [], "emulated games: no store rows (EmuDeck manages them)")
	ca.free()
	fa.free()
