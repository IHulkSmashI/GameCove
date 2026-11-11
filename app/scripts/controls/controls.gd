extends Node
## Registry of every Control (see control.gd). Autoload "Controls".
## Providers register at startup (register_provider), detection and reads run
## on one worker so nothing blocks the UI; results come back as signals on the
## main thread. Profiles (profiles.gd) use snapshot()/apply().
##
## Tests: var c = ControlsScript.new(); c.sync_mode = true; c.setup(ctx)
## then register controls; every call runs inline.
##
## Threads (review S4-1): hooks change a Control's fields on the worker, so the main
## thread never reads them for snapshot() / value(). Each worker job commits what it
## changed to a cache under a mutex when it finishes (one commit per job), and those two
## read the cache: no torn reads, and never a state half-way through an apply.

signal control_changed(id: String, value: Variant)
signal control_failed(id: String, value: Variant)
signal detected()

const ControlScript := preload("res://scripts/controls/control.gd")
const PROVIDERS_DIR := "res://scripts/controls/providers"
const GROUPS := ["power", "display", "perf", "audio", "controller", "system", "network"]

## Stands in when a context comes without a runner (tests, previews): every
## program "isn't installed", so hooks see a bare system and never run anything.
class NoRunner extends RefCounted:
	func run(_program: String, _args: PackedStringArray) -> Dictionary:
		return {"code": 127, "out": ""}


var ctx: Dictionary = {}
var sync_mode := false
var _controls: Dictionary = {}     # id -> Control
var _order: Array = []             # ids in registration order
var _jobs: Array = []
var _mutex := Mutex.new()
var _sem := Semaphore.new()
var _thread: Thread
var _quit := false
var _cache: Dictionary = {}        # id -> {"available", "value", "per_game"}, committed per worker job
var _cache_mutex := Mutex.new()


func _ready() -> void:
	if ctx.is_empty():
		setup({"sys_root": "", "runner": load("res://scripts/device/command_runner.gd").new(),
			"home": OS.get_environment("HOME"), "device": get_node_or_null("/root/Device"),
			"open_uri": open_uri})
		load_providers()
		detect_all()


## ctx["open_uri"]: a provider asks for a steam:// or https:// link to be opened
## (Lossless Scaling's store page); providers run on the worker and never reach
## the desktop themselves. Only these two schemes; opened on the main thread.
func open_uri(uri: String) -> bool:
	if not (uri.begins_with("steam://") or uri.begins_with("https://")):
		return false
	call_deferred("_shell_open", uri)
	return true


func _shell_open(uri: String) -> void:
	OS.shell_open(uri)


## Every script in providers/ is a provider (new() then controls()), so each
## area adds its own file without touching a shared list. Exports keep scripts
## as *.gd.remap; both spellings load.
func load_providers(dir := PROVIDERS_DIR) -> void:
	var names := []
	for f in DirAccess.get_files_at(dir):
		var n := f.trim_suffix(".remap")
		if n.ends_with(".gd") and not names.has(n):
			names.append(n)
	names.sort()
	for n in names:
		var p = load(dir.path_join(n)).new()
		if p.has_method("setup"):
			p.setup(ctx)
		register_provider(p)


func _exit_tree() -> void:
	if _thread != null and _thread.is_started():
		_mutex.lock(); _quit = true; _mutex.unlock()
		_sem.post()
		_thread.wait_to_finish()


## ctx.runner is always set afterwards (NoRunner when the context has none), so
## providers and their helpers can call it without checking.
func setup(context: Dictionary) -> void:
	ctx = context
	if ctx.get("runner") == null:
		ctx["runner"] = NoRunner.new()
	# the game per-game controls act on: made here, before any worker reads the
	# context, so changing the game later never adds or erases a context key
	load("res://scripts/controls/game_scope.gd").ensure(ctx)
	for id in _order:
		_controls[id].ctx = ctx


func register(c: RefCounted) -> void:
	assert(c.id != "" and c.group in GROUPS, "control needs an id and a known group")
	if not _controls.has(c.id):
		_order.append(c.id)
	c.ctx = ctx
	_controls[c.id] = c
	_commit([c.id])


## A provider is any object with controls() -> Array of Control.
func register_provider(p: Object) -> void:
	for c in p.controls():
		register(c)


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


## Control.describe() as of the last finished worker job (a copy: safe while the
## worker changes the control; the UI reads this, never the live fields, or a
## detection replacing `options` mid-read crashes it).
func describe_cached(id: String) -> Dictionary:
	_cache_mutex.lock()
	var e: Variant = _cache.get(id)
	var d: Dictionary = e["desc"].duplicate(true) if e != null and e.has("desc") else {}
	_cache_mutex.unlock()
	return d


## `v` made valid for the control as of the last finished worker job (Control.coerce on the
## committed description): safe on the main thread while a detection replaces the live
## control's options (that read crashed, review M14). null when unknown or invalid.
func coerce(id: String, v: Variant) -> Variant:
	var c = _controls.get(id)
	var d := describe_cached(id)
	if c == null or d.is_empty():
		return null
	var out: Variant = ControlScript.coerce_spec(d, v)
	if out != null and c.normalize.is_valid():
		out = c.normalize.call(out)
	return out


## Available as of the last finished worker job.
func available(id: String) -> bool:
	_cache_mutex.lock()
	var e: Variant = _cache.get(id)
	var a: bool = e != null and bool(e["available"])
	_cache_mutex.unlock()
	return a


## The control's value as of the last finished worker job (safe on any thread).
func value(id: String) -> Variant:
	_cache_mutex.lock()
	var e: Variant = _cache.get(id)
	var v: Variant = _copy(e["value"]) if e != null else null
	_cache_mutex.unlock()
	return v


