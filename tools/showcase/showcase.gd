extends "../screenshots/shoot_controls.gd"
## The showcase set: every main screen with a real, lived-in profile (real
## games, their Steam art and achievements, GameCove's own gamedb data, live
## Discover prices for Canada from snapshot/). Run through shoot.sh:
##   tools/showcase/shoot.sh            (every shot, both sizes, both themes)
## or directly (needs a display):
##   godot --path app --resolution 1920x1200 -s ../tools/showcase/showcase.gd -- --out DIR [--only a,b] [--suffix _x]
## SHOWCASE_THEME=light renders the light theme (default: Cove).

const SHOTS_ALL := ["home", "library", "game", "game_achievements", "discover", "discover_deals", "discover_calendar",
	"discover_wishlist", "discover_calendar_month", "quick_game", "quick_power", "quick_display", "quick_controller", "quick_leds",
	"settings_power", "settings_about", "settings_fixes", "settings_updates", "settings_privacy", "settings_profiles"]

var here := ""
var lib_doc: Dictionary = {}
var ach_svc: Node
var now := 0


## Achievements for every game from library.json (the real Steam lists).
class ShowcaseAchievements extends Node:
	signal loaded(appid: String, result: Dictionary)
	signal changed(appid: String)
	var by_appid := {}
	var invalidated: Array = []
	func request(appid: Variant) -> void:
		var a := str(appid)
		loaded.emit(a, by_appid.get(a, {"appid": a, "unlocked": 0, "total": 0, "source": "steam-local", "items": []}))
	func invalidate(appid: Variant) -> void:
		invalidated.append(str(appid))


## The maker's own product picture (device_photos.json "maker_image"), fetched
## by shoot.sh the way the app fetches it on the device.
class MakerPhoto extends RefCounted:
	signal photo_ready(device_id: String, path: String)
	var enabled := true
	var maker_enabled := true
	var path := ""
	var page_url := ""
	func photo_for(_id: String) -> Dictionary:
		return {"path": path, "credit": {"kind": "maker", "maker": "MSI", "page_url": page_url, "url": ""}}
	func set_enabled(on: bool) -> void:
		enabled = on
	func set_maker_enabled(on: bool) -> void:
		maker_enabled = on


func theme_id() -> String:
	var t := OS.get_environment("SHOWCASE_THEME")
	return t if t != "" else "cove"


static func theme_override() -> String:
	return OS.get_environment("SHOWCASE_THEME")


func _run() -> void:
	OS.low_processor_usage_mode = false
	here = get_script().resource_path.get_base_dir()
	T = load("res://tests/test_ui_screens.gd")
	S = load("res://tests/test_ui_settings.gd")
	now = int(Time.get_unix_time_from_system())
	lib_doc = JSON.parse_string(FileAccess.get_file_as_string(here.path_join("library.json")))
	games = _library()
	ach_svc = ShowcaseAchievements.new()
	ach_svc.name = "ShowcaseAchievements"
	ach_svc.by_appid = _achievements()
	root.add_child(ach_svc)

	var prefs = load("res://scripts/ui/ui_prefs.gd")
	prefs.path = OS.get_cache_dir().path_join("gamecove-showcase-ui.cfg")
	DirAccess.remove_absolute(prefs.path)
	prefs.theme = theme_id()
	prefs.match_art = theme_id() == "cove"
	load("res://scripts/main.gd").boot_splash = false
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await frames(3)
	main._live_timer.stop()
	main._live_timer.wait_time = 9999
	var flow_script = load("res://scripts/ui/setup/setup_flow.gd")
	if flow_script.instance != null:
		flow_script.instance.finish()
	# main's _ready reads the prefs file (defaults): set the theme after it.
	prefs.theme = theme_id()
	prefs.match_art = theme_id() == "cove"
	main.apply_theme()
	var lib := root.get_node("Library")
	# The real Library scans this machine (finds nothing) and rescans when the
	# game database download lands: let its first scan finish, stop the
	# rescans, then show the showcase library.
	for i in 600:
		if int(lib.get("_task")) == -1:
			break
		await process_frame
	var db: Node = lib.get("_db")
	if db != null and db.updated.is_connected(lib.refresh):
		db.updated.disconnect(lib.refresh)
	lib.games.assign(games)
	lib.changed.emit()
	_status()
	await frames(4)
	await _use_device("msi-claw-8-ex", claw_patch())
	_photo()

	# Home: Elden Ring in the spotlight.
	main.show_screen("home")
	await frames(4)
	main.home.play_button.grab_focus()
	await shot("home")

	if want(["library"]):
		main.show_screen("library")
		await frames(4)
		for t in main.library_screen.tiles():
			if t.game["key"] == "steam:1086940":
				t.grab_focus()
		await shot("library")
		main.show_screen("home")

	if want(["game", "game_achievements"]):
		main._open_page(_find_key("steam:1245620"))
		await frames(6)
		await shot("game")
		if want(["game_achievements"]) and main.page.ach_card != null and main.page.ach_card.cells.size() > 2:
			main.page.ach_card.cells[1].grab_focus()
			await frames(10)
			await shot("game_achievements")
		main._close_page()

	if want(["discover", "discover_deals", "discover_calendar", "discover_calendar_month", "discover_wishlist"]):
		await _discover(lib)

	_relibrary(lib)
	await _quick()
	_relibrary(lib)
	await _settings()
	await finish()


