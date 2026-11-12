extends "res://tests/test_case.gd"
## The installer service against a fake runner and a temp home: order of
## commands, files written, pending choices, the log, game check, password
## refusal, retry, undo, uninstall. Nothing real runs.

const Service := preload("res://scripts/installer/installer_service.gd")
const Paths := preload("res://scripts/installer/paths.gd")
const Plan := preload("res://scripts/installer/plan.gd")
const Target := preload("res://scripts/installer/target.gd")
const UserFiles := preload("res://scripts/installer/user_files.gd")
const SettingsWriter := preload("res://scripts/installer/settings_writer.gd")
const Fake := preload("res://tests/fixtures/system/fake_runner.gd")
const F := preload("res://tests/fixtures/installer/fakes.gd")
const UserData := preload("res://scripts/installer/user_data.gd")
const SteamGrid := preload("res://scripts/library/art/steam_grid.gd")


func _dir(n: String) -> String:
	var d := ProjectSettings.globalize_path("user://test_installer/" + n)
	UserFiles.remove_tree(d, ProjectSettings.globalize_path("user://test_installer"))
	DirAccess.make_dir_recursive_absolute(d + "/home")
	DirAccess.make_dir_recursive_absolute(d + "/root")
	return d


## Every command succeeds (exit 0) except the game check (no game: exit 1).
func _runner(overrides := {}) -> RefCounted:
	var r := Fake.new()
	r.handler = func(cmd: String):
		for k in overrides:
			if cmd.begins_with(k):
				return overrides[k]
		return {"code": 1, "out": ""} if cmd.begins_with("pgrep") else {"code": 0, "out": "done"}
	return r


func _make_live(d: String) -> void:
	for f in ["/root/usr/libexec/gamecove/gamecove-fix", "/root/usr/lib/gamecove/gamecove.x86_64"]:
		DirAccess.make_dir_recursive_absolute((d + f).get_base_dir())
		FileAccess.open(d + f, FileAccess.WRITE).store_string("x")


func _svc(d: String, runner: RefCounted, target: Dictionary) -> Node:
	var s: Node = Service.new()
	s.setup(runner, Paths.for_home(d + "/home", d + "/root"), target, "/opt/gc/gamecove.x86_64")
	s.user_dir = d + "/userdata/GameCove"   # never the real user:// (remove_settings deletes it)
	s._clock = func() -> String: return "2026-11-08T12:00:00Z"
	_nodes.append(s)
	return s


var _nodes: Array = []


func _cleanup() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()


func _choices(t: Dictionary) -> Dictionary:
	return Plan.start(t, F.claw().profile, {}).choices


func _cmds(r: RefCounted) -> Array:
	return Array(r.calls).filter(func(c): return not c.begins_with("pgrep"))


