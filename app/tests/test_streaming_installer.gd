extends "res://tests/test_case.gd"
## The installer's optional Moonlight install (Extras): a user Flatpak, no
## password, never fatal; change doesn't install twice or remove it.

const C := preload("res://scripts/installer/commands.gd")
const Paths := preload("res://scripts/installer/paths.gd")
const Plan := preload("res://scripts/installer/plan.gd")
const F := preload("res://tests/fixtures/installer/fakes.gd")


func test_moonlight_option() -> void:
	var t := F.target("bazzite")
	var plan := Plan.start(t, F.claw().profile, {})
	eq(plan.choices["moonlight"], false, "off unless picked")
	ok(plan.set_choice("moonlight", true), "can be picked")
	ok(not plan.set_choice("moonlight", "yes"), "bool only")
	var p := Paths.for_home("/h")
	var tasks := C.tasks_for("install", plan.choices, t, p)
	var m: Array = tasks.filter(func(k): return str(k["id"]).begins_with("moonlight"))
	eq(m.map(func(k): return k["id"]), ["moonlight_remote", "moonlight_install"], "remote, then the app")
	eq(m[1]["cmd"], ["flatpak", "install", "--user", "--noninteractive", "-y", "flathub", "com.moonlight_stream.Moonlight"], "user install")
	ok(m.all(func(k): return not k["privileged"] and k["optional"]), "no pkexec, never fatal")
	eq(m[1]["undo"][1], "uninstall", "undo removes it")
	var had := F.target("bazzite", {"installed": true, "state": {"choices": {"moonlight": true}}})
	var ids: Array = C.tasks_for("change", plan.choices, had, p).map(func(k): return k["id"])
	ok(not "moonlight_install" in ids, "already installed: change leaves it")
	var off: Dictionary = plan.choices.duplicate()
	off["moonlight"] = false
	ok(C.tasks_for("install", off, t, p).all(func(k): return not str(k["id"]).begins_with("moonlight")), "not picked: nothing")
