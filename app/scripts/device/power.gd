extends Node
## Power: TDP, profiles, fan and charge limit. Talks to the system services
## that already exist instead of a daemon of our own:
##   steamos-manager  (user bus)   com.steampowered.SteamOSManager1
##   PowerStation     (system bus) org.shadowblip.PowerStation
##   Handheld Daemon  (HTTP, 127.0.0.1:5335, scripts/input/hhd.gd) when its TDP
##                    plugin (adjustor) manages TDP ("hhd.settings.tdp_enable"):
##                    then hhd owns TDP, fan curves and charge limit, and writing
##                    them through PowerStation, steamos-manager or our fixes would
##                    fight it (it re-applies its own values). So the TDP goes
##                    through hhd's API, and fan / charge limit are left to hhd.
## and, for fan curves and charge limits neither offers, to the root actions in
## fixes/ through `pkexec /usr/libexec/gamecove/gamecove-fix-set <name> set <value>`
## (the entry point polkit allows without a password; see docs/CONTRACTS.md).
## Whether a fix is in use is read unprivileged with
## `/usr/libexec/gamecove/gamecove-fix <name> status` (installed=yes|no).
##
## Every command goes through `runner` (command_runner.gd) and every sysfs read
## starts with `sys_root`, so tests swap both. No polling: values are read once
## at start and after each change; a 15 s check of the charger (one sysfs read)
## switches the remembered profile when you plug in or unplug.
##
## Threading: busctl and pkexec can take seconds (pkexec may wait on a polkit
## agent), so the running app does all of that on one worker thread. The UI
## calls request_set(); each setting keeps only its newest value, so dragging
## the TDP slider writes once per pause, not once per step. Results come back
## on the main thread as `applied` and `changed`. Instances that never enter
## the tree (tests) have no worker and run everything synchronously.

signal changed(state: Dictionary)
## A request_set() finished: setting is "profile", "tdp", "charge_limit" or "fan".
signal applied(setting: String, ok: bool)
## Auto TDP started (true) or stopped (false). PerfMonitor listens to sample
## while it runs. Always arrives on the main thread.
signal autotune_changed(on: bool)
## Auto TDP can't (true) or can again (false) hold the target frame rate at the
## TDP the user allows. info: {"cant_reach", "target_fps", "fps", "tdp_w",
## "ceiling_w", "ref_fps", "tdp_max"}; ceiling_w < tdp_max means raising the TDP
## may help, otherwise lower the game's settings or frame limit. Main thread.
signal autotune_limit(cant_reach: bool, info: Dictionary)
## The charger was plugged in (true) or out. Main thread. Profiles listen.
signal source_changed(plugged: bool)
## Battery percent changed (from the 15 s charger check; one sysfs read). Main thread.
signal battery_level(percent: int, plugged: bool)
## After a resume from sleep, once the TDP was put back (main.gd calls request_refresh()).
## Providers re-apply what the firmware may have reset. Main thread.
signal resumed()

const Runner := preload("res://scripts/device/command_runner.gd")
const Busctl := preload("res://scripts/device/busctl.gd")
const AutotuneScript := preload("res://scripts/device/autotune.gd")
const DeviceScript := preload("res://scripts/device/device.gd")
const Hhd := preload("res://scripts/input/hhd.gd")
const HhdHttp := preload("res://scripts/input/hhd_http.gd")
const PerDevice := preload("res://scripts/device/per_device.gd")
const SettingsFile := preload("res://scripts/system/settings_file.gd")
const Backend := preload("res://scripts/controls/power/backend.gd")
const Levers := preload("res://scripts/controls/power/levers.gd")
const ThermalGuard := preload("res://scripts/controls/power/thermal_guard.gd")
const RunMode := preload("res://scripts/system/run_mode.gd")
## power.cfg sections kept per device ("<name>@<device id>", see per_device.gd).
const DEVICE_SECTIONS: Array[String] = ["profile", "custom_w", "device"]
## Auto TDP options (power.autotune_* controls), defaults as ClawDeck's.
const AUTOTUNE_DEFAULTS := {"target": 0, "auto_fps": true, "keep_pct": 5.0, "floor_w": 0, "plugged": false}
## Package power is read through PowerStation's GpuBusyPercent at most this often (ClawDeck BUSY_EVERY_S).
const BUSY_EVERY_S := 10.0

# PowerStation (GPL-3.0): src/constants.rs, src/performance/gpu/dbus/{gpu,tdp}.rs
const PS_SERVICE := "org.shadowblip.PowerStation"
const PS_GPU_PATH := "/org/shadowblip/Performance/GPU"
const PS_GPU_IFACE := "org.shadowblip.GPU"            # EnumerateCards() -> ao
const PS_TDP_IFACE := "org.shadowblip.GPU.Card.TDP"   # TDP d, MinTdp d, MaxTdp d, Boost d, MaxBoost d
# steamos-manager (MIT): data/interfaces/com.steampowered.SteamOSManager1.xml
const SM_SERVICE := "com.steampowered.SteamOSManager1"
const SM_PATH := "/com/steampowered/SteamOSManager1"
const SM_TDP_IFACE := "com.steampowered.SteamOSManager1.TdpLimit1"              # TdpLimit u, TdpLimitMin u, TdpLimitMax u
const SM_CHARGE_IFACE := "com.steampowered.SteamOSManager1.BatteryChargeLimit1" # MaxChargeLevel i, SuggestedMinimumLimit i
const SM_FAN_IFACE := "com.steampowered.SteamOSManager1.FanControl1"            # FanControlState u: 0 BIOS, 1 OS

const FIX_HELPER := "/usr/libexec/gamecove/gamecove-fix"
const FIX_SET_HELPER := "/usr/libexec/gamecove/gamecove-fix-set"
const CONFIG_PATH := "user://power.cfg"
const PROFILES: Array[String] = ["battery", "balanced", "performance"]
## Fan presets for the msi_wmi_platform tables, in EC percent per point (ClawDeck's
## known-good Claw presets). Must match fixes/fan/fix.sh.
# Quiet ends at full speed at the hottest point (review L6); must match fixes/fan/fix.sh table_for.
const FAN_TABLES := {"quiet": [0, 40, 40, 45, 60, 100], "max": [100, 100, 100, 100, 100, 100]}
const FIX_FAN_MODES: Array[String] = ["quiet", "auto", "max"]
## Fan drivers the `fan` fix drives, keyed by devices.json "fan". Must match
## fixes/fan/fix.sh. "hwmon": hwmon names to look for; "kind": table (duty
## tables, pwmN_auto_pointM_pwm) or manual (one duty, pwm1); "auto": the
## pwmN_enable value for the firmware's own control per hwmon name ("" = 2);
## "full": enable values that mean full speed. Quiet only where a table exists.
const FAN_DRIVERS := {
	"msi_wmi_platform": {"hwmon": ["msi_wmi_platform"], "kind": "table", "points": 6,
		"modes": ["quiet", "auto", "max"], "tables": FAN_TABLES},
	"asus_custom_fan_curve": {"hwmon": ["asus_custom_fan_curve"], "kind": "table", "points": 8,
		"modes": ["quiet", "auto", "max"],
		"tables": {"quiet": [2, 5, 17, 35, 55, 75, 75, 100], "max": [100, 100, 100, 100, 100, 100, 100, 100]}},
	"oxp_ec": {"hwmon": ["oxp_ec", "oxpec"], "kind": "manual", "modes": ["auto", "max"],
		"auto": {"oxpec": "0"}, "full": {"oxp_ec": "0"}},
	"ayaneo_ec": {"hwmon": ["ayaneo_ec"], "kind": "manual", "modes": ["auto", "max"]},
	"gpdfan": {"hwmon": ["gpdfan", "gpd_fan"], "kind": "manual", "modes": ["auto", "max"], "full": {"gpdfan": "0", "gpd_fan": "0"}},
	"zotac_zone_platform": {"hwmon": ["zotac_zone_platform", "zotac_platform"], "kind": "manual", "modes": ["auto", "max"]},
}
const CHARGE_STATE_DIR := "/var/lib/gamecove/fixes/charge-limit"
const SM_FAN_MODES: Array[String] = ["auto", "firmware"]
const CHARGE_MIN := 50
const SOURCE_CHECK_S := 15.0