func test_staged_install_defers_fixes_and_session() -> void:
	var d := _dir("staged")
	var r := _runner()
	var t := F.target("bazzite")
	var s := _svc(d, r, t)
	var results := []
	s.finished.connect(func(a, ok_, m): results.append([a, ok_, m]))
	ok(s.start("install", _choices(t)))
	eq(results, [["install", true, ""]])
	eq(_cmds(r).size(), 1, "only the package ran: nothing is live")
	ok(_cmds(r)[0].begins_with("pkexec sh -c set -e; rpm-ostree install --idempotent --apply-live \"$1\"; ") and _cmds(r)[0].ends_with(" sh " + t["package"]), "the layer, live: " + _cmds(r)[0])
	ok(_cmds(r)[0].contains("/etc/gamecove/autologin-guard"), "with the autologin guard in the same root command")
	eq(s.results.count("pending"), 5, "four fixes and the startup choice wait for the reboot")
	eq(s.deferred_fixes, ["claw8ex-buttons", "claw8ex-vrr", "claw8ex-gyro", "claw-kbd-wakeup"])
	var p: RefCounted = s.paths
	var pending := Target.read_pending(p.pending_file())
	eq(pending, {"STARTUP": "gamecove", "SWITCH_NOW": "1", "FIXES": "claw8ex-buttons,claw8ex-vrr,claw8ex-gyro,claw-kbd-wakeup"})
	ok(FileAccess.file_exists(p.autostart_entry()), "installer opens itself in Desktop Mode after the reboot")
	ok("GAMECOVE_STEAM_MODE=silent" in FileAccess.get_file_as_string(p.env_conf()))
	ok("ConditionPathExists=/usr/libexec/gamecove/gamecove-apply-choices" in FileAccess.get_file_as_string(p.unit_file()))
	var wants := DirAccess.open(p.unit_link().get_base_dir())
	ok(wants != null and wants.is_link(p.unit_link().get_file()), "unit enabled for every login")
	ok("gamecove-session-select gamecove" in FileAccess.get_file_as_string(p.switch_entry()))
	ok(FileAccess.file_exists(p.window_entry()))
	ok(FileAccess.file_exists(p.installer_entry()))
	var st := Target.read_state(p.state_file())
	eq(st["stage"], "staged")
	eq(st["version"], "0.2.0")
	eq(st["fixes"], [], "no fix installed yet")
	eq(st["waiting_fixes"], ["claw8ex-buttons", "claw8ex-vrr", "claw8ex-gyro", "claw-kbd-wakeup"])
	eq(st["choices"]["startup"], "gamecove")
	ok(not st["choices"].has("ggdeals_key"), "keys stay out of the state file")
	var log := FileAccess.get_file_as_string(p.log_file())
	ok("$ pkexec sh -c <one root script for: package" in log, "the root steps are logged as one script")
	ok("rpm-ostree install" in log or "claw8ex-buttons" in log, "and name their steps: " + log.left(300))
	ok("install finished" in log)
	_cleanup()


func test_live_install_runs_fixes_and_applies_choices() -> void:
	var d := _dir("live")
	_make_live(d)
	var r := _runner()
	var t := F.target("steamos")
	var c := _choices(t)
	c["fixes"] = ["claw8ex-vrr"]
	c["charge_limit"] = 80
	var s := _svc(d, r, t)
	ok(s.start("install", c))
	var p: RefCounted = s.paths
	eq(_cmds(r), [
		"pkexec sh -c " + load("res://scripts/installer/commands.gd").SYSEXT_INSTALL + " sh " + t["package"],
		"pkexec " + p.fix_helper() + " claw8ex-vrr install",
		p.apply_helper(),
	])
	eq(Target.read_pending(p.pending_file()), {"STARTUP": "gamecove", "SWITCH_NOW": "1", "CHARGE_LIMIT": "80"})
	ok(not FileAccess.file_exists(p.autostart_entry()), "nothing waits for Desktop Mode")
	var st := Target.read_state(p.state_file())
	eq(st["stage"], "live")
	eq(st["fixes"], ["claw8ex-vrr"])
	_cleanup()


func test_refuses_during_a_game() -> void:
	var d := _dir("game")
	var r := _runner({"pgrep": {"code": 0, "out": "123"}})
	var t := F.target("bazzite")
	var s := _svc(d, r, t)
	var results := []
	s.finished.connect(func(a, ok_, m): results.append([a, ok_, m]))
	s.start("install", _choices(t))
	eq(results, [["install", false, "game_running"]])
	eq(_cmds(r), [], "nothing ran")
	eq(s.results[0], "failed")
	ok(not FileAccess.file_exists(s.paths.state_file()))
	var rb := []
	s.finished.connect(func(a, ok_, m): rb.append([a, ok_, m]))
	s.reboot()
	eq(rb[-1], ["reboot", false, "game_running"], "no restart during a game")
	ok(not r.called("systemctl reboot"))
	_cleanup()


