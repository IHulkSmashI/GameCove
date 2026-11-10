extends SceneTree
## Records GameCove's animations for review, with the showcase's real-game
## library (tools/showcase/library.json and its art cache, which
## tools/showcase/shoot.sh downloads) when that cache is there, else a fake
## library with painted art (--painted forces it). No network either way: run under Godot's Movie Maker so every frame is rendered at a
## fixed step whatever the machine's speed, then cut into clips by the markers
## this prints. tools/screenshots/record_animations.sh does all of it:
##
##   tools/screenshots/record_animations.sh [OUT_DIR] [clips]
##
## Clips: launch (Home Play -> zoom -> waiting -> failed: back), launch_page
## (Play on the game page), screens (RB through every tab, LB back, a page open
## and close), moments (toasts, wake fade, shelves easing in), boot (the intro clip),
## boot_code (the code animation used when there's no clip).
## Each prints "CLIP <name> <first frame> <last frame>".

var only: Array = []
var painted := false
var art_dir := "/tmp/gamecove-anim/art/"
## tools/showcase, for the real-game library.
var showcase := ""
var main: Control
var games: Array = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--only":
			only = Array(args[i + 1].split(","))
		elif args[i] == "--painted":
			painted = true
	_run.call_deferred()


func frames(n: int) -> void:
	for i in n:
		await process_frame


func secs(s: float) -> void:
	await frames(int(round(s * 30.0)))


func settle() -> void:
	for i in 90:
		await process_frame
		if load("res://scripts/ui/art_cache.gd").pending_count() == 0 and i > 20:
			break
	await frames(20)


func want(n: String) -> bool:
	return only.is_empty() or n in only


func mark(n: String, from: int) -> void:
	print("CLIP %s %d %d" % [n, from, Engine.get_frames_drawn()])


func _title(i: int, fallback: String) -> String:
	if games.is_empty():
		return fallback
	return str(games[posmod(i, games.size())].get("title", fallback))


func _cache(rel: String) -> String:
	var p := showcase.path_join("cache").path_join(rel)
	return ProjectSettings.globalize_path(p) if FileAccess.file_exists(p) else ""


## The showcase profile's games (real titles, their Steam art from the cache);
## [] when the cache isn't there. Same entries as tools/showcase/showcase.gd.
func _showcase_library() -> Array:
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(showcase.path_join("library.json")))
	if not doc is Dictionary:
		return []
	var now := int(Time.get_unix_time_from_system())
	var out: Array = []
	for g in doc["games"]:
		var a: String = g["steam_appid"]
		var hero := _cache(a + "/hero.jpg")
		if hero == "" and out.is_empty():
			return []   # no art cache: painted art instead
		var info: Dictionary = g["info"].duplicate(true)
		if info.get("released") != null:
			info["released"] = int(info["released"])
		if info.get("time_to_beat") is Dictionary and info["time_to_beat"].has("count"):
			info["time_to_beat"]["count"] = int(info["time_to_beat"]["count"])
		var e := {"key": "%s:%s" % [g["store"], g["id"]], "store": g["store"], "id": g["id"], "title": g["title"],
			"installed": g["installed"],
			"art": {"cover": _cache(a + "/cover.jpg"), "hero": hero, "logo": _cache(a + "/logo.png"), "icon": ""},
			"info": info,
			"last_played": int(now - float(g["last_played_days"]) * 86400.0) if float(g["last_played_days"]) >= 0.0 else 0,
			"playtime_min": int(g["playtime_min"])}
		if g.has("added_days"):
			e["added"] = now - int(float(g["added_days"]) * 86400.0)
		out.append(e)
	return out


