extends "../screenshots/shoot_controls.gd"
## The showcase set: every screen with a real, lived-in profile (real games,
## their Steam art and achievements, GameCove's own gamedb data, live Discover
## prices for Canada from snapshot/), favourites and collections, an EmuDeck
## setup, pinned apps, clips, cloud saves, a week of battery history,
## Bluetooth devices, GE-Proton builds and music playing. Everything the app
## would read from the system is a fake in a temp folder: nothing real is
## installed, run or changed. Run through shoot.sh:
##   tools/showcase/shoot.sh            (every shot, both sizes, both themes)
## or directly (needs a display):
##   godot --path app --resolution 1920x1200 -s ../tools/showcase/showcase.gd -- --out DIR [--only a,b] [--suffix _x]
## SHOWCASE_THEME=light renders the light theme (default: Cove).

const SHOTS_ALL := ["home", "home_shelves", "library", "library_filter", "library_apps", "game", "game_achievements",
	"game_saves", "emulation", "library_emulation", "game_rom", "apps_view", "discover", "discover_free", "discover_deals", "discover_calendar",
	"discover_calendar_month", "discover_wishlist", "quick_game", "quick_power", "quick_display", "quick_audio",
	"quick_controller", "quick_leds", "quick_device", "quick_shortcuts", "settings_buttons", "settings_power", "settings_performance", "settings_system",
	"settings_profiles", "settings_saves", "settings_media", "media_clip_sheet", "media_share", "settings_about",
	"settings_battery", "settings_storage", "settings_fixes", "settings_updates", "settings_privacy", "setup_art"]

const Recorder := preload("res://scripts/system/recorder.gd")
const Clips := preload("res://scripts/system/clips.gd")
const Apps := preload("res://scripts/library/apps.gd")
const FakeRunner := preload("res://tests/fixtures/system/fake_runner.gd")

## The phone page's address in the Game art and Send to phone shots: a typical
## home Wi-Fi address (the render machine's own network isn't a handheld's).
const LAN_IP := "192.168.1.42"
## The game page with cloud saves: Cyberpunk 2077 from GOG.
const SAVES_KEY := "gog:1423049311"
## Favourites (Steam's own favourites would bring these in on a real device).
const FAVOURITES := ["steam:1245620", "steam:1145350", "steam:2379780", "steam:413150", "gog:1423049311",
	"steam:367520", "epic:celeste"]

var here := ""
var lib_doc: Dictionary = {}
var ach_svc: Node
var now := 0
## Temp home for everything faked from the system (clips, apps, saves, ...).
var fake_home := ""


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


## The fake Controls with the Controls worker the Audio tab's cards use (here
## the jobs run on the next idle frame, after the card is in the menu, as a
## worker's would).
class ShowcaseControls extends "res://tests/fixtures/ui_controls/fake_controls.gd":
	func run_on_worker(job: Callable) -> void:
		job.call_deferred()


## PipeWire's per-app streams while Elden Ring runs with music and a voice chat.
class Mixer extends RefCounted:
	var list := [{"id": 61, "name": "ELDEN RING", "volume": 100.0, "muted": false},
		{"id": 74, "name": "Spotify", "volume": 35.0, "muted": false},
		{"id": 88, "name": "Discord", "volume": 80.0, "muted": false}]
	func app_mixer(_ctx: Dictionary) -> Array:
		return list.duplicate(true)
	func set_stream_volume(_ctx: Dictionary, _id: int, _pct: float) -> bool:
		return true


## Storage with Clean up: shader caches of four games that aren't installed.
class ShowcaseStorage extends "res://tests/fixtures/device_ui/fakes.gd".FakeStorage:
	func leftovers() -> void:
		calls.append("leftovers")
	func clean_leftovers() -> bool:
		return false


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
	fake_home = OS.get_cache_dir().path_join("gamecove-showcase-home")
	_wipe(fake_home)
	_fake_clips()

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
	_collections(lib)
	_emulation(lib)
	_relibrary(lib)
	_seed_shots(lib)
	_status()
	await frames(4)
	await _use_device("msi-claw-8-ex", claw_patch())
	_photo()
	_fake_apps()
	_saves_and_battery()
	_media_services()
	_pads()

	# Home: Elden Ring in the spotlight.
	main.show_screen("home")
	await frames(4)
	main.home.play_button.grab_focus()
	await shot("home")
	await _library_shots()
	await _game_shots()
	lib.set("_last_emu_scan", 1 << 40)   # no rescan of this machine's ROM folders while the shots run
	if want(["emulation"]):
		main.show_screen("library")
		await frames(2)
		main.open_emulation()
		await frames(4)
		await shot("emulation")
		main._close_page()
		main.show_screen("home")
	if want(["library_emulation"]):
		main.show_screen("library")
		main.library_screen.set_view("emulation")
		await frames(4)
		for t in main.library_screen.tiles():
			if t.game.get("title", "") == "Super Metroid":
				t.grab_focus()
		await frames(4)
		await shot("library_emulation")
		main.library_screen.set_view("")
		main.show_screen("home")
	if want(["game_rom"]):
		for g in games:
			if g.get("title", "") == "Super Metroid":
				main._open_page(g)
		await frames(6)
		await shot("game_rom")
		main._close_page()
	await _apps_view()

	if want(["discover", "discover_free", "discover_deals", "discover_calendar", "discover_calendar_month", "discover_wishlist"]):
		await _discover(lib)

	_relibrary(lib)
	await _quick()
	_relibrary(lib)
	await _settings()
	await _media()
	if want(["home_shelves"]):
		main.show_screen("home")
		await frames(4)
		# Further down: Favourites, Installed, Emulation and the Apps shelf.
		var em: Array = main.home.tiles("emulation")
		for t in em:
			if t.game.get("title", "") == "Super Metroid":
				t.grab_focus()
		await frames(10)
		await shot("home_shelves")

	await _setup_art()
	_wipe(fake_home)
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
		var meta := _meta(a)
		if not meta.is_empty():
			info["meta"] = meta
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


