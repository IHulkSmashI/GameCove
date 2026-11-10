extends "res://tests/test_case.gd"
## Game page v2, downloads, game actions, install badges and the game-session
## wiring, with fakes for Library (store API), Achievements and the services
## main.gd calls around a running game. Synchronous; nothing real is touched.

const TG := preload("res://scripts/ui/texts_games.gd")
const InstallState := preload("res://scripts/ui/games/install_state.gd")
const GameActions := preload("res://scripts/ui/games/game_actions.gd")
const DownloadsView := preload("res://scripts/ui/games/downloads_view.gd")
const DownloadsButton := preload("res://scripts/ui/games/downloads_button.gd")
const SteamOverlay := preload("res://scripts/ui/games/steam_overlay.gd")
const TileProgress := preload("res://scripts/ui/games/tile_progress.gd")
const SessionWiring := preload("res://scripts/ui/games/session_wiring.gd")
const AchievementsCard := preload("res://scripts/ui/games/achievements_card.gd")
const TextKeyboard := preload("res://scripts/ui/games/text_keyboard.gd")
const GamePage := preload("res://scripts/ui/game_page.gd")
const Home := preload("res://scripts/ui/home.gd")
const LibraryScreen := preload("res://scripts/ui/library_screen.gd")
const Tile := preload("res://scripts/ui/game_tile.gd")
const Screens := preload("res://tests/test_ui_screens.gd")


## Library's store API with the same signals; records every call.
class FakeLibrary extends Node:
	signal download_progress(key: String, bytes_done: int, bytes_total: int, rate: float, eta: int)
	signal install_state_changed(key: String, state: String)
	signal queue_changed
	signal action_failed(key: String, action: String, message: String)
	signal external_window_needed(key: String, app: String, reason: String)
	signal store_settings_changed
	var calls: Array = []
	var caps := {"install": true, "uninstall": true, "update": true, "verify": true, "move": true,
		"launch_options": true, "compat_tool": true, "progress": true, "pause": true, "resume": true, "cancel": true,
		"how": {}, "why": {}, "needs_window": []}
	var queue: Array[Dictionary] = []
	var locations: Array[Dictionary] = [{"path": "/home/deck/Games", "label": "Internal", "free": 214748364800, "removable": false}]
	var opts := ""
	var tool := ""
	var pending := 0
	var result := {"ok": true, "via": "queue", "why": ""}
	func _rec(name: String, args: Array) -> Dictionary:
		calls.append([name] + args)
		return result
	func capabilities(_g: Dictionary) -> Dictionary: return caps
	func install(g: Dictionary, o := {}) -> Dictionary: return _rec("install", [g["key"], o])
	func uninstall(g: Dictionary) -> Dictionary: return _rec("uninstall", [g["key"]])
	func update(g: Dictionary) -> Dictionary: return _rec("update", [g["key"]])
	func verify(g: Dictionary) -> Dictionary: return _rec("verify", [g["key"]])
	func move(g: Dictionary, p: String) -> Dictionary: return _rec("move", [g["key"], p])
	func pause(g: Dictionary) -> Dictionary: return _rec("pause", [g["key"]])
	func resume(g: Dictionary) -> Dictionary: return _rec("resume", [g["key"]])
	func cancel(g: Dictionary) -> Dictionary: return _rec("cancel", [g["key"]])
	func reorder_download(g: Dictionary, d: int) -> bool:
		_rec("reorder", [g["key"], d])
		return true
	func downloads() -> Array[Dictionary]: return queue
	func launch_options(_g: Dictionary) -> String: return opts
	func set_launch_options(g: Dictionary, s: String) -> Dictionary:
		opts = s
		pending += 1
		calls.append(["set_launch_options", g["key"], s])
		return {"ok": true, "via": "steam-files-after-restart", "why": "", "pending": true}
	func compat_tool(_g: Dictionary) -> String: return tool
	func set_compat_tool(g: Dictionary, t: String) -> Dictionary:
		tool = t
		return _rec("set_compat_tool", [g["key"], t])
	func compat_tools(_g: Dictionary = {}) -> Array[Dictionary]:
		return [{"id": "", "name": "Default", "path": ""}, {"id": "proton_9", "name": "Proton 9.0", "path": ""}, {"id": "GE-Proton10", "name": "GE-Proton10-4", "path": ""}] as Array[Dictionary]
	func install_locations() -> Array[Dictionary]: return locations
	func store_settings() -> Dictionary: return {"steam_pending_count": pending}
	func apply_pending_steam_changes(restart := false) -> Dictionary:
		pending = 0
		return _rec("apply_pending", [restart])
	func open_steam_page(g: Dictionary, p: String) -> Dictionary: return _rec("open_steam_page", [g["key"], p])
	func return_from_steam() -> void: calls.append(["return_from_steam"])


class FakeAchievements extends Node:
	signal loaded(appid: String, result: Dictionary)
	signal changed(appid: String)
	var data := {}
	var invalidated: Array = []
	func request(appid: Variant) -> void:
		loaded.emit(str(appid), data)
	func invalidate(appid: Variant) -> void:
		invalidated.append(str(appid))


