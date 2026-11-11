extends Node
## Profiles: saved values for Controls (controls.gd), applied by themselves.
## Autoload "Profiles".
##
## Layers, per device (one drive can boot several handhelds; a 35 W profile
## picked on a Claw must never reach a Steam Deck):
##   global        everyday values
##   ac / battery  per power source
##   game          one game, any power source
##   game+ac / game+battery
## Precedence: game+source > game > source > global. effective() merges them
## in that order; explain() says which layer each value came from.
##
## When they apply (no polling; everything follows a signal):
##   - Controls.detected the first time: the everyday values (global + source).
##     Later detections apply only values of controls that just appeared
##     (another provider loaded, a backend started), never undoing a change the
##     user made by hand.
##   - GameSession.started (a game launched / took focus): the game's layers.
##     The values from just before the game are kept; every control a game
##     layer touches during the session goes back to them at the end.
##   - GameSession.ended: back to baseline + global + source, baseline dropped.
##   - Power.changed with a different charger state (Power checks the charger;
##     we also look once at every game start and end): the other source's
##     layers.
##   - An edit that touches what's in effect right now (save_current, reset,
##     import, set_value, copy into the current context).
##
## Values are stored by control id and kept even when no provider registers
## that id (yet): a provider merged later, a backend that isn't running today,
## a profile imported from a handheld with other hardware. Applying skips ids
## that are unknown, unavailable, not per_game, or whose value the control
## rejects (Control.coerce); Controls clamps the rest to the control's range,
## which providers keep inside the device's safe limits.
##
## File: user://profiles.json (atomic writes), shape
##   {"format": "gamecove-profiles", "version": 1, "devices": {"<device key>": {
##     "global": {id: v}, "ac": {...}, "battery": {...},
##     "games": {"<game key>": {"title": "", "updated": unix, "all": {...}, "ac": {...}, "battery": {...}}}}}}
## Export/import use the same format with one device (or one game) in it.
##
## Tests: var p = ProfilesScript.new(); p.setup(registry, "msi-claw-8-ex", path)
## then call game_started()/game_ended()/set_plugged() directly.

## Stored profiles changed (save, reset, copy, import).
signal changed()
## Values were sent to Controls. info: {"game": key or "", "source": "ac"|"battery",
## "values": {id: v} (what was sent), "from": {id: layer}, "reason": String}.
signal applied(info: Dictionary)

const SettingsFile := preload("res://scripts/system/settings_file.gd")
const PerDevice := preload("res://scripts/device/per_device.gd")
const DeviceScript := preload("res://scripts/device/device.gd")

const FORMAT := "gamecove-profiles"
const VERSION := 1
const PATH := "user://profiles.json"
const SOURCES: Array[String] = ["ac", "battery"]
## Layer names, lowest precedence first (explain() uses these).
const LAYERS: Array[String] = ["global", "source", "game", "game+source"]
## Imports larger than this are refused (a profile is a few KB).
const MAX_IMPORT_BYTES := 1 << 20
## The frame limit control Profiles owns (see sync_launcher_fps()).
const FPS_ID := "display.fps_limit"
## The values from before the running game, kept on disk next to profiles.json while it
## runs (review H2): a crash, a SIGTERM at a session switch or a power-off leaves them
## there, and the next start (or `gamecove.x86_64 --headless -- --restore-baseline`, run by
## the session on a switch) puts them back instead of keeping the game's.
const BASELINE_FILE := "game_baseline.json"
## Headless run that only puts the everyday values back (and a leftover game baseline), then quits.
const RESTORE_ARG := "--restore-baseline"
const RESTORE_TIMEOUT_S := 30.0

