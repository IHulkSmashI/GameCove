extends "res://tests/test_case.gd"
## The Stream tab with the real Streaming service (sync mode, fake runner and
## spawner, hosts set directly): what shows for each PC state, the pairing and
## settings sheets, Add PC, play / wake, hints. Built outside the scene tree.

const Streaming := preload("res://scripts/streaming/streaming.gd")
const Screen := preload("res://scripts/ui/streaming/streaming_screen.gd")
const HostCard := preload("res://scripts/ui/streaming/host_card.gd")
const FakeRunner := preload("res://tests/fixtures/system/fake_runner.gd")
const FakeSpawn := preload("res://tests/fixtures/streaming/fake_spawn.gd")
const TopBar := preload("res://scripts/ui/top_bar.gd")
const MainScript := preload("res://scripts/main.gd")
const T := preload("res://scripts/ui/texts_streaming.gd")

const UUID := "A1B2C3D4-0000-4E5F-8899-AABBCCDDEEFF"

var dir := ""
var toasts: Array = []
var played: Array = []


func _service(moonlight := true) -> Node:
	dir = ProjectSettings.globalize_path("user://test_streaming_ui_%d" % randi())
	var s: Node = Streaming.new()
	s.sync_mode = true
	s.setup({"runner": FakeRunner.new(), "spawn": FakeSpawn.new(), "home": "/nonexistent", "path_env": "",
		"data_dir": dir, "display": {"width": 1920, "height": 1200, "hz": 120, "hdr": true}, "gpu_family": "intel-xe2",
		"probe": func(_a, _p): return []})
	s.moonlight = {"kind": "flatpak", "program": "/usr/bin/flatpak", "prefix": ["run", "--branch=stable", "com.moonlight_stream.Moonlight"],
		"config": "", "cache": ""} if moonlight else {"kind": ""}
	return s


func _host(id: String, fields: Dictionary) -> Dictionary:
	var h: Dictionary = Streaming.blank_host(id)
	h["uuid"] = id
	h.merge(fields, true)
	return h


func _apps() -> Array:
	return [{"id": 1, "title": "Desktop", "hdr": true, "uuid": "", "art": ""},
		{"id": 1093255277, "title": "Steam Big Picture", "hdr": true, "uuid": "", "art": ""},
		{"id": 77, "title": "Iron Meridian", "hdr": false, "uuid": "", "art": ""}]


func _screen(s: Node) -> Control:
	toasts = []
	played = []
	var sc: Control = Screen.new()
	sc.setup({"streaming": s, "toast": func(t, i, tone, d): toasts.append([t, i, tone, d]),
		"play": func(g, id, app): played.append([g, id, app])})
	sc._make_modals()
	return sc


func _done(sc: Control, s: Node) -> void:
	sc.free()
	s.free()
	OS.move_to_trash(dir)


func test_setup_guide_and_moonlight_card() -> void:
	var s := _service(false)
	var sc := _screen(s)
	ok(sc.empty != null, "setup guide with no PCs")
	ok(sc.empty.find_child("QR", true, false) != null, "QR to Vibepollo's download page")
	ok(sc.install_button != null and sc.install_button.text == T.INSTALL, "Install Moonlight button")
	eq(sc.default_focus(), sc.install_button, "focus starts on Install")
	eq(sc.hints(sc.install_button)[0], ["A", T.INSTALL], "hint says what A does")
	s.moonlight = {"kind": "native", "program": "/usr/bin/moonlight", "prefix": [], "config": "", "cache": ""}
	sc.rebuild()
	eq(sc.install_button, null, "card gone once Moonlight is there")
	eq(sc.default_focus(), sc.add_button, "then Add PC")
	_done(sc, s)


