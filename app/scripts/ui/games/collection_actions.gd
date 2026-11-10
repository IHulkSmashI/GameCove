extends Node
## Favourites, hidden games and collections as controller flows, on the same
## sheet and on-screen keyboard as GameActions:
##   options(game)            Menu on a tile: favourite, collections, hide, page
##   pick_collection(game)    add to / remove from collections, or make one
##   manage()                 rename or delete the collections you made
##   filter(screen)           the Library's view and order (the toolbar is full)
## Writes go through Collections (settings_file.gd). Steam's collections are
## shown read-only.

const TL := preload("res://scripts/ui/texts_library.gd")
const View := preload("res://scripts/ui/library_view.gd")

## The game page should open for this game.
signal open_game(game: Dictionary)
## The Emulation page should open.
signal open_emulation

var collections: RefCounted
var actions: Node   # GameActions: open_menu, open_keyboard, toast


func setup(store: RefCounted, game_actions: Node) -> void:
	name = "CollectionActions"
	collections = store
	actions = game_actions


func _toast(text: String, icon := "check", tone := "", detail := "") -> void:
	if actions != null:
		actions.toast.call(text, icon, tone, detail)


func _saved(ok: bool, text: String, icon := "check") -> void:
	if ok:
		_toast(text, icon, "good")
	else:
		_toast(TL.COULDNT_SAVE, "alert", "bad", TL.COULDNT_SAVE_LINE)


static func _key(game: Dictionary) -> String:
	return str(game.get("key", ""))


# ------------------------------------------------------------ one game

func toggle_favourite(game: Dictionary) -> bool:
	var on: bool = not collections.is_favourite(_key(game))
	_saved(collections.set_favourite(_key(game), on), (TL.FAVOURITE_ADDED if on else TL.FAVOURITE_REMOVED) % game.get("title", ""), "star")
	return on


func set_hidden(game: Dictionary, on: bool) -> void:
	var ok: bool = collections.set_hidden(_key(game), on)
	if not ok:
		_saved(false, "")
	elif on:
		_toast(TL.HIDDEN_TOAST % game.get("title", ""), "check", "", TL.HIDDEN_TOAST_LINE)
	else:
		_toast(TL.UNHIDDEN_TOAST % game.get("title", ""), "check", "good")


## The rows of a game's options sheet (also part of its page's Manage menu).
func game_rows(game: Dictionary, with_page := true) -> Array:
	var k := _key(game)
	var fav: bool = collections.is_favourite(k)
	var hid: bool = collections.is_hidden(k)
	var n: int = collections.collections_of(k).size()
	var rows: Array = []
	if with_page:
		rows.append({"id": "page", "text": TL.OPEN_PAGE, "icon": "info"})
	rows.append({"id": "favourite", "text": TL.REMOVE_FAVOURITE if fav else TL.ADD_FAVOURITE, "detail": TL.FAVOURITE_DETAIL, "icon": "star"})
	rows.append({"id": "collections", "text": TL.ADD_TO_COLLECTION,
		"detail": (TL.COLLECTIONS_OF % [n, TL.plural(n)]) if n > 0 else TL.ADD_TO_COLLECTION_DETAIL, "icon": "layers"})
	rows.append({"id": "unhide", "text": TL.UNHIDE, "detail": TL.UNHIDE_DETAIL, "icon": "eye"} if hid
		else {"id": "hide", "text": TL.HIDE, "detail": TL.HIDE_DETAIL, "icon": "eye_off"})
	return rows


## Runs one of game_rows' ids. True when it was one of ours.
func run(id: String, game: Dictionary) -> bool:
	match id:
		"page": open_game.emit(game)
		"favourite": toggle_favourite(game)
		"collections": pick_collection(game)
		"hide": set_hidden(game, true)
		"unhide": set_hidden(game, false)
		_: return false
	return true


func options(game: Dictionary) -> void:
	actions.open_menu(TL.GAME_OPTIONS, str(game.get("title", "")), game_rows(game), func(id: String): run(id, game))


func pick_collection(game: Dictionary) -> void:
	var k := _key(game)
	var rows: Array = [{"id": "+new", "text": TL.NEW_COLLECTION, "detail": TL.NEW_COLLECTION_DETAIL, "icon": "plus"}]
	for c in collections.collections():
		var inside: bool = k in c["games"]
		if c["read_only"]:
			rows.append({"id": c["id"], "text": c["name"], "detail": TL.STEAM_READ_ONLY, "icon": "layers", "current": inside, "disabled": true})
		else:
			rows.append({"id": c["id"], "text": c["name"], "detail": TL.IN_IT if inside else TL.NOT_IN_IT, "icon": "layers",
				"value": str(c["games"].size()), "current": inside})
	actions.open_menu(TL.PICK_COLLECTION, TL.PICK_COLLECTION_SUB, rows, func(id: String):
		if id == "+new":
			actions.open_keyboard(TL.NEW_COLLECTION_TITLE, TL.NEW_COLLECTION_HELP, "", func(text: String):
				var name := text.strip_edges()
				if name == "":
					return
				var cid: String = collections.create(name)
				_saved(cid != "" and collections.add(cid, k), TL.CREATED % name, "layers"))
			return
		var c: Dictionary = collections.find(id)
		if c.is_empty() or c["read_only"]:
			return
		if k in c["games"]:
			_saved(collections.remove(id, k), TL.REMOVED_FROM % c["name"], "layers")
		else:
			_saved(collections.add(id, k), TL.ADDED_TO % c["name"], "layers"))


