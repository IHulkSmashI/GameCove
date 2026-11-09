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
const SettingsFile := preload("res://scripts/system/settings_file.gd")
const PowerScript := preload("res://scripts/device/power.gd")

const CFG := "user://power_controls.cfg"
## Device-level settings remembered per handheld and put back at start.
const DEVICE_IDS := ["power.sleep_mode", "power.mcu_powersave", "power.battery_long_life", "power.fan_curve",
	"power.battery_saver_at", "power.thermal_limit"]
## Levers Auto TDP moves: a manual change pauses it for the game (ClawDeck main.py).
const LEVER_IDS := ["power.cpu_boost", "power.cpu_max", "power.epp", "power.gpu_min", "power.gpu_max",
	"power.gpu_profile", "power.gpu_level", "power.gpu_clock"]
## Firmware that accepts ppt_* attributes and ignores them: quirk "fw-ppt-ignored" in
## app/data/quirks.json (MSI's Panther Lake Claw firmware, ClawDeck docs/HARDWARE-FINDINGS.md §12,
## measured 2026-10-21); RAPL through PowerStation is the real limit. Keyed by traits, so siblings
## with the same firmware get it too.
const Traits := preload("res://scripts/device/traits.gd")
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
var _replaying := {}       # ids the resume replay is writing (main thread sets, worker clears)
var _replay_mutex := Mutex.new()


func setup(c: Dictionary) -> void:
	ctx = c
	be = Backend.new(str(c.get("sys_root", "")), c.get("runner"))
	if c.has("config_path"):   # tests / device matrix: keep our file next to the fixture's settings
		cfg_path = str(c["config_path"]).get_base_dir().path_join("power_controls.cfg")
	if c.has("fix_set"):
		be.fix_set = str(c["fix_set"])
	power = c.get("power")
	registry = c.get("registry")
	# the autoloads only on the real system: a fixture context (tests, device
	# matrix) must never drive the machine running the tests
	var real := str(c.get("sys_root", "")) == ""
	var tree := Engine.get_main_loop() as SceneTree
	if real and power == null and tree != null and tree.root != null:
		power = tree.root.get_node_or_null("Power")
	if real and registry == null and tree != null and tree.root != null:
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


## Controls probe (hwtest/controls_cli.gd): the raw GPU clock state, put back exactly after
## a GPU probe (level, xe min/max_freq, PowerStation ManualClock and clock values).
func probe_snapshot() -> Dictionary:
	be.reset()
	var g: Dictionary = be.gpu_raw_state()
	return {"gpu": g} if not g.is_empty() else {}


func probe_restore(snap: Dictionary) -> bool:
	if not snap.has("gpu"):
		return true
	be.reset()
	return be.gpu_raw_restore(snap["gpu"])


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
	c.set_meta("provider", self)   # control -> provider only (probe_snapshot/probe_restore)
	return c


func _ctl(id: String) -> RefCounted:
	var w: WeakRef = _by_id.get(id)
	return w.get_ref() if w != null else null


func _wrote(id: String, v: Variant) -> void:
	if _limit_alias(id):
		# Battery care done through the charge limit is the charge limit (Power remembers
		# it): saving the toggle too re-applied 80 or 100 over the slider (review M18)
		_forget(id)
		return
	_last[id] = v
	if id in DEVICE_IDS:
		SettingsFile.update_cfg(cfg_path, func(cfg: ConfigFile): cfg.set_value(PerDevice.section("set", device_key()), id, v))
	_replay_mutex.lock()
	var replay := _replaying.has(id)
	_replaying.erase(id)
	_replay_mutex.unlock()
	if not replay and id in LEVER_IDS and power != null and power.has_method("autotune_active") and power.autotune_active():
		power.request_autotune_pause("manual " + id)


