extends SceneTree
## End-to-end runner: one fake handheld (E2E_INFO), the real app on it, every
## suite in res://tests/e2e/suite_*.gd. Start it through tests/e2e/run.py, which
## builds the fixture, gives the process its own HOME / XDG folders and checks
## for left-over processes afterwards.
##
## Unlike tests/run_tests.gd the main loop runs: tests await frames, worker
## threads answer, timers fire. Each test starts from a reset handheld
## (world.reset()), and the safety invariants (checks.gd) are checked after it.
##
## Env: E2E_SUITES=a,b (file name parts), E2E_TEST=<part of a test name>,
## E2E_SEED (randomized parts), E2E_ITERS (iterations of randomized parts),
## E2E_PHASE (restart suite: 1 = before the restart, 2 = after).
## Prints "E2E PASS|FAIL <suite>::<test> (<ms> ms)" and a last line
## "E2E RESULT {json}"; exits 1 on any failure.

const ErrorCounter := preload("res://tests/run_tests.gd").ErrorCounter
const RunTests := preload("res://tests/run_tests.gd")
const World := preload("res://tests/e2e/world.gd")
const Checks := preload("res://tests/e2e/checks.gd")

var world: RefCounted
var errors: Logger


func _initialize() -> void:
	_run()


func _run() -> void:
	set_meta(&"gamecove_e2e", true)   # Services.E2E_META: production service lookups
	errors = ErrorCounter.new()
	OS.add_logger(errors)
	var t_start := Time.get_ticks_msec()
	world = World.new(self)
	var err: String = await world.configure()
	if err != "":
		printerr("E2E FAIL setup: " + err)
		_finish(1, {"error": err})
		return
	await world.boot_main()
	var boot_errors := RunTests.unexpected(Checks.drop_noise(errors.take()), [] as Array[String])
	var results := {"setup": world.setup_name, "passed": 0, "failed": 0, "failures": [], "tests": [],
		"boot_errors": boot_errors}
	for e in boot_errors:
		printerr("E2E FAIL boot: " + e)
		results["failed"] += 1
		results["failures"].append("boot: " + e)
	var only_suites := Array(OS.get_environment("E2E_SUITES").split(",", false))
	var only_test := OS.get_environment("E2E_TEST")
	var skip := Array(OS.get_environment("E2E_SKIP").split(",", false))
	var files := Array(DirAccess.get_files_at("res://tests/e2e")).filter(func(f): return f.begins_with("suite_") and f.ends_with(".gd"))
	files.sort()
	for f in files:
		if not only_suites.is_empty() and not only_suites.any(func(s): return s in f):
			continue
		if skip.any(func(s): return s in f):
			continue
		var script: GDScript = load("res://tests/e2e/" + f)
		if script == null or not script.can_instantiate():
			results["failed"] += 1
			results["failures"].append("%s does not compile" % f)
			printerr("E2E FAIL %s: does not compile" % f)
			continue
		var t = script.new()
		t.w = world
		for m in t.get_method_list():
			var name: String = m["name"]
			if not name.begins_with("test_"):
				continue
			var label := "%s::%s" % [f.trim_suffix(".gd"), name]
			if only_test != "" and not only_test in label:
				continue
			if t.has_method("applies") and not t.applies(name):
				continue
			if OS.get_environment("E2E_PHASE") != "2":
				await world.reset()   # phase 2 of a restart starts from what phase 1 left
			else:
				world.fake.reset_log()
			errors.take()
			t._current = label
			t._expected_errors.clear()
			var before: int = t.failures.size()
			var t0 := Time.get_ticks_msec()
			await t.call(name)
			await world.idle()
			for p in await Checks.after_test(world):
				t.failures.append("%s: invariant: %s" % [label, p])
			for msg in RunTests.unexpected(Checks.drop_noise(errors.take()), t._expected_errors):
				t.failures.append("%s: %s" % [label, msg])
			var ms := Time.get_ticks_msec() - t0
			var fails: Array = t.failures.slice(before)
			results["tests"].append({"name": label, "ms": ms, "ok": fails.is_empty()})
			if fails.is_empty():
				results["passed"] += 1
				print("E2E PASS %s (%d ms)" % [label, ms])
			else:
				results["failed"] += 1
				for msg in fails:
					printerr("E2E FAIL ", msg)
					results["failures"].append(msg)
	# the app exits: every InputPlumber device must be back in InterceptMode 0
	for p in await Checks.on_exit(world):
		results["failed"] += 1
		results["failures"].append("exit: " + p)
		printerr("E2E FAIL exit: " + p)
	results["ms"] = Time.get_ticks_msec() - t_start
	_finish(1 if results["failed"] > 0 else 0, results)


func _finish(code: int, results: Dictionary) -> void:
	print("E2E RESULT " + JSON.stringify(results))
	OS.remove_logger(errors)
	quit(code)
