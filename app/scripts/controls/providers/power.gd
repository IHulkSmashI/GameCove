extends RefCounted
## Power controls (group "power"): every power setting a handheld player changes, on whatever
## this exact handheld's backends allow. TDP, profile, charge limit, fan preset and Auto TDP go
## through the Power service (scripts/device/power.gd: Handheld Daemon, steamos-manager,
## PowerStation, the charge-limit and fan fixes), serialised on Power's worker with run_sync().
## Everything below the TDP goes through controls/power/backend.gd (steamos-manager and
## PowerStation first, both prompt-free; the power-tune root verbs where neither offers it).
##
## Device handling copied from tested Decky plugins and daemons (cited where used, in
## backend.gd, fixes/power-tune/fix.sh and power.gd): SimpleDeckyTDP (aarron-lee), PowerTools
## (NGnius), PowerStation, steamos-manager, Handheld Daemon's adjustor, ClawDeck.
##
## Ranges are the device's: the TDP from devices.json via Power (per power source), boost
## limits from devices.json boost_max and the firmware's own min/max, clocks from the hardware.
## Values written are re-applied after a resume (firmwares reset EPP, boost and limits on
## sleep; PowerTools resume_worker.rs does the same) and device-level ones (sleep mode, battery
## care, fan curve, MCU power saving, battery saver settings) are kept per handheld
## (per_device.gd sections in user://power_controls.cfg) and put back at start.

const Ctl := preload("res://scripts/controls/control.gd")
const Backend := preload("res://scripts/controls/power/backend.gd")
const Tx := preload("res://scripts/controls/power/texts.gd")
const PerDevice := preload("res://scripts/device/per_device.gd")
const PowerScript := preload("res://scripts/device/power.gd")

const CFG := "user://power_controls.cfg"
## Device-level settings remembered per handheld and put back at start.
const DEVICE_IDS := ["power.sleep_mode", "power.mcu_powersave", "power.battery_long_life", "power.fan_curve",
	"power.battery_saver_at", "power.thermal_limit"]
## Levers Auto TDP moves: a manual change pauses it for the game (ClawDeck main.py).
const LEVER_IDS := ["power.cpu_boost", "power.cpu_max", "power.epp", "power.gpu_min", "power.gpu_max",
	"power.gpu_profile", "power.gpu_level", "power.gpu_clock"]
## The MSI Claw 8 EX firmware accepts ppt_* attributes and ignores them (ClawDeck
## docs/HARDWARE-FINDINGS.md §12, measured 2026-10-21); RAPL through PowerStation is the real limit.
const FW_PPT_IGNORED := ["msi-claw-8-ex"]
const TARGETS := [0, 30, 40, 45, 50, 60, 72, 90, 120]

var ctx: Dictionary = {}
var be: RefCounted
var power: Object
var registry: Object
var cfg_path := CFG
var _last := {}           # id -> last value written (re-applied after resume)
var _saver_prev := {}
var _saver_auto := false
var _thermal_top := -1.0
var _by_id := {}


func setup(c: Dictionary) -> void:
	ctx = c
	be = Backend.new(str(c.get("sys_root", "")), c.get("runner"))
	if c.has("fix_set"):
		be.fix_set = str(c["fix_set"])
	power = c.get("power")
	registry = c.get("registry")
	var tree := Engine.get_main_loop() as SceneTree
	if power == null and tree != null and tree.root != null:
		power = tree.root.get_node_or_null("Power")
	if registry == null and tree != null and tree.root != null:
		registry = tree.root.get_node_or_null("Controls")
	if power != null:
		if power.has_signal("source_changed"):
			power.source_changed.connect(_on_source)
		if power.has_signal("battery_level"):
			power.battery_level.connect(_on_battery)
		if power.has_signal("resumed"):
			power.resumed.connect(_on_resumed)
	if registry != null and registry.has_signal("detected"):
		registry.detected.connect(_on_detected, CONNECT_ONE_SHOT)


func row() -> Dictionary:
	var d: Variant = ctx.get("device")
	if d is Dictionary:
		return d
	if d is Object and "profile" in d:
		return d.profile
	if power != null and "device" in power and power.device is Dictionary:
		return power.device
	return {}


func device_key() -> String:
	return PerDevice.key(str(row().get("id", "unknown")))