var controls: Object       # the Controls registry (autoload or a test instance)
var power: Object          # Power autoload (signal changed, var plugged) or null
## Launcher (settings_for(key)["fps_limit"]): its per-game frame limit is moved
## into the game's profile (display.fps_limit); Profiles alone applies it.
var launcher: Object
var device_id := "unknown"
var path := PATH
var baseline_path := "user://" + BASELINE_FILE
## "ac" or "battery"; set_plugged() changes it.
var source := "battery"
## Key of the game in front ("" at home) and its title.
var game_key := ""
var game_title := ""

var _data: Dictionary = {}
var _baseline: Dictionary = {}     # id -> value before the game changed it
var _pre_game: Dictionary = {}     # every per-game value when the game started
var _session: Object
var _first_detect_done := false
var _seen_available: Dictionary = {}   # ids available at the last detection
var _apply_after_detect := ""          # a reason to apply once the detection asked for ends
var _apply_after_seq := 0              # ... the Controls detection that has to have finished
var _layer_gen := 0
var _game_gen := 0                     # game starts so far
var _ended_baseline: Dictionary = {}   # the last ended game's baseline ...
var _restore_gen := 0                  # ... its restore, queued (main thread) ...
var _restore_done := 0                 # ... and run (Controls worker)
var _restore_and_quit := false         # --restore-baseline: quit once the start values are applied
var controller: Object                 # Controller autoload (hand_back), or null; set when --restore-baseline runs


func _ready() -> void:
	if RESTORE_ARG in OS.get_cmdline_user_args():
		_restore_and_quit = true
		controller = get_node_or_null("/root/Controller")
		get_tree().create_timer(RESTORE_TIMEOUT_S).timeout.connect(func(): get_tree().quit(1))
	if controls != null:
		return   # set up by a test
	var dev := get_node_or_null("/root/Device")
	setup(get_node_or_null("/root/Controls"), str(dev.id()) if dev != null and dev.has_method("id") else "unknown", PATH)
	attach_power(get_node_or_null("/root/Power"))
	launcher = get_node_or_null("/root/Launcher")
	# GameSession belongs to main.gd (not an autoload): pick it up when it joins.
	var existing := get_tree().root.find_child("GameSession", true, false)
	if existing != null:
		attach_session(existing)
	else:
		get_tree().node_added.connect(_on_node_added)


func setup(registry: Object, device: String, file_path := PATH) -> void:
	controls = registry
	device_id = PerDevice.key(device)
	path = file_path
	baseline_path = file_path.get_base_dir().path_join(BASELINE_FILE)
	load_file()
	if controls != null and controls.has_signal("detected") and not controls.detected.is_connected(_on_detected):
		controls.detected.connect(_on_detected)


func attach_power(p: Object) -> void:
	power = p
	if power != null and power.has_signal("changed") and not power.changed.is_connected(_on_power_changed):
		power.changed.connect(_on_power_changed)
	_refresh_source(false)


func attach_session(s: Object) -> void:
	if s == null or s == _session:
		return
	_session = s
	if s.has_signal("started"):
		s.started.connect(game_started)
	if s.has_signal("ended"):
		s.ended.connect(game_ended)
	if is_inside_tree() and get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)


func _on_node_added(n: Node) -> void:
	if n.name == "GameSession" and n.has_signal("started"):
		attach_session(n)


# ---- events -------------------------------------------------------------------

func game_started(game: Dictionary) -> void:
	var key := str(game.get("key", ""))
	if key == "":
		return
	if game_key != "" and game_key != key:
		_end_game()
	# The game before may have ended a moment ago (GameSession: ended(A), started(B)) and
	# its restore still be queued: then the snapshot below still shows its values. What it
	# changed goes back to the values from before it (review M17).
	var carry: Dictionary = _ended_baseline if _restore_done < _restore_gen else {}
	_game_gen += 1
	game_key = key
	_pre_game = controls.snapshot(true) if controls != null else {}
	_pre_game.merge(carry, true)
	game_title = str(game.get("title", ""))
	_remember_title(key, game_title)
	sync_launcher_fps(key)
	_refresh_source(false)
	apply_now("game started")


