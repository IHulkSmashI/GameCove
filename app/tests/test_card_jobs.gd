extends "res://tests/test_case.gd"
## Review 3, high 1: a Settings card torn down mid-job (theme change rebuilds every
## page, quitting) used to join its WorkerThreadPool task in _exit_tree, freezing
## the app for as long as curl / tar / a Bluetooth pair took. The jobs now belong
## to scripts/system/card_jobs.gd: leaving never waits, the next card gets the
## result, and only real exit joins, after the programs were stopped.
## Plus a lint: no _exit_tree outside the real-exit owners, and no page rebuild
## path, joins a worker.

const CardJobs := preload("res://scripts/system/card_jobs.gd")
const ExecSafe := preload("res://scripts/system/exec_safe.gd")
const Proc := preload("res://scripts/system/proc.gd")
const ProtonCard := preload("res://scripts/ui/settings/proton_card.gd")
const BtCard := preload("res://scripts/ui/settings/bluetooth_card.gd")
const ProtonT := preload("res://tests/test_extras_proton.gd")
const BtT := preload("res://tests/test_extras_bluetooth.gd")
const Fake := preload("res://tests/fixtures/system/fake_runner.gd")
const TX := preload("res://scripts/ui/texts_extras.gd")

## How long the faked programs take; leaving must take far less.
const SLOW_MS := 900


## What leaving the tree does to a card (the test runner's tree isn't live, so
## remove_child alone wouldn't call it).
func _leave(c: Node) -> int:
	var t0 := Time.get_ticks_msec()
	c._exit_tree()
	c.free()
	return Time.get_ticks_msec() - t0


## A GE-Proton home and a runner whose GitHub lookup takes SLOW_MS.
func _proton_setup(t: Object, name: String) -> Array:
	var h: Dictionary = t._home(name)
	var inner: RefCounted = t._fake(ProtonT.HASH, true, ProtonT.release_json())
	var f: RefCounted = Fake.new()
	f.handler = func(cmd: String) -> Variant:
		if cmd.ends_with("releases/latest"):
			OS.delay_msec(SLOW_MS)
		return inner.handler.call(cmd)
	f.set_meta("inner", inner)
	return [h, f]


func test_leaving_the_proton_card_mid_job_never_waits() -> void:
	var t = ProtonT.new()
	var s := _proton_setup(t, "cardjobs")
	var h: Dictionary = s[0]
	var jobs: RefCounted = CardJobs.new()
	jobs.force_threads = true
	var c: VBoxContainer = ProtonCard.new()
	c.setup(s[1], h.home, null, jobs)
	c.check()
	eq(c.busy, "check", "the lookup runs on a worker")
	var took := _leave(c)   # what a theme change does to every Settings page
	ok(took < SLOW_MS / 3, "leaving didn't wait for the job (%d ms)" % took)
	# the page built again: the new card sees the job and gets its result
	var c2: VBoxContainer = ProtonCard.new()
	c2.setup(s[1], h.home, null, jobs)
	eq(c2.busy, "check", "the new card knows a check is running")
	eq(c2.main_row.value_label.text, TX.GE_CHECKING, "and says so")
	var notes := []
	c2.notice.connect(func(text, _tone): notes.append(text))
	jobs.wait_idle()
	eq(c2.busy, "", "done")
	eq(c2.main_row.title_label.text, TX.GE_INSTALL % "GE-Proton10-26", "the result reached the new card")
	eq(notes, [], "no error")
	c2.free()
	t._rm(h.root)


func test_a_result_with_no_card_waits_for_the_next_one() -> void:
	var t = ProtonT.new()
	var s := _proton_setup(t, "cardjobs_wait")
	var h: Dictionary = s[0]
	var jobs: RefCounted = CardJobs.new()
	jobs.force_threads = true
	var c: VBoxContainer = ProtonCard.new()
	c.setup(s[1], h.home, null, jobs)
	c.check()
	_leave(c)
	jobs.wait_idle()   # finished while no card was there
	var c2: VBoxContainer = ProtonCard.new()
	c2.setup(s[1], h.home, null, jobs)
	jobs._flush_waiting("ge_proton")   # the next frame
	eq(c2.release.get("tag", ""), "GE-Proton10-26", "what the check found reached the new card")
	eq(c2.main_row.title_label.text, TX.GE_INSTALL % "GE-Proton10-26", "the card shows it")
	c2.free()
	t._rm(h.root)