## Game details as GameCove's own lookup builds them: the game's real Steam
## store answer (cache/appdetails/, fetched by fetch.py) read by
## Metadata.steam_layer and merged.
func _meta(appid: String) -> Dictionary:
	var p := _cache("appdetails/%s.json" % appid)
	if p == "":
		return {}
	var M = load("res://scripts/library/meta/metadata.gd")
	var l: Dictionary = M.steam_layer(appid, FileAccess.get_file_as_bytes(p))
	return M.merge([l]) if not l.is_empty() else {}


## The game page asks the Library's details resolver for each screenshot
## thumbnail; put the cached ones where it looks, so nothing is fetched mid-shot.
func _seed_shots(lib: Node) -> void:
	var res: Object = lib.get("metadata")
	if res == null:
		return
	var dir: String = res.abs_dir().path_join("shots")
	DirAccess.make_dir_recursive_absolute(dir)
	for g in games:
		var m: Variant = g["info"].get("meta")
		if not m is Dictionary:
			continue
		var appid := str(g["key"]).get_slice(":", 1) if g["store"] == "steam" else ""
		for x in lib_doc["games"]:
			if "%s:%s" % [x["store"], x["id"]] == g["key"]:
				appid = x["steam_appid"]
		for s in m.get("screenshots", []):
			var url := str(s.get("thumb", ""))
			var name := url.get_file().get_slice("?", 0)
			var re := RegEx.create_from_string("[^A-Za-z0-9_.-]")
			name = re.sub(name, "_", true)
			var src := _cache("shots/%s/%s" % [appid, name])
			if src != "":
				DirAccess.copy_absolute(src, dir.path_join(url.sha1_text().substr(0, 24) + ".jpg"))


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


## Favourites and two collections of this player's own, on a temp file.
func _collections(lib: Node) -> void:
	var cols: RefCounted = lib.collections
	cols.path = fake_home.path_join("collections.json")
	cols.reload()
	for k in FAVOURITES:
		cols.set_favourite(k, true)
	var couch: String = cols.create("Couch co-op")
	for k in ["steam:553850", "steam:413150", "steam:1551360"]:
		cols.add(couch, k)
	var next: String = cols.create("Up next")
	for k in ["steam:1030300", "steam:1903340", "steam:2246340"]:
		cols.add(next, k)


## An EmuDeck setup: ES-DE, ROMs for seven systems, recently played ones, and
## four Steam ROM Manager shortcuts with their box art (fetch.py's cache/emu/).
func _emulation(lib: Node) -> void:
	# EmuDeck's usual place, ~/Emulation (only shown, never read).
	var home := OS.get_environment("HOME")
	var roms := home.path_join("Emulation/roms")
	lib.emulation = {"kind": "emudeck", "name": "EmuDeck",
		"frontend": {"name": "ES-DE", "command": ["/home/deck/Applications/ES-DE.AppImage"]},
		"app": {"name": "EmuDeck", "command": ["/home/deck/Applications/EmuDeck.AppImage"]},
		"srm": {"command": ["/home/deck/Applications/srm/Steam-ROM-Manager.AppImage"]},
		"roms_dir": roms, "esde_dir": home.path_join("ES-DE"), "rom_total": 0, "roms_shown": true,
		"roots": [{"path": roms, "real": roms, "online": true, "from": "EmuDeck"}],
		# Filled in below from the ROM games themselves (the page's counts are the Library's games).
		"systems": [],
		"recent": [{"title": "Super Metroid", "system": "SNES", "last_played": now - 86400 * 10},
			{"title": "Pokémon Emerald", "system": "GBA", "last_played": now - 86400 * 13},
			{"title": "Castlevania: Symphony of the Night", "system": "PS1", "last_played": now - 86400 * 19},
			{"title": "Sonic the Hedgehog 2", "system": "Genesis", "last_played": now - 86400 * 26}]}
	var none := {"cover": "", "hero": "", "logo": "", "icon": ""}
	games.append({"key": "emu:frontend", "store": "emu", "id": "frontend", "title": "ES-DE", "installed": true,
		"art": none.duplicate(), "info": {"released": null, "time_to_beat": null, "anticheat": null, "protondb": null},
		"last_played": now - 86400 * 10, "playtime_min": 1840, "command": lib.emulation["frontend"]["command"], "frontend": true,
		"emulated": {"system": "", "system_name": "", "system_short": "", "emulator": "", "via": "emudeck"}})
	# [title, system, system name, short, core, art name, days since played, minutes, ROM file, genres, developer, released, players, rating]
	var specs := [["Super Metroid", "snes", "Nintendo SNES (Super Nintendo)", "SNES", "Snes9x - Current", "super-metroid", 10, 612,
			"Super Metroid (Japan, USA) (En,Ja).sfc", ["Action", "Platform"], "Nintendo R&D1", "1994-03-19", "1", 0.95],
		["Pokémon Emerald", "gba", "Nintendo Game Boy Advance", "GBA", "mGBA", "pokemon-emerald", 13, 1490,
			"Pokemon - Emerald Version (USA, Europe).gba", ["Role-playing"], "Game Freak", "2004-09-16", "1-4", 0.9],
		["Castlevania: Symphony of the Night", "psx", "Sony PlayStation", "PS1", "SwanStation", "castlevania-sotn", 19, 538,
			"Castlevania - Symphony of the Night (USA).chd", ["Action", "Platform"], "Konami", "1997-03-20", "1", 0.95],
		["Sonic the Hedgehog 2", "genesis", "Sega Genesis", "Genesis", "Genesis Plus GX", "sonic-2", 26, 205,
			"Sonic The Hedgehog 2 (World) (Rev A).md", ["Platform"], "Sonic Team", "1992-11-21", "1-2", 0.85]]
	var i := 0
	for s in specs:
		i += 1
		var art := none.duplicate()
		# SHOWCASE_ROM_ART=0: ROMs ES-DE has no art for (a fresh install): console
		# covers on the tiles and the console pattern behind the Emulation page.
		if OS.get_environment("SHOWCASE_ROM_ART") != "0":
			art["cover"] = _cache("emu/%s-cover.png" % s[5])
			art["hero"] = _cache("emu/%s-snap.png" % s[5])
		# Every ROM is a game of its own (scripts/library/stores/roms.gd): ES-DE's details, its art, our play time.
		var id := "rom:%s/%s" % [s[1], s[8]]
		var summary := "From your %s ROM folder. It runs in RetroArch (%s) through EmuDeck." % [s[3], s[4]]
		var M = load("res://scripts/library/meta/metadata.gd")
		var meta: Dictionary = M.merge([M.layer("esde", {"summary": summary, "genres": s[9], "developers": [s[10]], "release_date": s[11]})])
		games.append({"key": "emu:" + id, "store": "emu", "id": id, "title": s[0], "installed": true,
			"art": art, "info": {"released": int(str(s[11]).substr(0, 4)), "time_to_beat": null, "anticheat": null, "protondb": null,
			"summary": summary, "meta": meta},
			"last_played": now - 86400 * int(s[6]), "playtime_min": int(s[7]), "shortcut": false,
			"emulated": {"system": s[1], "system_name": s[2], "system_short": s[3], "emulator": "RetroArch (%s)" % s[4], "via": "emudeck",
				"rom": true, "players": s[12], "rating": float(s[13]), "playcount": 0, "root": roms}})

	var by := {}
	for g in games:
		var e: Variant = g.get("emulated")
		if e is Dictionary and e.get("rom", false):
			if not by.has(e["system"]):
				by[e["system"]] = {"id": e["system"], "name": e["system_name"], "short": e["system_short"], "count": 0, "roots": [roms], "known": true}
			by[e["system"]]["count"] += 1
	lib.emulation["systems"] = by.values()
	lib.emulation["rom_total"] = games.filter(func(g): return g.get("emulated", {}).get("rom", false)).size()


