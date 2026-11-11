extends RefCounted
## Where PerfMonitor reads each number from, found once per game (discover())
## and then read with plain file reads: no process per sample. Every path
## starts with `root` ("" on the real system, a fixture folder in tests).
##
## Sources, in order of preference (docs/CONTRACTS.md "Performance"):
##   cpu_load   /proc/stat (delta of the aggregate line)
##   package_w  RAPL /sys/class/powercap/intel-rapl:N "package-0" energy_uj
##              (Intel and AMD; root-only on kernels >= 5.10 unless the distro
##              opens it, so discover() checks it can really read it), else
##              amdgpu hwmon power1_average / power1_input on an AMD APU (the
##              socket power the TDP limits; Steam Deck, Ally, Legion Go)
##   gpu_w      RAPL "uncore" subzone (older Intel), amdgpu power on a dGPU,
##              xe/i915 hwmon energy1_input (discrete Intel only)
##   gpu_load   amdgpu device/gpu_busy_percent (Intel has no sysfs file: the
##              MangoHud log's gpu_load fills it in)
##   gpu_mhz    xe  device/tile0/gt0/freq0/act_freq, i915 gt_act_freq_mhz,
##              amdgpu hwmon freq1_input (Hz)
##   cpu_temp   hwmon coretemp / k10temp / zenpower temp1_input, else the
##              x86_pkg_temp thermal zone
##   gpu_temp   amdgpu hwmon temp1_input, discrete Intel hwmon temp1_input;
##              integrated Intel shares the package temperature
##   battery_w  power_supply BAT*: power_now, or current_now * voltage_now,
##              only while discharging

const DRM := "/sys/class/drm/"
const HWMON := "/sys/class/hwmon/"
const POWERCAP := "/sys/class/powercap/"
const THERMAL := "/sys/class/thermal/"
const POWER_SUPPLY := "/sys/class/power_supply/"
const CPU_HWMONS := ["coretemp", "k10temp", "zenpower"]
## An AMD GPU with at most this much dedicated VRAM is taken as an APU (its
## "VRAM" is the carve-out from system memory), so its power is the package's.
const APU_VRAM_MAX := 4 * 1024 * 1024 * 1024


## Reads the first line of a sysfs/procfs file. "" when missing or unreadable.
## (procfs files report size 0, so this reads by line, not by length.)
static func read_line(path: String) -> String:
	if path == "":
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_line().strip_edges()


static func read_int(path: String, fallback := -1) -> int:
	var t := read_line(path)
	return t.to_int() if t.is_valid_int() else fallback


static func _dirs(path: String) -> Array:
	var d := DirAccess.open(path)
	if d == null:
		return []
	var names := Array(d.get_directories()) + Array(d.get_files())
	names.sort()
	return names


static func _first_existing(paths: Array) -> String:
	for p in paths:
		if FileAccess.file_exists(p):
			return p
	return ""


## Finds every source on this machine. Returns a Dictionary of file paths
## ("" = not available) plus "gpu_vendor" ("amd" | "intel" | "") and
## "gpu_driver" ("amdgpu" | "xe" | "i915" | "").
static func discover(root := "") -> Dictionary:
	var s := {
		"proc_stat": "", "rapl_pkg": "", "rapl_pkg_max": 0, "rapl_gpu": "", "rapl_gpu_max": 0,
		"gpu_vendor": "", "gpu_driver": "", "gpu_busy": "", "gpu_power": "", "gpu_power_is_package": false,
		"gpu_energy": "", "gpu_mhz": "", "gpu_mhz_scale": 1.0, "gpu_temp": "", "cpu_temp": "",
		"battery": "",
	}
	if read_line(root + "/proc/stat").begins_with("cpu "):
		s["proc_stat"] = root + "/proc/stat"
	_find_rapl(root, s)
	_find_gpu(root, s)
	_find_cpu_temp(root, s)
	for n in _dirs(root + POWER_SUPPLY):
		var b: String = root + POWER_SUPPLY + n + "/"
		if read_line(b + "type") == "Battery":
			s["battery"] = b
			break
	return s


static func _find_rapl(root: String, s: Dictionary) -> void:
	var base := root + POWERCAP
	for n in _dirs(base):
		# top-level zones only: intel-rapl:0, not intel-rapl:0:1 (nor mmio twins)
		if not n.begins_with("intel-rapl:") or n.count(":") != 1:
			continue
		var z: String = base + n + "/"
		if read_line(z + "name") != "package-0":
			continue
		# energy_uj is often root-only (CVE-2020-8694): only take it if it reads
		if read_line(z + "energy_uj").is_valid_int():
			s["rapl_pkg"] = z + "energy_uj"
			s["rapl_pkg_max"] = read_int(z + "max_energy_range_uj", 0)
		for sub in _dirs(z):
			if not sub.begins_with(n + ":"):
				continue
			var sz: String = z + sub + "/"
			if read_line(sz + "name") == "uncore" and read_line(sz + "energy_uj").is_valid_int():
				s["rapl_gpu"] = sz + "energy_uj"
				s["rapl_gpu_max"] = read_int(sz + "max_energy_range_uj", 0)
		return


