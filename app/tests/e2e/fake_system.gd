extends "res://tests/devicematrix/matrix.gd".FakeRunner
## The whole fake handheld behind ctx.runner for the end-to-end suite: the
## device matrix's FakeRunner (stateful D-Bus props, gamescope root atoms,
## canned command answers) plus what a running system does with the calls:
##
##   steamos-manager  TdpLimit1 through the firmware attribute exactly like
##                    steamos-manager a3b2013 src/power.rs FirmwareAttributeLimitManager
##                    (range from ppt_pl1_spl min/max, refused unless the platform
##                    profile is the one its device config names, SPPT/FPPT follow);
##                    PerformanceProfile1 / CpuBoost1 / CpuScaling1 / GpuPerformanceLevel1 /
##                    BatteryChargeLimit1 read and write the sysfs files behind them
##   PowerStation     TDP and Boost on Intel RAPL (PL1 = TDP, PL2 = TDP + Boost),
##                    SMT, cores online, AMD boost, amdgpu clocks
##   tuned-ppd        ActiveProfile only from the offered list
##   root helper      `pkexec gamecove-fix-set ...` runs the REAL packaging/libexec
##                    script and fixes/*/fix.sh with GAMECOVE_ROOT = the fixture, so the
##                    helper's own checks decide; `pkexec gamecove-fix` (password) fails
##                    the way it does in Gaming Mode (no polkit agent)
##
## Faults (set `faults`): "helper": "deny" (polkit says no) | "fail" (exit 1);
## "dbus_timeout": [service names, or "*"] answer after `timeout_ms` with busctl's
## timeout error; "latency_ms": every command takes this long (off the main thread
## only: a command on the main thread is recorded as such, see main_thread_calls);
## "xprop": "fail"; "readonly": true (sysfs writes refused, see World.set_readonly).
##
## Every call is logged with the thread it ran on: `log` [{t_ms, argv, main, code}].

const SM := "com.steampowered.SteamOSManager1"
const SM_PATH := "/com/steampowered/SteamOSManager1"
const PS := "org.shadowblip.PowerStation"
const PPD := "org.freedesktop.UPower.PowerProfiles"
const FIX_SET := "/usr/libexec/gamecove/gamecove-fix-set"
const FIX_ADMIN := "/usr/libexec/gamecove/gamecove-fix"
## steamos-manager device configs (data/devices/*.toml, a3b2013): which firmware
## attribute carries the TDP and the platform profile it needs to be active.
const SM_TDP := {
	"asus-rog-ally": {"attr": "asus-armoury", "profile": "performance"},
	"lenovo-legion-go-s-z2go": {"attr": "lenovo-wmi-other-0", "profile": "custom"},
	"msi-claw-8-ex": {"attr": "msi-wmi-platform", "profile": "custom"},
}

var root := ""
var repo := ""
var row_id := ""
var stub_dir := ""
var log: Array = []
var faults: Dictionary = {}
var timeout_ms := 250
## Helper runs: [argv, code, output]
var helper_runs: Array = []
## Sessions asked for: "desktop", "steam", "suspend"...
var events: Array = []
var _log_mutex := Mutex.new()
var _start_ms := Time.get_ticks_msec()


func _init(backends: Dictionary, sys_root: String, repo_dir: String, device_row: String) -> void:
	super(backends, "ok")
	root = sys_root
	repo = repo_dir
	row_id = device_row
	stub_dir = sys_root.get_base_dir().path_join("stubs")
	DirAccess.make_dir_recursive_absolute(stub_dir)
	for prog in ["systemctl", "logger", "udevadm", "modprobe", "rpm-ostree", "steamos-readonly"]:
		var f := FileAccess.open(stub_dir.path_join(prog), FileAccess.WRITE)
		f.store_string("#!/bin/sh\n# e2e stand-in: records nothing, changes nothing\nexit 0\n")
		f.close()
		FileAccess.set_unix_permissions(stub_dir.path_join(prog), 493)