var runner: RefCounted
var system_bus: RefCounted
var user_bus: RefCounted
## Row of devices.json for this handheld ({} when unknown).
var device: Dictionary = {}
var sys_root := ""
var config_path := CONFIG_PATH
var fix_helper := FIX_HELPER
var fix_set_helper := FIX_SET_HELPER
var autotune: RefCounted = AutotuneScript.new()
## Power levers below the TDP (CPU, GPU, RAPL...), shared with the power.* controls.
var be: RefCounted
var levers: RefCounted
var guard: RefCounted = ThermalGuard.new()
var autotune_opts := AUTOTUNE_DEFAULTS.duplicate()
var _game_key := ""
var _thermald_checked := false
var _thermald_held := false
var _thermald_try_ms := 0
const THERMALD_RETRY_MS := 30000
var _guard_timer: Timer
var _guard_base_w := -1.0   # the TDP before the guard's first step (no user pick this run)
var _busy := -1
var _busy_at := -1000.0
var _battery_pct := -1
## Boost watts above the TDP the user picked on PowerStation (PL2 - PL1 / SPPT above SPL);
## -1 = the device's default (devices.json pl2_offset_w, else what PowerStation keeps).
var boost_w := -1.0
## True while a game's profile layer is in effect (Profiles sets it): what it writes is
## applied but not remembered as the everyday value (review H2).
var game_layer := false
## PowerStation's boost as last seen awake (detect, TDP writes): put back after a sleep when the
## user never picked one (-1 unknown).
var _live_boost := -1.0
## Handheld Daemon client; setup() swaps its transport in tests.
var hhd: RefCounted = Hhd.new()
var _hhd_tdp := {}      # Hhd.tdp_info() while backend == "hhd"

var backend := "none"
var plugged := false
var _ps_card := ""
var _tdp_w := -1.0
var _range := {"min": -1.0, "battery_max": -1.0, "plugged_max": -1.0}
var _profile := ""
var _charge_via := ""   # "steamos-manager" | "fix" | ""
var _charge_mode := ""  # fix: "threshold" (charge_control_end_threshold) | "behaviour" (charge_behaviour)
var _charge_path := ""
var _charge := -1
var _charge_min := CHARGE_MIN
var _fan_via := ""      # "steamos-manager" | "fix" | ""
var _fan_mode := ""
var _fan_driver := ""   # key of FAN_DRIVERS while _fan_via == "fix"
var _fan_hwmon := ""    # its hwmon folder (with a trailing /)
var _fan_hwmon_name := ""
## Settings this handheld has but that only the root helper can write, while it isn't
## installed (a source checkout, or before the installer ran): {"charge_limit": bool, "fan": bool}.
var _needs_helper := {"charge_limit": false, "fan": false}
var _svc_range := {}    # {"min", "max"} the TDP service reported, {} when none
var _autotune_on := false
var _autotune_stopping := false  # request_autotune(false) queued: drop samples until it runs
var _user_tdp := -1.0   # what the user picked; autotune works under it
var _limit_shown := false  # last cant_reach reported through autotune_limit
var _timer: Timer
var _thread: Thread
var _jobs := {}               # name -> Callable, newest wins
var _job_order: Array = []
var _job_mutex := Mutex.new()
var _job_sem := Semaphore.new()
var _quit := false

# ---- what the handheld had before GameCove, and leaving it that way (final review, session) ----
## The TDP, boost and fan mode read at start, before restore() puts GameCove's own back, are
## kept in this file (next to power.cfg) for as long as GameCove's session lasts. When the
## session is left for Steam or the desktop, `--restore-baseline` (run by the session, see
## profiles.gd) writes them back with restore_before(), so the next session finds the handheld
## as it was instead of at GameCove's profile, boost and fan mode. Keyed by the boot: a
## GameCove that restarts in the same boot (a crash, an update) keeps the first record, since
## what it would read then is its own values.
const BEFORE_FILE := "power_before.json"
const BOOT_ID := "/proc/sys/kernel/random/boot_id"
var before_path := ""
## True from prepare_leave() on: a session switch is under way, so nothing here writes any
## more (Auto TDP, the charge hold, the thermald hold, the 15 s check, the thermal guard).
## cancel_leave() turns it off again when the switch didn't happen.
var leaving := false


func _ready() -> void:
	var dev := get_node_or_null("/root/Device")
	setup(Runner.new(), dev.profile if dev else {}, "", HhdHttp.new())
	_thread = Thread.new()
	_thread.start(_worker)
	# detection runs several busctl calls; restore may run a root action
	_queue("start", _start)


func _exit_tree() -> void:
	if _thread == null:
		return
	_job_mutex.lock()
	_quit = true
	_job_mutex.unlock()
	_job_sem.post()
	_thread.wait_to_finish()
	_thread = null


func _start() -> bool:
	detect()
	load_autotune_opts()
	if not RunMode.helper():
		record_before()   # before restore(): what is live now is what the handheld had without us
	restore()
	# always: besides the charger it notices a sleep while a game is in front (review M19)
	_start_timer.call_deferred()
	_emit_changed()
	return true


func _start_timer() -> void:
	_timer = Timer.new()
	_timer.wait_time = SOURCE_CHECK_S
	_timer.timeout.connect(func(): _queue("source", func(): source_tick(); return true))
	add_child(_timer)
	_timer.start()


func _before_file() -> String:
	return before_path if before_path != "" else config_path.get_base_dir().path_join(BEFORE_FILE)


func _boot() -> String:
	return DeviceScript.read_text(sys_root + BOOT_ID)


## Notes the live TDP, boost and fan mode, once per boot (see BEFORE_FILE). Call after detect().
func record_before() -> bool:
	var boot := _boot()
	var have: Variant = SettingsFile.load_json(_before_file()).get("data")
	if have is Dictionary and boot != "" and str(have.get("boot", "")) == boot:
		return false   # already noted this boot: what is live now is ours
	var rec := {"boot": boot, "backend": backend, "tdp_w": _tdp_w if backend != "none" else -1.0,
		"boost_w": _live_boost if backend == "powerstation" else -1.0, "fan_mode": _fan_mode, "fan_via": _fan_via}
	return SettingsFile.save_json(_before_file(), rec, "\t") == OK


## Writes back what record_before() noted and forgets it. Nothing is remembered as the user's
## choice (GameCove's own profile, boost and fan mode stay as they are in power.cfg), and the
## TDP is never set past the limit of the power source we're on now. True when something was
## written.
func restore_before() -> bool:
	var saved: Variant = SettingsFile.load_json(_before_file()).get("data")
	if FileAccess.file_exists(SettingsFile.abs_path(_before_file())):
		DirAccess.remove_absolute(SettingsFile.abs_path(_before_file()))
	if not saved is Dictionary or str(saved.get("boot", "")) != _boot() or _boot() == "":
		return false   # from another boot (or unreadable): the values there mean nothing now
	var any := false
	var w := float(saved.get("tdp_w", -1.0))
	if backend != "none" and str(saved.get("backend", "")) == backend and w > 0.0:
		if tdp_max() > 0.0:
			w = minf(w, tdp_max())
		var b := float(saved.get("boost_w", -1.0))
		var ours := boost_w
		boost_w = b   # write_tdp writes TDP and boost in the safe order; -1 leaves the boost alone
		var boost_differs := b >= 0.0 and absf(b - _live_boost) >= 0.05
		if absf(w - _tdp_w) >= 0.05 or boost_differs:
			any = write_tdp(w)
		boost_w = ours
	var f := str(saved.get("fan_mode", ""))
	# "custom" was someone's curve, which we never read: nothing to put back
	if f != "" and f != "custom" and f != _fan_mode and _fan_via != "" and str(saved.get("fan_via", "")) == _fan_via and f in fan_modes():
		if _fan_via != "fix" or fix_installed("fan"):
			any = _write_fan_mode(f) == f or any
	return any


## A session switch is about to start (quick menu): stop everything that keeps writing, on the
## worker, so the restores that follow (the session's --restore-baseline and the root helper)
## are the last word. Auto TDP stops first and puts its levers and the user's TDP back.
func prepare_leave() -> bool:
	_autotune_stop(true)
	leaving = true
	_stop_timers.call_deferred()
	return true


## The switch didn't happen (it failed or timed out): back to normal, with our values in place.
func cancel_leave() -> bool:
	if not leaving:
		return false
	leaving = false
	_thermald_checked = false
	_resume_timers.call_deferred()
	restore()
	return true


## prepare_leave() on the worker; `done` (optional) is called on the main thread afterwards.
func request_leave(done := Callable()) -> void:
	_queue("leave", func():
		prepare_leave()
		if done.is_valid():
			_emit_main_call(done)
		return true)


## restore_before() on the worker (after whatever it is still doing: the start's detect and
## restore), then `done` on the main thread. The --restore-baseline run ends with this.
func request_restore_before(done := Callable()) -> void:
	_queue("before", func():
		restore_before()
		if done.is_valid():
			_emit_main_call(done)
		return true)


func request_cancel_leave() -> void:
	_queue("leave", func(): cancel_leave(); return true)


func _emit_main_call(fn: Callable) -> void:
	fn.call_deferred()


func _stop_timers() -> void:
	for t in [_timer, _guard_timer]:
		if t != null and is_instance_valid(t):
			t.stop()


func _resume_timers() -> void:
	if leaving:
		return
	for t in [_timer, _guard_timer]:
		if t != null and is_instance_valid(t) and t.is_inside_tree():
			t.start()


# ---- worker -------------------------------------------------------------------

