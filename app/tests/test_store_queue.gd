extends "res://tests/test_case.gd"
## Download queue state machine with a fake runner: one at a time, progress,
## pause/resume (the same step runs again), cancel, failures, space check,
## reordering, and restoring a saved queue.

const DownloadQueue := preload("res://scripts/library/manage/download_queue.gd")
const FakeRunner := preload("res://tests/fixtures/stores/fake_job_runner.gd")

var events: Array = []


func _plan(name: String, probe := false) -> Dictionary:
	var steps: Array = []
	if probe:
		steps.append({"cmd": ["legendary", "info", name, "--json"], "env": {}, "parser": "size", "kind": "probe", "tool": "legendary"})
	steps.append({"cmd": ["legendary", "install", name], "env": {"X": "1"}, "parser": "legendary", "kind": "main", "tool": "legendary"})
	return {"ok": true, "steps": steps, "finalize": {"base": "/games/epic"}}


func _queue(path := "") -> DownloadQueue:
	var r := FakeRunner.new()
	var q := DownloadQueue.new(r)
	q.save_path = path
	q.free_space = func(_p: String) -> int: return 5000000000
	events = []
	q.job_changed.connect(func(j): events.append([j["key"], j["state"]]))
	q.job_progress.connect(func(j): events.append([j["key"], "progress", j["progress"]["bytes_done"]]))
	return q


func test_one_at_a_time_in_order() -> void:
	var q := _queue()
	var r: Object = q.runner
	q.add("epic:A", "install", _plan("A"), "A")
	q.add("epic:B", "install", _plan("B"), "B")
	eq(r.started.size(), 1, "only the first runs")
	eq(r.last()["cmd"], ["legendary", "install", "A"], "A first")
	eq(r.last()["env"], {"X": "1"}, "env passed")
	eq(q.job_for("epic:B")["state"], "queued", "B waits")
	ok(q.add("epic:A", "update", _plan("A")).is_empty(), "one job per game")
	r.feed_file(1, fixture("stores/data/logs/legendary_install.log"))
	eq(q.job_for("epic:A")["progress"]["percent"], 25.0, "progress parsed")
	ok(events.has(["epic:A", "progress", 2560 * 1048576]), "progress signal")
	r.finish(1, 0)
	ok(q.job_for("epic:A").is_empty(), "A done and gone")
	ok(events.has(["epic:A", "done"]), "done state")
	eq(r.last()["cmd"], ["legendary", "install", "B"], "B starts")


func test_parallel_setting() -> void:
	var q := _queue()
	q.max_parallel = 2
	q.add("epic:A", "install", _plan("A"))
	q.add("epic:B", "install", _plan("B"))
	q.add("epic:C", "install", _plan("C"))
	eq(q.running_count(), 2, "two at once")


func test_pause_resume_runs_the_step_again() -> void:
	var q := _queue()
	var r: Object = q.runner
	q.add("epic:A", "install", _plan("A"))
	q.add("epic:B", "install", _plan("B"))
	ok(q.pause("epic:A"), "pause")
	eq(r.stopped, [1], "process stopped")
	r.finish(1, -15)
	eq(q.job_for("epic:A")["state"], "paused", "paused, not failed")
	eq(r.last()["cmd"], ["legendary", "install", "B"], "next job takes the slot")
	ok(q.resume("epic:A"), "resume")
	eq(q.job_for("epic:A")["state"], "queued", "waits for B")
	r.finish(2, 0)
	eq(r.last()["cmd"], ["legendary", "install", "A"], "A runs the same command again (tools resume)")
	ok(not q.resume("epic:A"), "can't resume a running job")


func test_cancel_queued_and_running() -> void:
	var q := _queue()
	var r: Object = q.runner
	var finished := []
	q.job_finished.connect(func(j): finished.append([j["key"], j["state"]]))
	q.add("epic:A", "install", _plan("A"))
	q.add("epic:B", "install", _plan("B"))
	ok(q.cancel("epic:B"), "cancel waiting")
	eq(finished, [["epic:B", "cancelled"]], "B cancelled without running")
	ok(q.cancel("epic:A"), "cancel running")
	eq(q.job_for("epic:A")["state"], "running", "until the process ends")
	r.finish(1, -15)
	eq(finished.back(), ["epic:A", "cancelled"], "A cancelled")
	eq(q.jobs.size(), 0, "empty")
	ok(not q.cancel("epic:A"), "nothing left")