## Drops a device-level value from memory and from the file (it no longer applies).
func _forget(id: String) -> void:
	_last.erase(id)
	SettingsFile.update_cfg(cfg_path, func(cfg: ConfigFile):
		var sec := PerDevice.section("set", device_key())
		if not cfg.has_section_key(sec, id):
			return false
		cfg.erase_section_key(sec, id))


func saved_device_values() -> Dictionary:
	var cfg := SettingsFile.load_cfg(cfg_path)
	var sec := PerDevice.section("set", device_key())
	var out := {}
	if cfg.has_section(sec):
		for k in cfg.get_section_keys(sec):
			out[k] = cfg.get_value(sec, k)
	if out.has("power.battery_long_life") and _limit_alias("power.battery_long_life"):
		out.erase("power.battery_long_life")   # saved by an older build (review M18)
	return out


## power.battery_long_life where it is only a preset charge limit (no firmware mode).
func _limit_alias(id: String) -> bool:
	return id == "power.battery_long_life" and _long_life_via() == "limit"


# ---- events --------------------------------------------------------------------------------------

func _on_detected() -> void:
	var saved := saved_device_values()
	if registry == null:
		return
	if not saved.is_empty():
		registry.apply(saved)
	# Battery saver still on from before the restart: its values win over the
	# everyday profile Profiles applies right after this first detection (deferred,
	# so this apply is queued after Profiles' one)
	var bs: RefCounted = _ctl("power.battery_saver")
	if bs != null and bs.value == true:
		_reassert_saver.call_deferred()


func _reassert_saver() -> void:
	var bs: RefCounted = _ctl("power.battery_saver")
	if registry != null and bs != null and bs.value == true:
		registry.apply(saver_values())


## After sleep the firmware may have reset what we set while every control still
## holds our value, so this writes them all again (forced, not "skip if equal").
##
## Not the TDP, the profile or the boost (review M16): Power's own refresh(true) already put
## back the TDP that is in effect now (the battery saver's, or the battery profile after
## waking on battery), and `_last` only knows the last value written through the control,
## which Power or the saver may have changed since. Nor does this replay pause Auto TDP:
## it is ours, not a manual change.
const NO_RESUME_REPLAY := ["power.tdp", "power.profile", "power.boost"]