func _status() -> void:
	main.top_bar.set_status("MSI Claw 8 EX AI+", {"percent": 72, "status": "Discharging", "watts": 9.4}, "8:42 PM", {"connected": true, "strength": 0.8})
	main.top_bar.set_telemetry({"tdp_w": 17.0, "profile": "balanced", "temp_c": 58.0})
	main.home.set_battery_left("~2 h 45 min")
	main.hint_status.text = "● GameCove %s   MSI Claw 8 EX AI+" % _short_version()
	# About GameCove's Version line, as a release build has it (the spec's Version).
	main.settings.version = _short_version()
	main.achievements_api = ach_svc
	main.home.set_achievements(ach_svc)
	main.status_panel.set_battery("MSI Claw 8 EX AI+", {"percent": 72, "status": "Discharging", "watts": 9.4, "time_left_min": 165})


## The render machine has no UPower: a DualSense at 62 % (after main's own read).
func _pads() -> void:
	main.top_bar.set_pads([{"name": "DualSense Wireless Controller", "percent": 62, "charging": false}])


func _photo() -> void:
	var dp := seed_device_photo(root, fake_home.path_join("device_photos"), _cache("device/msi-claw-8-ex.png"))
	if dp == null:
		return
	var svc: Dictionary = main.settings.services.duplicate()
	svc["photo"] = dp
	main.settings.set_services(svc)


## GameCove's own DevicePhoto service with the Claw 8 EX's maker image already
## in its cache, exactly where and as it keeps a successful download
## (maker-<url hash>.png, fresh, so nothing is fetched): every screen that shows
## the device then shows it as on the handheld, credit line included. The
## picture is the one app/data/device_photos.json links to (fetch.py downloads
## it into cache/device/; it's never bundled). Null without it.
static func seed_device_photo(tree_root: Node, cache_dir: String, src: String) -> Node:
	var dp: Node = tree_root.get_node_or_null("DevicePhoto")
	if dp == null or src == "" or not FileAccess.file_exists(src):
		return null
	dp.cache_dir = cache_dir
	dp.enabled = true
	dp.maker_enabled = true
	var m: Dictionary = dp.maker_entry("msi-claw-8-ex")
	if m.is_empty():
		return null
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(cache_dir))
	DirAccess.copy_absolute(src, dp._maker_base(str(m["url"])) + ".png")
	return dp


func _make_controls() -> Node:
	return ShowcaseControls.new()


## Profiles: this player's own per-game layers (games from the library).
func _use_device(id: String, patch: Dictionary) -> void:
	await super(id, patch)
	_extra_controls()
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


## Button shortcuts (the device snapshot predates them): the real controller
## provider on the Claw's fake InputPlumber, its shortcut controls copied into
## the fake Controls with a lived-in setup.
func _button_controls() -> void:
	var CtlTest = load("res://tests/test_controls_controller.gd")
	var CFakes = load("res://tests/fixtures/controller/fakes.gd")
	var FC = load("res://tests/fixtures/ui_controls/fake_controls.gd")
	var h: RefCounted = CtlTest.new()
	var dir := fake_home.path_join("button_shortcuts")
	DirAccess.make_dir_recursive_absolute(dir.path_join("home"))
	var f: RefCounted = CFakes.new(dir)
	f.with_ip("MSI Claw 8 EX", CtlTest.CLAW_CAPS)
	var reg: Node = h._setup(f, h._row("msi-claw-8-ex"))
	for w in [["controller.paddle.LeftPaddle1", "action:screenshot"], ["controller.paddle.RightPaddle1", "KeyLeftAlt+KeyEnter"]]:
		var c: RefCounted = reg.control(w[0])
		if c != null:
			c.write(w[1])
	reg.detect_all()
	for c in reg.list("controller"):
		var d: Dictionary = c.describe()
		var id := str(d.get("id", ""))
		for pre in ["controller.paddle.", "controller.button.", "controller.hold", "controller.to_steam.", "controller.reset_shortcuts"]:
			if id.begins_with(pre):
				fake.add(FC.from_describe(d))
				break
	reg.free()


## What the device snapshot predates: Sleep at low battery (on, at 5 %), the
## music playing (MPRIS) and each app's volume (PipeWire), all fakes.
func _extra_controls() -> void:
	var PT = load("res://scripts/controls/power/texts.gd")
	var low: Array = PT.T["power.low_battery_sleep"]
	var at: Array = PT.T["power.low_battery_sleep_at"]
	fake.add({"id": "power.low_battery_sleep", "title": low[0], "help": low[1], "kind": "toggle", "per_game": false,
		"default_value": false, "value": true})
	fake.add({"id": "power.low_battery_sleep_at", "title": at[0], "help": at[1], "kind": "slider", "unit": "%",
		"min_value": 3.0, "max_value": 10.0, "step": 1.0, "per_game": false, "default_value": 5.0, "value": 5})
	# Battery saver turns itself on at 20 % on this handheld.
	var saver: RefCounted = fake.control("power.battery_saver_at")
	if saver != null:
		saver.get_meta("fake_state")["value"] = 20
		saver.read()
	fake.ctx["runner"] = _media_runner()
	var vol: RefCounted = fake.control("audio.volume")
	if vol != null:
		vol.set_meta("provider", Mixer.new())


