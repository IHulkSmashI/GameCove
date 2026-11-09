extends Node
## Registry of every Control (see control.gd). Autoload "Controls".
## Providers register at startup (register_provider), detection and reads run
## on one worker so nothing blocks the UI; results come back as signals on the
## main thread. Profiles (profiles.gd) use snapshot()/apply().
##
## Tests: var c = ControlsScript.new(); c.sync_mode = true; c.setup(ctx)
## then register controls; every call runs inline.

signal control_changed(id: String, value: Variant)
signal control_failed(id: String, value: Variant)
signal detected()

const ControlScript := preload("res://scripts/controls/control.gd")
const PROVIDERS_DIR := "res://scripts/controls/providers"
const GROUPS := ["power", "display", "perf", "audio", "controller", "system", "network"]

var ctx: Dictionary = {}
var sync_mode := false
var _controls: Dictionary = {}     # id -> Control
var _order: Array = []             # ids in registration order
var _jobs: Array = []
var _mutex := Mutex.new()
var _sem := Semaphore.new()
var _thread: Thread
var _quit := false


func _ready() -> void:
	if ctx.is_empty():
		setup({"sys_root": "", "runner": load("res://scripts/device/command_runner.gd").new(),
			"home": OS.get_environment("HOME"), "device": get_node_or_null("/root/Device")})
		load_providers()
		detect_all()


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


func setup(context: Dictionary) -> void:
	ctx = context
	for id in _order:
		_controls[id].ctx = ctx


func register(c: RefCounted) -> void:
	assert(c.id != "" and c.group in GROUPS, "control needs an id and a known group")
	if not _controls.has(c.id):
		_order.append(c.id)
	c.ctx = ctx
	_controls[c.id] = c


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


func value(id: String) -> Variant:
	var c = _controls.get(id)
	return c.value if c != null else null


## Detects and reads everything (worker). Emits detected().
func detect_all() -> void:
	_queue(func():
		for id in _order:
			var c = _controls[id]
			c.detect()
			c.read()
		_emit(detected, []))


## Sets one control (worker). Emits control_changed or control_failed.
func set_value(id: String, v: Variant) -> void:
	var c = _controls.get(id)
	if c == null:
		return
	_queue(func():
		if c.write(v):
			_emit(control_changed, [id, c.value])
		else:
			_emit(control_failed, [id, v]))


## {id: value} for every available per-game control (what a profile stores).
func snapshot(per_game_only := true) -> Dictionary:
	var out := {}
	for id in _order:
		var c = _controls[id]
		if c.available and c.value != null and (c.per_game or not per_game_only):
			out[id] = c.value
	return out


## Applies a {id: value} map, highest apply_order first, skipping values that
## already match and unknown/unavailable ids. Worker.
func apply(values: Dictionary) -> void:
	var ids := values.keys().filter(func(i): return _controls.has(i))
	ids.sort_custom(func(a, b): return _controls[a].apply_order > _controls[b].apply_order)
	_queue(func():
		for id in ids:
			var c = _controls[id]
			if not c.available or c.value == c.coerce(values[id]):
				continue
			if c.write(values[id]):
				_emit(control_changed, [id, c.value])
			else:
				_emit(control_failed, [id, values[id]]))


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
		if _quit:
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
		(func(): _do_emit(sig, args)).call_deferred()


func _do_emit(sig: Signal, args: Array) -> void:
	match args.size():
		0: sig.emit()
		2: sig.emit(args[0], args[1])