# ------------------------------------------------------------------ data

func _cache(rel: String) -> String:
	var p := here.path_join("cache").path_join(rel)
	return ProjectSettings.globalize_path(p) if FileAccess.file_exists(p) else ""


func _library() -> Array:
	var out: Array = []
	for g in lib_doc["games"]:
		var a: String = g["steam_appid"]
		var info: Dictionary = g["info"].duplicate(true)
		if info.get("released") != null:
			info["released"] = int(info["released"])
		if info.get("time_to_beat") is Dictionary and info["time_to_beat"].has("count"):
			info["time_to_beat"]["count"] = int(info["time_to_beat"]["count"])
		var e := {"key": "%s:%s" % [g["store"], g["id"]], "store": g["store"], "id": g["id"], "title": g["title"],
			"installed": g["installed"],
			"art": {"cover": _cache(a + "/cover.jpg"), "hero": _cache(a + "/hero.jpg"), "logo": _cache(a + "/logo.png"), "icon": ""},
			"info": info,
			"last_played": int(now - float(g["last_played_days"]) * 86400.0) if float(g["last_played_days"]) >= 0.0 else 0,
			"playtime_min": int(g["playtime_min"])}
		if g.has("added_days"):
			e["added"] = now - int(float(g["added_days"]) * 86400.0)
		if g.get("update", false):
			e["update_available"] = true
		out.append(e)
	return out


func _achievements() -> Dictionary:
	var out := {}
	for g in lib_doc["games"]:
		if g["store"] != "steam" or g["achievements"].is_empty():
			continue
		var a: String = g["steam_appid"]
		var items: Array = []
		var shift := now - int(lib_doc.get("now", now))
		var unlocked := 0
		for it in g["achievements"]:
			var icon := _cache("ach/%s/%s" % [a, it["icon"]])
			var gray := _cache("ach/%s/%s" % [a, it["icon_gray"]])
			items.append({"id": it["id"], "name": it["name"], "description": it["description"], "hidden": it["hidden"],
				"icon": icon, "icon_gray": gray if gray != "" else icon, "unlocked": it["unlocked"],
				"unlock_time": int(it["unlock_time"]) + shift if it["unlocked"] else 0, "rarity": float(it["rarity"])})
			if it["unlocked"]:
				unlocked += 1
		out[a] = {"appid": a, "unlocked": unlocked, "total": items.size(), "source": "steam-local", "items": items}
	return out


## The real Library autoload rescans this machine in the background (and finds
## nothing): put the showcase library back before each group of shots.
func _relibrary(lib: Node) -> void:
	lib.games.assign(games)
	lib.changed.emit()


func _find_key(k: String) -> Dictionary:
	for g in games:
		if g["key"] == k:
			return g
	return {}


func _status() -> void:
	main.top_bar.set_status("MSI Claw 8 EX AI+", {"percent": 72, "status": "Discharging", "watts": 9.4}, "8:42 PM", {"connected": true, "strength": 0.8})
	main.top_bar.set_telemetry({"tdp_w": 17.0, "profile": "balanced", "temp_c": 58.0})
	main.home.set_battery_left("~2 h 45 min")
	main.hint_status.text = "● GameCove 0.4   MSI Claw 8 EX AI+"
	main.achievements_api = ach_svc
	main.home.set_achievements(ach_svc)
	main.status_panel.set_battery("MSI Claw 8 EX AI+", {"percent": 72, "status": "Discharging", "watts": 9.4, "time_left_min": 165})


func _photo() -> void:
	var p := _cache("device/msi-claw-8-ex.png")
	if p == "":
		return
	var mp := MakerPhoto.new()
	mp.path = p
	mp.page_url = "https://us-store.msi.com/Claw-8-EX-AI-CG3EM-024US"
	var svc: Dictionary = main.settings.services.duplicate()
	svc["photo"] = mp
	main.settings.set_services(svc)