func test_failure_keeps_error_line() -> void:
	var q := _queue()
	var r: Object = q.runner
	var finished := []
	q.job_finished.connect(func(j): finished.append(j.duplicate()))
	q.add("epic:A", "verify", _plan("A"))
	r.feed_file(1, fixture("stores/data/logs/legendary_verify.log"))
	r.finish(1, 1)
	eq(finished[0]["state"], "failed", "failed")
	eq(finished[0]["error"], "[cli] ERROR: Verification failed, 3 file(s) corrupted, 0 file(s) are missing.", "error line")


func test_space_check_from_probe() -> void:
	var q := _queue()
	var r: Object = q.runner
	q.free_space = func(_p: String) -> int: return 1000
	var finished := []
	q.job_finished.connect(func(j): finished.append(j.duplicate()))
	q.add("epic:A", "install", _plan("A", true))
	eq(r.last()["cmd"], ["legendary", "info", "A", "--json"], "probe first")
	r.feed_file(1, fixture("stores/data/size/legendary_info.json"))
	r.finish(1, 0)
	eq(finished[0]["state"], "failed", "not enough space")
	ok(str(finished[0]["error"]).begins_with("Not enough space in /games/epic"), "says so")
	eq(r.started.size(), 1, "never downloaded")


func test_probe_failure_continues() -> void:
	var q := _queue()
	var r: Object = q.runner
	q.add("epic:A", "install", _plan("A", true))
	r.feed(1, "[cli] ERROR: offline")
	r.finish(1, 1)
	eq(r.last()["cmd"], ["legendary", "install", "A"], "download starts anyway (tools check space too)")
	q.add("epic:B", "install", _plan("B", true))
	r.finish(2, 0)
	eq(r.last()["cmd"], ["legendary", "info", "B", "--json"], "B probes after A")


func test_probe_size_used_as_total() -> void:
	var q := _queue()
	var r: Object = q.runner
	q.free_space = func(_p: String) -> int: return -1
	q.add("epic:A", "install", _plan("A", true))
	r.feed_file(1, fixture("stores/data/size/legendary_info.json"))
	r.finish(1, 0)
	eq(q.job_for("epic:A")["size"], 15754981376, "size kept")
	eq(q.job_for("epic:A")["progress"]["bytes_total"], 15754981376, "total until the tool says")


func test_reorder() -> void:
	var q := _queue()
	q.add("epic:A", "install", _plan("A"))
	q.add("epic:B", "install", _plan("B"))
	q.add("epic:C", "install", _plan("C"))
	ok(q.reorder("epic:C", -1), "C up")
	eq(q.snapshot().map(func(j): return j["key"]), ["epic:A", "epic:C", "epic:B"], "order")
	ok(not q.reorder("epic:A", -1), "already first")


func test_save_and_restore() -> void:
	var path := OS.get_user_data_dir().path_join("test_downloads.json")
	DirAccess.remove_absolute(path)
	var q := _queue(path)
	q.add("epic:A", "install", _plan("A", true))
	q.runner.finish(1, 1)   # probe done -> step 1 running
	q.add("epic:B", "install", _plan("B"))
	q.add("epic:C", "update", _plan("C"))
	q.pause("epic:C")
	ok(FileAccess.file_exists(path), "saved")
	var q2 := _queue(path)
	q2.restore(func(j): return j["key"] != "epic:B")
	eq(q2.snapshot().map(func(j): return [j["key"], j["state"]]), [["epic:A", "running"], ["epic:C", "paused"]], "running came back and restarted; paused stays; B dropped")
	eq(q2.runner.last()["cmd"], ["legendary", "install", "A"], "restarts at the saved step")
	var q3 := _queue(path)
	q3.auto_resume = false
	q3.restore()
	eq(q3.job_for("epic:A")["state"], "paused", "no auto resume: paused")
	DirAccess.remove_absolute(path)
