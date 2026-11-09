extends RefCounted
## One fake handheld with the real app on it, for the end-to-end suite.
##
## The driver (tests/e2e/run.py) generates the fixture once (tools/devicematrix/
## gen.py --setups), copies it into a private work folder and starts Godot with
## HOME / XDG_* pointing into that folder, so nothing of the machine running the
## tests is read for settings or written. Here the real autoloads (Device, Power,
## Controls, Profiles, Controller, Gamescope, PerfMonitor, Launcher) are pointed at
## the fixture: sys_root, the fake system (fake_system.gd) as their runner, the
## fixture home. Then the real main scene boots on top (scenes/main.tscn), so the
## quick menu, Settings, GameSession, Profiles and the resume path are the
## production ones, wired the production way.
##
## The Controls worker runs for real (a thread, not sync_mode), as do Power's,
## the Controller's and Gamescope's: `idle()` waits until all of them are quiet.

const Fake := preload("res://tests/e2e/fake_system.gd")
const Matrix := preload("res://tests/devicematrix/matrix.gd")
const PerfProvider := preload("res://scripts/controls/providers/perf.gd")
const HhdHttpFake := preload("res://tests/devicematrix/matrix.gd").FakeHhd

const WINDOW_ID := 0x2a00007
const PROFILES_FILE := "user://e2e_profiles.json"

var tree: SceneTree
var info: Dictionary = {}
var backends: Dictionary = {}
var root := ""
var home := ""
var pristine := ""
var repo := ""
var setup_name := ""
var fake: RefCounted
var hhd: RefCounted
var main: Control
var ctx: Dictionary = {}
var row: Dictionary = {}
var readonly_files: Array = []
var _marks := 0


func _init(t: SceneTree) -> void:
	tree = t


func autoload(n: String) -> Node:
	return tree.root.get_node_or_null(n)


# ---- startup --------------------------------------------------------------------

## Reads E2E_INFO (the manifest entry the driver wrote) and points every service at it.
func configure() -> String:
	var path := OS.get_environment("E2E_INFO")
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) if path != "" else null
	if not parsed is Dictionary:
		return "E2E_INFO missing or unreadable (%s): run through tests/e2e/run.py" % path
	info = parsed
	setup_name = str(info.get("setup", ""))
	root = str(info["root"])
	home = str(info["home"])
	pristine = str(info.get("pristine", ""))
	repo = ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	if not root.begins_with(OS.get_environment("E2E_WORK")) or OS.get_environment("E2E_WORK") == "":
		return "fixture root %s is not inside E2E_WORK: refusing to run" % root
	if OS.get_environment("HOME") == "" or not OS.get_environment("HOME").begins_with(OS.get_environment("E2E_WORK")):
		return "HOME must point inside E2E_WORK (run through tests/e2e/run.py)"
	backends = JSON.parse_string(FileAccess.get_file_as_string(str(info["backends"])))
	# the autoloads came up on the machine running the tests: let their first jobs end
	await settle_startup()
	_mark_setup_done()
	_wire_services()
	return ""


## The real autoloads' own start (detection on the test machine) finishes first.
func settle_startup() -> void:
	var deadline := Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < deadline:
		await tree.process_frame
		var c := autoload("Controls")
		var p := autoload("Power")
		var busy := false
		if c != null:
			c._mutex.lock()
			busy = not c._jobs.is_empty()
			c._mutex.unlock()
		if p != null:
			p._job_mutex.lock()
			busy = busy or not p._job_order.is_empty()
			p._job_mutex.unlock()
		if not busy:
			break
	await _worker_mark("Controls")
	await _worker_mark("Power")


func _mark_setup_done() -> void:
	var st := autoload("Setup")
	if st != null:
		st._load()
		st._cfg.set_value("steps", "done", true)
		st._save()