func reset_log() -> void:
	_log_mutex.lock()
	log.clear()
	helper_runs.clear()
	events.clear()
	calls.clear()
	unmatched.clear()
	_log_mutex.unlock()


func log_copy() -> Array:
	_log_mutex.lock()
	var out := log.duplicate(true)
	_log_mutex.unlock()
	return out


## Commands that ran on the main thread since the last reset (the UI waited for them).
func main_thread_calls() -> Array:
	return log_copy().filter(func(e): return e["main"])


func run(program: String, args: PackedStringArray) -> Dictionary:
	var main := OS.get_thread_caller_id() == OS.get_main_thread_id()
	var lat := int(faults.get("latency_ms", 0))
	if lat > 0 and not main:
		OS.delay_msec(lat)
	var r := _dispatch(program, args)
	_log_mutex.lock()
	log.append({"t_ms": Time.get_ticks_msec() - _start_ms, "argv": [program] + Array(args), "main": main,
		"code": int(r.get("code", -1))})
	_log_mutex.unlock()
	return r


func spawn(program: String, args: PackedStringArray) -> int:
	_log_mutex.lock()
	log.append({"t_ms": Time.get_ticks_msec() - _start_ms, "argv": [program] + Array(args),
		"main": OS.get_thread_caller_id() == OS.get_main_thread_id(), "code": 0, "spawn": true})
	_log_mutex.unlock()
	if program.ends_with("session-select") and args.size() > 0:
		_event(str(args[0]))
	return super.spawn(program, args)


func _event(e: String) -> void:
	_log_mutex.lock()
	events.append(e)
	_log_mutex.unlock()


func _dispatch(program: String, args: PackedStringArray) -> Dictionary:
	match program:
		"pkexec":
			return _pkexec(args)
		"busctl":
			return _bus(args)
		"systemctl":
			if args.size() > 0 and args[0] in ["suspend", "hibernate", "poweroff", "reboot"]:
				_event(str(args[0]))
				return {"code": 0, "out": ""}
		"xprop":
			if str(faults.get("xprop", "")) == "fail":
				_mutex.lock()
				calls.append([program, args])
				_mutex.unlock()
				return {"code": 1, "out": "xprop: unable to open display ':0'"}
	return super.run(program, args)


# ---- root helper -----------------------------------------------------------------

func _pkexec(args: PackedStringArray) -> Dictionary:
	_mutex.lock()
	calls.append(["pkexec", args])
	_mutex.unlock()
	if args.is_empty():
		return {"code": 127, "out": ""}
	var helper := str(args[0])
	if helper == FIX_ADMIN:
		# Gaming Mode: no polkit agent, so auth_admin_keep can't ask
		return {"code": 127, "out": "Error executing command as another user: No authentication agent found."}
	if helper != FIX_SET:
		return {"code": 127, "out": "pkexec: not allowed"}
	match str(faults.get("helper", "")):
		"deny":
			return {"code": 126, "out": "Error executing command as another user: Not authorized"}
		"fail":
			return {"code": 1, "out": "gamecove-fix: the kernel refused"}
	var script := repo.path_join("packaging/libexec/gamecove-fix-set")
	var argv := PackedStringArray(["GAMECOVE_ROOT=" + root, "GAMECOVE_FIXES_DIR=" + repo.path_join("fixes"),
		"GAMECOVE_PATH=" + stub_dir, "GAMECOVE_THERMALD_WATCH=off", "sh", script])
	argv.append_array(args.slice(1))
	var out := []
	var code := OS.execute("env", argv, out, true)
	var text := "".join(PackedStringArray(out.map(func(x): return str(x))))
	_log_mutex.lock()
	helper_runs.append([Array(args.slice(1)), code, text])
	_log_mutex.unlock()
	return {"code": code, "out": text}


# ---- D-Bus services ----------------------------------------------------------------

func _timed_out(svc: String) -> bool:
	var t: Variant = faults.get("dbus_timeout", [])
	return t is Array and ("*" in t or svc in t)


