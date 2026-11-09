extends "res://tests/test_case.gd"
## Every command the installer builds, and the task lists per action. Nothing runs.

const C := preload("res://scripts/installer/commands.gd")
const Paths := preload("res://scripts/installer/paths.gd")
const Plan := preload("res://scripts/installer/plan.gd")
const F := preload("res://tests/fixtures/installer/fakes.gd")


func _ids(tasks: Array) -> Array:
	return tasks.map(func(t): return str(t["id"]) + ("" if t["fix"] == "" else ":" + t["fix"]))


func _choices(target: Dictionary) -> Dictionary:
	return Plan.start(target, F.claw().profile, {}).choices


func test_rpm_ostree_commands() -> void:
	eq(C.rpm_install("/dl/g.rpm"), ["pkexec", "rpm-ostree", "install", "--idempotent", "--apply-live", "/dl/g.rpm"])
	eq(C.rpm_install("/dl/g.rpm", false), ["pkexec", "rpm-ostree", "install", "--idempotent", "/dl/g.rpm"])
	eq(C.rpm_uninstall(), ["pkexec", "rpm-ostree", "uninstall", "gamecove"])
	eq(C.rpm_update("/dl/n.rpm"), ["pkexec", "rpm-ostree", "uninstall", "gamecove", "--install", "/dl/n.rpm"])


func test_sysext_commands() -> void:
	var c := C.sysext_install("/dl/g.raw")
	eq(c.slice(0, 3), ["pkexec", "sh", "-c"])
	eq(c.slice(4), ["sh", "/dl/g.raw"], "the image path is an argument, never pasted into the script")
	ok("/var/lib/extensions/gamecove.raw" in c[3])
	ok("systemd-sysext refresh" in c[3])
	ok("steamos-readonly" not in c[3], "/var is writable: no read-only toggling")
	var r := C.sysext_remove()
	ok("rm -f /var/lib/extensions/gamecove.raw" in r[3])
	ok("systemd-sysext refresh" in r[3])


func test_session_and_misc_commands() -> void:
	eq(C.session_default("/usr/bin/gamecove-session-select", "gamecove"), ["/usr/bin/gamecove-session-select", "gamecove", "--default", "--no-switch"])
	eq(C.session_default("/usr/bin/gamecove-session-select", "steam"), ["/usr/bin/gamecove-session-select", "steam", "--default", "--no-switch"])
	eq(C.session_restore(), ["steamosctl", "set-default-login-mode", "game"])
	eq(C.fix("/usr/libexec/gamecove/gamecove-fix", "claw8ex-vrr", "install"), ["pkexec", "/usr/libexec/gamecove/gamecove-fix", "claw8ex-vrr", "install"])
	eq(C.game_check()[0], "pgrep")
	eq(C.reboot(), ["systemctl", "reboot"])


func test_install_tasks_bazzite() -> void:
	var t := F.target("bazzite")
	var tasks := C.tasks_for("install", _choices(t), t, Paths.for_home("/h"))
	eq(_ids(tasks), ["check_game", "package", "fix_install:claw8ex-buttons", "fix_install:claw8ex-vrr", "fix_install:claw8ex-gyro",
		"user_files", "pending", "apply_now", "state"])
	var pkg: Dictionary = tasks[1]
	ok(pkg["privileged"], "package needs pkexec")
	eq(pkg["undo"], C.rpm_uninstall(), "package can be undone")
	eq(pkg["fallback"], C.rpm_install(t["package"], false), "staged install when live apply fails")
	ok(tasks[2]["needs_live"], "fixes wait for the package")
	eq(tasks[2]["undo"], ["pkexec", "/usr/libexec/gamecove/gamecove-fix", "claw8ex-buttons", "remove"])
	eq(tasks[7]["cmd"], ["/usr/libexec/gamecove/gamecove-apply-choices"])
	ok(tasks[7]["optional"] and tasks[7]["needs_live"])


func test_install_tasks_steamos_and_other() -> void:
	var t := F.target("steamos")
	var c := _choices(t)
	c["fixes"] = []
	var tasks := C.tasks_for("install", c, t, Paths.for_home("/h"))
	eq(_ids(tasks), ["check_game", "package", "user_files", "pending", "apply_now", "state"])
	eq(tasks[1]["cmd"], C.sysext_install(t["package"]))
	eq(tasks[1]["undo"], C.sysext_remove())
	var o := F.target("other")
	var oc := _choices(o)
	oc["fixes"] = []
	eq(_ids(C.tasks_for("install", oc, o, Paths.for_home("/h"))), ["check_game", "user_files", "pending", "state"], "no package elsewhere")


func test_change_repair_update_uninstall_finish() -> void:
	var t := F.target("bazzite", {"installed": true, "state": {"fixes": ["claw8ex-buttons", "claw8ex-gyro"]}})
	var c := _choices(t)
	c["fixes"] = ["claw8ex-buttons", "claw8ex-vrr"]
	var p := Paths.for_home("/h")
	eq(_ids(C.tasks_for("change", c, t, p)), ["check_game", "fix_install:claw8ex-vrr", "fix_remove:claw8ex-gyro",
		"user_files", "pending", "apply_now", "state"], "change installs and removes only the difference")
	eq(_ids(C.tasks_for("repair", c, t, p)), ["check_game", "package", "fix_install:claw8ex-buttons", "fix_install:claw8ex-vrr",
		"user_files", "pending", "apply_now", "state"])
	var up := C.tasks_for("update", c, t, p)
	eq(_ids(up), ["check_game", "package_update", "user_files", "state"])
	eq(up[1]["cmd"], C.rpm_update(t["package"]))
	c["remove_fixes"] = true
	c["keep_settings"] = false
	var un := C.tasks_for("uninstall", c, t, p)
	eq(_ids(un), ["check_game", "session_restore", "fix_remove:claw8ex-buttons", "fix_remove:claw8ex-gyro", "package_remove",
		"remove_user_files", "remove_settings", "forget"])
	eq(un[1]["cmd"], C.session_restore())
	eq(un[4]["cmd"], C.rpm_uninstall())
	c["remove_fixes"] = false
	c["keep_settings"] = true
	eq(_ids(C.tasks_for("uninstall", c, t, p)), ["check_game", "session_restore", "package_remove", "remove_user_files", "forget"])
	c["fixes"] = ["claw8ex-vrr"]
	eq(_ids(C.tasks_for("finish", c, t, p)), ["check_game", "fix_install:claw8ex-vrr", "pending", "state"])