## New fake system + every autoload on it. Also the per-test reset.
func _wire_services() -> void:
	fake = Fake.new(backends, root, repo, str(info["expect_row"]))
	hhd = HhdHttpFake.new(backends.get("hhd"), backends.get("hhd") != null)
	var dev := autoload("Device")
	dev.root = root
	dev.home = home
	dev.detect()
	row = dev.profile
	var power := autoload("Power")
	power.setup(fake, row, root, hhd)
	power.config_path = home.path_join(".config/gamecove/power.cfg")
	power.autotune_opts = power.AUTOTUNE_DEFAULTS.duplicate()
	power._queue("start", power._start)
	var gs := autoload("Gamescope")
	if gs.runner != null and gs.runner.has_method("shutdown"):
		gs.runner.shutdown()
	gs.runner = Fake.GamescopeRunner.new(fake)
	gs.env = session_env()
	gs.window_id = WINDOW_ID
	gs._running = 1
	var perf := autoload("PerfMonitor")
	perf.sys_root = root
	perf.env = session_env()
	perf.runner = fake
	perf.config_path = home.path_join(".config/gamecove/perf.cfg")
	perf._setup_done = false
	perf._setup()
	var launcher := autoload("Launcher")
	launcher.home = home
	launcher.root_prefix = root
	launcher.settings_path = home.path_join(".config/gamecove/launch_settings.json")
	if "env_hooks" in launcher:
		launcher.env_hooks.clear()
	launcher._loaded = false
	launcher._load()
	var lib := autoload("Library")
	lib.home = home
	var ctl := autoload("Controller")
	ctl.setup(fake, home, hhd)
	ctl.set_device(str(dev.id()))
	ctl.setup_intercept_for_tests()
	ctl.monitor_line({"kind": "started"})
	reset_controls()


func session_env() -> Dictionary:
	return Matrix.session_env(info, "battery").merged({"MANGOHUD_CONFIGFILE": root + "/run/user/1000/mangohud.conf",
		"PATH": "/usr/local/bin:/usr/bin:/bin", "XDG_CURRENT_DESKTOP": "gamescope"}, true)


## Fresh providers on the fixture (production loads them once; a test reset needs
## the same start every time) and Profiles starting over on its file.
func reset_controls() -> void:
	var c := autoload("Controls")
	c._mutex.lock()
	c._jobs.clear()
	c._mutex.unlock()
	c._controls = {}
	c._order = []
	c._cache_mutex.lock()
	c._cache = {}
	c._cache_mutex.unlock()
	ctx = {"sys_root": root, "runner": fake, "home": home, "device": autoload("Device"),
		"hhd_transport": hhd, "env": session_env(), "config_path": home.path_join(".config/gamecove/controls.cfg"),
		"power": autoload("Power"), "registry": c, "perf_monitor": autoload("PerfMonitor"),
		"launcher": autoload("Launcher"), "library": autoload("Library"),
		"perf_store_path": home.path_join(".config/gamecove/perf_controls.cfg"),
		# Gaming Mode: no polkit agent, so nothing can ask for the admin password
		"password_prompt": false}
	c.setup(ctx)
	c.load_providers()
	var p := autoload("Profiles")
	p.game_key = ""
	p.game_title = ""
	p._baseline.clear()
	p._pre_game.clear()
	p._first_detect_done = false
	p._seen_available = {}
	p.setup(c, str(autoload("Device").id()), PROFILES_FILE)
	p.attach_power(autoload("Power"))
	p.launcher = autoload("Launcher")
	c.detect_all()


# ---- the main scene ---------------------------------------------------------------

func boot_main() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	tree.root.add_child(main)
	tree.current_scene = main
	await frames(3)
	# main makes its own Fixes service and quick-menu command runner on the real
	# system: point them at the fixture too
	if main.fixes != null:
		main.fixes.setup({"sys_root": root, "runner": fake, "home": home, "device": autoload("Device")})
	main.quick_menu.commands.runner = Fake.BgRunner.new(fake)
	if main.session != null:
		main.session.pid_running = func(pid: int) -> bool: return fake_pids.has(pid)
		main.session.steam_alive = func(id: int) -> bool: return fake_apps.has(id)
	await idle()


var fake_pids := {}
var fake_apps := {}


func shutdown_main() -> void:
	if main != null and is_instance_valid(main):
		if main.session != null and main.session.is_active():
			main.session.stop()
		main.queue_free()
		await frames(2)
	main = null


# ---- per-test reset ---------------------------------------------------------------

## Back to the freshly generated handheld: files, services, profiles, UI at home.
func reset() -> void:
	set_readonly(false)
	if main != null:
		if main.quick_menu.visible:
			main.quick_menu.close()
		if main.session.is_active():
			main.session.stop()
		main.show_screen("home")
	fake_pids.clear()
	fake_apps.clear()
	await idle()
	restore_tree(pristine, root)
	var p := autoload("Profiles")
	p.reset_all()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILES_FILE))
	var launcher := autoload("Launcher")
	DirAccess.remove_absolute(launcher.settings_path)
	_wire_services()
	if main != null:
		main.fixes.setup({"sys_root": root, "runner": fake, "home": home, "device": autoload("Device")})
		main.quick_menu.commands.runner = Fake.BgRunner.new(fake)
	await idle()
	fake.reset_log()


