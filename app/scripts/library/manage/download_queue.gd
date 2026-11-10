extends RefCounted
## The download queue for Epic, GOG and Amazon: one job at a time by default
## (max_parallel), pause / resume / cancel, progress from the tool's output, and
## a saved copy so jobs survive an app restart. legendary, gogdl and nile all
## pick up a stopped download where it left off when run again with the same
## command, so pause = stop the process, resume = run the step again.
##
## A job runs its plan's steps in order (StoreCommands). A "probe" step asks the
## tool how big the game is; if the install folder hasn't got that much space
## the job fails before downloading anything. A probe that fails (offline, old
## tool) doesn't stop the job: the tools check space themselves too.
##
## A move across drives (StoreCommands.move_steps) is a copy, a rename and a delete. Only
## the copy may be paused or cancelled: a step marked "no_stop" can't be, and neither can a
## job that has reached one (can_stop()), so a game is never left half in each place. A
## step's "cleanup" command runs when the job is cancelled or fails on that step (the half
## copy goes); a step with "done_if" {"gone", "there"} is skipped when it already happened
## (the app ended right after the rename).
##
## Steam downloads aren't here: Steam runs its own queue (SteamBackend reports it).
##
## Job: {"id", "key", "action", "title", "state", "steps", "step", "progress",
##       "error", "finalize", "size": bytes or 0}
## state: queued | running | paused | done | failed | cancelled

signal job_changed(job: Dictionary)
signal job_progress(job: Dictionary)
signal job_finished(job: Dictionary)

const SettingsFile := preload("res://scripts/system/settings_file.gd")
const Progress := preload("res://scripts/library/manage/progress.gd")
const Disk := preload("res://scripts/library/manage/disk.gd")

const QUEUED := "queued"
const RUNNING := "running"
const PAUSED := "paused"
const DONE := "done"
const FAILED := "failed"
const CANCELLED := "cancelled"
const TAIL_LINES := 20

## Anything with start(cmd, env) -> handle, stop(handle), and line/exited signals.
var runner: Object
var max_parallel := 1
## Where the queue is saved ("" = not saved).
var save_path := ""
## Restored jobs that were running start again by themselves.
var auto_resume := true
## func(path) -> free bytes (-1 unknown). Swapped in tests.
var free_space := func(path: String) -> int: return Disk.free_bytes(path)

var jobs: Array[Dictionary] = []
var _handles := {}   # runner handle -> job id
var _next_id := 0


func _init(job_runner: Object = null) -> void:
	if job_runner != null:
		set_runner(job_runner)


func set_runner(job_runner: Object) -> void:
	runner = job_runner
	runner.line.connect(_on_line)
	runner.exited.connect(_on_exit)


## Queues `plan` (StoreCommands.plan) for game `key`. Returns the job, or {} if the
## game already has an unfinished job.
func add(key: String, action: String, plan: Dictionary, title := "") -> Dictionary:
	if not job_for(key).is_empty():
		return {}
	_next_id += 1
	var job := {"id": _next_id, "key": key, "action": action, "title": title, "state": QUEUED,
		"steps": plan.get("steps", []), "step": 0, "progress": Progress.empty(), "error": "",
		"finalize": plan.get("finalize", {}), "size": 0, "tail": [], "handle": 0, "stopping": ""}
	jobs.append(job)
	job_changed.emit(job)
	_save()
	_pump()
	return job


## The unfinished job for a game, or {}.
func job_for(key: String) -> Dictionary:
	for j in jobs:
		if j["key"] == key:
			return j
	return {}


## Unfinished jobs in queue order, as copies safe to hand to the UI.
func snapshot() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for j in jobs:
		out.append(public(j))
	return out


static func public(j: Dictionary) -> Dictionary:
	return {"key": j["key"], "action": j["action"], "title": j["title"], "state": j["state"],
		"progress": j["progress"].duplicate(), "error": j["error"], "size": j["size"]}