## Change a setting without blocking the caller. `applied` reports the result.
func request_set(setting: String, value: Variant) -> void:
	var job: Callable
	match setting:
		"profile": job = set_profile.bind(str(value))
		"tdp": job = set_tdp.bind(float(value))
		"charge_limit": job = set_charge_limit.bind(int(value))
		"fan": job = set_fan_mode.bind(str(value))
		_:
			push_warning("Power: unknown setting %s" % setting)
			return
	_queue(setting, job, true)


## Start (on = true) or stop Auto TDP on the worker. Both share one job, so a
## stop queued behind a start (or the other way round) leaves only the newest.
func request_autotune(on: bool, game_key := "") -> void:
	_autotune_stopping = not on
	if on:
		_queue("autotune", func(): return autotune_start(game_key))
	else:
		_queue("autotune", func(): _autotune_stop(true); return true)


## One PerfMonitor sample for Auto TDP, run on the worker so autotune's state
## is only ever touched there. Newest wins: a sample that arrives while the
## worker is busy replaces the one waiting.
## `sample`: PerfMonitor's whole reading (cpu_load, gpu_load, gpu_mhz, fps...) when it has one.
func request_feed(fps: float, watts := -1.0, sample := {}) -> void:
	if not _autotune_on or _autotune_stopping or leaving:
		return
	_queue("feed", func(): autotune_feed(fps, watts, sample); return true)


## The frame rate the running game should hold (its frame limit; 0 = none).
## Only drives the "can't reach" state; the TDP rule doesn't change.
func request_autotune_target(fps: float) -> void:
	_queue("autotune_target", func():
		autotune.set_frame_limit(fps)
		_check_limit()
		return true)


## A manual change of a lever Auto TDP moves (CPU boost, GPU clocks...): Auto TDP stops changing
## things for the rest of this game (ClawDeck: never fight the user).
func request_autotune_pause(reason := "manual change") -> void:
	_queue("autotune_pause", func(): autotune.pause(reason); return true)


## Runs job on Power's worker and waits for its result (callers on another worker thread: the
## power.* controls). Inline when there is no worker or when called from it.
func run_sync(job: Callable) -> Variant:
	if _thread == null or OS.get_thread_caller_id() == _thread.get_id().to_int():
		return job.call()
	var done := Semaphore.new()
	var box := [null]
	_queue("sync_%d_%d" % [Time.get_ticks_usec(), randi()], func():
		box[0] = job.call()
		done.post()
		return true)
	done.wait()
	return box[0]


## True while Auto TDP runs.
func autotune_active() -> bool:
	return _autotune_on and not _autotune_stopping


## Last "can't reach" state and its numbers (see autotune_limit).
func autotune_limit_info() -> Dictionary:
	var info: Dictionary = autotune.limit_info()
	info["tdp_max"] = tdp_max()
	return info


## Clocks for noticing a sleep: [unix seconds, ticks msec] (tests swap it).
var clock: Callable = func(): return [Time.get_unix_time_from_system(), Time.get_ticks_msec()]
## Wall clock ahead of the monotonic one by more than this between two looks = the device slept.
const RESUME_GAP_S := 20.0
var _clock_mark := [0.0, 0]
var _clock_mutex := Mutex.new()
## Unix time of the last look before the latest sleep (within SOURCE_CHECK_S of falling
## asleep), 0 before any. Battery history closes a game's stretch on battery there.
var slept_at := 0


## The 15 s timer's job (worker): a sleep since the last look, else the charger. main.gd
## only looks while its window or the quick menu is shown, so a sleep with a game in front
## went unnoticed: a firmware-reset TDP, fan table or charge limit stayed reset (review M19).
func source_tick() -> void:
	if leaving:
		return
	if slept_since_last_look():
		refresh(true)
	else:
		check_power_source()


## True when the clocks say the device slept since the last look (and moves the mark).
func slept_since_last_look() -> bool:
	var now: Array = clock.call()
	_clock_mutex.lock()
	var before: Array = _clock_mark
	_clock_mark = now
	_clock_mutex.unlock()
	if int(before[1]) == 0:
		return false
	var slept := (float(now[0]) - float(before[0])) - (int(now[1]) - int(before[1])) / 1000.0 > RESUME_GAP_S
	if slept:
		slept_at = int(before[0])
	return slept


func _mark_clock() -> void:
	var now: Array = clock.call()
	_clock_mutex.lock()
	_clock_mark = now
	_clock_mutex.unlock()


## refresh() on the worker (it runs busctl).
func request_refresh() -> void:
	_queue("refresh", func(): refresh(); return true)


## After a resume from sleep: refresh() on the worker, then `resumed` so every
## other setting is put back (main.gd calls this when it sees the device slept).
func request_resumed() -> void:
	_queue("refresh", func(): refresh(true); return true)


func _queue(job_name: String, job: Callable, report := false) -> void:
	if _thread == null:
		var ok := bool(job.call())
		if report:
			applied.emit(job_name, ok)
		return
	_job_mutex.lock()
	if not _jobs.has(job_name):
		_job_order.append(job_name)
	_jobs[job_name] = [job, report]
	_job_mutex.unlock()
	_job_sem.post()


func _worker() -> void:
	while true:
		_job_sem.wait()
		_job_mutex.lock()
		if _job_order.is_empty():  # coalesced: this post's job already ran
			_job_mutex.unlock()
			if _quit:
				return
			continue
		# quitting: what's queued (a restore, a TDP write) still runs first (review H2)
		var job_name: String = _job_order.pop_front()
		var entry: Array = _jobs[job_name]
		_jobs.erase(job_name)
		_job_mutex.unlock()
		var ok := bool(entry[0].call())
		if entry[1]:
			applied.emit.call_deferred(job_name, ok)


## Signals other than `changed` also reach listeners on the main thread.
func _emit_main(sig: Signal, args: Array) -> void:
	if OS.get_thread_caller_id() == OS.get_main_thread_id():
		_emit_now(sig, args)
	else:
		_emit_now.call_deferred(sig, args)


func _emit_now(sig: Signal, args: Array) -> void:
	match args.size():
		1: sig.emit(args[0])
		2: sig.emit(args[0], args[1])
		_: sig.emit()


## `changed` always reaches listeners on the main thread.
func _emit_changed() -> void:
	if OS.get_thread_caller_id() == OS.get_main_thread_id():
		changed.emit(state())
	else:
		changed.emit.call_deferred(state())


## Tests call this instead of _ready.
func setup(command_runner: RefCounted, device_row: Dictionary, root: String, hhd_transport: RefCounted = null) -> void:
	runner = command_runner
	device = device_row
	sys_root = root
	hhd = Hhd.new()
	hhd.root = root
	hhd.home = root + "/home" if root != "" else OS.get_environment("HOME")
	# tests get no daemon unless they pass one; _ready passes the real HTTP transport
	hhd.transport = hhd_transport if hhd_transport != null else _NoHhd.new()
	system_bus = Busctl.new(runner, "--system")
	user_bus = Busctl.new(runner, "--user")
	be = Backend.new(root, runner)
	levers = Levers.new(be, func(w: int) -> bool: return write_tdp(float(w)))
	autotune = AutotuneScript.new()
	autotune.levers = levers


# ---- detection ----------------------------------------------------------------

class _NoHhd extends RefCounted:
	func request(_m: String, _p: String, _h: PackedStringArray, _b := "") -> Dictionary:
		return {"code": 0, "body": ""}


## Pick the backend for TDP, then for charge limit and fan. Handheld Daemon first
## when it manages TDP (anything else would fight it), then the device row's
## "tdp_backends" (default steamos-manager, then PowerStation).
func detect() -> String:
	backend = "none"
	_ps_card = ""
	_svc_range = {}
	_hhd_tdp = {}
	plugged = DeviceScript.ac_online(sys_root)
	var t: Dictionary = device.get("tdp", {})
	_range = {
		"min": float(t.get("min", -1)),
		"battery_max": float(t.get("battery_max", -1)),
		"plugged_max": float(t.get("plugged_max", t.get("battery_max", -1))),
	}
	var order: Array = device.get("tdp_backends", ["steamos-manager", "powerstation"])
	if _detect_hhd():
		backend = "hhd"
		order = []
	for b in order:
		if b == "steamos-manager" and _detect_steamos_manager():
			backend = b
			break
		if b == "powerstation" and _detect_powerstation():
			backend = b
			break
	_clamp_generic_range()
	if backend != "none" and (_range["min"] <= 0.0 or _range["battery_max"] <= _range["min"]):
		backend = "none"  # no safe range known from devices.json or the service
	if backend != "none" and not device.has("tdp"):
		device = device.duplicate()
		device["tdp"] = {"min": _range["min"], "battery_max": _range["battery_max"], "plugged_max": _range["plugged_max"]}
	_profile = _profile_for(_tdp_w) if backend != "none" else ""
	if backend == "hhd":
		_charge_via = ""   # hhd keeps its own charge limit and fan curve
		_charge = -1
		_fan_via = ""
		_fan_mode = ""
		return backend
	_detect_charge()
	_detect_fan()
	return backend


