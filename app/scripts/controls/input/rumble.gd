extends RefCounted
## Rumble Controls for the Controller provider: controller.rumble (on/off),
## controller.rumble_strength and controller.rumble_test, on every backend.
## docs/CONTROLS.md ("Rumble") has the per-device table and the research.
##
## Where the strength lives (research 2026-11-09):
##   * InputPlumber (0.78 .. 0.84, main 6aca920): org.shadowblip.Output.ForceFeedback
##     has only `Enabled` (b), `Rumble(d)` (0..1, both motors, a test buzz) and
##     `Stop()`. No gain or scale property, nothing in the device YAML schema; a
##     game's effects pass to the source driver unscaled. So InputPlumber can turn
##     rumble on or off, never weaker.
##   * The controller's firmware, through the kernel HID driver (sysfs, root to
##     write, anyone may read): hid-msi `rumble_intensity_left/_right` 0-100 (MSI
##     Claw, controller firmware 1.66+ / 2.17+), hid-lenovo-go `rumble_intensity`
##     off/low/medium/high (Legion Go / Go 2). Written by fixes/controller-rumble.
##     This scales every game's rumble whoever drives the pad, so it wins.
##   * Handheld Daemon's own settings when hhd runs: ROG Ally `limits.manual.
##     vibration` 0-100, OneXPlayer `vibration_strength` v1-v5, AYANEO `vibration`
##     off/low/medium/high, GPD `wincontrols.vibration` off/medium/high.
##   * Nowhere else: no knob in hid-asus (the Ally series with vibration strength
##     isn't merged), hid-lenovo-go-s, hid-steam or steamos-manager; Steam owns the
##     Steam Deck's haptics. GameCove's InputPlumber intercept only carries input
##     events to GameCove (scripts/input/intercept.gd); force feedback goes game ->
##     virtual pad -> InputPlumber -> controller and never passes through GameCove,
##     so it can't scale effects either.
## devices.json `rumble` says what to expect per handheld (the reasons use it);
## the controls still check the live system.

const Ctl := preload("res://scripts/controls/control.gd")
const Hhd := preload("res://scripts/controls/input/hhd_client.gd")

const FIX_SET_HELPER := "/usr/libexec/gamecove/gamecove-fix-set"
const FIX := "controller-rumble"
const CACHE_MS := 1500
## Kernel knobs, first match wins (the same order as fixes/controller-rumble).
const KNOBS := [
	{"driver": "hid-msi", "kind": "percent", "attrs": ["rumble_intensity_left", "rumble_intensity_right"],
		"range": "rumble_intensity_range"},
	{"driver": "hid-lenovo-go", "kind": "levels", "attrs": ["rumble_intensity"], "levels": "rumble_intensity_index"},
]
const LEVEL_LABELS := {"off": "Off", "low": "Low", "medium": "Medium", "high": "High"}
## Percent steps offered for a 0-100 knob (0 is "Rumble" off).
const PERCENT_STEP := 10

const R_NONE := "Needs InputPlumber or Handheld Daemon running"
const R_IP_ONOFF := "InputPlumber can only turn rumble on or off"
const R_STEAM := "Only Steam sets this controller's rumble strength"
const R_HHD_HERE := "Needs Handheld Daemon; InputPlumber can only turn rumble on or off"
const R_NO_KNOB := "This controller has no rumble strength setting"
const R_HHD_NO_SETTING := "Handheld Daemon has no vibration setting for this handheld"
const R_HHD_NO_OFF := "This handheld can't turn rumble off; set its strength"
const R_HHD_NO_BUZZ := "Handheld Daemon can't buzz on request"
const R_IP_NO_FF := "This handheld can't rumble through InputPlumber"

## input/backend.gd, shared with the Controller provider (its ctx and row too,
## so a new setup() reaches these controls).
var be: RefCounted
var _knob: Dictionary = {}
var _knob_at := -1000000
## Last strength that wasn't off, to turn rumble back on at it (kernel and hhd).
var _last_on: Variant = null
## Strength chosen while a kernel-only rumble was off: applied when it goes on.
var _pending: Variant = null


func _init(backend: RefCounted) -> void:
	be = backend


func controls() -> Array:
	return [toggle(), strength(), test()]


func _be() -> RefCounted:
	return be


func _sys_root() -> String:
	return str(be.ctx.get("sys_root", ""))


func _make(spec: Dictionary, detect: Callable, read: Callable, write: Callable) -> RefCounted:
	spec["group"] = "controller"
	return Ctl.make(spec, detect, read, write)


## devices.json `rumble` of this handheld ({} when the row has none).
func row_info() -> Dictionary:
	var r: Variant = be.row.get("rumble")
	return r if r is Dictionary else {}


# ---- kernel knob ------------------------------------------------------------------