## Copies `from` over `to`: changed files rewritten, extra files removed.
static func restore_tree(from: String, to: String) -> void:
	for f in DirAccess.get_files_at(from):
		var a := FileAccess.get_file_as_bytes(from.path_join(f))
		var dst := to.path_join(f)
		if not FileAccess.file_exists(dst) or FileAccess.get_file_as_bytes(dst) != a:
			var w := FileAccess.open(dst, FileAccess.WRITE)
			if w != null:
				w.store_buffer(a)
				w.close()
	for f in DirAccess.get_files_at(to):
		if not FileAccess.file_exists(from.path_join(f)):
			DirAccess.remove_absolute(to.path_join(f))
	for d in DirAccess.get_directories_at(from):
		DirAccess.make_dir_recursive_absolute(to.path_join(d))
		restore_tree(from.path_join(d), to.path_join(d))
	for d in DirAccess.get_directories_at(to):
		if not DirAccess.dir_exists_absolute(from.path_join(d)):
			Matrix._rm_tree(to.path_join(d))


# ---- waiting ------------------------------------------------------------------------

func frames(n := 1) -> void:
	for i in n:
		await tree.process_frame


## Waits until every worker (Controls, Power, Controller, Gamescope's runner) has
## nothing queued and the answers they sent back to the main thread have run.
func idle(max_ms := 10000) -> bool:
	var deadline := Time.get_ticks_msec() + max_ms
	var last := -1
	while Time.get_ticks_msec() < deadline:
		await _worker_mark("Controls")
		await _worker_mark("Power")
		await _worker_mark("Controller")
		var gs := autoload("Gamescope")
		while gs.runner != null and gs.runner.has_method("pending") and gs.runner.pending() > 0 and Time.get_ticks_msec() < deadline:
			await tree.process_frame
		await frames(2)
		var n: int = fake.log.size() if fake != null else 0
		if n == last:
			return true
		last = n
	return false


## Queues a marker job on a service's worker and waits for it (FIFO: everything
## queued before it has run).
func _worker_mark(svc: String) -> void:
	var s := autoload(svc)
	if s == null:
		return
	_marks += 1
	var box := [false]
	var job := func():
		box[0] = true
		return true
	match svc:
		"Controls":
			if s._thread == null:
				return
			s.run_on_worker(job)
		"Power":
			if s._thread == null:
				return
			s._queue("e2e-mark-%d" % _marks, job)
		"Controller":
			if s._thread == null or not s.is_inside_tree():
				return
			s._queue("e2e-mark-%d" % _marks, job)
	var deadline := Time.get_ticks_msec() + 10000
	while not box[0] and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	await tree.process_frame   # deferred emits from that job


# ---- faults -------------------------------------------------------------------------

## sysfs read-only for us (chattr +i as root, chmod otherwise): every direct
## write fails; reads still work.
func set_readonly(on: bool, under := "/sys") -> void:
	if not on:
		for f in readonly_files:
			_ro(f, false)
		readonly_files.clear()
		return
	var files := {}
	Matrix._walk(root, under, files)
	for rel in files:
		if rel.begins_with(under):
			readonly_files.append(root + rel)
			_ro(root + rel, true)


static func _ro(path: String, on: bool) -> void:
	if OS.get_environment("USER") == "root" or _uid() == 0:
		OS.execute("chattr", PackedStringArray(["+i" if on else "-i", path]))
	else:
		var r := FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_READ_GROUP | FileAccess.UNIX_READ_OTHER
		FileAccess.set_unix_permissions(path, r if on else (r | FileAccess.UNIX_WRITE_OWNER))


static var _uid_cache := -1


static func _uid() -> int:
	if _uid_cache == -1:
		var out := []
		OS.execute("id", PackedStringArray(["-u"]), out)
		_uid_cache = str(out[0]).strip_edges().to_int() if out.size() > 0 else 1000
	return _uid_cache


# ---- the charger --------------------------------------------------------------------

## Plugs the charger in or out the way the kernel shows it; Power notices on its
## next check (`notify` asks it now, as udev's power_supply event would).
func set_ac(on: bool, notify := true) -> void:
	Matrix._set_ac(info, on)
	if notify:
		# what Power's source timer (SOURCE_CHECK_S) does when it fires
		var p := autoload("Power")
		p._queue("source", func(): p.check_power_source(); return true)


# ---- the fixture -------------------------------------------------------------------

func read(rel: String) -> String:
	return Matrix._read(root + rel)


func write(rel: String, v: String) -> void:
	var f := FileAccess.open(root + rel, FileAccess.WRITE)
	if f != null:
		f.store_string(v + "\n")
		f.close()