## True when hhd answers and its TDP plugin is on.
func _detect_hhd() -> bool:
	var st: Variant = hhd.get_state()
	if st == null:
		return false
	var info := Hhd.tdp_info(st)
	if info.is_empty() or not info["enabled"]:
		return false
	_hhd_tdp = info
	_tdp_w = float(info["value"])
	return true


## The profile whose watts equal `watts` here, else "custom".
## On hardware devices.json doesn't know (a generic row from the CPU table, or a
## family row), its range is a guess: never go past what the power service
## itself allows. Rows for a specific handheld keep their tested range (the
## service may report 0/0 or a chip-wide range there, e.g. Panther Lake).
func _clamp_generic_range() -> void:
	if _svc_range.is_empty():
		return
	var generic := str(device.get("support", "")) == "generic" or str(device.get("tier", "")) in ["generic", "family"] \
		or str(device.get("id", "unknown")) == "unknown"
	if not generic:
		return
	var lo := float(_svc_range["min"])
	var hi := float(_svc_range["max"])
	var changed_range := false
	if _range["min"] < lo:
		_range["min"] = lo
		changed_range = true
	for k in ["battery_max", "plugged_max"]:
		if _range[k] < 0.0 or _range[k] > hi:
			_range[k] = hi
			changed_range = true
	if changed_range and device.has("tdp"):
		device = device.duplicate(true)
		var t: Dictionary = device["tdp"]
		t["min"] = _range["min"]
		t["battery_max"] = _range["battery_max"]
		t["plugged_max"] = _range["plugged_max"]
		if t.has("boost_max") and float(t["boost_max"]) > hi:
			t["boost_max"] = hi
		device.erase("profiles")  # profile watts were picked for the old range


func _profile_for(watts: float) -> String:
	for p in PROFILES:
		if absf(profile_watts(device, p, plugged) - watts) < 0.5:
			return p
	return "custom"


func _detect_steamos_manager() -> bool:
	var v: Variant = user_bus.get_prop(SM_SERVICE, SM_PATH, SM_TDP_IFACE, "TdpLimit")
	if v == null:
		return false
	var lo: Variant = user_bus.get_prop(SM_SERVICE, SM_PATH, SM_TDP_IFACE, "TdpLimitMin")
	var hi: Variant = user_bus.get_prop(SM_SERVICE, SM_PATH, SM_TDP_IFACE, "TdpLimitMax")
	if lo != null and hi != null and float(hi) > float(lo) and float(hi) > 0.0:
		_merge_range(float(lo), float(hi))
	_tdp_w = float(v)
	return true


func _detect_powerstation() -> bool:
	var out: Variant = system_bus.call_method(PS_SERVICE, PS_GPU_PATH, PS_GPU_IFACE, "EnumerateCards")
	if out == null or out.is_empty() or typeof(out[0]) != TYPE_ARRAY:
		return false
	for path in out[0]:
		var v: Variant = system_bus.get_prop(PS_SERVICE, str(path), PS_TDP_IFACE, "TDP")
		if v == null:
			continue
		_ps_card = str(path)
		_tdp_w = float(v)
		var b: Variant = system_bus.get_prop(PS_SERVICE, _ps_card, PS_TDP_IFACE, "Boost")
		_live_boost = float(b) if b != null else -1.0
		# PowerStation reports MinTdp = MaxTdp = 0 for chips missing from its
		# database (Panther Lake today); then devices.json's range stands.
		var lo: Variant = system_bus.get_prop(PS_SERVICE, _ps_card, PS_TDP_IFACE, "MinTdp")
		var hi: Variant = system_bus.get_prop(PS_SERVICE, _ps_card, PS_TDP_IFACE, "MaxTdp")
		if lo != null and hi != null and float(hi) > float(lo) and float(hi) > 0.0:
			_merge_range(float(lo), float(hi))
		return true
	return false


## A service's own range wins only where devices.json has nothing.
func _merge_range(lo: float, hi: float) -> void:
	_svc_range = {"min": lo, "max": hi}
	if _range["min"] < 0.0:
		_range["min"] = lo
	if _range["battery_max"] < 0.0:
		_range["battery_max"] = hi
	if _range["plugged_max"] < 0.0:
		_range["plugged_max"] = hi


func _detect_charge() -> void:
	_charge_via = ""
	_charge = -1
	_needs_helper["charge_limit"] = false
	var v: Variant = user_bus.get_prop(SM_SERVICE, SM_PATH, SM_CHARGE_IFACE, "MaxChargeLevel")
	# steamos-manager reads charge_control_end_threshold as it is. -1: it couldn't
	# (ENODATA, or older builds without the Claw's config). 0: MSI's EC has no limit
	# set (msi-wmi-platform reads the EC byte without its enable bit; steamos-manager
	# data/devices/msi-claw-8ex.toml: battery_charge_limit method acpi_sb), so only
	# where devices.json says this battery has a limit.
	# -1: steamos-manager found the attribute but read ENODATA (asus-wmi until a limit is
	# written; power.rs parse_max_charge_level): no limit set, and it can still write it.
	# A missing attribute is a D-Bus error (null), never -1. So where devices.json says the
	# battery has a limit, 0 and -1 both mean "charges to full" (the ROG Ally on SteamOS 3.10).
	var sm := int(v) if v != null else -2
	if sm > 0 and sm <= 100 or (sm in [0, -1] and device.get("charge_limit", false)):
		_charge_via = "steamos-manager"
		_charge = sm_charge(sm)
		var m: Variant = user_bus.get_prop(SM_SERVICE, SM_PATH, SM_CHARGE_IFACE, "SuggestedMinimumLimit")
		# never under 50 %: MSI's EC takes 0-100 and 0 with its enable bit would stop charging
		_charge_min = maxi(int(m) if m != null else 0, CHARGE_MIN)
		return
	_charge_mode = ""
	_charge_path = ""
	if device.get("charge_limit", false):
		var ctl := charge_control(sys_root)
		if not ctl.is_empty() and not _helper_present():
			_needs_helper["charge_limit"] = true
		elif not ctl.is_empty():
			_charge_via = "fix"
			_charge_mode = ctl["mode"]
			_charge_path = ctl["path"]
			_charge_min = CHARGE_MIN
			_charge = read_charge_sysfs()


## steamos-manager's MaxChargeLevel as a percent: 0 and -1 (no limit set, see
## _detect_charge) are 100, anything else outside 1-100 is unknown (-1). Only used where
## devices.json says the battery has a limit.
static func sm_charge(v: int) -> int:
	if v == 0 or v == -1:
		return 100
	return v if v > 0 and v <= 100 else -1


## The battery's charge control: {"mode": "threshold", "path": …charge_control_end_threshold}
## or {"mode": "behaviour", "path": …charge_behaviour} (only "auto"/"inhibit-charge",
## AYANEO's ayaneo-ec), {} when there is none. Same order as fixes/charge-limit/fix.sh.
static func charge_control(root := "") -> Dictionary:
	var t := DeviceScript.charge_threshold_path(root)
	if t != "":
		return {"mode": "threshold", "path": t}
	var dir := DirAccess.open(root + "/sys/class/power_supply")
	if dir == null:
		return {}
	var names := Array(dir.get_directories())
	names.sort()
	for n in names:
		var d: String = root + "/sys/class/power_supply/" + n + "/"
		if DeviceScript.read_text(d + "type") != "Battery":
			continue
		if FileAccess.file_exists(d + "charge_behaviour") and \
				("inhibit-charge" in DeviceScript.read_text(d + "charge_behaviour") or FileAccess.file_exists(root + CHARGE_STATE_DIR + "/limit")):
			return {"mode": "behaviour", "path": d + "charge_behaviour"}
	return {}


## The handheld's own fan driver (devices.json "fan", driven by the fan fix) first.
## steamos-manager's FanControl1 only switches the Steam Deck's jupiter-fan-control
## service (platform.toml [fan_control]); Bazzite exposes it on every handheld, so on
## the MSI Claw it answered "firmware" and hid the EC's fan tables. It is used only
## where devices.json says so (fan_via "steamos-manager") or no driver of our own is there.
func _detect_fan() -> void:
	_fan_via = ""
	_fan_mode = ""
	_needs_helper["fan"] = false
	_detect_fan_driver()
	if _fan_via != "":
		return
	var drv := str(device.get("fan", ""))
	if FAN_DRIVERS.has(drv) and _fan_hwmon_found(drv) != "" and not _helper_present():
		_needs_helper["fan"] = true
		return
	if str(device.get("fan_via", "")) == "fix":
		return
	var v: Variant = user_bus.get_prop(SM_SERVICE, SM_PATH, SM_FAN_IFACE, "FanControlState")
	if v != null:
		_fan_via = "steamos-manager"
		_fan_mode = "auto" if int(v) == 1 else "firmware"


