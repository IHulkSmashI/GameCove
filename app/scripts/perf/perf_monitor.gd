extends Node
## PerfMonitor: the running game's frame rate and frame time, package and GPU
## power, CPU/GPU load, temperatures and clocks, once a second, ONLY while a
## game runs and has focus. At idle nothing runs: no timer, no file open.
##
## Who calls what (docs/CONTRACTS.md "Performance"):
##   start(app_id, opts) / stop()   the screens agent, on GameSession
##                                  started / ended
##   set_focused(bool)              false while home is in front of the game
##   set_target_fps(fps)            the game's frame limit (0 = none)
##   set_overlay_level(0..3)        quick menu "Performance overlay"
## and Power: while Auto TDP runs (Power.autotune_changed) we sample even if
## nobody called start(), and every sample goes to Power.request_feed() (on
## Power's worker). Power reports "can't reach target" (autotune_limit).
##
## Each sample is read on a WorkerThreadPool task (plain file reads, see
## sources.gd and mangohud.gd; no process per sample) and published on the
## main thread through `sample`. Instances outside the tree (tests) do
## everything synchronously; tests call sample_now().

## One reading. Keys (always present; -1 = unknown):
##   time (unix s), app_id, fps (presented), fps_rendered (fps / frame-gen
##   multiplier), frame_ms, cpu_load, gpu_load (%), cpu_temp, gpu_temp (C),
##   package_w, gpu_w, cpu_w, battery_w (W), gpu_mhz,
##   sources {metric: "rapl" | "amdgpu" | "procfs" | "mangohud" | ...}
signal sample(data: Dictionary)
## Sampling started (true) or stopped (false).
signal running_changed(active: bool)
## The performance overlay level changed (0 off, 1 fps, 2 compact, 3 full).
signal overlay_changed(level: int)

const SettingsFile := preload("res://scripts/system/settings_file.gd")
const Sources := preload("res://scripts/perf/sources.gd")
const Math := preload("res://scripts/perf/perf_math.gd")
const MangoHud := preload("res://scripts/perf/mangohud.gd")
const Runner := preload("res://scripts/device/command_runner.gd")

const INTERVAL_S := 1.0
const CONFIG_PATH := "user://perf.cfg"
## A MangoHud value older than this isn't reused for a second without rows.
const HOLD_S := 2.5

## Filesystem prefix for every read ("" = real system).
var sys_root := ""
## Environment overrides for tests; a key here wins over the real environment.
var env: Dictionary = {}
var config_path := CONFIG_PATH
## Runs mangohudctl; tests swap in a fake.
var runner: RefCounted = Runner.new()
## Power (or a fake with autotune_active() and request_feed()); null = none.
var power: Object

var latest: Dictionary = {}
var app_id := 0
var fg_multiplier := 1.0
var target_fps := 0.0
var active := false
var focused := true
var mangohud: RefCounted

var _sampler: Sampler
var _timer: Timer
var _busy := false
## WorkerThreadPool tasks started and not yet waited for: every task must be
## waited for, or it outlives the pool at exit (GameCove crashed on the way out
## after any game had been measured).
var _tasks: Array[int] = []
var _auto_started := false   # started for Auto TDP, not by start()
var _setup_done := false