## Records method calls for the session wiring.
class Recorder extends RefCounted:
	var calls: Array = []
	func start(a, o): calls.append(["start", a, o])
	func stop(): calls.append(["stop"])
	func set_focused(f): calls.append(["set_focused", f])
	func set_game_running(on): calls.append(["set_game_running", on])
	func start_game(k): calls.append(["start_game", k])
	func end_game(): calls.append(["end_game"])
	func pause(): calls.append(["pause"])
	func resume(): calls.append(["resume"])
	func invalidate(a): calls.append(["invalidate", a])
	func set_target_fps(f): calls.append(["set_target_fps", f])
	func settings_for(_k): return {"fps_limit": 40, "frame_gen": true}


func _steam_game(installed := true) -> Dictionary:
	return {"key": "steam:42", "store": "steam", "id": "42", "title": "Hollow Tide", "installed": installed,
		"art": {"cover": "", "hero": "", "logo": "", "icon": ""},
		"info": {"released": 2017, "time_to_beat": null, "anticheat": null, "protondb": "gold"},
		"last_played": 0, "playtime_min": 0}


func _epic_game(installed := false) -> Dictionary:
	var g := _steam_game(installed)
	g["key"] = "epic:Fern"
	g["store"] = "epic"
	g["id"] = "Fern"
	g["title"] = "Fern Valley"
	return g


func _ach() -> Dictionary:
	return {"appid": "42", "unlocked": 2, "total": 4, "source": "steam-local", "items": [
		{"id": "a", "name": "First Steps", "description": "Finish the tutorial", "hidden": false, "icon": "", "icon_gray": "", "unlocked": true, "unlock_time": 1700000000, "rarity": 82.5},
		{"id": "b", "name": "Deep Dive", "description": "Reach the trench", "hidden": false, "icon": "", "icon_gray": "", "unlocked": true, "unlock_time": 1760000000, "rarity": 4.2},
		{"id": "c", "name": "Secret Ending", "description": "Spoiler", "hidden": true, "icon": "", "icon_gray": "", "unlocked": false, "unlock_time": 0, "rarity": 1.0},
		{"id": "d", "name": "Collector", "description": "Find every shell", "hidden": false, "icon": "", "icon_gray": "", "unlocked": false, "unlock_time": 0, "rarity": 20.0},
	]}


func _rig() -> Dictionary:
	var lib := FakeLibrary.new()
	var st: Node = InstallState.new()
	st.attach(lib)
	var toasts: Array = []
	var layer := Control.new()
	var acts: Node = GameActions.new()
	acts.setup(lib, st, func(t, i = "info", tone = "", d = ""): toasts.append([t, i, tone, d]), layer, null)
	return {"lib": lib, "state": st, "actions": acts, "toasts": toasts, "layer": layer}


func _free(r: Dictionary) -> void:
	r["actions"].free()
	r["layer"].free()
	r["state"].free()
	r["lib"].free()


func _texts(n: Node, out: Array = []) -> Array:
	if n is Label or n is Button:
		out.append(n.text)
	for c in n.get_children():
		_texts(c, out)
	return out


# ------------------------------------------------------------ words

func test_formatting() -> void:
	eq(TG.bytes(4509715660), "4.2 GB", "bytes")
	eq(TG.bytes(820 * 1024 * 1024), "820 MB", "MB over 100 rounds")
	eq(TG.rate(18.4 * 1024 * 1024), "18.4 MB/s", "rate")
	eq(TG.rate(0.0), "", "no rate")
	eq(TG.eta(30), "less than a minute left", "seconds")
	eq(TG.eta(360), "about 6 min left", "minutes")
	eq(TG.eta(3600 + 1200), "about 1 h 20 min left", "hours")
	eq(TG.eta(-1), "", "unknown eta")
	eq(TG.progress_line({"bytes_done": 1073741824, "bytes_total": 4294967296, "rate": 1048576.0, "eta": 120}), "1.0 GB of 4.0 GB · 1.0 MB/s · about 2 min left", "progress line")
	eq(TG.progress_line({"bytes_done": 10, "bytes_total": 40, "unit": "files"}), "10 of 40 files", "files")
	eq(TG.fraction({"bytes_done": 1, "bytes_total": 4}), 0.25, "fraction")
	eq(TG.fraction({}), -1.0, "unknown fraction")
	eq(TG.failed("install", "Hollow Tide"), "Couldn't install Hollow Tide", "failure toast")
	eq(TG.ago(100, 100 + 240), "4 min ago", "ago")


func test_autotune_message() -> void:
	var raise := TG.autotune_message(true, {"target_fps": 60, "ceiling_w": 17.0, "tdp_max": 30.0})
	ok(raise[0].contains("60 fps") and raise[0].contains("17 W"), "raise names fps and watts")
	ok(raise[1].contains("TDP"), "raise says TDP")
	var lower := TG.autotune_message(true, {"target_fps": 60, "ceiling_w": 30.0, "tdp_max": 30.0})
	ok(lower[1].contains("graphics settings"), "at the max: lower settings")
	eq(TG.autotune_message(false, {}), [], "cleared: nothing")


# ------------------------------------------------------------ install state

