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
	var ri := C.rpm_install("/dl/g.rpm")
	eq([ri[0], ri[1], ri[2], ri[4], ri[5]], ["pkexec", "sh", "-c", "sh", "/dl/g.rpm"], "one root command, the package path as an argument")
	ok(ri[3].begins_with("set -e; rpm-ostree install --idempotent --apply-live \"$1\"; "), "the layer first: " + ri[3])
	ok(C.rpm_install("/dl/g.rpm", false)[3].begins_with("set -e; rpm-ostree install --idempotent \"$1\"; "), "staged when live apply isn't possible")
	ok(ri[3].ends_with(C.GUARD_INSTALL), "then the autologin guard into /etc (Bazzite too)")
	ok(C.rpm_uninstall()[3].ends_with("exec rpm-ostree uninstall gamecove") and C.rpm_uninstall()[3].contains("rm -f /etc/systemd/system/multi-user.target.wants/gamecove-autologin-guard.service"), "uninstall takes the guard along")
	eq(C.rpm_update("/dl/n.rpm"), ["pkexec", "rpm-ostree", "uninstall", "gamecove", "--install", "/dl/n.rpm"])


func test_the_root_step_checks_the_package_again_on_its_own_copy() -> void:
	var rpm := C.rpm_install("/dl/g.rpm", true, "abc")
	eq([rpm[0], rpm[1], rpm[2], rpm[4], rpm[5], rpm[6]], ["pkexec", "sh", "-c", "sh", "/dl/g.rpm", "abc"], "the path and the hash are arguments")
	ok(rpm[3].contains("sha256sum -c -") and rpm[3].contains("rpm-ostree install --idempotent --apply-live \"$1\""), "it checks, then installs")
	ok(rpm[3].find("sha256sum") < rpm[3].find("rpm-ostree"), "the check comes first")
	ok(rpm[3].contains("set -- \"$d/gamecove.rpm\""), "and installs the copy it checked, not the original")
	ok(C.rpm_update("/dl/n.rpm", "abc")[3].contains("sha256sum -c -"), "an update too")
	ok(C.sysext_install("/dl/g.raw", "abc")[3].contains("sha256sum -c -"), "and the sysext")
	eq(C.rpm_install("/dl/g.rpm"), C.rpm_install("/dl/g.rpm", true, ""), "no hash (an older release.env): as before")


## Runs the real script text on a temp copy: a matching package is used from a private copy, a changed one is refused.
func test_a_changed_package_is_refused_before_anything_runs() -> void:
	var dir := ProjectSettings.globalize_path("user://test_checked_pkg")
	DirAccess.make_dir_recursive_absolute(dir)
	var pkg := dir.path_join("g.rpm")
	var f := FileAccess.open(pkg, FileAccess.WRITE)
	f.store_string("the package")
	f.close()
	var sha := FileAccess.get_sha256(pkg)
	# the script text goes through a file: `sh file args` is the same program as `sh -c text sh args`, and this way
	# nothing between the test and sh can touch the $1 and $d in it
	var script_file := dir.path_join("check.sh")
	f = FileAccess.open(script_file, FileAccess.WRITE)
	f.store_string(C._checked("set -e; cat \"$1\"; echo; echo ran", "gamecove.rpm"))
	f.close()
	var out := []
	eq(OS.execute("sh", [script_file, pkg, sha], out, true), 0, "the right hash goes on: " + str(out))
	ok(str(out[0]).contains("the package") and str(out[0]).contains("ran"), "and works on the copy")
	out.clear()
	f = FileAccess.open(pkg, FileAccess.WRITE)
	f.store_string("swapped")
	f.close()
	ok(OS.execute("sh", [script_file, pkg, sha], out) != 0, "a package changed since it was checked is refused")
	ok(not str(out[0]).contains("ran"), "and nothing after the check ran")
	DirAccess.remove_absolute(pkg)
	DirAccess.remove_absolute(script_file)
	DirAccess.remove_absolute(dir)


