extends "res://tests/test_case.gd"
## Review High 13: the Library's grid made every tile up to the game it was asked for (the
## remembered game, a letter jump): seconds-long freezes at 20,000 ROMs. The grid is virtual
## now: only the rows around the view are made, spacers stand in for the rest.

const LibraryScreen := preload("res://scripts/ui/library_screen.gd")
const View := preload("res://scripts/ui/library_view.gd")
const Home := preload("res://scripts/ui/home.gd")
const Collections := preload("res://scripts/library/collections.gd")

## Time budgets on a loaded 2-core box (a shared CI runner; quiet: 0.8 s to open 20,000, 60 ms to jump): the old code needed 40 s and more for the deep ones.
const MAX_OPEN_MS := 6000
## Home's shelves from 20,300 games (review H5: 1.1 s; ~0.1 s on a quiet 4-core box). The screens in the tree, where a
## change is measured as it really comes, are in e2e/suite_perf.gd (this runner has no running tree).
const MAX_SHELVES_MS := 450
const MAX_JUMP_MS := 3000
## Tiles that may exist at once at any size the tests use (window rows x 7 columns).
const MAX_TILES := 24 * 7


func _roms(n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append({"key": "emu:%d" % (3000000000 + i), "store": "emu", "id": str(3000000000 + i), "title": "Rom %05d" % i,
			"installed": true, "shortcut": true, "art": {"cover": "", "hero": "", "logo": "", "icon": ""},
			"info": {"released": null, "time_to_beat": null, "anticheat": null, "protondb": null, "summary": ""},
			"last_played": 0, "playtime_min": 0, "emulated": {"system": "snes", "system_short": "SNES"}})
	return out


func _spacers_height(l: Control, list: Array) -> float:
	var h := 0.0
	for sp in list:
		if sp.visible:
			h = maxf(h, sp.custom_minimum_size.y)
	return h


func test_twenty_thousand_roms_make_a_window_of_tiles() -> void:
	var l: Control = LibraryScreen.new()
	var t0 := Time.get_ticks_msec()
	l.set_games(_roms(20000))
	var opened := Time.get_ticks_msec() - t0
	eq(l.shown.size(), 20000, "every game is shown (listed)")
	ok(l.tiles().size() > 0 and l.tiles().size() <= MAX_TILES, "%d tiles made, not 20000" % l.tiles().size())
	ok(opened <= MAX_OPEN_MS, "opened in %d ms <= %d" % [opened, MAX_OPEN_MS])
	eq(l.tiles()[0].game["title"], "Rom 00000", "the grid starts at the top")
	ok(l.grid.get_child_count() <= MAX_TILES + 2 * LibraryScreen.MAX_COLS, "and the grid holds only those (and the spacers)")
	l.free()


func test_a_game_far_down_is_made_without_making_the_ones_before_it() -> void:
	var l: Control = LibraryScreen.new()
	var list := _roms(20000)
	l.set_games(list)
	var key: String = list[19000]["key"]
	var t0 := Time.get_ticks_msec()
	var tile: Control = l.tile_for(key)
	var took := Time.get_ticks_msec() - t0
	ok(tile != null, "the tile for game 19000 exists")
	if tile != null:
		eq(tile.game["key"], key, "and is that game's")
	ok(l.tiles().size() <= MAX_TILES, "still only %d tiles" % l.tiles().size())
	ok(took <= MAX_JUMP_MS, "made in %d ms <= %d (it took every tile before it)" % [took, MAX_JUMP_MS])
	var cols: int = l.grid.columns
	var pitch: float = l.tile_size.y + l.GAP.y
	# the rows above stand as one spacer row: the whole list keeps its height for the scroll bar
	var above: float = (l._first / cols) * pitch - l.GAP.y
	ok(absf(_spacers_height(l, l._top_sp) - above) < 0.01, "the rows above are a spacer %d px high" % above)
	var below_rows: int = ceili(20000.0 / cols) - (l._first + l.tiles().size() + cols - 1) / cols
	ok(absf(_spacers_height(l, l._bot_sp) - (below_rows * pitch - l.GAP.y)) < 0.01, "and the rows below another")
	eq(l._first % cols, 0, "the window starts on a whole row")
	# a neighbour is linked to the tile the d-pad should reach, in the window
	var k: int = l.tiles().find(tile)
	ok(tile.focus_neighbor_left != NodePath("") and l.tiles().size() > k + cols, "linked inside the window")
	# and back to the top
	var first_key: String = list[0]["key"]
	ok(l.tile_for(first_key) != null and l.tiles().size() <= MAX_TILES, "the first game again")
	l.free()


func test_the_remembered_game_deep_in_the_list_opens_fast() -> void:
	var l: Control = LibraryScreen.new()
	var list := _roms(20000)
	l.set_games(list)
	l._memory_key = list[15000]["key"]
	var t0 := Time.get_ticks_msec()
	l.set_games(list)   # an install changed: the list is rebuilt, the game it had stays in reach
	var took := Time.get_ticks_msec() - t0
	ok(l.default_focus() != null and l.default_focus().get("game") != null and l.default_focus().game["key"] == l._memory_key, "focus returns to the remembered game")
	ok(l.tiles().size() <= MAX_TILES, "%d tiles" % l.tiles().size())
	ok(took <= MAX_OPEN_MS, "rebuilt in %d ms <= %d" % [took, MAX_OPEN_MS])
	l.free()


func test_a_short_list_has_no_spacers_and_every_tile() -> void:
	var l: Control = LibraryScreen.new()
	l.set_games(_roms(30))
	eq(l.tiles().size(), 30, "30 games, 30 tiles")
	ok(_spacers_height(l, l._top_sp) == 0.0 and _spacers_height(l, l._bot_sp) == 0.0, "nothing to stand in for")
	l.free()


## The hint bar over the search keyboard names its buttons: B cancels (it is not "Home"), Menu keeps.
func test_the_hint_bar_over_the_search_keyboard_says_cancel_and_done() -> void:
	var l: Control = LibraryScreen.new()
	eq(l.hints(null), [], "no keyboard: the usual hints")
	l.open_search()
	var h: Array = l.hints(null)
	ok(["B", "Cancel"] in h and ["MENU", "Done"] in h, "keyboard open: B Cancel, Menu Done (%s)" % [h])
	ok(not (["B", "Home"] in h), "and no Home")
	l.keyboard.cancel()
	l.free()


func _store_games(n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append({"key": "steam:%d" % i, "store": "steam" if i % 2 == 0 else "gog", "id": str(i), "title": "Store game %d" % i,
			"installed": i % 3 == 0, "added": 1700000000 + i, "art": {"cover": ""}, "info": {}, "last_played": 1700000000 + i * 1000 if i % 5 == 0 else 0,
			"playtime_min": i % 97})
	return out


func _in_tree(n: Control) -> Control:
	(Engine.get_main_loop() as SceneTree).root.add_child(n)
	return n


func _drop(n: Node) -> void:
	n.get_parent().remove_child(n)
	n.free()


## The orders are what the Callable sorts gave: title, recent, most played, shortest, top rated.
func test_home_shelves_from_20000_roms_are_quick_and_complete() -> void:
	var list := _roms(20000) + _store_games(300)
	var t0 := Time.get_ticks_msec()
	var shelves := View.shelves(list)
	var took := Time.get_ticks_msec() - t0
	ok(took <= MAX_SHELVES_MS, "Home's shelves from 20,300 games: %d ms <= %d (was 1.1 s)" % [took, MAX_SHELVES_MS])
	var ids: Array = shelves.map(func(s): return s["id"])
	ok("installed" in ids and "emulation" in ids and "all" in ids and "store_steam" in ids, "the shelves are all there (%s)" % [ids])


func test_the_fast_orders_equal_the_comparator_orders() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var list: Array = []
	for i in 600:
		list.append({"key": "k%d" % i, "title": "Game %d%s" % [rng.randi() % 50, ["", " b", " A", " é"][rng.randi() % 4]],
			"last_played": [0, 0, 1700000000 + rng.randi() % 5][rng.randi() % 3], "playtime_min": rng.randi() % 4,
			"info": {"time_to_beat": {"main_h": float(rng.randi() % 4) - 1.0}}})
	var by_title := list.duplicate()
	by_title.sort_custom(View.title_order)
	for mode in View.SORTS:
		var got: Array = View.sort_games(list, mode)
		eq(got.size(), 600, "%s: every game" % mode)
		for i in range(1, got.size()):
			var a: Dictionary = got[i - 1]
			var b: Dictionary = got[i]
			var fine := true
			match mode:
				"recent": fine = int(a["last_played"]) > int(b["last_played"]) or (int(a["last_played"]) == int(b["last_played"]) and a["title"].naturalnocasecmp_to(b["title"]) <= 0)
				"playtime": fine = int(a["playtime_min"]) > int(b["playtime_min"]) or (int(a["playtime_min"]) == int(b["playtime_min"]) and a["title"].naturalnocasecmp_to(b["title"]) <= 0)
				"az": fine = a["title"].naturalnocasecmp_to(b["title"]) <= 0
				"ttb":
					var ha := View.main_hours(a)
					var hb := View.main_hours(b)
					fine = (ha > 0.0 and hb <= 0.0) or ((ha > 0.0) == (hb > 0.0) and (ha < hb or (ha == hb and a["title"].naturalnocasecmp_to(b["title"]) <= 0)))
			if not fine:
				ok(false, "%s: %s (%s) then %s (%s)" % [mode, a["title"], a, b["title"], b])
				break
	ok(View.title_sorted(by_title) and not View.title_sorted(list), "title_sorted tells")


## Typing more of the query narrows the last result and finds what a fresh search of the whole list finds.
func test_a_longer_query_finds_what_a_fresh_search_finds() -> void:
	var list := _roms(3000) + _store_games(300)
	var l: Control = LibraryScreen.new()
	l.set_games(list)
	for q in ["r", "ro", "rom", "rom ", "rom 1", "rom 12", "rom 123", "rom 1234", "store", "store g", "sto 1", "st", "s"]:
		l.set_query(q)
		var fresh: Array = View.sort_games(View.search(View.not_hidden(list), q), "recent")
		eq(l.shown.map(func(g): return g["key"]), fresh.map(func(g): return g["key"]), "query '%s' shows what a fresh search shows" % q)
	# a changed filter or list starts over: no old result is reused
	l.set_query("rom 1")
	l.set_store("steam")
	eq(l.shown.size(), 0, "another store: the ROMs are gone")
	l.set_store("")
	l.set_query("rom 0000")
	var other := _roms(10)
	for g in other:
		g["key"] = "emu:other" + g["id"]
	l.set_games(other)
	eq(l.shown.map(func(g): return g["key"]), other.map(func(g): return g["key"]), "a new list is searched afresh, not narrowed from the old result")
	l.free()


func test_decorate_copies_only_games_that_are_marked() -> void:
	var c := Collections.new("user://test_decorate_pass.json")
	var plain := {"key": "emu:1", "title": "A"}
	var marked := {"key": "emu:2", "title": "B"}
	c.set_favourite("emu:2", true)
	var out: Array = c.decorate([plain, marked])
	ok(is_same(out[0], plain) or out[0] == plain, "a game in nothing is passed through")
	ok(not out[0].has("favourite"), "without copying it")
	eq(out[1].get("favourite"), true, "a favourite is a decorated copy")
	ok(not marked.has("favourite"), "and the original stays as it was")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_decorate_pass.json"))
