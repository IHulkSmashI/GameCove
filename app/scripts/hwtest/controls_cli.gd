extends Node
## Hardware-test entry point to the real Controls and Profiles (the code the quick
## menu runs), without the UI. tools/testbed/checks/*.sh use it to change a setting
## and read it back from the system on a handheld:
##
##   gamecove.x86_64 --headless -- --controls list
##   gamecove.x86_64 --headless -- --controls get <id>
##   gamecove.x86_64 --headless -- --controls set <id> <json value>    (kept)
##   gamecove.x86_64 --headless -- --controls probe <id> [<id>...]     (changed, read back, put back)
##   gamecove.x86_64 --headless -- --controls profile-test <id> <json value>
##   gamecove.x86_64 --headless -- --controls source-test <id> <json on AC> <json on battery>
##
## One tab-separated line per result on stdout (keyword first: control, get, set,
## probe, profile, source, error), then the process quits; exit code 0, or 1 when
## something didn't apply. Profiles' automatic applies are detached first, so this
## instance never puts a stored profile on by itself; profile-test and source-test
## drive Profiles directly with a throw-away game key and put every stored layer back.
## boot.gd starts it for `--controls` (so main.tscn never loads).

const TEST_GAME := "test:gamecove-hwtest"
const TIMEOUT_S := 90.0

var args: PackedStringArray = []
var controls: Node
var profiles: Node
var _failed := false
var _signal_hit: Array = []


func _ready() -> void:
	controls = get_node_or_null("/root/Controls")
	profiles = get_node_or_null("/root/Profiles")
	detach_profiles(controls, profiles, get_node_or_null("/root/Power"))
	get_tree().create_timer(TIMEOUT_S).timeout.connect(func():
		out(["error", "timeout", "gave up after %d s" % int(TIMEOUT_S)])
		get_tree().quit(1))
	_run.call_deferred()


## Profiles must not apply stored values in a test instance (start, charger change).
static func detach_profiles(c: Object, p: Object, power: Object) -> void:
	if c == null or p == null:
		return
	if c.has_signal("detected") and p.has_method("_on_detected") and c.detected.is_connected(p._on_detected):
		c.detected.disconnect(p._on_detected)
	if power != null and power.has_signal("changed") and p.has_method("_on_power_changed") \
			and power.changed.is_connected(p._on_power_changed):
		power.changed.disconnect(p._on_power_changed)


func _run() -> void:
	if controls == null:
		out(["error", "controls", "the Controls autoload isn't there"])
		get_tree().quit(1)
		return
	var a := args.duplicate()
	if a.size() > 0 and a[0] == "--controls":
		a.remove_at(0)
	var cmd := a[0] if a.size() > 0 else "list"
	await _barrier()   # the first detect_all (queued by Controls._ready) has finished
	match cmd:
		"list":
			for c in controls.list():
				out(describe(c))
		"get":
			for id in a.slice(1):
				var c = controls.control(id)
				if c == null:
					_unknown(id)
					continue
				out(["get", id, "available=" + yn(c.available), "value=" + js(await _fresh(c))])
		"set":
			if a.size() < 3:
				_usage()
			else:
				await _set_cmd(a[1], parse_value(a[2]))
		"probe":
			for id in a.slice(1):
				await _probe(id)
		"profile-test":
			if a.size() < 3:
				_usage()
			else:
				await _profile_test(a[1], parse_value(a[2]))
		"source-test":
			if a.size() < 4:
				_usage()
			else:
				await _source_test(a[1], parse_value(a[2]), parse_value(a[3]))
		_:
			_usage()
	get_tree().quit(1 if _failed else 0)


# ---- commands -----------------------------------------------------------------

func _set_cmd(id: String, v: Variant) -> void:
	var c = controls.control(id)
	if c == null:
		_unknown(id)
		return
	var ok := await _write(id, v)
	var back: Variant = await _fresh(c)
	var match_ok := ok and same(c, back, c.coerce(v))
	_failed = _failed or not match_ok
	out(["set", id, "want=" + js(v), "ok=" + str(ok).to_lower(), "readback=" + js(back),
		"result=" + ("ok" if match_ok else ("write_failed" if not ok else "mismatch"))])


