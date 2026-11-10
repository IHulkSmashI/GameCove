extends "../screenshots/shoot_installer.gd"
## The installer on the showcase's MSI Claw 8 EX (Bazzite): welcome, the
## device step and the finished install. Shots: installer, installer_device,
## installer_done. SHOWCASE_THEME=light renders the light theme.


func _run() -> void:
	OS.low_processor_usage_mode = false
	F = load("res://tests/fixtures/installer/fakes.gd")
	Screen = load("res://scripts/ui/installer/installer_screen.gd")
	Plan = load("res://scripts/installer/plan.gd")
	Service = load("res://scripts/installer/installer_service.gd")
	Paths = load("res://scripts/installer/paths.gd")
	Commands = load("res://scripts/installer/commands.gd")
	ThemeLib = load("res://theme/gamecove_theme.gd")
	home = OS.get_cache_dir().path_join("gamecove-showcase-installer")
	var theme_id := OS.get_environment("SHOWCASE_THEME")
	if theme_id == "":
		theme_id = "cove"
	# The Claw as read live: Bazzite 45 (tools/devicematrix/overrides.json).
	var t: Dictionary = F.target("bazzite", {"os": {"name": "Bazzite 45", "family": "bazzite"},
		"release": {"tag": "v0.4.0", "version": "0.4.0", "os": "bazzite", "package": "/dl/gamecove-0.4.0-1.fc45.x86_64.rpm"},
		"package": "/dl/gamecove-0.4.0-1.fc45.x86_64.rpm"})
	await make(t, theme_id)
	await shot("installer")
	if want("installer_device"):
		at("device")
		await shot("installer_device")
	if want("installer_done"):
		at("summary")
		progress(["ok", "ok", "ok", "ok", "ok", "ok", "ok", "ok", "ok"], "ok")
		screen.installer.deferred_fixes = ["claw8ex-buttons", "claw8ex-vrr", "claw8ex-gyro"]
		screen.plan.ran = true
		screen.plan.step = "done"
		screen.show_step()
		screen.focus_first()
		await shot("installer_done")
	quit()
