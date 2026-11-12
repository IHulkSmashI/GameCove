extends "res://tests/test_case.gd"
## What the user sees of cloud saves and battery drain: the game page's Cloud saves card
## (status, switch, conflict choice with the newest side first, backups), the drain line
## under About, and Settings > Saves. The service is a fake with saves_service.gd's API.

const SavesCard := preload("res://scripts/ui/games/saves_card.gd")
const GamePage := preload("res://scripts/ui/game_page.gd")
const SavesPage := preload("res://scripts/ui/settings/saves_page.gd")
const TS := preload("res://scripts/ui/texts_saves.gd")
const TG := preload("res://scripts/ui/texts_games.gd")
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

	## A game runs: resolve refuses, as saves_service.gd does.
	var running := false

	func resolve(_g: Dictionary, c: String, _d := Callable()) -> bool:
		if running:
			return false
		calls.append("resolve " + c)
		return true

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
	eq(c.focusables(), [c.toggle_button, c.sync_button], "switch and Sync now: \"No backups\" is a line, not a control (CUX-7)")
	ok(c.backups_button.disabled and c.backups_button.focus_mode == Control.FOCUS_NONE, "no backups yet: nothing to focus there")
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
	ok(c.backups_button.focus_mode == Control.FOCUS_ALL and c.backups_button in c.focusables(), "and the row takes focus again")
	s.backups.append({"id": "20261109-0900", "time": 900, "reason": "before_download", "bytes": 1024, "parts": []})
	c.refresh()
	eq((c.backups_button.find_child("Detail", true, false) as Label).text, "2 backups", "the count in plain words (not \"2 Backups\")")
	s.backups.pop_back()
	c.refresh()
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


## Every state the service can leave a game in has a status line and a short label on Settings >
## Saves (they were blank for "upload cut off", "upload finished" and "couldn't save state").
## The states are read from the service's own source, so a new one fails here until it has both.
func test_every_state_the_service_emits_has_a_line_and_a_short_label() -> void:
	var emitted := {"never": true, "pending_down": true, "synced": true, "uploaded": true, "downloaded": true}
	var src := FileAccess.get_file_as_string("res://scripts/system/saves_service.gd")
	for pat in ["_set_status\\(key, \"([a-z_]+)\"", "st\\[\"state\"\\] = \"([a-z_]+)\"", "\"state\": \"([a-z_]+)\"",
			"return \"(offline|failed|upload_cut)\""]:
		for m in RegEx.create_from_string(pat).search_all(src):
			emitted[m.get_string(1)] = true
	# a plan's "why" becomes the state (signed_out, no_tool, ...); "ask" is handled inside the service
	for m in RegEx.create_from_string("\"why\": \"([a-z_]+)\"").search_all(FileAccess.get_file_as_string("res://scripts/system/cloud_saves.gd")):
		if m.get_string(1) != "ask":
			emitted[m.get_string(1)] = true
	ok(emitted.size() > 20, "the states were found (%d)" % emitted.size())
	for state in emitted:
		ok(TS.STATE.has(state), "%s has a status line" % state)
		ok(str(SavesPage.SHORT.get(state, "")) != "", "%s has a short label on Settings > Saves" % state)
	for state in TS.STATE:
		ok(str(SavesPage.SHORT.get(state, "")) != "", "%s (a known state) has a short label" % state)


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


## High 5: the conflict choice from the game page while a game runs is refused, and the
## card says why instead of looking as if it worked.
func test_conflict_choice_while_a_game_runs_says_close_the_game() -> void:
	var s := FakeSaves.new()
	var a := FakeActions.new()
	var toasts := []
	a.toast = func(t, _i = "info", tone = "", _d = ""): toasts.append([t, tone])
	var c: VBoxContainer = SavesCard.new()
	s.st["state"] = "conflict"
	c.setup(EPIC, s, a)
	s.running = true
	c.choose_button.pressed.emit()
	a.cb.call("cloud")
	eq(s.calls, [], "nothing was started")
	eq(toasts, [[TS.RESOLVE_RUNNING, "warn"]], "the card says to close the game first")
	s.running = false
	a.cb.call("cloud")
	eq(s.calls, ["resolve cloud"], "after the game it goes through")
	eq(toasts.size(), 1, "with no warning")
	c.free()
	s.free()
	a.free()


## High 6: after a restore the conflict sheet offers the restored save first, even though
## the cloud's is newer by the clock.
func test_conflict_rows_after_a_restore_offer_the_restored_side_first() -> void:
	var rows := SavesCard.conflict_rows({"local": 1000, "remote": 2000, "prefer": "local", "store": "epic"}, 2030, true)
	eq(rows.map(func(r): return r["id"]), ["local", "cloud", "later"], "the restored save first")
	eq([rows[0].get("tone", ""), rows[0].get("value", "")], ["good", TS.RESTORED_BADGE], "marked as the restored one")
	eq(rows[0]["detail"], TS.RESTORED_DETAIL, "and said so")
	ok(not rows[1].has("value"), "the cloud's isn't called newer next to it")
	var plain := SavesCard.conflict_rows({"local": 1000, "remote": 2000, "prefer": "", "store": "epic"}, 2030)
	eq(plain.map(func(r): return r["id"]), ["cloud", "local"], "without a restore: newest first, as before")


