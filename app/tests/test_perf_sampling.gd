extends "res://tests/test_case.gd"
## PerfMonitor's sampling against fake sysfs trees (Claw 8 EX: Intel xe + RAPL;
## Steam Deck: amdgpu APU) and a fake MangoHud log. Nothing real is read:
## every path starts with a fixture root and commands go to a recording runner.

const Monitor := preload("res://scripts/perf/perf_monitor.gd")
const Sources := preload("res://scripts/perf/sources.gd")
const Math := preload("res://scripts/perf/perf_math.gd")
const MangoHud := preload("res://scripts/perf/mangohud.gd")


class Rec extends RefCounted:
	var calls: Array[String] = []
	func run(program: String, args: PackedStringArray) -> Dictionary:
		calls.append(program + " " + " ".join(args))
		return {"code": 0, "exit": 0, "out": "", "output": ""}


class FakePower extends Object:
	signal autotune_changed(on: bool)
	var on := false
	var fed: Array = []
	var targets: Array = []
	func autotune_active() -> bool:
		return on
	func request_feed(fps: float, watts := -1.0, _sample := {}) -> void:
		fed.append([fps, watts])
	func request_autotune_target(fps: float) -> void:
		targets.append(fps)


func _copy(src: String, dst: String) -> void:
	DirAccess.make_dir_recursive_absolute(dst)
	var d := DirAccess.open(src)
	for f in d.get_files():
		DirAccess.copy_absolute(src + "/" + f, dst + "/" + f)
	for sub in d.get_directories():
		_copy(src + "/" + sub, dst + "/" + sub)


func _rmdir(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(path + "/" + f)
	for sub in d.get_directories():
		_rmdir(path + "/" + sub)
	DirAccess.remove_absolute(path)


func _tree(fixture_name: String, test_name: String) -> String:
	var dst := ProjectSettings.globalize_path("user://test_perf/" + test_name)
	_rmdir(dst)
	_copy(fixture("perf/" + fixture_name), dst)
	return dst


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text + "\n")
	f.close()


func _monitor(root: String, extra_env := {}) -> Node:
	var m: Node = Monitor.new()
	m.sys_root = root
	m.config_path = root + "/perf.cfg"
	m.runner = Rec.new()
	var e := {"PATH": "/usr/bin", "MANGOHUD_CONFIGFILE": "", "XDG_RUNTIME_DIR": root + "/run"}
	e.merge(extra_env, true)
	m.env = e
	return m


# ---- math -------------------------------------------------------------------------

func test_proc_stat_and_cpu_load() -> void:
	var a := Math.parse_proc_stat("cpu  1000 0 500 8000 500 0 0 0 0 0")
	eq(a, [1500, 10000], "busy excludes idle and iowait")
	var b := Math.parse_proc_stat("cpu  1600 0 700 8600 600 0 0 0 0 0")
	eq(Math.cpu_load(a, b), 800.0 / 1500.0 * 100.0, "busy share of the jiffies between readings")
	eq(Math.cpu_load([], b), -1.0, "first reading: unknown")
	eq(Math.parse_proc_stat("cpu0 1 2 3 4 5"), [], "per-core line is not the aggregate")
	eq(Math.cpu_load(b, b), -1.0, "no time passed")


func test_energy_counter_watts_and_wrap() -> void:
	eq(Math.energy_watts(1_000_000, 16_000_000, 1.0), 15.0, "15 J in 1 s")
	eq(Math.energy_watts(1_000_000, 11_000_000, 2.0), 5.0, "over 2 s")
	ok(absf(Math.energy_watts(262_143_000_000, 9_328_850, 1.0, 262_143_328_850) - 9.6577) < 1e-9, "wraps at max_energy_range_uj")
	eq(Math.energy_watts(500, 100, 1.0), -1.0, "a wrap without the range is unknown")
	eq(Math.energy_watts(-1, 100, 1.0), -1.0, "no earlier reading")


func test_rendered_fps_and_means() -> void:
	eq(Math.rendered_fps(120.0, 2.0), 60.0, "2x frame generation")
	eq(Math.rendered_fps(90.0, 0.5), 90.0, "multiplier below 1 counts as off")
	eq(Math.rendered_fps(-1.0, 2.0), -1.0, "unknown stays unknown")
	eq(Math.mean_known([10.0, -1.0, 20.0]), 15.0, "unknowns skipped")
	eq(Math.mean_known([-1.0]), -1.0, "nothing known")


func test_mangohud_log_parsing_in_pieces() -> void:
	var mh: RefCounted = MangoHud.new()
	var text := FileAccess.get_file_as_string(fixture("perf/mangohud_log.csv"))
	var cut := text.find("60.2,") + 3  # split in the middle of a row
	var rows: Array = mh.parse_chunk(text.substr(0, cut))
	eq(rows.size(), 1, "system info lines skipped, unfinished row held back")
	eq(rows[0]["fps"], 59.8, "fps column by header name")
	rows = mh.parse_chunk(text.substr(cut))
	eq(rows.size(), 1, "rest of the row arrives")
	eq(rows[0]["frametime"], 16.61, "frametime")
	var folded := Math.fold_rows([{"fps": 59.8, "gpu_load": 88.0}, {"fps": 60.2, "gpu_load": 90.0}])
	eq(folded["fps"], 60.0, "rows since last sample averaged")
	eq(folded["gpu_load"], 89.0, "load averaged")
	eq(Math.fold_rows([]), {}, "no rows: nothing")