## False once the job has reached a step that must run to the end (the rename and what
## follows in a move): pausing or cancelling there would leave the game half moved.
func can_stop(key: String) -> bool:
	var j := job_for(key)
	if j.is_empty():
		return false
	var steps: Array = j["steps"]
	for i in mini(int(j["step"]) + 1, steps.size()):
		if steps[i] is Dictionary and bool(steps[i].get("no_stop", false)):
			return false
	return true


## Runs the current step's clean-up command, if it has one (not followed: it's quick, and
## failing leaves a folder whose name says what it is).
func _cleanup(j: Dictionary) -> void:
	var steps: Array = j["steps"]
	if int(j["step"]) >= steps.size() or not steps[j["step"]] is Dictionary:
		return
	var c: Variant = steps[j["step"]].get("cleanup")
	if c is Array and not c.is_empty():
		runner.start(c, {})


func pause(key: String) -> bool:
	var j := job_for(key)
	if j.is_empty() or not can_stop(key):
		return false
	if j["state"] == QUEUED:
		_set_state(j, PAUSED)
		return true
	if j["state"] == RUNNING:
		j["stopping"] = PAUSED
		runner.stop(j["handle"])
		return true
	return false


func resume(key: String) -> bool:
	var j := job_for(key)
	if j.is_empty() or j["state"] != PAUSED:
		return false
	_set_state(j, QUEUED)
	_pump()
	return true


## Stops and drops the job. A half-finished download stays on disk, so a later
## install of the same game continues from it.
func cancel(key: String) -> bool:
	var j := job_for(key)
	if j.is_empty() or not can_stop(key):
		return false
	if j["state"] == RUNNING:
		j["stopping"] = CANCELLED
		runner.stop(j["handle"])
		return true
	_cleanup(j)   # a copy that was paused half way
	_finish(j, CANCELLED)
	return true


## Moves a waiting job up (delta < 0) or down the queue.
func reorder(key: String, delta: int) -> bool:
	var j := job_for(key)
	if j.is_empty():
		return false
	var i := jobs.find(j)
	var to := clampi(i + delta, 0, jobs.size() - 1)
	if to == i:
		return false
	jobs.remove_at(i)
	jobs.insert(to, j)
	_save()
	_pump()
	return true


func running_count() -> int:
	var n := 0
	for j in jobs:
		if j["state"] == RUNNING:
			n += 1
	return n


func _pump() -> void:
	for j in jobs.duplicate():
		if running_count() >= max_parallel:
			return
		if j["state"] == QUEUED:
			_start_step(j)


func _start_step(j: Dictionary) -> void:
	var steps: Array = j["steps"]
	if j["step"] >= steps.size():
		_finish(j, DONE)
		return
	var s: Dictionary = steps[j["step"]]
	var done_if: Variant = s.get("done_if")
	if done_if is Dictionary and not DirAccess.dir_exists_absolute(str(done_if.get("gone", ""))) \
			and DirAccess.dir_exists_absolute(str(done_if.get("there", ""))):
		# it already happened (the app ended right after): on to the next step
		j["step"] += 1
		_start_step(j)
		return
	j["probe_out"] = ""
	j["stopping"] = ""
	j["state"] = RUNNING
	j["handle"] = runner.start(s["cmd"], s.get("env", {}))
	_handles[j["handle"]] = j["id"]
	job_changed.emit(j)
	_save()


func _job_by_handle(handle: int) -> Dictionary:
	var id: int = _handles.get(handle, -1)
	for j in jobs:
		if j["id"] == id:
			return j
	return {}


func _on_line(handle: int, text: String) -> void:
	var j := _job_by_handle(handle)
	if j.is_empty():
		return
	var tail: Array = j["tail"]
	tail.append(text)
	if tail.size() > TAIL_LINES:
		tail.pop_front()
	var s: Dictionary = j["steps"][j["step"]]
	if s["parser"] == "size":
		j["probe_out"] += text + "\n"
	elif s["parser"] != "none" and Progress.parse_line(s["parser"], text, j["progress"]):
		job_progress.emit(j)


