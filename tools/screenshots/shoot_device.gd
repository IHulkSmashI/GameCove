extends SceneTree
## Renders the device pages (About this device, Controller, Storage, Updates)
## inside the real main scene with fake services. Run through shoot.sh:
##   SHOOT_SCRIPT=shoot_device.gd tools/screenshots/shoot.sh /tmp/shots 1280x800
## Shots: device_about, device_about_scrolled, device_controller, device_controller_test,
## device_storage, device_updates, device_about_light, device_controller_midnight,
## device_about_generic, device_storage_loading, device_controller_missing,
## device_storage_cleanup_missing (an SD library listed but not mounted),
## device_storage_cleanup_away (a card that's out and no longer listed by Steam),
## device_about_photo (needs a photo at /tmp/gamecove-shots/device_photo.webp, e.g. one
## built by tools/device_photos/build.py; skipped otherwise).

var out := "/tmp/gamecove-shots/"
var only: Array = []
var suffix := ""
var main: Control
var Fakes: GDScript
var Kit: GDScript
var frame: Control

const PHOTO := "/tmp/gamecove-shots/device_photo.webp"


## Storage with Clean up: the SD card's library is listed but not mounted.
class ShotStorage extends "res://tests/fixtures/device_ui/fakes.gd".FakeStorage:
	func leftovers() -> void:
		calls.append("leftovers")
	func clean_leftovers() -> bool:
		return false


## Stand-in for DevicePhoto with one cached photo for every device.
class FakePhoto extends RefCounted:
	signal photo_ready(device_id: String, path: String)
	var enabled := true
	func photo_for(_id: String) -> Dictionary:
		return {"path": PHOTO, "credit": {"author": "ZMASLO", "license": "CC BY 3.0",
			"license_url": "https://creativecommons.org/licenses/by/3.0/",
			"page_url": "https://commons.wikimedia.org/wiki/File:Example.png", "file": "Example.png"}}
	func set_enabled(on: bool) -> void:
		enabled = on


func _initialize() -> void:
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
	await frames(40)
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(out)
	root.get_texture().get_image().save_png(out + name + suffix + ".png")
	print("saved ", out + name + suffix + ".png")


func _run() -> void:
	OS.low_processor_usage_mode = false
	Fakes = load("res://tests/fixtures/device_ui/fakes.gd")
	Kit = load("res://scripts/ui/ui_kit.gd")
	var prefs = load("res://scripts/ui/ui_prefs.gd")
	prefs.path = "/tmp/gamecove-shots/ui-device.cfg"
	DirAccess.remove_absolute(prefs.path)
	load("res://scripts/main.gd").boot_splash = false
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await frames(3)
	main._live_timer.stop()
	main._live_timer.wait_time = 9999
	# First-run setup would open over every shot (same as shoot.gd).
	var flow_script = load("res://scripts/ui/setup/setup_flow.gd")
	if flow_script.instance != null:
		flow_script.instance.finish()
	main.top_bar.set_status("MSI Claw 8 EX AI+", {"percent": 72, "status": "Discharging", "watts": 9.4}, "2:05 PM", {"connected": true, "strength": 0.8})
	main.top_bar.set_telemetry({"tdp_w": 17.0, "profile": "balanced", "temp_c": 58.0})
	main.hint_status.text = "● GameCove 0.4   MSI Claw 8 EX AI+"
	main.show_screen("settings")
	await frames(4)
	for c in main.settings.get_children():
		c.visible = false

	var s: Dictionary = Fakes.services()
	s["controls"] = _claw_controls()
	await _page("about_panel.gd", "About this device", s, "device_about")
	if only.is_empty() or "device_about_scrolled" in only:
		var p: Control = frame.get_meta("panel")
		var chain: Array = p.focus_chain()
		chain[mini(5, chain.size() - 1)].grab_focus()
		await shot("device_about_scrolled")
	var cp: Control = await _page("controller_panel.gd", "Controller", s, "device_controller", 1)
	if only.is_empty() or "device_controller_test" in only:
		cp.start_test()
		cp.light("South", true)
		cp.light("LeftPaddle1", true)
		cp.light("RightBumper", true)
		await shot("device_controller_test")
		cp.stop_test()
	# what upscaling keeps here (gamecove-upscale storage), as on a Claw with three games set up
	s["storage"].st["upscaling"] = {"bytes": 438304768, "games": 3, "bundle_bytes": 347078656,
		"folder": "/home/deck/.local/share/gamecove", "parts": []}
	await _page("storage_panel.gd", "Storage", s, "device_storage", 1)
	await _page("updates_panel.gd", "Updates", s, "device_updates", 1)

	if FileAccess.file_exists(PHOTO) and (only.is_empty() or "device_about_photo" in only):
		var ps: Dictionary = Fakes.services()
		ps["photo"] = FakePhoto.new()
		ps["controls"] = s["controls"]
		await _page("about_panel.gd", "About this device", ps, "device_about_photo")

	var ThemeLib = load("res://theme/gamecove_theme.gd")
	for pair in [["light", "about_panel.gd", "device_about_light", "About this device"], ["midnight", "controller_panel.gd", "device_controller_midnight", "Controller"], ["sunset", "storage_panel.gd", "device_storage_sunset", "Storage"]]:
		if not only.is_empty() and not pair[2] in only:
			continue
		ThemeLib.use(pair[0])
		main.theme = ThemeLib.build()
		await _page(pair[1], pair[3], s, pair[2])
	ThemeLib.use("cove")
	main.theme = ThemeLib.build()

	var g: Dictionary = Fakes.services()
	g["device"].device_id = "unknown"
	g["device"].data = {"device": {"id": "unknown", "name": "Unknown handheld", "maker": "Contoso", "model": "Handheld X"},
		"chip": {"cpu": "AMD Ryzen Z2 Go", "cores": 4, "threads": 8, "gpu": "Radeon 680M", "gpu_arch": "RDNA2", "gpu_driver": "amdgpu", "kernel": "6.19.4"},
		"memory": {"total_mb": 16384, "vram_mb": 4096, "gtt_mb": 8192},
		"support": {"level": "generic", "verified": false, "unverified": ["all"], "features": {"tdp": true}, "fixes": [], "quirks": ["Not in GameCove's device table yet. Power limits come from the chip."]}}
	await _page("about_panel.gd", "About this device", g, "device_about_generic")
	g["storage"].st = {"ready": false, "error": "", "drives": [], "libraries": []}
	await _page("storage_panel.gd", "Storage", g, "device_storage_loading")
	if only.is_empty() or "device_storage_cleanup_missing" in only:
		var ms: Node = ShotStorage.new()
		ms.st = s["storage"].st.duplicate(true)
		ms.st["cleanup"] = {"ready": true, "dirs": [], "bytes": 0, "cleaning": false, "missing": ["/run/media/deck/SD/SteamLibrary"]}
		var sm: Dictionary = s.duplicate()
		sm["storage"] = ms
		await _page("storage_panel.gd", "Storage", sm, "device_storage_cleanup_missing")
	if only.is_empty() or "device_storage_cleanup_away" in only:
		# a card that's out and that Steam no longer lists: its games' caches are kept, the rest offered
		var aw: Node = ShotStorage.new()
		aw.st = s["storage"].st.duplicate(true)
		aw.st["cleanup"] = {"ready": true, "dirs": ["/home/deck/.local/share/Steam/steamapps/shadercache/20"], "bytes": 734003200,
			"cleaning": false, "missing": [], "away": ["/run/media/deck/SD/SteamLibrary"]}
		var sa: Dictionary = s.duplicate()
		sa["storage"] = aw
		await _page("storage_panel.gd", "Storage", sa, "device_storage_cleanup_away")
	g["controller"].st = {"available": false, "supported": {}}
	var mp: Control = await _page("controller_panel.gd", "Controller", g, "", 0)
	g["controller"].changed.emit({"available": false, "supported": {}})
	mp.default_focus().grab_focus()
	await shot("device_controller_missing")
	await finish()


