extends "res://tests/test_case.gd"
## Performance overlay levels and mangoapp logging: the config file the session
## hands us (MANGOHUD_CONFIGFILE) lives under user:// here, and mangohudctl goes
## to a recording runner.

const Monitor := preload("res://scripts/perf/perf_monitor.gd")
const MangoHud := preload("res://scripts/perf/mangohud.gd")


class Rec extends RefCounted:
	var calls: Array[String] = []
	func run(program: String, args: PackedStringArray) -> Dictionary:
		calls.append(program + " " + " ".join(args))
		return {"code": 0, "exit": 0}


func _dir(test_name: String) -> String:
	var d := ProjectSettings.globalize_path("user://test_perf_overlay/" + test_name)
	DirAccess.make_dir_recursive_absolute(d + "/run")
	for f in ["mangohud.cfg", "perf.cfg"]:
		DirAccess.remove_absolute(d + "/" + f)
	return d


## A monitor over the Claw fixture's PATH (mangoapp and mangohudctl present)
## with the session's config file in a scratch folder.
func _monitor(dir: String, with_ctl := true, with_config := true) -> Node:
	var m: Node = Monitor.new()
	m.sys_root = fixture("perf/sys_claw" if with_ctl else "perf/sys_deck")
	m.config_path = dir + "/perf.cfg"
	m.runner = Rec.new()
	m.env = {"PATH": "/usr/bin", "XDG_RUNTIME_DIR": dir + "/run",
		"MANGOHUD_CONFIGFILE": (dir + "/mangohud.cfg") if with_config else ""}
	return m


func _lines(path: String) -> Array:
	return Array(FileAccess.get_file_as_string(path).split("\n", false))


func test_level_mapping() -> void:
	eq(MangoHud.LEVEL_NAMES, ["off", "fps", "compact", "full"], "four levels")
	var off := MangoHud.config_text(0, false, "")
	ok(off.contains("\nno_display\n"), "off hides the overlay")
	var fps := MangoHud.config_text(1, false, "")
	ok(fps.contains("\nfps_only\n") and not fps.contains("no_display"), "fps only")
	var compact := MangoHud.config_text(2, false, "")
	ok(compact.contains("\nhorizontal\n") and compact.contains("\ngpu_stats\n"), "compact is one horizontal row")
	var full := MangoHud.config_text(3, false, "")
	ok(full.contains("\ngpu_temp\n") and full.contains("\nframe_timing=1\n") and not full.contains("horizontal"), "full")
	eq(MangoHud.config_text(9, false, ""), full, "out of range clamps to full")
	eq(MangoHud.config_text(-1, false, ""), off, "below range clamps to off")
	ok(not off.contains("output_folder"), "no log lines unless logging")


func test_set_level_writes_the_session_config() -> void:
	var dir := _dir("set_level")
	var m := _monitor(dir)
	var seen := []
	m.overlay_changed.connect(func(l): seen.append(l))
	ok(m.overlay_supported(), "config file + mangoapp on PATH")
	ok(m.set_overlay_level(1), "level 1 accepted")
	ok(_lines(dir + "/mangohud.cfg").has("fps_only"), "written to MANGOHUD_CONFIGFILE")
	eq(m.overlay_level(), 1, "level kept")
	eq(seen, [1], "overlay_changed")
	ok(m.set_overlay_level(0), "back to off")
	ok(_lines(dir + "/mangohud.cfg").has("no_display"), "hidden again")
	var cfg := ConfigFile.new()
	cfg.load(dir + "/perf.cfg")
	eq(cfg.get_value("overlay", "level", -1), 0, "remembered for next start")
	m.free()


func test_unsupported_without_config_or_mangoapp() -> void:
	var dir := _dir("unsupported")
	var m := _monitor(dir, true, false)
	ok(not m.overlay_supported(), "no MANGOHUD_CONFIGFILE: not our session")
	ok(not m.set_overlay_level(2), "set refused")
	ok(not FileAccess.file_exists(dir + "/mangohud.cfg"), "nothing written")
	ok(not m.capabilities()["fps"], "no fps source either")
	m.free()
	var m2 := _monitor(dir, true, true)
	m2.env["PATH"] = "/nowhere"
	ok(not m2.overlay_supported(), "no mangoapp installed")
	m2.free()


