extends Node
## Power: TDP, profiles, fan and charge limit. Talks to the system services
## that already exist instead of a daemon of our own:
##   steamos-manager  (user bus)   com.steampowered.SteamOSManager1
##   PowerStation     (system bus) org.shadowblip.PowerStation
## and, for fan curves and charge limits neither offers, to the root actions in
## fixes/ through `pkexec /usr/libexec/gamecove/gamecove-fix <name> set <value>`.
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

const Runner := preload("res://scripts/device/command_runner.gd")
const Busctl := preload("res://scripts/device/busctl.gd")
const AutotuneScript := preload("res://scripts/device/autotune.gd")
const DeviceScript := preload("res://scripts/device/device.gd")

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
const CONFIG_PATH := "user://power.cfg"
const PROFILES: Array[String] = ["battery", "balanced", "performance"]
## Fan presets for the msi_wmi_platform tables, in EC percent per point (ClawDeck's
## known-good Claw presets). Must match fixes/fan/fix.sh.
const FAN_TABLES := {"quiet": [0, 40, 40, 45, 60, 75], "max": [100, 100, 100, 100, 100, 100]}
const FIX_FAN_MODES: Array[String] = ["quiet", "auto", "max"]
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
var autotune: RefCounted = AutotuneScript.new()

var backend := "none"
var plugged := false
var _ps_card := ""
var _tdp_w := -1.0
var _range := {"min": -1.0, "battery_max": -1.0, "plugged_max": -1.0}
var _profile := ""
var _charge_via := ""   # "steamos-manager" | "fix" | ""
var _charge := -1
var _charge_min := CHARGE_MIN
var _fan_via := ""      # "steamos-manager" | "fix" | ""
var _fan_mode := ""
var _autotune_on := false
var _user_tdp := -1.0   # what the user picked; autotune works under it
var _timer: Timer
var _thread: Thread
var _jobs := {}               # name -> Callable, newest wins
var _job_order: Array = []
var _job_mutex := Mutex.new()
var _job_sem := Semaphore.new()
var _quit := false


func _ready() -> void:
	var dev := get_node_or_null("/root/Device")
	setup(Runner.new(), dev.profile if dev else {}, "")
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
	restore()
	if backend != "none":
		_start_timer.call_deferred()
	_emit_changed()
	return true


func _start_timer() -> void:
	_timer = Timer.new()
	_timer.wait_time = SOURCE_CHECK_S
	_timer.timeout.connect(func(): _queue("source", func(): check_power_source(); return true))
	add_child(_timer)
	_timer.start()


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
		if _quit:
			_job_mutex.unlock()
			return
		if _job_order.is_empty():  # coalesced: this post's job already ran
			_job_mutex.unlock()
			continue
		var job_name: String = _job_order.pop_front()
		var entry: Array = _jobs[job_name]
		_jobs.erase(job_name)
		_job_mutex.unlock()
		var ok := bool(entry[0].call())
		if entry[1]:
			applied.emit.call_deferred(job_name, ok)


## `changed` always reaches listeners on the main thread.
func _emit_changed() -> void:
	if OS.get_thread_caller_id() == OS.get_main_thread_id():
		changed.emit(state())
	else:
		changed.emit.call_deferred(state())


## Tests call this instead of _ready.
func setup(command_runner: RefCounted, device_row: Dictionary, root: String) -> void:
	runner = command_runner
	device = device_row
	sys_root = root
	system_bus = Busctl.new(runner, "--system")
	user_bus = Busctl.new(runner, "--user")


# ---- detection ----------------------------------------------------------------

## Pick the backend for TDP, then for charge limit and fan. Order: the device
## row's "tdp_backends" (default steamos-manager, then PowerStation).
func detect() -> String:
	backend = "none"
	_ps_card = ""
	plugged = DeviceScript.ac_online(sys_root)
	var t: Dictionary = device.get("tdp", {})
	_range = {
		"min": float(t.get("min", -1)),
		"battery_max": float(t.get("battery_max", -1)),
		"plugged_max": float(t.get("plugged_max", t.get("battery_max", -1))),
	}
	var order: Array = device.get("tdp_backends", ["steamos-manager", "powerstation"])
	for b in order:
		if b == "steamos-manager" and _detect_steamos_manager():
			backend = b
			break
		if b == "powerstation" and _detect_powerstation():
			backend = b
			break
	if backend != "none" and (_range["min"] <= 0.0 or _range["battery_max"] <= _range["min"]):
		backend = "none"  # no safe range known from devices.json or the service
	if backend != "none" and not device.has("tdp"):
		device = device.duplicate()
		device["tdp"] = {"min": _range["min"], "battery_max": _range["battery_max"], "plugged_max": _range["plugged_max"]}
	_profile = _profile_for(_tdp_w) if backend != "none" else ""
	_detect_charge()
	_detect_fan()
	return backend