## hwmon folder of a FAN_DRIVERS driver with a pwm1_enable, "" when none.
func _fan_hwmon_found(drv: String) -> String:
	for hw_name in FAN_DRIVERS[drv]["hwmon"]:
		var h := DeviceScript.find_hwmon(hw_name, sys_root)
		if h != "" and FileAccess.file_exists(h + "pwm1_enable"):
			return h
	return ""


func _detect_fan_driver() -> void:
	_fan_driver = ""
	_fan_hwmon = ""
	_fan_hwmon_name = ""
	var drv := str(device.get("fan", ""))
	if FAN_DRIVERS.has(drv) and _helper_present():
		for hw_name in FAN_DRIVERS[drv]["hwmon"]:
			var h := DeviceScript.find_hwmon(hw_name, sys_root)
			if h != "" and FileAccess.file_exists(h + "pwm1_enable"):
				_fan_via = "fix"
				_fan_driver = drv
				_fan_hwmon = h
				_fan_hwmon_name = hw_name
				_fan_mode = read_fan_sysfs()
				break


func _helper_present() -> bool:
	return FileAccess.file_exists(sys_root + fix_helper)


# ---- state --------------------------------------------------------------------

## Shape fixed by docs/CONTRACTS.md.
func state() -> Dictionary:
	var tdp_ok := backend != "none"
	return {
		"backend": backend,
		"tdp_w": _tdp_w if tdp_ok else -1.0,
		"tdp_min": _range["min"],
		"tdp_max": tdp_max(),
		"profile": _profile,
		"profiles": PROFILES.duplicate() if tdp_ok else [],
		"charge_limit": _charge if _charge_via != "" else -1,
		"fan_mode": _fan_mode,
		"fan_modes": fan_modes(),
		"needs_helper": _needs_helper.duplicate(),
		"plugged": plugged,
		"supported": {
			"tdp": tdp_ok,
			"profiles": tdp_ok,
			"charge_limit": _charge_via != "",
			"fan": _fan_via != "",
		},
	}


func tdp_max() -> float:
	return _range["plugged_max"] if plugged else _range["battery_max"]


func fan_modes() -> Array:
	if _fan_via == "fix":
		return (FAN_DRIVERS[_fan_driver]["modes"] as Array).duplicate() if FAN_DRIVERS.has(_fan_driver) else FIX_FAN_MODES.duplicate()
	if _fan_via == "steamos-manager":
		return SM_FAN_MODES.duplicate()
	return []


## Read the live values again (after resume, or when another tool changed them).
## `resumed` only when after_resume: controls call refresh() after their own
## writes, and a `resumed` from there would re-apply everything again, forever.
func refresh(after_resume := false) -> void:
	var boost_before := _live_boost   # before sleep: what the firmware may have reset
	if after_resume:
		_clock_mutex.lock()
		var mark: Array = _clock_mark
		_clock_mutex.unlock()
		var now: Array = clock.call()
		# main.gd noticed it first: the last 15 s look before the sleep is when it began
		if int(mark[1]) != 0 and (float(now[0]) - float(mark[0])) - (int(now[1]) - int(mark[1])) / 1000.0 > RESUME_GAP_S:
			slept_at = int(mark[0])
		_mark_clock()   # the 15 s check mustn't report it again
		# the charger may have come or gone while asleep: limits first (review S1-2)
		check_power_source()
	var v := read_tdp()
	# after sleep some firmwares come back at their own limit (SimpleDeckyTDP, aarron-lee/SimpleDeckyTDP
	# src/steamListeners.tsx re-applies the TDP after resume; PowerTools, NGnius/PowerTools
	# backend/src/resume_worker.rs re-applies every setting): put ours back, never above the
	# limit for the power source we're on now
	var want := minf(_tdp_w, tdp_max()) if _tdp_w > 0.0 else _tdp_w
	if v >= 0.0 and want > 0.0 and backend != "none" and absf(v - want) >= 0.5:
		if not write_tdp(want):
			_tdp_w = v
	elif v >= 0.0:
		_tdp_w = v
	if v >= 0.0 and backend != "none" and _tdp_w > tdp_max() + 0.01:
		_clamp_to_source()
	if after_resume:
		_reassert_boost(boost_before)
	if _charge_via == "steamos-manager":
		var c: Variant = user_bus.get_prop(SM_SERVICE, SM_PATH, SM_CHARGE_IFACE, "MaxChargeLevel")
		_charge = sm_charge(int(c)) if c != null else -1
	elif _charge_via == "fix":
		_charge = read_charge_sysfs()
	if _fan_via == "fix":
		_fan_mode = read_fan_sysfs()
	if after_resume:
		_emit_main(resumed, [])
	_emit_changed()


# ---- profiles -----------------------------------------------------------------

## Watts for a profile on this device: devices.json "profiles", else a spread of
## the device's range. Always inside the range for the current power source.
static func profile_watts(row: Dictionary, profile_name: String, on_charger: bool) -> float:
	var t: Dictionary = row.get("tdp", {})
	var lo := float(t.get("min", 5))
	var hi := float(t.get("plugged_max", t.get("battery_max", 15))) if on_charger else float(t.get("battery_max", 15))
	var table: Dictionary = row.get("profiles", {})
	var w := -1.0
	if table.has(profile_name):
		w = float(table[profile_name])
	else:
		var share := {"battery": 0.3, "balanced": 0.6, "performance": 1.0}
		if not share.has(profile_name):
			return -1.0
		w = roundf(lo + (hi - lo) * float(share[profile_name]))
	return clampf(w, lo, hi)


func set_profile(profile_name: String) -> bool:
	if backend == "none":
		return false
	if profile_name == "custom":
		# back to the user's own watts for this power source (custom_w@<device>)
		var cw := custom_watts()
		return cw > 0.0 and set_tdp(cw)
	if not profile_name in PROFILES:
		return false
	var w := profile_watts(device, profile_name, plugged)
	if not _apply_user_tdp(w):
		return false
	_profile = profile_name
	_remember("profile", _source(), profile_name)
	_emit_changed()
	return true


## The TDP slider. Moving it away from a profile's watts makes the profile "custom".
func set_tdp(watts: float) -> bool:
	if backend == "none":
		return false
	var w := clampf(watts, _range["min"], tdp_max())
	if not _apply_user_tdp(w):
		return false
	_profile = _profile_for(w)
	_remember("profile", _source(), _profile)
	if _profile == "custom":
		_remember("custom_w", _source(), w)
	_emit_changed()
	return true


## The user's own watts for the power source we're on (set by the TDP slider), -1 when none.
func custom_watts() -> float:
	return float(_recall("custom_w", _source(), -1.0))


func _apply_user_tdp(w: float) -> bool:
	_user_tdp = w
	guard.reset()  # the user's choice replaces a thermal step (ClawDeck: guard.reset on a pick)
	if _autotune_on:
		# ClawDeck: a pick while a game runs starts Auto TDP over from the new limit
		return autotune.set_ceiling(int(roundf(w))) > 0
	return write_tdp(w)


## Put back what was remembered for this power source (start, plug, unplug).
func restore() -> void:
	if backend != "none":
		var remembered := str(_recall("profile", _source(), ""))
		if remembered == "custom":
			var w := float(_recall("custom_w", _source(), -1.0))
			if w > 0.0:
				set_tdp(w)
		elif remembered in PROFILES:
			set_profile(remembered)
	# root actions only when the live value differs, so no needless prompt, and
	# only while the fix is in use: after `gamecove-fix fan remove` its status says
	# installed=no and the remembered value must not bring it back
	var c := int(_recall("device", "charge_limit", -1))
	if c > 0 and _charge_via != "" and c != _charge:
		if _charge_via != "fix" or fix_installed("charge-limit"):
			set_charge_limit(c)
	var f := str(_recall("device", "fan_mode", ""))
	# "custom": a fan curve (power.fan_curve) is the setting; the power controls put it back
	if f != "" and f != "custom" and _fan_via != "" and f != _fan_mode:
		if _fan_via != "fix" or fix_installed("fan"):
			set_fan_mode(f)


func check_power_source() -> void:
	var now := DeviceScript.ac_online(sys_root)
	_report_battery(now)
	if now == plugged:
		# a clamp to this source's limit that failed (unplugged at 30 W, the write didn't
		# land) is tried again on every check until it holds (review L11)
		if backend != "none" and _tdp_w > tdp_max() + 0.01:
			_clamp_to_source()
		hold_charge()
		return
	plugged = now
	if _autotune_on and plugged and not bool(autotune_opts.get("plugged", false)):
		_autotune_stop(true)  # Auto TDP is for battery unless asked (ClawDeck)
	restore()
	_clamp_to_source()
	hold_charge()
	_emit_main(source_changed, [plugged])
	_emit_changed()


