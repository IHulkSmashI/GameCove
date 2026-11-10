extends RefCounted
## The one way GameCove writes its settings files (review H9).
##
## Writes go to "<path>.<pid>.tmp", are flushed, then renamed over the file: a crash or
## a dead battery leaves either the old file or the new one, never half of one. The
## temp name carries the process id, so two processes saving the same file (a helper run
## next to the home screen) never write into each other's half-written copy; what a
## crashed process left is cleared on the first save of that file in a run.
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
## claim_instance() is the one-home-screen lock (run_mode.gd decides who asks).
##
## Tests: reset_for_tests() forgets blocked paths.

static var _lock := Mutex.new()
static var _blocked := {}   # absolute path -> true: damaged on load, never saved this run
static var _swept := {}     # absolute path -> true: leftover temp files looked for this run
## Tests only: when >= 0, at most this many bytes reach the .tmp file (a full disk).
static var test_write_limit := -1


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
	_swept.clear()
	test_write_limit = -1
	_lock.unlock()


## Moves a damaged file aside and blocks saving it.
static func _quarantine(path: String, why: String) -> void:
	var p := abs_path(path)
	_lock.lock()
	_blocked[p] = true
	_lock.unlock()
	var bad := p + ".bad"
	# a second damaged file never replaces the first copy (review 2, low 23)
	var n := 1
	while FileAccess.file_exists(bad) and n < 10:
		bad = "%s.bad.%d" % [p, n]
		n += 1
	DirAccess.rename_absolute(p, bad)
	push_warning("GameCove: %s couldn't be read (%s); kept it as %s and won't save it until the next start" % [p, why, bad])


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


## private: readable by this user only (0600 before any byte is written: API keys).
static func save_json(path: String, data: Variant, indent := "", private := false) -> Error:
	return save_text(path, JSON.stringify(data, indent, true) + ("\n" if indent != "" else ""), private)


static func save_text(path: String, text: String, private := false) -> Error:
	return save_bytes(path, text.to_utf8_buffer(), private)


## This process's temp file for `path`.
static func tmp_path(path: String) -> String:
	return "%s.%d.tmp" % [abs_path(path), OS.get_process_id()]


## Once per file and run: removes temp files of `p` that no live process owns (a crash in
## the middle of a save, or the fixed "<file>.tmp" of builds before the pid was in the name).
## Call with the lock held.
static func _sweep(p: String) -> void:
	if _swept.has(p):
		return
	_swept[p] = true
	var dir := p.get_base_dir()
	var name := p.get_file()
	for f in DirAccess.get_files_at(dir):
		if not f.begins_with(name + ".") or not f.ends_with(".tmp"):
			continue
		var mid := f.substr(name.length() + 1, f.length() - name.length() - 5)
		if f == name + ".tmp":
			DirAccess.remove_absolute(dir.path_join(f))
		elif mid.is_valid_int() and mid.to_int() != OS.get_process_id() and not DirAccess.dir_exists_absolute("/proc/" + mid):
			DirAccess.remove_absolute(dir.path_join(f))


## The one-home-screen lock: `lock` holds the pid of the GameCove that runs the home
## screen. Returns 0 when that is (now) `my_pid`, else the pid of the other, live one.
## A holder that is gone, or whose pid now belongs to another program, is replaced.
static func claim_instance(lock: String, my_pid: int = OS.get_process_id(), proc_root := "/proc") -> int:
	var p := abs_path(lock)
	var mine := _read_all(proc_root.path_join(str(my_pid)).path_join("comm")).strip_edges()
	for attempt in 2:
		var held := FileAccess.get_file_as_string(p).strip_edges() if FileAccess.file_exists(p) else ""
		if held.is_valid_int() and held.to_int() > 0 and held.to_int() != my_pid:
			var theirs := _read_all(proc_root.path_join(held).path_join("comm")).strip_edges()
			if theirs != "" and theirs == mine:
				return held.to_int()
		if held == str(my_pid):
			return 0
		DirAccess.make_dir_recursive_absolute(p.get_base_dir())
		if save_text(p, "%d\n" % my_pid) != OK:
			return 0   # a settings folder that can't be written: nothing to protect by stepping aside
		# two starting in the same instant: the one whose pid is in the file after both wrote keeps it
	return 0


## A file read to its real end (/proc files report a size of 0).
static func _read_all(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var buf := PackedByteArray()
	while buf.size() < 65536:
		var chunk := f.get_buffer(4096)
		buf.append_array(chunk)
		if chunk.size() < 4096:
			break
	return buf.get_string_from_utf8()


## Atomic write: <path>.<pid>.tmp, flush, rename over <path>.
## A short write (a full disk: the kernel can accept the bytes into the page cache
## and still drop them, and Godot's close() reports nothing) never replaces the
## file: the .tmp must hold exactly `data` before the rename (review 2, problem 2).
static func save_bytes(path: String, data: PackedByteArray, private := false) -> Error:
	var p := abs_path(path)
	_lock.lock()
	if _blocked.has(p):
		_lock.unlock()
		return ERR_LOCKED
	# never makes folders: an explicit path whose folder is missing fails; the owners of
	# the app's own folders (user://, ~/.config/...) create them
	_sweep(p)
	var tmp := tmp_path(p)
	if private:
		var e0 := FileAccess.open(tmp, FileAccess.WRITE)
		if e0 != null:
			e0.close()
			FileAccess.set_unix_permissions(tmp, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		var e := FileAccess.get_open_error()
		_lock.unlock()
		return e if e != OK else ERR_CANT_OPEN
	var stored := f.store_buffer(data if test_write_limit < 0 else data.slice(0, mini(test_write_limit, data.size())))
	f.flush()
	var werr := f.get_error()
	f.close()
	if werr == OK and not stored:
		werr = ERR_FILE_CANT_WRITE
	if werr == OK and _size_of(tmp) != data.size():
		werr = ERR_FILE_CANT_WRITE
	if werr != OK:
		DirAccess.remove_absolute(tmp)
		_lock.unlock()
		push_warning("GameCove: couldn't write %s (%s); kept the old file" % [p, error_string(werr)])
		return werr
	var err := DirAccess.rename_absolute(tmp, p)
	if err != OK:
		DirAccess.remove_absolute(tmp)
	_lock.unlock()
	return err


## Bytes in `path` as the file system reports them after close (-1 when unreadable).
static func _size_of(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var n := f.get_length()
	f.close()
	return n
