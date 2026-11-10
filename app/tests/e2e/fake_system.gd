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

const Matrix := preload("res://tests/devicematrix/matrix.gd")
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
	_kernel_settle([], -1)   # what the bracketed files and clock tables offer, before any write


func reset_log() -> void:
	_log_mutex.lock()
	log.clear()
	helper_runs.clear()
	events.clear()
	calls.clear()
	pass   # unmatched commands stay for the whole run (E2E_UNMATCHED)
	_log_mutex.unlock()


func log_copy() -> Array:
	_log_mutex.lock()
	var out := log.duplicate(true)
	_log_mutex.unlock()
	return out


## Commands that ran on the main thread since the last reset (the UI waited for them).
func main_thread_calls() -> Array:
	return log_copy().filter(func(e): return e["main"])


## Calls the harness itself makes (a fresh read to compare with) are answered but
## not logged: hold() / release() around them, on the main thread only.
var _held_by_harness := 0


func hold() -> void:
	_held_by_harness += 1


func release() -> void:
	_held_by_harness = maxi(0, _held_by_harness - 1)


func run(program: String, args: PackedStringArray) -> Dictionary:
	var main := OS.get_thread_caller_id() == OS.get_main_thread_id()
	if main and _held_by_harness > 0:
		return _dispatch(program, args)
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
	# the quick menu runs the session switch to read its result (review M8): the switch "works"
	if program.ends_with("session-select") and args.size() > 0:
		_event(str(args[0]))
		return {"code": 0, "out": ""}
	match program:
		"pkexec":
			return _pkexec(args)
		"busctl":
			return _bus(args)
		"wpctl":
			var w := _wpctl(args)
			if not w.is_empty():
				return w
		"nmcli", "rfkill":
			var r := _radio(program, args)
			if not r.is_empty():
				return r
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
	_kernel_settle(Array(args.slice(1)), code)
	_log_mutex.lock()
	helper_runs.append([Array(args.slice(1)), code, text])
	_log_mutex.unlock()
	return {"code": code, "out": text}


## What the kernel shows after the helper wrote a word or a command into a file
## that isn't a plain value: "[active] other" lists, and amdgpu's clock table,
## which takes "s <idx> <MHz>" / "c" / "r" commands.
const BRACKETED := ["/sys/power/mem_sleep", "/tile0/gt0/freq0/power_profile", "/charge_types", "/charge_behaviour"]
var _choices := {}   # rel path -> words offered (from the pristine file)
var _od := {}        # rel path -> [min, max, lo, hi]


