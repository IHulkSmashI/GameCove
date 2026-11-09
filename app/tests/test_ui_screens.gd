extends "res://tests/test_case.gd"
## Builds the home screen, game page and quick menu with fake services, with
## an empty library and with three games, and checks what ends up on screen.

const Home := preload("res://scripts/ui/home.gd")
const GamePage := preload("res://scripts/ui/game_page.gd")
const QuickMenu := preload("res://scripts/ui/quick_menu.gd")
const SettingsForm := preload("res://scripts/ui/settings_form.gd")
const Texts := preload("res://scripts/ui/texts.gd")
const TG := preload("res://scripts/ui/texts_games.gd")
const TC := preload("res://scripts/ui/texts_controls.gd")
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
	## devices.json's answer for the Claw 8 EX (the quick menu's What works chips).
	func features() -> Dictionary:
		var D: GDScript = load("res://scripts/device/device.gd")
		var want := str(profile.get("id", "msi-claw-8-ex"))
		for r in D.load_table():
			if r.get("id", "") == want:
				return D.features_of(r)
		return {}


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
	# The Continue game owns the spotlight: Recently played starts after it,
	# and Installed leaves out what Recently played already shows.
	eq(h.tiles("recent").map(func(t): return t.game["title"]), ["Hades"], "recent row skips the spotlight game")
	eq(h.tiles("installed").size(), 0, "no installed row repeating the recent one")
	eq(h.tiles("all").size(), 3, "all row")
	eq(h.shelf_ids(), ["recent", "short", "store_steam", "store_epic", "store_gog", "all"], "shelves in order")
	eq(String(h.default_focus().name), "Play", "focus lands on Play")
	ok("Jump back in" in _texts(h), "spotlight says why it's there")
	var all_text := _texts(h)
	ok("Linux denied" in all_text, "anti-cheat pill in the tile's plate")
	ok(not "10 h to beat" in all_text, "no focus strip on tiles (the spotlight has it)")
	ok("GOG · Not installed" in all_text, "not installed in the sub-line")
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
	var ttb: Control = p.find_child("TimeToBeat", true, false)
	ok(ttb != null and ttb.find_child("Ttb_Main", true, false) != null, "time to beat as stat chips")
	ok(t.has(Texts.format_hours(10.0)) and t.has(Texts.format_hours(20.0)), "main and extras hours")
	eq(p.info_lines.size(), 3, "anti-cheat and ProtonDB lines, then the data credit")
	eq(p.info_lines[2].text, Texts.DATA_CREDIT, "ProtonDB (ODbL) and IGDB credited on the about card")
	eq(p.info_lines[2].get_theme_font_size("font_size"), 12, "credit small and dim, at the foot")
	ok(p.find_child("Back", true, false) == null, "no Back button: B goes back")
	ok(p.actions.all(func(b): return b.text != "Settings"), "no jump to the settings card on screen")
	for i in 3:
		var title: String = [TG.ABOUT, TG.ACH_TITLE, TC.GAME_CARD][i]
		var card: Node = p.find_child("Card_" + title.validate_node_name(), true, false)
		if card != null:
			eq(int(card.get_meta("col", -1)), i, "%s in bento column %d" % [title, i])
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