static func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path).strip_edges() if FileAccess.file_exists(path) else ""


## The kernel rumble knob under <sys_root>/sys/bus/hid/drivers, or {}:
## {"driver", "kind": "percent"|"levels", "dir", "attrs", "lo", "hi"} or
## {..., "levels": [words]}, plus "value" (int or word; null when unreadable).
static func scan(sys_root: String) -> Dictionary:
	for k in KNOBS:
		var base: String = sys_root + "/sys/bus/hid/drivers/" + str(k["driver"])
		var d := DirAccess.open(base)
		if d == null:
			continue
		var names: Array = []
		for n in Array(d.get_directories()) + Array(d.get_files()):
			if ":" in n and not n in names:
				names.append(n)
		names.sort()
		for n in names:
			var dir: String = base + "/" + n
			if not (k["attrs"] as Array).all(func(a): return FileAccess.file_exists(dir + "/" + a)):
				continue
			var out := {"driver": k["driver"], "kind": k["kind"], "dir": dir, "attrs": k["attrs"]}
			if k["kind"] == "percent":
				var r := _read(dir + "/" + str(k["range"]))
				var parts := r.split("-")
				var ok := parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_int()
				out["lo"] = int(parts[0]) if ok else 0
				out["hi"] = int(parts[1]) if ok else 100
				var vals: Array = (k["attrs"] as Array).map(func(a): return _read(dir + "/" + a))
				if vals.all(func(v): return str(v).is_valid_int()):
					var sum := 0
					for v in vals:
						sum += int(v)
					out["value"] = roundi(float(sum) / vals.size())
				else:
					out["value"] = null
			else:
				var words: Array = Array(_read(dir + "/" + str(k["levels"])).split(" ", false)).filter(
					func(w): return w != "unknown")
				out["levels"] = words if not words.is_empty() else ["off", "low", "medium", "high"]
				var v := _read(dir + "/" + str(k["attrs"][0]))
				out["value"] = v if v in out["levels"] else null
			return out
	return {}


func knob() -> Dictionary:
	var now := Time.get_ticks_msec()
	if now - _knob_at >= CACHE_MS:
		_knob = scan(_sys_root())
		_knob_at = now
		var v: Variant = _knob.get("value")
		if v != null and not _is_off(v):
			_last_on = v
	return _knob


func _drop_knob() -> void:
	_knob_at = -1000000


## Equal without Godot's error on mixed types (a word knob vs a number); 10 == 10.0.
static func same(a: Variant, b: Variant) -> bool:
	if (a is int or a is float) and (b is int or b is float):
		return absf(float(a) - float(b)) < 0.001
	return typeof(a) == typeof(b) and a == b


static func _is_off(v: Variant) -> bool:
	return v == null or (v is int and v == 0) or str(v) == "off" or str(v) == "disabled"


## Strength choices of the knob: 10..100 % or its words without "off".
static func knob_options(k: Dictionary) -> Array:
	var out: Array = []
	if k.get("kind") == "percent":
		var lo: int = maxi(int(k.get("lo", 0)), PERCENT_STEP)
		var x := lo
		while x <= int(k.get("hi", 100)):
			out.append({"value": x, "label": "%d%%" % x})
			x += PERCENT_STEP
		if out.is_empty() or int(out[out.size() - 1]["value"]) != int(k.get("hi", 100)):
			out.append({"value": int(k.get("hi", 100)), "label": "%d%%" % int(k.get("hi", 100))})
	else:
		for w in k.get("levels", []):
			if w != "off":
				out.append({"value": w, "label": str(LEVEL_LABELS.get(w, str(w).capitalize()))})
	return out


static func _knob_off(k: Dictionary) -> Variant:
	if k.get("kind") == "percent":
		return 0 if int(k.get("lo", 0)) == 0 else null
	return "off" if "off" in k.get("levels", []) else null


## The value to turn a kernel-only rumble on at.
func _knob_on_value(k: Dictionary) -> Variant:
	var opts := knob_options(k)
	for v in [_pending, _last_on]:
		if v != null and opts.any(func(o): return same(o["value"], v)):
			return v
	return opts[opts.size() - 1]["value"] if not opts.is_empty() else null


## Writes the knob through the root action and reads it back.
func knob_write(v: Variant) -> bool:
	var k := knob()
	if k.is_empty() or v == null:
		return false
	var spec := str(v)
	if k["kind"] == "percent":
		if not (v is int or v is float) or int(v) < int(k["lo"]) or int(v) > int(k["hi"]):
			return false
		spec = str(int(v))
		v = int(v)
	elif not spec in k["levels"]:
		return false
	if same(k.get("value"), v):
		return true   # already set: hid-msi writes every store to the controller's flash
	var runner: RefCounted = be.ctx.get("runner")
	if runner == null:
		return false
	var r: Dictionary = runner.run("pkexec", PackedStringArray([FIX_SET_HELPER, FIX, "set", spec]))
	_drop_knob()
	if int(r.get("code", -1)) != 0:
		return false
	var got: Variant = knob().get("value")
	if not same(got, v):
		return false
	if not _is_off(v):
		_last_on = v
	return true


