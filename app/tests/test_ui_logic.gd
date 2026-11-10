extends "res://tests/test_case.gd"
## Pure UI logic: store filter, recent sorting, Continue pick, badge text,
## explanation strings and quick-goal mapping.

const View := preload("res://scripts/ui/library_view.gd")
const Texts := preload("res://scripts/ui/texts.gd")
const Tile := preload("res://scripts/ui/game_tile.gd")
const MainScript := preload("res://scripts/main.gd")


static func g(store: String, id: String, title: String, installed := true, last := 0, info := {}) -> Dictionary:
	var base := {"released": null, "time_to_beat": null, "anticheat": null, "protondb": null}
	base.merge(info, true)
	return {"key": "%s:%s" % [store, id], "store": store, "id": id, "title": title, "installed": installed,
		"art": {"cover": "", "hero": "", "logo": "", "icon": ""}, "info": base,
		"last_played": last, "playtime_min": 0}


func _games() -> Array:
	return [
		g("steam", "1", "Alpha", true, 100),
		g("epic", "2", "Bravo", true, 300),
		g("gog", "3", "Charlie", false, 0),
		g("steam", "4", "Delta", true, 0),
		g("amazon", "5", "Echo", true, 300),
	]


func test_store_filter() -> void:
	var games := _games()
	eq(View.filter_by_store(games, "").size(), 5, "All keeps every game")
	eq(View.filter_by_store(games, "steam").map(func(x): return x["id"]), ["1", "4"], "Steam only")
	eq(View.filter_by_store(games, "gog").size(), 1, "GOG only")
	eq(View.filter_by_store([], "epic").size(), 0, "empty library")
	eq(View.STORES.map(func(s): return s[1]), ["All", "Steam", "Epic", "GOG", "Amazon"], "filter labels")


func test_recently_played_sorted_newest_first() -> void:
	var r := View.recently_played(_games())
	# Bravo and Echo tie at 300: title order breaks the tie. Unplayed games are left out.
	eq(r.map(func(x): return x["title"]), ["Bravo", "Echo", "Alpha"], "recent order")
	eq(View.recently_played(_games(), 1).size(), 1, "limit")


func test_installed_filter() -> void:
	eq(View.installed(_games()).size(), 4, "installed count")


func test_continue_game() -> void:
	eq(View.continue_game(_games())["title"], "Bravo", "most recent installed")
	var never := [g("steam", "9", "Zed", false, 999), g("steam", "8", "Yak", true, 0)]
	eq(View.continue_game(never)["title"], "Yak", "falls back to first installed, skips uninstalled recent")
	eq(View.continue_game([]), {}, "empty library has no hero")
	eq(View.continue_game([g("gog", "1", "X", false)]), {}, "nothing installed")


func test_badge_text() -> void:
	var works := g("steam", "1", "A", true, 0, {"anticheat": {"status": "works", "anticheats": ["EAC"]}})
	eq(Texts.anticheat_badge(works["info"]), {"text": "Anti-cheat OK", "tone": "good"}, "works badge")
	eq(Texts.anticheat_badge({"anticheat": {"status": "blocked", "anticheats": []}})["tone"], "warn", "blocked tone")
	eq(Texts.anticheat_badge({"anticheat": {"status": "denied", "anticheats": []}})["text"], "Linux denied", "denied text")
	eq(Texts.anticheat_badge({"anticheat": {"status": "unknown", "anticheats": []}}), {}, "unknown has no badge")
	eq(Texts.anticheat_badge({"anticheat": null}), {}, "null has no badge")

	var ttb := {"time_to_beat": {"main_h": 10.0, "extra_h": 20.0, "complete_h": null, "count": 17, "source": "igdb"}}
	eq(Texts.ttb_badge(ttb), "10 h", "main hours")
	eq(Texts.ttb_badge({"time_to_beat": {"main_h": null, "extra_h": 6.5, "complete_h": null, "count": 1}}), "6.5 h", "falls back to extras")
	eq(Texts.ttb_badge({"time_to_beat": null}), "", "no data")

	var specs := Tile.badge_specs(g("gog", "1", "A", false, 0, ttb))
	eq(specs.map(func(s): return s["text"]), ["10 h to beat", "Not installed"], "tile badges in order")
	eq(Tile.badge_specs(g("steam", "1", "A")), [], "plain game has no badges")