## Spotify playing over the game (busctl answers as test_extras_media.gd's).
func _media_runner() -> RefCounted:
	var f: RefCounted = FakeRunner.new()
	var spot := "org.mpris.MediaPlayer2.spotify"
	var prop := func(iface: String, name: String) -> String:
		return "busctl --user get-property %s /org/mpris/MediaPlayer2 %s %s" % [spot, iface, name]
	var p := "org.mpris.MediaPlayer2.Player"
	f.responses["busctl --user call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ListNames"] = {"code": 0,
		"out": JSON.stringify({"type": "as", "data": [["org.freedesktop.DBus", ":1.12", spot]]})}
	f.responses[prop.call(p, "PlaybackStatus")] = {"code": 0, "out": JSON.stringify({"type": "s", "data": "Playing"})}
	f.responses[prop.call(p, "Metadata")] = {"code": 0, "out": JSON.stringify({"type": "a{sv}", "data": {
		"xesam:title": {"type": "s", "data": "Midnight City"}, "xesam:album": {"type": "s", "data": "Hurry Up, We're Dreaming"},
		"xesam:artist": {"type": "as", "data": ["M83"]}}})}
	f.responses[prop.call("org.mpris.MediaPlayer2", "Identity")] = {"code": 0, "out": JSON.stringify({"type": "s", "data": "Spotify"})}
	f.responses[prop.call(p, "CanGoNext")] = {"code": 0, "out": JSON.stringify({"type": "b", "data": true})}
	f.responses[prop.call(p, "CanGoPrevious")] = {"code": 0, "out": JSON.stringify({"type": "b", "data": true})}
	return f


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
	info["software"]["gamecove_version"] = release_version()
	var svc: Dictionary = main.settings.services.duplicate()
	var F = DeviceFakes.services()
	F["device"].free()
	F["storage"].free()
	var st := ShowcaseStorage.new()
	st.st = DeviceFakes.storage_state()
	# Shader caches left by four games that were uninstalled.
	st.st["cleanup"] = {"ready": true, "cleaning": false, "missing": [], "bytes": 3_870_000_000,
		"dirs": ["shadercache/1174180", "shadercache/1817070", "shadercache/2344520", "shadercache/814380"]}
	F["storage"] = st
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
	svc["bluetooth_runner"] = _bluetooth_runner()
	var ph := _proton_home()
	svc["proton_runner"] = ph[1]
	svc["proton_home"] = ph[0]
	main.settings.set_services(svc)


## BlueZ with the DualSense connected (62 %), paired earbuds and a speaker
## nearby (test_extras_bluetooth.gd's fake bus).
func _bluetooth_runner() -> RefCounted:
	var BT = load("res://tests/test_extras_bluetooth.gd")
	var bz: RefCounted = BT.Bluez.new()
	var pad: Dictionary = bz.tree[BT.PAD]
	pad["org.bluez.Device1"]["Name"] = {"type": "s", "data": "DualSense Wireless Controller"}
	pad["org.bluez.Device1"]["Alias"] = {"type": "s", "data": "DualSense Wireless Controller"}
	pad["org.bluez.Battery1"]["Percentage"] = {"type": "y", "data": 62}
	var buds: Dictionary = bz.tree[BT.BUDS]["org.bluez.Device1"]
	buds["Name"] = {"type": "s", "data": "Galaxy Buds2 Pro"}
	var f: RefCounted = FakeRunner.new()
	f.handler = bz.answer
	f.set_meta("bluez", bz)
	return f


## Steam's compatibility tools with GE-Proton10-25 (Cyberpunk 2077 set to it)
## and GE-Proton9-20 installed; GitHub's newest release is GE-Proton10-26.
## [home, runner]
func _proton_home() -> Array:
	var PT = load("res://tests/test_extras_proton.gd")
	var home := fake_home.path_join("proton")
	var steam := home.path_join(".local/share/Steam")
	for t in ["GE-Proton10-25", "GE-Proton9-20"]:
		_write(steam.path_join("compatibilitytools.d").path_join(t).path_join("compatibilitytool.vdf"), PT._tool_vdf(t))
	_write(steam.path_join("config/config.vdf"), "\"InstallConfigStore\"\n{\n \"Software\"\n {\n  \"Valve\"\n  {\n   \"Steam\"\n   {\n    \"CompatToolMapping\"\n    {\n     \"1091500\"\n     {\n      \"name\" \"GE-Proton10-25\"\n      \"config\" \"\"\n      \"priority\" \"250\"\n     }\n    }\n   }\n  }\n }\n}\n")
	var ProtonGE = load("res://scripts/launch/proton_ge.gd")
	var release: String = PT.release_json("GE-Proton10-26")
	var f: RefCounted = FakeRunner.new()
	f.handler = func(full: String) -> Variant:
		var cmd := full.trim_prefix("nice -n 19 ionice -c 3 ").trim_prefix("nice -n 19 ")
		if cmd.begins_with("curl ") and cmd.ends_with(ProtonGE.API):
			return {"code": 0, "out": release}
		return null
	return [home, f]


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(d))
	DirAccess.remove_absolute(dir)


# ------------------------------------------------------- saves and battery

