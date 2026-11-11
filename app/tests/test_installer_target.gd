extends "res://tests/test_case.gd"
## OS detection for the installer (fixture roots), release.env, install state,
## version compare, user files, and the boot scene's argument check.

const Target := preload("res://scripts/installer/target.gd")
const Paths := preload("res://scripts/installer/paths.gd")
const UserFiles := preload("res://scripts/installer/user_files.gd")
const Boot := preload("res://scripts/installer/boot.gd")


func _home(n: String) -> String:
	var d := ProjectSettings.globalize_path("user://test_installer_target/" + n)
	UserFiles.remove_tree(d, ProjectSettings.globalize_path("user://test_installer_target"))
	DirAccess.make_dir_recursive_absolute(d)
	return d


func _detect(os_fixture: String, home: String) -> Dictionary:
	return Target.detect(Paths.for_home(home, fixture("system/os/" + os_fixture)), "/nonexistent")


func test_os_fixtures() -> void:
	var h := _home("os")
	var cases := {
		"bazzite_desktop": ["bazzite", "rpm-ostree", true],
		"bazzite_deck": ["bazzite", "rpm-ostree", true],
		"fedora_silverblue": ["fedora-atomic", "rpm-ostree", true],
		"steamos": ["steamos", "sysext", true],
		"arch": ["other", "none", false],
	}
	for k in cases:
		var t := _detect(k, h)
		eq([t["family"], t["method"], t["supported"]], cases[k], k)
		ok(not t["installed"] and not t["maintenance"], k + ": fresh")


func test_release_state_and_update() -> void:
	var h := _home("release")
	var p: RefCounted = Paths.for_home(h, fixture("system/os/bazzite_desktop"))
	DirAccess.make_dir_recursive_absolute(p.installer_dir() + "/packages")
	var pkg: String = p.installer_dir() + "/packages/gamecove-0.3.0-1.fc43.x86_64.rpm"
	FileAccess.open(pkg, FileAccess.WRITE).store_string("rpm")
	FileAccess.open(p.release_file(), FileAccess.WRITE).store_string("TAG=v0.3.0\nVERSION=0.3.0\nOS=bazzite\nPACKAGE=%s\n# note\nAPP=/x\n" % pkg)
	var t := Target.detect(p, "/nonexistent")
	eq(t["release"]["tag"], "v0.3.0")
	eq(t["package"], pkg)
	ok(not t["maintenance"])
	FileAccess.open(p.state_file(), FileAccess.WRITE).store_string(JSON.stringify({"version": "0.2.0", "stage": "staged", "method": "rpm-ostree"}))
	t = Target.detect(p, "/nonexistent")
	ok(t["staged"], "staged: installed, waiting for the reboot")
	ok(t["maintenance"])
	ok(t["update_available"], "0.3.0 > 0.2.0")
	FileAccess.open(p.release_file(), FileAccess.WRITE).store_string("TAG=v0.3.0\nPACKAGE=/gone.rpm\n")
	eq(Target.detect(p, "/nonexistent")["package"], "", "a missing download isn't offered")


func test_version_compare() -> void:
	ok(Target.newer("0.10.0", "0.9.1"))
	ok(Target.newer("v1.0", "0.9.9"))
	ok(not Target.newer("0.2.0", "0.2.0"))
	ok(not Target.newer("0.2.0", "0.2.1"))
	ok(Target.newer("0.2.0.1", "0.2.0"))


func test_pending_kv_never_runs_anything() -> void:
	var h := _home("kv")
	var f := h + "/pending"
	FileAccess.open(f, FileAccess.WRITE).store_string("STARTUP=gamecove\n# c\nbad line\nX=$(rm -rf ~)\n")
	eq(Target.read_kv(f), {"STARTUP": "gamecove", "X": "$(rm -rf ~)"}, "plain text, no shell")


func test_remove_tree_never_follows_a_linked_folder() -> void:
	var root := ProjectSettings.globalize_path("user://test_remove_tree_link")
	DirAccess.make_dir_recursive_absolute(root + "/data/elsewhere")
	DirAccess.make_dir_recursive_absolute(root + "/data/tools")
	var keep := FileAccess.open(root + "/data/elsewhere/keep.txt", FileAccess.WRITE)
	keep.store_string("mine")
	keep.close()
	OS.execute("ln", ["-sfn", root + "/data/elsewhere", root + "/data/tools/linked"])
	OS.execute("ln", ["-sfn", root + "/data/elsewhere", root + "/data/tools2"])
	ok(UserFiles.remove_tree(root + "/data/tools2", root + "/data"), "a linked folder is removed")
	ok(FileAccess.file_exists(root + "/data/elsewhere/keep.txt"), "but what it pointed at is kept")
	ok(UserFiles.remove_tree(root + "/data/tools", root + "/data"), "a tree with a link inside")
	ok(FileAccess.file_exists(root + "/data/elsewhere/keep.txt"), "keeps that too")
	UserFiles.remove_tree(root + "/data", root)


func test_desktop_dir_and_remove_tree_guard() -> void:
	var h := _home("dirs")
	var p: RefCounted = Paths.for_home(h)
	eq(p.desktop_dir(), h + "/Desktop")
	DirAccess.make_dir_recursive_absolute(h + "/.config")
	FileAccess.open(h + "/.config/user-dirs.dirs", FileAccess.WRITE).store_string("XDG_DESKTOP_DIR=\"$HOME/Schreibtisch\"\n")
	eq(p.desktop_dir(), h + "/Schreibtisch")
	ok(not UserFiles.remove_tree("/", "/"), "never the root")
	ok(not UserFiles.remove_tree(h + "/../x", h), "no ..")
	ok(not UserFiles.remove_tree("/etc", h), "only below the given folder")


func test_boot_picks_the_scene() -> void:
	eq(Boot.scene_for(PackedStringArray(["--installer"])), Boot.INSTALLER)
	eq(Boot.scene_for(PackedStringArray([])), Boot.MAIN)
	eq(Boot.scene_for(PackedStringArray(["--fullscreen"])), Boot.MAIN)
	ok(ResourceLoader.exists(Boot.INSTALLER) and ResourceLoader.exists(Boot.MAIN))
	var h := _home("boot")
	ok(not Boot.apply_pending(Paths.for_home(h, h)), "nothing pending, nothing runs")


func test_launcher_default_goal() -> void:
	var h := _home("launcher")
	var L: Node = load("res://scripts/launch/launcher.gd").new()
	L.settings_path = h + "/launch.json"
	L.device_profile = {"id": "x", "gpu_family": "intel-xe2"}
	eq(L.settings_for("steam:1")["goal"], "balanced")
	ok(not L.set_default_goal("turbo"))
	ok(L.set_default_goal("smooth"))
	eq(L.settings_for("steam:1")["goal"], "smooth", "Auto TDP off for every game")
	ok(not L.auto_tdp_for("steam:1"))
	L.reload()
	eq(L.default_goal(), "smooth", "saved")
	L.save_settings("steam:2", {"goal": "battery"})
	eq(L.settings_for("steam:2")["goal"], "battery", "a game's own goal still wins")
	L.free()
