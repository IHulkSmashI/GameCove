extends "res://tests/test_case.gd"
## Recording: recorder.gd (where GPU Screen Recorder is, its arguments, clip
## names, its errors, finding its process) and the Recording service with a
## fake recorder process, plus the quick menu's Record row. Nothing real runs:
## a temp folder stands in for /, $HOME and /proc.

const Recorder := preload("res://scripts/system/recorder.gd")
const Recording := preload("res://scripts/system/recording.gd")
const Fake := preload("res://tests/fixtures/system/fake_runner.gd")
const TX := preload("res://scripts/ui/texts_extras.gd")
const QuickMenu := preload("res://scripts/ui/quick_menu.gd")
const Screens := preload("res://tests/test_ui_screens.gd")


func _tmp(tag: String) -> String:
	var d := OS.get_cache_dir().path_join("gamecove_rec_%s_%d" % [tag, Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(d)
	return d


func _touch(path: String, text := "x") -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _wipe(dir: String) -> void:
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(d))
	DirAccess.remove_absolute(dir)


## A recorder that "runs" inline: hands over a pid, prints `lines`, writes
## `bytes` to the -o file, and returns `code`.
class FakeSpawner extends RefCounted:
	var argv := PackedStringArray()
	var pid := 4242
	var lines: Array = []
	var bytes := 1000
	var code := 0
	var hold := false        # stop after on_pid (the test finishes it with finish())
	var _on_line: Callable

	func run_blocking(a: PackedStringArray, on_pid: Callable, on_line: Callable) -> int:
		argv = a
		on_pid.call(pid)
		for l in lines:
			on_line.call(l)
		var out := ""
		for i in a.size():
			if a[i] == "-o" and i + 1 < a.size():
				out = a[i + 1]
		if out != "" and bytes >= 0:
			var f := FileAccess.open(out, FileAccess.WRITE)
			var b := PackedByteArray()
			b.resize(bytes)
			f.store_buffer(b)
			f.close()
		return code


# ---- recorder.gd ---------------------------------------------------------------------

func test_locate_prefers_the_host_program_then_the_system_flatpak() -> void:
	var root := _tmp("loc")
	var home := "/home/deck"
	eq(Recorder.locate({"sys_root": root, "path_env": "/usr/bin", "home": home})["kind"], "", "nothing installed")
	eq(Recorder.status(null, Recorder.locate({"sys_root": root, "path_env": "/usr/bin", "home": home}), home)["why"], "no_flatpak", "no flatpak either")
	_touch(root + "/usr/bin/flatpak")
	var none := Recorder.locate({"sys_root": root, "path_env": "/usr/bin", "home": home})
	eq([none["kind"], none["flatpak"]], ["", "/usr/bin/flatpak"], "flatpak but no recorder")
	eq(Recorder.status(null, none, home), {"ready": false, "why": "missing"}, "offer the install")
	DirAccess.make_dir_recursive_absolute(root + home + "/" + Recorder.USER_APP_DIR)
	eq(Recorder.locate({"sys_root": root, "path_env": "/usr/bin", "home": home})["kind"], "flatpak_user", "per-user install can't capture")
	DirAccess.make_dir_recursive_absolute(root + Recorder.SYSTEM_APP_DIR)
	var fp := Recorder.locate({"sys_root": root, "path_env": "/usr/bin", "home": home})
	eq([fp["kind"], fp["program"]], ["flatpak", "/usr/bin/flatpak"], "system flatpak")
	_touch(root + "/usr/local/bin/gpu-screen-recorder")
	var host := Recorder.locate({"sys_root": root, "path_env": "/usr/local/bin:/usr/bin", "home": home})
	eq([host["kind"], host["program"]], ["host", "/usr/local/bin/gpu-screen-recorder"], "host program wins")
	eq(Recorder.status(null, host, home), {"ready": true, "why": ""}, "host installs carry the capability")
	_wipe(root)


func test_flatpak_status_asks_kms_server_proxy() -> void:
	var f: RefCounted = Fake.new()
	var loc := {"kind": "flatpak", "program": "/usr/bin/flatpak", "flatpak": "/usr/bin/flatpak"}
	f.responses[Recorder.KMS_PROXY + " is-setup /home/deck"] = {"code": 1, "out": "Error: kms-server-proxy is either not installed or is missing capabilities"}
	eq(Recorder.status(f, loc, "/home/deck"), {"ready": false, "why": "needs_setup"}, "not set up")
	f.responses[Recorder.KMS_PROXY + " is-setup /home/deck"] = {"code": 0, "out": ""}
	eq(Recorder.status(f, loc, "/home/deck"), {"ready": true, "why": ""}, "set up")
	eq(Recorder.setup_command("/home/deck"), PackedStringArray([Recorder.KMS_PROXY, "setup-gsr-ui", "/home/deck"]), "the official UI's set-up call")
	ok(Recorder.needs_desktop(126) and Recorder.needs_desktop(127) and not Recorder.needs_desktop(1), "pkexec without an agent")


func test_arguments_capture_the_screen_in_h264() -> void:
	var a := Recorder.record_args("/v/clip.mp4", {"fps": 60, "audio": true})
	eq(a, PackedStringArray(["-w", "screen", "-c", "mp4", "-k", "h264", "-f", "60", "-q", "very_high", "-cursor", "no", "-v", "no",
		"-a", "default_output", "-o", "/v/clip.mp4"]), "monitor capture (works under gamescope), H.264, sound")
	var silent := Recorder.record_args("/v/c.mp4", {"fps": 30, "audio": false})
	ok(not "-a" in silent and silent[silent.find("-f") + 1] == "30", "no sound, 30 fps")
	eq(Recorder.record_args("/v/c.mp4", {"fps": 144})[7], "60", "odd frame rates fall back to 60")
	var fp := Recorder.command({"kind": "flatpak", "program": "/usr/bin/flatpak"}, PackedStringArray(["-w", "screen"]))
	eq(fp, PackedStringArray(["/usr/bin/flatpak", "run", "--command=gpu-screen-recorder", Recorder.FLATPAK_ID, "-w", "screen"]), "flatpak command")
	eq(Recorder.command({"kind": "host", "program": "/usr/bin/gpu-screen-recorder"}, PackedStringArray(["-x"])), PackedStringArray(["/usr/bin/gpu-screen-recorder", "-x"]), "host command")
	eq(Recorder.command({"kind": "flatpak_user"}, PackedStringArray(["-x"])), PackedStringArray(), "a per-user install can't record")


func test_install_is_system_wide_and_adds_flathub_only_when_missing() -> void:
	var with := Recorder.install_commands("flatpak", true)
	eq(with, [["flatpak", "install", "--system", "--noninteractive", "-y", "flathub", Recorder.FLATPAK_ID]], "install only")
	var without := Recorder.install_commands("flatpak", false)
	eq(without.size(), 2, "remote first")
	eq(without[0].slice(0, 4), ["flatpak", "remote-add", "--system", "--if-not-exists"], "system remote")
	ok(Recorder.has_flathub("fedora\nflathub\n") and not Recorder.has_flathub("fedora\nflathub-beta\n"), "remote list")


func test_clip_names_and_folders() -> void:
	eq(Recorder.safe_name("  Half-Life: Alyx / VR  "), "Half-Life Alyx VR", "no slashes or colons")
	eq(Recorder.safe_name("..hidden"), "hidden", "no dot files")
	eq(Recorder.safe_name("\u0001\u0002"), Recorder.NO_GAME, "nothing left")
	eq(Recorder.safe_name("x".repeat(120)).length(), 80, "capped")
	var home := _tmp("names")
	var when := {"year": 2026, "month": 11, "day": 10, "hour": 15, "minute": 4, "second": 9}
	var p := Recorder.clip_path(home, "Hades II", when)
	eq(p, home + "/Videos/GameCove/Hades II/Hades II 2026-11-10 15-04-09.mp4", "folder per game, time in the name")
	_touch(p)
	eq(Recorder.clip_path(home, "Hades II", when), home + "/Videos/GameCove/Hades II/Hades II 2026-11-10 15-04-09 (2).mp4", "never over a clip")
	_wipe(home)


func test_errors_in_plain_words() -> void:
	eq(Recorder.error_kind(127, ["sh: 1: gpu-screen-recorder: not found"]), "missing", "gone")
	eq(Recorder.error_kind(1, ["gsr info: gsr_kms_client_init: setting up connection", "Error: kms-server-proxy is either not installed or is missing capabilities"]), "needs_setup", "KMS helper not allowed")
	eq(Recorder.error_kind(1, ["gsr error: gsr_kms_client_init: failed to launch \"gsr-kms-server\""]), "needs_setup", "helper refused")
	eq(Recorder.error_kind(1, ["gsr error: failed to get vaapi device"]), "no_encoder", "no VA-API")
	eq(Recorder.error_kind(1, ["Error: something odd"]), "failed", "anything else")
	eq(Recorder.last_line(["a", "b", "  ", ""]), "b", "last real line")
	for k in ["needs_setup", "no_encoder", "missing", "no_screen", "not_ready", "empty", "failed"]:
		ok(TX.REC_ERRORS.has(k), "words for " + k)


func test_finds_the_recorder_under_the_flatpak_sandbox() -> void:
	var proc := _tmp("proc")
	# flatpak run (100) -> bwrap (101) -> bwrap (102) -> gpu-screen-recorder (103); another one elsewhere (200)
	for row in [[100, 1, "flatpak"], [101, 100, "bwrap"], [102, 101, "bwrap"], [103, 102, "gpu-screen-reco"], [200, 1, "gpu-screen-reco"], [300, 1, "a (weird) name"]]:
		_touch(proc + "/%d/stat" % row[0], "%d (%s) S %d 1 1 0 -1" % [row[0], row[2], row[1]])
	_touch(proc + "/self/stat", "ignored")
	var t := Recorder.proc_table(proc)
	eq(t["names"][300], "a (weird) name", "names with spaces and parentheses")
	eq(Recorder.recorder_pid(100, t), 103, "the recorder itself gets SIGINT, not the wrapper")
	eq(Recorder.recorder_pid(200, t), 200, "a host recorder is its own pid")
	eq(Recorder.recorder_pid(999, t), -1, "gone")
	_wipe(proc)


# ---- the service ---------------------------------------------------------------------

func _service(home: String, sp: FakeSpawner, f: RefCounted) -> Node:
	var root := home.path_join("root")
	DirAccess.make_dir_recursive_absolute(root + Recorder.SYSTEM_APP_DIR)
	_touch(root + "/usr/bin/flatpak")
	var r: Node = Recording.new()
	r.threaded = false
	r.spawner = sp
	r.runner = f
	r.thumb_fn = func(_c): pass
	r.prefs_path = home.path_join("settings.cfg")
	r.env = {"home": home, "path_env": "/usr/bin", "sys_root": root, "proc_root": home.path_join("proc")}
	_touch(home + "/proc/4242/stat", "4242 (gpu-screen-reco) S 1 1 1")
	return r


func test_records_and_saves_a_clip() -> void:
	var home := _tmp("svc")
	var sp := FakeSpawner.new()
	var f: RefCounted = Fake.new()
	var r := _service(home, sp, f)
	var got := []
	r.saved.connect(func(p, info): got.append([p, info]))
	r.failed.connect(func(k, d): got.append(["failed", k, d]))
	eq(r.row_state(), "record", "installed and not known to need set-up")
	ok(r.start({"title": "Hades", "key": "steam:1145360"}), "started")
	# the fake ran to the end at once: exit 0 with a file means saved
	eq(got.size(), 1, "one answer")
	ok(str(got[0][0]).begins_with(home + "/Videos/GameCove/Hades/Hades "), "into the game's folder: %s" % str(got[0][0]))
	eq(got[0][1]["game"], "Hades", "game named")
	eq(sp.argv[0], "/usr/bin/flatpak", "through the flatpak")
	ok("--command=gpu-screen-recorder" in sp.argv and "-o" in sp.argv, "recorder arguments")
	eq(r.state, "idle", "idle again")
	r.free()
	_wipe(home)


func test_stop_sends_sigint_to_the_recorder() -> void:
	var home := _tmp("stop")
	var sp := FakeSpawner.new()
	var f: RefCounted = Fake.new()
	f.responses["kill -INT 4242"] = {"code": 0, "out": ""}
	var r := _service(home, sp, f)
	# drive the steps by hand: start without running the fake to the end
	r.state = "starting"
	r.path = home + "/Videos/GameCove/X/x.mp4"
	r._on_pid(4242)
	eq(r.state, "recording", "recording once it has a pid")
	r.stop()
	eq(r.state, "stopping", "stopping")
	ok(f.called("kill -INT 4242"), "SIGINT, the recorder's own stop")
	_touch(r.path, "data")
	var got := []
	r.saved.connect(func(p, _i): got.append(p))
	r._on_exit(130, [])
	eq(got.size(), 1, "a stopped recording with a file is saved whatever the exit code")
	r.free()
	_wipe(home)


func test_stop_before_the_pid_arrives_still_stops_it() -> void:
	var home := _tmp("early")
	var f: RefCounted = Fake.new()
	var r := _service(home, FakeSpawner.new(), f)
	r.state = "starting"
	r.stop()
	eq(r.state, "stopping", "waiting for the pid")
	ok(not f.called("kill"), "nothing to signal yet")
	r._on_pid(4242)
	ok(f.called("kill -INT 4242"), "stopped as soon as it started")
	r.free()
	_wipe(home)


func test_a_failed_start_says_why_and_leaves_nothing() -> void:
	var home := _tmp("fail")
	var sp := FakeSpawner.new()
	sp.code = 1
	sp.bytes = 0
	sp.lines = ["gsr info: gsr_kms_client_init: setting up connection", "Error: kms-server-proxy is either not installed or is missing capabilities"]
	var r := _service(home, sp, Fake.new())
	var got := []
	r.failed.connect(func(k, d): got.append([k, d]))
	ok(r.start({}), "started")
	eq(got, [["needs_setup", "Error: kms-server-proxy is either not installed or is missing capabilities"]], "one-time OK needed")
	eq(r.row_state(), "set_up", "the quick menu now offers the set-up")
	eq(DirAccess.get_files_at(home + "/Videos/GameCove/GameCove").size(), 0, "no empty clip left behind")
	r.set_ready(true)
	eq(r.row_state(), "record", "Settings > Media found it allowed")
	r.free()
	_wipe(home)


func test_not_installed_is_refused() -> void:
	var r: Node = Recording.new()
	r.threaded = false
	r.env = {"home": "/nonexistent", "path_env": "", "sys_root": "/nonexistent"}
	var got := []
	r.failed.connect(func(k, _d): got.append(k))
	ok(not r.start({}), "refused")
	eq(got, ["not_ready"], "says so")
	eq(r.row_state(), "set_up", "offers the set-up")
	r.free()


func test_options_are_saved() -> void:
	var home := _tmp("opts")
	var r: Node = Recording.new()
	r.prefs_path = home.path_join("settings.cfg")
	eq(r.options(), {"audio": true, "fps": 60}, "defaults: sound on, 60 fps")
	ok(r.set_option("audio", false) and r.set_option("fps", 30), "saved")
	eq(r.options(), {"audio": false, "fps": 30}, "read back")
	ok(not r.set_option("quality", 1), "unknown keys refused")
	eq(Recording.clock(42), "0:42", "clock")
	eq(Recording.clock(3723), "1:02:03", "hours")
	r.free()
	_wipe(home)


# ---- quick menu ----------------------------------------------------------------------

class FakeRec extends Node:
	signal changed
	var st := "record"
	var state := "idle"
	var started: Array = []
	var stopped := 0

	func row_state() -> String:
		return st

	func elapsed_s() -> int:
		return 65

	func clock(s: int) -> String:
		return "%d:%02d" % [s / 60, s % 60]

	func start(g: Dictionary) -> bool:
		started.append(g)
		st = "stop"
		state = "recording"
		changed.emit()
		return true

	func stop() -> void:
		stopped += 1


func _qm(extra: Dictionary) -> Control:
	var qm: Control = QuickMenu.new()
	var svc := {"device": Screens.FakeDevice.new(), "power": Screens.FakePower.new(), "launcher": Screens.FakeLauncher.new(),
		"gamescope": Screens.FakeGamescope.new()}
	svc.merge(extra, true)
	qm.setup(svc)
	return qm


func test_quick_menu_record_row() -> void:
	var rec := FakeRec.new()
	var qm := _qm({"recording": rec})
	qm.open({})
	var row: Node = qm.body.find_child("Record", true, false)
	ok(row != null, "Record row on This game, even with no game")
	eq(row.title_label.text, TX.REC_START, "Record")
	var notes := []
	qm.notice.connect(func(t, _tone): notes.append(t))
	row.pressed.emit()
	eq(rec.started, [{}], "records the screen (no game running: no game folder)")
	eq(notes, [TX.REC_STARTED], "says how to stop")
	ok(not qm.visible, "the menu gets out of the way")
	qm.open({})
	row = qm.body.find_child("Record", true, false)
	eq(row.title_label.text, TX.REC_STOP, "Stop recording while it records")
	ok(row.value_label.text.ends_with("1:05"), "with the time so far")
	row.pressed.emit()
	eq(rec.stopped, 1, "stops")
	rec.st = "set_up"
	qm.show_section(0)
	row = qm.body.find_child("Record", true, false)
	eq(row.title_label.text, TX.REC_SET_UP, "points to Settings when it can't record")
	qm.free()
	rec.free()


func test_quick_menu_without_recording_has_no_row() -> void:
	var qm := _qm({})
	qm.open({})
	ok(qm.body.find_child("Record", true, false) == null, "no service, no row")
	qm.free()