func test_sysext_commands() -> void:
	var c := C.sysext_install("/dl/g.raw")
	eq(c.slice(0, 3), ["pkexec", "sh", "-c"])
	eq(c.slice(4), ["sh", "/dl/g.raw"], "the image path is an argument, never pasted into the script")
	ok("/var/lib/extensions/gamecove.raw" in c[3], "non-SteamOS sysext systems: /var/lib/extensions")
	ok("systemd-sysext refresh" in c[3])
	ok("steamos-readonly" not in c[3], "no read-only toggling: the image never goes into /usr")
	# SteamOS: image on /home (root-owned offload folder), linked from /etc/extensions,
	# both links in an atomic-update keep list so an OS update keeps GameCove
	ok("/home/.steamos/offload/gamecove/gamecove.raw" in c[3])
	ok("ln -sfn /home/.steamos/offload/gamecove/gamecove.raw /etc/extensions/gamecove.raw" in c[3])
	ok("/etc/atomic-update.conf.d/gamecove.conf" in c[3])
	ok("sysinit.target.wants/systemd-sysext.service" in c[3], "the enable link is kept across updates too")
	ok("systemctl enable systemd-sysext.service" in c[3])
	var r := C.sysext_remove()
	ok("rm -f /etc/extensions/gamecove.raw /var/lib/extensions/gamecove.raw /etc/atomic-update.conf.d/gamecove.conf" in r[3])
	ok("/home/.steamos/offload/gamecove/gamecove.raw" in r[3])
	ok("systemd-sysext refresh" in r[3])
	# review L25: turned off again only if GameCove turned it on and no other extension is left
	ok("if ! systemctl is-enabled -q systemd-sysext.service 2>/dev/null; then mkdir -p /etc/gamecove && : > /etc/gamecove/sysext-enabled; fi" in c[3], "remembers it was off")
	ok("if [ -f /etc/gamecove/sysext-enabled ]; then" in r[3] and "systemctl disable systemd-sysext.service" in r[3], "off again only then")
	ok(r[3].find("for e in /etc/extensions/* /var/lib/extensions/*") < r[3].find("systemctl disable"), "...and only with no other extension")
	ok(r.size() == 5 and "rm -rf /var/lib/gamecove" in r[3] and "\"${1:-}\" = purge" in r[3], "state only with purge")
	eq(C.sysext_remove(true).back(), "purge")
	var rr := C.rpm_remove(true)
	eq(rr[0], "pkexec")
	ok(rr[3].begins_with("rm -rf /var/lib/gamecove && ") and rr[3].ends_with("exec rpm-ostree uninstall gamecove"), "rpm-ostree: state, then the layer, one password")
	eq(C.rpm_remove(false), C.rpm_uninstall(), "fixes kept: their state stays too")


func test_session_and_misc_commands() -> void:
	eq(C.session_default("/usr/bin/gamecove-session-select", "gamecove"), ["/usr/bin/gamecove-session-select", "gamecove", "--default", "--no-switch"])
	eq(C.session_default("/usr/bin/gamecove-session-select", "steam"), ["/usr/bin/gamecove-session-select", "steam", "--default", "--no-switch"])
	var rs := C.session_restore()
	eq(rs.slice(0, 2), ["sh", "-c"], "restore runs as a small shell step")
	eq(rs[-1], "/usr/bin/gamecove-session-select", "installed switcher is the second choice")
	ok("restore" in rs[2] and "set-default-desktop-session" in rs[2], "restores the desktop session, not only the login mode")
	ok("set-default-login-mode game" in rs[2], "and the boot mode")
	eq(C.fix("/usr/libexec/gamecove/gamecove-fix", "claw8ex-vrr", "install"), ["pkexec", "/usr/libexec/gamecove/gamecove-fix", "claw8ex-vrr", "install"])
	eq(C.game_check()[0], "pgrep")
	eq(C.reboot(), ["systemctl", "reboot"])