# ---- hhd -------------------------------------------------------------------------

## hhd's vibration setting for this handheld: {"path" (absolute state path),
## "off" (value meaning off, or null when it can't go off), "node", "kind":
## "limits" | "multiple"}, or {}.
func hhd_setting() -> Dictionary:
	var key: String = be.hhd_key()
	if key == "":
		return {}
	var lim: Variant = be.hhd_ctl(["limits"])
	if lim is Dictionary and lim.get("mode") is String:
		return {"kind": "limits", "path": ["controllers", key, "limits", "manual", "vibration"], "off": 0,
			"node": be.hhd_ctl_schema(["limits", "manual", "vibration"])}
	var candidates: Array = [["controllers", key, "vibration_strength"], ["controllers", key, "vibration"],
		["wincontrols", "wincontrols", "vibration"]]   # GPD: hhd src/hhd/device/gpd/win/wincontrols.yml
	for path in candidates:
		if Hhd.dig(be.hhd_state(), path) is String:
			var node: Variant = Hhd.schema_node(be.hhd_settings(), path)
			var vals := Hhd.options_of(node)
			var off: Variant = null
			for w in ["disabled", "off"]:
				if w in vals:
					off = w
			return {"kind": "multiple", "path": path, "off": off, "node": node}
	return {}


func hhd_value(r: Dictionary) -> Variant:
	var v: Variant
	if r["kind"] == "limits":
		v = 100   # hhd's default limits vibrate at full strength
		if str(be.hhd_ctl(["limits", "mode"])) == "manual":
			var got: Variant = Hhd.dig(be.hhd_state(), r["path"])
			v = int(got) if got != null else 100
	else:
		v = str(Hhd.dig(be.hhd_state(), r["path"]))
	if not same(v, r["off"]):
		_last_on = v
	return v


func hhd_write(r: Dictionary, value: Variant) -> bool:
	var patch: Dictionary
	if r["kind"] == "limits":
		patch = {"controllers": {be.hhd_key(): {"limits": {"mode": "manual", "manual": {"vibration": value}}}}}
	else:
		patch = Hhd.nest(r["path"], value)
	var ok: bool = be.hhd_set(patch, [[r["path"], value]])
	if ok and not same(value, r["off"]):
		_last_on = value
	return ok


func hhd_options(r: Dictionary) -> Array:
	if r["kind"] == "limits":
		var node: Variant = r["node"]
		var lo := int(node.get("min", 0)) if node is Dictionary else 0
		var hi := int(node.get("max", 100)) if node is Dictionary else 100
		var st := maxi(1, int(node.get("step", 20)) if node is Dictionary else 20)
		var out: Array = []
		var x := maxi(lo, st)
		while x <= hi:
			out.append({"value": x, "label": "%d%%" % x})
			x += st
		return out
	var labels := Hhd.labels_of(r["node"])
	return Hhd.options_of(r["node"]).filter(func(o): return o != r["off"]).map(
		func(v): return {"value": v, "label": str(labels.get(v, str(v).capitalize()))})


# ---- which path, on this handheld ----------------------------------------------------

## How rumble on/off works here: "ip" (ForceFeedback.Enabled), "hhd" (its
## vibration setting has an off value), "kernel" (the knob's off value), or ""
## with `why` set.
func switch_path() -> Dictionary:
	var backend: String = be.controller_backend()
	if backend == "inputplumber" and be.ip().get("device", {}).get("rumble", false):
		return {"path": "ip"}
	var why := R_NONE
	if backend == "hhd":
		var r := hhd_setting()
		if not r.is_empty() and r["off"] != null:
			return {"path": "hhd", "hhd": r}
		why = R_HHD_NO_SETTING if r.is_empty() else R_HHD_NO_OFF
	elif backend == "inputplumber":
		why = R_IP_NO_FF
	var k := knob()
	if not k.is_empty() and _knob_off(k) != null:
		return {"path": "kernel"}
	return {"path": "", "why": why}


## Where the strength is set: "kernel", "hhd", or "" with `why`.
func strength_path() -> Dictionary:
	if not knob().is_empty():
		return {"path": "kernel"}
	var backend: String = be.controller_backend()
	if backend == "hhd":
		var r := hhd_setting()
		if not r.is_empty():
			return {"path": "hhd", "hhd": r}
	return {"path": "", "why": strength_reason(backend)}