# ---- sources ----------------------------------------------------------------------

func test_discover_claw_intel_xe() -> void:
	var s := Sources.discover(fixture("perf/sys_claw"))
	eq(s["gpu_vendor"], "intel", "Intel GPU")
	eq(s["gpu_driver"], "xe", "xe by its freq0 folder")
	ok(s["rapl_pkg"].ends_with("intel-rapl:0/energy_uj"), "RAPL package zone, not the core subzone")
	eq(s["rapl_pkg_max"], 262143328850, "wrap range read")
	ok(s["cpu_temp"].contains("hwmon4"), "coretemp chosen over acpitz")
	var d := Sources.describe(s)
	eq(d["package_w"], "rapl", "package power from RAPL")
	eq(d["gpu_load"], "", "no sysfs GPU load on Intel")
	eq(d["gpu_mhz"], "xe", "GPU clock from xe")
	eq(d["gpu_temp"], "", "integrated Intel has no GPU hwmon")


func test_discover_deck_amd_apu() -> void:
	var s := Sources.discover(fixture("perf/sys_deck"))
	eq(s["gpu_vendor"], "amd", "AMD GPU")
	ok(s["gpu_power_is_package"], "1 GiB carve-out: an APU, so its power is the package's")
	var d := Sources.describe(s)
	eq(d["package_w"], "amdgpu", "package power from amdgpu")
	eq(d["gpu_w"], "", "not counted twice as GPU power")
	eq(d["gpu_load"], "amdgpu", "gpu_busy_percent")
	eq(d["cpu_temp"], "hwmon", "k10temp")


func test_unreadable_rapl_is_skipped() -> void:
	var root := _tree("sys_claw", "rapl_locked")
	_write(root + "/sys/class/powercap/intel-rapl:0/energy_uj", "")  # what a 0400 file reads as
	var s := Sources.discover(root)
	eq(s["rapl_pkg"], "", "not offered when it can't be read")
	eq(Sources.describe(s)["package_w"], "", "package power unknown")


# ---- monitor ----------------------------------------------------------------------

func test_nothing_runs_at_idle() -> void:
	var m := _monitor(_tree("sys_claw", "idle"))
	eq(m.sample_now(1.0), {}, "no sample before start()")
	ok(not m.is_active(), "inactive")
	m.start(1234)
	m.stop()
	eq(m.sample_now(2.0), {}, "none after stop()")
	eq(m.latest, {}, "latest cleared")
	m.free()


func test_claw_samples_deltas_and_feeds_autotune() -> void:
	var root := _tree("sys_claw", "claw")
	var m := _monitor(root, {"MANGOHUD_CONFIGFILE": root + "/run/mangohud.cfg"})
	var p := FakePower.new()
	p.on = true
	m.power = p
	var got: Array = []
	m.sample.connect(func(d): got.append(d))
	m.start(1234, {"frame_gen_multiplier": 2.0, "target_fps": 60})
	eq(p.targets, [60.0], "target passed to Power")
	var first: Dictionary = m.sample_now(10.0)
	eq(first["cpu_load"], -1.0, "first sample has no delta yet")
	eq(first["package_w"], -1.0, "nor package power")
	eq(first["cpu_temp"], 71.0, "coretemp in C")
	eq(first["gpu_mhz"], 1850.0, "xe act_freq")
	eq(first["battery_w"], 21.5, "battery draw while discharging")
	_write(root + "/proc/stat", "cpu  1600 0 700 8600 600 0 0 0 0 0")
	_write(root + "/sys/class/powercap/intel-rapl:0/energy_uj", "15000000")
	# mangoapp's log: two rows of 120 presented fps (frame generation on)
	var log_dir: String = root + "/run/gamecove-mangohud"
	DirAccess.make_dir_recursive_absolute(log_dir)
	_write(log_dir + "/mangoapp_2026-11-08_10-00-00.csv",
		"fps,frametime,cpu_load,cpu_power,gpu_load,cpu_temp,gpu_temp,gpu_core_clock,gpu_power\n" +
		"119,8.4,30,0,92,0,0,1850,0\n121,8.2,32,0,94,0,0,1850,0")
	var d: Dictionary = m.sample_now(12.0)
	ok(absf(d["cpu_load"] - 800.0 / 1500.0 * 100.0) < 0.001, "cpu load from /proc/stat delta (%s)" % d["cpu_load"])
	eq(d["package_w"], 7.0, "14 J over 2 s")
	eq(d["fps"], 120.0, "presented fps from mangoapp's log")
	eq(d["fps_rendered"], 60.0, "rendered = presented / 2")
	ok(absf(d["frame_ms"] - 8.3) < 0.0001, "frame time from the log (%s)" % d["frame_ms"])
	eq(d["gpu_load"], 93.0, "Intel GPU load filled in from the log")
	eq(d["sources"]["package_w"], "rapl", "source named")
	eq(d["sources"]["gpu_load"], "mangohud", "gap filled by mangohud")
	ok(not d["sources"].has("gpu_temp"), "unknown values name no source")
	eq(p.fed, [[60.0, 7.0]], "Auto TDP fed rendered fps and package watts (none without fps)")
	eq(got.size(), 2, "both samples published")
	eq(m.latest, d, "latest value kept")
	m.stop()
	p.free()
	m.free()


