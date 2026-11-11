extends SceneTree
## Renders every installer step with fake services (nothing real runs):
##   SHOOT_SCRIPT=shoot_installer.gd tools/screenshots/shoot.sh /tmp/shots 1280x800
## Shots: installer_welcome, installer_startup, installer_steam, installer_stores,
## installer_signin, installer_device, installer_look, installer_extras,
## installer_summary, installer_progress, installer_failed, installer_done,
## installer_maintenance, installer_uninstall, installer_uninstall_backups, installer_finish, installer_welcome_steamos,
## installer_welcome_other, installer_welcome_light.

var out := "/tmp/gamecove-shots/"
var only: Array = []
var suffix := ""
var F: GDScript
var Screen: GDScript
var Plan: GDScript
var Service: GDScript
var Paths: GDScript
var Commands: GDScript
var ThemeLib: GDScript
var screen: Control
var home := "/tmp/gamecove-shots/installer-home"


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


func want(name: String) -> bool:
	return only.is_empty() or name in only


func shot(name: String) -> void:
	if not want(name):
		return
	await frames(30)
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(out)
	root.get_texture().get_image().save_png(out + name + suffix + ".png")
	print("saved ", out + name + suffix + ".png")


## A fake runner: every command works, no game is running.
class OkRunner extends RefCounted:
	func run(program: String, _args: PackedStringArray) -> Dictionary:
		return {"code": 1 if program == "pgrep" else 0, "out": ""}

	func stream(_program: String, _args: PackedStringArray, on_line: Callable) -> int:
		on_line.call("ok")
		return 0


func make(target: Dictionary, theme_id := "cove") -> void:
	if screen != null:
		root.remove_child(screen)
		screen.free()
	ThemeLib.use(theme_id)
	var dev = F.claw()
	if target.get("family", "") == "steamos":
		dev = F.FakeDevice.new()
		dev.profile = {"id": "steam-deck-oled", "name": "Steam Deck OLED", "support": "full", "fixes": [], "tdp": {}, "charge_limit": true}
	elif target.get("family", "") == "other":
		dev = F.FakeDevice.new()
		dev.profile = {"id": "unknown", "name": "Handheld", "support": "generic", "fixes": []}
	var p = Plan.start(target, dev.profile, {"theme": theme_id})
	var inst = Service.new()
	inst.setup(OkRunner.new(), Paths.for_home(home), target, "/opt/gamecove/gamecove.x86_64")
	screen = Screen.create(F.services(dev, F.FakeSetup.new(), F.Recorder.new(), home + "/power.cfg"), target, p, inst)
	screen.theme = ThemeLib.build()
	root.add_child(screen)
	await frames(2)


func at(step: String, mode := "custom") -> void:
	screen.plan.set_mode(mode)
	screen.plan.step = step
	screen.show_step()
	screen.focus_first()


## Freezes the progress page mid-run (no commands start).
func progress(results: Array, state := "running", msg := "") -> void:
	screen._started_action = screen.plan.action()
	screen.installer.tasks = Commands.tasks_for(screen.plan.action(), screen.plan.choices, screen.target, screen.installer.paths)
	var r: Array = []
	for i in screen.installer.tasks.size():
		r.append(results[i] if i < results.size() else "")
	screen.installer.results = r
	screen._run_state = state
	screen._run_message = msg
	screen.plan.step = "progress"
	screen.show_step()
	screen.focus_first()


func _run() -> void:
	OS.low_processor_usage_mode = false
	F = load("res://tests/fixtures/installer/fakes.gd")
	Screen = load("res://scripts/ui/installer/installer_screen.gd")
	Plan = load("res://scripts/installer/plan.gd")
	Service = load("res://scripts/installer/installer_service.gd")
	Paths = load("res://scripts/installer/paths.gd")
	Commands = load("res://scripts/installer/commands.gd")
	ThemeLib = load("res://theme/gamecove_theme.gd")
	var t: Dictionary = F.target("bazzite")
	await make(t)
	await shot("installer_welcome")
	for s in ["startup", "steam", "stores", "device", "look", "art", "extras", "summary"]:
		if want("installer_" + s):
			at(s)
			await shot("installer_" + s)
	if want("installer_signin"):
		at("stores")
		screen.open_sign_in("gog")
		await shot("installer_signin")
	if want("installer_progress"):
		at("summary")
		progress(["ok", "ok", "pending", "running"])
		screen.installer.results[2] = "pending"
		await shot("installer_progress")
	if want("installer_failed"):
		at("summary")
		progress(["ok", "failed"], "failed", "no_password")
		await shot("installer_failed")
	if want("installer_done"):
		at("summary")
		progress(["ok", "ok", "pending", "pending", "pending", "ok", "ok", "pending", "ok"], "ok")
		screen.installer.deferred_fixes = ["claw8ex-buttons", "claw8ex-vrr", "claw8ex-gyro"]
		screen.plan.ran = true
		screen.plan.step = "done"
		screen.show_step()
		screen.focus_first()
		await shot("installer_done")
	var installed: Dictionary = F.target("bazzite", {"installed": true, "maintenance": true, "update_available": true,
		"release": {"tag": "v0.3.0", "version": "0.3.0", "os": "bazzite", "package": "/dl/gamecove-0.3.0.rpm"},
		"state": {"version": "0.2.0", "method": "rpm-ostree", "stage": "live", "fixes": ["claw8ex-buttons", "claw8ex-vrr"]}})
	if want("installer_maintenance") or want("installer_uninstall"):
		await make(installed)
		await shot("installer_maintenance")
		at("uninstall", "uninstall")
		await shot("installer_uninstall")
		# "Keep my settings" off with save backups on disk: their own switch, with count and size
		var user := home + "/userdata/GameCove"
		for g in ["epic_hades", "gog_witcher3", "epic_alanwake2"]:
			DirAccess.make_dir_recursive_absolute(user + "/saves/backups/" + g)
			for stamp in ["20261108-201500", "20261109-221000"]:
				FileAccess.open(user + "/saves/backups/%s/%s.json" % [g, stamp], FileAccess.WRITE).store_string("{}")
				var f := FileAccess.open(user + "/saves/backups/%s/%s-0.tar.gz" % [g, stamp], FileAccess.WRITE)
				f.store_buffer(PackedByteArray().duplicate())
				f.resize(7 * 1024 * 1024)
		screen.installer.user_dir = user
		screen.plan.set_choice("keep_settings", false)
		screen.show_step()
		screen.focus_first()
		await shot("installer_uninstall_backups")
	if want("installer_finish"):
		await make(F.target("bazzite", {"installed": true, "maintenance": true, "pending": {"FIXES": "claw8ex-vrr,claw8ex-gyro"},
			"state": {"version": "0.2.0", "method": "rpm-ostree", "stage": "live", "fixes": []}}))
		await shot("installer_finish")
	if want("installer_welcome_steamos"):
		await make(F.target("steamos"))
		await shot("installer_welcome_steamos")
	if want("installer_welcome_other"):
		await make(F.target("other"))
		await shot("installer_welcome_other")
	if want("installer_welcome_light"):
		await make(t, "light")
		await shot("installer_welcome_light")
	quit()
