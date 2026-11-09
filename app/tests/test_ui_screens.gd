extends "res://tests/test_case.gd"
## Builds the home screen, game page and quick menu with fake services, with
## an empty library and with three games, and checks what ends up on screen.

const Home := preload("res://scripts/ui/home.gd")
const GamePage := preload("res://scripts/ui/game_page.gd")
const QuickMenu := preload("res://scripts/ui/quick_menu.gd")
const SettingsForm := preload("res://scripts/ui/settings_form.gd")
const Texts := preload("res://scripts/ui/texts.gd")
const Logic := preload("res://tests/test_ui_logic.gd")
const LibraryScreen := preload("res://scripts/ui/library_screen.gd")
const TopBar := preload("res://scripts/ui/top_bar.gd")


class FakeDevice extends RefCounted:
	var profile := {"name": "MSI Claw 8 EX AI+", "chip": "Intel Panther Lake", "gpu": "Arc B390 / B370 (Xe3)",
		"panel_hz": [60, 120], "support": "full"}
	var bat := {"percent": 72, "status": "Discharging", "watts": 9.4}
	func display_name() -> String: return profile["name"]
	func support_level() -> String: return profile["support"]
	func battery() -> Dictionary: return bat


class FakePower extends RefCounted:
	signal changed(state: Dictionary)
	var supported := {"tdp": false, "profiles": false, "charge_limit": false, "fan": false}
	var st := {"backend": "none", "tdp_w": 17.0, "tdp_min": 8.0, "tdp_max": 35.0, "profile": "balanced",
		"profiles": ["battery", "balanced", "performance"], "charge_limit": 80,
		"fan_mode": "auto", "fan_modes": ["quiet", "auto", "max"]}
	var calls: Array = []
	var accept := true
	func state() -> Dictionary:
		var s := st.duplicate()
		s["supported"] = supported.duplicate()
		return s
	func set_tdp(w: float) -> bool: return _store("tdp_w", w)
	func set_profile(p: String) -> bool: return _store("profile", p)
	func set_charge_limit(p: int) -> bool: return _store("charge_limit", p)
	func set_fan_mode(m: String) -> bool: return _store("fan_mode", m)
	func _store(k: String, v: Variant) -> bool:
		calls.append([k, v])
		if accept:
			st[k] = v
			changed.emit(state())
		return accept


class FakeLauncher extends RefCounted:
	var saved := {}
	func settings_for(key: String) -> Dictionary:
		return saved.get(key, {"goal": "balanced", "fps_limit": 0, "upscaler": "auto", "frame_gen": false, "low_latency": true}).duplicate()
	func save_settings(key: String, s: Dictionary) -> void:
		saved[key] = s.duplicate()


class FakeGamescope extends RefCounted:
	var running := false
	var focused := 0          # gamescope app id in front; 769 = GameCove
	var overlay := []
	var fps := []
	func is_running() -> bool: return running
	func focused_app() -> int: return focused
	func set_fps_limit(f: int) -> bool:
		fps.append(f)
		return running
	func set_refresh_rate(_hz: int) -> bool: return running
	func set_overlay(o: bool) -> void: overlay.append(o)


func _three() -> Array:
	var ttb := {"time_to_beat": {"main_h": 10.0, "extra_h": 20.0, "complete_h": null, "count": 17, "source": "igdb"}}
	return [
		Logic.g("steam", "1", "Hades", true, 500, ttb),
		Logic.g("epic", "2", "Fortnite", true, 900, {"anticheat": {"status": "denied", "anticheats": ["EAC"]}}),
		Logic.g("gog", "3", "Witcher 3", false, 0),
	]


func _services(power := FakePower.new(), gs := FakeGamescope.new()) -> Dictionary:
	return {"device": FakeDevice.new(), "power": power, "launcher": FakeLauncher.new(), "gamescope": gs}


func _texts(n: Node, out: Array = []) -> Array:
	if n is Label or n is Button:
		out.append(n.text)
	for c in n.get_children():
		_texts(c, out)
	return out


func _count(n: Node, script: Script) -> int:
	var c := 1 if n.get_script() == script else 0
	for child in n.get_children():
		c += _count(child, script)
	return c