func _bus(args: PackedStringArray) -> Dictionary:
	var a := Array(args).filter(func(x): return not str(x).begins_with("--timeout") and not str(x).begins_with("--json"))
	if a.size() >= 3 and _timed_out(str(a[2])):
		_mutex.lock()
		calls.append(["busctl", args])
		_mutex.unlock()
		if OS.get_thread_caller_id() != OS.get_main_thread_id():
			OS.delay_msec(timeout_ms)
		return {"code": 1, "out": "Failed to get property: Connection timed out"}
	if a.size() >= 6 and str(a[1]) in ["get-property", "set-property"]:
		var svc := str(a[2])
		var iface := str(a[4])
		var prop := str(a[5])
		if a[1] == "get-property":
			var live: Variant = _live_get(svc, str(a[3]), iface, prop)
			if live != null:
				_mutex.lock()
				calls.append(["busctl", args])
				_mutex.unlock()
				if live is Dictionary and live.has("error"):
					return {"code": 1, "out": str(live["error"])}
				var key := " ".join(PackedStringArray([str(a[0]), svc, str(a[3]), iface, prop]))
				var typ: String = props[key]["type"] if props.has(key) else "s"
				return {"code": 0, "out": JSON.stringify({"type": typ, "data": live})}
		elif a.size() >= 8 and mode == "ok":
			var err := _live_set(svc, str(a[3]), iface, prop, str(a[7]))
			if err != "":
				_mutex.lock()
				calls.append(["busctl", args])
				_mutex.unlock()
				return {"code": 1, "out": "Failed to set property %s: %s" % [prop, err]}
	return super.run("busctl", args)


## Values a running service reads from the hardware (null: use the stored prop).
func _live_get(svc: String, _obj: String, iface: String, prop: String) -> Variant:
	if svc == SM:
		match iface.trim_prefix(SM + ".") + "." + prop:
			"TdpLimit1.TdpLimit":
				var cfg: Dictionary = SM_TDP.get(row_id, {})
				if cfg.is_empty():
					return null
				if cfg["profile"] != "" and _rd("/sys/firmware/acpi/platform_profile") != cfg["profile"]:
					return {"error": "TDP limiting not active"}
				return _rd(_attr(cfg["attr"], "ppt_pl1_spl") + "/current_value").to_int()
			"TdpLimit1.TdpLimitMin", "TdpLimit1.TdpLimitMax":
				var cfg: Dictionary = SM_TDP.get(row_id, {})
				if cfg.is_empty():
					return null
				return _rd(_attr(cfg["attr"], "ppt_pl1_spl") + ("/min_value" if prop.ends_with("Min") else "/max_value")).to_int()
			"PerformanceProfile1.PerformanceProfile":
				return _rd("/sys/firmware/acpi/platform_profile") if _exists("/sys/firmware/acpi/platform_profile") else null
			"CpuBoost1.CpuBoostState":
				return _rd("/sys/devices/system/cpu/cpufreq/boost").to_int() if _exists("/sys/devices/system/cpu/cpufreq/boost") else null
			"CpuScaling1.CpuScalingGovernor":
				return _rd("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor")
			"GpuPerformanceLevel1.GpuPerformanceLevel":
				var f := _gpu_level_file()
				return _rd(f) if f != "" else null
			"BatteryChargeLimit1.MaxChargeLevel":
				var key := "--user %s %s %s.BatteryChargeLimit1 MaxChargeLevel" % [SM, SM_PATH, SM]
				if props.has(key) and int(props[key]["data"]) < 0:
					return null   # reads -1 here (msi-claw-8-ex): the stored prop answers
				var t := _charge_file()
				return _rd(t).to_int() if t != "" else null
	if svc == PS and iface == "org.shadowblip.CPU":
		match prop:
			"SmtEnabled":
				return _rd("/sys/devices/system/cpu/smt/control") == "on"
			"CoresEnabled":
				var n := 1
				for d in DirAccess.get_directories_at(root + "/sys/devices/system/cpu"):
					if d.begins_with("cpu") and d.substr(3).is_valid_int() and d != "cpu0":
						n += 1 if _rd("/sys/devices/system/cpu/%s/online" % d) != "0" else 0
				return n
	return null