## Profiles: this player's own per-game layers (games from the library).
func _use_device(id: String, patch: Dictionary) -> void:
	await super(id, patch)
	profiles.reset("steam:892970")
	profiles.reset("epic:fn")
	_device_details()
	profiles.set_layer("steam:1245620", "", {"power.tdp": 20, "display.fps_limit": 45, "perf.upscaler": "xess"})
	profiles._remember_title("steam:1245620", "ELDEN RING")
	profiles.set_layer("steam:2379780", "battery", {"power.tdp": 8, "display.fps_limit": 30})
	profiles._remember_title("steam:2379780", "Balatro")
	profiles.set_layer("steam:1086940", "", {"power.tdp": 22, "display.fps_limit": 40, "perf.frame_gen": 2})
	profiles._remember_title("steam:1086940", "Baldur's Gate 3")
	profiles.save_file()


## The Claw 8 EX as read live on the device (tools/devicematrix/overrides.json:
## board MS-1T91, BIOS E1T91IMS.10E, Bazzite 45, kernel 7.2.15, InputPlumber
## 0.83.1) and the Device pages' services with those values.
func _device_details() -> void:
	var info: Dictionary = dev.data
	info["device"]["board"] = "MS-1T91"
	info["device"]["bios_version"] = "E1T91IMS.10E"
	info["device"]["bios_date"] = ""
	info["chip"]["kernel"] = "7.2.15-ogc1.1.fc45.x86_64"
	info["software"]["os_version"] = "45"
	info["software"]["os"] = "Bazzite"
	var svc: Dictionary = main.settings.services.duplicate()
	var F = DeviceFakes.services()
	F["device"].free()
	var u = F["updates"]
	u.st["os_info"] = {"id": "bazzite", "name": "Bazzite", "version": "45", "variant": "deck", "atomic": true}
	u.st["os"]["current"] = "45"
	u.st["os"]["available"] = false
	u.st["os"]["version"] = ""
	u.st["phase"] = {"os": "up_to_date", "firmware": "up_to_date", "flatpak": "available", "maker": "up_to_date", "drivers": "up_to_date"}
	u.st["maker"] = {"available": false, "items": [], "error": "", "stale": false}
	u.st["drivers"] = {"available": false, "items": [], "error": ""}
	u.st["hub"] = [
		{"id": "index:bios:bios", "section": "firmware", "kind": "bios", "name": "BIOS", "current": "E1T91IMS.10E", "latest": "",
			"status": "info", "how": "link", "flash": "windows", "source": "index", "download_page": "https://www.msi.com/Handheld/Claw-8-EX-AI-plus/support"},
		{"id": "driver:inputplumber", "section": "drivers", "kind": "inputplumber", "name": "InputPlumber (controller)", "current": "0.83.1",
			"latest": "", "status": "info", "how": "auto", "source": "os"},
		{"id": "driver:kernel", "section": "drivers", "kind": "kernel", "name": "Linux kernel", "current": "7.2.15", "latest": "",
			"status": "info", "how": "auto", "source": "os"},
	]
	for k in ["controller", "storage", "updates"]:
		F[k].name = "Showcase_" + k
		root.add_child(F[k])
		svc[k] = F[k]
	var setup = S.FakeSetup.new()
	setup.done = {"welcome": true, "theme": true, "stores": true, "device_fixes": true, "steamgriddb": true, "done": true}
	setup.status["epic"] = {"signed_in": true, "account": "player", "how": "code"}
	setup.status["gog"] = {"signed_in": true, "account": "player", "how": "heroic"}
	svc["setup"] = setup
	main.settings.set_services(svc)


# ------------------------------------------------------------------ Discover

