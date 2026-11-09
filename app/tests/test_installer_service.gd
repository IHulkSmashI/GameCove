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
	eq(_cmds(r), ["pkexec rpm-ostree install --idempotent --apply-live " + t["package"]], "only the package ran: nothing is live")
	eq(s.results.count("pending"), 4, "three fixes and the startup choice wait for the reboot")
	eq(s.deferred_fixes, ["claw8ex-buttons", "claw8ex-vrr", "claw8ex-gyro"])
	var p: RefCounted = s.paths
	var pending := Target.read_pending(p.pending_file())
	eq(pending, {"STARTUP": "gamecove", "SWITCH_NOW": "1", "FIXES": "claw8ex-buttons,claw8ex-vrr,claw8ex-gyro"})
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
	eq(st["waiting_fixes"], ["claw8ex-buttons", "claw8ex-vrr", "claw8ex-gyro"])
	eq(st["choices"]["startup"], "gamecove")
	ok(not st["choices"].has("ggdeals_key"), "keys stay out of the state file")
	var log := FileAccess.get_file_as_string(p.log_file())
	ok("$ pkexec rpm-ostree install" in log, "commands logged")
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
	var answers := {"pkexec rpm-ostree": {"code": 126, "out": "Not authorized"}}
	var r := _runner(answers)
	var t := F.target("bazzite")
	var s := _svc(d, r, t)
	var results := []
	s.finished.connect(func(a, ok_, m): results.append([a, ok_, m]))
	s.start("install", _choices(t))
	eq(results[-1], ["install", false, "no_password"])
	eq(r.calls.filter(func(c): return c.begins_with("pkexec rpm-ostree")).size(), 2, "live install, then the staged fallback")
	answers.clear()
	ok(s.retry(), "retry from the failed step")
	eq(results[-1], ["install", true, ""])
	ok(FileAccess.file_exists(s.paths.env_conf()))
	var undone := []
	s.undone.connect(func(o): undone.append(o))
	ok(s.undo())
	eq(undone, [true])
	ok(r.called("pkexec rpm-ostree uninstall gamecove"), "package taken off again")
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
	s2.start("uninstall", c)
	eq(_cmds(r), ["steamosctl set-default-login-mode game", "pkexec " + s2.paths.fix_helper() + " claw8ex-vrr remove",
		"pkexec rpm-ostree uninstall gamecove"])
	for f in [s2.paths.env_conf(), s2.paths.unit_file(), s2.paths.switch_entry(), s2.paths.window_entry(),
			s2.paths.pending_file(), s2.paths.state_file()]:
		ok(not FileAccess.file_exists(f), "removed " + f)
	ok(FileAccess.file_exists(s2.paths.log_file()), "the log stays")
	_cleanup()


func test_optional_failures_continue() -> void:
	var d := _dir("optional")
	_make_live(d)
	var t := F.target("bazzite", {"installed": true})
	var r := _runner({"steamosctl": {"code": 127, "out": ""}})
	var s := _svc(d, r, t)
	var results := []
	s.finished.connect(func(a, ok_, m): results.append([a, ok_, m]))
	s.start("uninstall", _choices(t))
	eq(results[-1], ["uninstall", true, ""], "a missing steamosctl doesn't stop the removal")
	eq(s.results[1], "skipped")
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
