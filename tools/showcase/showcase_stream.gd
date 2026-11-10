extends "../screenshots/shoot_streaming.gd"
## The showcase's Stream tab: a gaming PC ("GAMING-PC", Sunshine/Apollo-style
## host) whose app list is real games with their Steam covers, a second host
## and the user's remote office PC. Shots: stream, stream_host.
## SHOWCASE_THEME=light renders the light theme.

const LIB := ["Steam Big Picture", "Desktop", "Cyberpunk 2077", "Red Dead Redemption 2", "Forza Horizon 5",
	"Black Myth: Wukong", "Monster Hunter Wilds", "Baldur's Gate 3", "ELDEN RING", "HELLDIVERS 2"]


func _run() -> void:
	OS.low_processor_usage_mode = false
	var here: String = get_script().resource_path.get_base_dir()
	var doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(here.path_join("library.json")))
	for g in doc["games"]:
		var p := here.path_join("cache/%s/cover.jpg" % g["steam_appid"])
		if FileAccess.file_exists(p):
			cover_by_title[str(g["title"]).to_lower()] = ProjectSettings.globalize_path(p)
	var prefs = load("res://scripts/ui/ui_prefs.gd")
	prefs.path = OS.get_cache_dir().path_join("gamecove-showcase-stream.cfg")
	DirAccess.remove_absolute(prefs.path)
	var theme_id := OS.get_environment("SHOWCASE_THEME")
	prefs.theme = theme_id if theme_id != "" else "cove"
	prefs.match_art = prefs.theme == "cove"
	load("res://scripts/main.gd").boot_splash = false
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await frames(3)
	main._live_timer.stop()
	main._live_timer.wait_time = 9999
	var flow_script = load("res://scripts/ui/setup/setup_flow.gd")
	if flow_script.instance != null:
		flow_script.instance.finish()
	prefs.theme = theme_id if theme_id != "" else "cove"
	prefs.match_art = prefs.theme == "cove"
	main.apply_theme()
	main.top_bar.set_status("MSI Claw 8 EX AI+", {"percent": 72, "status": "Discharging", "watts": 9.4}, "8:42 PM", {"connected": true, "strength": 0.8})
	main.top_bar.set_telemetry({"tdp_w": 17.0, "profile": "balanced", "temp_c": 58.0})
	main.hint_status.text = "● GameCove %s   MSI Claw 8 EX AI+" % _short_version()
	svc = main.streaming
	screen = main.stream_screen
	svc.sync_mode = true
	svc.ctx["runner"] = NoRunner.new()
	svc.ctx["spawn"] = load("res://tests/fixtures/streaming/fake_spawn.gd").new()
	svc.ctx["probe"] = func(_a, _p): return []
	svc.ctx["display"] = {"width": 1920, "height": 1200, "hz": 120, "hdr": true}
	svc.ctx.erase("display_fn")
	svc.decode = {"h264": true, "hevc": true, "hevc10": true, "av1": true}
	svc.moonlight = {"kind": "flatpak", "program": "/usr/bin/flatpak", "prefix": ["run", "--branch=stable", "com.moonlight_stream.Moonlight"], "config": "", "cache": ""}
	main.show_screen("stream")
	await frames(4)
	svc._check_timer.stop()
	_hosts()
	screen.selected_id = UUID
	screen.rebuild()
	await frames(3)
	if screen.shelf.tiles.size() > 2:
		screen.shelf.tiles[2].grab_focus()
	await shot("stream")
	if want_shot("stream_host"):
		screen.host_cards[0].grab_focus()
		await shot("stream_host")
	await finish()


func want_shot(n: String) -> bool:
	return only.is_empty() or n in only


func _hosts() -> void:
	var S = load("res://scripts/streaming/streaming.gd")
	var h: Dictionary = S.blank_host(UUID)
	h.merge({"uuid": UUID, "name": "GAMING-PC", "addresses": ["192.168.1.20"], "address": "192.168.1.20", "mac": "D8:BB:C1:12:34:56",
		"status": "online", "paired": true, "latency_ms": 3, "flavor": "vibepollo", "permission": 0x07000100, "sleep_allowed": true,
		"info": {"hevc": true, "av1": true, "hdr": true}, "apps_state": "ready"}, true)
	var apps: Array = []
	var ids := [1093255277, 881448767, 1091500, 1174180, 1551360, 2358720, 2246340, 1086940, 1245620, 553850]
	for i in LIB.size():
		apps.append({"id": ids[i], "title": LIB[i], "hdr": i >= 2, "uuid": "",
			"art": str(cover_by_title.get(str(LIB[i]).to_lower(), ""))})
	h["apps"] = apps
	var u: Dictionary = S.blank_host("5C2B7E9A-1111-2222-3333-444455556666")
	u.merge({"uuid": "5C2B7E9A-1111-2222-3333-444455556666", "name": "LIVING-ROOM", "addresses": ["192.168.1.31"], "address": "192.168.1.31",
		"status": "online", "paired": false, "latency_ms": 6, "flavor": "sunshine", "info": {"hevc": true, "av1": false, "hdr": true}}, true)
	var a: Dictionary = S.blank_host("77777777-8888-9999-AAAA-BBBBBBBBBBBB")
	a.merge({"uuid": "77777777-8888-9999-AAAA-BBBBBBBBBBBB", "name": "OFFICE-TOWER", "addresses": ["100.101.102.103"], "address": "100.101.102.103",
		"status": "asleep", "paired": true, "remote": true, "mac": "AA:BB:CC:00:11:22", "flavor": "vibepollo", "apps_state": "ready",
		"apps": apps.slice(2, 6), "info": {"hevc": true, "av1": true, "hdr": false}}, true)
	svc.hosts = {UUID: h, u["id"]: u, a["id"]: a}


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
