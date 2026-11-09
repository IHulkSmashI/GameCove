extends Node
## A Controls registry for UI tests and screenshots: same API and signals as
## app/scripts/controls/controls.gd, everything synchronous, no system
## access. Controls are real Control objects (Control.make) whose hooks read
## and write a dictionary. Build from specs, or from a snapshot JSON made by
## tools/screenshots/dump_controls.gd (real providers on the device matrix).
##
##   var c = FakeControls.new()
##   c.add({"id": "power.tdp", "kind": "slider", "min_value": 4, "max_value": 30, "value": 15})
##   c.refuse["power.tdp"] = true     # the next writes fail
##   c.defer = true                   # writes wait for flush() (pending state)

signal control_changed(id: String, value: Variant)
signal control_failed(id: String, value: Variant)
signal detected()

const ControlScript := preload("res://scripts/controls/control.gd")

var ctx: Dictionary = {}
var sync_mode := true
## id -> true: writes to it fail.
var refuse := {}
## Hold writes until flush() (to see the pending state).
var defer := false
var writes: Array = []          # [id, value] in order
var detect_calls := 0
var _controls := {}
var _order: Array = []
var _queued: Array = []


## spec: Control vars (id, title, help, group, kind, min_value, max_value,
## step, unit, options, points, default_value, per_game, needs_root,
## requires, apply_order) plus "value" and "reason" ("" = available).
func add(spec: Dictionary) -> RefCounted:
	var s := spec.duplicate(true)
	var state := {"value": s.get("value"), "reason": str(s.get("reason", ""))}
	for k in ["value", "reason", "available"]:
		s.erase(k)
	if not s.has("group"):
		s["group"] = str(s["id"]).get_slice(".", 0)
	if not s.has("title"):
		s["title"] = str(s["id"]).get_slice(".", 1).capitalize()
	var c := ControlScript.make(s,
		func(_c): return state["reason"],
		func(_c): return state["value"],
		func(_c, v):
			state["value"] = v
			return true)
	c.set_meta("fake_state", state)
	if not _controls.has(c.id):
		_order.append(c.id)
	_controls[c.id] = c
	c.ctx = ctx
	c.detect()
	c.read()
	return c


## Loads a dump (tools/screenshots/dump_controls.gd). `patch`: {id: {key:
## value}} overrides (available, reason, value, min, max, options, ...).
func load_snapshot(path: String, patch := {}) -> void:
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not d is Dictionary:
		return
	for c in d.get("controls", []):
		var spec := from_describe(c)
		if patch.has(spec["id"]):
			var p: Dictionary = patch[spec["id"]]
			for k in p:
				var kk: String = {"min": "min_value", "max": "max_value", "default": "default_value"}.get(k, k)
				spec[kk] = p[k]
			if p.has("value") and not p.has("reason"):
				spec["reason"] = ""
		add(spec)


## A spec for add() from a describe() dictionary.
static func from_describe(c: Dictionary) -> Dictionary:
	var spec := {"id": c["id"], "title": c.get("title", ""), "help": c.get("help", ""), "group": c.get("group", ""),
		"kind": c.get("kind", "toggle"), "min_value": float(c.get("min", 0.0)), "max_value": float(c.get("max", 1.0)),
		"step": float(c.get("step", 1.0)), "unit": c.get("unit", ""), "options": c.get("options", []),
		"points": int(c.get("points", 0)), "default_value": c.get("default"), "per_game": bool(c.get("per_game", true)),
		"needs_root": bool(c.get("needs_root", false)), "requires": c.get("requires", []),
		"apply_order": int(c.get("apply_order", 0)),
		"value": _num(c.get("value")), "reason": "" if bool(c.get("available", false)) else str(c.get("reason", "Not here"))}
	# JSON turns ints into floats; choice values must keep their type
	var opts := []
	for o in spec["options"]:
		if o is Dictionary:
			opts.append({"value": _num(o.get("value")), "label": o.get("label", "")})
	spec["options"] = opts
	return spec


static func _num(v: Variant) -> Variant:
	if v is float and is_equal_approx(v, roundf(v)) and absf(v) < 1e9:
		return int(v)
	if v is Array:
		return v.map(func(x): return float(x))
	return v


func setup(context: Dictionary) -> void:
	ctx = context


func has(id: String) -> bool:
	return _controls.has(id)


func control(id: String) -> RefCounted:
	return _controls.get(id)


func list(group := "") -> Array:
	var out := []
	for id in _order:
		if group == "" or _controls[id].group == group:
			out.append(_controls[id])
	return out


func value(id: String) -> Variant:
	var c = _controls.get(id)
	return c.value if c != null else null


func detect_all() -> void:
	detect_calls += 1
	for id in _order:
		_controls[id].detect()
		_controls[id].read()
	detected.emit()


func set_value(id: String, v: Variant) -> void:
	var c = _controls.get(id)
	if c == null:
		return
	if defer:
		_queued.append([id, v])
		return
	_write(c, v)


func flush() -> void:
	var q := _queued.duplicate()
	_queued.clear()
	for job in q:
		_write(_controls[job[0]], job[1])


func _write(c: RefCounted, v: Variant) -> void:
	writes.append([c.id, v])
	if refuse.has(c.id):
		control_failed.emit(c.id, v)
		return
	if c.write(v):
		control_changed.emit(c.id, c.value)
	else:
		control_failed.emit(c.id, v)


## Makes a control (un)available, as a backend appearing would.
func set_available(id: String, on: bool, reason := "Not here") -> void:
	var c = _controls.get(id)
	if c == null:
		return
	c.get_meta("fake_state")["reason"] = "" if on else reason
	c.detect()
	c.read()


func snapshot(per_game_only := true) -> Dictionary:
	var out := {}
	for id in _order:
		var c = _controls[id]
		if c.available and c.value != null and (c.per_game or not per_game_only):
			out[id] = c.value
	return out


func apply(values: Dictionary) -> void:
	for id in values:
		var c = _controls.get(id)
		if c == null or not c.available or c.value == c.coerce(values[id]):
			continue
		_write(c, values[id])
