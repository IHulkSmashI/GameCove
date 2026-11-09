extends RefCounted
## One user-facing setting (brightness, TDP, gyro sensitivity, upscaler...).
## Every adjustable thing in GameCove is a Control registered with the Controls
## autoload, so the quick menu, the settings pages and per-game / power-source
## profiles all drive it the same way. Providers subclass this (or build one
## with Control.make()) and override the three hooks:
##   _detect() -> String   ""  when usable on this machine, else a short plain
##                         reason shown greyed out ("Needs InputPlumber").
##   _read() -> Variant    current value from the system (null if unknown).
##   _write(v) -> bool     apply v; true on success.
## Hooks run on a worker thread (Controls queues them); they must not touch
## the scene tree. All system access goes through `ctx` (sys_root, runner,
## home) so tests swap in fixture trees and fake runners.

## Unique id, dotted by group: "display.brightness", "power.tdp".
var id := ""
var title := ""
## One plain line shown under the title.
var help := ""
## power | display | perf | audio | controller | system | network
var group := ""
## slider | choice | toggle | color | action | curve
## (curve: an Array of `points` numbers, each in min..max on `step`; a fan curve)
var kind := "toggle"
## slider: min/max/step/unit ("W", "%", "Hz", "fps"); choice: options =
## [{"value": v, "label": "..."}...]
var min_value := 0.0
var max_value := 1.0
var step := 1.0
var unit := ""
var options: Array = []
## curve: how many points (0 = any count).
var points := 0
var default_value: Variant = null
## Saved in per-game and power-source profiles (brightness: no; TDP: yes).
var per_game := true
## Higher runs first when a profile applies several at once (power before fps).
var apply_order := 0
## Needs a root action (pkexec): the UI shows a lock badge on first use.
var needs_root := false
## Optional: ids this depends on; disabled while a dependency is off/unavailable.
var requires: Array = []
## Optional: ids whose value a write of this one changes on the system (a power
## profile sets the TDP, the TDP sets PL2, the battery saver several). Controls
## reads them again after a write that worked, so they never show a stale value.
var affects: Array = []
## Optional: makes an already coerced value safe for this device (a fan curve
## raised to Quiet and never falling); returns null to reject it. Called by
## coerce(), so profiles, imports and the UI all get the safe value.
var normalize: Callable

var ctx: Dictionary = {}           # {"sys_root", "runner", "home", "device"}
var available := false
var reason := "Not checked yet"
var value: Variant = null

var _detect_fn: Callable
var _read_fn: Callable
var _write_fn: Callable


## Builds a control from callables instead of a subclass:
## spec keys mirror the vars above; fns take the control as first argument.
static func make(spec: Dictionary, detect_fn: Callable, read_fn: Callable, write_fn: Callable) -> RefCounted:
	var c = load("res://scripts/controls/control.gd").new()
	for k in spec:
		c.set(k, spec[k])
	c._detect_fn = detect_fn
	c._read_fn = read_fn
	c._write_fn = write_fn
	return c


func detect() -> void:
	var r: String = _detect()
	available = r == ""
	reason = r


func read() -> Variant:
	if not available:
		return null
	value = _read()
	return value


## Clamps/validates, then writes. Returns true when applied.
func write(v: Variant) -> bool:
	if not available:
		return false
	var nv: Variant = coerce(v)
	if nv == null:
		return false
	if _write(nv):
		value = nv
		return true
	return false


## The value made valid for this control, or null when it can't be.
func coerce(v: Variant) -> Variant:
	var out: Variant = _coerce_kind(v)
	if out != null and normalize.is_valid():
		out = normalize.call(out)
	return out


func _coerce_kind(v: Variant) -> Variant:
	match kind:
		"slider":
			if not (v is int or v is float):
				return null
			var f := clampf(float(v), min_value, max_value)
			if step > 0.0:
				f = min_value + roundf((f - min_value) / step) * step
				f = clampf(f, min_value, max_value)
			return f
		"toggle":
			return bool(v) if (v is bool or v is int) else null
		"choice":
			# compare like types only: "fsr" == 30 is a script error in GDScript,
			# and a profile or import may hand over a value of the wrong type
			var num := v is int or v is float
			for o in options:
				var ov: Variant = o.get("value") if o is Dictionary else null
				var onum := ov is int or ov is float
				if (typeof(ov) == typeof(v) or (num and onum)) and ov == v:
					return ov
			return null
		"color":
			return v if v is String and v.is_valid_html_color() else null
		"curve":
			if not v is Array or v.is_empty() or (points > 0 and v.size() != points):
				return null
			var out := []
			for x in v:
				if not (x is int or x is float):
					return null
				var f := clampf(float(x), min_value, max_value)
				if step > 0.0:
					f = clampf(min_value + roundf((f - min_value) / step) * step, min_value, max_value)
				out.append(f)
			return out
		_:
			return v


func describe() -> Dictionary:
	return {"id": id, "title": title, "help": help, "group": group, "kind": kind,
		"min": min_value, "max": max_value, "step": step, "unit": unit,
		"options": options, "points": points, "default": default_value, "per_game": per_game,
		"needs_root": needs_root, "requires": requires,
		"available": available, "reason": reason, "value": value}


func _detect() -> String:
	return _detect_fn.call(self) if _detect_fn.is_valid() else "Not supported"


func _read() -> Variant:
	return _read_fn.call(self) if _read_fn.is_valid() else null


func _write(v: Variant) -> bool:
	return _write_fn.call(self, v) if _write_fn.is_valid() else false