func test_deck_apu_package_power() -> void:
	var m := _monitor(_tree("sys_deck", "deck"))
	m.start(0)
	var d: Dictionary = m.sample_now(1.0)
	eq(d["package_w"], 12.5, "amdgpu power1_average in W")
	eq(d["gpu_load"], 67.0, "gpu_busy_percent")
	eq(d["gpu_temp"], 58.0, "amdgpu temp")
	eq(d["gpu_mhz"], 1600.0, "freq1_input Hz -> MHz")
	eq(d["cpu_temp"], 64.0, "k10temp")
	eq(d["battery_w"], -1.0, "charging: no battery draw")
	eq(d["fps"], -1.0, "no mangoapp config: no fps")
	m.stop()
	m.free()


func test_fps_held_between_log_rows() -> void:
	var root := _tree("sys_claw", "hold")
	var m := _monitor(root, {"MANGOHUD_CONFIGFILE": root + "/run/mangohud.cfg"})
	var log_dir: String = root + "/run/gamecove-mangohud"
	m.start(1)
	_write(log_dir + "/g_1.csv", "fps,frametime\n45,22.2")
	eq(m.sample_now(1.0)["fps"], 45.0, "row read")
	eq(m.sample_now(2.0)["fps"], 45.0, "no new row this second: last value held")
	eq(m.sample_now(4.0)["fps"], -1.0, "no rows for 3 s: unknown")
	m.stop()
	m.free()


func test_autotune_starts_and_stops_sampling() -> void:
	var m := _monitor(_tree("sys_claw", "auto"))
	var p := FakePower.new()
	m.power = p
	p.autotune_changed.connect(m._on_autotune_changed)
	p.on = true
	p.autotune_changed.emit(true)
	ok(m.is_active(), "Auto TDP on: sampling without start()")
	p.on = false
	p.autotune_changed.emit(false)
	ok(not m.is_active(), "Auto TDP off: stopped again")
	m.start(5)
	p.autotune_changed.emit(false)
	ok(m.is_active(), "a game started by start() keeps sampling after Auto TDP stops")
	m.stop()
	p.free()
	m.free()


func test_stale_sample_from_last_game_is_dropped() -> void:
	var m := _monitor(_tree("sys_claw", "stale"))
	m.start(1)
	var old = m._sampler
	var d: Dictionary = old.sample(1.0)
	m.stop()
	m.start(2)
	var got := []
	m.sample.connect(func(x): got.append(x))
	m._publish(d, old)
	eq(got.size(), 0, "sample from the previous game ignored")
	m.stop()
	m.free()


## PerfMonitor's sample and mangohud tasks were never waited for: after any
## game had been measured GameCove crashed on exit (a WorkerThreadPool task
## outliving the pool, SIGABRT in pthread_mutex_lock). Tasks are kept and
## waited for now. Found by the end-to-end suite.
func test_tasks_are_waited_for() -> void:
	var pm: Node = load("res://scripts/perf/perf_monitor.gd").new()
	var box := {"done": false}
	pm._add_task(func():
		OS.delay_msec(150)
		box["done"] = true)
	eq(pm._tasks.size(), 1, "the task is kept")
	pm._exit_tree()   # leaving the tree (the app quits)
	ok(box["done"], "leaving the tree waited for it")
	eq(pm._tasks.size(), 0, "nothing left behind")
	pm._add_task(func(): pass)
	OS.delay_msec(50)
	pm._add_task(func(): pass)
	eq(pm._tasks.size(), 1, "finished tasks are freed when the next one starts")
	pm._exit_tree()
	pm.free()


func test_samples_only_while_someone_uses_them() -> void:
	var m := _monitor(_tree("sys_claw", "wanted"))
	var p := FakePower.new()
	m.power = p
	m.start(5)
	ok(not m.wanted(), "a game with nobody using the numbers: no sampling behind it")
	p.on = true
	ok(m.wanted(), "Auto TDP on: every sample feeds it")
	p.on = false
	m._on_autotune_changed(true)
	ok(m.wanted(), "told Auto TDP started (its state may lag on Power's worker)")
	m._on_autotune_changed(false)
	ok(not m.wanted(), "Auto TDP stopped")
	var got := []
	var listener := func(d): got.append(d)
	m.sample.connect(listener)
	ok(m.wanted(), "a listener on `sample` keeps it sampling")
	m.sample.disconnect(listener)
	ok(not m.wanted(), "and only while it listens")
	m.stop()
	p.free()
	m.free()