func test_install_state_tracks_jobs() -> void:
	var lib := FakeLibrary.new()
	lib.queue = [{"key": "epic:Fern", "action": "install", "title": "Fern Valley", "state": "running", "progress": {}, "error": "", "size": 0},
		{"key": "steam:7", "action": "update", "title": "Seven", "state": "queued", "progress": {}, "error": "", "size": 0}] as Array[Dictionary]
	var st: Node = InstallState.new()
	var changes := [0]
	st.changed.connect(func(): changes[0] += 1)
	st.attach(lib)
	eq(st.state_of("epic:Fern"), "installing", "running install")
	eq(st.state_of("steam:7"), "queued", "queued")
	ok(changes[0] >= 1, "changed on attach")
	lib.download_progress.emit("epic:Fern", 1024, 4096, 512.0, 6)
	eq(st.fraction("epic:Fern"), 0.25, "live fraction")
	eq(st.progress_of("epic:Fern")["rate"], 512.0, "rate kept")
	var dec: Array = st.decorate([_epic_game(), _steam_game()])
	eq(dec[0]["download"]["progress"], 0.25, "decorate: progress for badges")
	eq(dec[0]["install_state"], "installing", "decorate: state")
	ok(not dec[1].has("install_state"), "untouched game stays as is")
	lib.install_state_changed.emit("epic:Fern", "installed")
	eq(st.done.size(), 1, "finished job listed")
	eq(st.done[0]["action"], "install", "with its action")
	ok(st.done[0]["ok"], "ok")
	lib.install_state_changed.emit("steam:42", "update_required")
	eq(st.decorate([_steam_game()])[0]["update_available"], true, "update_required -> update badge")
	lib.install_state_changed.emit("steam:7", "updating")
	lib.action_failed.emit("steam:7", "update", "Disk full")
	eq(st.state_of("steam:7"), "failed", "failure recorded")
	eq(st.done[0]["message"], "Disk full", "with Steam's words")
	st.free()
	lib.free()


func test_tile_corner_and_bar() -> void:
	eq(TileProgress.corner_for("installing", 0.45)["short"], "45%", "percent while bytes move")
	eq(TileProgress.corner_for("queued", -1.0)["short"], "Queued", "queued")
	eq(TileProgress.corner_for("paused", 0.3)["short"], "Paused", "paused says so")
	eq(TileProgress.corner_for("update_required", -1.0)["short"], "Update", "update")
	eq(TileProgress.corner_for("", -1.0), {}, "nothing to add")
	var r := _rig()
	r["lib"].install_state_changed.emit("epic:Fern", "installing")
	r["lib"].download_progress.emit("epic:Fern", 50, 100, 1.0, 10)
	var t: Button = Tile.new()
	t.setup(_epic_game())
	TileProgress.apply(t, r["state"])
	ok(t.card.get_node_or_null(TileProgress.BAR) != null, "progress bar on the cover")
	eq(t.corner_badge.label.text, "50%", "corner shows percent")
	r["lib"].install_state_changed.emit("epic:Fern", "installed")
	TileProgress.apply(t, r["state"])
	ok(t.card.get_node_or_null(TileProgress.BAR) == null, "bar gone when done")
	t.free()
	_free(r)


# ------------------------------------------------------------ game page

func test_primary_action() -> void:
	var c := {"pause": true, "resume": true, "update": true}
	eq(GamePage.primary_for(_steam_game(), "", c)["id"], "play", "installed: Play")
	eq(GamePage.primary_for(_steam_game(false), "", c)["id"], "install", "owned: Install")
	eq(GamePage.primary_for(_steam_game(), "update_required", c)["id"], "update", "update needed")
	eq(GamePage.primary_for(_steam_game(), "update_required", {"update": false})["id"], "play", "can't update here: Play")
	eq(GamePage.primary_for(_steam_game(false), "installing", c)["id"], "pause", "downloading: Pause")
	eq(GamePage.primary_for(_steam_game(false), "paused", c)["id"], "resume", "paused: Resume")
	eq(GamePage.primary_for(_steam_game(false), "installing", {"pause": false})["id"], "downloads", "no pause: see downloads")
	eq(GamePage.primary_for(_steam_game(false), "queued", c)["id"], "downloads", "queued: downloads")


func test_game_page_leaves_room_for_the_top_bar() -> void:
	var r := _rig()
	var p: Control = GamePage.new()
	p.setup(_steam_game(), Screens.FakeLauncher.new(), {"library": r["lib"], "state": r["state"], "actions": r["actions"]})
	eq(p.frame.offset_top, float(p.FRAME_TOP + GamePage.TOP_INSET), "hero card starts below the top bar")
	eq(p.scroll.offset_top, float(p.FRAME_TOP + GamePage.TOP_INSET), "content too")
	ok(p.has_method("set_top_target"), "main can link d-pad up to the tabs")
	p.free()
	_free(r)