func _discover(lib: Node) -> void:
	var SD = load(here.path_join("showcase_discover.gd"))
	var d: Node = SD.make("replay")
	d.name = "ShowcaseDiscover"
	root.add_child(d)
	var art: Node = load("res://scripts/discover/art.gd").new()
	art.name = "ShowcaseArt"
	root.add_child(art)
	art.http = load(here.path_join("snapshot_http.gd")).new("live", ProjectSettings.globalize_path(here.path_join("cache/discover_http")))
	art.cache_dir = ProjectSettings.globalize_path(here.path_join("cache/discover_art"))
	var clock: Callable = d.clock
	art.clock = clock
	# The real Discover tells /root/Art each Steam game's own art files (newer
	# games have hashed file names); this Art isn't at /root/Art, so tell it here.
	for appid in d._cache["steam"]:
		var a: Variant = d._cache["steam"][appid].get("art")
		if a is Dictionary:
			art.remember("steam:" + str(appid), a)
	var svc := {"library": lib, "open_game": main._open_page, "toast": main.toast, "discover": d, "art": art, "prefs_path": "", "clock": clock}
	main.discover.setup(svc)
	main.show_screen("discover")
	var r = main.discover.content
	await frames(6)
	await shot("discover")
	if want(["discover_deals"]):
		r.show_section("deals")
		await frames(4)
		r.sections["deals"].rows[0].grab_focus()
		await shot("discover_deals")
	if want(["discover_calendar", "discover_calendar_month"]):
		r.show_section("calendar")
		var cal = r.sections["calendar"]
		cal.set_layout("list")
		await frames(4)
		if cal.rows.size() > 3 and not cal.rows[3].is_empty():
			cal.rows[3][0].grab_focus()
		await shot("discover_calendar")
		if want(["discover_calendar_month"]):
			cal.set_layout("month")
			await frames(4)
			# Today is the 9th: focus the 10th (three releases).
			if cal.day_buttons.has(10):
				cal.day_buttons[10].grab_focus()
			await shot("discover_calendar_month")
			cal.set_layout("list")
	if want(["discover_wishlist"]):
		r.show_section("wishlist")
		await frames(4)
		# Focus the game that's on sale (Frostpunk, -90%).
		var rows: Array = r.sections["wishlist"].rows
		var pick: Control = rows[0] if not rows.is_empty() else null
		for row in rows:
			var it: Variant = row.get_meta("view", null)
			if it is Dictionary and str(it.get("title", "")).to_lower() == "frostpunk":
				pick = row
				break
		if pick != null:
			await frames(6)
			pick.grab_focus()
			await frames(6)
		await shot("discover_wishlist")
	main.show_screen("home")


# ------------------------------------------------------------------ quick menu

func _quick() -> void:
	if not want(["quick_game", "quick_power", "quick_display", "quick_controller", "quick_leds"]):
		return
	var qm = main.quick_menu
	var g := _find_key("steam:1245620")
	var sess = S.FakeSession.new()
	root.add_child(sess)
	qm.attach_session(sess)
	if not qm.exit_game_requested.is_connected(_noop):
		qm.exit_game_requested.connect(_noop)
	main.show_screen("home")
	await frames(3)
	main.home.play_button.grab_focus()
	await frames(3)
	main.playing = g
	sess.started.emit(g)
	profiles.game_started(g)
	qm._session_start_ms = Time.get_ticks_msec() - 47 * 60 * 1000
	main._open_menu()
	qm.game = g
	await _open_quick(g, 0)
	var top: Array = qm.focusables()
	if not top.is_empty():
		top[0].grab_focus()
		await frames(3)
	await shot("quick_game")
	await _open_quick(g, 1, "power.tdp")
	await shot("quick_power")
	await _open_quick(g, 2, "display.brightness")
	await shot("quick_display")
	await _open_quick(g, 4, "controller.gyro")
	await shot("quick_controller")
	await _open_quick(g, 4, "controller.led_color")
	var led: Node = qm.body.find_child("controller_led_color", true, false)
	if led != null:
		led.button.grab_focus()
	await shot("quick_leds")
	qm.close()
	main.playing = {}


# ------------------------------------------------------------------ settings

func _settings() -> void:
	var st = main.settings
	if want(["settings_power"]):
		await _settings_page("power", "power.tdp")
		await shot("settings_power")
	if want(["settings_profiles"]):
		await _settings_page("profiles")
		var f: Array = st.pages["profiles"].focusables()
		if f.size() > 3:
			f[3].grab_focus()
		await shot("settings_profiles")
	for p in [["settings_about", "about"], ["settings_fixes", "fixes"], ["settings_updates", "updates"]]:
		if not want([p[0]]):
			continue
		main.show_screen("settings")
		await frames(4)
		st.open_category("device", p[1])
		await frames(14)
		await shot(p[0])
	if want(["settings_privacy"]):
		main.show_screen("settings")
		await frames(4)
		st.open_category("about")
		await frames(6)
		var card: Node = st.find_child("Card_privacy", true, false)
		if card != null:
			var n := 0
			for c in card.find_children("*", "Button", true, false):
				if c.focus_mode != Control.FOCUS_NONE and c.is_visible_in_tree():
					n += 1
					if n == 3:
						c.grab_focus()
						break
		await frames(8)
		await shot("settings_privacy")
	main.show_screen("home")
