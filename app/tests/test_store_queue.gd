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


# ---- final review, low: move jobs ------------------------------------------------------------------

const StoreCommands := preload("res://scripts/library/manage/store_commands.gd")
const Disk := preload("res://scripts/library/manage/disk.gd")


func _move_plan(src: String, dest: String) -> Dictionary:
	var e := {"store": "gog", "id": "1207", "title": "W", "installed": true, "source": "gamecove", "platform": "windows",
		"install_path": src, "heroic_root": "/h"}
	return StoreCommands.plan("move", e, {"gogdl": "/opt/gogdl"}, {"home": "/home/u", "options": {"path": dest}, "gog_auth_exists": true, "same_drive": false})


func test_move_can_only_be_stopped_while_it_copies() -> void:
	var q := _queue()
	var r: Object = q.runner
	q.add("gog:1207", "move", _move_plan("/home/u/Games/gog/Witcher", "/sd/Games"), "W")
	ok(q.can_stop("gog:1207"), "copying: can be paused or cancelled")
	ok(q.pause("gog:1207"), "pause the copy")
	r.finish(1, 143)
	eq(q.job_for("gog:1207")["state"], "paused", "paused")
	ok(q.resume("gog:1207"), "resume")
	eq(r.last()["cmd"][0], "cp", "the copy runs again from the start (cp -a over what's there)")
	r.finish(2, 0)
	eq(r.last()["cmd"][0], "mv", "then the rename")
	ok(not q.can_stop("gog:1207"), "from here it can't be stopped")
	ok(not q.pause("gog:1207") and not q.cancel("gog:1207"), "pause and cancel are refused")
	eq(r.stopped, [1], "nothing was killed")
	r.finish(3, 0)
	eq(r.last()["cmd"].slice(0, 2), ["rm", "-rf"], "the old folder goes last")
	ok(not q.cancel("gog:1207"), "still no cancel while it deletes")
	r.finish(4, 0)
	ok(q.job_for("gog:1207").is_empty(), "done")
	ok(events.has(["gog:1207", "done"]), "finished as done")


func test_cancelled_or_failed_copy_is_cleared_away() -> void:
	var q := _queue()
	var r: Object = q.runner
	var part: String = "/sd/Games/Witcher" + StoreCommands.MOVING_SUFFIX
	q.add("gog:1207", "move", _move_plan("/home/u/Games/gog/Witcher", "/sd/Games"), "W")
	ok(q.cancel("gog:1207"), "cancel while copying")
	r.finish(1, 143)
	eq(r.last()["cmd"], ["rm", "-rf", "--", part], "the half copy is removed")
	ok(q.job_for("gog:1207").is_empty(), "the job is gone")
	# a copy that fails (the card is full) cleans up too
	q.add("gog:1207", "move", _move_plan("/home/u/Games/gog/Witcher", "/sd/Games"), "W")
	var h: int = r.last()["handle"]
	r.feed(h, "cp: error writing: No space left on device")
	r.finish(h, 1)
	eq(r.last()["cmd"], ["rm", "-rf", "--", part], "removed after a failure as well")
	# cancelled while it waits paused, with half a copy on the card
	q.add("gog:1207", "move", _move_plan("/home/u/Games/gog/Witcher", "/sd/Games"), "W")
	h = r.last()["handle"]
	q.pause("gog:1207")
	r.finish(h, 143)
	var before: int = r.started.size()
	ok(q.cancel("gog:1207"), "cancel a paused copy")
	eq(r.started.size(), before + 1, "one clean-up command")
	eq(r.last()["cmd"], ["rm", "-rf", "--", part], "that removes the half copy")


## Runs each command for real, at once; pump() then reports the exits in order.
class RealRunner extends RefCounted:
	signal line(handle: int, text: String)
	signal exited(handle: int, code: int)
	var pending: Array = []
	var ran: Array = []
	var _next := 0

	func start(cmd: Array, _env := {}) -> int:
		_next += 1
		var out := []
		ran.append(str(cmd[0]))
		pending.append([_next, OS.execute(str(cmd[0]), PackedStringArray(cmd.slice(1)), out, true)])
		return _next

	func stop(_handle: int) -> void:
		pass

	func pump() -> void:
		while not pending.is_empty():
			var p: Array = pending.pop_front()
			exited.emit(p[0], p[1])


