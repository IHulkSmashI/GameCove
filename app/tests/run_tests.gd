extends SceneTree
## godot --headless --path app -s res://tests/run_tests.gd
## Runs every res://tests/test_*.gd; exits 1 if anything fails.
##
## A GDScript runtime error (null call, bad index, ...) aborts only the test
## method; control comes back here as if it had returned. So every test runs
## with a Logger attached, and a test that logged a script error, or an engine
## error (`ERROR:` lines: push_error, failed conditions, get_node misuse...), or
## that didn't reach the end of the runner's wrapper, counts as failed. A test
## that triggers an error on purpose declares it first with
## expect_error("part of the message") (test_case.gd); warnings never count.


## Collects script and engine errors reported while a test runs.
class ErrorCounter extends Logger:
	var _mutex := Mutex.new()
	var _seen: Array[Dictionary] = []   # {"script": bool, "text": String}

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == ERROR_TYPE_WARNING:
			return
		var text := "%s (%s:%d in %s)" % [rationale if rationale != "" else code, file, line, function]
		if error_type == ERROR_TYPE_ERROR and rationale != "" and code != "":
			text = "%s: %s" % [code, text]
		_mutex.lock()
		_seen.append({"script": error_type == ERROR_TYPE_SCRIPT, "text": text})
		_mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	## Everything seen since the last take(), and forgets it.
	func take() -> Array[Dictionary]:
		_mutex.lock()
		var out := _seen.duplicate()
		_seen.clear()
		_mutex.unlock()
		return out


## Errors left after the expected ones (each expectation absorbs one error
## whose text contains it). Script errors can't be expected away.
static func unexpected(seen: Array[Dictionary], expected: Array[String]) -> Array[String]:
	var left := expected.duplicate()
	var out: Array[String] = []
	for e in seen:
		var hit := -1
		if not e["script"]:
			for i in left.size():
				if left[i] in str(e["text"]):
					hit = i
					break
		if hit >= 0:
			left.remove_at(hit)
		else:
			out.append(("script error: " if e["script"] else "engine error: ") + str(e["text"]))
	return out


func _initialize() -> void:
	var errors := ErrorCounter.new()
	OS.add_logger(errors)
	var failed := 0
	var passed := 0
	var dir := DirAccess.open("res://tests")
	var files := Array(dir.get_files()).filter(func(f): return f.begins_with("test_") and f.ends_with(".gd") and f != "test_case.gd")
	files.sort()
	# GAMECOVE_TEST=<part of a file or test name>: run only the matching tests
	var only := OS.get_environment("GAMECOVE_TEST")
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
			if only != "" and not only in "%s::%s" % [f, name]:
				continue
			var before: int = t.failures.size()
			errors.take()
			t._current = "%s::%s" % [f, name]
			t._expected_errors.clear()
			var finished: bool = t._run_test(name) == true
			var bad := unexpected(errors.take(), t._expected_errors)
			for msg in bad:
				t.failures.append("%s: %s" % [t._current, msg])
			if bad.is_empty() and not finished:
				t.failures.append("%s: did not run to the end" % t._current)
			if t.failures.size() > before:
				failed += 1
				for msg in t.failures.slice(before):
					printerr("FAIL ", msg)
			else:
				passed += 1
		if t.has_method("after_all"):
			t.after_all()   # per-file cleanup (generated fixture folders...)
	OS.remove_logger(errors)
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)