func game_ended(_game: Dictionary = {}) -> void:
	_end_game()


func _end_game() -> void:
	if game_key == "":
		return
	game_key = ""
	game_title = ""
	_refresh_source(false)
	_set_game_layer(false)
	apply_now("game ended")
	_ended_baseline = _baseline.duplicate()
	_baseline.clear()
	_pre_game.clear()
	_restore_gen += 1
	var rg := _restore_gen
	var gg := _game_gen
	_after_worker(func():
		_restore_done = rg
		if _game_gen == gg:   # no other game started since: its own file is the one there now
			_drop_baseline_file())


## The charger was plugged in (true) or unplugged.
func set_plugged(on: bool) -> void:
	var s := "ac" if on else "battery"
	if s == source:
		return
	source = s
	# Ranges follow the source (the TDP's ceiling on battery vs plugged in): detect
	# again and apply once that's done, or the new values get clamped to the old range.
	if controls != null and controls.has_method("detect_all") and controls.has_signal("detected"):
		_apply_after_detect = "power source"
		controls.detect_all()
		_apply_after_seq = int(controls.get("requested_seq")) if "requested_seq" in controls else 0
	else:
		apply_now("power source")


func _on_power_changed(_state: Dictionary = {}) -> void:
	_refresh_source(true)


func _refresh_source(apply_on_change: bool) -> void:
	var on: bool
	if power != null and "plugged" in power:
		on = bool(power.plugged)
	elif controls != null and "ctx" in controls and controls.ctx is Dictionary:
		on = DeviceScript.ac_online(str(controls.ctx.get("sys_root", "")))
	else:
		return
	if apply_on_change:
		set_plugged(on)
	else:
		source = "ac" if on else "battery"


func _on_detected() -> void:
	var now := {}
	for c in _all_controls():
		if _available(c):
			now[c.id] = true
	# an older detection (from before the charger changed again) isn't the one we wait for
	if _apply_after_detect != "" and "detected_seq" in controls and int(controls.detected_seq) < _apply_after_seq:
		return
	if _apply_after_detect != "":
		var why := _apply_after_detect
		_apply_after_detect = ""
		_first_detect_done = true
		_seen_available = now
		apply_now(why)
		return
	if not _first_detect_done:
		_first_detect_done = true
		_seen_available = now
		if game_key != "" or not restore_baseline():
			apply_now("start")
		if _restore_and_quit:
			_after_worker(func(): _leave_and_quit.call_deferred())
		return
	var fresh := now.keys().filter(func(id): return not _seen_available.has(id))
	_seen_available = now
	if not fresh.is_empty():
		# a leftover baseline kept for a control that wasn't there at start (review 2, low 14)
		if game_key == "" and FileAccess.file_exists(SettingsFile.abs_path(baseline_path)):
			restore_baseline(fresh)
		apply_now("controls appeared", fresh)


## The frame limit used to live in Launcher's per-game settings (applied by
## GameSession). Profiles owns it now: whenever Launcher's stored value for
## this game differs from the one last taken over (the old settings form still
## writes there), it becomes the game's display.fps_limit, snapped to the
## nearest choice at or below it. GameSession stops applying its own while
## Controls has display.fps_limit (GameSession.profiles_own_fps()).
## True when the profile changed.
func sync_launcher_fps(key: String) -> bool:
	if launcher == null or not launcher.has_method("settings_for") or key == "":
		return false
	var v := int(launcher.settings_for(key).get("fps_limit", 0))
	var dflt := 0
	if launcher.has_method("defaults_for") and launcher.has_method("profile"):
		dflt = int(launcher.defaults_for(launcher.profile()).get("fps_limit", 0))
	var g: Dictionary = _dev().get("games", {}).get(key, {})
	var last := int(g.get("launcher_fps", dflt))
	if v == last:
		return false
	var c = controls.control(FPS_ID) if controls != null and controls.has(FPS_ID) else null
	if c != null and c.kind == "choice" and v > 0:
		var best := 0
		var opts: Array = _desc(c).get("options", [])
		for o in opts:
			var ov: Variant = o.get("value") if o is Dictionary else null
			if (ov is int or ov is float) and int(ov) <= v and int(ov) > best:
				best = int(ov)
		v = best if best > 0 else v
	_layer_ref(key, "", true)[FPS_ID] = v
	_dev(true)["games"][key]["launcher_fps"] = int(launcher.settings_for(key).get("fps_limit", 0))
	_dev()["games"][key]["updated"] = int(Time.get_unix_time_from_system())
	save_file()
	changed.emit()
	return true