## Cloud saves in sync for Cyberpunk 2077 (GOG) and Celeste (Epic), and a week
## of battery history on an 80 Wh battery (games, sleep, the charger).
func _saves_and_battery() -> void:
	var tmp := fake_home.path_join("saves")
	DirAccess.make_dir_recursive_absolute(tmp)
	var bat := tmp + "/sys/class/power_supply/BAT0/"
	for f in [["type", "Battery"], ["capacity", "72"], ["energy_now", "53700000"], ["energy_full", "74600000"]]:
		_write(bat + f[0], f[1] + "\n")
	var sv: Node = main.saves
	sv.cfg_path = tmp + "/saves.cfg"
	sv.backup_dir = tmp + "/backups"
	sv.backups.base_dir = sv.backup_dir
	var cfg := ConfigFile.new()
	for k in [[SAVES_KEY, 47 * 60 + 300], ["epic:celeste", 60 * 86400]]:
		cfg.set_value("game:" + k[0], "state", "synced")
		cfg.set_value("game:" + k[0], "at", now - int(k[1]))
		cfg.set_value("game:" + k[0], "last_sync", now - int(k[1]))
	cfg.save(sv.cfg_path)
	# Copies GameCove took before cloud downloads (the last three syncs that brought saves down).
	var bdir: String = sv.backups.dir_for(SAVES_KEY)
	for b in [[53 * 60 + 40, 18_400_000], [2 * 86400 + 5200, 18_100_000], [6 * 86400 + 900, 17_600_000]]:
		var when := now - int(b[0])
		var stamp := Time.get_datetime_string_from_unix_time(when).replace("-", "").replace(":", "").replace("T", "-")
		_write(bdir.path_join(stamp + ".json"), JSON.stringify({"time": when, "reason": "before_download", "title": "Cyberpunk 2077",
			"parts": [{"name": "saves", "path": "", "file": stamp + "-0.tar.gz", "bytes": int(b[1])}], "fingerprint": stamp}, "\t"))
	var bl: Node = main.battery_log
	bl.path = tmp + "/battery.json"
	bl.sys_root = tmp
	var plan := [["steam:1245620", "ELDEN RING", 34], [SAVES_KEY, "Cyberpunk 2077", 41], ["steam:2379780", "Balatro", 12],
		["steam:1086940", "Baldur's Gate 3", 37], ["steam:1145350", "Hades II", 22], ["steam:1245620", "ELDEN RING", 30],
		["steam:413150", "Stardew Valley", 14]]
	bl.data = {"v": 1, "open": {}, "samples": [], "games": {
		"steam:1245620": {"title": "ELDEN RING", "wh": 62.4, "s": 15600, "n": 4},
		SAVES_KEY: {"title": "Cyberpunk 2077", "wh": 49.8, "s": 9900, "n": 3},
		"steam:1086940": {"title": "Baldur's Gate 3", "wh": 41.2, "s": 8700, "n": 2},
		"steam:2379780": {"title": "Balatro", "wh": 9.6, "s": 6300, "n": 3},
		"steam:1145350": {"title": "Hades II", "wh": 18.1, "s": 5400, "n": 2}}}
	var full := 74.6 / 100.0
	var t := now - 7 * 86400 + 18 * 3600
	for day in plan.size():
		var pct := 100
		var s: Array = bl.data["samples"]
		s.append([t, pct, pct * full, "unplug", ""])
		s.append([t + 900, pct - 1, (pct - 1) * full, "start", day_key(plan[day])])
		pct -= int(plan[day][2]) + 1
		s.append([t + 900 + int(plan[day][2]) * 190, pct, pct * full, "end", day_key(plan[day])])
		s.append([t + 9000, pct - 2, (pct - 2) * full, "suspend", ""])
		s.append([t + 46000, pct - 4, (pct - 4) * full, "resume", ""])
		pct -= 4
		if day < plan.size() - 1:
			s.append([t + 47000, pct, pct * full, "plug", ""])
			s.append([t + 52000, 100, 100 * full, "suspend", ""])
		t += 86400


static func day_key(p: Array) -> String:
	return str(p[0])


# ------------------------------------------------------- clips and apps

static func _u32(n: int) -> PackedByteArray:
	var b := PackedByteArray([0, 0, 0, 0])
	b.encode_u32(0, n)
	b.reverse()
	return b


static func _box(kind: String, body: PackedByteArray) -> PackedByteArray:
	var out := _u32(body.size() + 8)
	out.append_array(kind.to_ascii_buffer())
	out.append_array(body)
	return out


## A small MP4 whose header says `seconds` (what the Clips list reads) and
## whose size is `mb` (sparse padding).
static func _mp4(path: String, seconds: int, mb: int) -> void:
	var mvhd := PackedByteArray([0, 0, 0, 0])
	for v in [0, 0, 1000, seconds * 1000]:
		mvhd.append_array(_u32(v))
	var pad := PackedByteArray()
	pad.resize(80)
	mvhd.append_array(pad)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(_box("ftyp", "isom\u0000\u0000\u0002\u0000".to_ascii_buffer()))
	var size := mb * 1_000_000
	f.store_buffer(_u32(size + 8))
	f.store_buffer("mdat".to_ascii_buffer())
	f.seek(f.get_position() + size)
	f.store_buffer(_box("moov", _box("mvhd", mvhd)))
	f.close()


## Clips from the showcase library's games, each with its hero art as the
## picture, and a recorder that's set up (in a temp root).
func _fake_clips() -> void:
	var root_dir := fake_home.path_join("root")
	DirAccess.make_dir_recursive_absolute(root_dir + Recorder.SYSTEM_APP_DIR)
	DirAccess.make_dir_recursive_absolute(root_dir + "/usr/bin")
	FileAccess.open(root_dir + "/usr/bin/flatpak", FileAccess.WRITE).close()
	var clips := [["1245620", "ELDEN RING", 94, 71, 0], ["1145350", "Hades II", 42, 33, 49], ["1086940", "Baldur's Gate 3", 185, 140, 74],
		["1091500", "Cyberpunk 2077", 61, 47, 146], ["2379780", "Balatro", 28, 12, 170]]
	# Times to go with the top bar's clock (8:42 PM today): the newest clip is 8:15 PM.
	var d := Time.get_datetime_dict_from_system()
	var shown := Time.get_unix_time_from_datetime_dict({"year": d["year"], "month": d["month"], "day": d["day"], "hour": 20, "minute": 15, "second": 0})
	for c in clips:
		var at: int = shown - int(c[4]) * 3600
		var when := Time.get_datetime_dict_from_unix_time(at)
		var p := Recorder.clip_path(fake_home, str(c[1]), when)
		_mp4(p, int(c[2]), int(c[3]))
		OS.execute("touch", ["-d", "@%d" % (at - int(Time.get_time_zone_from_system()["bias"]) * 60), p])
		var hero := here.path_join("cache").path_join(str(c[0])).path_join("hero.jpg")
		if FileAccess.file_exists(hero):
			Clips.save_thumb(p, Image.load_from_file(hero))