func test_leaving_the_bluetooth_card_mid_scan_never_waits() -> void:
	var bz = BtT.Bluez.new()
	var f: RefCounted = Fake.new()
	f.handler = func(cmd: String) -> Variant:
		if cmd.begins_with("bluetoothctl"):
			OS.delay_msec(SLOW_MS)
		return bz.answer(cmd)
	f.set_meta("bz", bz)
	var jobs: RefCounted = CardJobs.new()
	var c: VBoxContainer = BtCard.new()
	c.setup(f, null, jobs)   # the first read runs at once
	eq(c.rows.size(), 3, "devices read")
	jobs.force_threads = true
	c.find_new()
	eq(c.busy, "scan", "scanning on a worker")
	var took := _leave(c)
	ok(took < SLOW_MS / 3, "leaving didn't wait for the scan (%d ms)" % took)
	var c2: VBoxContainer = BtCard.new()
	c2.setup(f, null, jobs)
	eq(c2.rows.size(), 3, "the rebuilt card shows the last read at once")
	eq(c2.find_row.value_label.text, TX.BT_FINDING, "and that the scan runs")
	jobs.wait_idle()
	eq(c2.busy, "", "scan done")
	eq(c2.find_row.value_label.text, "", "and the new card heard of it")
	c2.free()


func test_shutdown_stops_the_programs_before_joining() -> void:
	var jobs: RefCounted = CardJobs.new()
	jobs.group = "test_card_jobs_%d" % Time.get_ticks_usec()
	var r: RefCounted = jobs.runner()
	var sub := _Sub.new()
	jobs.subscribe("x", sub)
	ok(jobs.start("x", "sleep", func(): return r.run("sleep", PackedStringArray(["30"])), "take", [], true), "started")
	var waited := 0
	while ExecSafe.live(jobs.group).is_empty() and waited < 3000:
		OS.delay_msec(10)
		waited += 10
	eq(ExecSafe.live(jobs.group).size(), 1, "sleep runs in the jobs' stop group")
	var t0 := Time.get_ticks_msec()
	jobs.shutdown(500)
	var took := Time.get_ticks_msec() - t0
	ok(took < 2500, "exit didn't wait the 30 s (%d ms)" % took)
	eq(ExecSafe.live(jobs.group), [], "nothing left running")
	eq(r.run("true", PackedStringArray()), {"code": -1, "out": "stopped"}, "nothing new starts after")
	ok(not jobs.start("x", "again", func(): return 1, "take", [], false), "no new jobs either")
	jobs._drain()   # the worker's hand-back, had a frame passed
	eq(sub.got, [], "nothing delivered after exit")
	ExecSafe.clear_stopped(jobs.group)
	sub.free()


class _Sub extends Node:
	var got := []
	func take(v: Variant) -> void:
		got.append(v)


func test_never_stop_programs_are_left_alone() -> void:
	var g := "test_never_stop_%d" % Time.get_ticks_usec()
	ok(not ExecSafe.track(999999, "/usr/bin/fwupdmgr", g), "a firmware flash is never tracked")
	ok(not ExecSafe.track(999999, "systemctl", g), "systemctl neither")
	ok(not ExecSafe.track(999999, "curl", ""), "no group, nothing tracked")
	ExecSafe.stop_group(g, 0)
	ok(ExecSafe.stopped(g), "stopped")
	eq(ExecSafe.run("true", PackedStringArray(), true, g)["out"], "stopped", "refused once stopped")
	eq(ExecSafe.run("true", PackedStringArray(), true, "")["code"], 0, "other runs go on")
	eq(Proc.new(g).stream("true", PackedStringArray(), func(_l): pass), -1, "streams too")
	ExecSafe.clear_stopped(g)
	eq(ExecSafe.run("true", PackedStringArray(), true, g)["code"], 0, "runs again once cleared")


# ---- lint ---------------------------------------------------------------------------------------