func test_password_refused_then_retry_then_undo() -> void:
	var d := _dir("retry")
	var answers := {"pkexec sh -c set -e; rpm-ostree install": {"code": 126, "out": "Not authorized"}}
	var r := _runner(answers)
	var t := F.target("bazzite")
	var s := _svc(d, r, t)
	var results := []
	s.finished.connect(func(a, ok_, m): results.append([a, ok_, m]))
	s.start("install", _choices(t))
	eq(results[-1], ["install", false, "no_password"])
	eq(r.calls.filter(func(c): return c.begins_with("pkexec sh -c set -e; rpm-ostree install")).size(), 2, "live install, then the staged fallback")
	answers.clear()
	ok(s.retry(), "retry from the failed step")
	eq(results[-1], ["install", true, ""])
	ok(FileAccess.file_exists(s.paths.env_conf()))
	var undone := []
	s.undone.connect(func(o): undone.append(o))
	ok(s.undo())
	eq(undone, [true])
	ok(r.calls.any(func(c): return c.begins_with("pkexec sh -c rm -f /etc/systemd/system/multi-user.target.wants/gamecove-autologin-guard.service") and c.ends_with("exec rpm-ostree uninstall gamecove")), "package taken off again, the guard with it")
	ok(not FileAccess.file_exists(s.paths.env_conf()), "user files removed")
	ok(not FileAccess.file_exists(s.paths.pending_file()), "pending file removed")
	_cleanup()


func test_uninstall_restores_steam_and_cleans_up() -> void:
	var d := _dir("uninstall")
	_make_live(d)
	var t := F.target("bazzite", {"installed": true, "state": {"version": "0.2.0", "fixes": ["claw8ex-vrr"]}})
	var s := _svc(d, _runner(), t)
	s.start("install", _choices(t))
	ok(FileAccess.file_exists(s.paths.state_file()))
	var r := _runner()
	var s2 := _svc(d, r, t)
	var c := _choices(t)
	c["keep_settings"] = true
	# review L25: the session's leftovers and the bootstrap's cosign download
	var data: String = s2.paths.data_dir()
	DirAccess.make_dir_recursive_absolute(data + "/tools")
	for f in ["/crash-count", "/crash-fallback", "/left-for-steam", "/default-suspended", "/tools/cosign-v2.5.3"]:
		FileAccess.open(data + f, FileAccess.WRITE).store_string("x")
	s2.start("uninstall", c)
	var cmds := _cmds(r)
	eq(cmds.size(), 4)
	ok(cmds[0].begins_with("sh -c ") and "restore" in cmds[0], "session defaults restored first (desktop session too)")
	ok(cmds[0].ends_with(s2.paths.session_select()), "through the switcher when it's there")
	eq(cmds[1], "%s purge --home %s" % [s2.paths.upscale_helper(), s2.paths.home], "our upscaler files leave the games, as the user, while the helper is still there")
	eq(cmds[2], "pkexec " + s2.paths.fix_helper() + " --remove-all")
	eq(r.batches, 1, "one password for the fixes and the package (one pkexec)")
	ok(cmds[3].begins_with("pkexec sh -c rm -rf /var/lib/gamecove && ") and cmds[3].ends_with("exec rpm-ostree uninstall gamecove"), "the helper's state goes with the layer: " + cmds[3])
	for f in [s2.paths.env_conf(), s2.paths.unit_file(), s2.paths.switch_entry(), s2.paths.window_entry(),
			s2.paths.pending_file(), s2.paths.state_file(), data + "/crash-count", data + "/crash-fallback",
			data + "/left-for-steam", data + "/default-suspended"]:
		ok(not FileAccess.file_exists(f), "removed " + f)
	ok(not DirAccess.dir_exists_absolute(data + "/tools"), "cosign download removed")
	ok(FileAccess.file_exists(s2.paths.log_file()), "the log stays")
	_cleanup()


## Review L25: without "keep settings" the installer's app entry goes too (its script is deleted).
func test_uninstall_without_settings_removes_the_installer_entry() -> void:
	var d := _dir("uninstall_all")
	_make_live(d)
	var t := F.target("bazzite", {"installed": true, "state": {"version": "0.2.0", "fixes": []}})
	var s := _svc(d, _runner(), t)
	DirAccess.make_dir_recursive_absolute(s.paths.apps_dir())
	FileAccess.open(s.paths.installer_entry(), FileAccess.WRITE).store_string("[Desktop Entry]\n")
	DirAccess.make_dir_recursive_absolute(s.paths.data_dir() + "/launch")
	FileAccess.open(s.paths.data_dir() + "/launch/steam-42.env", FileAccess.WRITE).store_string("x")
	var c := _choices(t)
	c["keep_settings"] = false
	s.start("uninstall", c)
	ok(not FileAccess.file_exists(s.paths.installer_entry()), "installer entry removed")
	ok(not DirAccess.dir_exists_absolute(s.paths.data_dir() + "/launch"), "launch files removed")
	_cleanup()