## Runs on Power's worker when there is one (Power's state isn't thread-safe), else inline.
func _p(job: Callable) -> Variant:
	if power != null and power.has_method("run_sync"):
		return power.run_sync(job)
	return job.call()


func _pstate() -> Dictionary:
	if power == null or not power.has_method("state"):
		return {}
	return _p(func(): return power.state())


func _make(id: String, kind: String, spec: Dictionary, detect: Callable, read: Callable, write: Callable) -> RefCounted:
	var base := {"id": id, "title": Tx.title(id), "help": Tx.help(id), "group": "power", "kind": kind}
	base.merge(spec, true)
	var c: RefCounted = Ctl.make(base, func(ctl): be.reset(); return detect.call(ctl), read,
		func(ctl, v):
			var ok := bool(write.call(ctl, v))
			if ok:
				_wrote(id, v)
			return ok)
	_by_id[id] = weakref(c)  # controls hold callables bound to us: no strong ref back (no cycle)
	return c


func _ctl(id: String) -> RefCounted:
	var w: WeakRef = _by_id.get(id)
	return w.get_ref() if w != null else null


func _wrote(id: String, v: Variant) -> void:
	_last[id] = v
	if id in DEVICE_IDS:
		var cfg := ConfigFile.new()
		cfg.load(cfg_path)
		cfg.set_value(PerDevice.section("set", device_key()), id, v)
		cfg.save(cfg_path)
	if id in LEVER_IDS and power != null and power.has_method("autotune_active") and power.autotune_active():
		power.request_autotune_pause("manual " + id)


func saved_device_values() -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load(cfg_path) != OK:
		return {}
	var sec := PerDevice.section("set", device_key())
	var out := {}
	if cfg.has_section(sec):
		for k in cfg.get_section_keys(sec):
			out[k] = cfg.get_value(sec, k)
	return out


# ---- events --------------------------------------------------------------------------------------

func _on_detected() -> void:
	var saved := saved_device_values()
	if saved.is_empty() or registry == null:
		return
	registry.apply(saved)


func _on_resumed() -> void:
	if registry == null:
		return
	var v := saved_device_values()
	v.merge(_last, true)
	registry.apply(v)


## The TDP's range follows the power source: detect again.
func _on_source(plugged: bool) -> void:
	if registry != null:
		registry.detect_all()
	if plugged and _saver_auto and registry != null:
		registry.set_value("power.battery_saver", false)


func _on_battery(pct: int, plugged: bool) -> void:
	var at := int(saved_device_values().get("power.battery_saver_at", 0))
	var c: RefCounted = _ctl("power.battery_saver")
	if at <= 0 or plugged or c == null or not c.available or registry == null:
		return
	if pct <= at and c.value != true:
		_saver_auto = true
		registry.set_value("power.battery_saver", true)


# ---- the controls --------------------------------------------------------------------------------

func controls() -> Array:
	return [
		_tdp(), _profile(), _boost(), _boost_on(), _ppt("sppt"), _ppt("fppt"),
		_power_mode(), _platform(), _cpu_boost(), _smt(), _cores(), _epp(), _governor(), _cpu_max(),
		_gpu_level(), _gpu_clock(), _gpu_min_max("min"), _gpu_min_max("max"), _gpu_profile(), _thermal_limit(),
		_charge_limit(), _battery_long_life(), _fan_mode(), _fan_curve(), _battery_saver(), _battery_saver_at(),
		_sleep_mode(), _mcu(),
		_autotune_target(), _autotune_auto_fps(), _autotune_keep(), _autotune_floor(), _autotune_plugged(),
	]


func _tdp() -> RefCounted:
	return _make("power.tdp", "slider", {"unit": "W", "step": 1.0, "apply_order": 100, "per_game": true},
		func(c):
			var st := _pstate()
			if st.is_empty() or not st.get("supported", {}).get("tdp", false):
				return Tx.NO_TDP
			c.min_value = float(st["tdp_min"])
			c.max_value = float(st["tdp_max"])
			return "",
		func(_c): return float(_pstate().get("tdp_w", -1.0)),
		func(_c, v): return bool(_p(func(): return power.set_tdp(float(v)))))