## Change to another valid value, read it back from the system, put the old one back.
func _probe(id: String) -> void:
	var c = controls.control(id)
	if c == null:
		_unknown(id)
		return
	if not c.available:
		out(["probe", id, "result=skipped", "reason=" + str(c.reason)])
		return
	var from: Variant = await _fresh(c)
	var to: Variant = alt_value(c, from)
	if from == null or to == null:
		out(["probe", id, "result=skipped", "reason=no value to change to (now %s)" % js(from)])
		return
	var saved := snapshot_files(saved_dir())
	# what the provider wants back byte for byte (InputPlumber's live profile text), and the
	# controls this one requires (gpu_clock switches gpu_level to manual)
	var prov: Object = c.get_meta("provider") if c.has_meta("provider") else null
	var snap: Dictionary = prov.probe_snapshot() if prov != null and prov.has_method("probe_snapshot") else {}
	var req := {}
	for r in c.requires:
		var rc = controls.control(r)
		if rc != null and rc.available:
			req[r] = await _fresh(rc)
	var ok := await _write(id, to)
	var back: Variant = await _fresh(c)
	# order matters: the probed value first (gpu_clock goes back while the GPU is still in
	# manual), then what it required (gpu_level back to auto), and only then the read
	# that decides "restored" (the Ally read 850 before the level went back)
	var put_back := false
	var restored: Variant = null
	for step in restore_steps(id, req.keys()):
		match step[0]:
			"write":
				put_back = await _write(id, from)
			"provider":
				if not snap.is_empty():
					prov.probe_restore(snap)
			"required":
				var rc = controls.control(step[1])
				if req[step[1]] != null and not same(rc, await _fresh(rc), req[step[1]]):
					await _write(step[1], req[step[1]])
			"read":
				restored = await _fresh(c)
	# a put-back leaves no trace: GameCove's saved InputPlumber layout as it was
	restore_files(saved_dir(), saved)
	var result := "ok"
	if not ok:
		result = "write_failed"
	elif not same(c, back, c.coerce(to)):
		result = "mismatch"
	if not put_back or not same(c, restored, from):
		result += ",not_restored"
	_failed = _failed or result != "ok"
	out(["probe", id, "result=" + result, "from=" + js(from), "to=" + js(to), "read=" + js(back), "restored=" + js(restored)])


## A per-game value goes on at game start and comes off at game end (precedence:
## game > source > global), with a throw-away game key that's removed afterwards.
func _profile_test(id: String, v: Variant) -> void:
	var c = controls.control(id)
	if c == null or profiles == null:
		_unknown(id)
		return
	if not c.available or not c.per_game:
		out(["profile", id, "result=skipped", "reason=" + (str(c.reason) if not c.available else "not saved in profiles")])
		return
	var before: Variant = await _fresh(c)
	profiles.set_layer(TEST_GAME, "", {id: v})
	profiles.game_started({"key": TEST_GAME, "title": "GameCove hardware test"})
	var during: Variant = await _fresh(c)
	profiles.game_ended({"key": TEST_GAME})
	var after: Variant = await _fresh(c)
	profiles.reset(TEST_GAME, "*")
	var ok: bool = same(c, during, c.coerce(v)) and same(c, after, before)
	_failed = _failed or not ok
	out(["profile", id, "result=" + ("ok" if ok else "mismatch"), "before=" + js(before), "game=" + js(during), "after=" + js(after)])