# ------------------------------------------------------------ home

func test_home_empty() -> void:
	var h: Control = Home.new()
	h.set_games([])
	eq(h.hero_game, {}, "no hero game")
	eq(h.tiles("recent").size() + h.tiles("installed").size() + h.tiles("all").size(), 0, "no tiles")
	ok(h.find_child("Refresh", true, false) != null, "empty hero offers Look again")
	ok("No games found yet" in _texts(h), "empty message shown")
	eq(String(h.default_focus().name), "Refresh", "focus lands on Look again")
	h.free()


func test_home_three_games() -> void:
	var h: Control = Home.new()
	h.set_games(_three())
	eq(h.hero_game["title"], "Fortnite", "hero is most recent installed")
	eq(h.spotlight_game["title"], "Fortnite", "spotlight starts on the Continue game")
	eq(h.tiles("recent").map(func(t): return t.game["title"]), ["Fortnite", "Hades"], "recent row")
	eq(h.tiles("installed").size(), 2, "installed row")
	eq(h.tiles("all").size(), 3, "all row")
	eq(h.shelf_ids(), ["recent", "installed", "short", "store_steam", "store_epic", "store_gog", "all"], "shelves in order")
	eq(String(h.default_focus().name), "Play", "focus lands on Play")
	ok("Jump back in" in _texts(h), "spotlight says why it's there")
	var all_text := _texts(h)
	ok("Linux denied" in all_text, "anti-cheat badge on tile")
	ok("10 h to beat" in all_text, "time to beat badge on tile")
	ok("Not installed" in all_text, "uninstalled badge")
	ok(h.find_child("TitleCard", true, false) != null, "art-less games get a generated cover")
	eq(h.tile_for("gog:3").game["title"], "Witcher 3", "tile lookup by key")
	h.free()


func test_library_screen_filters() -> void:
	var l: Control = LibraryScreen.new()
	l.set_games(_three())
	eq(l.tiles().size(), 3, "every game")
	eq(l.tiles().map(func(t): return t.game["title"]), ["Fortnite", "Hades", "Witcher 3"], "recent first, unplayed last")
	l.set_store("epic")
	eq(l.tiles().size(), 1, "Epic filter")
	l.set_store("amazon")
	eq(l.tiles().size(), 0, "no Amazon games")
	ok(l.find_child("EmptyFilter", true, false).is_visible_in_tree() or l.find_child("Empty", true, false).visible, "empty message visible")
	l.cycle_store(1)
	eq(l.store, "", "cycling past Amazon wraps to All")
	l.set_sort("az")
	eq(l.tiles().map(func(t): return t.game["title"]), ["Fortnite", "Hades", "Witcher 3"], "A to Z")
	l.cycle_sort(1)
	eq(l.sort, "playtime", "X cycles the sort")
	eq(l.tiles()[0].game["title"], "Fortnite", "most played first")
	l.set_query("wit")
	eq(l.tiles().map(func(t): return t.game["title"]), ["Witcher 3"], "search")
	eq(l.count_label.text, "1 of 3", "count shows the filter")
	l.set_query("zzz")
	ok(l.find_child("EmptyFilter", true, false).text.contains("zzz"), "no-results line names the query")
	l.free()


func test_top_bar_status() -> void:
	var b: HBoxContainer = TopBar.new()
	b.set_status("MSI Claw 8 EX AI+", {"percent": 72, "status": "Charging", "watts": 9.44}, "1:30 PM")
	eq(b.device_name, "MSI Claw 8 EX AI+", "device name kept")
	eq(b.battery_label.text, "72%", "battery percent")
	ok(b.battery_icon.texture != null, "battery icon drawn")
	eq(b.clock_label.text, "1:30 PM", "clock")
	ok(not b.wifi_icon.visible, "no Wi-Fi data, no icon")
	b.set_status("X", {"percent": 72}, "", {"connected": true, "strength": 0.8})
	ok(b.wifi_icon.visible, "Wi-Fi shown when known")
	b.set_status("X", {"percent": -1, "status": "", "watts": -1.0}, "")
	ok(not b.battery_label.visible, "no battery hides the reading")
	ok(TopBar.is_low({"percent": 12, "status": "Discharging"}), "12% discharging is low")
	ok(not TopBar.is_low({"percent": 12, "status": "Charging"}), "charging is never low")
	b.select("library")
	ok(b.tabs["library"].button_pressed and not b.tabs["home"].button_pressed, "tab selection")
	b.set_dot("library", true)
	ok(b.has_dot("library"), "new dot")
	b.free()