## A set-up Claw 8 EX's Controls (the snapshot and patch shoot_controls.gd uses),
## so the Controller page's gyro rows show real values, not "Needs InputPlumber".
func _claw_controls() -> Node:
	var here: String = get_script().resource_path.get_base_dir()
	var fc: Node = load("res://tests/fixtures/ui_controls/fake_controls.gd").new()
	fc.name = "ShotControls"
	fc.load_snapshot("res://tests/fixtures/ui_controls/msi-claw-8-ex.json", load(here.path_join("shoot_controls.gd")).claw_patch())
	root.add_child(fc)
	return fc


## Free main and the static caches before quitting (see shoot.gd).
func finish() -> void:
	if main != null and is_instance_valid(main):
		main.get_parent().remove_child(main)
		main.free()
	load("res://scripts/main.gd").release_caches()
	load("res://scripts/ui/ui_kit.gd")._art_cache.clear()
	# Background work (library scans, art decodes) must end before the engine does.
	for n in root.get_children():
		var t: Variant = n.get("_task")
		if t is int and t >= 0:
			WorkerThreadPool.wait_for_task_completion(t)
			n.set("_task", -1)
	await frames(4)
	quit(0)


## Shows one page in a Settings-like frame, focuses `focus_index`, shoots.
func _page(file: String, title: String, s: Dictionary, shot_name: String, focus_index := 0) -> Control:
	if frame != null:
		var old: Control = frame.get_meta("panel")
		if old.has_method("closed"):
			old.closed()
		frame.queue_free()
		await frames(2)
	frame = MarginContainer.new()
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.add_theme_constant_override("margin_left", 48)
	frame.add_theme_constant_override("margin_right", 48)
	frame.add_theme_constant_override("margin_top", 84)
	frame.add_theme_constant_override("margin_bottom", 64)
	var col: VBoxContainer = Kit.vbox(14)
	frame.add_child(col)
	var crumbs: HBoxContainer = Kit.hbox(10)
	crumbs.add_child(Kit.label("Settings", "AccentLabel"))
	crumbs.add_child(Kit.label("›", "QuietLabel"))
	crumbs.add_child(Kit.label(title, "QuietLabel"))
	col.add_child(crumbs)
	col.add_child(Kit.label(title, "TitleLabel"))
	var p: Control = load("res://scripts/ui/device/" + file).build(s)
	col.add_child(p)
	frame.set_meta("panel", p)
	main.settings.add_child(frame)
	if p.has_method("opened"):
		p.opened()
	p.hints_changed.connect(func(h): _hints(h))
	await frames(3)
	var chain: Array = p.focus_chain()
	if not chain.is_empty():
		chain[mini(focus_index, chain.size() - 1)].grab_focus()
	_hints(p.hints())
	if shot_name != "":
		await shot(shot_name)
	return p


func _hints(h: Array) -> void:
	for c in main.hint_bar.get_children():
		c.queue_free()
	main.hint_bar.add_child(Kit.prompts(h if not h.is_empty() else [["B", "Back"]]))