## Side effects of a property write; "" when it was taken, else the service's error.
func _live_set(svc: String, obj: String, iface: String, prop: String, raw: String) -> String:
	if svc == SM:
		match iface.trim_prefix(SM + ".") + "." + prop:
			"TdpLimit1.TdpLimit":
				var cfg: Dictionary = SM_TDP.get(row_id, {})
				if cfg.is_empty():
					return ""
				if cfg["profile"] != "" and _rd("/sys/firmware/acpi/platform_profile") != cfg["profile"]:
					return "TDP limiting not active"
				var base := _attr(cfg["attr"], "")
				var v := raw.to_int()
				if not raw.is_valid_int() or v < _rd(base + "ppt_pl1_spl/min_value").to_int() or v > _rd(base + "ppt_pl1_spl/max_value").to_int():
					return "Invalid limit"
				_wr(base + "ppt_pl1_spl/current_value", str(v))
				for a in ["ppt_pl2_sppt", "ppt_pl3_fppt"]:
					if _exists(base + a + "/current_value"):
						_wr(base + a + "/current_value", str(maxi(v, _rd(base + a + "/min_value").to_int())))
			"PerformanceProfile1.PerformanceProfile":
				if not raw in _rd("/sys/firmware/acpi/platform_profile_choices").split(" ", false):
					return "Invalid profile"
				_wr("/sys/firmware/acpi/platform_profile", raw)
			"CpuBoost1.CpuBoostState":
				if not raw in ["0", "1"]:
					return "Invalid state"
				_wr("/sys/devices/system/cpu/cpufreq/boost", raw)
			"CpuScaling1.CpuScalingGovernor":
				if not raw in _rd("/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors").split(" ", false):
					return "Invalid governor"
				for d in DirAccess.get_directories_at(root + "/sys/devices/system/cpu"):
					if _exists("/sys/devices/system/cpu/%s/cpufreq/scaling_governor" % d):
						_wr("/sys/devices/system/cpu/%s/cpufreq/scaling_governor" % d, raw)
			"GpuPerformanceLevel1.GpuPerformanceLevel":
				var f := _gpu_level_file()
				if f != "":
					if not raw in ["auto", "low", "high", "manual", "peak_performance"]:
						return "Invalid level"
					_wr(f, "profile_peak" if raw == "peak_performance" else raw)
			"BatteryChargeLimit1.MaxChargeLevel":
				var t := _charge_file()
				if t == "":
					return "Not supported"
				var v := raw.to_int()
				if v == -1:
					v = 100
				if v < 0 or v > 100:
					return "Invalid limit"
				_wr(t, str(v))
		return ""
	if svc == PS:
		match iface + "." + prop:
			"org.shadowblip.GPU.Card.TDP.TDP", "org.shadowblip.GPU.Card.TDP.Boost":
				var tdp := raw.to_float() if prop == "TDP" else float(_prop(svc, obj, iface, "TDP"))
				var boost := raw.to_float() if prop == "Boost" else float(_prop(svc, obj, iface, "Boost"))
				if tdp <= 0.0 or boost < 0.0:
					return "Invalid value"
				var rapl := "/sys/class/powercap/intel-rapl-mmio:0"
				if _exists(rapl + "/constraint_0_power_limit_uw"):
					_wr(rapl + "/constraint_0_power_limit_uw", str(int(tdp * 1000000.0)))
					_wr(rapl + "/constraint_1_power_limit_uw", str(int((tdp + boost) * 1000000.0)))
			"org.shadowblip.CPU.SmtEnabled":
				if _rd("/sys/devices/system/cpu/smt/control") in ["notsupported", "notimplemented", ""]:
					return "SMT not supported"
				_wr("/sys/devices/system/cpu/smt/control", "on" if raw == "true" else "off")
			"org.shadowblip.CPU.CoresEnabled":
				var n := raw.to_int()
				var nums := []
				for d in DirAccess.get_directories_at(root + "/sys/devices/system/cpu"):
					if d.begins_with("cpu") and d.substr(3).is_valid_int():
						nums.append(d.substr(3).to_int())
				nums.sort()
				if n < 1 or n > nums.size():
					return "Invalid count"
				for c in nums:
					if c > 0:
						_wr("/sys/devices/system/cpu/cpu%d/online" % c, "1" if c < n else "0")
			"org.shadowblip.CPU.BoostEnabled":
				if _exists("/sys/devices/system/cpu/cpufreq/boost"):
					_wr("/sys/devices/system/cpu/cpufreq/boost", "1" if raw == "true" else "0")
		return ""
	if svc == PPD and prop == "ActiveProfile":
		var offered := []
		var key := "--system %s /org/freedesktop/UPower/PowerProfiles %s Profiles" % [PPD, PPD]
		for p in props.get(key, {}).get("data", []):
			offered.append(str(p["Profile"]["data"]))
		if not raw in offered:
			return "Invalid profile"
		# tuned's acpi plugin sets the firmware platform profile with each tuned profile
		# (tuned-ppd maps power-saver / balanced / performance onto them)
		var choices := _rd("/sys/firmware/acpi/platform_profile_choices").split(" ", false)
		var want := {"power-saver": ["low-power", "quiet"], "balanced": ["balanced"], "performance": ["performance"]}
		for wpp in want.get(raw, []):
			if wpp in choices:
				_wr("/sys/firmware/acpi/platform_profile", wpp)
				break
	return ""