## Final review, session: uninstall left ~/.config/environment.d/80-gamecove-display.conf, which every
## gamescope session reads: a rotation or refresh-rate unlock stayed in Steam Gaming Mode with nothing
## left to turn it off. It goes; "Keep my settings" keeps a copy that the next install puts back.
func test_uninstall_takes_the_display_session_file_away() -> void:
	for keep in [true, false]:
		var d := _dir("uninstall_display_%s" % keep)
		_make_live(d)
		var t := F.target("bazzite", {"installed": true, "state": {"version": "0.2.0", "fixes": []}})
		var s := _svc(d, _runner(), t)
		var conf: String = s.paths.display_env_conf()
		eq(conf, d + "/home/.config/environment.d/80-gamecove-display.conf", "the file the Display settings write")
		DirAccess.make_dir_recursive_absolute(conf.get_base_dir())
		FileAccess.open(conf, FileAccess.WRITE).store_string("# Written by GameCove (Display settings).\nORIENTATION=left\nCUSTOM_REFRESH_RATES=40,60,90\n")
		FileAccess.open(conf.get_base_dir() + "/90-mine.conf", FileAccess.WRITE).store_string("X=1\n")
		var c := _choices(t)
		c["keep_settings"] = keep
		s.start("uninstall", c)
		ok(not FileAccess.file_exists(conf), "gone from every session's way (keep settings %s)" % keep)
		ok(FileAccess.file_exists(conf.get_base_dir() + "/90-mine.conf"), "the user's own files in that folder stay")
		eq(FileAccess.file_exists(s.paths.display_env_kept()), keep, "a copy only with \"Keep my settings\"")
		if keep:
			var s2 := _svc(d, _runner(), F.target("bazzite"))
			s2.start("install", _choices(F.target("bazzite")))
			ok(FileAccess.get_file_as_string(conf).contains("ORIENTATION=left"), "the next install puts the display settings back")
			ok(not FileAccess.file_exists(s2.paths.display_env_kept()), "and the copy is used up")
		_cleanup()


## Final review, high 9: with "Keep my settings" off, user:// went whole: every save backup and the
## originals of the art GameCove replaced in Steam, whose replacements stayed in Steam's grid folder
## for good. Now Steam's own art is put back first, and save backups stay unless asked for by name.
func _user_data(d: String) -> Dictionary:
	var user := d + "/userdata/GameCove"
	var grid := d + "/home/.local/share/Steam/userdata/123/config/grid"
	DirAccess.make_dir_recursive_absolute(grid)
	DirAccess.make_dir_recursive_absolute(user + "/saves/backups/epic_abc")
	DirAccess.make_dir_recursive_absolute(user + "/art/picked")
	FileAccess.open(grid + "/620p.png", FileAccess.WRITE).store_string("the user's own cover")
	FileAccess.open(user + "/art/picked/new.png", FileAccess.WRITE).store_string("GameCove's pick")
	FileAccess.open(user + "/ui.cfg", FileAccess.WRITE).store_string("[ui]\n")
	FileAccess.open(user + "/saves/backups/epic_abc/20261110-120000.json", FileAccess.WRITE).store_string("{\"parts\": []}")
	FileAccess.open(user + "/saves/backups/epic_abc/20261110-120000-0.tar.gz", FileAccess.WRITE).store_string("a save")
	FileAccess.open(user + "/saves/status.json", FileAccess.WRITE).store_string("{}")
	var bdir: String = SteamGrid.backup_dir_for(user + "/art/steam_backup", grid)
	eq(SteamGrid.apply(grid, bdir, "620", "cover", user + "/art/picked/new.png"), grid + "/620p.png", "GameCove's cover applied to Steam")
	eq(FileAccess.get_file_as_string(grid + "/620p.png"), "GameCove's pick", "replaced")
	return {"user": user, "grid": grid, "bdir": bdir}


