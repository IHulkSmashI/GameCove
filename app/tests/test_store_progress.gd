extends "res://tests/test_case.gd"
## Progress lines of legendary, gogdl and nile (fixture logs in each tool's real
## format), size probes, and the job runner's command wrapping.

const Progress := preload("res://scripts/library/manage/progress.gd")
const JobRunner := preload("res://scripts/library/manage/job_runner.gd")

const MIB := 1048576


func _feed(tool: String, log_name: String) -> Dictionary:
	var p := Progress.empty()
	var text := FileAccess.get_file_as_string(fixture("stores/data/logs/" + log_name))
	for l in text.replace("\r", "\n").split("\n", false):
		Progress.parse_line(tool, l, p)
	return p


func test_legendary_install() -> void:
	var p := _feed("legendary", "legendary_install.log")
	eq(p["bytes_total"], 10240 * MIB, "total from Download size")
	eq(p["percent"], 25.0, "percent")
	eq(p["bytes_done"], 2560 * MIB, "done = percent of total")
	eq(p["eta"], 360, "eta 00:06:00")
	eq(p["rate"], 21.33 * MIB, "raw download rate")
	eq(p["unit"], "bytes", "bytes")


func test_legendary_verify_with_carriage_returns() -> void:
	var p := _feed("legendary", "legendary_verify.log")
	eq(p["unit"], "files", "verify counts files")
	eq(p["bytes_done"], 200, "files done")
	eq(p["bytes_total"], 400, "files total")
	eq(p["percent"], 50.0, "percent")
	eq(p["phase"], "verify", "phase")


func test_gogdl_and_nile() -> void:
	var g := _feed("gogdl", "gogdl_download.log")
	eq([g["bytes_done"], g["bytes_total"], g["eta"], g["percent"]], [104857600, 1048576000, 90, 10.0], "gogdl bytes written/total")
	eq(g["rate"], 8.0 * MIB, "gogdl rate")
	var n := _feed("nile", "nile_install.log")
	eq([n["bytes_done"], n["bytes_total"], n["eta"]], [524288000, 1048576000, 50], "nile")
	eq(n["rate"], 10.0 * MIB, "nile rate")


func test_lines_that_change_nothing() -> void:
	var p := Progress.empty()
	ok(not Progress.parse_line("legendary", "[cli] INFO: Preparing download", p), "chatter")
	ok(not Progress.parse_line("unknown", "= Progress: 1.00 1/2, ETA: 00:00:01", p), "unknown tool")
	eq(Progress.hms("01:02:03"), 3723, "hms")
	eq(Progress.hms("bad"), -1, "bad hms")


func test_size_probes() -> void:
	var d := "stores/data/size/"
	eq(Progress.parse_size("legendary", FileAccess.get_file_as_string(fixture(d + "legendary_info.json"))), 15754981376, "legendary disk_size after a log line")
	eq(Progress.parse_size("gogdl", FileAccess.get_file_as_string(fixture(d + "gogdl_info.json"))), 1200000000, "gogdl size.*.disk_size")
	eq(Progress.parse_size("nile", FileAccess.get_file_as_string(fixture(d + "nile_info.json"))), 2147483648, "nile download_size")
	eq(Progress.parse_size("nile", "no json here"), 0, "unknown")


func test_runner_wraps_commands() -> void:
	var argv := JobRunner.wrap_command(["legendary", "install", "Quail"], {"LEGENDARY_CONFIG_PATH": "/c", "A": "1"})
	eq(argv, PackedStringArray(["env", "PYTHONUNBUFFERED=1", "A=1", "LEGENDARY_CONFIG_PATH=/c",
		"sh", "-c", "exec \"$@\" 2>&1", "gamecove-job", "legendary", "install", "Quail"]), "merged stderr, env")