## Capacity only: Decky Battery Tracker (safijari/steam-deck-battery-tracker main.py) also reads
## voltage_now * current_now, but current_now isn't credible on the Claw 8 EX (ClawDeck
## docs/HARDWARE-FINDINGS.md §6: -65 A at idle), and battery saver needs only the level.
## Never above the limit for the power source we're on (review S1-2): unplugging with 30 W
## set on an Ally (battery_max 25), or a firmware that came back from sleep higher, brings
## the TDP, the user's own value and Auto TDP's ceiling down to the battery limit. Only
## lowers; nothing is remembered, so the charger's own value comes back on the charger.
func _clamp_to_source() -> void:
	if backend == "none":
		return
	var hi := tdp_max()
	if hi <= 0.0:
		return
	if _user_tdp > hi:
		_user_tdp = hi
	if _autotune_on and autotune.session != null and autotune.session.ceiling_tdp > int(floorf(hi)):
		autotune.set_ceiling(int(floorf(hi)))
	if _tdp_w > hi + 0.01:
		if write_tdp(hi):
			_profile = _profile_for(hi)
			_emit_changed()
		else:
			push_warning("Power: couldn't bring the TDP down to %.0f W for this power source" % hi)


func _report_battery(on_ac: bool) -> void:
	var pct := -1
	var dir := DirAccess.open(sys_root + "/sys/class/power_supply")
	if dir != null:
		var names := Array(dir.get_directories()) + Array(dir.get_files())
		names.sort()
		for n in names:
			var d: String = sys_root + "/sys/class/power_supply/" + n + "/"
			if DeviceScript.read_text(d + "type") == "Battery":
				var c := DeviceScript.read_text(d + "capacity")
				if c.is_valid_int():
					pct = c.to_int()
				break
	if pct >= 0 and pct != _battery_pct:
		_battery_pct = pct
		_emit_main(battery_level, [pct, on_ac])


func battery_percent() -> int:
	return _battery_pct


## Behaviour batteries (AYANEO) can't stop at a level by themselves: the fix
## holds charging while plugged in at or above the limit. Runs it again when
## the charger or the level crossed that line (from the 15 s check; one sysfs
## read when nothing changed). True when it ran the fix.
func hold_charge() -> bool:
	if leaving or _charge_via != "fix" or _charge_mode != "behaviour" or _charge <= 0 or _charge >= 100:
		return false
	if not FileAccess.file_exists(sys_root + CHARGE_STATE_DIR + "/original"):
		return false  # the fix isn't in use (removed): leave the battery alone
	var cap_raw := DeviceScript.read_text(_charge_path.get_base_dir() + "/capacity")
	if not cap_raw.is_valid_int():
		return false
	var want := plugged and cap_raw.to_int() >= _charge
	var held := "[inhibit-charge]" in DeviceScript.read_text(_charge_path) or DeviceScript.read_text(_charge_path) == "inhibit-charge"
	if want == held:
		return false
	return _run_fix("charge-limit", str(_charge))


func _source() -> String:
	return "plugged" if plugged else "battery"


## The device id power.cfg keys this handheld's values by.
func device_key() -> String:
	return PerDevice.key(str(device.get("id", "unknown")))


## Everything here is per device: one drive can boot a Claw and a ROG Ally, and
## 30 W or a quiet fan curve picked on one must never be applied to the other.
## Values saved before (plain [profile]/[custom_w]/[device]) move to this device.
func _load_cfg() -> ConfigFile:
	var cfg := SettingsFile.load_cfg(config_path)
	if PerDevice.migrate_cfg(cfg, DEVICE_SECTIONS, device_key()):
		SettingsFile.save_cfg(cfg, config_path)
	return cfg


## Values a game's profile can set (power.tdp, power.profile, power.boost, power.fan_mode, the
## Auto TDP options): not the user's own while a game layer is in effect (review H2). What
## Auto TDP learned per game, the charge limit and a fan curve the user draws are.
func _game_value(section: String, key: String, value: Variant) -> bool:
	if section in ["profile", "custom_w"]:
		return true
	if section == "device":
		return key in ["boost_w", "autotune_opts"] or (key == "fan_mode" and str(value) != "custom")
	return false


## One load-modify-save under SettingsFile's lock (Power's worker, the Controls worker and
## the installer all write power.cfg).
func _remember(section: String, key: String, value: Variant) -> void:
	if game_layer and _game_value(section, key, value):
		return
	SettingsFile.update_cfg(config_path, func(cfg: ConfigFile):
		PerDevice.migrate_cfg(cfg, DEVICE_SECTIONS, device_key())
		if value == null:
			if cfg.has_section_key(PerDevice.section(section, device_key()), key):
				cfg.erase_section_key(PerDevice.section(section, device_key()), key)
		else:
			cfg.set_value(PerDevice.section(section, device_key()), key, value))


func _recall(section: String, key: String, fallback: Variant) -> Variant:
	return _load_cfg().get_value(PerDevice.section(section, device_key()), key, fallback)


# ---- TDP ----------------------------------------------------------------------

## The TDP as the backend reports it now, or -1.
func read_tdp() -> float:
	var v: Variant = null
	if backend == "steamos-manager":
		v = user_bus.get_prop(SM_SERVICE, SM_PATH, SM_TDP_IFACE, "TdpLimit")
	elif backend == "powerstation":
		v = system_bus.get_prop(PS_SERVICE, _ps_card, PS_TDP_IFACE, "TDP")
	elif backend == "hhd":
		var info := Hhd.tdp_info(hhd.get_state())
		if info.is_empty() or float(info["value"]) < 0.0:
			return -1.0
		_hhd_tdp = info
		return float(info["value"])
	return float(v) if v != null else -1.0


## Write the TDP and read it back. On PowerStation the boost (PL2 - PL1) is only
## written when the user picked one (power.boost, boost_w) and the live value differs:
## writing devices.json's pl2_offset_w with every TDP write put 2 W over the Claw 8
## EX's live 7 W at start (and a probe then stored 2 as the user's).
func write_tdp(watts: float) -> bool:
	var ok := false
	if backend == "steamos-manager":
		var w := int(roundf(watts))
		if user_bus.set_prop(SM_SERVICE, SM_PATH, SM_TDP_IFACE, "TdpLimit", "u", str(w)):
			ok = absf(read_tdp() - w) < 0.5
	elif backend == "powerstation":
		# PL2 = TDP + boost. A smaller boost goes in before the TDP, a larger one after, so TDP + boost never
		# passes the new total on the way (a raised TDP with the old, larger boost overshot boost_max;
		# review 2, low 23)
		var boost := boost_for(watts)
		var live: Variant = system_bus.get_prop(PS_SERVICE, _ps_card, PS_TDP_IFACE, "Boost")
		var change := boost >= 0.0 and (live == null or absf(float(live) - boost) >= 0.05)
		var first := change and live != null and boost < float(live)
		if first:
			system_bus.set_prop(PS_SERVICE, _ps_card, PS_TDP_IFACE, "Boost", "d", "%.1f" % boost)
		if system_bus.set_prop(PS_SERVICE, _ps_card, PS_TDP_IFACE, "TDP", "d", "%.1f" % watts):
			if change and not first:
				system_bus.set_prop(PS_SERVICE, _ps_card, PS_TDP_IFACE, "Boost", "d", "%.1f" % boost)
			if boost >= 0.0:
				_live_boost = boost
			elif live != null:
				_live_boost = float(live)
			ok = absf(read_tdp() - watts) < 0.5
	elif backend == "hhd" and not _hhd_tdp.is_empty():
		var w := int(roundf(watts))
		var after: Variant = hhd.set_state(Hhd.tdp_patch(_hhd_tdp, w))
		var info := Hhd.tdp_info(after)
		ok = not info.is_empty() and absf(float(info["value"]) - w) < 0.5
		if ok:
			_hhd_tdp = info
	if ok:
		_tdp_w = watts
		_hold_thermald()
	return ok


## After a resume: the firmware may have reset PL2 while the TDP itself survived, so the user's
## boost goes back even when refresh() didn't rewrite the TDP (the power controls no longer
## replay power.boost, review M16).
func _reassert_boost(before: float) -> void:
	if backend != "powerstation" or _ps_card == "":
		return
	var want := boost_for(_tdp_w)
	if want < 0.0 and before >= 0.0:
		# no boost of the user's: the one PowerStation had before the sleep
		var cap := float(device.get("tdp", {}).get("boost_max", -1.0))
		want = minf(before, maxf(0.0, cap - _tdp_w)) if cap > 0.0 else before
	if want < 0.0:
		return
	var live: Variant = system_bus.get_prop(PS_SERVICE, _ps_card, PS_TDP_IFACE, "Boost")
	if live == null or absf(float(live) - want) >= 0.05:
		system_bus.set_prop(PS_SERVICE, _ps_card, PS_TDP_IFACE, "Boost", "d", "%.1f" % want)
	_live_boost = want