# ---- applying -----------------------------------------------------------------

## Sends what's in effect now (game + source) to Controls. `only`: limit to
## these ids. Returns what was sent.
func apply_now(reason := "", only: Array = []) -> Dictionary:
	if controls == null:
		return {}
	var eff := effective(game_key, source)
	var from := explain(game_key, source)
	if game_key != "":
		var grew := false
		for id in game_ids(game_key):
			if not _baseline.has(id) and _registered(id):
				# a layer added mid-game (save, import) restores to the value
				# from before the game, not to a change made while it ran
				var v: Variant = _pre_game.get(id, controls.value(id))
				if v != null:
					_baseline[id] = v
					grew = true
		if grew:
			_save_baseline_file()
		_set_game_layer(not _baseline.is_empty())
	var target := {}
	for id in _baseline:
		if not eff.has(id):
			target[id] = _baseline[id]
			from[id] = "restore"
	target.merge(eff, true)
	if not only.is_empty():
		for id in target.keys():
			if not id in only:
				target.erase(id)
	var values := applicable(target)
	for id in from.keys():
		if not values.has(id):
			from.erase(id)
	if not values.is_empty():
		controls.apply(values)
	applied.emit({"game": game_key, "source": source, "values": values, "from": from, "reason": reason})
	return values


## The subset of `values` Controls can take right now, coerced: registered,
## available, saved in profiles (per_game) and valid for the control.
func applicable(values: Dictionary) -> Dictionary:
	var out := {}
	for id in values:
		var c = controls.control(id) if controls != null and controls.has(id) else null
		if c == null or not _available(c) or not c.per_game:
			continue
		var v: Variant = controls.coerce(id, values[id]) if controls.has_method("coerce") else c.coerce(values[id])
		if v != null:
			out[id] = v
	return out


## Main thread: the registry's committed copy, never the fields the worker rewrites (review M14).
func _available(c: RefCounted) -> bool:
	return bool(controls.available(c.id)) if controls.has_method("available") else bool(c.available)


func _desc(c: RefCounted) -> Dictionary:
	var d: Dictionary = controls.describe_cached(c.id) if controls.has_method("describe_cached") else {}
	return d if not d.is_empty() else c.describe()


## Puts back a game baseline left on disk by a run that never reached the game's end
## (crash, SIGTERM, power-off), together with the everyday values, and drops it once
## that ran. Only with no game running and only this device's. True when there was one.
## `only`: limit what is sent to these ids (controls that just appeared).
func restore_baseline(only: Array = []) -> bool:
	if game_key != "" or controls == null:
		return false
	var d: Variant = SettingsFile.load_json(baseline_path)["data"]
	if not d is Dictionary or str(d.get("device", "")) != device_id or not d.get("values") is Dictionary:
		if FileAccess.file_exists(baseline_path):
			DirAccess.remove_absolute(SettingsFile.abs_path(baseline_path))
		return false
	var vals := _clean(d["values"])
	var game_vals: Dictionary = d["game_values"] if d.get("game_values") is Dictionary else {}
	var now := applicable(vals)
	var keep := {}
	for id in vals.keys():
		if not now.has(id):
			# registered but not available yet (detected later): kept for when it appears,
			# not dropped with the rest (review 2, low 14)
			if controls.has(id):
				keep[id] = vals[id]
			vals.erase(id)
		elif game_vals.has(id) and _changed_since_game(id, game_vals[id]):
			# the value isn't the game's any more: someone chose a newer one; leave it
			vals.erase(id)
	if not only.is_empty():
		for id in vals.keys():
			if not id in only:
				keep[id] = vals[id]   # still to do, and not ours to send now
				vals.erase(id)
	_baseline = vals
	apply_now("restore baseline", only)
	_baseline.clear()
	var gg := _game_gen
	var kept_game := {}
	for id in keep:
		if game_vals.has(id):
			kept_game[id] = game_vals[id]
	_after_worker(func():
		if _game_gen != gg:
			return
		if keep.is_empty():
			_drop_baseline_file()
		else:
			SettingsFile.save_json(baseline_path, {"device": device_id, "game": str(d.get("game", "")), "values": keep, "game_values": kept_game}, "  "))
	return true