func _kernel_settle(args: Array, code: int) -> void:
	var files := {}
	Matrix._walk(root, "/sys", files)
	for rel in files:
		var text: String = files[rel]
		for suffix in BRACKETED:
			if rel.ends_with(suffix):
				if "[" in text:
					_choices[rel] = Array(text.replace("[", "").replace("]", "").split(" ", false))
				elif _choices.has(rel) and text in _choices[rel]:
					_wr(rel, " ".join(PackedStringArray(_choices[rel].map(func(x): return "[%s]" % x if x == text else x))))
		if rel.ends_with("/pp_od_clk_voltage"):
			if text.begins_with("OD_SCLK"):
				var nums := []
				for line in text.split("\n"):
					var m := RegEx.create_from_string("([0-9]+)Mhz").search_all(line)
					for x in m:
						nums.append(x.get_string(1).to_int())
				if nums.size() >= 4:
					_od[rel] = [nums[0], nums[1], nums[2], nums[3]]
			elif _od.has(rel):
				var st: Array = _od[rel]
				if code == 0 and args.size() >= 3 and str(args[2]).begins_with("gpumin:"):
					st[0] = str(args[2]).trim_prefix("gpumin:").to_int()
				elif code == 0 and args.size() >= 3 and str(args[2]).begins_with("gpumax:"):
					st[1] = str(args[2]).trim_prefix("gpumax:").to_int()
				elif text == "r":
					st[0] = st[2]
					st[1] = st[3]
				_wr(rel, "OD_SCLK:\n0:        %dMhz\n1:       %dMhz\nOD_RANGE:\nSCLK:     %dMhz       %dMhz" % st)


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
	# logind: the active session sets its own backlight (Session.SetBrightness ssu)
	if a.size() >= 10 and str(a[1]) == "call" and str(a[2]) == "org.freedesktop.login1" and str(a[5]) == "SetBrightness":
		_mutex.lock()
		calls.append(["busctl", args])
		_mutex.unlock()
		var bl := "/sys/class/backlight/%s/brightness" % str(a[8])
		var mx := _rd("/sys/class/backlight/%s/max_brightness" % str(a[8])).to_int()
		var raw := str(a[9]).to_int()
		if mode != "ok" or not _exists(bl) or raw < 0 or raw > mx:
			return {"code": 1, "out": "Call failed: Invalid argument"}
		_wr(bl, str(raw))
		if _rd(bl) != str(raw):
			return {"code": 1, "out": "Call failed: Read-only file system"}
		return {"code": 0, "out": ""}
	if a.size() >= 6 and str(a[1]) == "call" and str(a[2]) == "org.shadowblip.InputPlumber":
		var ipr := _ip_call(str(a[3]), str(a[4]), str(a[5]), a.slice(6))
		if not ipr.is_empty():
			_mutex.lock()
			calls.append(["busctl", args])
			_mutex.unlock()
			return ipr
	if a.size() >= 6 and str(a[1]) in ["get-property", "set-property"]:
		var svc := str(a[2])
		var iface := str(a[4])
		var prop := str(a[5])
		var stored := props.has(" ".join(PackedStringArray([str(a[0]), svc, str(a[3]), iface, prop])))
		if a[1] == "get-property" and stored:
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
		elif a[1] == "set-property" and a.size() >= 8 and mode == "ok" and stored:
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
				# steamos-manager src/power.rs: intel_pstate's no_turbo (inverted), else cpufreq/boost
				if _exists("/sys/devices/system/cpu/intel_pstate/no_turbo"):
					return 1 - _rd("/sys/devices/system/cpu/intel_pstate/no_turbo").to_int()
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
	if svc == PS and iface == "org.shadowblip.GPU.Card.TDP" and prop in ["TDP", "Boost"]:
		# Intel: PowerStation reads the RAPL package limits (PL1, PL2 - PL1)
		var rapl := "/sys/class/powercap/intel-rapl-mmio:0/"
		if _exists(rapl + "constraint_0_power_limit_uw"):
			var pl1 := _rd(rapl + "constraint_0_power_limit_uw").to_float() / 1e6
			var pl2 := _rd(rapl + "constraint_1_power_limit_uw").to_float() / 1e6
			return pl1 if prop == "TDP" else maxf(0.0, pl2 - pl1)
	if svc == PS and iface == "org.shadowblip.CPU.Core" and prop == "Online":
		return _rd("/sys/devices/system/cpu/cpu%d/online" % _obj.get_file().trim_prefix("Core").to_int()) != "0"
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
				if _exists("/sys/devices/system/cpu/intel_pstate/no_turbo"):
					_wr("/sys/devices/system/cpu/intel_pstate/no_turbo", "1" if raw == "0" else "0")
				else:
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
			"org.shadowblip.CPU.Core.Online":
				var n := obj.get_file().trim_prefix("Core").to_int()
				if n <= 0 or not _exists("/sys/devices/system/cpu/cpu%d/online" % n):
					return "No such core"
				_wr("/sys/devices/system/cpu/cpu%d/online" % n, "1" if raw == "true" else "0")
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


# ---- PipeWire (wpctl), NetworkManager / rfkill ----------------------------------------

## WirePlumber's state: volume and mute per default sink / source, the defaults.
var audio := {"sinks": {50: "Speaker", 51: "HDMI / DisplayPort"}, "sources": {60: "Digital Microphone"},
	"sink": 50, "source": 60, "vol": {50: 0.5, 51: 1.0, 60: 0.8}, "mute": {50: false, 51: false, 60: false}}
