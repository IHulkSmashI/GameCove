extends RefCounted
## The one way GameCove writes its settings files (review H9).
##
## Writes go to "<path>.tmp", are flushed, then renamed over the file: a crash or
## a dead battery leaves either the old file or the new one, never half of one.
## (Godot has no fsync; FileAccess.flush() hands the data to the kernel, and the
## rename-over-an-existing-file pattern is what ext4/btrfs order for us.)
##
## A file that exists, isn't empty and doesn't parse is never silently replaced:
## it is moved to "<path>.bad" (kept for the user or a bug report), the load gives
## empty settings, and every save of that path is refused for the rest of this
## run, so a default never lands on top of a value we couldn't read.
##
## One process-wide lock serialises every load-modify-save of the same files
## (Power's worker, the Controls worker and the main thread all write power.cfg).
## Use update_cfg() for a read-modify-write; load_cfg()/save_cfg() for stores
## that keep the ConfigFile in memory.
##
## Tests: reset_for_tests() forgets blocked paths.

static var _lock := Mutex.new()
static var _blocked := {}   # absolute path -> true: damaged on load, never saved this run


static func abs_path(path: String) -> String:
	return ProjectSettings.globalize_path(path) if path.begins_with("user://") or path.begins_with("res://") else path


## True when `path` was damaged on load this run (saves are refused).
static func blocked(path: String) -> bool:
	_lock.lock()
	var b := _blocked.has(abs_path(path))
	_lock.unlock()
	return b


static func reset_for_tests() -> void:
	_lock.lock()
	_blocked.clear()
	_lock.unlock()


## Moves a damaged file aside and blocks saving it.
static func _quarantine(path: String, why: String) -> void:
	var p := abs_path(path)
	_lock.lock()
	_blocked[p] = true
	_lock.unlock()
	DirAccess.rename_absolute(p, p + ".bad")
	push_warning("GameCove: %s couldn't be read (%s); kept it as %s.bad and won't save it until the next start" % [p, why, p])


static func _non_empty(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var n := f.get_length()
	if n == 0:
		# /proc-like files report 0; a settings file of 0 bytes is just empty
		return f.get_buffer(1).size() > 0
	return true


## The file as a ConfigFile; empty when missing, empty or damaged (then quarantined).
static func load_cfg(path: String) -> ConfigFile:
	var cfg := ConfigFile.new()
	_lock.lock()
	if FileAccess.file_exists(path):
		var err := cfg.load(path)
		if err != OK and _non_empty(path):
			cfg = ConfigFile.new()
			_quarantine(path, error_string(err))
	_lock.unlock()
	return cfg


## Writes `cfg` atomically. ERR_LOCKED when the file was damaged this run.
static func save_cfg(cfg: ConfigFile, path: String) -> Error:
	return save_text(path, cfg.encode_to_text())


## Loads, calls fn(cfg) and saves, all under the lock; fn returning false skips
## the save. Returns the save's result (OK when skipped).
static func update_cfg(path: String, fn: Callable) -> Error:
	_lock.lock()
	var cfg := load_cfg(path)
	var err := OK
	if fn.call(cfg) != false:
		err = save_cfg(cfg, path)
	_lock.unlock()
	return err


## {"ok": bool, "data": Variant}: data null when the file is missing or empty; ok false
## (and the file quarantined) when it exists and isn't JSON.
static func load_json(path: String) -> Dictionary:
	_lock.lock()
	var out := {"ok": true, "data": null}
	if FileAccess.file_exists(path):
		var text := FileAccess.get_file_as_string(path)
		if text.strip_edges() != "":
			var j := JSON.new()
			if j.parse(text) == OK:
				out["data"] = j.data
			else:
				out["ok"] = false
				_quarantine(path, "JSON line %d: %s" % [j.get_error_line(), j.get_error_message()])
	_lock.unlock()
	return out


## Quarantines a file whose JSON parsed but whose content the caller can't use
## (an unknown format from a newer build): never replaced by defaults.
static func reject(path: String, why: String) -> void:
	_lock.lock()
	if FileAccess.file_exists(path):
		_quarantine(path, why)
	_lock.unlock()


static func save_json(path: String, data: Variant, indent := "") -> Error:
	return save_text(path, JSON.stringify(data, indent, true) + ("\n" if indent != "" else ""))


static func save_text(path: String, text: String) -> Error:
	return save_bytes(path, text.to_utf8_buffer())


## Atomic write: <path>.tmp, flush, rename over <path>.
static func save_bytes(path: String, data: PackedByteArray) -> Error:
	var p := abs_path(path)
	_lock.lock()
	if _blocked.has(p):
		_lock.unlock()
		return ERR_LOCKED
	# never makes folders: an explicit path whose folder is missing fails; the owners of
	# the app's own folders (user://, ~/.config/...) create them
	var tmp := p + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		var e := FileAccess.get_open_error()
		_lock.unlock()
		return e if e != OK else ERR_CANT_OPEN
	f.store_buffer(data)
	f.flush()
	var werr := f.get_error()
	f.close()
	if werr != OK:
		DirAccess.remove_absolute(tmp)
		_lock.unlock()
		return werr
	var err := DirAccess.rename_absolute(tmp, p)
	if err != OK:
		DirAccess.remove_absolute(tmp)
	_lock.unlock()
	return err