## True when control `id` now holds something other than the value the game set.
func _changed_since_game(id: String, game_value: Variant) -> bool:
	var cur: Variant = controls.value(id)
	if cur == null:
		return false
	var want: Variant = controls.coerce(id, game_value) if controls.has_method("coerce") else game_value
	if want == null:
		return false
	if (cur is int or cur is float) and (want is int or want is float):
		return not is_equal_approx(float(cur), float(want))
	return cur != want


func _save_baseline_file() -> void:
	DirAccess.make_dir_recursive_absolute(SettingsFile.abs_path(baseline_path).get_base_dir())
	# with what the game sets, so a restore can tell a newer choice from the game's value
	var eff := effective(game_key, source)
	var game_vals := {}
	for id in _baseline:
		if eff.has(id):
			game_vals[id] = eff[id]
	SettingsFile.save_json(baseline_path, {"device": device_id, "game": game_key, "values": _baseline, "game_values": game_vals}, "  ")


func _drop_baseline_file() -> void:
	if FileAccess.file_exists(baseline_path):
		DirAccess.remove_absolute(SettingsFile.abs_path(baseline_path))


## Power must not remember what a game layer writes as the user's own (review H2). Set
## from the main thread before the game's values are queued; cleared on the Controls
## worker, in order, before the restore at the game's end is written.
func _set_game_layer(on: bool) -> void:
	if power == null or not "game_layer" in power:
		return
	if on:
		_layer_gen += 1
		power.game_layer = true
	else:
		var p := power
		var gen := _layer_gen
		# not when the next game turned it on again meanwhile (a switch from one game to another)
		_after_worker(func():
			if _layer_gen == gen:
				p.game_layer = false)


## Runs `fn` once everything queued on the Controls worker so far has run (inline in tests).
## --restore-baseline, last steps (main thread): the everyday values are back, and applying
## them put the buttons' GameCove mappings into the profile again (a hold or a back button
## set to a GameCove action: the value's apply loads the whole profile). Nobody answers them
## once Steam or the desktop has the controller, so the Controller hands them back first
## (review High 7: they were dead buttons in Steam); then Power puts back the TDP, boost
## and fan mode the handheld had before GameCove's session, then we quit.
func _leave_and_quit() -> void:
	var quit := func(): get_tree().quit(0)
	var then_power := func():
		if power != null and power.has_method("request_restore_before"):
			power.request_restore_before(quit)
		else:
			quit.call()
	if controller != null and controller.has_method("hand_back"):
		controller.hand_back(then_power)
	else:
		then_power.call()


func _after_worker(fn: Callable) -> void:
	if controls != null and controls.has_method("run_on_worker") and controls.get("sync_mode") != true:
		controls.run_on_worker(fn)
	else:
		fn.call()


# ---- reading ------------------------------------------------------------------