func _media_services() -> void:
	var f: RefCounted = FakeRunner.new()
	f.responses[Recorder.KMS_PROXY + " is-setup " + fake_home] = {"code": 0, "out": ""}
	f.responses["/usr/bin/flatpak list --app --columns=application"] = {"code": 0, "out": Clips.MPV_FLATPAK + "\n"}
	var svc: Dictionary = main.settings.services
	svc["media_runner"] = f
	svc["media_env"] = {"home": fake_home, "path_env": "/usr/bin", "sys_root": fake_home.path_join("root")}
	svc["drop_bind"] = "127.0.0.1"
	main.recording.env = {"home": fake_home, "path_env": "/usr/bin", "sys_root": fake_home.path_join("root"), "proc_root": fake_home}


## Simple original icons (no brand marks) for a handful of everyday apps.
func _fake_apps() -> void:
	var specs := [
		["org.mozilla.firefox", "Firefox", "#FF7139", "<circle cx='32' cy='32' r='20' fill='none' stroke='white' stroke-width='5'/><path d='M12 32h40M32 12c-8 8-8 32 0 40M32 12c8 8 8 32 0 40' stroke='white' stroke-width='4' fill='none'/>"],
		["com.discordapp.Discord", "Discord", "#5865F2", "<path d='M14 20h36v20H30l-10 8v-8h-6z' fill='white'/>"],
		["io.mpv.Mpv", "mpv", "#6A1B9A", "<path d='M24 18v28l22-14z' fill='white'/>"],
		["com.spotify.Client", "Spotify", "#1DB954", "<path d='M18 26c10-4 20-3 28 2M20 33c8-3 16-2 22 2M22 40c6-2 12-1 16 2' stroke='white' stroke-width='4' fill='none' stroke-linecap='round'/>"],
		["org.libretro.RetroArch", "RetroArch", "#4A4A4A", "<rect x='14' y='22' width='36' height='20' rx='10' fill='white'/><circle cx='24' cy='32' r='3' fill='#4A4A4A'/><circle cx='40' cy='32' r='3' fill='#4A4A4A'/>"],
		["org.videolan.VLC", "VLC media player", "#FF8800", "<path d='M32 12l14 36H18z' fill='white'/>"],
		["com.obsproject.Studio", "OBS Studio", "#302E31", "<circle cx='32' cy='32' r='18' fill='white'/><circle cx='32' cy='32' r='7' fill='#302E31'/>"],
		["net.davidotek.pupgui2", "ProtonUp-Qt", "#C2185B", "<path d='M32 14v26M22 30l10 10 10-10M18 48h28' stroke='white' stroke-width='5' fill='none'/>"],
		["org.kde.dolphin", "Dolphin", "#1D99F3", "<path d='M14 22h14l4 4h18v20H14z' fill='white'/>"],
		["com.heroicgameslauncher.hgl", "Heroic Games Launcher", "#0E1A2B", "<path d='M32 12l18 8v12c0 10-8 18-18 20-10-2-18-10-18-20V20z' fill='white'/>"],
		["org.chromium.Chromium", "Chromium", "#4285F4", "<circle cx='32' cy='32' r='20' fill='white'/><circle cx='32' cy='32' r='8' fill='#4285F4'/>"],
		["md.obsidian.Obsidian", "Obsidian", "#7C3AED", "<path d='M32 12l16 14-6 26H22l-6-26z' fill='white'/>"],
	]
	var list: Array = []
	var dir := fake_home.path_join("icons")
	DirAccess.make_dir_recursive_absolute(dir)
	for s in specs:
		var svg := "<svg xmlns='http://www.w3.org/2000/svg' width='64' height='64'><rect width='64' height='64' rx='14' fill='%s'/>%s</svg>" % [s[2], s[3]]
		var img := Image.new()
		img.load_svg_from_buffer(svg.to_utf8_buffer(), 4.0)
		var p := dir.path_join(str(s[0]) + ".png")
		img.save_png(p)
		list.append({"key": "app:" + str(s[0]), "id": s[0], "store": "app", "title": s[1], "exec": ["/usr/bin/flatpak", "run", s[0]],
			"icon": p, "flatpak": s[0], "installed": true, "art": {"icon": p}})
	var pins := fake_home.path_join("apps.json")
	for i in [1, 3, 0, 2]:
		Apps.set_pinned(list[i], true, pins)
	main.home.set_apps(Apps.pinned(pins))
	main.set_meta("fake_apps", list)
	main.set_meta("fake_pins", pins)


# ------------------------------------------------------------------ library and game

func _library_shots() -> void:
	if not want(["library", "library_filter", "library_apps"]):
		return
	main.show_screen("library")
	await frames(4)
	for t in main.library_screen.tiles():
		if t.game["key"] == "steam:1086940":
			t.grab_focus()
	await shot("library")
	if want(["library_filter"]):
		main.open_library_filter()
		await shot("library_filter")
		main.game_actions.sheet.close()
		await frames(4)
	if want(["library_apps"]):
		main.library_screen.apps_button.grab_focus()
		await frames(6)
		await shot("library_apps")
	main.show_screen("home")
	await frames(3)


func _game_shots() -> void:
	if want(["game", "game_achievements"]):
		main._open_page(_find_key("steam:1245620"))
		await frames(6)
		await shot("game")
		if want(["game_achievements"]) and main.page.ach_card != null and main.page.ach_card.cells.size() > 2:
			main.page.ach_card.cells[1].grab_focus()
			await frames(10)
			await shot("game_achievements")
		main._close_page()
	if want(["game_saves"]):
		# Cyberpunk 2077 (GOG): a favourite, saves in sync, what it drains.
		main._open_page(_find_key(SAVES_KEY))
		await frames(20)
		var card: Control = main.page.saves_card
		if card != null:
			card.toggle_button.grab_focus()
		await frames(10)
		# Down to the About card's last lines (what the game drains on battery),
		# as far as the saves card stays in view.
		var drain: Control = main.page.drain_label
		if drain != null and card != null:
			var n: Node = drain
			while n != null and not n is ScrollContainer:
				n = n.get_parent()
			var sc := n as ScrollContainer
			if sc != null:
				var bottom := sc.global_position.y + sc.size.y - 110.0
				var need := drain.get_global_rect().end.y - bottom
				var room := card.get_global_rect().position.y - sc.global_position.y - 70.0
				sc.scroll_vertical += int(maxf(0.0, minf(need, room)))
			await frames(10)
		await shot("game_saves")
		main._close_page()
	await frames(3)