var radios := {"wifi": true, "bluetooth": true, "wlan_soft": false, "bt_soft": false}


func _wpctl(args: PackedStringArray) -> Dictionary:
	var a := Array(args)
	if a.is_empty() or mode == "bare":
		return {}
	_mutex.lock()
	calls.append(["wpctl", args])
	var out := {}
	var target := func(x: String) -> int:
		if x == "@DEFAULT_AUDIO_SINK@" or x == "@DEFAULT_SINK@":
			return int(audio["sink"])
		if x == "@DEFAULT_AUDIO_SOURCE@" or x == "@DEFAULT_SOURCE@":
			return int(audio["source"])
		return x.to_int() if x.is_valid_int() else -1
	match str(a[0]):
		"status":
			var lines := PackedStringArray(["Audio", " ├─ Sinks:"])
			for id in audio["sinks"]:
				lines.append(" │  %s %d. %-28s [vol: %.2f]" % ["*" if id == audio["sink"] else " ", id, audio["sinks"][id], audio["vol"][id]])
			lines.append(" ├─ Sources:")
			for id in audio["sources"]:
				lines.append(" │  %s %d. %-28s [vol: %.2f]" % ["*" if id == audio["source"] else " ", id, audio["sources"][id], audio["vol"][id]])
			out = {"code": 0, "out": "\n".join(lines) + "\n"}
		"get-volume":
			var id: int = target.call(str(a[1])) if a.size() > 1 else -1
			out = {"code": 0, "out": "Volume: %.2f%s" % [audio["vol"].get(id, 0.0), " [MUTED]" if audio["mute"].get(id, false) else ""]} \
				if audio["vol"].has(id) else {"code": 1, "out": "Object not found"}
		"set-volume":
			if mode == "failing":
				out = {"code": 1, "out": ""}
			else:
				var words := a.slice(1)
				if words.size() >= 2 and words[0] == "-l":
					words = words.slice(2)   # -l <limit>
				var id: int = target.call(str(words[0])) if words.size() > 0 else -1
				var v := str(words[1]) if words.size() > 1 else ""
				if not audio["vol"].has(id) or not v.is_valid_float():
					out = {"code": 1, "out": "bad volume"}
				else:
					audio["vol"][id] = clampf(v.to_float(), 0.0, 1.0)
					out = {"code": 0, "out": ""}
		"set-mute":
			var id: int = target.call(str(a[1])) if a.size() > 1 else -1
			if mode == "failing" or not audio["mute"].has(id):
				out = {"code": 1, "out": ""}
			else:
				var m := str(a[2]) if a.size() > 2 else "toggle"
				audio["mute"][id] = (not audio["mute"][id]) if m == "toggle" else m == "1"
				out = {"code": 0, "out": ""}
		"set-default":
			var id := str(a[1]).to_int() if a.size() > 1 else -1
			if mode == "failing":
				out = {"code": 1, "out": ""}
			elif audio["sinks"].has(id):
				audio["sink"] = id
				out = {"code": 0, "out": ""}
			elif audio["sources"].has(id):
				audio["source"] = id
				out = {"code": 0, "out": ""}
			else:
				out = {"code": 1, "out": "Object not found"}
	_mutex.unlock()
	return out


