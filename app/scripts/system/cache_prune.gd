extends RefCounted
## Removes cache files nobody has refreshed in a long time (review 2, low 23: caches
## were never pruned). Plain files only, in `dir` and its direct subfolders; never
## follows links, never removes a folder. Safe on a worker thread (no nodes).

## Files in `dir` (and one level below) last modified more than `max_age_s` before
## `now`, and only those whose name ends with one of `exts`. Returns how many went.
static func prune(dir: String, max_age_s: int, now: int, exts: Array = [".json", ".jpg", ".png", ".webp"]) -> int:
	var n := 0
	var da := DirAccess.open(dir)
	if da == null:
		return 0
	da.include_hidden = false
	for f in da.get_files():
		n += _maybe(dir.path_join(f), max_age_s, now, exts)
	for sub in da.get_directories():
		if da.is_link(sub):
			continue
		var sd := DirAccess.open(dir.path_join(sub))
		if sd == null:
			continue
		for f in sd.get_files():
			n += _maybe(dir.path_join(sub).path_join(f), max_age_s, now, exts)
	return n


static func _maybe(path: String, max_age_s: int, now: int, exts: Array) -> int:
	if not exts.any(func(e: String) -> bool: return path.ends_with(e)):
		return 0
	var m := int(FileAccess.get_modified_time(path))
	if m > 0 and now - m > max_age_s and DirAccess.remove_absolute(path) == OK:
		return 1
	return 0


static var _tasks: Array[int] = []


## prune() on a WorkerThreadPool thread. main.gd calls wait_all() before quitting:
## a task still running when the engine shuts down aborts the process (CI caught it).
static func prune_later(dir: String, max_age_s: int) -> void:
	var now := int(Time.get_unix_time_from_system())
	_tasks.append(WorkerThreadPool.add_task(func(): prune(dir, max_age_s, now), false, "Cache prune"))


## Waits for every prune started with prune_later (each one is quick).
static func wait_all() -> void:
	for id in _tasks:
		WorkerThreadPool.wait_for_task_completion(id)
	_tasks.clear()
