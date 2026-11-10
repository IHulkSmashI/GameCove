extends "res://tests/test_case.gd"
## What the user sees of cloud saves and battery drain: the game page's Cloud saves card
## (status, switch, conflict choice with the newest side first, backups), the drain line
## under About, and Settings > Saves. The service is a fake with saves_service.gd's API.

const SavesCard := preload("res://scripts/ui/games/saves_card.gd")
const GamePage := preload("res://scripts/ui/game_page.gd")
const SavesPage := preload("res://scripts/ui/settings/saves_page.gd")
const TS := preload("res://scripts/ui/texts_saves.gd")
const Screens := preload("res://tests/test_ui_screens.gd")


class FakeSaves:
	extends Node
	signal status_changed(key: String)
	var st := {"state": "synced", "at": 1000, "detail": "", "local": 0, "remote": 0, "last_sync": 1000, "enabled": true, "busy": "", "store": "epic"}
	var on := true
	var all := true
	var backups: Array = []
	var calls: Array = []

	func applies(g: Dictionary) -> bool:
		return str(g.get("store", "")) in ["epic", "gog"] and bool(g.get("installed", false))

	func allowed() -> bool:
		return all

	func set_allowed(v: bool) -> bool:
		all = v
		return true

	func enabled(_k: String) -> bool:
		return on

	func set_enabled(k: String, v: bool) -> bool:
		on = v
		st["enabled"] = v
		calls.append("enabled %s" % v)
		status_changed.emit(k)
		return true

	func status(_g: Dictionary) -> Dictionary:
		var out := st.duplicate()
		if not on:
			out["state"] = "off"
		elif not all:
			out["state"] = "disabled"
		return out

	func backup_list(_k: String) -> Array:
		return backups

	func sync_now(_g: Dictionary, _d := Callable()) -> void:
		calls.append("sync")

	func resolve(_g: Dictionary, c: String, _d := Callable()) -> void:
		calls.append("resolve " + c)

	func restore(_g: Dictionary, id: String, _d := Callable()) -> void:
		calls.append("restore " + id)

	func overview(games: Array) -> Array:
		return games.filter(func(g): return applies(g)).map(func(g): return {"game": g, "status": status(g)})


class FakeActions:
	extends Node
	var opened: Array = []
	var cb := Callable()
	var toast: Callable = func(_t, _i = "info", _tone = "", _d = ""): pass

	func open_menu(title: String, sub: String, rows: Array, c: Callable) -> void:
		opened.append({"title": title, "sub": sub, "rows": rows})
		cb = c


class FakeBattery:
	extends Node
	func drain_for(k: String) -> Dictionary:
		return {"watts": 8.4, "hours": 6.2, "seconds": 3600} if k == "epic:Min" else {}


const EPIC := {"key": "epic:Min", "store": "epic", "id": "Min", "title": "Minecraft Dungeons", "installed": true,
	"art": {"cover": "", "hero": "", "logo": "", "icon": ""}, "info": {}}
const STEAM := {"key": "steam:1", "store": "steam", "id": "1", "title": "Alpha", "installed": true,
	"art": {"cover": "", "hero": "", "logo": "", "icon": ""}, "info": {}}


func test_card_shows_status_switch_and_backups() -> void:
	var s := FakeSaves.new()
	var a := FakeActions.new()
	var c: VBoxContainer = SavesCard.new()
	c.clock = func() -> int: return 1000 + 120
	c.setup(EPIC, s, a)
	eq(c.status_label.text, "Saves synced 2 min ago", "how the saves stand")
	ok(not c.choose_button.visible, "no conflict: no choice row")
	eq(c.focusables(), [c.toggle_button, c.sync_button, c.backups_button], "switch, Sync now, backups")
	ok(c.backups_button.disabled, "no backups yet")
	c.toggle_button.pressed.emit()
	eq(s.calls, ["enabled false"], "the switch turns this game off")
	ok(not c.sync_button.visible, "off: no Sync now")
	eq(c.status_label.text, TS.STATE["off"], "and says so")
	s.set_enabled("epic:Min", true)
	s.st["state"] = "conflict"
	s.st["local"] = 500
	s.st["remote"] = 900
	s.backups = [{"id": "20261110-1200", "time": 1000, "reason": "before_download", "bytes": 2048, "parts": []}]
	c.refresh()
	ok(c.choose_button.visible and c.focusables()[0] == c.choose_button, "a conflict puts the choice first")
	c.choose_button.pressed.emit()
	var rows: Array = a.opened[-1]["rows"]
	eq(rows.map(func(r): return r["id"]), ["cloud", "local"], "the newest side first")
	eq([rows[0].get("tone", ""), rows[0].get("value", "")], ["good", TS.NEWER], "and highlighted")
	a.cb.call("local")
	eq(s.calls[-1], "resolve local", "A keeps it")
	ok(not c.backups_button.disabled, "backups listed")
	c.backups_button.pressed.emit()
	eq(a.opened[-1]["rows"][0]["text"], TS.REASONS["before_download"], "why the backup was made")
	a.cb.call("20261110-1200")
	eq(s.calls[-1], "restore 20261110-1200", "A restores it")
	s.st["busy"] = "now"
	c.refresh()
	eq(c.status_label.text, TS.SYNCING, "busy: syncing")
	ok(c.sync_button.disabled, "Sync now waits")
	c.free()
	s.free()
	a.free()