func test_game_page_lines() -> void:
	var info := {"time_to_beat": {"main_h": 10.0, "extra_h": 20.0, "complete_h": null, "count": 17, "source": "igdb"},
		"anticheat": {"status": "denied", "anticheats": ["Easy Anti-Cheat"]}, "protondb": "gold"}
	eq(Texts.ttb_line(info), "Main story 10 h  ·  Main + extras 20 h  ·  100% —  ·  from 17 players  ·  data from IGDB.com", "ttb line credits IGDB")
	ok(Texts.anticheat_line(info).contains("Easy Anti-Cheat"), "anti-cheat names listed")
	ok(Texts.anticheat_line(info).contains("blocks Linux"), "denied explained")
	eq(Texts.protondb_line(info), "Community reports (ProtonDB data): Gold, runs perfectly after small tweaks", "tier labelled as our summary of community reports")
	eq(Texts.protondb_line({"protondb": null}), "Community reports (ProtonDB data): no reports yet", "no protondb")
	ok(Texts.DATA_CREDIT.contains("ODbL") and Texts.DATA_CREDIT.contains("IGDB"), "ODbL notice and IGDB credit")
	eq(Texts.ttb_line({"time_to_beat": null}), "Time to beat: no data yet", "no ttb")


func test_every_setting_explained() -> void:
	for k in Texts.TITLES:
		ok(Texts.explain(k).length() > 20, "explanation for " + k)
	for goal in Texts.GOALS:
		ok(Texts.explain("goal", goal) != Texts.explain("goal"), "goal %s has its own line" % goal)
		ok(Texts.GOAL_LABELS.has(goal), "goal label " + goal)
	for u in Texts.UPSCALERS:
		ok(Texts.explain("upscaler", u).length() > 20, "upscaler line " + u)
	eq(Texts.explain("frame_gen", true), Texts.EXPLAIN["frame_gen"], "bool falls back to general line")
	eq(Texts.GOAL_LABELS.values(), ["Longest battery", "Balanced", "Smoothest"], "goal names")


func test_quick_goal_mapping() -> void:
	var s := {"goal": "balanced", "fps_limit": 0, "upscaler": "off", "frame_gen": false, "low_latency": false}
	var b := Texts.apply_goal(s, "battery")
	eq(b, {"goal": "battery", "fps_limit": 30, "upscaler": "auto", "frame_gen": false, "low_latency": false}, "battery preset")
	eq(Texts.apply_goal(s, "smooth")["frame_gen"], true, "smooth turns frame gen on")
	eq(Texts.apply_goal(s, "smooth")["fps_limit"], 0, "smooth has no cap")
	eq(Texts.apply_goal(s, "balanced")["fps_limit"], 60, "balanced caps at 60")
	eq(s["goal"], "balanced", "input not modified")
	eq(Texts.goal_profile("smooth", ["battery", "balanced", "performance"]), "performance", "smooth profile")
	eq(Texts.goal_profile("battery", ["power-saver", "balanced"]), "power-saver", "battery profile alias")
	eq(Texts.goal_profile("smooth", []), "", "no profiles")


func test_formatting() -> void:
	eq(Texts.format_hours(null), "—", "null hours")
	eq(Texts.format_hours(22.5), "23 h", "rounds above 10")
	eq(Texts.fps_label(0), "No limit", "no fps limit")
	eq(Texts.charge_label(100), "Off (charge to 100%)", "charge off")
	eq(Texts.refresh_rates([60, 120]), [60, 72, 90, 100, 120], "panel rates")
	eq(Texts.refresh_rates([40, 144]).has(144), true, "panel max included")
	eq(Texts.refresh_rates([]), [], "unknown panel")
	eq(Texts.last_played_text(0, 1000), "Not played yet", "never played")
	eq(Texts.last_played_text(1_000_000 - 86400 * 3, 1_000_000), "Played 3 days ago", "days ago")
	eq(MainScript.clock_text({"hour": 0, "minute": 5}), "12:05 AM", "midnight")
	eq(MainScript.clock_text({"hour": 13, "minute": 30}), "1:30 PM", "afternoon")


## Review 2, low 23: cover and screenshot art was decoded and scaled on the main thread.
func test_art_is_decoded_off_the_main_thread() -> void:
	var Kit := load("res://scripts/ui/ui_kit.gd")
	var p := OS.get_temp_dir().path_join("gc_art_%d.png" % Time.get_ticks_usec())
	Image.create(64, 32, false, Image.FORMAT_RGB8).save_png(p)
	var img: Image = Kit.decode_art(p, Vector2i(16, 16))
	eq(img.get_size(), Vector2i(16, 8), "decoded and scaled by the worker function")
	ok(Kit.decode_art(p + ".missing", Vector2i(16, 16)) == null, "missing file: nothing")
	var tr := TextureRect.new()
	Kit.load_art_async(p, Vector2i(16, 16), tr)
	ok(tr.texture == null, "nothing decoded on the calling thread")
	Kit.wait_art_jobs()
	var src := FileAccess.get_file_as_string("res://scripts/ui/games/metadata_card.gd") + FileAccess.get_file_as_string("res://scripts/ui/games/art_picker.gd") \
		+ FileAccess.get_file_as_string("res://scripts/ui/streaming/streaming_screen.gd")
	ok(not "Kit.load_art(" in src, "the screens use load_art_async")
	tr.free()
	DirAccess.remove_absolute(p)