func test_game_page_v2() -> void:
	var r := _rig()
	var ach := FakeAchievements.new()
	ach.data = _ach()
	r["lib"].pending = 1
	var p: Control = GamePage.new()
	p.setup(_steam_game(), Screens.FakeLauncher.new(), {"library": r["lib"], "state": r["state"], "actions": r["actions"], "achievements": ach})
	var t := _texts(p)
	eq(p.play_button.text, "Play", "primary")
	ok(p.manage_button.visible and TG.MANAGE in t, "Manage button")
	ok(p.find_child("AchievementsJump", true, false) == null, "no Achievements button: the card is right below")
	ok(p.pending_card.visible, "Steam changes waiting card")
	ok(TG.RESTART_STEAM in t, "restart button")
	eq(p.focusables[0], p.restart_button, "restart is the first stop below the actions")
	eq(p.ach_card.summary.text, "2 of 4 unlocked", "achievement count")
	eq(p.ach_card.detail_name.text, "Deep Dive", "the rarest in the gold box")
	eq(p.ach_card.cells.size(), 3, "a row each, the rarest not repeated under its box")
	ok(p.ach_card.show_all == null, "no Show all for a short list")
	eq(p.ach_card.items[0]["id"], "a", "newest unlock first (after the rarest)")
	eq(p.ach_card.items[2]["id"], "c", "hidden last")
	p.ach_card.show_item(p.ach_card.items[2])
	eq(p.ach_card.detail_name.text, TG.ACH_HIDDEN, "hidden name stays secret")
	ok(not p.ach_card.detail_line.text.contains("Spoiler"), "and its description")
	ok(p.ach_card.cells[2].find_child("Icon", true, false).modulate.a < 0.5, "locked dimmed")
	ok(p.ach_card.cells[1].focus_neighbor_top == p.ach_card.cells[1].get_path_to(p.ach_card.cells[0]), "list up/down")
	eq(p.hints_for_focus(p.ach_card.cells[0])[0], ["DPAD", "Browse"], "list hints")
	p.restart_button.pressed.emit()
	eq(r["lib"].calls[-1], ["apply_pending", true], "restart Steam to apply")
	ok(not p.pending_card.visible, "card hides once applied")
	# A download starts: Pause, live progress line.
	r["lib"].install_state_changed.emit("steam:42", "updating")
	r["lib"].download_progress.emit("steam:42", 1073741824, 4294967296, 1048576.0, 120)
	r["state"].on_progress("steam:42", 1073741824, 4294967296, 1048576.0, 120)
	eq(p.play_button.text, TG.PAUSE, "primary becomes Pause")
	ok(p.status_box.visible, "progress shows")
	ok(p.status_label.text.begins_with("Updating 25%"), "says what and how far: " + p.status_label.text)
	ok(p.status_label.text.contains("about 2 min left"), "time left")
	p.play_button.pressed.emit()
	eq(r["lib"].calls[-1], ["pause", "steam:42"], "Pause pauses")
	p.free()
	ach.free()
	_free(r)


func test_achievements_card_rarest_and_show_all() -> void:
	var ach := FakeAchievements.new()
	var items: Array = []
	for i in 9:
		items.append({"id": "x%d" % i, "name": "Ach %d" % i, "unlocked": i < 4, "unlock_time": 1762000000 + i, "rarity": 50.0 - i * 5.0})
	ach.data = {"unlocked": 4, "total": 9, "source": "steam-local", "items": items}
	var c: VBoxContainer = AchievementsCard.new()
	c.setup("42", ach)
	eq(c.summary.text, "4 of 9 unlocked", "count and bar, like Home's card")
	eq(c.rarest["id"], "x3", "the rarest unlocked one")
	ok(c.detail_eyebrow.visible and c.detail_name.text == "Ach 3", "shown gold-edged over the list")
	eq(c.cells.size(), AchievementsCard.LIST_ROWS + 1, "four rows, then Show all")
	for i in AchievementsCard.LIST_ROWS:
		ok(c.cells[i].tooltip_text != "Ach 3", "the rarest isn't repeated in row %d" % i)
	eq(c.items.map(func(a): return a["id"]).slice(0, 4), ["x2", "x1", "x0", "x3"], "the rarest moves past the rows shown first")
	ok(c.detail_line.text.contains("35% of players"), "rounded like the rows")
	ok(c.show_all != null and c.show_all.text == TG.ACH_SHOW_ALL % 9, "names how many")
	c.show_all.pressed.emit()
	eq(c.cells.size(), 9, "every row after Show all")
	var few: Array = items.slice(0, 3)
	eq(AchievementsCard.without_rarest(AchievementsCard.ordered(few), few[2]).map(func(a): return a["id"]), ["x1", "x0"], "a short list leaves it to the box")
	var small := {"rarity": 41.8, "unlocked": true, "unlock_time": 1762000000, "name": "A"}
	ok(AchievementsCard.describe(small).contains("42% of players"), "41.8 reads 42%, as in the row")
	c.free()
	ach.free()


func test_game_page_explains_unavailable_install() -> void:
	var r := _rig()
	r["lib"].caps["install"] = false
	r["lib"].caps["why"] = {"install": "Steam isn't installed"}
	var p: Control = GamePage.new()
	p.setup(_steam_game(false), Screens.FakeLauncher.new(), {"library": r["lib"], "state": r["state"], "actions": r["actions"]})
	eq(p.play_button.text, "Install", "still Install")
	ok(p.status_box.visible and p.status_label.text == "Steam isn't installed", "why under the action")
	p.play_button.pressed.emit()
	eq(r["lib"].calls.size(), 0, "nothing called")
	ok(r["toasts"][-1][3] == "Steam isn't installed", "toast explains")
	p.free()
	_free(r)


# ------------------------------------------------------------ actions