func test_host_states() -> void:
	var s := _service()
	s.hosts = {
		UUID: _host(UUID, {"name": "GAMING-PC", "address": "192.168.1.20", "addresses": ["192.168.1.20"], "status": "online",
			"paired": true, "latency_ms": 3, "apps": _apps(), "apps_state": "ready", "permission": 0x07000100,
			"info": {"hevc": true, "av1": true, "hdr": true}}),
		"U2": _host("U2", {"name": "living-room", "address": "192.168.1.31", "status": "online", "paired": false}),
		"U3": _host("U3", {"name": "office", "address": "100.101.102.103", "status": "asleep", "paired": true, "mac": "AA:BB:CC:00:11:22", "remote": true}),
	}
	var sc := _screen(s)
	eq(sc.host_cards.size(), 3, "three cards")
	eq(sc.selected_id, UUID, "paired online PC chosen first")
	var card: Button = sc.host_cards[0]
	eq(card._status.text, "ONLINE · 3 MS", "status line")
	eq(card.selected, true, "selected outline")
	ok(sc.shelf != null and sc.shelf.tiles.size() == 3, "apps as a shelf")
	eq(sc.shelf.tiles[0].sub_label.text, "GAMING-PC · HDR", "tile line: PC and HDR")
	eq(sc.shelf.tiles[2].sub_label.text, "GAMING-PC", "no HDR for that app")
	eq(sc.hints(sc.shelf.tiles[0])[0], ["A", T.H_STREAM], "A streams")
	eq(sc.hints(card)[0], ["A", T.H_OPEN], "A opens a paired PC")
	ok(sc._detail.find_child("PermissionNote", true, false) == null, "launch allowed: no note")
	# unpaired
	sc._select("U2")
	ok(sc._detail.find_child("PairButton", true, false) != null, "pair card")
	eq(sc.hints(sc.host_cards[1])[0], ["A", T.H_PAIR], "A pairs")
	eq(sc.shelf, null, "no apps before pairing")
	# asleep, remote
	sc._select("U3")
	ok(sc._detail.find_child("WakeButton", true, false) != null, "wake card")
	eq(sc.host_cards[2]._status.text, "ASLEEP · REMOTE", "remote shown")
	eq(sc.hints(sc.host_cards[2])[0], ["A", T.H_WAKE], "A wakes")
	_done(sc, s)


func test_busy_denied_and_permissions() -> void:
	var s := _service()
	s.hosts = {UUID: _host(UUID, {"name": "GAMING-PC", "address": "192.168.1.20", "status": "busy", "paired": true,
		"current_app": 1093255277, "apps": _apps(), "apps_state": "ready", "permission": 0x03000000})}
	var sc := _screen(s)
	ok(sc._detail.find_child("RunningCard", true, false) != null, "running-now card")
	eq(sc.detail_focus[0].name, &"Resume", "Resume first")
	eq(Screen.host_line(s.host(UUID), true), T.PLAYING % "Steam Big Picture", "card says what's playing")
	ok(sc._detail.find_child("PermissionNote", true, false) != null, "no launch permission: told how to allow it")
	sc.detail_focus[0].pressed.emit()
	eq(played.size(), 1, "Resume streams the running app")
	eq(played[0][2]["id"], 1093255277, "that app")
	s.hosts[UUID]["apps_state"] = "denied"
	s.hosts[UUID]["apps"] = []
	s.hosts[UUID]["current_app"] = 0
	s.hosts[UUID]["status"] = "online"
	sc.rebuild()
	ok(sc._detail.find_child("DeniedNote", true, false) != null, "Vibepollo hides the list: note")
	_done(sc, s)


func test_play_and_wake() -> void:
	var s := _service()
	s.hosts = {UUID: _host(UUID, {"name": "GAMING-PC", "address": "192.168.1.20", "addresses": ["192.168.1.20"], "status": "online",
		"paired": true, "apps": _apps(), "apps_state": "ready", "mac": "D8:BB:C1:12:34:56"})}
	var sc := _screen(s)
	sc.shelf.tiles[2].pressed.emit()
	eq(played.size(), 1, "tile streams")
	eq(played[0][0]["key"], "stream:%s:77" % UUID, "the app's game")
	eq(played[0][0]["store"], "stream", "a stream")
	s.hosts[UUID]["status"] = "asleep"
	s.ctx["send"] = func(_a, _p, _b): return true
	sc.rebuild()
	sc.shelf.tiles[0].pressed.emit()
	eq(played.size(), 1, "asleep: no stream yet")
	eq(s.hosts[UUID]["status"], "waking", "woken first")
	ok(toasts.any(func(t): return str(t[0]).begins_with("Waking")), "told")
	_done(sc, s)