func _radio(program: String, args: PackedStringArray) -> Dictionary:
	var a := Array(args)
	if mode == "bare":
		return {}
	_mutex.lock()
	calls.append([program, args])
	var out := {}
	if program == "nmcli":
		if a == ["-t", "-f", "WIFI", "radio"] or a == ["radio", "wifi"]:
			out = {"code": 0, "out": "enabled" if radios["wifi"] and not radios["wlan_soft"] else "disabled"}
		elif a.size() == 3 and a[0] == "radio" and a[1] == "wifi" and a[2] in ["on", "off"]:
			if mode == "failing":
				out = {"code": 1, "out": ""}
			else:
				radios["wifi"] = a[2] == "on"
				out = {"code": 0, "out": ""}
	else:
		if a == ["--json"]:
			var devs := [{"id": 0, "type": "wlan", "device": "phy0", "soft": "blocked" if radios["wlan_soft"] else "unblocked", "hard": "unblocked"},
				{"id": 1, "type": "bluetooth", "device": "hci0", "soft": "blocked" if radios["bt_soft"] else "unblocked", "hard": "unblocked"}]
			out = {"code": 0, "out": JSON.stringify({"rfkilldevices": devs})}
		elif a.size() >= 2 and a[0] in ["block", "unblock"]:
			if mode == "failing":
				out = {"code": 1, "out": ""}
			else:
				var on: bool = a[0] == "block"
				for t in a.slice(1):
					if t in ["all", "wlan", "wifi", "0"]:
						radios["wlan_soft"] = on
					if t in ["all", "bluetooth", "1"]:
						radios["bt_soft"] = on
				for i in 2:
					_wr("/sys/class/rfkill/rfkill%d/soft" % i, "1" if radios["wlan_soft" if i == 0 else "bt_soft"] else "0")
				out = {"code": 0, "out": ""}
	_mutex.unlock()
	return out


# ---- InputPlumber's composite device ------------------------------------------------------

## The profile InputPlumber has loaded (what GetProfileYaml serializes).
var ip_profile: Dictionary = {"version": 1, "kind": "DeviceProfile", "name": "Default", "mapping": []}
var ip_loads := 0


func _ip_call(path: String, iface: String, method: String, a: Array) -> Dictionary:
	if not path.begins_with("/org/shadowblip/InputPlumber/CompositeDevice"):
		return {}
	match method:
		"GetProfileYaml":
			return {"code": 0, "out": JSON.stringify({"type": "s", "data": [to_yaml(ip_profile)]})}
		"LoadProfileFromYaml":
			if mode == "failing":
				return {"code": 1, "out": "Call failed: refused"}
			var p: Variant = JSON.parse_string(str(a[1])) if a.size() > 1 else null
			if not p is Dictionary or not p.has("version"):
				return {"code": 1, "out": "Call failed: invalid profile"}
			ip_profile = p
			ip_loads += 1
			var key := "--system org.shadowblip.InputPlumber %s org.shadowblip.Input.CompositeDevice ProfileName" % path
			if props.has(key):
				props[key]["data"] = str(p.get("name", ""))
			return {"code": 0, "out": ""}
		"SetInterceptActivation", "Rumble", "Stop":
			return {"code": 0 if mode != "failing" else 1, "out": ""}
	return {}


## serde_yaml-style block YAML (what InputPlumber hands back), enough for profiles.
static func to_yaml(v: Variant, indent := 0) -> String:
	var pad := "  ".repeat(indent)
	if v is Dictionary:
		if v.is_empty():
			return pad + "{}\n"
		var out := ""
		for k in v:
			var x: Variant = v[k]
			if (x is Dictionary and not x.is_empty()) or (x is Array and not x.is_empty()):
				out += "%s%s:\n%s" % [pad, k, to_yaml(x, indent + 1 if x is Dictionary else indent)]
			else:
				out += "%s%s: %s\n" % [pad, k, _scalar(x)]
		return out
	if v is Array:
		if v.is_empty():
			return pad + "[]\n"
		var out := ""
		for x in v:
			if x is Dictionary and not x.is_empty():
				var inner := to_yaml(x, indent + 1).trim_prefix("  ".repeat(indent + 1))
				out += "%s- %s" % [pad, inner]
			elif x is Array and not x.is_empty():
				out += "%s-\n%s" % [pad, to_yaml(x, indent + 1)]
			else:
				out += "%s- %s\n" % [pad, _scalar(x)]
		return out
	return pad + _scalar(v) + "\n"


static func _scalar(x: Variant) -> String:
	if x == null:
		return "null"
	if x is bool:
		return "true" if x else "false"
	if x is int or x is float:
		return str(int(x)) if x is float and x == floorf(x) else str(x)
	if x is Dictionary:
		return "{}"
	if x is Array:
		return "[]"
	return JSON.stringify(str(x))
