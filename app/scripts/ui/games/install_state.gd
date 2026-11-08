extends Node
## What every game is going through right now, for the screens: install state
## per game, live progress, the download queue and what finished this session.
## Listens to Library's store signals (or a fake with the same signals) and
## turns them into two signals the UI can afford:
##   changed      something structural happened (state, queue): rebuild badges
##   progress(key) new numbers for one job, at most PROGRESS_HZ per job
## Nothing runs while nothing downloads.

const TG := preload("res://scripts/ui/texts_games.gd")

signal changed
signal progress(key: String)
signal finished(key: String, action: String, ok: bool)

const PROGRESS_MS := 1000
const DONE_MAX := 12

var library: Object
## key -> state string (install_state_changed)
var states := {}
## key -> {"bytes_done", "bytes_total", "rate", "eta", "percent", "unit"}
var live := {}
## Library.downloads() snapshot, queue order.
var queue: Array = []
## [{"key", "title", "action", "ok", "message", "at"}], newest first.
var done: Array = []
## Wall clock, swapped in tests.
var clock: Callable = func() -> int: return int(Time.get_unix_time_from_system())
var _last_emit := {}
var _actions := {}    # key -> last action seen in the queue
var _titles := {}


func attach(lib: Object) -> void:
	library = lib
	if lib == null:
		return
	for s in ["download_progress", "install_state_changed", "queue_changed", "action_failed"]:
		if not lib.has_signal(s):
			return
	lib.download_progress.connect(on_progress)
	lib.install_state_changed.connect(on_state)
	lib.queue_changed.connect(refresh_queue)
	lib.action_failed.connect(on_failed)
	refresh_queue()


func refresh_queue() -> void:
	queue = []
	if library != null and library.has_method("downloads"):
		for d in library.downloads():
			queue.append(d)
			var k := str(d.get("key", ""))
			_actions[k] = str(d.get("action", "install"))
			_titles[k] = str(d.get("title", ""))
			var p: Variant = d.get("progress", {})
			if p is Dictionary and not p.is_empty() and not live.has(k):
				live[k] = p.duplicate()
			if not states.has(k) or not states[k] in TG.BUSY:
				var st := str(d.get("state", "queued"))
				states[k] = {"running": _running_state(_actions[k]), "paused": "paused"}.get(st, "queued")
	changed.emit()


static func _running_state(action: String) -> String:
	return {"install": "installing", "update": "updating", "verify": "verifying", "move": "moving", "uninstall": "uninstalling"}.get(action, "downloading")


func on_progress(key: String, bytes_done: int, bytes_total: int, rate: float, eta: int) -> void:
	var p: Dictionary = live.get(key, {})
	p["bytes_done"] = bytes_done
	p["bytes_total"] = bytes_total
	p["rate"] = rate
	p["eta"] = eta
	p["percent"] = (100.0 * bytes_done / bytes_total) if bytes_total > 0 else -1.0
	live[key] = p
	if states.get(key, "") in ["", "queued", "not_installed", "installed", "update_required"]:
		states[key] = _running_state(_actions.get(key, "install"))
	var now := Time.get_ticks_msec()
	if bytes_total > 0 and bytes_done >= bytes_total or now - int(_last_emit.get(key, -PROGRESS_MS)) >= PROGRESS_MS:
		_last_emit[key] = now
		progress.emit(key)


func on_state(key: String, state: String) -> void:
	var was: String = states.get(key, "")
	states[key] = state
	if was in TG.BUSY and not state in TG.BUSY:
		var ok := state != "failed"
		_finish(key, _actions.get(key, _action_from_state(was)), ok, "")
	if not state in TG.BUSY:
		live.erase(key)
	changed.emit()


func on_failed(key: String, action: String, message: String) -> void:
	if states.get(key, "") in TG.BUSY:
		states[key] = "failed"
		live.erase(key)
		_finish(key, action, false, message)
		changed.emit()


func _finish(key: String, action: String, ok: bool, message: String) -> void:
	done.push_front({"key": key, "title": _titles.get(key, ""), "action": action, "ok": ok, "message": message, "at": clock.call()})
	if done.size() > DONE_MAX:
		done.resize(DONE_MAX)
	finished.emit(key, action, ok)


static func _action_from_state(state: String) -> String:
	return {"installing": "install", "updating": "update", "verifying": "verify", "moving": "move", "uninstalling": "uninstall"}.get(state, "install")


func clear_done() -> void:
	done.clear()
	changed.emit()


# ------------------------------------------------------------ reading

func state_of(key: String) -> String:
	return states.get(key, "")


func is_busy(key: String) -> bool:
	return state_of(key) in TG.BUSY


## The game's queue entry or {}.
func job(key: String) -> Dictionary:
	for d in queue:
		if str(d.get("key", "")) == key:
			return d
	return {}


## Progress numbers for a job: live signal numbers over the queue's snapshot.
func progress_of(key: String) -> Dictionary:
	var p: Dictionary = job(key).get("progress", {}).duplicate() if job(key).get("progress") is Dictionary else {}
	p.merge(live.get(key, {}), true)
	return p


## 0..1, -1 when unknown.
func fraction(key: String) -> float:
	return TG.fraction(progress_of(key))


func action_of(key: String) -> String:
	return str(job(key).get("action", _actions.get(key, _action_from_state(state_of(key)))))


func active_count() -> int:
	var n := 0
	for d in queue:
		if str(d.get("state", "")) != "paused":
			n += 1
	return n


## Mean progress over running jobs with known numbers; -1 if none.
func overall_fraction() -> float:
	var sum := 0.0
	var n := 0
	for d in queue:
		var f := fraction(str(d.get("key", "")))
		if f >= 0.0:
			sum += f
			n += 1
	return sum / n if n > 0 else -1.0


## Total download speed of running jobs, bytes/s.
func total_rate() -> float:
	var r := 0.0
	for d in queue:
		r += maxf(0.0, float(progress_of(str(d.get("key", ""))).get("rate", 0.0)))
	return r


## Copies of `games` with the fields badges read: download.progress while
## bytes move, update_available for update_required, install_state always.
func decorate(games: Array) -> Array:
	var out: Array = []
	for g in games:
		var key := str(g.get("key", ""))
		var st := state_of(key)
		if st == "" and job(key).is_empty():
			out.append(g)
			continue
		var c: Dictionary = g.duplicate()
		c["install_state"] = st
		if st == "update_required":
			c["update_available"] = true
		var f := fraction(key)
		if st in TG.RUNNING and f >= 0.0:
			c["download"] = {"progress": f}
		out.append(c)
	return out