## The boost to write with a TDP of `watts` (review H6): the user's boost_w, never past the
## device's boost_max for that TDP (TDP + boost <= boost_max), for whatever power source and
## TDP we're at now. -1 = leave PowerStation's own.
func boost_for(watts: float) -> float:
	if boost_w < 0.0:
		return -1.0
	var cap := float(device.get("tdp", {}).get("boost_max", -1.0))
	return minf(boost_w, maxf(0.0, cap - watts)) if cap > 0.0 else boost_w


# ---- charge limit -------------------------------------------------------------

## steamos-manager's charge limit lands about a second after set-property.
const CHARGE_SETTLE_MAX_MS := 3000
## Pause between read-backs while it lands (tests set 0: no sleeping, the
## loop still counts 250 ms per read toward the 3 s cap).
var charge_settle_ms := 250

## 50-100 %. 100 means no limit.
func set_charge_limit(percent: int) -> bool:
	if _charge_via == "" or percent < _charge_min or percent > 100:
		return false
	var got := -1
	if _charge_via == "steamos-manager":
		if user_bus.set_prop(SM_SERVICE, SM_PATH, SM_CHARGE_IFACE, "MaxChargeLevel", "i", str(percent)):
			# steamos-manager applies it about a second later (seen live on a ROG
			# Ally): poll the read-back for up to 3 s before calling it refused.
			var waited := 0
			while true:
				var v: Variant = user_bus.get_prop(SM_SERVICE, SM_PATH, SM_CHARGE_IFACE, "MaxChargeLevel")
				got = sm_charge(int(v)) if v != null else -1
				if got == percent or waited >= CHARGE_SETTLE_MAX_MS:
					break
				if charge_settle_ms > 0:
					OS.delay_msec(charge_settle_ms)
				waited += maxi(charge_settle_ms, 1) if charge_settle_ms > 0 else 250
	else:
		if _run_fix("charge-limit", str(percent)):
			got = read_charge_sysfs()
	if got != percent:
		return false
	_charge = got
	_remember("device", "charge_limit", percent)
	_emit_changed()
	return true


## The kernel's charge_control_end_threshold as a percent; 0 (the Claw's "no
## limit") reads as 100. -1 when unreadable. Behaviour batteries (AYANEO): the
## limit the charge-limit fix keeps (100 = none set).
func read_charge_sysfs() -> int:
	if _charge_mode == "behaviour":
		if not FileAccess.file_exists(sys_root + CHARGE_STATE_DIR + "/original"):
			return 100
		var lim := DeviceScript.read_text(sys_root + CHARGE_STATE_DIR + "/limit")
		return lim.to_int() if lim.is_valid_int() else 100
	var raw := DeviceScript.read_text(DeviceScript.charge_threshold_path(sys_root))
	if not raw.is_valid_int():
		return -1
	var v := raw.to_int()
	if v < 0 or v > 100:
		return -1   # not a percent: show nothing rather than a wrong limit
	return 100 if v == 0 else v


# ---- fan ----------------------------------------------------------------------

func set_fan_mode(mode: String) -> bool:
	if _fan_via == "" or not mode in fan_modes():
		return false
	if _write_fan_mode(mode) != mode:
		return false
	_remember("device", "fan_mode", mode)
	_emit_changed()
	return true


## Writes a fan mode and reads it back (the mode the hardware is in afterwards, "" when
## unreadable). Remembers nothing: set_fan_mode() is the user's choice, restore_before() isn't.
func _write_fan_mode(mode: String) -> String:
	var got := ""
	if _fan_via == "steamos-manager":
		var want := "1" if mode == "auto" else "0"
		if user_bus.set_prop(SM_SERVICE, SM_PATH, SM_FAN_IFACE, "FanControlState", "u", want):
			var v: Variant = user_bus.get_prop(SM_SERVICE, SM_PATH, SM_FAN_IFACE, "FanControlState")
			if v != null:
				got = "auto" if int(v) == 1 else "firmware"
	else:
		if _run_fix("fan", mode):
			got = read_fan_sysfs()
	if got == mode:
		_fan_mode = got
	return got


## The fan preset the hardware is in now: "auto" (the firmware's own control),
## "quiet"/"max" when every fan matches that preset, "custom" otherwise, ""
## when unreadable. Works for every driver in FAN_DRIVERS.
func read_fan_sysfs() -> String:
	var info: Dictionary = FAN_DRIVERS.get(_fan_driver, FAN_DRIVERS["msi_wmi_platform"])
	var h := _fan_hwmon
	var hw_name := _fan_hwmon_name if _fan_hwmon_name != "" else str(info["hwmon"][0])
	if h == "":
		h = DeviceScript.find_hwmon(hw_name, sys_root)
	if h == "":
		return ""
	var fans := []
	for n in [1, 2, 3]:
		if FileAccess.file_exists(h + "pwm%d_enable" % n):
			fans.append(n)
	if fans.is_empty():
		return ""
	var auto_value := str(info.get("auto", {}).get(hw_name, "2"))
	var full_value := str(info.get("full", {}).get(hw_name, ""))
	var enables := []
	for n in fans:
		enables.append(DeviceScript.read_text(h + "pwm%d_enable" % n))
	if enables.all(func(e): return e == auto_value):
		return "auto"
	if info["kind"] == "manual":
		if full_value != "" and enables.all(func(e): return e == full_value):
			return "max"
		if enables.all(func(e): return e == "1") and fans.all(func(n): return DeviceScript.read_text(h + "pwm%d" % n) == "255"):
			return "max"
		return "custom"
	if not enables.all(func(e): return e == "1"):
		return "custom"
	var points := int(info.get("points", 6))
	for preset in info["tables"]:
		var table: Array = info["tables"][preset]
		var match_all := true
		for n in fans:
			for i in range(points):
				var raw := DeviceScript.read_text(h + "pwm%d_auto_point%d_pwm" % [n, i + 1])
				# hwmon's 0-255 scale; the EC stores percent, so allow rounding
				if not raw.is_valid_int() or absi(roundi(raw.to_int() * 100.0 / 255.0) - int(table[i])) > 1:
					match_all = false
		if match_all:
			return preset
	return "custom"


# ---- root actions -------------------------------------------------------------

## The command for a root action, per docs/CONTRACTS.md "Root actions": the
## no-password entry point, which only takes `set` on charge-limit, fan and the
## gyro's accelerometer.
func fix_command(fix_name: String, value: String) -> PackedStringArray:
	return PackedStringArray(["pkexec", fix_set_helper, fix_name, "set", value])


## True when `gamecove-fix <name> status` (run as the user, no pkexec) says
## installed=yes. Runs a process: call it from the worker.
func fix_installed(fix_name: String) -> bool:
	var r: Dictionary = runner.run(fix_helper, PackedStringArray([fix_name, "status"]))
	if int(r.get("code", -1)) != 0:
		return false
	for line in str(r.get("out", "")).split("\n"):
		if line.strip_edges() == "installed=yes":
			return true
	return false


func _run_fix(fix_name: String, value: String) -> bool:
	var argv := fix_command(fix_name, value)
	var r: Dictionary = runner.run(argv[0], argv.slice(1))
	return int(r.get("code", -1)) == 0


# ---- auto TDP -----------------------------------------------------------------------------------
# ClawDeck's algorithm (autotune.gd); this part is the plumbing ClawDeck's main.py does: where the
# ceiling and floor come from, battery-only unless asked, what a game learned, levers restored.

## PowerStation boost (power.boost control): watts above the TDP, clamped to the device's boost_max.
func set_boost_w(watts: float) -> bool:
	if backend != "powerstation":
		return false
	var cap := float(device.get("tdp", {}).get("boost_max", -1.0))
	var w := maxf(0.0, watts)
	if cap > 0.0:
		w = minf(w, maxf(0.0, cap - _tdp_w))
	if not be.set_ps_boost(w):
		return false
	boost_w = w
	_live_boost = w
	_remember("device", "boost_w", w)
	return true


## Handheld Daemon's TDP boost switch (<driver>.tdp.custom.boost), null when it has none.
func hhd_boost() -> Variant:
	if backend != "hhd" or _hhd_tdp.is_empty():
		return null
	var path: Array = (_hhd_tdp["value_path"] as Array).duplicate()
	path[path.size() - 1] = "boost"
	var v: Variant = Hhd.dig(hhd.get_state(), path)
	return bool(v) if v != null else null


func set_hhd_boost(on: bool) -> bool:
	if hhd_boost() == null:
		return false
	var path: Array = (_hhd_tdp["value_path"] as Array).duplicate()
	path[path.size() - 1] = "boost"
	var patch := Hhd.tdp_patch(_hhd_tdp, int(roundf(_tdp_w)))
	var node: Dictionary = Hhd.dig(patch, path.slice(0, path.size() - 1))
	node["boost"] = on
	var after: Variant = hhd.set_state(patch)
	return after != null and Hhd.dig(after, path) == on