# ------------------------------------------------------------ game page

func test_game_page() -> void:
	var launcher := FakeLauncher.new()
	var p: Control = GamePage.new()
	# Env rows (upscaler, frame gen, low latency) only show for games we start
	# ourselves; Steam games get a note instead (test_launch_focus.gd).
	var g: Dictionary = _three()[0].duplicate(true)
	g["store"] = "epic"
	p.setup(g, launcher)
	var t := _texts(p)
	ok("Hades" in t, "title")
	ok("Play" in t, "play button")
	ok(t.has(Texts.ttb_line(_three()[0]["info"])), "time to beat line")
	eq(p.info_lines.size(), 4, "ttb, anti-cheat and ProtonDB lines, then the data credit")
	eq(p.info_lines[3].text, Texts.DATA_CREDIT, "ProtonDB (ODbL) and IGDB credited on the about card")
	eq(p.form.rows.keys(), ["goal", "fps_limit", "upscaler", "frame_gen", "low_latency"], "all per-game settings")
	for k in p.form.rows:
		ok(p.form.rows[k].hint_text().length() > 20, "explanation under " + k)

	p.form.rows["goal"].step(-1)  # balanced -> battery
	eq(launcher.saved["steam:1"]["goal"], "battery", "goal saved")
	eq(launcher.saved["steam:1"]["fps_limit"], 30, "goal preset applied")
	eq(p.form.rows["fps_limit"].value(), 30, "fps row follows goal")
	p.form.rows["low_latency"].step(1)
	eq(launcher.saved["steam:1"]["low_latency"], false, "toggle saved")
	launcher.saved["steam:1"]["upscaler"] = "xess"
	p.form.reload()
	eq(p.form.rows["upscaler"].value(), "xess", "reload picks up changes made elsewhere")
	p.free()

	var p2: Control = GamePage.new()
	p2.setup(_three()[2], launcher)
	eq(p2.play_button.text, "Install", "uninstalled game says Install")
	p2.free()


# ------------------------------------------------------------ quick menu

func test_quick_menu_unsupported_device() -> void:
	var gs := FakeGamescope.new()
	var m: Control = QuickMenu.new()
	m.setup(_services(FakePower.new(), gs))
	m.open({})
	eq(m.section, 0, "opens on This game")
	eq(gs.overlay, [true], "overlay on")
	ok("No game selected" in _texts(m.body), "no game message")
	m.show_section(1)
	var na := _texts(m.body).filter(func(s): return s.ends_with(Texts.NOT_AVAILABLE))
	eq(na.size(), 4, "four not-available lines")
	eq(m.focusables().size(), 0, "nothing to focus")
	m.show_section(2)
	eq(m.focusables().size(), 0, "screen hidden outside gamescope")
	m.show_section(4)
	var dev := _texts(m.body)
	ok("MSI Claw 8 EX AI+" in dev and "Chip: Intel Panther Lake" in dev and "Support: Full" in dev, "device lines")
	m.close()
	eq(gs.overlay, [true, false], "overlay off")
	m.free()