## The whole plan with the real cp, mv and rm, the second time over the half copy an
## interrupted try left on the card: the game is whole in the new place, gone from the old.
func test_move_for_real_and_over_a_leftover() -> void:
	var root := ProjectSettings.globalize_path("user://test_store_queue/move")
	OS.execute("rm", ["-rf", root])
	var src := root.path_join("internal/Games/gog/Witcher")
	var dest := root.path_join("card/Games")
	var part: String = dest.path_join("Witcher") + StoreCommands.MOVING_SUFFIX
	DirAccess.make_dir_recursive_absolute(dest)
	for round in 2:
		DirAccess.make_dir_recursive_absolute(src.path_join("data"))
		for i in 5:
			var f := FileAccess.open(src.path_join("data/file%d.bin" % i), FileAccess.WRITE)
			f.store_string("round %d content %d" % [round, i])
			f.close()
		if round == 1:
			# what a copy paused or killed half way leaves: a cut-off file, some missing
			OS.execute("rm", ["-rf", dest.path_join("Witcher")])
			DirAccess.make_dir_recursive_absolute(part.path_join("data"))
			var half := FileAccess.open(part.path_join("data/file0.bin"), FileAccess.WRITE)
			half.store_string("rou")
			half.close()
		var real := RealRunner.new()
		var q := DownloadQueue.new(real)
		var done := []
		q.job_finished.connect(func(j): done.append(j["state"]))
		q.add("gog:1207", "move", _move_plan(src, dest), "W")
		real.pump()
		eq(done, ["done"], "round %d: finished" % round)
		eq(real.ran, ["cp", "mv", "rm"], "round %d: copy, rename, delete" % round)
		eq(DirAccess.get_files_at(dest.path_join("Witcher/data")).size(), 5, "round %d: every file is in the new place" % round)
		eq(FileAccess.get_file_as_string(dest.path_join("Witcher/data/file0.bin")), "round %d content 0" % round, "round %d: whole, not the cut-off one" % round)
		ok(not DirAccess.dir_exists_absolute(src), "round %d: the old folder is gone" % round)
		ok(not DirAccess.dir_exists_absolute(part), "round %d: no working folder left" % round)
	OS.execute("rm", ["-rf", root])


func test_same_drive_and_restart_after_the_rename() -> void:
	ok(Disk.same_drive("/home/u/Games/a", "/home/u/Games/b", "/dev/a / ext4 rw 0 0\n/dev/b /home ext4 rw 0 0\n/dev/c /run/media/deck/SD ext4 rw 0 0\n"), "two folders under /home")
	ok(not Disk.same_drive("/home/u/Games/a", "/run/media/deck/SD/Games", "/dev/a / ext4 rw 0 0\n/dev/b /home ext4 rw 0 0\n/dev/c /run/media/deck/SD ext4 rw 0 0\n"), "home and the card")
	ok(not Disk.same_drive("/home/u/a", "/home/u/b", ""), "mounts unreadable: assume different (the copy is always right)")
	eq(Disk.mount_of("/run/media/deck/My Card/Games", "/dev/a / ext4 rw 0 0\n/dev/c /run/media/deck/My\\040Card ext4 rw 0 0\n"), "/run/media/deck/My Card", "a space in the label")
	eq(Disk.mount_of("/homework/x", "/dev/a / ext4 rw 0 0\n/dev/b /home ext4 rw 0 0\n"), "/", "a prefix that isn't a folder boundary")
	# the app died right after the rename: the saved job starts again at that step and must
	# see it's done, not fail on "no such folder"
	var root := ProjectSettings.globalize_path("user://test_store_queue/restart")
	OS.execute("rm", ["-rf", root])
	var src := root.path_join("internal/Games/gog/Witcher")
	var dest := root.path_join("card/Games")
	DirAccess.make_dir_recursive_absolute(src)
	DirAccess.make_dir_recursive_absolute(dest.path_join("Witcher"))   # the rename happened
	var q := _queue()
	var r: Object = q.runner
	var plan := _move_plan(src, dest)
	var j := q.add("gog:1207", "move", plan, "W")
	r.finish(1, 0)   # the copy
	# now at the rename, whose "from" is gone and "to" is there
	eq(r.last()["cmd"].slice(0, 2), ["rm", "-rf"], "the rename is skipped as done, on to deleting the old folder")
	eq(j["step"], 2, "at the last step")
	OS.execute("rm", ["-rf", root])