## Everything one game's sampling needs; a new one per start(), so a task
## still running for the last game can't mix its numbers into this one.
class Sampler extends RefCounted:
	const S := preload("res://scripts/perf/sources.gd")
	const M := preload("res://scripts/perf/perf_math.gd")
	var src: Dictionary
	var mh: RefCounted
	var app_id := 0
	var fg := 1.0
	var _prev_t := -1.0
	var _prev_stat: Array = []
	var _prev_pkg := -1
	var _prev_gpu_e := -1
	var _mh_last: Dictionary = {}
	var _mh_last_t := -1.0

	func _init(sources: Dictionary, mangohud: RefCounted) -> void:
		src = sources
		mh = mangohud

	func sample(now_s: float) -> Dictionary:
		var dt := now_s - _prev_t if _prev_t >= 0.0 else -1.0
		_prev_t = now_s
		var d := {
			"time": Time.get_unix_time_from_system(), "app_id": app_id,
			"fps": -1.0, "fps_rendered": -1.0, "frame_ms": -1.0,
			"cpu_load": -1.0, "gpu_load": -1.0, "cpu_temp": -1.0, "gpu_temp": -1.0,
			"package_w": -1.0, "gpu_w": -1.0, "cpu_w": -1.0, "battery_w": -1.0, "gpu_mhz": -1.0,
		}
		var used: Dictionary = S.describe(src)
		var srcs := {}
		# CPU load
		if src["proc_stat"] != "":
			var cur := M.parse_proc_stat(S.read_line(src["proc_stat"]))
			d["cpu_load"] = M.cpu_load(_prev_stat, cur)
			_prev_stat = cur
		# package power
		if src["rapl_pkg"] != "":
			var e := S.read_int(src["rapl_pkg"])
			d["package_w"] = M.energy_watts(_prev_pkg, e, dt, int(src["rapl_pkg_max"]))
			_prev_pkg = e
		elif src["gpu_power_is_package"]:
			var uw := S.read_int(src["gpu_power"])
			d["package_w"] = uw / 1_000_000.0 if uw >= 0 else -1.0
		# GPU power
		match used["gpu_w"]:
			"rapl-uncore":
				var e := S.read_int(src["rapl_gpu"])
				d["gpu_w"] = M.energy_watts(_prev_gpu_e, e, dt, int(src["rapl_gpu_max"]))
				_prev_gpu_e = e
			"amdgpu":
				var uw := S.read_int(src["gpu_power"])
				d["gpu_w"] = uw / 1_000_000.0 if uw >= 0 else -1.0
			"xe-hwmon", "i915-hwmon":
				var e := S.read_int(src["gpu_energy"])
				d["gpu_w"] = M.energy_watts(_prev_gpu_e, e, dt)
				_prev_gpu_e = e
		if src["gpu_busy"] != "":
			var b := S.read_int(src["gpu_busy"])
			d["gpu_load"] = float(b) if b >= 0 else -1.0
		if src["gpu_mhz"] != "":
			var f := S.read_int(src["gpu_mhz"])
			d["gpu_mhz"] = f * float(src["gpu_mhz_scale"]) if f >= 0 else -1.0
		if src["cpu_temp"] != "":
			var t := S.read_int(src["cpu_temp"])
			d["cpu_temp"] = t / 1000.0 if t > 0 else -1.0
		if src["gpu_temp"] != "":
			var t := S.read_int(src["gpu_temp"])
			d["gpu_temp"] = t / 1000.0 if t > 0 else -1.0
		d["battery_w"] = S.battery_watts(src["battery"])
		for k in used:
			if used[k] != "" and float(d.get(k, -1.0)) >= 0.0:
				srcs[k] = used[k]
		_merge_mangohud(d, srcs, now_s)
		d["fps_rendered"] = M.rendered_fps(d["fps"], fg)
		d["sources"] = srcs
		return d

	## Frame timings from mangoapp's log; its other columns only fill gaps.
	func _merge_mangohud(d: Dictionary, srcs: Dictionary, now_s: float) -> void:
		if mh == null:
			return
		var folded: Dictionary = M.fold_rows(mh.read_rows(now_s))
		if folded.has("fps"):
			_mh_last = folded
			_mh_last_t = now_s
		elif _mh_last_t >= 0.0 and now_s - _mh_last_t <= 2.5:  # PerfMonitor.HOLD_S
			folded = _mh_last  # log rows land on either side of our tick
		else:
			return
		if not folded.has("fps"):
			return
		d["fps"] = folded["fps"]
		srcs["fps"] = "mangohud"
		var ft: float = folded.get("frametime", 0.0)
		d["frame_ms"] = ft if ft > 0.0 else (1000.0 / folded["fps"] if folded["fps"] > 0.0 else -1.0)
		srcs["frame_ms"] = "mangohud"
		# 0 in MangoHud's log means "couldn't read"; loads may truly be 0 only with fps
		for pair in [["cpu_load", "cpu_load", 0.0], ["gpu_load", "gpu_load", 0.0],
				["cpu_temp", "cpu_temp", 0.1], ["gpu_temp", "gpu_temp", 0.1],
				["gpu_w", "gpu_power", 0.01], ["cpu_w", "cpu_power", 0.01]]:
			var key: String = pair[0]
			var col: String = pair[1]
			if float(d[key]) < 0.0 and folded.has(col) and float(folded[col]) >= float(pair[2]):
				d[key] = float(folded[col])
				srcs[key] = "mangohud"
		if float(d["gpu_mhz"]) < 0.0 and float(folded.get("gpu_core_clock", 0.0)) > 0.0:
			d["gpu_mhz"] = float(folded["gpu_core_clock"])
			srcs["gpu_mhz"] = "mangohud"


