extends RefCounted
## What the Controls UI talks to: one object over the Controls registry and
## Profiles (both autoloads, or fakes in tests), for one game in focus.
##
## It adds what every widget needs and Controls doesn't keep:
##   - pending / failed state per control (set_value -> control_changed /
##     control_failed come back later from the Controls worker),
##   - where a value comes from (Profiles.explain: "game", "battery"...),
##   - "needs X first" when a control's `requires` aren't met,
##   - saving: a change that worked is written into the profile layer it came
##     from (this game's when the game has its own settings, else battery /
##     plugged in when that layer holds it, else everyday), so it sticks;
##   - profile editing: for a game that has its own settings but isn't
##     running, changes only go into its profile (nothing on the handheld
##     changes until it starts),
##   - UI-local controls (add_local) that aren't in the registry, e.g. the
##     per-game Auto TDP switch that lives in Launcher.
##
## Signals arrive on the main thread (Controls emits deferred).

const Control_ := preload("res://scripts/controls/control.gd")
const TC := preload("res://scripts/ui/texts_controls.gd")

## A value was applied (or saved into the profile being edited).
signal changed(id: String, value: Variant)
## A write didn't work; the control kept its value.
signal failed(id: String, value: Variant)
## A write started (on = true) or finished.
signal pending_changed(id: String, on: bool)
## Everything may look different: detection finished, a profile changed,
## the game changed. Views re-read their descriptions.
signal refreshed()

const PERF_PROVIDER := "res://scripts/controls/providers/perf.gd"

var controls: Object
var profiles: Object
## The game the UI is about ({} = none): its key picks the profile.
var game: Dictionary = {}
## Write successful changes into profile layers (off for previews).
var autosave := true
var _pending := {}     # id -> value we asked for
var _failed := {}      # id -> value that didn't take
var _local := {}       # id -> Control (not in the registry)
var _local_order: Array = []


func setup(registry: Object, prof: Object = null) -> void:
	if controls != null:
		_disconnect()
	controls = registry
	profiles = prof
	if controls != null:
		if controls.has_signal("control_changed"):
			controls.control_changed.connect(_on_changed)
		if controls.has_signal("control_failed"):
			controls.control_failed.connect(_on_failed)
		if controls.has_signal("detected"):
			controls.detected.connect(_on_refreshed)
	if profiles != null and profiles.has_signal("changed"):
		profiles.changed.connect(_on_refreshed)


func _disconnect() -> void:
	for pair in [[controls, "control_changed", _on_changed], [controls, "control_failed", _on_failed],
			[controls, "detected", _on_refreshed], [profiles, "changed", _on_refreshed]]:
		var o: Object = pair[0]
		if o != null and o.has_signal(pair[1]) and o.is_connected(pair[1], pair[2]):
			o.disconnect(pair[1], pair[2])


func ready() -> bool:
	return controls != null


## The game in focus. Per-game controls (Proton, upscaler...) follow it: the
## perf provider gets it in the Controls context and detection runs again.
func set_game(g: Dictionary, redetect := true) -> void:
	var same := str(g.get("key", "")) == game_key()
	game = g
	if controls != null and "ctx" in controls and controls.ctx is Dictionary and ResourceLoader.exists(PERF_PROVIDER):
		var pp: Script = load(PERF_PROVIDER)
		if pp != null and pp.has_method("set_game"):
			pp.set_game(controls.ctx, g)
	if redetect and not same and controls != null and controls.has_method("detect_all"):
		controls.detect_all()
	_redetect_locals()
	refreshed.emit()


func game_key() -> String:
	return str(game.get("key", ""))


func game_title() -> String:
	return str(game.get("title", game_key()))


# ---- reading ------------------------------------------------------------------

func add_local(c: RefCounted) -> void:
	if not _local.has(c.id):
		_local_order.append(c.id)
	_local[c.id] = c
	c.detect()
	c.read()


func control(id: String) -> RefCounted:
	if _local.has(id):
		return _local[id]
	if controls != null and controls.has_method("has") and controls.has(id):
		return controls.control(id)
	return null


func has(id: String) -> bool:
	return control(id) != null


## Ids in a Controls group, in registration order (locals of that group last).
func ids(group := "") -> Array:
	var out := []
	if controls != null:
		for c in controls.list(group):
			out.append(str(c.id))
	for id in _local_order:
		if group == "" or _local[id].group == group:
			out.append(id)
	return out


## Control.describe() plus: blocked (reason or ""), layer (Profiles), pending,
## failed, editing (profile only), labels (curve point labels when the
## provider set meta "point_labels"). {} when there's no such control.
func describe(id: String) -> Dictionary:
	var c := control(id)
	if c == null:
		return {}
	var d: Dictionary = c.describe()
	d["blocked"] = blocked_reason(c)
	d["layer"] = layer_of(id)
	d["pending"] = _pending.has(id)
	d["failed"] = _failed.has(id)
	d["editing"] = editing_profile() and bool(c.per_game)
	if d["editing"]:
		var eff: Dictionary = profiles.effective(game_key(), "")
		if eff.has(id):
			var v: Variant = c.coerce(eff[id])
			if v != null:
				d["value"] = v
	d["labels"] = c.get_meta("point_labels") if c.has_meta("point_labels") else []
	return d


func value(id: String) -> Variant:
	return describe(id).get("value")


## "" when every control `c` requires is on, else a short reason.
func blocked_reason(c: RefCounted) -> String:
	for dep in c.requires:
		var dc := control(str(dep))
		if dc == null:
			continue
		if not dc.available:
			return TC.NEEDS_OTHER % str(dc.title)
		var v: Variant = dc.value
		if editing_profile() and dc.per_game and profiles != null:
			v = profiles.effective(game_key(), "").get(dc.id, v)
		if falsy(v):
			return TC.NEEDS_FIRST % str(dc.title)
	return ""