func test_manage_rows() -> void:
	var c := {"install": false, "uninstall": true, "update": false, "verify": true, "move": false, "launch_options": true,
		"compat_tool": true, "pause": false, "resume": false, "cancel": false,
		"why": {"install": "Already installed", "update": "Steam updates games by itself; turn on Steam control to start one now",
			"move": "Turn on Steam control, or use Steam's Properties > Installed Files", "pause": "Nothing running for this game"}}
	var rows := GameActions.manage_rows(_steam_game(), c, "")
	var ids: Array = rows.map(func(x): return x["id"])
	eq(ids, ["update", "verify", "move", "launch_options", "compat_tool", "steam_store", "steam_properties", "uninstall"], "rows for an installed Steam game")
	var upd: Dictionary = rows[0]
	ok(upd["disabled"] and upd["detail"].contains("Steam control"), "unavailable update explained")
	eq(rows[-1]["tone"], "bad", "uninstall in red")
	var busy := GameActions.manage_rows(_epic_game(false), {"pause": true, "cancel": true, "launch_options": false, "compat_tool": false, "why": {"launch_options": "Not installed", "compat_tool": "Not installed"}}, "installing")
	eq(busy.map(func(x): return x["id"]), ["pause", "cancel"], "downloading: pause and cancel; not-installed reasons hidden")


func test_uninstall_is_confirmed() -> void:
	var r := _rig()
	r["actions"].uninstall(_steam_game())
	ok(r["actions"].sheet.is_open(), "confirmation sheet")
	eq(r["actions"].sheet.rows.size(), 2, "keep / uninstall")
	r["actions"].sheet.pick("no")
	eq(r["lib"].calls.size(), 0, "kept")
	r["actions"].uninstall(_steam_game())
	r["actions"].sheet.pick("yes")
	eq(r["lib"].calls[-1], ["uninstall", "steam:42"], "uninstalled after yes")
	ok(not r["actions"].sheet.is_open(), "sheet closed")
	_free(r)


func test_install_location_picker() -> void:
	var r := _rig()
	r["actions"].install(_epic_game())
	eq(r["lib"].calls[-1], ["install", "epic:Fern", {"path": "/home/deck/Games"}], "one drive: straight in")
	r["lib"].locations.append({"path": "/run/media/deck/SD/Games", "label": "SD", "free": 5 * 1024 * 1024 * 1024, "removable": true})
	r["actions"].install(_epic_game())
	var sheet: Control = r["actions"].sheet
	ok(sheet.is_open(), "two drives: picker")
	var t := _texts(sheet)
	ok("200 GB free" in t, "free space shown")
	ok(TG.INTERNAL in t, "internal named plainly")
	eq(sheet.items[1]["tone"], "warn", "low space warned")
	ok(sheet.items[1]["detail"].begins_with(TG.LOW_SPACE), "with a reason")
	sheet.pick("/run/media/deck/SD/Games")
	eq(r["lib"].calls[-1], ["install", "epic:Fern", {"path": "/run/media/deck/SD/Games"}], "installs where picked")
	eq(r["toasts"][-1][0], "Installing Fern Valley", "started toast")
	_free(r)


func test_failure_toast_not_doubled() -> void:
	var r := _rig()
	r["lib"].result = {"ok": false, "via": "", "why": "Couldn't reach Steam"}
	r["actions"].verify(_steam_game())
	eq(r["toasts"][-1][0], "Couldn't check the files of Hollow Tide", "failure toast")
	eq(r["toasts"][-1][3], "Couldn't reach Steam", "with why")
	ok(not r["actions"].should_toast_failure("steam:42", "verify"), "Library's action_failed for the same call is skipped")
	ok(r["actions"].should_toast_failure("steam:42", "install"), "others still toast")
	_free(r)


func test_launch_options_and_compat() -> void:
	var r := _rig()
	r["lib"].opts = "PROTON_LOG=1 %command%"
	r["actions"].launch_options(_steam_game())
	ok(r["actions"].is_modal(), "keyboard open")
	var kb: PanelContainer = r["actions"].keyboard
	eq(kb.text, "PROTON_LOG=1 %command%", "starts with current options")
	kb.set_text("")
	kb.toggle_shift()
	for ch in "dxvk":
		kb.type(ch)
	kb.toggle_shift()
	kb.type("_")
	kb.type("x")
	eq(kb.text, "DXVK_x", "shift and symbols type")
	kb.close()
	eq(r["lib"].calls[-1], ["set_launch_options", "steam:42", "DXVK_x"], "saved")
	eq(r["toasts"][-1][0], TG.SAVED_PENDING, "says Steam applies it after a restart")
	ok(not r["actions"].is_modal(), "closed")
	r["actions"].compat_tool(_steam_game())
	var sheet: Control = r["actions"].sheet
	eq(sheet.rows.size(), 3, "a row per tool")
	ok(sheet.items[0]["current"], "default marked current")
	sheet.pick("GE-Proton10")
	eq(r["lib"].calls[-1], ["set_compat_tool", "steam:42", "GE-Proton10"], "tool set")
	_free(r)


func test_text_keyboard_layout() -> void:
	var kb: PanelContainer = TextKeyboard.new()
	eq(kb.keys.size(), 6, "four letter rows, symbols, bottom row (built once)")
	eq(kb.get_child(0).get_child_count(), 7, "head + six rows")
	kb.free()


# ------------------------------------------------------------ downloads