## Merged values for a game ("" = none) and source ("" = the current one).
func effective(game := "", src := "") -> Dictionary:
	var out := {}
	for layer in _stack(game, src):
		out.merge(layer[1], true)
	return out


## {id: "global" | "ac" | "battery" | "game" | "game+ac" | "game+battery"}:
## which layer each effective value comes from.
func explain(game := "", src := "") -> Dictionary:
	var out := {}
	for layer in _stack(game, src):
		for id in layer[1]:
			out[id] = layer[0]
	return out


## One layer's own values (a copy). game "" = global/source layers;
## src "" = the layer for any source.
func layer(game := "", src := "") -> Dictionary:
	return _layer_ref(game, src, false).duplicate()


## Ids any of a game's layers sets.
func game_ids(game: String) -> Array:
	var g: Dictionary = _dev().get("games", {}).get(game, {})
	var ids := {}
	for k in ["all"] + SOURCES:
		for id in g.get(k, {}):
			ids[id] = true
	return ids.keys()


func has_profile(game: String) -> bool:
	return not game_ids(game).is_empty()


## Games with a profile on this device: [{"key", "title", "updated"}], newest first.
func games() -> Array:
	var out := []
	var gs: Dictionary = _dev().get("games", {})
	for k in gs:
		if has_profile(k):
			out.append({"key": k, "title": str(gs[k].get("title", "")), "updated": int(gs[k].get("updated", 0))})
	out.sort_custom(func(a, b): return a["updated"] > b["updated"] if a["updated"] != b["updated"] else a["key"] < b["key"])
	return out


func current_source() -> String:
	return source


# ---- editing ------------------------------------------------------------------

## Saves the current value of every per-game control into a layer, replacing
## it ("Save current as this game's profile"). Default: the running game, any
## source. Returns the saved values.
func save_current(game := "<current>", src := "") -> Dictionary:
	if game == "<current>":
		game = game_key
	var snap: Dictionary = controls.snapshot(true) if controls != null else {}
	set_layer(game, src, snap)
	return snap


## Replaces one layer. Unknown ids are kept; values must be bool/number/text.
func set_layer(game: String, src: String, values: Dictionary) -> void:
	var l := _layer_ref(game, src, true)
	var ids := l.keys() + values.keys()
	l.clear()
	l.merge(_clean(values), true)
	_touched(game, src, true, ids)


## One value in one layer; null removes it.
func set_value(game: String, src: String, id: String, v: Variant) -> void:
	var l := _layer_ref(game, src, true)
	if v == null:
		l.erase(id)
	elif _clean({id: v}).has(id):
		l[id] = _clean({id: v})[id]
	else:
		return
	_touched(game, src, true, [id])


## Copies one layer onto another (replacing it). src "*" copies all three of
## a game's layers.
func copy(from_game: String, from_src: String, to_game: String, to_src: String) -> void:
	if from_src == "*" or to_src == "*":
		var parts := {}
		for s in [""] + SOURCES:
			parts[s] = layer(from_game, s)
		for s in parts:
			var l := _layer_ref(to_game, s, true)
			l.clear()
			l.merge(parts[s], true)
		_touched(to_game, "")
		return
	set_layer(to_game, to_src, layer(from_game, from_src))


## Clears one layer; src "*" clears all of them (for a game: forgets it).
func reset(game := "", src := "*") -> void:
	var dev := _dev(true)
	if src == "*":
		if game == "":
			for k in ["global"] + SOURCES:
				dev[k] = {}
		else:
			dev["games"].erase(game)
	else:
		_layer_ref(game, src, true).clear()
	_touched(game, src, false)


## Forgets every profile on this device.
func reset_all() -> void:
	_data["devices"].erase(device_id)
	_touched("", "*", false)


# ---- export / import ----------------------------------------------------------