func _ready() -> void:
	if preload("res://scripts/system/run_mode.gd").helper():
		return   # --restore-baseline: no services (review 2, problem 5)
	_setup()
	_timer = Timer.new()
	_timer.wait_time = INTERVAL_S
	_timer.timeout.connect(_tick)
	add_child(_timer)
	_update_timer()  # start() may have come before we entered the tree
	if power == null:
		power = get_node_or_null("/root/Power")
	if power != null and power.has_signal("autotune_changed"):
		power.autotune_changed.connect(_on_autotune_changed)
	# the session starts mangoapp hidden; put back the level the player chose
	var lvl := int(_recall("overlay", "level", 0))
	if lvl > 0 and overlay_supported():
		set_overlay_level(lvl)


## Reads the environment once. Tests set sys_root/env/runner first; start()
## and the overlay calls run this themselves.
func _setup() -> void:
	if _setup_done:
		return
	_setup_done = true
	mangohud = MangoHud.new()
	mangohud.runner = runner
	mangohud.config_path = _env(MangoHud.ENV_CONFIG)
	var rt := _env("XDG_RUNTIME_DIR")
	mangohud.log_dir = (rt + "/gamecove-mangohud") if rt != "" else ProjectSettings.globalize_path("user://mangohud")
	mangohud.ctl = which("mangohudctl")
	mangohud.level = int(_recall("overlay", "level", 0))
	mangohud.override_lines = MangoHud._clean(_recall("overlay", "override", []))
	mangohud.extra_lines = MangoHud._clean(_recall("overlay", "extra", []))


# ---- sampling -------------------------------------------------------------------

## A game is running and in front. app_id is gamescope's id for it (0 if
## unknown). opts: {"frame_gen_multiplier": 2.0, "target_fps": 60}.
func start(game_app_id := 0, opts := {}) -> void:
	_setup()
	_auto_started = false
	app_id = game_app_id
	fg_multiplier = maxf(1.0, float(opts.get("frame_gen_multiplier", 1.0)))
	if opts.has("target_fps"):
		set_target_fps(float(opts["target_fps"]))
	if active:
		if _sampler != null:
			_sampler.app_id = app_id
			_sampler.fg = fg_multiplier
		return
	_begin()


## The game ended (or the app is closing).
func stop() -> void:
	if not active:
		return
	active = false
	_auto_started = false
	target_fps = 0.0
	_sampler = null
	_update_timer()
	var mh := mangohud
	mh.want_logging = false
	_run_off_main(func(): mh.sync(0.0))
	latest = {}
	running_changed.emit(false)


## Home (or anything else) in front of the game: pause; true resumes.
func set_focused(has_focus: bool) -> void:
	focused = has_focus
	_update_timer()


## The game's frame limit: Auto TDP's target for "can't reach" (0 = none).
func set_target_fps(fps: float) -> void:
	target_fps = maxf(0.0, fps)
	if power != null and power.has_method("request_autotune_target"):
		power.request_autotune_target(target_fps)


## Frame generation presents this many frames per rendered one (1 = off).
func set_frame_gen_multiplier(m: float) -> void:
	fg_multiplier = maxf(1.0, m)
	if _sampler != null:
		_sampler.fg = fg_multiplier


func is_active() -> bool:
	return active


## What this machine can report: {"fps": bool, "overlay": bool,
## "sources": {metric: source or ""}}. Reads sysfs: call once per screen.
func capabilities() -> Dictionary:
	_setup()
	var srcs: Dictionary = Sources.describe(Sources.discover(sys_root))
	var fps_ok: bool = mangohud.supported() and which("mangoapp") != ""
	srcs["fps"] = "mangohud" if fps_ok else ""
	srcs["frame_ms"] = srcs["fps"]
	return {"fps": fps_ok, "overlay": overlay_supported(), "fps_needs_overlay": fps_ok and mangohud.ctl == "", "sources": srcs}


## Takes one sample now, on this thread, and publishes it. The timer's task
## does the same off the main thread. Returns the sample ({} when inactive).
func sample_now(now_s := -1.0) -> Dictionary:
	if not active or _sampler == null:
		return {}
	var d := _sampler.sample(now_s if now_s >= 0.0 else Time.get_ticks_usec() / 1_000_000.0)
	_publish(d, _sampler)
	return d


