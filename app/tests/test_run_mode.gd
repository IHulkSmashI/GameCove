extends "res://tests/test_case.gd"
## Review 2, problem 5: `--restore-baseline` (run next to the live GameCove before a
## session switch) booted the full app: the store manager relaunched a saved install
## command, GameDB downloaded, the InputPlumber monitor started.

const RunMode := preload("res://scripts/system/run_mode.gd")
const PerfMonitorScript := preload("res://scripts/perf/perf_monitor.gd")


func test_helper_mode_from_the_command_line() -> void:
	RunMode.test_args = ["--restore-baseline"]
	ok(RunMode.helper(), "--restore-baseline is a helper run")
	RunMode.test_args = []
	ok(not RunMode.helper(), "a normal start isn't")
	RunMode.test_args = null


func test_perf_monitor_starts_nothing_in_helper_mode() -> void:
	RunMode.test_args = ["--restore-baseline"]
	var pm: Node = PerfMonitorScript.new()
	pm._ready()   # the runner's tree isn't running yet: call it as the autoload start would
	eq(pm.get_child_count(), 0, "no sampling timer")
	ok(pm.mangohud == null, "no MangoHud setup")
	pm.free()
	RunMode.test_args = null


## The autoloads whose services must stay off check helper() before anything else
## (their own test-runner guard comes after, so only the source shows it).
func test_service_autoloads_check_helper_mode_first() -> void:
	for p in ["res://scripts/library/library.gd", "res://scripts/discover/discover.gd",
			"res://scripts/discover/art.gd", "res://scripts/perf/perf_monitor.gd"]:
		var src := FileAccess.get_file_as_string(p)
		var body := src.substr(src.find("func _ready() -> void:\n") + 23)
		ok(body.begins_with("\tif preload(\"res://scripts/system/run_mode.gd\").helper():\n\t\treturn"), "%s: _ready returns first in helper mode" % p)
	var photo := FileAccess.get_file_as_string("res://scripts/device/photo.gd")
	ok(photo.find("run_mode.gd\").helper()") < photo.find("prefetch_detected.call_deferred()"), "photo: no prefetch in helper mode")
	var ctl := FileAccess.get_file_as_string("res://scripts/input/controller.gd")
	ok("not preload(\"res://scripts/system/run_mode.gd\").helper() and intercept_wanted(" in ctl, "controller: no intercept in helper mode")