func _apps_view() -> void:
	if not want(["apps_view"]):
		return
	main.open_apps()
	main.apps_view.pins_path = main.get_meta("fake_pins")
	var list: Array = main.get_meta("fake_apps")
	main.apps_view.scan_fn = func() -> Array: return list
	main.apps_view.loading = false
	main.apps_view.open()
	for i in 120:
		if not main.apps_view.loading:
			break
		await process_frame
	await frames(6)
	if main.apps_view.tiles.size() > 5:
		main.apps_view.tiles[5].grab_focus()
	await frames(8)
	main._update_hints()
	await frames(2)
	await shot("apps_view")
	main.close_apps()
	await frames(4)


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
	if want(["discover_free"]):
		# Free to keep (CheapShark's giveaways, recorded with the rest).
		var home_view: Node = main.discover.find_child("Home", true, false)
		if home_view != null:
			for s in home_view.shelves:
				if s.id == "free" and not s.tiles.is_empty():
					s.tiles[0].grab_focus()
		await frames(14)
		await shot("discover_free")
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

class ShowSession extends RefCounted:
	var game: Dictionary
	var app_id := 0
	var pid := 0

	func _init(g: Dictionary) -> void:
		game = g

	func is_active() -> bool:
		return true


class ShowController extends RefCounted:
	func state() -> Dictionary:
		return {"backend": "inputplumber"}


func _quick() -> void:
	if not want(["quick_game", "quick_power", "quick_display", "quick_audio", "quick_controller", "quick_leds", "quick_device", "quick_shortcuts"]):
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
	# Recording the boss fight for 1:23 (the REC chip in the top bar).
	var rec = main.recording
	rec.state = "recording"
	rec._started_ms = Time.get_ticks_msec() - 83 * 1000
	main.top_bar.set_recording(true)
	# The Shortcuts strip as it is over a running game on InputPlumber.
	main.actions.session = ShowSession.new(g)
	main.actions.controls = fake
	for cid in ["system.screenshot", "system.sleep", "audio.mute", "controller.desktop_mode"]:
		if not fake.has(cid):
			fake.add({"id": cid, "kind": "toggle" if cid in ["audio.mute", "controller.desktop_mode"] else "action", "value": cid == "audio.mute"})
		fake.set_available(cid, true)
	main.actions.controller = ShowController.new()
	main.actions.game_front = func() -> bool: return true
	main.actions.steam_bin = "/usr/bin/steam"
	main._open_menu()
	qm.game = g
	await _open_quick(g, 0)
	var row: Node = qm.body.find_child("Record", true, false)
	if row != null:
		row.button.grab_focus()
	await frames(6)
	_pads()
	await shot("quick_game")
	await _open_quick(g, 1, "power.tdp")
	await shot("quick_power")
	await _open_quick(g, 2, "display.brightness")
	await shot("quick_display")
	await _open_quick(g, 3, "audio.volume")
	await frames(6)
	# Down to Now playing and each app's own volume.
	var mx: Node = qm.body.find_child("AppMixer", true, false)
	if mx != null and not mx.focusables().is_empty():
		mx.focusables()[0].grab_focus()
	await frames(10)
	await shot("quick_audio")
	await _open_quick(g, 4, "controller.gyro")
	await shot("quick_controller")
	await _open_quick(g, 4, "controller.led_color")
	var led: Node = qm.body.find_child("controller_led_color", true, false)
	if led != null:
		led.button.grab_focus()
	await shot("quick_leds")
	await _open_quick(g, 5)
	await shot("quick_device")
	# The strip itself: focus on Screenshot, sound muted.
	await _open_quick(g, 0)
	if qm.strip != null and qm.strip.buttons.has("screenshot"):
		qm.strip.buttons["screenshot"].grab_focus()
	await frames(8)
	await shot("quick_shortcuts")
	qm.close()
	main.actions.session = main.session
	main.actions.controller = root.get_node_or_null("Controller")
	main.actions.controls = root.get_node_or_null("Controls")
	rec.state = "idle"
	main.top_bar.set_recording(false)
	main.playing = {}
	# The game ends here: its own values go back to the everyday ones, so the
	# Settings shots show those (17 W, as the top bar says), not Elden Ring's 20 W.
	profiles.game_ended(g)
	await frames(3)


# ------------------------------------------------------------------ settings

## Focuses `row`, lets the page glide to it, then scrolls so the card around
## it starts near the top (or, for a card taller than the page, the row sits
## a third of the way down).
func _focus_row(row: Control) -> void:
	if row == null:
		return
	var b: Control = row.get("button") if row.get("button") is Control else row
	b.grab_focus()
	await frames(24)
	var n: Node = row
	while n != null and not n is ScrollContainer:
		n = n.get_parent()
	var sc := n as ScrollContainer
	if sc == null:
		return
	var card: Control = null
	var p: Node = row.get_parent()
	while p != null and p != sc:
		if p is PanelContainer:
			card = p
			break
		p = p.get_parent()
	var top := sc.global_position.y
	if card != null and card.size.y <= sc.size.y - 24:
		sc.scroll_vertical += int(card.global_position.y - top - 12)
	else:
		sc.scroll_vertical += int(row.global_position.y - top - sc.size.y / 3.0)
	await frames(12)