static func _find_gpu(root: String, s: Dictionary) -> void:
	var base := root + DRM
	var picked := ""
	for n in _dirs(base):
		# card0, card1 ... (skip connectors like card0-eDP-1 and render nodes)
		if not n.begins_with("card") or not n.substr(4).is_valid_int():
			continue
		var vendor := read_line(base + n + "/device/vendor")
		if vendor != "0x1002" and vendor != "0x8086":
			continue
		if picked == "" or read_line(base + n + "/device/boot_vga") == "1":
			picked = n
	if picked == "":
		return
	var card := base + picked + "/"
	var dev := card + "device/"
	var hw := ""
	for h in _dirs(dev + "hwmon"):
		hw = dev + "hwmon/" + h + "/"
		break
	if read_line(dev + "vendor") == "0x1002":
		s["gpu_vendor"] = "amd"
		s["gpu_driver"] = "amdgpu"
		if FileAccess.file_exists(dev + "gpu_busy_percent"):
			s["gpu_busy"] = dev + "gpu_busy_percent"
		if hw != "":
			s["gpu_power"] = _first_existing([hw + "power1_average", hw + "power1_input"])
			s["gpu_temp"] = _first_existing([hw + "temp1_input"])
			s["gpu_mhz"] = _first_existing([hw + "freq1_input"])
			s["gpu_mhz_scale"] = 1.0 / 1_000_000.0  # Hz
		var vram := read_int(dev + "mem_info_vram_total", -1)
		s["gpu_power_is_package"] = s["gpu_power"] != "" and vram >= 0 and vram <= APU_VRAM_MAX
		return
	s["gpu_vendor"] = "intel"
	var xe_freq := dev + "tile0/gt0/freq0/act_freq"
	if FileAccess.file_exists(xe_freq):
		s["gpu_driver"] = "xe"
		s["gpu_mhz"] = xe_freq
	elif FileAccess.file_exists(card + "gt_act_freq_mhz"):
		s["gpu_driver"] = "i915"
		s["gpu_mhz"] = card + "gt_act_freq_mhz"
	if hw != "":  # discrete Arc only; integrated Intel registers no GPU hwmon
		s["gpu_energy"] = _first_existing([hw + "energy1_input"])
		s["gpu_temp"] = _first_existing([hw + "temp1_input"])


static func _find_cpu_temp(root: String, s: Dictionary) -> void:
	var base := root + HWMON
	for want in CPU_HWMONS:
		for n in _dirs(base):
			if read_line(base + n + "/name") == want and FileAccess.file_exists(base + n + "/temp1_input"):
				s["cpu_temp"] = base + n + "/temp1_input"
				return
	for n in _dirs(root + THERMAL):
		var z: String = root + THERMAL + n + "/"
		if n.begins_with("thermal_zone") and read_line(z + "type") == "x86_pkg_temp":
			s["cpu_temp"] = z + "temp"
			return


## Battery draw in watts while discharging, else -1. current_now may be negative while
## discharging (the Claw 8 EX's EC) and comes 100x too large on the Claw 8 EX (-64.6 A at about
## 10 W): scale_fix() as ClawDeck's telemetry.battery_watts does.
static func battery_watts(bat: String) -> float:
	if bat == "" or read_line(bat + "status") != "Discharging":
		return -1.0
	var ps := read_line(bat + "power_now")
	if ps.is_valid_int():
		return scale_fix(absf(ps.to_int() / 1_000_000.0))
	var cs := read_line(bat + "current_now")
	var vs := read_line(bat + "voltage_now")
	if cs.is_valid_int() and vs.is_valid_int():
		return scale_fix(absf(cs.to_int() * vs.to_int() / 1e12))
	return -1.0


## No handheld battery delivers 200 W: a reading above that is the Claw 8 EX EC's current_now in
## units 100x too large (ClawDeck py_modules/clawdeck/telemetry.py battery_watts, HARDWARE-FINDINGS §6).
static func scale_fix(w: float) -> float:
	return w / 100.0 if absf(w) > 200.0 else w


## Which source each metric uses, for the UI's "where does this number come
## from" line and for tests.
static func describe(s: Dictionary) -> Dictionary:
	var pkg := "rapl" if s["rapl_pkg"] != "" else ("amdgpu" if s["gpu_power_is_package"] else "")
	var gpu_w := ""
	if s["rapl_gpu"] != "":
		gpu_w = "rapl-uncore"
	elif s["gpu_power"] != "" and not s["gpu_power_is_package"]:
		gpu_w = "amdgpu"
	elif s["gpu_energy"] != "":
		gpu_w = s["gpu_driver"] + "-hwmon"
	return {
		"cpu_load": "procfs" if s["proc_stat"] != "" else "",
		"package_w": pkg,
		"gpu_w": gpu_w,
		"gpu_load": "amdgpu" if s["gpu_busy"] != "" else "",
		"gpu_mhz": s["gpu_driver"] if s["gpu_mhz"] != "" else "",
		"cpu_temp": "hwmon" if s["cpu_temp"].contains("/hwmon/") else ("thermal" if s["cpu_temp"] != "" else ""),
		"gpu_temp": "hwmon" if s["gpu_temp"] != "" else "",
		"battery_w": "power_supply" if s["battery"] != "" else "",
	}