func test_downloads_view() -> void:
	var r := _rig()
	r["lib"].queue = [{"key": "epic:Fern", "action": "install", "title": "Fern Valley", "state": "running", "progress": {"bytes_done": 0, "bytes_total": 0}, "error": "", "size": 0},
		{"key": "epic:Moss", "action": "install", "title": "Moss Road", "state": "queued", "progress": {}, "error": "", "size": 8589934592}] as Array[Dictionary]
	r["lib"].queue_changed.emit()
	r["lib"].download_progress.emit("epic:Fern", 2147483648, 4294967296, 20971520.0, 300)
	r["state"].done = [{"key": "steam:42", "title": "Hollow Tide", "action": "update", "ok": true, "message": "", "at": 100}]
	r["state"].clock = func() -> int: return 400
	var v: Control = DownloadsView.new()
	v.setup(r["state"], r["actions"], func(k: String) -> Dictionary: return _epic_game() if k == "epic:Fern" else {})
	var t := _texts(v)
	ok("Fern Valley" in t and "Moss Road" in t and "Hollow Tide" in t, "now, next and finished")
	ok("50%" in t, "percent")
	ok(t.any(func(s): return s.contains("2.0 GB of 4.0 GB") and s.contains("20.0 MB/s") and s.contains("about 5 min left")), "numbers line")
	ok(t.any(func(s): return s == "Waiting to install · 8.0 GB"), "queued line")
	ok(t.any(func(s): return s.begins_with("Updated · 5 min ago")), "finished line")
	eq(v.focus_list.size(), 5, "pause, cancel, game page, next row, finished row")
	eq(v.summary_label.text, "2 in the queue · 20.0 MB/s", "summary")
	r["lib"].download_progress.emit("epic:Fern", 3221225472, 4294967296, 20971520.0, 60)
	r["state"]._last_emit.clear()
	r["state"].on_progress("epic:Fern", 3221225472, 4294967296, 20971520.0, 60)
	ok("75%" in _texts(v), "live update in place")
	eq(v.focus_list.size(), 5, "no rebuild per tick")
	v.focus_list[0].pressed.emit()
	eq(r["lib"].calls[-1], ["pause", "epic:Fern"], "pause button")
	v.focus_list[3].pressed.emit()
	ok(r["actions"].sheet.is_open(), "row opens options")
	var ids: Array = r["actions"].sheet.items.map(func(x): return x["id"])
	ok("up" in ids and "cancel" in ids and "page" in ids, "move up, cancel, game page")
	r["actions"].sheet.pick("up")
	eq(r["lib"].calls[-1], ["reorder", "epic:Moss", -1], "reordered")
	eq(v.hints_for_focus(v.focus_list[3])[0], ["A", TG.DL_OPTIONS], "row hints")
	# Layout: hero card, then Up next and Finished side by side.
	ok(v.list.get_child(0).name == "Now" and v.list.get_child(1).name == "Columns", "hero card above the two columns")
	ok(v.next_col.find_child("Job_epic_Moss", true, false) != null, "queued job under Up next")
	ok(v.done_col.get_child_count() == 2, "finished row under Finished")
	ok(v.list.get_child(0).find_child("HeroStage", true, false) != null, "the game's art in the hero")
	eq(v.focus_list[3].get_node(v.focus_list[3].focus_neighbor_right), v.focus_list[4], "right crosses to Finished")
	eq(v.focus_list[3].get_node(v.focus_list[3].focus_neighbor_top), v.focus_list[0], "up goes back to the hero")
	eq(v.focus_list[0].get_node(v.focus_list[0].focus_neighbor_bottom), v.focus_list[3], "down from the hero into Up next")
	v.free()
	r["lib"].queue = [] as Array[Dictionary]
	r["state"].done = []
	r["lib"].queue_changed.emit()
	var e: Control = DownloadsView.new()
	e.setup(r["state"], r["actions"], func(_k: String) -> Dictionary: return {})
	ok(e.empty.visible and TG.DL_EMPTY in _texts(e), "empty state")
	e.free()
	_free(r)


func test_downloads_button_and_overlay() -> void:
	var b: Button = DownloadsButton.new()
	b.set_progress(true, 0.4, 3)
	ok(b.active and b._count.visible and b._count.text == "3", "ring and count while active")
	b.set_progress(false, -1.0, 0)
	ok(not b._count.visible, "quiet when idle")
	b.free()
	var o: Control = SteamOverlay.new()
	var back := [0]
	o.back_requested.connect(func(): back[0] += 1)
	o.show_for("steam:42", "Hollow Tide", "steam", "install")
	ok(o.is_open(), "shown")
	eq(o.title_label.text, TG.STEAM_NEEDS, "title")
	ok(o.line_label.text.contains("Hollow Tide"), "names the game")
	o.back_button.pressed.emit()
	eq(back[0], 1, "back to GameCove")
	ok(not o.is_open(), "closed")
	o.free()


# ------------------------------------------------------------ library and home

func test_library_install_filters() -> void:
	var l: Control = LibraryScreen.new()
	var hooked := [0]
	l.tile_hook = func(_t): hooked[0] += 1
	l.set_games([_steam_game(true), _epic_game(false)])
	eq(hooked[0], 2, "every tile goes through the hook")
	l.set_install_filter("installed")
	eq(l.shown.map(func(g): return g["key"]), ["steam:42"], "installed only")
	l.set_install_filter("not_installed")
	eq(l.shown.map(func(g): return g["key"]), ["epic:Fern"], "not installed only")
	ok(l.filter_buttons[1].button_pressed, "chip shows it")
	l.filter_buttons[1].pressed.emit()
	eq(l.install_filter, "", "pressing again clears it")
	ok(not l.downloads_chip.visible, "no downloads chip when idle")
	l.set_downloads(2, 0.5)
	ok(l.downloads_chip.visible and l.downloads_chip.text == "50%", "downloads chip with progress")
	ok(l.downloads_chip in l._toolbar(), "in the focus row")
	l.free()