func test_pairing_sheet() -> void:
	var s := _service()
	s.hosts = {"U2": _host("U2", {"name": "living-room", "address": "192.168.1.31", "addresses": ["192.168.1.31"], "status": "online"})}
	var sc := _screen(s)
	sc.host_action("U2")
	eq(sc.pair_sheet.state, "waiting", "sheet open")
	var pin: String = s.pairing_pin()
	eq("".join(sc.pair_sheet.digits.map(func(d): return d.text)), pin, "PIN in the boxes")
	ok(sc.pair_sheet.steps_box.find_child("Url", true, false).text == "https://192.168.1.31:47990", "web UI address")
	eq(sc.hints(null), [["A", T.H_CANCEL]], "hint")
	sc.pair_sheet.cancel_requested.emit()
	eq(s.pairing_host(), "", "cancelled in the service")
	eq(sc.pair_sheet.state, "closed", "closed")
	s.pair_changed.emit("U2", "failed", {"why": T.PAIR_TIMEOUT})
	eq(sc.pair_sheet.state, "failed", "failure shown")
	eq(sc.pair_sheet.status_label.text, T.PAIR_TIMEOUT, "why")
	s.pair_changed.emit("U2", "paired", {})
	eq(sc.pair_sheet.state, "paired", "paired")
	_done(sc, s)


func test_settings_sheet() -> void:
	var s := _service()
	s.hosts = {UUID: _host(UUID, {"name": "GAMING-PC", "address": "192.168.1.20", "status": "online", "paired": true,
		"apps": _apps(), "apps_state": "ready", "info": {"hevc": true, "av1": true, "hdr": true}})}
	var sc := _screen(s)
	sc.open_settings(sc.shelf.tiles[2])
	var sh: Control = sc.settings_sheet
	ok(sh.is_open(), "open")
	eq(sh.title.text, T.SETTINGS_FOR_APP % "Iron Meridian", "for the app")
	ok(sh.own_row != null and sh.own_row.value() == false, "uses the PC's settings")
	ok(sh.summary.text.contains("1920x1200 · 120 fps · AV1"), "matched to the panel and decoder")
	sh.rows["resolution"].step(1)   # native -> 720p
	eq(s.has_app_picks(UUID, 77), true, "changing a row gives the app its own settings")
	eq(sh.own_row.value(), true, "switch follows")
	eq(s.resolved(UUID, 77)["width"], 1280, "app at 720p")
	eq(s.resolved(UUID)["width"], 1920, "PC unchanged")
	ok(sh.summary.text.contains("1280x720"), "summary follows")
	sh.own_row.step(1)
	eq(s.has_app_picks(UUID, 77), false, "back to the PC's")
	eq(sh.rows["resolution"].value(), "native", "rows show the PC's again")
	sh.close()
	sc.open_settings(sc.host_cards[0])
	eq(sh.own_row, null, "PC settings: no per-app switch")
	sh.rows["quality"].step(1)
	eq(s.effective_picks(UUID)["quality"], "best", "PC pick saved")
	_done(sc, s)


func test_add_pc_and_more() -> void:
	var s := _service()
	var sc := _screen(s)
	sc.open_add()
	ok(sc._kb_modal.visible, "keyboard")
	sc._on_add_closed("not an address")
	ok(toasts.any(func(t): return t[0] == T.BAD_ADDRESS), "bad address told")
	sc._on_add_closed("192.168.1.77")
	ok(s.hosts.has("addr:192.168.1.77"), "added")
	sc.selected_id = "addr:192.168.1.77"
	sc.open_more()
	ok(sc.more_sheet.is_open(), "more sheet")
	var ids: Array = sc.more_sheet.items.map(func(i): return i["id"])
	ok("forget" in ids and "settings" in ids and not "sleep" in ids, "rows that apply")
	sc.more_sheet.pick("forget")
	ok(not s.hosts.has("addr:192.168.1.77"), "forgotten")
	_done(sc, s)


func test_tab_wired() -> void:
	ok("stream" in MainScript.SCREENS, "Stream is a screen")
	eq(MainScript.SCREENS.find("stream"), MainScript.SCREENS.find("settings") - 1, "before Settings")
	ok(TopBar.TABS.any(func(t): return t[0] == "stream" and t[1] == "Stream"), "top bar tab")
	var tb: HBoxContainer = TopBar.new()
	ok(tb.tabs.has("stream"), "tab button")
	tb.free()