func _on_resumed() -> void:
	if registry == null:
		return
	var v := saved_device_values()
	v.merge(_last, true)
	for id in NO_RESUME_REPLAY:
		v.erase(id)
	_replay_mutex.lock()
	for id in v:
		_replaying[id] = true
	_replay_mutex.unlock()
	registry.apply(v, true)
	if registry.has_method("run_on_worker"):
		# a replay write that failed (or was skipped) must not hide a later manual change
		registry.run_on_worker(func():
			_replay_mutex.lock()
			_replaying.clear()
			_replay_mutex.unlock())


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
	return _make("power.tdp", "slider", {"affects": ["power.profile", "power.boost", "power.sppt", "power.fppt"], "unit": "W", "step": 1.0, "apply_order": 100, "per_game": true},
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
	return _make("power.profile", "choice", {"affects": ["power.tdp", "power.boost", "power.sppt", "power.fppt"], "options": opts, "apply_order": 101, "per_game": false},
		func(c):
			var st := _pstate()
			if not st.get("supported", {}).get("profiles", false):
				return Tx.NO_TDP
			# "custom" (the watts the user set with the TDP slider) can be picked again
			# once there are some; without it a probe or profile could never go back
			var o: Array = opts.duplicate()
			if str(st.get("profile", "")) == "custom" or (power.has_method("custom_watts") and float(_p(func(): return power.custom_watts())) > 0.0):
				o.append({"value": "custom", "label": "Custom"})
			c.options = o
			return "",
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
	return _make("power.boost", "slider", {"affects": ["power.sppt", "power.fppt"], "unit": "W", "step": 1.0, "min_value": 0.0, "apply_order": 99},
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
	var c: RefCounted = _make("power." + which, "slider", {"affects": ["power.fppt" if which == "sppt" else "power.sppt"], "unit": "W", "step": 1.0, "apply_order": 98 if which == "sppt" else 97, "needs_root": true},
		func(c):
			var backend := str(power.get("backend")) if power != null else "none"
			if backend == "hhd":
				return Tx.HHD_OWNS
			if Traits.has_quirk("fw-ppt-ignored", row()):
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
			var cap := ppt_ceiling(which, float(spl.get("value", -1)) if not spl.is_empty() else -1.0)
			if cap > 0.0:
				hi = minf(hi, cap)
			if hi <= 0.0 or hi <= lo:
				return Tx.NOT_HERE
			c.min_value = lo
			c.max_value = hi
			return "",
		func(_c): return float(be.ppt_info(which).get("value", -1)),
		func(_c, v): return be.set_ppt(which, int(v)))
	# the ceiling follows the sustained limit as it is now (it may have moved since detect)
	c.normalize = func(v):
		var spl: Dictionary = be.fw_attr("ppt_pl1_spl")
		var cap := ppt_ceiling(which, float(spl["value"]) if not spl.is_empty() else -1.0)
		return minf(float(v), cap) if cap > 0.0 else v
	return c


## The most watts SPPT / FPPT may get on this handheld with the sustained limit
## at `spl` W (-1 = unknown), -1 when the row says nothing. devices.json tdp:
## <which>_max (else boost_max) is the ceiling; <which>_ratio caps it at
## floor(SPL x ratio) and <which>_over at SPL + over, Handheld Daemon's own
## formulas (asus: min(max(SPL, 35), SPL*1.4/1.2); lenovo: SPL + 2..3 and
## min(fppt_max, SPL*fppt_max/max); msi: SPL*sppt_max/max). Sources per row.
func ppt_ceiling(which: String, spl: float) -> float:
	var t: Dictionary = row().get("tdp", {}) if row().get("tdp") is Dictionary else {}
	var top := float(t.get(which + "_max", t.get("boost_max", -1.0)))
	if spl > 0.0:
		if t.has(which + "_ratio"):
			var r := floorf(spl * float(t[which + "_ratio"]) + 0.0001)
			top = r if top <= 0.0 else minf(top, r)
		if t.has(which + "_over"):
			var o := spl + float(t[which + "_over"])
			top = o if top <= 0.0 else minf(top, o)
	return top


func _choice_opts(words: Array) -> Array:
	var out := []
	for w in words:
		out.append({"value": str(w), "label": str(w).replace("_", " ").replace("-", " ").capitalize()})
	return out


func _power_mode() -> RefCounted:
	return _make("power.power_mode", "choice", {"affects": ["power.platform_profile", "power.tdp", "power.epp"], "apply_order": 90},
		func(c):
			var p: Dictionary = be.ppd()
			if p.is_empty():
				return Tx.NO_PPD
			c.options = _choice_opts(p["offered"])
			return "",
		func(_c): return str(be.ppd().get("active", "")),
		func(_c, v): return be.set_ppd(str(v)))


func _platform() -> RefCounted:
	return _make("power.platform_profile", "choice", {"affects": ["power.tdp", "power.sppt", "power.fppt", "power.power_mode"], "apply_order": 89},
		func(c):
			var info: Dictionary = be.platform_info()
			if info.is_empty():
				return Tx.NOT_HERE
			# power-profiles-daemon / tuned-ppd set the same firmware profile with their own
			# modes (tuned's acpi plugin), also where steamos-manager offers it (Bazzite runs both):
			# one owner, Power mode
			if not be.ppd().is_empty():
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
	return _make("power.smt", "toggle", {"affects": ["power.cpu_cores"], "apply_order": 82},
		func(_c):
			if not be.smt_control() in ["on", "off"]:
				return Tx.NO_SMT
			if be.smt_via() == "sysfs" and _admin_blocked():
				return Tx.NEEDS_ADMIN
			return "" if be.smt_via() != "" else Tx.NO_HELPER,
		func(_c): return be.get_smt(),
		func(_c, v): return be.set_smt(bool(v)))


func _cores() -> RefCounted:
	return _make("power.cpu_cores", "slider", {"affects": ["power.smt"], "step": 1.0, "apply_order": 81},
		func(c):
			if be.cores_via() == "":
				return Tx.NOT_HERE if not be.can_offline() else Tx.NO_HELPER
			if be.cores_via() == "sysfs" and _admin_blocked():
				return Tx.NEEDS_ADMIN
			var n: int = be.cpu_numbers().size()
			c.min_value = 2.0
			c.max_value = float(n)
			return "",
		func(_c): return float(be.get_cores()),
		func(_c, v): return be.set_cores(int(v)))


func _epp() -> RefCounted:
	return _make("power.epp", "choice", {"apply_order": 70, "needs_root": true},
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
	return _make("power.governor", "choice", {"affects": ["power.epp"], "apply_order": 75},
		func(c):
			if be.governor_via() == "":
				return Tx.NOT_HERE if be.governor_dir() == "" else Tx.NO_HELPER
			c.options = _choice_opts(be.governor_options())
			return "" if not c.options.is_empty() else Tx.NOT_HERE,
		func(_c): return be.get_governor(),
		func(_c, v): return be.set_governor(str(v)))


func _cpu_max() -> RefCounted:
	return _make("power.cpu_max", "slider", {"unit": "%", "step": 5.0, "max_value": 100.0, "apply_order": 72, "needs_root": true},
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
	return _make("power.gpu_level", "choice", {"affects": ["power.gpu_min", "power.gpu_max", "power.gpu_clock"], "apply_order": 66},
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
			# one owner for GPU clocks: min/max wherever they work (min = max is a fixed
			# clock); steamos-manager's manual clock only where nothing else can
			if not be.gpu_clocks().is_empty():
				return Tx.USE_GPU_MIN_MAX
			c.min_value = float(m["lo"])
			c.max_value = float(m["hi"])
			return "",
		func(_c): return float(be.sm_manual_clock().get("value", -1)),
		func(_c, v): return be.set_sm_manual_clock(int(v)))


func _gpu_min_max(which: String) -> RefCounted:
	return _make("power.gpu_" + which, "slider", {"affects": ["power.gpu_" + ("max" if which == "min" else "min"), "power.gpu_level"], "unit": "MHz", "step": 50.0, "apply_order": 64 if which == "max" else 63},
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
				# xe's power_profile is 0644 root and steamos-manager's GpuPowerProfile1 is amdgpu-only
				# (steamos-manager src/gpu.rs), so on Intel only the root helper can write it
				if not be.xe_profile().is_empty():
					return Tx.NO_HELPER
				# steamos-manager answers with an empty list where its config has no GPU
				# power profiles (the ROG Ally on SteamOS 3.10)
				# (or errors where its config names no GPU power profile driver): any answer
				# from steamos-manager means it runs and simply has none to offer
				if be.sm_get("GpuPowerProfile1", "AvailableGpuPowerProfiles") is Array or be.sm_present():
					return Tx.SM_NO_GPU_PROFILES
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
				var sec := PerDevice.section("firmware", device_key())
				SettingsFile.update_cfg(cfg_path, func(cfg: ConfigFile):
					_thermal_top = float(cfg.get_value(sec, "thermal_limit", now))
					if cfg.has_section_key(sec, "thermal_limit"):
						return false
					cfg.set_value(sec, "thermal_limit", now))
			c.max_value = minf(_thermal_top, 100.0)
			return "" if c.max_value > c.min_value else Tx.NO_THERMAL,
		func(_c): return be.thermal_limit(),
		func(_c, v): return be.set_thermal_limit(float(v)))


func _charge_limit() -> RefCounted:
	return _make("power.charge_limit", "slider", {"affects": ["power.battery_long_life"], "unit": "%", "step": 5.0, "min_value": 50.0, "max_value": 100.0, "per_game": false},
		func(_c):
			var st := _pstate()
			if st.is_empty():
				return Tx.NO_CHARGE
			if str(st.get("backend", "")) == "hhd":
				return Tx.HHD_OWNS
			if st.get("needs_helper", {}).get("charge_limit", false):
				return Tx.NO_HELPER
			return "" if st.get("supported", {}).get("charge_limit", false) else Tx.NO_CHARGE,
		func(_c): return float(_pstate().get("charge_limit", -1)),
		func(_c, v): return bool(_p(func(): return power.set_charge_limit(int(v)))))


## Battery care: the firmware's own Long_Life mode (Lenovo charge_types) where there is
## one, else a preset charge limit (LONG_LIFE_PCT) through the same backend as
## power.charge_limit, so the two never disagree (the Claw and the Ally said "no
## charge limit" here while power.charge_limit offered 100).
const LONG_LIFE_PCT := 80


func _long_life_via() -> String:
	var c2: Dictionary = be.charge_types()
	if not c2.is_empty() and "Long_Life" in c2["offered"]:
		return "charge_types"
	var st := _pstate()
	if str(st.get("backend", "")) != "hhd" and st.get("supported", {}).get("charge_limit", false):
		return "limit"
	return ""


func _battery_long_life() -> RefCounted:
	return _make("power.battery_long_life", "toggle", {"affects": ["power.charge_limit"], "per_game": false},
		func(_c):
			match _long_life_via():
				"charge_types":
					return "" if be.helper_present() else Tx.NO_HELPER
				"limit":
					return ""
			if _pstate().get("needs_helper", {}).get("charge_limit", false):
				return Tx.NO_HELPER
			return Tx.NO_CHARGE,
		func(_c):
			if _long_life_via() == "limit":
				var lim := int(_pstate().get("charge_limit", -1))
				return lim > 0 and lim <= LONG_LIFE_PCT
			return str(be.charge_types().get("active", "")) == "Long_Life",
		func(_c, v):
			if _long_life_via() == "limit":
				var want := LONG_LIFE_PCT if bool(v) else 100
				return bool(_p(func(): return power.set_charge_limit(want)))
			return be.set_battery_mode(bool(v)))


func _fan_mode() -> RefCounted:
	return _make("power.fan_mode", "choice", {"apply_order": 50},
		func(c):
			var st := _pstate()
			if str(st.get("backend", "")) == "hhd":
				return Tx.HHD_OWNS
			if st.get("needs_helper", {}).get("fan", false):
				return Tx.NO_HELPER
			if not st.get("supported", {}).get("fan", false):
				return Tx.NO_FAN
			c.options = _choice_opts(st.get("fan_modes", []))
			return "",
		func(_c): return str(_pstate().get("fan_mode", "")),
		func(_c, v):
			if not bool(_p(func(): return power.set_fan_mode(str(v)))):
				return false
			_forget("power.fan_curve")   # a preset replaces the curve, also at the next start (review H5)
			return true)


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


## A curve as the control keeps it: safe_curve() in floats, null when the point count is wrong.
func _normalize_curve(v: Variant) -> Variant:
	var t := _fan_table()
	if t.is_empty() or not v is Array:
		return v
	var quiet: Array = t["quiet"]
	if (v as Array).size() != quiet.size():
		return null
	return safe_curve(v, quiet).map(func(x): return float(x))


func _fan_curve() -> RefCounted:
	return _make("power.fan_curve", "curve", {"unit": "%", "min_value": 0.0, "max_value": 100.0, "step": 1.0, "apply_order": 49, "per_game": false,
			"needs_root": true, "normalize": _normalize_curve},
		func(c):
			var st := _pstate()
			if str(st.get("backend", "")) == "hhd":
				return Tx.HHD_OWNS
			if st.get("needs_helper", {}).get("fan", false):
				return Tx.NO_HELPER
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
				# the curve is the fan setting now: Power must not put a remembered preset back
				# over it on the next charger change or start (review H5)
				power._remember("device", "fan_mode", "custom")
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
		func(c):
			if c.value != null:
				return c.value
			# first read since GameCove started: the saver may still be on from before,
			# with the values it replaced (the hardware kept the saver's)
			var saved := _saved_saver()
			if bool(saved.get("on", false)):
				_saver_prev = saved.get("prev", {}) if saved.get("prev") is Dictionary else {}
				_saver_auto = bool(saved.get("auto", false))
				return true
			return false,
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
				# the exact watts and the firmware limits that follow them (the Ally's
				# SPPT/FPPT went 30/30 -> 15/15 under the battery profile and stayed)
				for id in ["power.tdp", "power.boost", "power.sppt", "power.fppt"]:
					var other: RefCounted = _ctl(id)
					if other != null and other.available:
						other.detect()
						var now: Variant = other.read()
						if now != null:
							_saver_prev[id] = now
				registry.apply(want)
				_save_saver(true)
			else:
				_saver_auto = false
				# forced: the controls' cached values may still show what was there before the
				# saver (the TDP control never re-read after the profile wrote 12 W), and a
				# plain apply would skip them as "unchanged"
				registry.apply(_saver_prev, true)
				_saver_prev = {}
				_save_saver(false)
			return true)


## Battery saver on / off and what it replaced, per handheld (survives a restart).
func _save_saver(on: bool) -> void:
	var sec := PerDevice.section("saver", device_key())
	var prev := _saver_prev.duplicate(true) if on else {}
	var auto := _saver_auto and on
	SettingsFile.update_cfg(cfg_path, func(cfg: ConfigFile):
		cfg.set_value(sec, "on", on)
		cfg.set_value(sec, "prev", prev)
		cfg.set_value(sec, "auto", auto))


func _saved_saver() -> Dictionary:
	var cfg := SettingsFile.load_cfg(cfg_path)
	var sec := PerDevice.section("saver", device_key())
	if not cfg.has_section(sec):
		return {}
	return {"on": cfg.get_value(sec, "on", false), "prev": cfg.get_value(sec, "prev", {}), "auto": cfg.get_value(sec, "auto", false)}


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
	return _make("power.sleep_mode", "choice", {"per_game": false, "needs_root": true},
		func(c):
			var m: Dictionary = be.mem_sleep()
			if m.is_empty():
				return Tx.NOT_HERE
			var offered: Array = m["offered"].filter(func(w): return w in ["s2idle", "deep"])
			if offered.size() < 2:
				return Tx.ONE_SLEEP
			if not be.helper_present():
				return Tx.NO_HELPER
			if _admin_blocked():
				return Tx.NEEDS_ADMIN
			c.options = _choice_opts(offered)
			return "",
		func(_c): return str(be.mem_sleep().get("active", "")),
		func(_c, v): return be.set_mem_sleep(str(v)))


## SMT, cores, sleep mode and MCU power saving need the admin password (review S3-2), which Gaming
## Mode can't ask for. Tests set ctx["password_prompt"].
func _admin_blocked() -> bool:
	if ctx.has("password_prompt"):
		return not bool(ctx["password_prompt"])
	return Backend.no_password_prompt()


func _mcu() -> RefCounted:
	return _make("power.mcu_powersave", "toggle", {"per_game": false, "needs_root": true},
		func(_c):
			if be.mcu_file() == "":
				return Tx.NOT_HERE
			# only with new enough controller MCU firmware (review S1-3)
			var why: String = be.mcu_blocked()
			if why != "" and Backend.read(be.mcu_file()) != "1":
				return why
			if be.helper_present() and _admin_blocked():
				return Tx.NEEDS_ADMIN
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