func _profile() -> RefCounted:
	var opts := []
	for p in PowerScript.PROFILES:
		opts.append({"value": p, "label": p.capitalize()})
	return _make("power.profile", "choice", {"options": opts, "apply_order": 101, "per_game": false},
		func(_c):
			var st := _pstate()
			return "" if st.get("supported", {}).get("profiles", false) else Tx.NO_TDP,
		func(_c): return str(_pstate().get("profile", "")),
		func(_c, v): return bool(_p(func(): return power.set_profile(str(v)))))


func _boost_cap(c: RefCounted) -> float:
	var st := _pstate()
	var t: Dictionary = row().get("tdp", {})
	var cap := float(t.get("boost_max", -1.0)) - float(st.get("tdp_max", 0.0))
	var ps: Dictionary = be.ps_boost()
	var mx := float(ps.get("max", -1.0))
	if mx > 0.0:
		cap = mx if cap <= 0.0 else minf(cap, mx)
	if cap <= 0.0:
		cap = float(row().get("pl2_offset_w", 0.0))
	c.max_value = maxf(cap, 0.0)
	return cap


func _boost() -> RefCounted:
	return _make("power.boost", "slider", {"unit": "W", "step": 1.0, "min_value": 0.0, "apply_order": 99},
		func(c):
			if power == null or str(power.get("backend")) != "powerstation":
				return Tx.NOT_HERE
			if be.ps_boost().is_empty():
				return Tx.NOT_HERE
			return "" if _boost_cap(c) > 0.0 else Tx.NOT_HERE,
		func(_c): return float(be.ps_boost().get("value", -1.0)),
		func(_c, v): return bool(_p(func(): return power.set_boost_w(float(v)))))


func _boost_on() -> RefCounted:
	return _make("power.boost_on", "toggle", {"apply_order": 99},
		func(_c):
			if power == null or str(power.get("backend")) != "hhd":
				return Tx.NOT_HERE
			return "" if _p(func(): return power.hhd_boost()) != null else Tx.NOT_HERE,
		func(_c): return _p(func(): return power.hhd_boost()),
		func(_c, v): return bool(_p(func(): return power.set_hhd_boost(bool(v)))))


func _ppt(which: String) -> RefCounted:
	return _make("power." + which, "slider", {"unit": "W", "step": 1.0, "apply_order": 98 if which == "sppt" else 97},
		func(c):
			var backend := str(power.get("backend")) if power != null else "none"
			if backend == "hhd":
				return Tx.HHD_OWNS
			if str(row().get("id", "")) in FW_PPT_IGNORED:
				return Tx.FW_IGNORED
			if backend == "powerstation":
				return Tx.NOT_HERE  # PowerStation keeps SPPT/FPPT itself (its Boost): power.boost
			var a: Dictionary = be.ppt_info(which)
			if a.is_empty():
				return Tx.NOT_HERE if be.helper_present() else Tx.NO_HELPER
			var lo := float(a["min"])
			var spl: Dictionary = be.fw_attr("ppt_pl1_spl")
			if not spl.is_empty():
				lo = maxf(lo, float(spl["value"]))
			if which == "fppt":
				var sp: Dictionary = be.ppt_info("sppt")
				if not sp.is_empty():
					lo = maxf(lo, float(sp["value"]))
			var hi := float(a["max"])
			var cap := float(row().get("tdp", {}).get("boost_max", -1.0))
			if cap > 0.0:
				hi = minf(hi, cap)
			if hi <= 0.0 or hi < lo:
				return Tx.NOT_HERE
			c.min_value = lo
			c.max_value = hi
			return "",
		func(_c): return float(be.ppt_info(which).get("value", -1)),
		func(_c, v): return be.set_ppt(which, int(v)))


func _choice_opts(words: Array) -> Array:
	var out := []
	for w in words:
		out.append({"value": str(w), "label": str(w).replace("_", " ").replace("-", " ").capitalize()})
	return out


func _power_mode() -> RefCounted:
	return _make("power.power_mode", "choice", {"apply_order": 90},
		func(c):
			var p: Dictionary = be.ppd()
			if p.is_empty():
				return Tx.NO_PPD
			c.options = _choice_opts(p["offered"])
			return "",
		func(_c): return str(be.ppd().get("active", "")),
		func(_c, v): return be.set_ppd(str(v)))