func _run() -> void:
	OS.low_processor_usage_mode = false
	showcase = get_script().resource_path.get_base_dir().path_join("../showcase").simplify_path()
	if not painted:
		games = _showcase_library()
	if games.is_empty():
		var painter: GDScript = load(get_script().resource_path.get_base_dir().path_join("painter.gd"))
		DirAccess.make_dir_recursive_absolute(art_dir)
		games = await painter.make_library(self, art_dir)
	print("LIBRARY %s" % ("showcase" if not painted and games.size() > 0 and str(games[0].get("key", "")).begins_with("steam:") else "painted"))
	var prefs = load("res://scripts/ui/ui_prefs.gd")
	prefs.path = "/tmp/gamecove-anim/ui.cfg"
	DirAccess.remove_absolute(prefs.path)
	load("res://scripts/main.gd").boot_splash = false
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await frames(3)
	main._live_timer.stop()
	var flow_script = load("res://scripts/ui/setup/setup_flow.gd")
	if flow_script.instance != null:
		flow_script.instance.finish()
	main.top_bar.set_status("MSI Claw 8 EX AI+", {"percent": 72, "status": "Discharging", "watts": 9.4}, "2:05 PM", {"connected": true, "strength": 0.8})
	main.hint_status.text = "● GameCove   MSI Claw 8 EX AI+"
	var lib := root.get_node("Library")
	# The real Library scans this machine first (finds nothing) and rescans when
	# the game database lands: let that finish and stop the rescans.
	for i in 600:
		if int(lib.get("_task")) == -1:
			break
		await process_frame
	var db: Node = lib.get("_db")
	if db != null and db.updated.is_connected(lib.refresh):
		db.updated.disconnect(lib.refresh)
	lib.games.assign(games)
	lib.changed.emit()
	await settle()
	main.home.play_button.grab_focus()
	await settle()

	if want("launch"):
		var f := Engine.get_frames_drawn()
		await secs(0.4)
		var g: Dictionary = main.home.spotlight_game
		main.launch_overlay.show_for(g, main.backdrop.current_accent(), main._launch_source(g))
		await secs(2.4)
		main.launch_overlay.back()
		await secs(0.9)
		mark("launch", f)

	if want("launch_page"):
		main._open_page(games[3] if games.size() > 3 else games[0])
		await settle()
		var f := Engine.get_frames_drawn()
		await secs(0.3)
		var g: Dictionary = main.page.game
		main.launch_overlay.show_for(g, main.backdrop.current_accent(), main._launch_source(g))
		await secs(2.0)
		main.launch_overlay.finish()   # the game took the screen
		await secs(0.3)
		mark("launch_page", f)
		main._close_page()
		await settle()

	if want("screens"):
		main.home.play_button.grab_focus()
		await settle()
		var f := Engine.get_frames_drawn()
		await secs(0.3)
		for i in 5:
			main.cycle_screen(1)
			await secs(0.7)
		main.cycle_screen(-1)
		await secs(0.7)
		main.show_screen("home")
		await secs(0.6)
		main._open_page(main.home.spotlight_game)   # the hero stays, the cards slide up
		await secs(0.9)
		main._close_page()
		await secs(0.8)
		var row: Array = main.home.shelves()[0].tiles if not main.home.shelves().is_empty() else []
		if row.size() > 2:
			row[2].grab_focus()
			await secs(0.5)
			main._open_page(row[2].game)   # another game: the page fades in, cards slide up
			await secs(0.9)
			main._close_page()
			await secs(0.8)
		mark("screens", f)

	if want("moments"):
		var f := Engine.get_frames_drawn()
		await secs(0.3)
		main.toast("%s is 60%% off" % _title(-1, "Hogwarts Legacy"), "tag", "sale", "Wishlist price drop, today only.")
		await secs(0.8)
		main.toast("%s is ready to play" % _title(2, "Hades II"), "check", "good")
		await secs(1.0)
		main._last_wake_ms = -1_000_000
		main._wake_fade()
		await secs(1.0)
		main.home._revealed.clear()
		main.home.set_games(main.home.games)
		await secs(1.0)
		mark("moments", f)

	for clip in ["boot", "boot_code"]:
		if not want(clip):
			continue
		main.show_screen("home")
		main.home.play_button.grab_focus()
		await settle()
		# boot: the clip in res://assets/boot/intro.ogv; boot_code: the code animation
		var Splash = load("res://scripts/ui/boot_splash.gd")
		var keep: String = Splash.video_path
		if clip == "boot_code":
			Splash.video_path = ""
		var f := Engine.get_frames_drawn()
		var sp: Variant = Splash.play(main)
		await secs(3.6)
		if sp != null and is_instance_valid(sp):
			sp.queue_free()
		Splash.video_path = keep
		mark(clip, f)

	main.get_parent().remove_child(main)
	main.free()
	load("res://scripts/main.gd").release_caches()
	load("res://scripts/ui/ui_kit.gd")._art_cache.clear()
	for n in root.get_children():
		var t: Variant = n.get("_task")
		if t is int and t >= 0:
			WorkerThreadPool.wait_for_task_completion(t)
			n.set("_task", -1)
	await frames(4)
	quit(0)