func test_uninstall_without_settings_keeps_save_backups_and_restores_steam_art() -> void:
	var d := _dir("uninstall_data")
	_make_live(d)
	var t := F.target("bazzite", {"installed": true, "state": {"version": "0.2.0", "fixes": []}})
	var s := _svc(d, _runner(), t)
	var u := _user_data(d)
	var c := _choices(t)
	eq(c["remove_save_backups"], false, "save backups are never deleted by default")
	c["keep_settings"] = false
	s.start("uninstall", c)
	eq(FileAccess.get_file_as_string(u["grid"] + "/620p.png"), "the user's own cover", "Steam has the user's own art back")
	ok(FileAccess.file_exists(u["user"] + "/saves/backups/epic_abc/20261110-120000.json"), "save backup index kept")
	eq(FileAccess.get_file_as_string(u["user"] + "/saves/backups/epic_abc/20261110-120000-0.tar.gz"), "a save", "save backup kept")
	ok(not FileAccess.file_exists(u["user"] + "/ui.cfg"), "settings deleted")
	ok(not FileAccess.file_exists(u["user"] + "/saves/status.json"), "sync state deleted (only the backups stay)")
	ok(not DirAccess.dir_exists_absolute(u["user"] + "/art"), "downloaded art and the used-up art backup deleted")
	ok("kept in" in FileAccess.get_file_as_string(s.paths.log_file()), "the log says what was kept")
	_cleanup()


func test_uninstall_deletes_save_backups_only_when_asked() -> void:
	var d := _dir("uninstall_data_all")
	_make_live(d)
	var t := F.target("bazzite", {"installed": true, "state": {"version": "0.2.0", "fixes": []}})
	var s := _svc(d, _runner(), t)
	var u := _user_data(d)
	var c := _choices(t)
	c["keep_settings"] = false
	c["remove_save_backups"] = true
	s.start("uninstall", c)
	eq(FileAccess.get_file_as_string(u["grid"] + "/620p.png"), "the user's own cover", "Steam art still goes back")
	ok(not DirAccess.dir_exists_absolute(u["user"]), "everything deleted, backups too")
	_cleanup()


## An original whose Steam folder isn't there (another drive, Steam moved) keeps its backup.
func test_uninstall_keeps_art_originals_it_could_not_put_back() -> void:
	var d := _dir("uninstall_data_art")
	_make_live(d)
	var t := F.target("bazzite", {"installed": true, "state": {"version": "0.2.0", "fixes": []}})
	var s := _svc(d, _runner(), t)
	var u := _user_data(d)
	UserFiles.remove_tree(d + "/home/.local/share/Steam", d + "/home")
	var c := _choices(t)
	c["keep_settings"] = false
	s.start("uninstall", c)
	ok(FileAccess.file_exists(str(u["bdir"]) + "/620p.png"), "the original stays in the backup")
	ok(FileAccess.file_exists(str(u["bdir"]) + "/manifest.json"), "with its manifest")
	ok(not FileAccess.file_exists(u["user"] + "/ui.cfg"), "settings still deleted")
	_cleanup()


func test_keep_settings_on_touches_nothing_in_the_data_folder() -> void:
	var d := _dir("uninstall_data_keep")
	_make_live(d)
	var t := F.target("bazzite", {"installed": true, "state": {"version": "0.2.0", "fixes": []}})
	var s := _svc(d, _runner(), t)
	var u := _user_data(d)
	var c := _choices(t)
	c["keep_settings"] = true
	c["remove_save_backups"] = true   # ignored: it belongs to "Keep my settings" off
	s.start("uninstall", c)
	ok(FileAccess.file_exists(u["user"] + "/ui.cfg"), "settings kept")
	ok(FileAccess.file_exists(u["user"] + "/saves/backups/epic_abc/20261110-120000-0.tar.gz"), "backups kept")
	eq(FileAccess.get_file_as_string(u["grid"] + "/620p.png"), "GameCove's pick", "art in Steam left as it is (its backup is kept too)")
	_cleanup()