func _platform() -> RefCounted:
	return _make("power.platform_profile", "choice", {"apply_order": 89},
		func(c):
			var info: Dictionary = be.platform_info()
			if info.is_empty():
				return Tx.NOT_HERE
			if info["via"] == "sysfs" and not be.ppd().is_empty():
				return Tx.PPD_OWNS
			c.options = _choice_opts(info["offered"])
			return "",
		func(_c): return str(be.platform_info().get("active", "")),
		func(_c, v): return be.set_platform(str(v)))


func _cpu_boost() -> RefCounted:
	return _make("power.cpu_boost", "toggle", {"apply_order": 80},
		func(_c): return "" if be.boost_via() != "" else (Tx.NOT_HERE if be.boost_file().is_empty() else Tx.NO_HELPER),
		func(_c): return be.get_boost(),
		func(_c, v): return be.set_boost(bool(v)))


func _smt() -> RefCounted:
	return _make("power.smt", "toggle", {"apply_order": 82},
		func(_c):
			if not be.smt_control() in ["on", "off"]:
				return Tx.NO_SMT
			return "" if be.smt_via() != "" else Tx.NO_HELPER,
		func(_c): return be.get_smt(),
		func(_c, v): return be.set_smt(bool(v)))


func _cores() -> RefCounted:
	return _make("power.cpu_cores", "slider", {"step": 1.0, "apply_order": 81},
		func(c):
			if be.cores_via() == "":
				return Tx.NOT_HERE if not be.can_offline() else Tx.NO_HELPER
			var n: int = be.cpu_numbers().size()
			c.min_value = 2.0
			c.max_value = float(n)
			return "",
		func(_c): return float(be.get_cores()),
		func(_c, v): return be.set_cores(int(v)))


func _epp() -> RefCounted:
	return _make("power.epp", "choice", {"apply_order": 70},
		func(c):
			if be.epp_files().is_empty() or be.epp_choices().is_empty():
				return Tx.NOT_HERE
			if not be.helper_present():
				return Tx.NO_HELPER
			c.options = _choice_opts(be.epp_choices())
			return "",
		func(_c): return be.epp_now(),
		func(_c, v): return be.set_epp(str(v)))


func _governor() -> RefCounted:
	return _make("power.governor", "choice", {"apply_order": 75},
		func(c):
			if be.governor_via() == "":
				return Tx.NOT_HERE if be.governor_dir() == "" else Tx.NO_HELPER
			c.options = _choice_opts(be.governor_options())
			return "" if not c.options.is_empty() else Tx.NOT_HERE,
		func(_c): return be.get_governor(),
		func(_c, v): return be.set_governor(str(v)))


func _cpu_max() -> RefCounted:
	return _make("power.cpu_max", "slider", {"unit": "%", "step": 5.0, "max_value": 100.0, "apply_order": 72},
		func(c):
			var m: Dictionary = be.cpu_max()
			if m.is_empty():
				return Tx.NOT_HERE
			if not be.helper_present():
				return Tx.NO_HELPER
			c.min_value = float(m["min"])
			return "",
		func(_c): return float(be.cpu_max().get("pct", -1)),
		func(_c, v): return be.set_cpu_max(int(v)))


func _gpu_level() -> RefCounted:
	return _make("power.gpu_level", "choice", {"apply_order": 66},
		func(c):
			var info: Dictionary = be.gpu_level_info()
			if info.is_empty():
				return Tx.AMD_ONLY if be.gpu().get("driver", "") != "amdgpu" else Tx.NO_HELPER
			c.options = _choice_opts(info["offered"])
			return "",
		func(_c): return str(be.gpu_level_info().get("active", "")),
		func(_c, v): return be.set_gpu_level(str(v)))


func _gpu_clock() -> RefCounted:
	return _make("power.gpu_clock", "slider", {"unit": "MHz", "step": 50.0, "apply_order": 65, "requires": ["power.gpu_level"]},
		func(c):
			var m: Dictionary = be.sm_manual_clock()
			if m.is_empty():
				return Tx.NOT_HERE
			c.min_value = float(m["lo"])
			c.max_value = float(m["hi"])
			return "",
		func(_c): return float(be.sm_manual_clock().get("value", -1)),
		func(_c, v): return be.set_sm_manual_clock(int(v)))