func _on_exit(handle: int, code: int) -> void:
	var j := _job_by_handle(handle)
	_handles.erase(handle)
	if j.is_empty():
		return
	j["handle"] = 0
	if j["stopping"] == CANCELLED:
		_cleanup(j)
		_finish(j, CANCELLED)
		return
	if j["stopping"] == PAUSED:
		j["stopping"] = ""
		_set_state(j, PAUSED)
		_pump()
		return
	var s: Dictionary = j["steps"][j["step"]]
	if s["kind"] == "probe":
		j["size"] = Progress.parse_size(s["tool"], j["probe_out"]) if code == 0 else 0
		var base := str(j["finalize"].get("base", ""))
		if j["size"] > 0 and base != "":
			var free: int = free_space.call(base)
			if free >= 0 and free < j["size"]:
				j["error"] = "Not enough space in %s: needs %s, %s free" % [base, Disk.human(j["size"]), Disk.human(free)]
				_finish(j, FAILED)
				return
		if int(j["progress"]["bytes_total"]) <= 0:
			j["progress"]["bytes_total"] = j["size"]
	elif code != 0:
		var tail: Array = j["tail"]
		j["error"] = last_error(tail) if not tail.is_empty() else "Exited with code %d" % code
		_cleanup(j)
		_finish(j, FAILED)
		return
	j["step"] += 1
	if j["step"] >= (j["steps"] as Array).size():
		_finish(j, DONE)
	else:
		_start_step(j)


## The most useful line of a failed tool's output: its last ERROR/CRITICAL line, else the last line.
static func last_error(tail: Array) -> String:
	for i in range(tail.size() - 1, -1, -1):
		var t := str(tail[i])
		if "ERROR" in t or "CRITICAL" in t or "Error" in t:
			return t.strip_edges()
	return str(tail.back()).strip_edges()


func _set_state(j: Dictionary, state: String) -> void:
	j["state"] = state
	job_changed.emit(j)
	_save()


func _finish(j: Dictionary, state: String) -> void:
	j["state"] = state
	jobs.erase(j)
	job_changed.emit(j)
	job_finished.emit(j)
	_save()
	_pump()


func _save() -> void:
	if save_path == "":
		return
	var out: Array = []
	for j in jobs:
		out.append({"key": j["key"], "action": j["action"], "title": j["title"], "state": j["state"],
			"steps": j["steps"], "step": j["step"], "finalize": j["finalize"], "size": j["size"]})
	SettingsFile.save_json(save_path, {"version": 1, "jobs": out}, "\t")


## Reads the saved queue. Jobs that were running come back queued (auto_resume)
## or paused. `still_needed(job)` can drop jobs the store state has made pointless
## (an install of a game that's now installed). Call before anything is added.
func restore(still_needed := Callable()) -> void:
	if save_path == "" or not FileAccess.file_exists(save_path):
		return
	var data: Variant = SettingsFile.load_json(save_path)["data"]
	if not (data is Dictionary) or not (data.get("jobs") is Array):
		return
	for saved in data["jobs"]:
		if not (saved is Dictionary) or not (saved.get("steps") is Array):
			continue
		var state := str(saved.get("state", QUEUED))
		if state == RUNNING:
			state = QUEUED if auto_resume else PAUSED
		if not state in [QUEUED, PAUSED]:
			continue
		_next_id += 1
		var steps: Array = saved["steps"]
		for s in steps:
			if s is Dictionary and s.get("cmd") is Array:
				var c: Array[String] = []
				for x in s["cmd"]:
					c.append(str(x))
				s["cmd"] = c
		var j := {"id": _next_id, "key": str(saved.get("key", "")), "action": str(saved.get("action", "")),
			"title": str(saved.get("title", "")), "state": state, "steps": steps, "step": int(saved.get("step", 0)),
			"progress": Progress.empty(), "error": "", "finalize": saved.get("finalize", {}),
			"size": int(saved.get("size", 0)), "tail": [], "handle": 0, "stopping": ""}
		if still_needed.is_valid() and not still_needed.call(j):
			continue
		jobs.append(j)
	_save()
	_pump()