static func falsy(v: Variant) -> bool:
	if v == null:
		return true
	if v is bool:
		return not v
	if v is int or v is float:
		return v == 0
	if v is String:
		return v == "" or v.to_lower() in ["off", "none", "disabled"]
	return false


## Where a value comes from now: "global", "ac", "battery", "game",
## "game+ac", "game+battery", or "" (nothing saved: the live value).
func layer_of(id: String) -> String:
	if profiles == null or not profiles.has_method("explain"):
		return ""
	return str(profiles.explain(game_key(), "").get(id, ""))


func is_pending(id: String) -> bool:
	return _pending.has(id)


func is_failed(id: String) -> bool:
	return _failed.has(id)


# ---- the game's own settings --------------------------------------------------

## True when the game in focus has its own settings saved.
func per_game() -> bool:
	return game_key() != "" and profiles != null and profiles.has_profile(game_key())


## True while the game in focus is the one running (Profiles applied it).
func running() -> bool:
	return game_key() != "" and profiles != null and "game_key" in profiles and str(profiles.game_key) == game_key()


## Changes only edit the game's profile (it has one and isn't running).
func editing_profile() -> bool:
	return per_game() and not running()


## "Use settings for this game": on saves the current values as its profile,
## off forgets it (it falls back to the everyday settings).
func set_per_game(on: bool) -> void:
	var key := game_key()
	if key == "" or profiles == null:
		return
	if on:
		profiles.save_current(key, "")
		if profiles.has_method("_remember_title") and game_title() != "":
			profiles._remember_title(key, game_title())
			if profiles.has_method("save_file"):
				profiles.save_file()
	else:
		profiles.reset(key, "*")
	refreshed.emit()


func reset_game() -> void:
	if game_key() != "" and profiles != null:
		profiles.reset(game_key(), "*")
		refreshed.emit()


# ---- writing ------------------------------------------------------------------

## Asks for a new value. Returns false when the control can't take one now.
func set_value(id: String, v: Variant) -> bool:
	var c := control(id)
	if c == null or not c.available or blocked_reason(c) != "":
		return false
	_failed.erase(id)
	if _local.has(id):
		if c.write(v):
			changed.emit(id, c.value)
		else:
			_failed[id] = v
			failed.emit(id, v)
		return true
	if editing_profile() and c.per_game:
		var nv: Variant = c.coerce(v)
		if nv == null:
			return false
		profiles.set_value(game_key(), "", id, nv)
		changed.emit(id, nv)
		return true
	_pending[id] = v
	pending_changed.emit(id, true)
	controls.set_value(id, v)
	return true


## [game, src] of the profile layer a change to `id` is saved into.
func target_layer(id: String) -> Array:
	var key := game_key()
	if key != "" and per_game():
		var from := str(profiles.explain(key, "").get(id, ""))
		return [key, from.trim_prefix("game+") if from.begins_with("game+") else ""]
	var src := str(profiles.explain("", "").get(id, "")) if profiles != null else ""
	return ["", src if src in ["ac", "battery"] else ""]


func _on_changed(id: String, v: Variant) -> void:
	var mine := _pending.has(id)
	_pending.erase(id)
	_failed.erase(id)
	if mine:
		_save(id, v)
		pending_changed.emit(id, false)
	changed.emit(id, v)


func _on_failed(id: String, v: Variant) -> void:
	if _pending.has(id):
		_pending.erase(id)
		_failed[id] = v
		pending_changed.emit(id, false)
	failed.emit(id, v)


func _save(id: String, v: Variant) -> void:
	var c := control(id)
	if not autosave or profiles == null or c == null or not c.per_game or v == null:
		return
	var t := target_layer(id)
	profiles.set_value(t[0], t[1], id, v)


func _on_refreshed() -> void:
	_redetect_locals()
	refreshed.emit()


## UI-local controls follow the game and what Controls found.
func _redetect_locals() -> void:
	for id in _local_order:
		_local[id].detect()
		_local[id].read()


## A plain label for a value of control `d` (describe()), e.g. "17 W", "On".
static func value_label(d: Dictionary, v: Variant = "<current>") -> String:
	if v is String and v == "<current>":
		v = d.get("value")
	if v == null:
		return "—"
	match str(d.get("kind", "")):
		"toggle":
			return "On" if bool(v) else "Off"
		"choice":
			for o in d.get("options", []):
				if o is Dictionary and _same(o.get("value"), v):
					return str(o.get("label", v))
			return str(v)
		"slider":
			return num(float(v), float(d.get("step", 1.0))) + unit_suffix(str(d.get("unit", "")))
		"color":
			return str(v).to_upper()
		"curve":
			return "%d points" % (v as Array).size() if v is Array else "—"
	return str(v)


static func num(f: float, step := 1.0) -> String:
	if step >= 1.0 or is_equal_approx(f, roundf(f)):
		return "%d" % roundi(f)
	if step >= 0.1:
		return "%.1f" % f
	return "%.2f" % f


## " W" for watts, "%" sticks to the number, "" stays "".
static func unit_suffix(u: String) -> String:
	if u == "":
		return ""
	if u in ["%", "°", "x"]:
		return u
	return " " + u


static func _same(a: Variant, b: Variant) -> bool:
	var na := a is int or a is float
	var nb := b is int or b is float
	if na and nb:
		return is_equal_approx(float(a), float(b))
	return typeof(a) == typeof(b) and a == b