func test_quick_menu_with_game_and_full_support() -> void:
	var power := FakePower.new()
	power.supported = {"tdp": true, "profiles": true, "charge_limit": true, "fan": true}
	var gs := FakeGamescope.new()
	gs.running = true
	var svc := _services(power, gs)
	var m: Control = QuickMenu.new()
	m.setup(svc)
	var steam_game: Dictionary = _three()[0]
	m.open(steam_game)
	eq(m.focusables().size(), 2, "Steam game: goal and fps only (env settings go in Steam launch options)")
	m.close()
	var game: Dictionary = _three()[0].duplicate(true)
	game["store"] = "epic"  # a game we start ourselves gets every setting
	m.open(game)
	eq(_count(m.body, SettingsForm), 1, "game settings shown")
	eq(m.focusables().size(), 4, "goal, fps, upscaler, frame gen")
	ok("Hades" in _texts(m.body), "game title")

	var goal: Control = m.body.find_child("goal", true, false)
	gs.focused = 769
	goal.step(1)  # balanced -> smooth
	eq(svc["launcher"].saved["steam:1"]["frame_gen"], true, "smooth saved")
	ok(["profile", "performance"] in power.calls, "smooth picks the performance profile")
	eq(gs.fps, [], "no live fps limit while GameCove's home is in front")
	gs.focused = 1145360
	goal.step(-1)  # smooth -> balanced
	eq(gs.fps[-1], 60, "fps limit pushed to gamescope while the game runs")

	m.show_section(1)
	eq(m.focusables().size(), 4, "profile, TDP, charge limit, fan")
	ok("Battery 72%, discharging   ·   drawing 9.4 W" in _texts(m.body), "live battery and watts")
	var tdp: Control = m.body.get_node("tdp")
	eq(tdp.slider.min_value, 8.0, "tdp min")
	eq(tdp.slider.max_value, 35.0, "tdp max")
	eq(tdp.value_text(), "17 W", "tdp value")
	m.body.get_node("fan").step(1)
	ok(["fan_mode", "max"] in power.calls, "fan set")
	power.accept = false
	m.body.get_node("charge_limit").step(1)
	eq(m.body.get_node("charge_limit").value(), 80, "refused change rolls back")
	ok(m.status_label.text.begins_with("Couldn't change"), "refusal explained")
	for k in ["profile", "tdp", "charge_limit", "fan"]:
		ok(Texts.explain(k).length() > 20, "explanation for " + k)

	m.show_section(2)
	eq(m.focusables().size(), 2, "refresh rate and fps limit under gamescope")
	m.show_section(3)
	ok(_texts(m.body).size() >= 2, "controller status lines")
	m.free()


func test_quick_menu_input_and_focus() -> void:
	var m: Control = QuickMenu.new()
	m.setup(_services())
	var game: Dictionary = _three()[0].duplicate(true)
	game["store"] = "epic"
	m.open(game)
	eq(m.focus_target(), m.focusables()[0], "first control gets focus on open")
	eq(m.focus_target("upscaler"), m.focusables()[2], "rebuild keeps focus on the same setting")
	var rb := InputEventJoypadButton.new()
	rb.button_index = JOY_BUTTON_RIGHT_SHOULDER
	rb.pressed = true
	m._unhandled_input(rb)
	eq(m.section, 1, "RB goes to Power")
	eq(m.focus_target(), m.tabs[1], "focus on the tab when a section has no controls")
	var lb := InputEventJoypadButton.new()
	lb.button_index = JOY_BUTTON_LEFT_SHOULDER
	lb.pressed = true
	m._unhandled_input(lb)
	m._unhandled_input(lb)
	eq(m.section, 4, "LB wraps to Device")
	var e := InputEventKey.new()
	e.keycode = KEY_E
	e.pressed = true
	m._unhandled_input(e)
	eq(m.section, 0, "E (keyboard RB) wraps to This game")
	m.close()
	m.open(_three()[0])
	eq(m.section, 0, "always reopens on This game")
	var esc := InputEventAction.new()
	esc.action = "ui_cancel"
	esc.pressed = true
	m._unhandled_input(esc)
	ok(not m.visible, "B closes")
	m.free()


func test_focus_chain_never_escapes() -> void:
	var m: Control = QuickMenu.new()
	m.setup(_services())
	m.open(_three()[0])
	var f: Array = m.focusables()
	eq(f[0].get_node(f[0].focus_neighbor_top), m.tabs[0], "up from the first control reaches the tab")
	eq(f[-1].get_node(f[-1].focus_neighbor_bottom), f[-1], "down from the last control stays put")
	eq(m.tabs[0].get_node(m.tabs[0].focus_neighbor_bottom), f[0], "down from the tab enters the section")
	eq(m.tabs[0].get_node(m.tabs[0].focus_neighbor_left), m.tabs[0], "left from the first tab stays put")
	m.free()