func test_user_data_helpers() -> void:
	var d := _dir("user_data")
	var u := _user_data(d)
	eq(UserData.save_backup_stats(u["user"]), {"backups": 1, "games": 1, "bytes": 19}, "one backup of one game, both files counted")
	eq(UserData.save_backup_stats(d + "/nowhere"), {"backups": 0, "games": 0, "bytes": 0}, "none")
	eq([UserData.size_text(20), UserData.size_text(5 * 1024 * 1024), UserData.size_text(1400000000)], ["1 KB", "5 MB", "1.3 GB"], "sizes")
	eq(UserData.remove_except(u["user"], "/", ["saves/backups"]), [], "refuses a folder that isn't under the given parent")
	eq(UserData.remove_except(u["user"], d + "/userdata", ["saves/backups", "nothing/here"]), ["saves/backups"], "kept")
	ok(DirAccess.dir_exists_absolute(u["user"] + "/saves/backups/epic_abc") and not FileAccess.file_exists(u["user"] + "/saves/status.json"), "only the kept folder is left")


## Review H4: a failed session restore stops the uninstall before the package goes, so the boot
## default never names a removed gamecove.desktop.
func test_failed_session_restore_stops_the_uninstall() -> void:
	var d := _dir("optional")
	_make_live(d)
	var t := F.target("bazzite", {"installed": true})
	var r := _runner({"sh": {"code": 127, "out": ""}})
	var s := _svc(d, r, t)
	var results := []
	s.finished.connect(func(a, ok_, m): results.append([a, ok_, m]))
	s.start("uninstall", _choices(t))
	eq(results[-1], ["uninstall", false, "no_password"], "a failed session restore stops the removal")
	eq(s.results[1], "failed")
	ok(not s.results.slice(2).has("ok"), "nothing after it ran (the package stays)")
	_cleanup()


## Device finding 10: ClawDeck's files made claw8ex-gyro refuse and the whole install stopped at 18%.
## An optional fix failing never stops the run: the rest installs, the failure is listed with its own retry.
## Device finding 12: one pkexec (one password prompt) for every root step of an install, each step
## keeping its own result; and the Plasma virtual keyboard is on while the dialog is open.
func test_one_password_for_the_whole_install_and_a_keyboard_for_it() -> void:
	var d := _dir("onepass")
	_make_live(d)
	var t := F.target("bazzite", {"installed": true})
	var r := _runner()
	var s := _svc(d, r, t)
	s.desktop = "KDE"
	s.session_type = "wayland"
	var c := _choices(t)
	c["fixes"] = ["claw8ex-buttons", "claw8ex-vrr", "claw8ex-gyro"]
	var results := []
	s.finished.connect(func(a, ok_, m): results.append([a, ok_, m]))
	s.start("install", c)
	eq(results[-1][1], true, "installed")
	eq(r.batches, 1, "one pkexec for the package and every fix")
	for f in c["fixes"]:
		ok(r.called("pkexec %s %s install" % [s.paths.fix_helper(), f]), "step ran: " + f)
	eq(s.results.count("failed"), 0)
	_cleanup()


func test_a_dismissed_password_asks_once_and_stops() -> void:
	var d := _dir("nopass")
	_make_live(d)
	var t := F.target("bazzite", {"installed": true})
	var r := _runner({"pkexec batch": {"code": 126, "out": "Not authorized"}})
	var s := _svc(d, r, t)
	var results := []
	s.finished.connect(func(a, ok_, m): results.append([a, ok_, m]))
	var c := _choices(t)
	c["fixes"] = ["claw8ex-buttons", "claw8ex-vrr"]
	s.start("install", c)
	eq(results[-1], ["install", false, "no_password"])
	eq(r.batches, 1, "the dialog came once, not once per step")
	_cleanup()


