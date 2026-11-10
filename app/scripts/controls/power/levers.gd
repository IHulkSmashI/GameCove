extends RefCounted
## The levers Auto TDP (scripts/device/autotune.gd) moves, on whatever this handheld's backends
## allow (backend.gd): the TDP through Power's own backend (hhd / steamos-manager / PowerStation),
## the GPU floor (PowerStation on AMD and i915, the helper on xe and amdgpu), the GPU efficiency
## mode (xe power_profile, steamos-manager GpuPowerProfile1), CPU boost, CPU ceiling, EPP and the
## RAPL PL1 window. Each lever remembers the value it found before its first change; restore()
## puts every one back when Auto TDP stops (ClawDeck: sysfs.revert_all at game exit).
## Runs on Power's worker.

var be: RefCounted
## Callable(watts: int) -> bool: Power.write_tdp.
var tdp_writer: Callable
var _orig := {}
var _gpu := {}      # gpu_clocks() at the first floor change
var _gpu_raw := {}  # backend.gpu_raw_state() then: PowerStation's ManualClock goes back too (review L9)
var _cached := {}


func _init(backend: RefCounted, writer: Callable) -> void:
	be = backend
	tdp_writer = writer


## What this handheld offers (cached once per Auto TDP session; refresh() forgets it).
func refresh() -> void:
	_cached.clear()


func _cap(key: String, f: Callable) -> Variant:
	if not _cached.has(key):
		_cached[key] = f.call()
	return _cached[key]


func tdp(w: int) -> bool:
	return bool(tdp_writer.call(w))


func gpu_floor_ok() -> bool:
	return _cap("gpu", func(): return not be.gpu_clocks().is_empty())


## [efficient clock, current ceiling] in MHz (-1 unknown).
func gpu_limits() -> Array:
	var c: Dictionary = be.gpu_clocks()
	if c.is_empty():
		return [-1, -1]
	return [int(c.get("rpe", -1)), int(c["max"])]


## mhz -1: back to the floor there was before Auto TDP.
func gpu_floor(mhz: int) -> bool:
	var c: Dictionary = be.gpu_clocks()
	if c.is_empty():
		return false
	if _gpu.is_empty():
		_gpu = c.duplicate()
		_gpu_raw = be.gpu_raw_state() if be.has_method("gpu_raw_state") else {}
	var want: int = int(_gpu["min"]) if mhz < 0 else mhz
	return be.set_gpu_clocks(want, -1)


func gpu_profile_now() -> String:
	return str(be.gpu_profile_info().get("active", ""))


func gpu_profiles() -> Array:
	return _cap("gpu_profiles", func(): return be.gpu_profile_info().get("offered", []))


func gpu_profile(v: String) -> bool:
	_remember("gpu_profile", gpu_profile_now())
	return be.set_gpu_profile(v)


func boost_ok() -> bool:
	return _cap("boost", func(): return be.boost_via() != "")


func boost(on: bool) -> bool:
	var now: Variant = be.get_boost()
	if now != null:
		_remember("boost", now)
	return be.set_boost(on)


func cpu_ceiling_ok() -> bool:
	return _cap("cpu_max", func(): return not be.cpu_max().is_empty() and be.helper_present())


func cpu_ceiling(pct: int) -> bool:
	_remember("cpu_max", int(be.cpu_max().get("pct", 100)))
	return be.set_cpu_max(pct)


func epp_now() -> String:
	return be.epp_now() if be.helper_present() else ""


func epp_choices() -> Array:
	return _cap("epp", func(): return be.epp_choices() if be.helper_present() else [])


func epp(v: String) -> bool:
	_remember("epp", be.epp_now())
	return be.set_epp(v)


func tau_ok() -> bool:
	return _cap("tau", func(): return be.rapl_window() != "" and be.helper_present())


func set_tau(us: int) -> bool:
	return be.set_tau(us)


func restore_tau() -> bool:
	return be.restore_tau()


func _remember(key: String, value: Variant) -> void:
	if not _orig.has(key) and value != null and str(value) != "":
		_orig[key] = value


## Everything Auto TDP moved back to what it found (the TDP is the caller's). True when all went back.
## A lever whose write-back failed keeps its original, so the next restore() (the next game's
## end, or Power's) tries again instead of forgetting it (review L9).
func restore() -> bool:
	var ok := true
	if not _gpu.is_empty():
		var g: bool = be.set_gpu_clocks(int(_gpu["min"]), int(_gpu["max"]))
		# set_gpu_clocks leaves PowerStation in manual clock mode: hand it back as it was
		if g and not _gpu_raw.get("ps", []).is_empty():
			g = be.gpu_raw_restore(_gpu_raw, false)
		if g:
			_gpu.clear()
			_gpu_raw.clear()
		ok = g and ok
	var put := {
		"gpu_profile": func(v): return be.set_gpu_profile(str(v)),
		"boost": func(v): return be.set_boost(bool(v)),
		"cpu_max": func(v): return be.set_cpu_max(int(v)),
		"epp": func(v): return be.set_epp(str(v)),
	}
	for k in ["gpu_profile", "boost", "cpu_max", "epp"]:
		if _orig.has(k):
			if bool(put[k].call(_orig[k])):
				_orig.erase(k)
			else:
				ok = false
	_cached.clear()
	return ok