## JSON text for one game's profile, or ("") everything on this device.
func export_json(game := "") -> String:
	var out := {"format": FORMAT, "version": VERSION, "device": device_id}
	if game == "":
		out["profiles"] = _dev().duplicate(true)
	else:
		var g: Dictionary = _dev().get("games", {}).get(game, {})
		out["game"] = game
		out["title"] = str(g.get("title", ""))
		for k in ["all"] + SOURCES:
			out[k] = g.get(k, {}).duplicate()
	return JSON.stringify(out, "  ", true)


## Imports export_json() text into this device. A game export goes to
## `as_game` (default: the game it was exported from); a device export
## replaces this device's profiles. Values from another handheld are fine:
## Controls clamps them to this one's limits when they apply.
## Returns {"ok", "why", "game", "values": count, "from_device"}.
func import_json(text: String, as_game := "") -> Dictionary:
	var res := {"ok": false, "why": "", "game": "", "values": 0, "from_device": ""}
	if text.length() > MAX_IMPORT_BYTES:
		res["why"] = "That file is too big to be a profile."
		return res
	var d: Variant = _parse(text)
	if not d is Dictionary or str(d.get("format", "")) != FORMAT:
		res["why"] = "That isn't a GameCove profile."
		return res
	if int(d.get("version", 0)) > VERSION:
		res["why"] = "That profile is from a newer GameCove. Update first."
		return res
	res["from_device"] = str(d.get("device", ""))
	if d.has("profiles"):
		if not d["profiles"] is Dictionary:
			res["why"] = "That profile file is damaged."
			return res
		var dev := _clean_device(d["profiles"])
		_data["devices"][device_id] = dev
		res["values"] = _count(dev)
		_touched("", "*")
	elif d.has("game"):
		var key := as_game if as_game != "" else str(d.get("game", ""))
		if key == "":
			res["why"] = "That profile doesn't say which game it's for."
			return res
		for k in ["all"] + SOURCES:
			var l := _layer_ref(key, "" if k == "all" else k, true)
			l.clear()
			l.merge(_clean(d.get(k, {}) if d.get(k, {}) is Dictionary else {}), true)
			res["values"] += l.size()
		if str(d.get("title", "")) != "":
			_remember_title(key, str(d["title"]))
		res["game"] = key
		_touched(key, "*")
	else:
		res["why"] = "That profile file is empty."
		return res
	res["ok"] = true
	return res


# ---- storage ------------------------------------------------------------------

func load_file() -> void:
	_data = {"format": FORMAT, "version": VERSION, "devices": {}}
	var d: Variant = SettingsFile.load_json(path)["data"]
	if d == null:
		return   # none yet, or damaged (kept as .bad, never saved over this run)
	if not d is Dictionary or str(d.get("format", "")) != FORMAT or not d.get("devices") is Dictionary \
			or int(d.get("version", 0)) > VERSION:
		# from a newer GameCove (or not ours): keep it, never replace it with an empty one
		SettingsFile.reject(path, "not a profiles file this version reads")
		return
	for k in d["devices"]:
		if d["devices"][k] is Dictionary:
			_data["devices"][PerDevice.key(str(k))] = _clean_device(d["devices"][k])
	# profiles made while devices.json didn't know this handheld are its own (review M25)
	var devs: Dictionary = _data["devices"]
	if device_id != PerDevice.UNKNOWN and not devs.has(device_id) and devs.has(PerDevice.UNKNOWN):
		devs[device_id] = devs[PerDevice.UNKNOWN]
		devs.erase(PerDevice.UNKNOWN)
		save_file()


## Writes the file through a temporary one, so a crash never leaves half a file.
func save_file() -> bool:
	DirAccess.make_dir_recursive_absolute(SettingsFile.abs_path(path).get_base_dir())
	return SettingsFile.save_json(path, _data, "  ") == OK


func _dev(create := false) -> Dictionary:
	if not _data.has("devices"):
		_data = {"format": FORMAT, "version": VERSION, "devices": {}}
	if not _data["devices"].has(device_id):
		var fresh := {"global": {}, "ac": {}, "battery": {}, "games": {}}
		if not create:
			return fresh
		_data["devices"][device_id] = fresh
	return _data["devices"][device_id]