func _settings() -> void:
	var st = main.settings
	var svc: Dictionary = main.settings.services.duplicate()
	svc["saves"] = main.saves
	svc["battery"] = main.battery_log
	main.settings.set_services(svc)
	if want(["settings_power"]):
		# The battery card: Sleep at low battery (on, at 5 %).
		await _settings_page("power")
		await _focus_row(st.pages["power"].find_child("power_low_battery_sleep", true, false))
		await shot("settings_power")
	if want(["settings_performance"]):
		await _settings_page("performance")
		var pp = st.pages["performance"]
		for i in 60:
			if pp.get("proton_card") != null and pp.proton_card.busy == "":
				break
			await process_frame
		# What GitHub says is newest (the fake answers GE-Proton10-26).
		if pp.get("proton_card") != null:
			pp.proton_card.check()
			for i in 120:
				if pp.proton_card.busy == "":
					break
				await process_frame
			await frames(6)
		if pp.get("proton_card") != null and not pp.proton_card.focusables().is_empty():
			await _focus_row(pp.proton_card.focusables()[0])
		await shot("settings_performance")
	if want(["settings_system"]):
		await _settings_page("system")
		var bt: Node = st.pages["system"].find_child("BluetoothDevices", true, false)
		for i in 60:
			if bt == null or bt.busy == "":
				break
			await process_frame
		if bt != null and not bt.focusables().is_empty():
			await _focus_row(bt.focusables()[0])
		await shot("settings_system")
	if want(["settings_buttons"]):
		# Settings > Controller > Button shortcuts on the Claw: M1 takes a
		# screenshot, M2 sends Alt + Enter, Quick Settings held opens Steam's keyboard.
		_button_controls()
		main.show_screen("settings")
		await frames(4)
		st.open_category("device", "controller")
		await frames(14)
		var card: Node = st.find_child("ShortcutsCard", true, false)
		if card != null and card.rows.has("hold:QuickAccess"):
			await _focus_row(card.rows["hold:QuickAccess"].button)
			card._on_seen("QuickAccess", "hold")
		await frames(8)
		await shot("settings_buttons")
	if want(["settings_profiles"]):
		await _settings_page("profiles")
		var f: Array = st.pages["profiles"].focusables()
		if f.size() > 3:
			f[3].grab_focus()
		await shot("settings_profiles")
	if want(["settings_saves"]):
		main.show_screen("settings")
		await frames(4)
		st.cat_buttons["saves"].grab_focus()
		await frames(2)
		st.enter_page()
		var sp = st.pages["saves"]
		var gk := "game_" + SAVES_KEY.validate_node_name()
		if sp.rows.has(gk):
			sp.rows[gk].button.grab_focus()
		await shot("settings_saves")
	for p in [["settings_about", "about"], ["settings_storage", "storage"], ["settings_fixes", "fixes"], ["settings_updates", "updates"]]:
		if not want([p[0]]):
			continue
		main.show_screen("settings")
		await frames(4)
		st.open_category("device", p[1])
		await frames(14)
		if p[1] == "storage":
			var cb: Control = st.find_child("CleanButton", true, false)
			if cb != null:
				cb.grab_focus()
				await frames(10)
		await shot(p[0])
	if want(["settings_battery"]):
		# About this device, further down: the week's battery history.
		main.show_screen("settings")
		await frames(4)
		st.open_category("device", "about")
		await frames(14)
		var hist: Node = st.find_child("Card_history", true, false)
		if hist != null:
			hist.grab_focus()
		await frames(12)
		await shot("settings_battery")
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


## Settings > Media: the recorder set up, clips with pictures, a clip's sheet
## and its Send to phone page.
func _media() -> void:
	if not want(["settings_media", "media_clip_sheet", "media_share"]):
		return
	main.show_screen("settings")
	await frames(4)
	var st = main.settings
	st.open_category("media")
	await frames(4)
	var page = st.pages["media"]
	for i in 200:
		if page.busy == "":
			break
		await process_frame
	await frames(6)
	if not page.clip_rows.is_empty():
		page.clip_rows[0].button.grab_focus()
	await frames(8)
	await shot("settings_media")
	if not page.clip_rows.is_empty() and want(["media_clip_sheet"]):
		page.open_clip(page.clip_rows[0].clip)
		await frames(12)
		await shot("media_clip_sheet")
		page.sheet.close()
		await frames(4)
	if not page.clip_rows.is_empty() and want(["media_share"]):
		page.share_clip(page.clip_rows[0].clip)
		await frames(2)
		if page.share != null and page.share.drop.is_running():
			page.share.qr_rect.texture = load("res://scripts/ui/settings/qr.gd").texture(page.share.drop.url.replace("127.0.0.1", LAN_IP), 6)
		await frames(12)
		await shot("media_share")
		page.share.close()
	main.show_screen("home")
	await frames(4)


# ------------------------------------------------------------ first-run setup

## First-run setup at its Game art step, the way a new player sees it after
## Welcome, Look and Stores: the QR opens GameCove's one-time page for the
## phone (KeyDrop, really serving here on 127.0.0.1; the address shown is a
## home Wi-Fi one).
func _setup_art() -> void:
	if not want(["setup_art"]):
		return
	main.show_screen("home")
	await frames(3)
	var setup = S.FakeSetup.new()
	setup.done = {"welcome": true, "theme": true, "stores": true}
	setup.status["epic"] = {"signed_in": true, "account": "player", "how": "code"}
	setup.status["gog"] = {"signed_in": true, "account": "player", "how": "heroic"}
	var flow_script = load("res://scripts/ui/setup/setup_flow.gd")
	var svc := {"setup": setup, "device": main.settings.services.get("device"), "library": root.get_node("Library"),
		"photo": main.settings.services.get("photo"), "lan": func() -> Array: return []}
	var flow: Control = flow_script.open(main, svc, "art")
	await frames(4)
	var step: Node = flow.art_step
	if step != null:
		step.stop()
		step._ensure_drop()
		step.drop.bind_address = "127.0.0.1"
		step._open_phone()
		if step.drop.is_running():
			step.drop.url = step.drop.url.replace("127.0.0.1", LAN_IP)
			step._show_mode()
	flow.focus_first()
	await frames(6)
	await shot("setup_art")
	flow.finish()
	await frames(3)


func _short_version() -> String:
	var v := release_version()
	var parts := v.split(".")
	return ".".join(parts.slice(0, 2)) if parts.size() >= 2 and parts[2] == "0" else v


## The version a release build shows: packaging/rpm/gamecove.spec's Version.
static func release_version() -> String:
	var f := FileAccess.open(ProjectSettings.globalize_path("res://").path_join("../packaging/rpm/gamecove.spec"), FileAccess.READ)
	if f == null:
		return "0.1.0"
	for line in f.get_as_text().split("\n"):
		if line.begins_with("Version:"):
			return line.trim_prefix("Version:").strip_edges()
	return "0.1.0"