## Detects and reads everything (worker). Emits detected().
## Detections asked for / finished (main thread): a caller that needs the state
## after its own detection waits until detected_seq reaches the requested_seq
## it saw (an older detection still running may emit `detected` first).
var requested_seq := 0
var detected_seq := 0


func detect_all() -> void:
	requested_seq += 1
	var n := requested_seq
	_queue(func():
		for id in _order:
			var c = _controls[id]
			c.detect()
			c.read()
		_commit(_order)
		_emit_detected(n))


func _emit_detected(n: int) -> void:
	if sync_mode:
		detected_seq = maxi(detected_seq, n)
		detected.emit()
	else:
		# A deferred method, not a lambda: if this node is freed first, Godot drops
		# the call (a lambda would run on whatever object reuses the memory).
		call_deferred("_do_detected", n)


func _do_detected(n: int) -> void:
	detected_seq = maxi(detected_seq, n)
	detected.emit()


## Sets one control (worker). Emits control_changed or control_failed.
func set_value(id: String, v: Variant) -> void:
	var c = _controls.get(id)
	if c == null:
		return
	_queue(func():
		var done: bool = c.write(v)
		var moved: Array = _reread_affected([c]) if done else []
		_commit([id] + moved)
		if done:
			_emit(control_changed, [id, c.value])
			for m in moved:
				_emit(control_changed, [m, _controls[m].value])
		else:
			_emit(control_failed, [id, v]))


## Worker: reads again what the written controls `affects` (not the written ones
## themselves); returns the ids whose value changed.
func _reread_affected(written: Array) -> Array:
	var skip := {}
	for c in written:
		skip[c.id] = true
	var out := []
	for c in written:
		for a in c.affects:
			var o = _controls.get(a)
			if o == null or skip.has(a):
				continue   # unavailable ones too: the write may be what makes them usable
			skip[a] = true
			var before: Variant = o.value
			var shape := [o.available, o.min_value, o.max_value, o.options.size()]
			# detect too: a range follows the other setting (SPPT never under the TDP)
			o.detect()
			o.read()
			if o.value != before or shape != [o.available, o.min_value, o.max_value, o.options.size()]:
				out.append(a)
	return out


## {id: value} for every available per-game control (what a profile stores).
## From the cache: safe while the worker runs, and never half-way through an apply.
func snapshot(per_game_only := true) -> Dictionary:
	var out := {}
	_cache_mutex.lock()
	for id in _order:
		var e: Variant = _cache.get(id)
		if e != null and e["available"] and e["value"] != null and (e["per_game"] or not per_game_only):
			out[id] = _copy(e["value"])
	_cache_mutex.unlock()
	return out


## Copies what the worker changed into the cache (end of each worker job).
func _commit(ids: Array) -> void:
	_cache_mutex.lock()
	for id in ids:
		var c = _controls.get(id)
		if c != null:
			_cache[id] = {"available": bool(c.available), "value": _copy(c.value), "per_game": bool(c.per_game),
				"desc": c.describe().duplicate(true)}
	_cache_mutex.unlock()


static func _copy(v: Variant) -> Variant:
	return v.duplicate(true) if v is Array or v is Dictionary else v


## Applies a {id: value} map, highest apply_order first, skipping values that
## already match and unknown/unavailable ids. Worker. `force` writes even values
## that match what the control last saw (after a resume the firmware may have
## reset the hardware behind our back).
func apply(values: Dictionary, force := false) -> void:
	var ids := values.keys().filter(func(i): return _controls.has(i))
	ids.sort_custom(func(a, b): return _controls[a].apply_order > _controls[b].apply_order)
	_queue(func():
		var out := []
		for id in ids:
			var c = _controls[id]
			if not c.available or (not force and c.value == c.coerce(values[id])):
				continue
			out.append([id, c.write(values[id])])
		var written := out.filter(func(r): return r[1]).map(func(r): return _controls[r[0]])
		var moved: Array = _reread_affected(written).filter(func(m): return not values.has(m))
		# one commit for the whole apply: a snapshot never sees it half done
		_commit(ids + moved)
		for r in out:
			if r[1]:
				_emit(control_changed, [r[0], _controls[r[0]].value])
			else:
				_emit(control_failed, [r[0], values[r[0]]])
		for m in moved:
			_emit(control_changed, [m, _controls[m].value]))


## Runs `job` on the Controls worker after everything queued before it (e.g.
## changing ctx between a profile's apply and the next detect_all).
func run_on_worker(job: Callable) -> void:
	_queue(job)


func _queue(job: Callable) -> void:
	if sync_mode:
		job.call()
		return
	if _thread == null:
		_thread = Thread.new()
		_thread.start(_worker)
	_mutex.lock(); _jobs.append(job); _mutex.unlock()
	_sem.post()


func _worker() -> void:
	while true:
		_sem.wait()
		_mutex.lock()
		# quitting: finish what's queued first (a game's restore queued just before the
		# quit must still be written, review H2), then stop
		if _quit and _jobs.is_empty():
			_mutex.unlock()
			return
		var job: Callable = _jobs.pop_front() if not _jobs.is_empty() else Callable()
		_mutex.unlock()
		if job.is_valid():
			job.call()


func _emit(sig: Signal, args: Array) -> void:
	if sync_mode:
		_do_emit(sig, args)
	else:
		call_deferred("_do_emit", sig, args)


func _do_emit(sig: Signal, args: Array) -> void:
	match args.size():
		0: sig.emit()
		2: sig.emit(args[0], args[1])