func test_a_failing_fix_does_not_stop_the_install_and_can_be_retried() -> void:
	var d := _dir("fixfail")
	_make_live(d)
	var t := F.target("bazzite", {"installed": true})
	var broken := [true]
	var r := Fake.new()
	r.handler = func(cmd: String):
		if cmd.begins_with("pgrep"):
			return {"code": 1, "out": ""}
		if "claw8ex-gyro install" in cmd and broken[0]:
			return {"code": 1, "out": "error: /etc/inputplumber/devices.d/x.yaml exists and isn't GameCove's; leaving it"}
		return {"code": 0, "out": "done"}
	var s := _svc(d, r, t)
	var results := []
	s.finished.connect(func(a, ok_, m): results.append([a, ok_, m]))
	var c := _choices(t)
	c["fixes"] = ["claw8ex-buttons", "claw8ex-gyro", "claw8ex-vrr"]
	s.start("install", c)
	eq(results[-1][1], true, "the install finished")
	var ids: Array = s.tasks.map(func(x): return str(x["id"]) + ":" + str(x["fix"]))
	var gyro := ids.find("fix_install:claw8ex-gyro")
	eq(s.results[gyro], "skipped", "the failed fix is marked, not fatal")
	eq(s.results[ids.find("fix_install:claw8ex-vrr")], "ok", "the fix after it still ran")
	ok(s.results.slice(gyro + 1).all(func(x): return x == "ok" or x == "pending"), "so did everything after it")
	eq(s.failed_fixes.size(), 1, "one failed fix is listed")
	eq(s.failed_fixes[0]["fix"], "claw8ex-gyro")
	ok("isn't GameCove's" in str(s.failed_fixes[0]["message"]), "with the reason")
	ok(not "claw8ex-gyro" in s.installed_fixes, "it isn't recorded as installed")
	ok("claw8ex-vrr" in s.installed_fixes)
	var again := []
	s.fix_retried.connect(func(f, ok_, m): again.append([f, ok_, m]))
	broken[0] = false
	ok(s.retry_fix("claw8ex-gyro"), "its own retry")
	eq(again[-1][0], "claw8ex-gyro")
	eq(again[-1][1], true, "worked this time")
	ok(s.failed_fixes.is_empty() and "claw8ex-gyro" in s.installed_fixes, "no longer listed, now installed")
	ok(not s.retry_fix("claw8ex-gyro"), "nothing to retry any more")
	_cleanup()


func test_settings_writer_and_setup_marks() -> void:
	var d := _dir("settings")
	var rec := F.Recorder.new()
	var setup := F.FakeSetup.new()
	var t := F.target("bazzite")
	var c := _choices(t)
	c["auto_tdp"] = false
	c["power_profile"] = "battery"
	c["charge_limit"] = 85
	c["steam_control"] = true
	c["ggdeals_key"] = "abcdefghijkl"
	c["steamgriddb_key"] = "0123456789abcdef0123456789abcdef"
	c["country"] = "CA"
	var log := SettingsWriter.apply(c, F.services(F.claw(), setup, rec, d + "/power.cfg"))
	ok(log.size() >= 4)
	ok(["store", "steam_cef", true] in rec.calls, "Steam control saved")
	ok(["goal", "smooth"] in rec.calls, "Auto TDP off = smooth goal")
	var disc: Array = rec.calls.filter(func(x): return x[0] == "discover")
	eq(disc[0][1], {"ggdeals_key": "abcdefghijkl", "country": "CA", "steamgriddb_key": "0123456789abcdef0123456789abcdef"})
	eq(setup.key, "0123456789abcdef0123456789abcdef")
	var cfg := ConfigFile.new()
	eq(cfg.load(d + "/power.cfg"), OK)
	eq(cfg.get_value("profile", "battery"), "battery")
	eq(cfg.get_value("profile", "plugged"), "battery")
	eq(cfg.get_value("device", "charge_limit"), 85)
	SettingsWriter.mark_setup(setup, c, {}, true)
	for k in ["welcome", "theme", "stores", "device_fixes", "steamgriddb", "done"]:
		ok(setup.done.has(k), "setup step done: " + k)
	var s2 := F.FakeSetup.new()
	SettingsWriter.mark_setup(s2, c, {"device": true}, false)
	ok(s2.skipped.has("stores") and s2.skipped.has("device_fixes"))
	ok(s2.done.has("done"), "the in-app first run has nothing left")
	_cleanup()