## The AC and battery layers applied by a charger change (Profiles.set_plugged, what
## Power.changed calls), then the user's own layers and the real source put back.
func _source_test(id: String, on_ac: Variant, on_battery: Variant) -> void:
	var c = controls.control(id)
	if c == null or profiles == null:
		_unknown(id)
		return
	if not c.available or not c.per_game:
		out(["source", id, "result=skipped", "reason=" + (str(c.reason) if not c.available else "not saved in profiles")])
		return
	var real_source: String = profiles.source
	var saved_ac: Dictionary = (profiles.layer("", "ac") as Dictionary).duplicate(true)
	var saved_bat: Dictionary = (profiles.layer("", "battery") as Dictionary).duplicate(true)
	var before: Variant = await _fresh(c)
	var ac_layer := saved_ac.duplicate(true)
	ac_layer[id] = on_ac
	var bat_layer := saved_bat.duplicate(true)
	bat_layer[id] = on_battery
	profiles.set_layer("", "ac", ac_layer)
	profiles.set_layer("", "battery", bat_layer)
	profiles.set_plugged(true)
	profiles.apply_now("hardware test: AC")
	var read_ac: Variant = await _fresh(c)
	profiles.set_plugged(false)
	var read_bat: Variant = await _fresh(c)
	profiles.set_layer("", "ac", saved_ac)
	profiles.set_layer("", "battery", saved_bat)
	profiles.source = real_source
	await _write(id, before)
	var after: Variant = await _fresh(c)
	var ok: bool = same(c, read_ac, c.coerce(on_ac)) and same(c, read_bat, c.coerce(on_battery)) and same(c, after, before)
	_failed = _failed or not ok
	out(["source", id, "result=" + ("ok" if ok else "mismatch"), "ac=" + js(read_ac), "battery=" + js(read_bat),
		"restored=" + js(after), "real_source=" + real_source])


# ---- worker plumbing ----------------------------------------------------------

## Waits until every job queued on the Controls worker so far has run.
func _barrier() -> void:
	var done := [false]
	controls.run_on_worker(func(): (func(): done[0] = true).call_deferred())
	while not done[0]:
		await get_tree().process_frame


## Reads the control again from the system (on the worker, like the UI does).
func _fresh(c: RefCounted) -> Variant:
	var box := [null]
	controls.run_on_worker(func():
		c.detect()
		box[0] = c.read())
	await _barrier()
	return box[0]


func _write(id: String, v: Variant) -> bool:
	_signal_hit = []
	var on_ok := func(i: String, _v: Variant) -> void:
		if i == id:
			_signal_hit.append(true)
	var on_fail := func(i: String, _v: Variant) -> void:
		if i == id:
			_signal_hit.append(false)
	controls.control_changed.connect(on_ok)
	controls.control_failed.connect(on_fail)
	controls.set_value(id, v)
	await _barrier()
	await get_tree().process_frame   # the deferred signal
	controls.control_changed.disconnect(on_ok)
	controls.control_failed.disconnect(on_fail)
	return _signal_hit.size() > 0 and bool(_signal_hit[0])


# ---- pure helpers (tested) --------------------------------------------------------

## How a probe puts things back, in order: the probed control's own value first (a GPU
## clock goes back while the GPU is still in manual), then the controls it required (the
## GPU level back to auto), then the provider's exact raw snapshot, and only then the read
## that decides "restored" (the Ally read 850 because it read before the level went back).
static func restore_steps(id: String, required: Array) -> Array:
	var out: Array = [["write", id]]
	for r in required:
		out.append(["required", r])
	# the provider's raw snapshot last: going back to GPU level auto makes steamos-manager
	# write its own window, which the snapshot then corrects (min_freq 850 -> 900 on the Claw)
	out.append(["provider"])
	out.append(["read", id])
	return out


## Where controller writes save the everyday InputPlumber layout (input/backend.gd profile_path()).
static func saved_dir(home := "") -> String:
	return (home if home != "" else OS.get_environment("HOME")) + "/.config/inputplumber/profiles/gamecove"


## {relative path: bytes} of every file under dir.
static func snapshot_files(dir: String, rel := "") -> Dictionary:
	var out := {}
	var d := DirAccess.open(dir.path_join(rel))
	if d == null:
		return out
	for f in d.get_files():
		out[rel.path_join(f)] = FileAccess.get_file_as_bytes(dir.path_join(rel).path_join(f))
	for sub in d.get_directories():
		out.merge(snapshot_files(dir, rel.path_join(sub)))
	return out