func test_home_action() -> void:
	eq(Home.action_for(_steam_game())["id"], "play", "Play")
	eq(Home.action_for(_steam_game(false))["id"], "install", "owned, not installed: Install")
	var g := _steam_game(false)
	g["install_state"] = "installing"
	g["download"] = {"progress": 0.45}
	eq(Home.action_for(g)["text"], "Installing 45%", "progress on the spotlight")
	eq(Home.action_for(g)["id"], "downloads", "opens downloads")
	var u := _steam_game()
	u["install_state"] = "update_required"
	u["update_available"] = true
	eq(Home.action_for(u)["id"], "update", "update")
	var h: Control = Home.new()
	h.set_games([_steam_game(false)])
	eq(h.play_button.text, "Install", "spotlight button")
	h.free()


# ------------------------------------------------------------ session wiring

func test_session_wiring() -> void:
	var perf := Recorder.new()
	var ach := Recorder.new()
	var upd := Recorder.new()
	var ctl := Recorder.new()
	var disc := Recorder.new()
	var w := SessionWiring.new()
	w.setup({"perf": perf, "achievements": ach, "updates": upd, "controller": ctl, "discover": disc, "launcher": Recorder.new()})
	w.home_in_front(true)
	eq(perf.calls, [], "nothing before a game")
	w.game_started(_steam_game(), 42)
	eq(perf.calls[0], ["start", 42, {"target_fps": 40, "frame_gen_multiplier": 2.0}], "perf starts with the frame limit and frame gen")
	eq(upd.calls, [["set_game_running", true]], "updates hold off")
	eq(ctl.calls, [["start_game", "steam:42"]], "controller profile")
	eq(disc.calls, [["pause"]], "discover pauses")
	w.home_in_front(true)
	eq(perf.calls[-1], ["set_focused", false], "home in front pauses sampling")
	w.home_in_front(false)
	eq(perf.calls[-1], ["set_focused", true], "game in front resumes")
	w.game_ended(_steam_game())
	eq(perf.calls[-1], ["stop"], "perf stops")
	eq(ach.calls, [["invalidate", "42"]], "achievements re-read")
	eq(upd.calls[-1], ["set_game_running", false], "updates free again")
	eq(ctl.calls[-1], ["end_game"], "controller back")
	eq(disc.calls[-1], ["resume"], "discover resumes")
	w.game_ended(_epic_game())
	eq(ach.calls.size(), 1, "no Steam stats for other stores")
	var empty := SessionWiring.new()
	empty.setup({})
	empty.game_started(_steam_game(), 1)
	empty.game_ended(_steam_game())
	ok(true, "missing services are fine")


## Profiles owns the frame limit: Auto TDP and PerfMonitor get the profile's,
## not the Launcher's older value, and follow a change while the game runs.
func test_session_wiring_uses_the_profiles_frame_limit() -> void:
	var c: Node = load("res://tests/test_ui_controls.gd").fake()
	var file := "user://test_wiring_profiles.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(file))
	var p: Node = load("res://scripts/controls/profiles.gd").new()
	p.setup(c, "msi-claw-8-ex", file)
	p.set_value("steam:42", "", "display.fps_limit", 30)
	var perf := Recorder.new()
	var w := SessionWiring.new()
	w.setup({"perf": perf, "launcher": Recorder.new(), "controls": c, "profiles": p})
	w.game_started(_steam_game(), 42)
	eq(perf.calls[0][2]["target_fps"], 30, "the profile's 30 fps, not the Launcher's 40")
	c.set_value("display.fps_limit", 60)
	eq(perf.calls[-1], ["set_target_fps", 60.0], "a new frame limit reaches Auto TDP at once")
	w.game_ended(_steam_game())
	c.set_value("display.fps_limit", 30)
	ok(perf.calls[-1][0] != "set_target_fps", "not after the game")
	p.free()
	c.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(file))


func test_game_closer_plan() -> void:
	var GC = load("res://scripts/ui/games/game_closer.gd")
	var steam: Array = GC.plan(_steam_game(), 42, 0)
	eq(steam[0], [["sh", "-c", GC.KILL_SCRIPT, "gamecove-close", "TERM", "steam", "42"]], "Steam: stop its launch wrapper and everything under it")
	eq(steam[1], [["sh", "-c", GC.KILL_SCRIPT, "gamecove-close", "KILL", "steam", "42"]], "then force")
	ok(GC.KILL_SCRIPT.contains("pgrep -u \"$(id -u)\" -f \"SteamLaunch AppId=$arg( |$)\""), "own user only, anchored to SteamLaunch AppId=<id>")
	var scoped: Array = GC.plan(_epic_game(true), 3000000123, 4242)
	eq(scoped[0], [["systemctl", "--user", "stop", "app-steam-app3000000123-*.scope"], ["sh", "-c", GC.KILL_SCRIPT, "gamecove-close", "TERM", "pid", "4242"]], "our scope, and the pid's group and children")
	eq(scoped[1], [["sh", "-c", GC.KILL_SCRIPT, "gamecove-close", "KILL", "pid", "4242"]], "pid forced later")
	eq(GC.plan(_epic_game(true), 0, 0), [[], []], "nothing to close")
	eq(GC.plan({"store": "steam", "id": "42 -x"}, 0, 0), [[], []], "a bad Steam id closes nothing")
	var c: Node = GC.new()
	var ran: Array = []
	c.run = func(cmd: Array) -> int:
		ran.append(cmd)
		return 1
	var s := GameSessionStub.new()
	ok(not c.close(s), "nothing running")
	s.active = true
	ok(c.close(s), "closing")
	eq(ran[0][0], "sh", "ran without waiting")
	c.free()