func _layer_ref(game: String, src: String, create: bool) -> Dictionary:
	var dev := _dev(create)
	var k := src if src in SOURCES else ("global" if game == "" else "all")
	if game == "":
		return dev[k]
	if not dev["games"].has(game):
		if not create:
			return {}
		dev["games"][game] = {"title": game_title if game == game_key else "", "updated": 0, "all": {}, "ac": {}, "battery": {}}
	var g: Dictionary = dev["games"][game]
	if not g.has(k):
		g[k] = {}
	return g[k]


## [[layer name, values]] lowest precedence first.
func _stack(game: String, src: String) -> Array:
	if not src in SOURCES:
		src = source
	var out := [["global", layer("", "")], [src, layer("", src)]]
	if game != "":
		out.append(["game", layer(game, "")])
		out.append(["game+" + src, layer(game, src)])
	return out


## `ids`: only these changed (re-apply just them; [] = everything). One saved
## value must not re-apply the whole layer over something that set others on
## purpose since (the battery saver's TDP was undone by saving the vibrance).
func _touched(game: String, src: String, stamp := true, ids: Array = []) -> void:
	if stamp and game != "" and _dev().get("games", {}).has(game):
		_dev()["games"][game]["updated"] = int(Time.get_unix_time_from_system())
	save_file()
	changed.emit()
	# Re-apply when the edit is about what's in effect now.
	var current_ctx := game == "" or game == game_key
	var current_src := src in ["", "*", source]
	if current_ctx and current_src and _first_detect_done:
		apply_now("profile edited", ids)


func _remember_title(key: String, title: String) -> void:
	if title == "":
		return
	var dev := _dev()
	if dev.get("games", {}).has(key):
		dev["games"][key]["title"] = title


func _registered(id: String) -> bool:
	return controls != null and controls.has(id)


func _all_controls() -> Array:
	return controls.list() if controls != null and controls.has_method("list") else []


## Parsed JSON or null, without logging an engine error for bad text.
static func _parse(text: String) -> Variant:
	var j := JSON.new()
	return j.data if j.parse(text) == OK else null


## Only {String id: bool | int | float | String} survives (a profile is plain data).
static func _clean(values: Variant) -> Dictionary:
	var out := {}
	if not values is Dictionary:
		return out
	for k in values:
		var v: Variant = values[k]
		if not (k is String) or k == "" or k.length() > 128:
			continue
		if v is bool or v is int or v is String:
			out[k] = v
		elif v is float and is_finite(v):
			# JSON has one number type: whole numbers come back as int, so a
			# value reads the same before and after a save.
			out[k] = int(v) if v == floorf(v) and absf(v) < 1e15 else v
	return out


static func _clean_device(d: Dictionary) -> Dictionary:
	var out := {"global": _clean(d.get("global", {})), "ac": _clean(d.get("ac", {})),
		"battery": _clean(d.get("battery", {})), "games": {}}
	var gs: Variant = d.get("games", {})
	if gs is Dictionary:
		for key in gs:
			var g: Variant = gs[key]
			if not (key is String) or not g is Dictionary:
				continue
			out["games"][key] = {"title": str(g.get("title", "")), "updated": int(g.get("updated", 0)),
				"all": _clean(g.get("all", {})), "ac": _clean(g.get("ac", {})), "battery": _clean(g.get("battery", {}))}
			if g.get("launcher_fps") is int or g.get("launcher_fps") is float:
				out["games"][key]["launcher_fps"] = int(g["launcher_fps"])
	return out


static func _count(dev: Dictionary) -> int:
	var n: int = dev["global"].size() + dev["ac"].size() + dev["battery"].size()
	for g in dev["games"].values():
		n += g["all"].size() + g["ac"].size() + g["battery"].size()
	return n