func _gpu_min_max(which: String) -> RefCounted:
	return _make("power.gpu_" + which, "slider", {"unit": "MHz", "step": 50.0, "apply_order": 64 if which == "max" else 63},
		func(c):
			var g: Dictionary = be.gpu_clocks()
			if g.is_empty():
				return Tx.NO_GPU_CLOCKS if be.helper_present() or be.ps_clock_card() != "" else Tx.NO_HELPER
			c.min_value = float(g["lo"])
			c.max_value = float(g["hi"])
			return "",
		func(_c): return float(be.gpu_clocks().get(which, -1)),
		func(_c, v): return be.set_gpu_clocks(int(v), -1) if which == "min" else be.set_gpu_clocks(-1, int(v)))


func _gpu_profile() -> RefCounted:
	return _make("power.gpu_profile", "choice", {"apply_order": 62},
		func(c):
			var info: Dictionary = be.gpu_profile_info()
			if info.is_empty():
				return Tx.XE_ONLY
			c.options = _choice_opts(info["offered"])
			return "",
		func(_c): return str(be.gpu_profile_info().get("active", "")),
		func(_c, v): return be.set_gpu_profile(str(v)))


## Never above the limit the firmware had when GameCove first saw it (kept per handheld).
func _thermal_limit() -> RefCounted:
	return _make("power.thermal_limit", "slider", {"unit": "°C", "step": 1.0, "min_value": 60.0, "apply_order": 60},
		func(c):
			var now: float = be.thermal_limit()
			if now <= 0.0:
				return Tx.NO_THERMAL
			if _thermal_top < 0.0:
				var cfg := ConfigFile.new()
				cfg.load(cfg_path)
				var sec := PerDevice.section("firmware", device_key())
				_thermal_top = float(cfg.get_value(sec, "thermal_limit", now))
				if not cfg.has_section_key(sec, "thermal_limit"):
					cfg.set_value(sec, "thermal_limit", now)
					cfg.save(cfg_path)
			c.max_value = minf(_thermal_top, 100.0)
			return "" if c.max_value > c.min_value else Tx.NO_THERMAL,
		func(_c): return be.thermal_limit(),
		func(_c, v): return be.set_thermal_limit(float(v)))


func _charge_limit() -> RefCounted:
	return _make("power.charge_limit", "slider", {"unit": "%", "step": 5.0, "min_value": 50.0, "max_value": 100.0, "per_game": false},
		func(_c):
			var st := _pstate()
			if st.is_empty():
				return Tx.NO_CHARGE
			if str(st.get("backend", "")) == "hhd":
				return Tx.HHD_OWNS
			return "" if st.get("supported", {}).get("charge_limit", false) else Tx.NO_CHARGE,
		func(_c): return float(_pstate().get("charge_limit", -1)),
		func(_c, v): return bool(_p(func(): return power.set_charge_limit(int(v)))))


func _battery_long_life() -> RefCounted:
	return _make("power.battery_long_life", "toggle", {"per_game": false},
		func(_c):
			var c2: Dictionary = be.charge_types()
			if c2.is_empty() or not "Long_Life" in c2["offered"]:
				return Tx.NO_CHARGE
			return "" if be.helper_present() else Tx.NO_HELPER,
		func(_c): return str(be.charge_types().get("active", "")) == "Long_Life",
		func(_c, v): return be.set_battery_mode(bool(v)))


func _fan_mode() -> RefCounted:
	return _make("power.fan_mode", "choice", {"apply_order": 50},
		func(c):
			var st := _pstate()
			if str(st.get("backend", "")) == "hhd":
				return Tx.HHD_OWNS
			if not st.get("supported", {}).get("fan", false):
				return Tx.NO_FAN
			c.options = _choice_opts(st.get("fan_modes", []))
			return "",
		func(_c): return str(_pstate().get("fan_mode", "")),
		func(_c, v): return bool(_p(func(): return power.set_fan_mode(str(v)))))


## {"driver", "points", "quiet": [...], "hwmon"} for table fan drivers driven by the fan fix, {}.
func _fan_table() -> Dictionary:
	if power == null or str(power.get("_fan_via")) != "fix":
		return {}
	var drv := str(power.get("_fan_driver"))
	var info: Dictionary = PowerScript.FAN_DRIVERS.get(drv, {})
	if info.get("kind", "") != "table":
		return {}
	return {"driver": drv, "points": int(info["points"]), "quiet": info["tables"]["quiet"], "hwmon": str(power.get("_fan_hwmon"))}