func _prop(svc: String, obj: String, iface: String, name: String) -> Variant:
	for k in props:
		if str(k).ends_with(" %s %s %s %s" % [svc, obj, iface, name]):
			return props[k]["data"]
	return 0.0


## Value of a stored D-Bus property (any bus), null when there is none.
func prop(svc: String, obj: String, iface: String, name: String) -> Variant:
	_mutex.lock()
	var out: Variant = null
	for k in props:
		if str(k).ends_with(" %s %s %s %s" % [svc, obj, iface, name]):
			out = props[k]["data"]
	_mutex.unlock()
	return out


func _attr(fw: String, a: String) -> String:
	return "/sys/class/firmware-attributes/%s/attributes/%s" % [fw, a]


func _gpu_level_file() -> String:
	for c in ["card0", "card1"]:
		var f := "/sys/class/drm/%s/device/power_dpm_force_performance_level" % c
		if _exists(f):
			return f
	return ""


func _charge_file() -> String:
	for b in ["BAT0", "BAT1"]:
		var f := "/sys/class/power_supply/%s/charge_control_end_threshold" % b
		if _exists(f):
			return f
	return ""


func _exists(rel: String) -> bool:
	return FileAccess.file_exists(root + rel)


func _rd(rel: String) -> String:
	if not FileAccess.file_exists(root + rel):
		return ""
	return FileAccess.get_file_as_string(root + rel).strip_edges()


func _wr(rel: String, v: String) -> void:
	var f := FileAccess.open(root + rel, FileAccess.WRITE)
	if f != null:
		f.store_string(v + "\n")
		f.close()


## Gamescope's CommandRunner interface ({"exit", "output"}) over this fake, with the
## real one's worker thread for run_async (scripts/gamescope/command_runner.gd).
class GamescopeRunner extends "res://scripts/gamescope/command_runner.gd":
	var fake: RefCounted

	func _init(f: RefCounted) -> void:
		fake = f

	func run(program: String, args: PackedStringArray) -> Dictionary:
		var r: Dictionary = fake.run(program, args)
		return {"exit": int(r.get("code", -1)), "output": str(r.get("out", ""))}


## bg_command.gd's runner interface (quick menu session switches).
class BgRunner extends RefCounted:
	var fake: RefCounted

	func _init(f: RefCounted) -> void:
		fake = f

	func run(program: String, args: PackedStringArray) -> Dictionary:
		return fake.run(program, args)

	func spawn(program: String, args: PackedStringArray) -> int:
		return fake.spawn(program, args)