func _begin() -> void:
	active = true
	_sampler = Sampler.new(Sources.discover(sys_root), mangohud)
	_sampler.app_id = app_id
	_sampler.fg = fg_multiplier
	var mh := mangohud
	var t0 := Time.get_ticks_usec() / 1_000_000.0
	mh.want_logging = true
	_run_off_main(func(): mh.sync(t0))
	_update_timer()
	running_changed.emit(true)


func _update_timer() -> void:
	if _timer == null or not _timer.is_inside_tree():
		return
	if active and focused:
		if _timer.is_stopped():
			_timer.start()
	else:
		_timer.stop()


func _tick() -> void:
	if _busy or _sampler == null:
		return
	_busy = true
	var s := _sampler
	_add_task(func():
		var d := s.sample(Time.get_ticks_usec() / 1_000_000.0)
		_publish_from_task.call_deferred(d, s))


func _publish_from_task(d: Dictionary, s: Sampler) -> void:
	_busy = false
	_publish(d, s)


func _publish(d: Dictionary, s: Sampler) -> void:
	if s != _sampler or not active:
		return  # a late sample from a stopped game
	latest = d
	if power != null and float(d["fps_rendered"]) > 0.0 and power.has_method("request_feed") \
			and power.autotune_active():
		power.request_feed(float(d["fps_rendered"]), float(d["package_w"]), d)
	sample.emit(d)


func _on_autotune_changed(on: bool) -> void:
	if on and target_fps > 0.0:
		set_target_fps(target_fps)  # Power forgets the target between games
	if on and not active:
		_setup()
		_begin()
		_auto_started = true
	elif not on and _auto_started:
		stop()


# ---- overlay --------------------------------------------------------------------

## True when the session runs mangoapp and gave us its config file.
func overlay_supported() -> bool:
	_setup()
	return mangohud.supported() and which("mangoapp") != ""


func overlay_level() -> int:
	_setup()
	return mangohud.level


## Names of the levels, index = level.
func overlay_levels() -> Array:
	return MangoHud.LEVEL_NAMES.duplicate()


## 0 off, 1 frame rate, 2 compact row, 3 full. Writes the session's
## MANGOHUD_CONFIGFILE (a tiny tmpfs write). False when unsupported.
func set_overlay_level(level: int) -> bool:
	if not overlay_supported():
		return false
	if not mangohud.set_level(level):
		return false
	_remember("overlay", "level", mangohud.level)
	overlay_changed.emit(mangohud.level)
	return true


## The overlay's look beyond the level (perf controls: "bar" and "custom"
## presets replace the level's lines; position / opacity / scale are added).
## Remembered with the level. False when unsupported.
func set_overlay_style(override: Array, extra: Array) -> bool:
	if not overlay_supported():
		return false
	if not mangohud.set_style(override, extra):
		return false
	_remember("overlay", "override", mangohud.override_lines)
	_remember("overlay", "extra", mangohud.extra_lines)
	overlay_changed.emit(mangohud.level)
	return true


# ---- helpers --------------------------------------------------------------------

## Full path of a program on PATH (file check only, no process), or "".
func which(program: String) -> String:
	for dir in _env("PATH").split(":", false):
		var p: String = sys_root + dir + "/" + program
		if FileAccess.file_exists(p):
			return dir + "/" + program
	return ""


func _env(name: String) -> String:
	return str(env[name]) if env.has(name) else OS.get_environment(name)


func _run_off_main(job: Callable) -> void:
	if is_inside_tree():
		_add_task(job)
	else:
		job.call()


func _add_task(job: Callable) -> void:
	for t in _tasks.filter(func(t): return WorkerThreadPool.is_task_completed(t)):
		WorkerThreadPool.wait_for_task_completion(t)   # frees it; returns at once
		_tasks.erase(t)
	_tasks.append(WorkerThreadPool.add_task(job, false, "GameCove perf sample"))


func _exit_tree() -> void:
	for t in _tasks:
		WorkerThreadPool.wait_for_task_completion(t)
	_tasks.clear()


func _remember(section: String, key: String, value: Variant) -> void:
	SettingsFile.update_cfg(config_path, func(cfg: ConfigFile): cfg.set_value(section, key, value))


func _recall(section: String, key: String, fallback: Variant) -> Variant:
	return SettingsFile.load_cfg(config_path).get_value(section, key, fallback)