## The profile whose watts equal `watts` here, else "custom".
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
	if _range["min"] < 0.0:
		_range["min"] = lo
	if _range["battery_max"] < 0.0:
		_range["battery_max"] = hi
	if _range["plugged_max"] < 0.0:
		_range["plugged_max"] = hi


func _detect_charge() -> void:
	_charge_via = ""
	_charge = -1
	var v: Variant = user_bus.get_prop(SM_SERVICE, SM_PATH, SM_CHARGE_IFACE, "MaxChargeLevel")
	# steamos-manager reports -1 where it can't read the limit (the Claw 8 EX)
	if v != null and int(v) > 0 and int(v) <= 100:
		_charge_via = "steamos-manager"
		_charge = int(v)
		var m: Variant = user_bus.get_prop(SM_SERVICE, SM_PATH, SM_CHARGE_IFACE, "SuggestedMinimumLimit")
		_charge_min = int(m) if m != null and int(m) > 0 else CHARGE_MIN
		return
	if device.get("charge_limit", false) and _helper_present() and DeviceScript.charge_threshold_path(sys_root) != "":
		_charge_via = "fix"
		_charge_min = CHARGE_MIN
		_charge = read_charge_sysfs()


func _detect_fan() -> void:
	_fan_via = ""
	_fan_mode = ""
	var v: Variant = user_bus.get_prop(SM_SERVICE, SM_PATH, SM_FAN_IFACE, "FanControlState")
	if v != null:
		_fan_via = "steamos-manager"
		_fan_mode = "auto" if int(v) == 1 else "firmware"
		return
	if device.get("fan", null) == "msi_wmi_platform" and _helper_present() \
			and DeviceScript.find_hwmon("msi_wmi_platform", sys_root) != "":
		_fan_via = "fix"
		_fan_mode = read_fan_sysfs()


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
		return FIX_FAN_MODES.duplicate()
	if _fan_via == "steamos-manager":
		return SM_FAN_MODES.duplicate()
	return []


## Read the live values again (after resume, or when another tool changed them).
func refresh() -> void:
	var v := read_tdp()
	if v >= 0.0:
		_tdp_w = v
	if _charge_via == "steamos-manager":
		var c: Variant = user_bus.get_prop(SM_SERVICE, SM_PATH, SM_CHARGE_IFACE, "MaxChargeLevel")
		_charge = int(c) if c != null else -1
	elif _charge_via == "fix":
		_charge = read_charge_sysfs()
	if _fan_via == "fix":
		_fan_mode = read_fan_sysfs()
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
	if backend == "none" or not profile_name in PROFILES:
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


func _apply_user_tdp(w: float) -> bool:
	_user_tdp = w
	if _autotune_on:
		var t: float = autotune.set_ceiling(w)
		return write_tdp(t if t > 0.0 else w)
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
	# root actions only when the live value differs, so no needless prompt
	var c := int(_recall("device", "charge_limit", -1))
	if c > 0 and _charge_via != "" and c != _charge:
		set_charge_limit(c)
	var f := str(_recall("device", "fan_mode", ""))
	if f != "" and _fan_via != "" and f != _fan_mode:
		set_fan_mode(f)


func check_power_source() -> void:
	var now := DeviceScript.ac_online(sys_root)
	if now == plugged:
		return
	plugged = now
	restore()
	_emit_changed()


func _source() -> String:
	return "plugged" if plugged else "battery"


func _remember(section: String, key: String, value: Variant) -> void:
	var cfg := ConfigFile.new()
	cfg.load(config_path)
	cfg.set_value(section, key, value)
	cfg.save(config_path)


func _recall(section: String, key: String, fallback: Variant) -> Variant:
	var cfg := ConfigFile.new()
	if cfg.load(config_path) != OK:
		return fallback
	return cfg.get_value(section, key, fallback)


# ---- TDP ----------------------------------------------------------------------

## The TDP as the backend reports it now, or -1.
func read_tdp() -> float:
	var v: Variant = null
	if backend == "steamos-manager":
		v = user_bus.get_prop(SM_SERVICE, SM_PATH, SM_TDP_IFACE, "TdpLimit")
	elif backend == "powerstation":
		v = system_bus.get_prop(PS_SERVICE, _ps_card, PS_TDP_IFACE, "TDP")
	return float(v) if v != null else -1.0