## Scripts whose _exit_tree may join a worker: they live as long as the app, so
## _exit_tree is real exit, and their own programs are stopped or their jobs are
## short (checked below for the ones running programs).
const REAL_EXIT_OWNERS := {
	"res://scripts/library/library.gd": "autoload; a store scan reads files",
	"res://scripts/library/gamedb.gd": "child of the Library autoload; unpacks a small database",
	"res://scripts/library/art/art_service.gd": "child of the Library autoload; writes one picture",
	"res://scripts/discover/discover.gd": "autoload; parses a calendar file",
	"res://scripts/achievements/achievements.gd": "autoload; reads achievement files",
	"res://scripts/perf/perf_monitor.gd": "autoload; one sample of /sys reads",
	"res://scripts/system/service.gd": "base of the Updates/Storage/Setup/Controller autoloads; stops its programs first",
	"res://scripts/system/saves_service.gd": "owned by main.gd; stops legendary/gogdl first",
	"res://scripts/ui/bg_command.gd": "owned by the quick menu and the fixes service (app lifetime); stops its programs first",
	"res://scripts/streaming/streaming.gd": "owned by main.gd; jobs check _quitting",
	"res://scripts/launch/game_session.gd": "owned by main.gd; one /proc check",
	"res://scripts/device/device.gd": "autoload; slow info reads",
	"res://scripts/device/power.gd": "autoload; its worker",
	"res://scripts/controls/controls.gd": "autoload; its worker",
	"res://scripts/input/intercept.gd": "kills its monitor before joining the reader",
	"res://scripts/gamescope/command_runner.gd": "kills its program before joining the reader",
}
## Functions that run when a page or card is built or rebuilt.
const REBUILD_RE := "^(_?re)?build\\w*$|^_show\\w*$|^refresh$|^on_shown$|^_on_snapshot$|^_on_apps$|^_on_state$"
const JOIN_RE := "wait_for_task_completion|wait_to_finish|wait_for_group_task_completion"


static func _scripts(dir: String, out: Array) -> void:
	var d := DirAccess.open(dir)
	for f in d.get_files():
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		_scripts(dir.path_join(sub), out)


## {func name: [body lines]} of a script (top-level and inner-class funcs).
static func _functions(text: String) -> Dictionary:
	var out := {}
	var cur := ""
	var indent := 0
	var re := RegEx.create_from_string("^(\\s*)(static\\s+)?func\\s+(\\w+)")
	for line in text.split("\n"):
		var m := re.search(line)
		if m != null:
			cur = m.get_string(3)
			indent = m.get_string(1).length()
			out[cur] = out.get(cur, [])
			continue
		if cur == "":
			continue
		var stripped := line.strip_edges()
		if stripped != "" and not stripped.begins_with("#") and (line.length() - line.lstrip("\t ").length()) <= indent:
			cur = ""
			continue
		out[cur].append(line)
	return out


## A join right after an is_task_completed check (freeing a finished task) returns at once.
static func _blocking_joins(body: Array) -> Array:
	var out := []
	var join := RegEx.create_from_string(JOIN_RE)
	for i in body.size():
		var l: String = body[i]
		if join.search(l) == null or l.strip_edges().begins_with("#"):
			continue
		var prev: String = body[i - 1] if i > 0 else ""
		if "is_task_completed" in prev or "is_task_completed" in l:
			continue
		out.append(l.strip_edges())
	return out


func test_lint_no_join_when_a_page_goes() -> void:
	var files := []
	_scripts("res://scripts", files)
	var rebuild := RegEx.create_from_string(REBUILD_RE)
	var bad := []
	for f in files:
		var fns := _functions(FileAccess.get_file_as_string(f))
		for fn in fns:
			var joins := _blocking_joins(fns[fn])
			if joins.is_empty():
				continue
			if fn == "_exit_tree" and not REAL_EXIT_OWNERS.has(f):
				bad.append("%s %s(): %s" % [f, fn, joins[0]])
			elif rebuild.search(fn) != null:
				bad.append("%s %s(): %s" % [f, fn, joins[0]])
	eq(bad, [], "no join on the main thread when a page or card goes or is rebuilt")
	for f in REAL_EXIT_OWNERS:
		ok(FileAccess.file_exists(f), "%s still exists (drop it from the list otherwise)" % f)


func test_lint_catches_the_old_pattern() -> void:
	var old := "func _exit_tree() -> void:\n\tfor t in _tasks:\n\t\tWorkerThreadPool.wait_for_task_completion(t)\n\t_tasks.clear()\n\n\nfunc _reap() -> void:\n\tif WorkerThreadPool.is_task_completed(t):\n\t\tWorkerThreadPool.wait_for_task_completion(t)\n"
	var fns := _functions(old)
	eq(_blocking_joins(fns["_exit_tree"]).size(), 1, "a join in _exit_tree is found")
	eq(_blocking_joins(fns["_reap"]), [], "freeing a finished task is fine")
