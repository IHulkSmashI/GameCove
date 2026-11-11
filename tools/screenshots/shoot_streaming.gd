extends SceneTree
## Renders the Stream tab inside the real main scene with a fake Streaming
## service state (no network, no Moonlight). Run through shoot.sh:
##   SHOOT_SCRIPT=shoot_streaming.gd tools/screenshots/shoot.sh /tmp/shots 1280x800
## Shots: stream_setup, stream_setup_moonlight, stream_hosts, stream_host_focus,
## stream_busy, stream_unpaired, stream_asleep, stream_pair, stream_paired,
## stream_settings, stream_more, stream_add, stream_light, stream_sunset.

var out := "/tmp/gamecove-shots/"
var only: Array = []
var suffix := ""
var art_dir := "/tmp/gamecove-shots/art/"
var main: Control
var svc: Node
var screen: Control
var covers: Array = []
## Painted cover per game title, so each app tile shows its own game.
var cover_by_title: Dictionary = {}

const ShotVersion := preload("shot_version.gd")
const Layout := preload("../layout/recorder.gd")
const UUID := "A1B2C3D4-0000-4E5F-8899-AABBCCDDEEFF"
const APPS := [["Steam Big Picture", 1093255277], ["Desktop", 881448767], ["Iron Meridian", 101], ["Kingdom of Ash", 102],
	["Hollow Tide", 103], ["Northbound", 104], ["Neon Ronin", 105], ["Saltwind", 106], ["Tidebreaker", 107]]


class NoRunner extends RefCounted:
	func run(_p: String, _a: PackedStringArray) -> Dictionary:
		return {"code": 127, "out": ""}


func _initialize() -> void:
	Layout.begin()   # tools/layout: measure every shot on one screen of the matrix
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		match args[i]:
			"--out": out = args[i + 1].trim_suffix("/") + "/"
			"--only": only = Array(args[i + 1].split(","))
			"--suffix": suffix = args[i + 1]
	_run.call_deferred()


func frames(n: int) -> void:
	for i in n:
		await process_frame


func shot(name: String) -> void:
	if not only.is_empty() and name not in only:
		return
	for i in 60:
		await process_frame
		if load("res://scripts/ui/art_cache.gd").pending_count() == 0 and i > 20:
			break
	await frames(30)
	if Layout.measuring():
		Layout.check(root, name)
		return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(out)
	root.get_texture().get_image().save_png(out + name + suffix + ".png")
	print("saved ", out + name + suffix + ".png")
	Layout.check(root, name)