func test_install_tasks_bazzite() -> void:
	var t := F.target("bazzite")
	var tasks := C.tasks_for("install", _choices(t), t, Paths.for_home("/h"))
	eq(_ids(tasks), ["check_game", "package", "fix_install:claw8ex-buttons", "fix_install:claw8ex-vrr", "fix_install:claw8ex-gyro",
		"fix_install:claw-kbd-wakeup", "user_files", "pending", "apply_now", "state"])
	var pkg: Dictionary = tasks[1]
	ok(pkg["privileged"], "package needs pkexec")
	eq(pkg["undo"], C.rpm_uninstall(), "package can be undone")
	eq(pkg["fallback"], C.rpm_install(t["package"], false), "staged install when live apply fails")
	ok(tasks[2]["needs_live"], "fixes wait for the package")
	eq(tasks[2]["undo"], ["pkexec", "/usr/libexec/gamecove/gamecove-fix", "claw8ex-buttons", "remove"])
	eq(tasks[8]["cmd"], ["/usr/libexec/gamecove/gamecove-apply-choices"])
	ok(tasks[8]["optional"] and tasks[8]["needs_live"])


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
	eq(_ids(un), ["check_game", "session_restore", "steam_unwrap", "fix_remove_all", "upscale_purge", "package_remove",
		"remove_user_files", "remove_settings", "forget"])
	eq(un[3]["cmd"], ["pkexec", p.fix_helper(), "--remove-all"], "every fix in use, not only the installer's (review S2-5)")
	eq(un[1]["cmd"], C.session_restore(p))
	eq(un[1]["cmd"][4], p.data_dir() + "/gamecove-session-guard", "the copy that survives the package goes first")
	eq(un[4]["cmd"], C.upscale_purge(p.upscale_helper(), p.home), "our upscaler files leave the games before the package goes")
	ok(not un[4]["privileged"] and un[4]["optional"], "as the user; a game that can't be put back doesn't stop the uninstall")
	eq(un[5]["cmd"], C.rpm_remove(true), "fixes undone: /var/lib/gamecove goes with the layer (review L25)")
	ok(un[2]["optional"], "taking GameCove out of Steam's launch options never stops an uninstall")
	ok(not un[1]["optional"], "review H4: the boot default must be restored before the package goes")
	ok(not un[3]["optional"], "review H4: every fix undone before the helper that undoes them goes")
	c["remove_fixes"] = false
	c["keep_settings"] = true
	var kept := C.tasks_for("uninstall", c, t, p)
	eq(_ids(kept), ["check_game", "session_restore", "steam_unwrap", "upscale_purge", "package_remove", "remove_user_files", "forget"])
	eq(kept[4]["cmd"], C.rpm_uninstall(), "fixes kept: their state stays")
	c["fixes"] = ["claw8ex-vrr"]
	eq(_ids(C.tasks_for("finish", c, t, p)), ["check_game", "fix_install:claw8ex-vrr", "pending", "state"])


## The Fixes page's Undo sticks: repair doesn't put back a fix the user turned off there.
func test_repair_skips_fixes_the_user_undid() -> void:
	var t := F.target("bazzite", {"installed": true, "state": {"fixes": ["claw8ex-buttons", "claw8ex-gyro"]},
		"fix_choices": {"msi-claw-8-ex": {"claw8ex-gyro": "off", "claw8ex-buttons": "on"}, "asus-rog-ally": {"claw8ex-vrr": "off"}}})
	var c := _choices(t)
	ok(not "claw8ex-gyro" in c["fixes"], "undone on this handheld: left off")
	ok("claw8ex-buttons" in c["fixes"] and "claw8ex-vrr" in c["fixes"], "other fixes and other handhelds' choices untouched")
	var ids := _ids(C.tasks_for("repair", c, t, Paths.for_home("/h")))
	ok(not "fix_install:claw8ex-gyro" in ids, "repair doesn't reinstall it: %s" % [ids])