## Puts dir back to a snapshot_files() result: new files go (and folders left empty), changed ones get their bytes back.
static func restore_files(dir: String, before: Dictionary) -> void:
	var now := snapshot_files(dir)
	for f in now:
		if not before.has(f):
			DirAccess.remove_absolute(dir.path_join(f))
			var parent := dir.path_join(f).get_base_dir()
			while parent.begins_with(dir) and parent != dir and DirAccess.get_files_at(parent).is_empty() and DirAccess.get_directories_at(parent).is_empty():
				DirAccess.remove_absolute(parent)
				parent = parent.get_base_dir()
		elif now[f] != before[f]:
			var w := FileAccess.open(dir.path_join(f), FileAccess.WRITE)
			if w != null:
				w.store_buffer(before[f])
				w.close()
	for f in before:
		if not now.has(f):
			DirAccess.make_dir_recursive_absolute(dir.path_join(f).get_base_dir())
			var w := FileAccess.open(dir.path_join(f), FileAccess.WRITE)
			if w != null:
				w.store_buffer(before[f])
				w.close()
	if before.is_empty() and DirAccess.dir_exists_absolute(dir) and DirAccess.get_files_at(dir).is_empty() and DirAccess.get_directories_at(dir).is_empty():
		DirAccess.remove_absolute(dir)


static func describe(c: RefCounted) -> Array:
	var shape := ""
	match str(c.kind):
		"slider":
			shape = "%s..%s step %s %s" % [c.min_value, c.max_value, c.step, c.unit]
		"choice":
			var vals := []
			for o in c.options:
				vals.append(js(o.get("value") if o is Dictionary else o))
			shape = "|".join(PackedStringArray(vals))
	return ["control", str(c.id), str(c.group), str(c.kind), "available=" + yn(c.available),
		"value=" + js(c.value), "root=" + yn(c.needs_root), "per_game=" + yn(c.per_game),
		"shape=" + shape.strip_edges(), "reason=" + ("" if c.available else str(c.reason))]


## Another valid value to change to (null when there's none to try).
static func alt_value(c: RefCounted, now: Variant) -> Variant:
	match str(c.kind):
		"toggle":
			return null if now == null else not bool(now)
		"slider":
			if not (now is int or now is float):
				return null
			var s: float = c.step if c.step > 0.0 else maxf((c.max_value - c.min_value) / 10.0, 1.0)
			var up := float(now) + s
			return c.coerce(up if up <= c.max_value else float(now) - s)
		"choice":
			for o in c.options:
				var ov: Variant = o.get("value") if o is Dictionary else o
				if c.coerce(ov) != null and not same(c, ov, now):
					return ov
			return null
		"color":
			return "#00ff00" if str(now).to_lower().trim_prefix("#") != "00ff00" else "#ff0000"
	return null


## Equal for this control: sliders within half a step (or 1 % of the range).
static func same(c: RefCounted, a: Variant, b: Variant) -> bool:
	if a == null or b == null:
		return a == b
	if str(c.kind) == "slider" and (a is int or a is float) and (b is int or b is float):
		var tol := maxf(c.step / 2.0, (c.max_value - c.min_value) / 100.0)
		return absf(float(a) - float(b)) <= tol + 0.0001
	if (a is int or a is float) and (b is int or b is float):
		return is_equal_approx(float(a), float(b))
	if str(c.kind) == "color":
		return str(a).to_lower().trim_prefix("#") == str(b).to_lower().trim_prefix("#")
	if typeof(a) != typeof(b):
		return str(a) == str(b)
	return a == b


## A JSON value from the command line; anything that isn't JSON is a string.
static func parse_value(text: String) -> Variant:
	var j := JSON.new()
	if j.parse(text) == OK:
		return j.data
	return text


static func js(v: Variant) -> String:
	return JSON.stringify(v).replace("\t", " ").replace("\n", " ")


static func yn(b: bool) -> String:
	return "yes" if b else "no"


static func line(fields: Array) -> String:
	var parts := PackedStringArray()
	for f in fields:
		parts.append(str(f).replace("\t", " ").replace("\n", " "))
	return "\t".join(parts)


func out(fields: Array) -> void:
	print(line(fields))


func _unknown(id: String) -> void:
	_failed = true
	out(["error", id, "no such control (or Profiles missing)"])


func _usage() -> void:
	_failed = true
	out(["error", "usage", "--controls list | get <id>... | set <id> <json> | probe <id>... | profile-test <id> <json> | source-test <id> <json ac> <json battery>"])
