extends "res://tests/test_case.gd"
## Review High 13: the Library's grid made every tile up to the game it was asked for (the
## remembered game, a letter jump): seconds-long freezes at 20,000 ROMs. The grid is virtual
## now: only the rows around the view are made, spacers stand in for the rest.

const LibraryScreen := preload("res://scripts/ui/library_screen.gd")

## Time budgets on a loaded 2-core box (a shared CI runner; quiet: 0.8 s to open 20,000, 60 ms to jump): the old code needed 40 s and more for the deep ones.
const MAX_OPEN_MS := 6000
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
