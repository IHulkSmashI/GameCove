extends "res://tests/test_case.gd"
## The runner fails a test on engine errors (`ERROR:` lines) unless the test
## declared them with expect_error(); script errors always fail.

const Runner := preload("res://tests/run_tests.gd")


func test_unexpected_errors() -> void:
	var seen: Array[Dictionary] = [{"script": false, "text": "Condition \"x\" is true (a.cpp:1 in f)"}]
	eq(Runner.unexpected(seen, [] as Array[String]).size(), 1, "an engine error fails the test")
	eq(Runner.unexpected(seen, ["Condition \"x\""] as Array[String]), [] as Array[String], "unless it was expected")
	var two: Array[Dictionary] = [seen[0], seen[0]]
	eq(Runner.unexpected(two, ["Condition"] as Array[String]).size(), 1, "one expectation absorbs one error")
	var script_err: Array[Dictionary] = [{"script": true, "text": "Invalid call"}]
	eq(Runner.unexpected(script_err, ["Invalid call"] as Array[String]).size(), 1, "script errors can't be expected away")


func test_expected_push_error_passes() -> void:
	expect_error("deliberate test error")
	push_error("deliberate test error")
	ok(true)