func test_target_reads_the_fixes_page_choices() -> void:
	var dir := OS.get_temp_dir().path_join("gc_fixcfg_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	var cfg := ConfigFile.new()
	cfg.set_value("fixes@msi-claw-8-ex", "claw8ex-gyro", "off")
	cfg.set_value("other", "x", 1)
	cfg.save(dir.path_join("fixes.cfg"))
	eq(load("res://scripts/installer/target.gd").read_fix_choices(dir.path_join("fixes.cfg")), {"msi-claw-8-ex": {"claw8ex-gyro": "off"}})
	eq(load("res://scripts/installer/target.gd").read_fix_choices(dir.path_join("none.cfg")), {})


## The XeSS XMX driver is an installer option on Intel Arc handhelds with XMX only (same install as ClawDeck's).
func test_xess_driver_option() -> void:
	var t := F.target("bazzite")
	var claw := Plan.start(t, F.claw().profile, {})
	ok(claw.xess_offered, "offered on the Claw 8 EX (Xe2 XMX)")
	eq(claw.choices["xess_driver"], false, "off unless the user picks it")
	ok(claw.set_choice("xess_driver", true), "can be picked")
	var amd := Plan.start(t, {"id": "asus-rog-ally", "cpu_vendor": "amd", "xmx": false, "fixes": []}, {})
	ok(not amd.xess_offered and not amd.set_choice("xess_driver", true), "never offered on AMD")
	var p := Paths.for_home("/h")
	var tasks := C.tasks_for("install", claw.choices, t, p)
	var x: Array = tasks.filter(func(k): return k["id"] == "xess_install")
	eq(x.size(), 1, "one install task")
	eq(x[0]["cmd"], ["/usr/libexec/gamecove/gamecove-upscale", "xess-install", "--home", "/h", "--gpu", "vendor=intel,xmx=1"])
	ok(not x[0]["privileged"] and x[0]["needs_live"] and x[0]["optional"], "as the user, after the package is live, never fatal")
	var had := F.target("bazzite", {"installed": true, "state": {"choices": {"xess_driver": true}}})
	var c: Dictionary = claw.choices.duplicate()
	ok(_ids(C.tasks_for("change", c, had, p)).filter(func(i): return i.begins_with("xess")).is_empty(), "already there: change leaves it")
	c["xess_driver"] = false
	ok("xess_remove" in _ids(C.tasks_for("change", c, had, p)), "turned off in change: removed")
	var un: Array = C.tasks_for("uninstall", c, had, p)
	ok("upscale_purge" in _ids(un) and not "xess_remove" in _ids(un), "uninstall takes it out with everything else of upscaling")
	eq(C.upscale_purge(p.upscale_helper(), p.home), [p.upscale_helper(), "purge", "--home", p.home], "as the user, no pkexec")
	ok(_ids(un).find("upscale_purge") < _ids(un).find("package_remove"), "while the helper is still installed")
	ok(load("res://scripts/ui/installer/texts_installer.gd").task_title({"id": "upscale_purge"}) != "upscale_purge", "the step has a plain title")


## Review H4: the root autologin guard is copied out of the sysext into /etc (kept across OS
## updates) and removed with it.
func test_sysext_installs_the_autologin_guard_into_etc() -> void:
	ok(C.SYSEXT_INSTALL.contains("install -D -m 0755 \"$src/gamecove-autologin-guard\" /etc/gamecove/autologin-guard"), "script copied into /etc")
	ok(C.SYSEXT_INSTALL.contains("ln -sfn " + C.GUARD_UNIT + " " + C.GUARD_LINK), "unit enabled")
	ok(C.SYSEXT_INSTALL.contains(C.GUARD_SCRIPT + " " + C.GUARD_UNIT + " " + C.GUARD_LINK + " " + C.SYSEXT_ENABLED_MARK + " > " + C.SYSEXT_KEEP), "kept across SteamOS updates")
	for f in [C.GUARD_LINK, C.GUARD_UNIT, C.GUARD_SCRIPT]:
		ok(C.SYSEXT_REMOVE.contains(f), "removed with GameCove: " + f)



## Final review: (session) Bazzite got no root autologin guard, so `rpm-ostree uninstall gamecove` by
## hand with GameCove as the boot default left the login screen at a password prompt; (low) the
## SteamOS install ended the guard's copy in `|| true`, hiding a failure. The copy runs for real
## here, against a temp folder standing in for / (systemctl isn't there to call).
func _guard_run(root: String) -> int:
	var text: String = C.GUARD_INSTALL.replace("/ostree/deploy/*/deploy/*/usr/lib/gamecove/session", "@STAGED@") \
		.replace("/usr/lib/gamecove/session", root + "/usr/lib/gamecove/session").replace("/etc/", root + "/etc/") \
		.replace("@STAGED@", root + "/ostree/deploy/*/deploy/*/usr/lib/gamecove/session")
	var script := root + "/guard-install.sh"
	FileAccess.open(script, FileAccess.WRITE).store_string("set -e\nsystemctl() { return 1; }\n" + text + "\n")
	return int(preload("res://scripts/system/exec_safe.gd").run("sh", PackedStringArray([script])).get("code", -1))


func _guard_root(n: String, src: String) -> String:
	var root := ProjectSettings.globalize_path("user://test_installer_guard/" + n)
	preload("res://scripts/installer/user_files.gd").remove_tree(root, ProjectSettings.globalize_path("user://test_installer_guard"))
	DirAccess.make_dir_recursive_absolute(root + "/etc")
	if src != "":
		DirAccess.make_dir_recursive_absolute(root + src)
		FileAccess.open(root + src + "/gamecove-autologin-guard", FileAccess.WRITE).store_string("#!/bin/sh\n# from " + src + "\n")
		FileAccess.open(root + src + "/gamecove-autologin-guard.service", FileAccess.WRITE).store_string("[Unit]\n")
	return root


func test_autologin_guard_install_runs_for_real() -> void:
	var live := _guard_root("live", "/usr/lib/gamecove/session")
	eq(_guard_run(live), 0, "live package: copied from /usr")
	ok(FileAccess.get_file_as_string(live + "/etc/gamecove/autologin-guard").contains("from /usr/lib/gamecove/session"), "the script is in /etc")
	ok(FileAccess.file_exists(live + "/etc/systemd/system/gamecove-autologin-guard.service"), "the unit too")
	var link := DirAccess.open(live + "/etc/systemd/system/multi-user.target.wants")
	ok(link != null and link.is_link("gamecove-autologin-guard.service"), "and it is enabled")
	var staged := _guard_root("staged", "/ostree/deploy/default/deploy/abc123.0/usr/lib/gamecove/session")
	eq(_guard_run(staged), 0, "package only staged for the next boot: copied from the new deployment")
	ok(FileAccess.get_file_as_string(staged + "/etc/gamecove/autologin-guard").contains("from /ostree/deploy/default/deploy/abc123.0"), "taken from the staged deployment")
	var none := _guard_root("none", "")
	ok(_guard_run(none) != 0, "no guard to copy: the install step fails instead of hiding it")
	ok(not FileAccess.file_exists(none + "/etc/gamecove/autologin-guard"), "and nothing half-made is left")
	# both installs use it, with nothing after it that could hide a failure
	ok(C.SYSEXT_INSTALL.contains(C.GUARD_INSTALL + "; systemctl reload polkit.service"), "SteamOS install: the same copy, under set -e")
	ok(not C.SYSEXT_INSTALL.contains(C.GUARD_UNIT + " && "), "no && chain ending in || true")
	ok(C.SYSEXT_INSTALL.begins_with("set -e; ") and C.rpm_install("/x.rpm")[3].begins_with("set -e; "), "both stop on a failed step")