## The curve as fix.sh will take it: never under Quiet at any point, never falling.
static func safe_curve(v: Array, quiet: Array) -> Array:
	var out := []
	var prev := 0
	for i in quiet.size():
		var d := clampi(int(roundf(float(v[i]))), 0, 100)
		d = maxi(d, maxi(int(quiet[i]), prev))
		out.append(d)
		prev = d
	return out


func _fan_curve() -> RefCounted:
	return _make("power.fan_curve", "curve", {"unit": "%", "min_value": 0.0, "max_value": 100.0, "step": 1.0, "apply_order": 49, "per_game": false},
		func(c):
			var st := _pstate()
			if str(st.get("backend", "")) == "hhd":
				return Tx.HHD_OWNS
			var t := _fan_table()
			if t.is_empty():
				return Tx.NO_CURVE if st.get("supported", {}).get("fan", false) else Tx.NO_FAN
			c.points = t["points"]
			c.default_value = (t["quiet"] as Array).map(func(x): return float(x))
			return "",
		func(_c):
			var t := _fan_table()
			var out := []
			for i in range(int(t.get("points", 0))):
				var raw := Backend.read_int(str(t["hwmon"]) + "pwm1_auto_point%d_pwm" % (i + 1))
				if raw < 0:
					return null
				out.append(float(roundi(raw * 100.0 / 255.0)))
			return out,
		func(_c, v):
			var t := _fan_table()
			if t.is_empty():
				return false
			var curve := safe_curve(v, t["quiet"])
			return bool(_p(func():
				if not power._run_fix("fan", "curve:" + ",".join(curve.map(func(x): return str(x)))):
					return false
				power.refresh()
				return true)))


## The lowest settings this handheld allows; the values before are put back when it goes off.
func saver_values() -> Dictionary:
	var out := {"power.profile": "battery"}
	var pm: RefCounted = _ctl("power.power_mode")
	if pm != null and pm.available and pm.options.any(func(o): return o["value"] == "power-saver"):
		out["power.power_mode"] = "power-saver"
	var epp: RefCounted = _ctl("power.epp")
	if epp != null and epp.available:
		for w in ["power", "balance_power"]:
			if epp.options.any(func(o): return o["value"] == w):
				out["power.epp"] = w
				break
	out["power.cpu_boost"] = false
	var gp: RefCounted = _ctl("power.gpu_profile")
	if gp != null and gp.available and gp.options.any(func(o): return o["value"] == "power_saving"):
		out["power.gpu_profile"] = "power_saving"
	return out


func _battery_saver() -> RefCounted:
	return _make("power.battery_saver", "toggle", {"per_game": false, "default_value": false},
		func(_c):
			var tdp: RefCounted = _ctl("power.tdp")
			if tdp != null and not tdp.available and be.boost_via() == "" and be.ppd().is_empty():
				return Tx.NOT_HERE
			return "",
		func(c): return c.value if c.value != null else false,
		func(c, v):
			if registry == null:
				return false
			if bool(v) == bool(c.value):
				return true
			if bool(v):
				var want := saver_values()
				_saver_prev = {}
				for id in want:
					var other: RefCounted = _ctl(id)
					if other != null and other.available and other.value != null:
						_saver_prev[id] = other.value
				if _saver_prev.has("power.profile") and str(_saver_prev["power.profile"]) == "custom":
					_saver_prev.erase("power.profile")
					var tdp: RefCounted = _ctl("power.tdp")
					if tdp != null and tdp.value != null:
						_saver_prev["power.tdp"] = tdp.value
				registry.apply(want)
			else:
				_saver_auto = false
				registry.apply(_saver_prev)
				_saver_prev = {}
			return true)


func _battery_saver_at() -> RefCounted:
	return _make("power.battery_saver_at", "slider", {"unit": "%", "min_value": 0.0, "max_value": 50.0, "step": 5.0, "per_game": false, "default_value": 0.0},
		func(_c): return "" if Backend.read_int(_battery_capacity_file()) >= 0 else Tx.NO_BATTERY,
		func(_c): return float(saved_device_values().get("power.battery_saver_at", 0.0)),
		func(_c, _v): return true)


