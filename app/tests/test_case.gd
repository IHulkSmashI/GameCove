extends RefCounted
## Base for tests: extend it, write methods named test_*, call eq()/ok().

var failures: Array[String] = []
var _current := ""


func eq(actual, expected, what := "") -> void:
	if typeof(actual) != typeof(expected) or actual != expected:
		failures.append("%s: %s expected %s, got %s" % [_current, what, var_to_str(expected), var_to_str(actual)])


func ok(condition: bool, what := "") -> void:
	if not condition:
		failures.append("%s: %s" % [_current, what])


## Runs one test method. Returns true only when it ran straight through: a
## method that awaits hands back a function state before it's done, which the
## runner can't wait for, so it counts as not finished. Script errors inside the
## method are caught by the runner's logger (they return here like a normal end).
func _run_test(method: String) -> bool:
	var r = call(method)
	return not (r is Object and r.get_class() == "GDScriptFunctionState")


## Path to a fixture under res://tests/fixtures as an absolute filesystem path.
func fixture(rel: String) -> String:
	return ProjectSettings.globalize_path("res://tests/fixtures/" + rel)