func _run() -> void:
	OS.low_processor_usage_mode = false
	var painter: GDScript = load(get_script().resource_path.get_base_dir().path_join("painter.gd"))
	DirAccess.make_dir_recursive_absolute(art_dir)
	for g in await painter.make_library(self, art_dir):
		if str(g["art"]["cover"]) != "":
			covers.append(g["art"]["cover"])
			cover_by_title[str(g.get("title", "")).to_lower()] = g["art"]["cover"]
	var prefs = load("res://scripts/ui/ui_prefs.gd")
	prefs.path = "/tmp/gamecove-shots/ui-stream.cfg"
	DirAccess.remove_absolute(prefs.path)
	load("res://scripts/main.gd").boot_splash = false
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await frames(3)
	main._live_timer.stop()
	main._live_timer.wait_time = 9999
	var flow_script = load("res://scripts/ui/setup/setup_flow.gd")
	if flow_script.instance != null:
		flow_script.instance.finish()
	main.top_bar.set_status("MSI Claw 8 EX AI+", {"percent": 72, "status": "Discharging", "watts": 9.4}, "2:05 PM", {"connected": true, "strength": 0.8})
	main.top_bar.set_telemetry({"tdp_w": 17.0, "profile": "balanced", "temp_c": 58.0})
	main.hint_status.text = "● GameCove %s   MSI Claw 8 EX AI+" % ShotVersion.short()
	if OS.get_environment("SHOOT_THEME") != "":
		var TL = load("res://theme/gamecove_theme.gd")
		TL.use(OS.get_environment("SHOOT_THEME"))
		main.theme = TL.build()
	svc = main.streaming
	screen = main.stream_screen
	svc.sync_mode = true
	svc.ctx["runner"] = NoRunner.new()
	svc.ctx["spawn"] = load("res://tests/fixtures/streaming/fake_spawn.gd").new()
	svc.ctx["probe"] = func(_a, _p): return []
	svc.ctx["display"] = {"width": 1920, "height": 1200, "hz": 120, "hdr": true}
	svc.ctx.erase("display_fn")
	svc.decode = {"h264": true, "hevc": true, "hevc10": true, "av1": true}
	svc.hosts = {}

	# Setup guide, then the same with Moonlight missing
	svc.moonlight = {"kind": "flatpak", "program": "/usr/bin/flatpak", "prefix": ["run", "--branch=stable", "com.moonlight_stream.Moonlight"], "config": "", "cache": ""}
	main.show_screen("stream")
	await frames(4)
	svc._check_timer.stop()   # fake state stays as set
	screen.rebuild()
	screen.default_focus().grab_focus()
	await shot("stream_setup")
	svc.moonlight = {"kind": ""}
	screen.rebuild()
	screen.default_focus().grab_focus()
	await shot("stream_setup_moonlight")
	svc.moonlight = {"kind": "flatpak", "program": "/usr/bin/flatpak", "prefix": ["run", "--branch=stable", "com.moonlight_stream.Moonlight"], "config": "", "cache": ""}

	_hosts()
	screen.selected_id = UUID
	screen.rebuild()
	await frames(3)
	screen.shelf.tiles[2].grab_focus()
	await shot("stream_hosts")
	screen.host_cards[0].grab_focus()
	await shot("stream_host_focus")

	svc.hosts[UUID]["status"] = "busy"
	svc.hosts[UUID]["current_app"] = 101
	screen.rebuild()
	await frames(3)
	screen.detail_focus[0].grab_focus()
	await shot("stream_busy")
	svc.hosts[UUID]["status"] = "online"
	svc.hosts[UUID]["current_app"] = 0

	screen.host_cards[1].grab_focus()
	await frames(3)
	await shot("stream_unpaired")
	screen.host_cards[2].grab_focus()
	await frames(3)
	await shot("stream_asleep")

	# pairing
	screen.host_cards[1].grab_focus()
	await frames(2)
	screen.pair_sheet.open_waiting("living-room", "4071", "https://192.168.1.31:47990")
	await shot("stream_pair")
	screen.pair_sheet.show_paired()
	await shot("stream_paired")
	screen.pair_sheet.close()

	screen.host_cards[0].grab_focus()
	await frames(3)
	screen.shelf.tiles[3].grab_focus()
	await frames(2)
	screen.open_settings(screen.shelf.tiles[3])
	await frames(4)
	screen.settings_sheet.rows["quality"].button.grab_focus()
	await shot("stream_settings")
	screen.settings_sheet.close()
	await frames(2)
	screen.open_more()
	await shot("stream_more")
	screen.more_sheet.close()
	await frames(2)
	screen.open_add()
	for ch in "100.101.102.103":
		screen.keyboard.type(ch)
	await shot("stream_add")
	screen._kb_modal.visible = false
	screen.keyboard.visible = false

	var ThemeLib = load("res://theme/gamecove_theme.gd")
	for pair in [["light", "stream_light"], ["sunset", "stream_sunset"]]:
		if not only.is_empty() and not pair[1] in only:
			continue
		ThemeLib.use(pair[0])
		main.theme = ThemeLib.build()
		screen.rebuild()
		await frames(3)
		screen.shelf.tiles[0].grab_focus()
		await shot(pair[1])
	await finish()


func _hosts() -> void:
	var S = load("res://scripts/streaming/streaming.gd")
	var h: Dictionary = S.blank_host(UUID)
	h.merge({"uuid": UUID, "name": "GAMING-PC", "addresses": ["192.168.1.20"], "address": "192.168.1.20", "mac": "D8:BB:C1:12:34:56",
		"status": "online", "paired": true, "latency_ms": 3, "flavor": "vibepollo", "permission": 0x07000100, "sleep_allowed": true,
		"info": {"hevc": true, "av1": true, "hdr": true}, "apps_state": "ready"}, true)
	var apps: Array = []
	for i in APPS.size():
		apps.append({"id": APPS[i][1], "title": APPS[i][0], "hdr": true, "uuid": "",
			"art": str(cover_by_title.get(str(APPS[i][0]).to_lower(), "")) if i >= 2 else ""})
	h["apps"] = apps
	var u: Dictionary = S.blank_host("5C2B7E9A-1111-2222-3333-444455556666")
	u.merge({"uuid": "5C2B7E9A-1111-2222-3333-444455556666", "name": "living-room", "addresses": ["192.168.1.31"], "address": "192.168.1.31",
		"status": "online", "paired": false, "latency_ms": 6, "flavor": "sunshine", "info": {"hevc": true, "av1": false, "hdr": true}}, true)
	var a: Dictionary = S.blank_host("77777777-8888-9999-AAAA-BBBBBBBBBBBB")
	a.merge({"uuid": "77777777-8888-9999-AAAA-BBBBBBBBBBBB", "name": "office-tower", "addresses": ["100.101.102.103"], "address": "100.101.102.103",
		"status": "asleep", "paired": true, "remote": true, "mac": "AA:BB:CC:00:11:22", "flavor": "vibepollo", "apps_state": "ready",
		"apps": apps.slice(2, 6), "info": {"hevc": true, "av1": true, "hdr": false}}, true)
	svc.hosts = {UUID: h, u["id"]: u, a["id"]: a}


func finish() -> void:
	if main != null and is_instance_valid(main):
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


func _finalize() -> void:
	Layout.save(get_script().resource_path.get_file().get_basename())