## GOG's time for the cloud side is when the files were uploaded, not when they were played,
## so it can't be compared with the local save's time: no side is called "Newer".
func test_gog_conflict_rows_dont_claim_a_newer_side() -> void:
	var rows := SavesCard.conflict_rows({"local": 1000, "remote": 2000, "store": "gog"}, 2030, true)
	eq(rows.map(func(r): return r["id"]), ["local", "cloud", "later"], "a fixed order: this handheld, the cloud")
	ok(not rows[0].has("value") and not rows[1].has("value"), "no Newer badge on either")
	ok(not rows[0].has("tone") and not rows[1].has("tone"), "and no highlight")
	eq(rows[1]["detail"], TS.UPLOADED_AT % TG.ago(2000, 2030), "the cloud side says when it was uploaded")
	eq(rows[0]["detail"], TS.saved_at(1000, 2030), "the local side when it was saved")
	eq(SavesCard.conflict_rows({"local": 1000, "remote": 0, "store": "gog"}, 2030)[1]["detail"], TS.UNKNOWN_TIME, "no time: unknown")
	var epic := SavesCard.conflict_rows({"local": 1000, "remote": 2000, "store": "epic"}, 2030)
	eq(epic[0].get("value", ""), TS.NEWER, "Epic's times are both save times: Newer stays")


## Review at ff76ca4: a blank save a game just made has the newest file time, and the sheet
## badged it "Newer". A side that may be blank is never called newer: the cloud's comes first.
func test_a_blank_local_save_is_never_called_newer() -> void:
	var fresh := SavesCard.conflict_rows({"local": 2000, "remote": 1000, "store": "epic", "fresh": true,
		"local_files": 1, "local_bytes": 900, "cloud_files": 3, "cloud_bytes": 2000}, 2030, true)
	eq(fresh.map(func(r): return r["id"]), ["cloud", "local", "later"], "a fresh folder: the cloud's save first")
	ok(fresh[0].get("value", "") != TS.NEWER and fresh[1].get("value", "") != TS.NEWER, "nobody called newer (the cloud is older by the clock)")
	eq([fresh[1].get("tone", ""), fresh[1].get("value", "")], ["warn", TS.FRESH_BADGE], "this handheld's says it might be new")
	ok(str(fresh[1]["detail"]).begins_with(TS.FRESH_DETAIL), "and why")
	ok(str(fresh[1]["detail"]).ends_with("1 file, 900 B"), "with what it holds (%s)" % fresh[1]["detail"])
	ok(str(fresh[0]["detail"]).ends_with("3 files, 2.0 KB") or str(fresh[0]["detail"]).ends_with("3 files, 1.95 KB"), "and what the cloud's holds (%s)" % fresh[0]["detail"])
	# not fresh, but far smaller than the cloud's: the same caution
	var small := SavesCard.conflict_rows({"local": 2000, "remote": 1000, "store": "epic", "local_files": 1,
		"local_bytes": 100, "cloud_files": 2, "cloud_bytes": 4000}, 2030)
	eq(small.map(func(r): return r["id"]), ["cloud", "local"], "much smaller: the cloud's first")
	eq(small[1].get("value", ""), TS.SMALL_BADGE, "and said so")
	var empty := SavesCard.conflict_rows({"local": 2000, "remote": 1000, "store": "gog", "local_files": 0, "local_bytes": 0}, 2030)
	eq(empty[1].get("value", ""), TS.SMALL_BADGE, "GOG, no files here: the same")
	# both real (synced before, similar sizes): newest first and Newer, as before
	var real := SavesCard.conflict_rows({"local": 2000, "remote": 1000, "store": "epic", "local_files": 2,
		"local_bytes": 3000, "cloud_files": 2, "cloud_bytes": 3100}, 2030)
	eq([real[0]["id"], real[0].get("value", "")], ["local", TS.NEWER], "a real newer save here is still Newer")
	# the cloud newer and this side in doubt: the cloud's keeps its Newer
	var both := SavesCard.conflict_rows({"local": 1000, "remote": 2000, "store": "epic", "fresh": true}, 2030)
	eq([both[0]["id"], both[0].get("value", "")], ["cloud", TS.NEWER], "the cloud's newer save is still called newer")
	eq(TS.size_text(-1, 0), "", "unknown size: nothing")
	eq(TS.size_text(0, 0), TS.NO_FILES, "no files")