## Write the TDP and read it back. On PowerStation the boost (PL2 - PL1) is set
## to the device's "pl2_offset_w" too (2 W on Intel, as Handheld Daemon,
## PowerControl and PowerStation's own database do).
func write_tdp(watts: float) -> bool:
	var ok := false
	if backend == "steamos-manager":
		var w := int(roundf(watts))
		if user_bus.set_prop(SM_SERVICE, SM_PATH, SM_TDP_IFACE, "TdpLimit", "u", str(w)):
			ok = absf(read_tdp() - w) < 0.5
	elif backend == "powerstation":
		if system_bus.set_prop(PS_SERVICE, _ps_card, PS_TDP_IFACE, "TDP", "d", "%.1f" % watts):
			if device.has("pl2_offset_w"):
				system_bus.set_prop(PS_SERVICE, _ps_card, PS_TDP_IFACE, "Boost", "d", "%.1f" % float(device["pl2_offset_w"]))
			ok = absf(read_tdp() - watts) < 0.5
	if ok:
		_tdp_w = watts
	return ok


# ---- charge limit -------------------------------------------------------------

## 50-100 %. 100 means no limit.
func set_charge_limit(percent: int) -> bool:
	if _charge_via == "" or percent < _charge_min or percent > 100:
		return false
	var got := -1
	if _charge_via == "steamos-manager":
		if user_bus.set_prop(SM_SERVICE, SM_PATH, SM_CHARGE_IFACE, "MaxChargeLevel", "i", str(percent)):
			var v: Variant = user_bus.get_prop(SM_SERVICE, SM_PATH, SM_CHARGE_IFACE, "MaxChargeLevel")
			got = int(v) if v != null else -1
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
## limit") reads as 100. -1 when unreadable.
func read_charge_sysfs() -> int:
	var raw := DeviceScript.read_text(DeviceScript.charge_threshold_path(sys_root))
	if not raw.is_valid_int():
		return -1
	var v := raw.to_int()
	return 100 if v == 0 else v


# ---- fan ----------------------------------------------------------------------

func set_fan_mode(mode: String) -> bool:
	if _fan_via == "" or not mode in fan_modes():
		return false
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
	if got != mode:
		return false
	_fan_mode = got
	_remember("device", "fan_mode", mode)
	_emit_changed()
	return true


## "auto" (pwmN_enable = 2, MSI's own control), "quiet"/"max" when every fan's
## table matches that preset, "custom" otherwise, "" when unreadable.
func read_fan_sysfs() -> String:
	var h := DeviceScript.find_hwmon("msi_wmi_platform", sys_root)
	if h == "":
		return ""
	var fans := []
	for n in [1, 2]:
		if FileAccess.file_exists(h + "pwm%d_enable" % n):
			fans.append(n)
	if fans.is_empty():
		return ""
	var enables := []
	for n in fans:
		enables.append(DeviceScript.read_text(h + "pwm%d_enable" % n))
	if enables.all(func(e): return e == "2"):
		return "auto"
	if not enables.all(func(e): return e == "1"):
		return "custom"
	for preset in FAN_TABLES:
		var table: Array = FAN_TABLES[preset]
		var match_all := true
		for n in fans:
			for i in range(6):
				var raw := DeviceScript.read_text(h + "pwm%d_auto_point%d_pwm" % [n, i + 1])
				# hwmon's 0-255 scale; the EC stores percent, so allow rounding
				if not raw.is_valid_int() or absi(roundi(raw.to_int() * 100.0 / 255.0) - int(table[i])) > 1:
					match_all = false
		if match_all:
			return preset
	return "custom"


# ---- root actions -------------------------------------------------------------

## The command for a root action, per docs/CONTRACTS.md "Root actions".
func fix_command(fix_name: String, value: String) -> PackedStringArray:
	return PackedStringArray(["pkexec", fix_helper, fix_name, "set", value])


func _run_fix(fix_name: String, value: String) -> bool:
	var argv := fix_command(fix_name, value)
	var r: Dictionary = runner.run(argv[0], argv.slice(1))
	return int(r.get("code", -1)) == 0


# ---- auto TDP -----------------------------------------------------------------

## Start Auto TDP for a game; it works under the TDP the user picked.
func autotune_start() -> bool:
	if backend == "none":
		return false
	if _user_tdp <= 0.0:
		_user_tdp = _tdp_w if _tdp_w > 0.0 else tdp_max()
	_autotune_on = true
	var w: float = autotune.start(_range["min"], _user_tdp)
	return write_tdp(w) if w > 0.0 else true


## One sample per second while the game runs: rendered fps and package watts.
func autotune_feed(fps: float, watts := -1.0) -> void:
	if not _autotune_on:
		return
	var w: float = autotune.feed(fps, watts)
	if w > 0.0:
		_queue("autotune", func():
			if write_tdp(w):
				_emit_changed()
			return true)


## Game closed: back to the user's own TDP.
func autotune_stop() -> void:
	if not _autotune_on:
		return
	_autotune_on = false
	autotune.stop()
	if _user_tdp > 0.0:
		var w := _user_tdp
		_queue("autotune", func():
			if write_tdp(w):
				_emit_changed()
			return true)
