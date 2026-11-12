extends "res://tests/test_case.gd"
## The Plasma virtual keyboard around the admin password dialog (device finding 12): on for KDE Wayland
## while the dialog is open, the old setting put back after. Fake runner, fake root; nothing real runs.

const RK := preload("res://scripts/installer/root_keyboard.gd")
const Fake := preload("res://tests/fixtures/system/fake_runner.gd")


func _root() -> String:
	var d := ProjectSettings.globalize_path("user://test_root_keyboard")
	DirAccess.make_dir_recursive_absolute(d + "/usr/share/applications")
	FileAccess.open(d + "/usr/share/applications/org.kde.plasma.keyboard.desktop", FileAccess.WRITE).store_string("[Desktop Entry]")
	return d


func test_only_on_kde_wayland() -> void:
	ok(RK.applies("KDE", "wayland"))
	ok(RK.applies("KDE:Plasma", "Wayland"))
	ok(not RK.applies("KDE", "x11"), "X11 types with the system's own tools")
	ok(not RK.applies("GNOME", "wayland"))
	var r := Fake.new()
	eq(RK.prepare(r, "GNOME", "wayland", _root())["on"], false)
	eq(r.calls, [], "nothing run elsewhere")


func test_switched_on_and_put_back() -> void:
	var root := _root()
	var r := Fake.new()
	r.responses = {"kreadconfig6 --file kwinrc --group Wayland --key InputMethod": {"code": 0, "out": "\n"}, "kwriteconfig6*": {"code": 0, "out": ""}, "qdbus6*": {"code": 0, "out": ""}}
	var st := RK.prepare(r, "KDE", "wayland", root)
	ok(st["on"] and st["changed"], "switched on")
	ok(r.called("kwriteconfig6 --file kwinrc --group Wayland --key InputMethod /usr/share/applications/org.kde.plasma.keyboard.desktop"), "the Plasma keyboard is the input method")
	ok(r.called("qdbus6 org.kde.KWin /KWin reconfigure"), "KWin reads it at once")
	RK.restore(r, st)
	ok(r.called("kwriteconfig6 --file kwinrc --group Wayland --key InputMethod --delete"), "it was unset before: unset again")


func test_already_on_is_left_alone_and_another_keyboard_is_restored() -> void:
	var root := _root()
	var r := Fake.new()
	r.responses = {"kreadconfig6*": {"code": 0, "out": "/usr/share/applications/org.kde.plasma.keyboard.desktop\n"}}
	var st := RK.prepare(r, "KDE", "wayland", root)
	ok(st["on"] and not st["changed"], "already on")
	RK.restore(r, st)
	ok(not r.called("kwriteconfig6"), "nothing written, nothing to put back")
	var r2 := Fake.new()
	r2.responses = {"kreadconfig6*": {"code": 0, "out": "/usr/share/applications/other.desktop\n"}, "kwriteconfig6*": {"code": 0, "out": ""}, "qdbus6*": {"code": 0, "out": ""}}
	var st2 := RK.prepare(r2, "KDE", "wayland", root)
	RK.restore(r2, st2)
	ok(r2.called("kwriteconfig6 --file kwinrc --group Wayland --key InputMethod /usr/share/applications/other.desktop"), "the user's own keyboard comes back")


func test_no_keyboard_installed_changes_nothing() -> void:
	var r := Fake.new()
	var st := RK.prepare(r, "KDE", "wayland", "/nonexistent-root")
	ok(not st["on"])
	eq(r.calls, [])