## Why there's no strength here, from devices.json `rumble` and the backend.
func strength_reason(backend: String) -> String:
	var info := row_info()
	match str(info.get("strength", "")):
		"steam":
			return R_STEAM
		"hhd":
			return R_HHD_HERE if backend != "hhd" else R_HHD_NO_SETTING
		"kernel":
			return "Needs a kernel whose %s driver has rumble strength" % str(info.get("driver", "controller"))
		"none":
			return R_NO_KNOB
	match backend:
		"inputplumber":
			return R_IP_ONOFF
		"hhd":
			return R_HHD_NO_SETTING
	return R_NONE


# ---- the controls -------------------------------------------------------------------

func toggle() -> RefCounted:
	return _make({"id": "controller.rumble", "title": "Rumble", "kind": "toggle", "default_value": true,
		"apply_order": 1, "help": "Vibration in games."},
		func(_c):
			var s := switch_path()
			return "" if s["path"] != "" else str(s["why"]),
		func(_c):
			var s := switch_path()
			match s["path"]:
				"ip":
					var en: Variant = _be().ip().get("rumble")
					if en == null:
						return null
					var k := knob()
					return bool(en) and (k.is_empty() or not _is_off(k.get("value")))
				"hhd":
					return not same(hhd_value(s["hhd"]), s["hhd"]["off"])
				"kernel":
					return not _is_off(knob().get("value"))
			return null,
		func(_c, v):
			var s := switch_path()
			match s["path"]:
				"ip":
					if not _be().ip_set_rumble(bool(v)):
						return false
					var k := knob()
					if v and not k.is_empty() and _is_off(k.get("value")):
						return knob_write(_knob_on_value(k))   # someone set the firmware to off
					return true
				"hhd":
					var r: Dictionary = s["hhd"]
					var want: Variant = r["off"]
					if v:
						var opts := hhd_options(r).map(func(o): return o["value"])
						if _last_on != null and _last_on in opts:
							want = _last_on
						elif r["kind"] == "limits":
							want = 100
						else:
							want = opts[int(opts.size() / 2.0)] if not opts.is_empty() else null
					if want == null:
						return false
					return hhd_write(r, want)
				"kernel":
					var k := knob()
					var ok := knob_write(_knob_on_value(k) if v else _knob_off(k))
					if ok and v:
						_pending = null
					return ok
			return false)


func strength() -> RefCounted:
	return _make({"id": "controller.rumble_strength", "title": "Rumble strength", "kind": "choice",
		"default_value": 100, "apply_order": 2,
		"options": [20, 40, 60, 80, 100].map(func(x): return {"value": x, "label": "%d%%" % x}),
		"help": "How strong every game's vibration is. Kept in the controller itself where it can be."},
		func(c):
			var s := strength_path()
			match s["path"]:
				"kernel":
					c.options = knob_options(knob())
					c.default_value = c.options[c.options.size() - 1]["value"] if not c.options.is_empty() else null
					return "" if not c.options.is_empty() else R_NO_KNOB
				"hhd":
					c.options = hhd_options(s["hhd"])
					return "" if not c.options.is_empty() else R_HHD_NO_SETTING
			return str(s["why"]),
		func(c):
			var s := strength_path()
			var v: Variant = null
			match s["path"]:
				"kernel":
					v = knob().get("value")
					if _is_off(v) and switch_path()["path"] == "kernel":
						v = _pending   # rumble is off: the strength it goes back on at
				"hhd":
					v = hhd_value(s["hhd"])
			if v == null or not c.options.any(func(o): return same(o["value"], v)):
				return null   # off, or a value between our steps
			return v,
		func(_c, v):
			var s := strength_path()
			match s["path"]:
				"kernel":
					var k := knob()
					if _is_off(k.get("value")) and switch_path()["path"] == "kernel":
						# Rumble is off and the knob is the switch: remember, don't turn it on.
						if not knob_options(k).any(func(o): return same(o["value"], v)):
							return false
						_pending = v
						return true
					return knob_write(v)
				"hhd":
					return hhd_write(s["hhd"], v)
			return false)


func test() -> RefCounted:
	return _make({"id": "controller.rumble_test", "title": "Test rumble", "kind": "action", "per_game": false,
		"requires": ["controller.rumble"],
		"help": "A short buzz at the rumble strength set here."},
		func(_c):
			match be.controller_backend():
				"inputplumber":
					return "" if be.ip().get("device", {}).get("rumble", false) else R_IP_NO_FF
				"hhd":
					return R_HHD_NO_BUZZ
			return R_NONE,
		func(_c): return null,
		func(_c, _v):
			# Full scale when the firmware scales it, so the buzz is what the chosen
			# strength gives a game's strongest effect; a gentler one where it doesn't.
			return _be().ip_rumble_test(1.0 if not knob().is_empty() else 0.6))