func test_conflict_rows_with_decide_later_and_unknown_times() -> void:
	var rows := SavesCard.conflict_rows({"local": 2000, "remote": 1000}, 2030, true)
	eq(rows.map(func(r): return r["id"]), ["local", "cloud", "later"], "local newer first; later last")
	eq(rows[0]["detail"], "Saved just now", "when")
	var same := SavesCard.conflict_rows({"local": 0, "remote": 0}, 10)
	ok(not same[0].has("value"), "no times: nothing marked newer")
	eq(same[0]["detail"], TS.UNKNOWN_TIME, "time unknown")


func test_status_lines_cover_every_state() -> void:
	for state in TS.STATE:
		var line := TS.status_line({"state": state, "at": 100}, 220)
		ok(line != "" and not line.contains("%s"), "%s has a line" % state)
		ok(not line.contains("  "), "%s: no double spaces" % state)
	eq(TS.status_line({"state": "offline", "at": 100}, 220), "Couldn't reach the store 2 min ago, so saves weren't synced. We'll try again next time.", "offline line")
	eq(TS.drain_line({"watts": 12.4, "hours": 3.9}), "Drains about 12 W, ~3.9 h on a full charge", "drain line")
	eq(TS.drain_line({"watts": 6.25, "hours": -1.0}), "Drains about 6.2 W on battery", "no full-charge figure")


func test_game_page_has_the_card_for_epic_only_and_the_drain_line() -> void:
	var s := FakeSaves.new()
	var bat := FakeBattery.new()
	var p: Control = GamePage.new()
	p.setup(EPIC, Screens.FakeLauncher.new(), {"saves": s, "battery": bat})
	ok(p.saves_card != null, "Epic game: Cloud saves card")
	ok(p.drain_label != null and p.drain_label.text == "Drains about 8.4 W, ~6.2 h on a full charge", "drain under About")
	for f in p.saves_card.focusables():
		ok(f in p.focusables, "card rows are in the page's focus chain")
	eq(p.hints_for_focus(p.saves_card.toggle_button), [["A", TS.HINT_OFF], ["B", "Back"]], "A turns it off")
	eq(p.hints_for_focus(p.saves_card.sync_button)[0], ["A", TS.SYNC_NOW], "A syncs")
	p.free()
	var q: Control = GamePage.new()
	q.setup(STEAM, Screens.FakeLauncher.new(), {"saves": s, "battery": bat})
	ok(q.saves_card == null, "Steam game: Steam Cloud, no card")
	ok(q.drain_label == null, "no drain data: no line")
	q.free()
	s.free()
	bat.free()


class FakeLib:
	extends Node
	signal changed
	var games: Array = []


func test_settings_page_lists_games_and_the_switch() -> void:
	var s := FakeSaves.new()
	var lib := FakeLib.new()
	lib.games = [EPIC, STEAM, {"key": "gog:1", "store": "gog", "id": "1", "title": "Witcher", "installed": true}]
	var page: VBoxContainer = SavesPage.new()
	page.setup("saves", {"saves": s, "library": lib}, null)
	ok(page.rows.has("cloud_saves"), "the switch")
	ok(page.rows.has("game_epic_Min") and page.rows.has("game_gog_1"), "Epic and GOG games listed")
	ok(not page.rows.has("game_steam_1"), "Steam games aren't")
	ok(page.find_child("AmazonNote", true, false) != null, "says why Amazon isn't covered")
	eq(page.rows["game_epic_Min"].value_label.text, "Synced", "short state per game")
	page.rows["cloud_saves"].changed.emit(false)
	ok(not s.all, "the switch turns cloud saves off")
	page.open_game(EPIC)
	var ids: Array = page.sheet.items.map(func(r): return r["id"])
	eq(ids, ["toggle", "backups"], "off for all: only the switch and backups")
	page.sheet.free()
	page.free()
	lib.free()
	s.free()
