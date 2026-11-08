extends SceneTree
## godot --headless --path app -s res://tests/run_tests.gd
## Runs every res://tests/test_*.gd; exits 1 if anything fails.
##
## A GDScript runtime error (null call, bad index, ...) aborts only the test
## method; control comes back here as if it had returned. So every test runs
## with a Logger attached, and a test that logged a script error, or that
## didn't reach the end of the runner's wrapper, counts as failed.


## Counts script errors (ERROR_TYPE_SCRIPT) reported by the engine. push_error
## and push_warning from the code under test are ERROR_TYPE_ERROR / WARNING
## and don't count: some tests trigger those on purpose.
class ErrorCounter extends Logger:
	var _mutex := Mutex.new()
	var _count := 0
	var _last := ""

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != ERROR_TYPE_SCRIPT:
			return
		_mutex.lock()
		_count += 1
		_last = "%s (%s:%d in %s)" % [rationale if rationale != "" else code, file, line, function]
		_mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func count() -> int:
		_mutex.lock()
		var c := _count
		_mutex.unlock()
		return c

	func last() -> String:
		_mutex.lock()
		var s := _last
		_mutex.unlock()
		return s


func _initialize() -> void:
	var errors := ErrorCounter.new()
	OS.add_logger(errors)
	var failed := 0
	var passed := 0
	var dir := DirAccess.open("res://tests")
	var files := Array(dir.get_files()).filter(func(f): return f.begins_with("test_") and f.ends_with(".gd") and f != "test_case.gd")
	files.sort()
	for f in files:
		var script: GDScript = load("res://tests/" + f)
		if script == null or not script.can_instantiate():
			# a parse error would otherwise leave the runner hanging
			printerr("FAIL %s: does not compile" % f)
			failed += 1
			continue
		var t = script.new()
		for m in t.get_method_list():
			var name: String = m["name"]
			if not name.begins_with("test_"):
				continue
			var before: int = t.failures.size()
			var errors_before := errors.count()
			t._current = "%s::%s" % [f, name]
			var finished: bool = t._run_test(name) == true
			var crashed := errors.count() > errors_before
			if crashed:
				t.failures.append("%s: script error: %s" % [t._current, errors.last()])
			elif not finished:
				t.failures.append("%s: did not run to the end" % t._current)
			if t.failures.size() > before:
				failed += 1
				for msg in t.failures.slice(before):
					printerr("FAIL ", msg)
			else:
				passed += 1
	OS.remove_logger(errors)
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)