class GameSessionStub extends RefCounted:
	var active := false
	var game := {"key": "steam:42", "store": "steam", "id": "42"}
	var app_id := 42
	var pid := 0
	func is_active() -> bool: return active


## Library with the off-main-thread reads: answers come later, through callbacks.
class AsyncLibrary extends FakeLibrary:
	var waiting: Array = []
	func launch_options_async(g: Dictionary, done: Callable) -> void: waiting.append(func(): done.call(launch_options(g)))
	func compat_tool_async(g: Dictionary, done: Callable) -> void: waiting.append(func(): done.call(compat_tool(g)))
	func compat_tools_async(g: Dictionary, done: Callable) -> void: waiting.append(func(): done.call(compat_tools(g)))
	func answer() -> void:
		while not waiting.is_empty():
			waiting.pop_front().call()


func test_launch_options_and_compat_read_off_the_main_thread() -> void:
	var lib := AsyncLibrary.new()
	var st: Node = InstallState.new()
	st.attach(lib)
	var acts: Node = GameActions.new()
	var layer := Control.new()
	acts.setup(lib, st, func(_t, _i = "", _tone = "", _d = ""): pass, layer, null)
	lib.opts = "-novid"
	acts.launch_options(_steam_game())
	ok(not acts.is_modal(), "nothing opens before the value is read")
	lib.answer()
	ok(acts.is_modal(), "keyboard opens with the answer")
	eq(acts.keyboard.text, "-novid", "with the current options")
	acts.keyboard.close()
	acts.compat_tool(_steam_game())
	lib.answer()
	eq(acts.sheet.rows.size(), 3, "tools menu after both answers")
	acts.free()
	layer.free()
	st.free()
	lib.free()


## The kill script itself, with fake pgrep / ps / id on PATH and a recording
## kill: never signals anything real.
func test_game_closer_kill_script() -> void:
	var GC = load("res://scripts/ui/games/game_closer.gd")
	var bin := ProjectSettings.globalize_path("user://test_closer_bin")
	DirAccess.make_dir_recursive_absolute(bin)
	var log := bin.path_join("kills.log")
	var files := {
		# reaper 100 (AppId=42) with child 101, grandchild 102; reaper 200 is AppId=420
		"pgrep": "#!/bin/sh\ncase \"$*\" in\n*\"-u 1000 -f SteamLaunch AppId=42( |$)\"*) echo 100 ;;\n\"-P 100\") echo 101 ;;\n\"-P 101\") echo 102 ;;\n\"-P 300\") echo 301 ;;\nesac\nexit 0\n",
		"ps": "#!/bin/sh\ncase \"$*\" in *\"-p 100\") echo ' 100' ;; *\"-p 300\") echo ' 7' ;; esac\n",
		"id": "#!/bin/sh\necho 1000\n",
		"fakekill": "#!/bin/sh\necho \"$*\" >> '%s'\n" % log,
	}
	for f in files:
		var h := FileAccess.open(bin.path_join(f), FileAccess.WRITE)
		h.store_string(files[f])
		h.close()
		OS.execute("chmod", ["+x", bin.path_join(f)])
	var run := func(args: Array) -> void:
		if FileAccess.file_exists(log):
			DirAccess.remove_absolute(log)
		# create_process, like GameCloser.run: arguments go to execvp untouched
		var pid := OS.create_process("env", PackedStringArray(["PATH=" + bin + ":/usr/bin:/bin", "GC_KILL=fakekill", "sh", "-c", GC.KILL_SCRIPT, "gamecove-close"] + args))
		var waited := 0
		while pid > 0 and OS.is_process_running(pid) and waited < 5000:
			OS.delay_msec(10)
			waited += 10
	run.call(["TERM", "steam", "42"])
	eq(FileAccess.get_file_as_string(log).split("\n", false), PackedStringArray(["-TERM -- -100", "-TERM 102", "-TERM 101", "-TERM 100"]),
		"the reaper's own group, then every descendant and the reaper")
	run.call(["KILL", "pid", "300"])
	eq(FileAccess.get_file_as_string(log).split("\n", false), PackedStringArray(["-KILL 301", "-KILL 300"]),
		"not a group leader (group 7 is someone else's): only the process and its children")
	run.call(["TERM", "steam", "42; reboot"])
	ok(not FileAccess.file_exists(log), "junk id: nothing signalled")
	for f in files:
		DirAccess.remove_absolute(bin.path_join(f))