func test_logging_lines_follow_the_game() -> void:
	var dir := _dir("logging")
	var m := _monitor(dir)
	m.set_overlay_level(2)
	m.start(77)
	var lines := _lines(dir + "/mangohud.cfg")
	ok(lines.has("horizontal"), "the player's level stays")
	ok(lines.has("output_folder=" + dir + "/run/gamecove-mangohud"), "log goes to our runtime folder")
	ok(lines.has("log_interval=1000"), "one row a second")
	ok(not lines.has("autostart_log=1"), "mangohudctl present: no autostart")
	ok(m.capabilities()["fps"], "fps available")
	ok(not m.capabilities()["fps_needs_overlay"], "even with the overlay off")
	var log_dir := dir + "/run/gamecove-mangohud"
	var f := FileAccess.open(log_dir + "/x.csv", FileAccess.WRITE)
	f.store_string("fps\n60\n")
	f.close()
	m.stop()
	lines = _lines(dir + "/mangohud.cfg")
	ok(not lines.any(func(l): return l.begins_with("output_folder")), "log lines removed after the game")
	ok(lines.has("horizontal"), "level unchanged")
	ok(not FileAccess.file_exists(log_dir + "/x.csv"), "logs deleted")
	m.free()


func test_without_mangohudctl_autostart_needs_visible_overlay() -> void:
	var dir := _dir("no_ctl")
	var m := _monitor(dir, false)  # Deck fixture: mangoapp, no mangohudctl
	m.start(1)
	ok(_lines(dir + "/mangohud.cfg").has("autostart_log=1"), "autostart instead of mangohudctl")
	ok(m.capabilities()["fps_needs_overlay"], "UI can say fps needs the overlay on")
	m.stop()
	m.free()


func test_kicks_start_the_log_and_stay_rare() -> void:
	var mh: RefCounted = MangoHud.new()
	var dir := _dir("kicks")
	mh.config_path = dir + "/mangohud.cfg"
	mh.log_dir = dir + "/run/kicklogs"
	mh.ctl = "/usr/bin/mangohudctl"
	var rec := Rec.new()
	mh.runner = rec
	mh.want_logging = true
	mh.sync(100.0)
	ok(mh.logging, "logging on")
	mh.read_rows(100.5)
	eq(rec.calls.size(), 0, "waits for mangoapp to reload the config first")
	mh.read_rows(101.0)
	eq(rec.calls, ["/usr/bin/mangohudctl set log_session 1"], "then asks once")
	for t in [102.0, 103.0]:
		mh.read_rows(t)
	eq(rec.calls.size(), 1, "not every second")
	mh.read_rows(104.0)
	eq(rec.calls.size(), 2, "again after KICK_S without rows")
	var f := FileAccess.open(mh.log_dir + "/a.csv", FileAccess.WRITE)
	f.store_string("fps,frametime\n60,16.6\n")
	f.close()
	eq(mh.read_rows(105.0).size(), 1, "rows arrive")
	for t in [106.0, 107.0]:
		mh.read_rows(t)
	eq(rec.calls.size(), 2, "no kicks while rows are fresh")
	for i in 40:
		mh.read_rows(110.0 + i)
	eq(rec.calls.size(), 2 + MangoHud.MAX_KICKS, "gives up after MAX_KICKS")
	mh.set_level(1)  # a reload ends the log: kicks allowed again
	mh.read_rows(151.0)
	eq(rec.calls.size(), 3 + MangoHud.MAX_KICKS, "kicked after the level change")
	mh.want_logging = false
	mh.sync(152.0)
	ok(not mh.logging, "stopped")
	eq(mh.read_rows(153.0), [], "nothing read when not logging")