# ------------------------------------------------------------ collections

func manage() -> void:
	var rows: Array = []
	for c in collections.collections():
		if not c["read_only"]:
			rows.append({"id": c["id"], "text": c["name"], "detail": TL.games_n(c["games"].size()), "icon": "layers", "value": "", "current": false})
	if rows.is_empty():
		actions.open_menu(TL.MANAGE_COLLECTIONS, TL.NO_COLLECTIONS_LINE, [{"id": "", "text": TL.NO_COLLECTIONS, "icon": "layers", "disabled": true}], Callable())
		return
	actions.open_menu(TL.MANAGE_COLLECTIONS, TL.MANAGE_COLLECTIONS_DETAIL, rows, func(id: String): _manage_one(id))


func _manage_one(id: String) -> void:
	var c: Dictionary = collections.find(id)
	if c.is_empty():
		return
	actions.open_menu(TL.COLLECTIONS, c["name"], [
		{"id": "rename", "text": TL.MANAGE_ONE_RENAME, "icon": "pencil"},
		{"id": "delete", "text": TL.MANAGE_ONE_DELETE, "detail": TL.DELETE_LINE, "icon": "trash", "tone": "bad"},
	], func(what: String):
		if what == "rename":
			actions.open_keyboard(TL.RENAME_TITLE, TL.RENAME_HELP, c["name"], func(text: String):
				var n := text.strip_edges()
				if n != "" and n != c["name"]:
					_saved(collections.rename(id, n), TL.RENAMED % n, "pencil"))
		elif what == "delete":
			actions.open_menu(TL.CONFIRM_DELETE % c["name"], TL.DELETE_LINE, [
				{"id": "no", "text": TL.CONFIRM_DELETE_NO, "icon": "chevron_left", "current": true},
				{"id": "yes", "text": TL.CONFIRM_DELETE_YES, "icon": "trash", "tone": "bad"},
			], func(yes: String):
				if yes == "yes":
					_saved(collections.delete(id), TL.DELETED % c["name"], "trash")))


# ------------------------------------------------------------ the Library's filter sheet

## Rows of the filter sheet for these (decorated) games and the current view.
func filter_rows(games: Array, view: String, sort: String) -> Array:
	var count := func(v: String) -> String: return str(View.filter_view(games, v).size())
	var rows: Array = [
		{"id": "", "text": TL.VIEW_ALL, "detail": TL.VIEW_ALL_DETAIL, "icon": "library", "value": count.call(""), "current": view == ""},
		{"id": "favourites", "text": TL.VIEW_FAVOURITES, "detail": TL.FAVOURITE_DETAIL, "icon": "star", "value": count.call("favourites"), "current": view == "favourites"},
	]
	for c in collections.collections():
		var v := "collection:" + str(c["id"])
		rows.append({"id": v, "text": c["name"], "detail": TL.FROM_STEAM if c["read_only"] else TL.YOUR_COLLECTION,
			"icon": "layers", "value": count.call(v), "current": view == v})
	if games.any(func(g): return g.get("store", "") == "emu"):
		rows.append({"id": "emulation", "text": TL.VIEW_EMULATION, "detail": TL.VIEW_EMULATION_DETAIL, "icon": "emulation", "value": count.call("emulation"), "current": view == "emulation"})
	rows.append({"id": "hidden", "text": TL.VIEW_HIDDEN, "detail": TL.VIEW_HIDDEN_DETAIL, "icon": "eye_off", "value": count.call("hidden"), "current": view == "hidden"})
	rows.append({"id": "+sort", "text": TL.SORT_ROW, "detail": View.SORT_NAMES.get(sort, ""), "icon": "sort"})
	rows.append({"id": "+emulation_page", "text": TL.VIEW_EMULATION_PAGE, "detail": TL.VIEW_EMULATION_PAGE_DETAIL, "icon": "emulation"})
	rows.append({"id": "+manage", "text": TL.MANAGE_COLLECTIONS, "detail": TL.MANAGE_COLLECTIONS_DETAIL, "icon": "pencil"})
	return rows


## Opens the filter sheet for `screen` (library_screen.gd: games, view, sort, set_view, set_sort).
func filter(screen: Object) -> void:
	actions.open_menu(TL.FILTER_TITLE, TL.FILTER_SUB, filter_rows(screen.games, screen.view, screen.sort), _on_filter.bind(screen))


func _on_filter(id: String, screen: Object) -> void:
	match id:
		"+sort":
			var rows: Array = []
			for s in View.SORTS:
				rows.append({"id": s, "text": View.SORT_NAMES[s], "icon": "sort", "current": s == screen.sort})
			actions.open_menu(TL.SORT_TITLE, TL.SORT_SUB, rows, func(s: String): screen.set_sort(s))
		"+emulation_page":
			open_emulation.emit()
		"+manage":
			manage()
		_:
			screen.set_view(id)