func load_autotune_opts() -> void:
	boost_w = float(_recall("device", "boost_w", -1.0))
	# a stale or hand-edited value: never more than the largest boost any TDP here allows
	var cap := float(device.get("tdp", {}).get("boost_max", -1.0))
	if boost_w >= 0.0 and cap > 0.0:
		boost_w = minf(boost_w, maxf(0.0, cap - maxf(_range["min"], 0.0)))
	autotune_opts = AUTOTUNE_DEFAULTS.duplicate()
	var saved: Variant = _recall("device", "autotune_opts", {})
	if saved is Dictionary:
		for k in saved:
			if autotune_opts.has(k):
				autotune_opts[k] = saved[k]


## power.autotune_* controls. Applies to the running game at once where ClawDeck does.
func set_autotune_option(key: String, value: Variant) -> bool:
	if not AUTOTUNE_DEFAULTS.has(key):
		return false
	autotune_opts[key] = value
	_remember("device", "autotune_opts", autotune_opts)
	if _autotune_on:
		match key:
			"target": autotune.set_target(int(value), bool(autotune_opts["auto_fps"]))
			"auto_fps": autotune.set_target(int(autotune_opts["target"]), bool(value))
			"keep_pct": autotune.set_keep(float(value))
			"floor_w": autotune.set_floor(_floor_w(), int(_range["min"]))
	return true


func _floor_w() -> int:
	var lo := int(_range["min"])
	var f := int(autotune_opts.get("floor_w", 0))
	return lo if f <= 0 else clampi(f, lo, int(tdp_max()))


func _learned_key() -> String:
	return "%s|%s" % [_game_key if _game_key != "" else "_", _source()]


## Start Auto TDP for a game; it works under the TDP the user picked. On the charger only when
## "Auto TDP when plugged in" is on (ClawDeck main.py _start_game_power).
func autotune_start(game_key := "") -> bool:
	if backend == "none":
		return false
	if plugged and not bool(autotune_opts.get("plugged", false)):
		return false
	if _autotune_on:
		_autotune_stop(true)
	_game_key = game_key
	if _user_tdp <= 0.0:
		_user_tdp = _tdp_w if _tdp_w > 0.0 else tdp_max()
	var ceiling := int(roundf(clampf(_user_tdp, _range["min"], tdp_max())))
	var learned: Variant = _recall("autotune", _learned_key(), {})
	_autotune_on = true
	_limit_shown = false
	levers.refresh()
	autotune.start(game_key, learned if learned is Dictionary else {}, mini(_floor_w(), ceiling), ceiling,
		{"keep_pct": float(autotune_opts["keep_pct"]), "target": int(autotune_opts["target"]),
		"auto_fps": bool(autotune_opts["auto_fps"]), "fg": 0})
	_emit_main(autotune_changed, [true])
	_emit_changed()
	return true


## One sample per second while the game runs: rendered fps, package watts, PerfMonitor's reading.
func autotune_feed(fps: float, watts := -1.0, sample := {}) -> void:
	if not _autotune_on or _autotune_stopping:
		return
	var before := _tdp_w
	autotune.step(autotune_sample(fps, watts, sample))
	_check_limit()
	if not is_equal_approx(before, _tdp_w):
		_emit_changed()


## PerfMonitor's reading in the shape autotune.step() takes. GPU load: amdgpu's sysfs (in the
## reading), else PowerStation's GpuBusyPercent at most every BUSY_EVERY_S (ClawDeck: xe has no
## gpu_busy_percent; findings §2).
func autotune_sample(fps: float, watts: float, d: Dictionary) -> Dictionary:
	var busy := int(roundf(float(d.get("gpu_load", -1.0))))
	if busy < 0:
		var now := Time.get_ticks_msec() / 1000.0
		if now - _busy_at >= BUSY_EVERY_S:
			_busy_at = now
			_busy = -1
			var card: String = be.ps_tdp_card() if be != null else ""
			if card != "":
				var v: Variant = be.ps_get(card, Backend.PS_CARD_IF, "GpuBusyPercent")
				_busy = int(v) if v != null else -1
		busy = _busy
	var shown := float(d.get("fps", -1.0))
	var rendered := shown > 0.0 and absf(shown - fps) > 0.5
	return {"fps": fps, "source": "rendered" if rendered else "presented", "shown_fps": shown if shown > 0.0 else fps,
		"gpu_busy": busy, "cpu_pct": float(d.get("cpu_load", -1.0)), "gpu_mhz": float(d.get("gpu_mhz", -1.0)),
		"gpu_max_mhz": float(d.get("gpu_max_mhz", -1.0)), "pkg_w": watts}


## Game closed: back to the user's own TDP.
func autotune_stop() -> void:
	_autotune_stop(false)


## sync: write the TDP here (on the worker) instead of queueing the write.
func _autotune_stop(sync: bool) -> void:
	if not _autotune_on:
		return
	_autotune_on = false
	var result: Dictionary = autotune.stop()
	# only a finished result: a session cut short keeps the last good one (ClawDeck _save_learned)
	if bool(result.get("settled", false)) and result.get("learned") is Dictionary:
		_remember("autotune", _learned_key(), result["learned"])
	_check_limit()
	_emit_main(autotune_changed, [false])
	var restore_levers := func():
		levers.restore()
		if _user_tdp > 0.0 and write_tdp(_user_tdp):
			_emit_changed()
		return true
	if sync:
		restore_levers.call()
	else:
		_queue("autotune", restore_levers)


## What Auto TDP is doing now (autotune.gd status()).
func autotune_status() -> Dictionary:
	return autotune.status()


## Report autotune's cant_reach when it flips.
func _check_limit() -> void:
	var now: bool = autotune.cant_reach
	if now == _limit_shown:
		return
	_limit_shown = now
	_emit_main(autotune_limit, [now, autotune_limit_info()])


# ---- thermald and the temperature guard (Intel) ------------------------------------------------
# thermald puts the firmware's power limits back into RAPL every few seconds: on the Claw 8 EX PL1
# went back to 30 W within 10 s of every write (ClawDeck docs/HARDWARE-FINDINGS.md §21). PowerStation
# writes RAPL and doesn't deal with it, so after GameCove's first TDP write on an Intel handheld with
# thermald running, thermald is held (stopped, never disabled; started again by the session when
# GameCove exits: power-tune set restore) and the guard watches the package temperature instead.

## The helper bounds a hold to a running game (review S3-2): thermald starts again by itself when no
## game runs. So a hold is asked for again (at most every THERMALD_RETRY_MS) once thermald runs again.
func _hold_thermald() -> void:
	if leaving or RunMode.helper():
		return   # leaving the session: the root helper starts thermald again, nothing may stop it now
	if backend != "powerstation" or str(device.get("cpu_vendor", "")) != "intel":
		return
	if _thermald_held and not be.thermald_active():
		return
	_thermald_held = false
	var now := Time.get_ticks_msec()
	if _thermald_checked and now - _thermald_try_ms < THERMALD_RETRY_MS:
		return
	_thermald_checked = true
	_thermald_try_ms = now
	if not be.helper_present():
		return
	if not be.thermald_active():
		# stopped by an earlier hold (a run that crashed or was switched away): thermald's
		# temperature control is off all the same, so the guard has to run (review L10)
		if be.thermald_held_mark():
			_thermald_held = true
			guard.reset()
			_start_guard.call_deferred()
		return
	if be.root_set("thermald", "hold"):
		_thermald_held = true
		guard.reset()
		_start_guard.call_deferred()


func _start_guard() -> void:
	if _guard_timer != null or not is_inside_tree():
		return
	_guard_timer = Timer.new()
	_guard_timer.wait_time = ThermalGuard.CHECK_S
	_guard_timer.timeout.connect(func(): _queue("guard", func(): guard_check(); return true))
	add_child(_guard_timer)
	_guard_timer.start()


## One guard check (worker): the package temperature against ThermalGuard's rules.
func guard_check() -> int:
	if not _thermald_held or leaving:
		return -1
	var f: String = be.pkg_temp_file()
	var raw := Backend.read_int(f) if f != "" else -1
	var t := raw / 1000.0 if raw > 0 else -1.0
	var w := -1
	if _autotune_on and autotune.session != null:
		var sess = autotune.session
		w = guard.check(t, sess.learned.tdp, sess.floor_tdp, func(x): return autotune.thermal_step(x),
			sess.ceiling_tdp, func(x): return autotune.thermal_release(x))
	else:
		# with no pick this run the limit is the TDP from before the first step, not the
		# stepped one (which never let the guard step back up, review L10)
		if guard.stepped_w < 0:
			_guard_base_w = _tdp_w
		var base := _user_tdp if _user_tdp > 0.0 else _guard_base_w
		var limit := int(roundf(base)) if base > 0.0 else int(roundf(_tdp_w))
		w = guard.check(t, int(roundf(_tdp_w)), _floor_w(), func(x): return write_tdp(float(x)), limit)
	if w > 0:
		_emit_changed()
	return w