func _battery_capacity_file() -> String:
	for n in be.dirs("/sys/class/power_supply"):
		var d: String = be.path("/sys/class/power_supply/" + n)
		if Backend.read(d + "/type") == "Battery":
			return d + "/capacity"
	return ""


func _sleep_mode() -> RefCounted:
	return _make("power.sleep_mode", "choice", {"per_game": false},
		func(c):
			var m: Dictionary = be.mem_sleep()
			if m.is_empty():
				return Tx.NOT_HERE
			var offered: Array = m["offered"].filter(func(w): return w in ["s2idle", "deep"])
			if offered.size() < 2:
				return Tx.ONE_SLEEP
			if not be.helper_present():
				return Tx.NO_HELPER
			c.options = _choice_opts(offered)
			return "",
		func(_c): return str(be.mem_sleep().get("active", "")),
		func(_c, v): return be.set_mem_sleep(str(v)))


func _mcu() -> RefCounted:
	return _make("power.mcu_powersave", "toggle", {"per_game": false},
		func(_c):
			if be.mcu_file() == "":
				return Tx.NOT_HERE
			return "" if be.helper_present() else Tx.NO_HELPER,
		func(_c): return Backend.read(be.mcu_file()) == "1",
		func(_c, v): return be.set_mcu(bool(v)))


# ---- Auto TDP options (Power applies them to the running game at once) ----------------------------

func _autotune_detect() -> String:
	var st := _pstate()
	return "" if st.get("supported", {}).get("tdp", false) else Tx.NO_TDP


func _opt(key: String) -> Variant:
	return _p(func(): return power.autotune_opts.get(key)) if power != null else null


func _set_opt(key: String, v: Variant) -> bool:
	return bool(_p(func(): return power.set_autotune_option(key, v)))


func _autotune_target() -> RefCounted:
	var opts := []
	for t in TARGETS:
		opts.append({"value": t, "label": "Most frames" if t == 0 else "%d fps" % t})
	return _make("power.autotune_target", "choice", {"options": opts, "default_value": 0, "apply_order": 40},
		func(_c): return _autotune_detect(),
		func(_c):
			var v: Variant = _opt("target")
			return int(v) if v != null else 0,
		func(_c, v): return _set_opt("target", int(v)))


func _autotune_auto_fps() -> RefCounted:
	return _make("power.autotune_auto_fps", "toggle", {"default_value": true, "apply_order": 41, "requires": ["power.autotune_target"]},
		func(_c): return _autotune_detect(),
		func(_c): return bool(_opt("auto_fps")) if _opt("auto_fps") != null else true,
		func(_c, v): return _set_opt("auto_fps", bool(v)))


func _autotune_keep() -> RefCounted:
	return _make("power.autotune_keep", "slider", {"unit": "%", "min_value": 2.0, "max_value": 15.0, "step": 1.0, "default_value": 5.0, "apply_order": 41},
		func(_c): return _autotune_detect(),
		func(_c): return float(_opt("keep_pct")) if _opt("keep_pct") != null else 5.0,
		func(_c, v): return _set_opt("keep_pct", float(v)))


func _autotune_floor() -> RefCounted:
	return _make("power.autotune_floor", "slider", {"unit": "W", "step": 1.0, "apply_order": 41},
		func(c):
			var r := _autotune_detect()
			if r != "":
				return r
			var st := _pstate()
			c.min_value = float(st["tdp_min"])
			c.max_value = float(st["tdp_max"])
			c.default_value = c.min_value
			return "",
		func(c):
			var f := int(_opt("floor_w")) if _opt("floor_w") != null else 0
			return c.min_value if f <= 0 else float(f),
		func(c, v): return _set_opt("floor_w", 0 if float(v) <= c.min_value else int(v)))


func _autotune_plugged() -> RefCounted:
	return _make("power.autotune_plugged", "toggle", {"default_value": false, "per_game": false},
		func(_c): return _autotune_detect(),
		func(_c): return bool(_opt("plugged")) if _opt("plugged") != null else false,
		func(_c, v): return _set_opt("plugged", bool(v)))
