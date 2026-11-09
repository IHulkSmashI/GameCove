extends "res://tests/test_case.gd"
## Every real command runner passes arguments to the program byte for byte.
## These run REAL processes (sh, printf, true/false): Godot 4.7's OS.execute()
## with an output array dropped double quotes and split quoted spaces, which
## broke every JSON argument (InputPlumber busctl calls) on a real Claw while
## the fake-runner tests stayed green.

const ExecSafe := preload("res://scripts/system/exec_safe.gd")
const Proc := preload("res://scripts/system/proc.gd")
const DeviceRunner := preload("res://scripts/device/command_runner.gd")
const GamescopeRunner := preload("res://scripts/gamescope/command_runner.gd")
const BgCommand := preload("res://scripts/ui/bg_command.gd")

## Double quotes, spaces, single quotes, a backslash, a tab, a newline, unicode, JSON.
const NASTY := "{\"a\":\"b c\"} it's a \\back\\slash\tand\nnew line ü 日本 🎮 $HOME `id` *"
const MB := 1048576


## Every runner: [name, Callable(program, args) -> [code, out], folds stderr in].
func _runners() -> Array:
	return [
		["exec_safe", _call.bind("exec_safe"), true],
		["exec_safe quiet", _call.bind("exec_safe quiet"), false],
		["proc", _call.bind("proc"), true],
		["device command_runner", _call.bind("device"), false],
		["gamescope command_runner", _call.bind("gamescope"), true],
		["bg_command SystemRunner", _call.bind("bg"), true],
	]


func _call(program: String, args: PackedStringArray, which: String) -> Array:
	var r: Dictionary
	match which:
		"exec_safe":
			r = ExecSafe.run(program, args)
		"exec_safe quiet":
			r = ExecSafe.run(program, args, false)
		"proc":
			r = Proc.new().run(program, args)
		"device":
			r = DeviceRunner.new().run(program, args)
		"gamescope":
			var g: Dictionary = GamescopeRunner.new().run(program, args)
			return [g["exit"], g["output"]]
		"bg":
			r = BgCommand.SystemRunner.new().run(program, args)
	return [r["code"], r["out"]]


func _dir() -> String:
	var d := ProjectSettings.globalize_path("user://test_exec_safe")
	DirAccess.make_dir_recursive_absolute(d)
	return d


func test_arguments_arrive_byte_for_byte() -> void:
	var file := _dir().path_join("arg.bin")
	for r in _runners():
		DirAccess.remove_absolute(file)
		var run: Callable = r[1]
		# the program writes its first argument to a file: exact bytes, no output decoding involved
		var res: Array = run.call("sh", PackedStringArray(["-c", "printf '%s' \"$1\" > \"$2\"", "sh", NASTY, file]))
		eq(res[0], 0, "%s: sh ran" % r[0])
		eq(FileAccess.get_file_as_bytes(file), NASTY.to_utf8_buffer(), "%s: argument bytes intact" % r[0])
		# and echoed back on stdout
		res = run.call("printf", PackedStringArray(["%s", NASTY]))
		eq(res[1], NASTY, "%s: printf echoes it" % r[0])
		# the exact case that broke on the Claw
		res = run.call("printf", PackedStringArray(["[%s]", "{\"a\":\"b c\"}"]))
		eq(res[1], "[{\"a\":\"b c\"}]", "%s: JSON with a quoted space" % r[0])
		# several arguments stay several arguments (no re-splitting, no joining)
		res = run.call("sh", PackedStringArray(["-c", "echo $#", "sh", "a b", "", "\"c d\"", "e'f"]))
		eq(res[1].strip_edges(), "4", "%s: argument count kept" % r[0])


func test_exit_codes() -> void:
	for r in _runners():
		var run: Callable = r[1]
		eq(run.call("true", PackedStringArray())[0], 0, "%s: true" % r[0])
		eq(run.call("false", PackedStringArray())[0], 1, "%s: false" % r[0])
		eq(run.call("sh", PackedStringArray(["-c", "exit 3"]))[0], 3, "%s: exit 3" % r[0])
		var missing: int = run.call("gamecove-no-such-program-xyz", PackedStringArray(["x"]))[0]
		ok(missing == 127 or missing == -1, "%s: missing program gives 127 or -1 (got %d)" % [r[0], missing])
		var abs_missing: int = run.call("/nonexistent/gamecove-xyz", PackedStringArray())[0]
		ok(abs_missing == 127 or abs_missing == -1, "%s: missing path gives 127 or -1 (got %d)" % [r[0], abs_missing])
	eq(ExecSafe.run("", PackedStringArray())["code"], -1, "empty program can't start")


func test_stderr_merged_where_it_was() -> void:
	for r in _runners():
		var run: Callable = r[1]
		var res: Array = run.call("sh", PackedStringArray(["-c", "echo out; echo err >&2; exit 2"]))
		eq(res[0], 2, "%s: code" % r[0])
		if r[2]:
			eq(res[1], "out\nerr\n", "%s: stderr folded in" % r[0])
		else:
			eq(res[1], "out\n", "%s: stdout only" % r[0])
	ok("not found" in ExecSafe.run("gamecove-no-such-program-xyz", PackedStringArray())["out"], "sh's not-found line is in the merged output")


func test_large_output_does_not_deadlock() -> void:
	for r in _runners():
		var run: Callable = r[1]
		var res: Array = run.call("sh", PackedStringArray(["-c", "head -c %d /dev/zero | tr '\\0' x" % MB]))
		eq(res[0], 0, "%s: 1 MB stdout code" % r[0])
		eq(res[1].length(), MB, "%s: 1 MB stdout read whole" % r[0])
		# 1 MB on stderr before any stdout: merged or dropped, never left to fill a pipe
		res = run.call("sh", PackedStringArray(["-c", "head -c %d /dev/zero | tr '\\0' y >&2; echo done" % MB]))
		eq(res[0], 0, "%s: 1 MB stderr code" % r[0])
		eq(res[1].length(), MB + 5 if r[2] else 5, "%s: 1 MB stderr handled" % r[0])


func test_game_session_pgrep_uses_real_argv() -> void:
	# steam_launch_alive's pattern has a space and a "(" — must reach pgrep as one argument
	var GameSession := load("res://scripts/launch/game_session.gd")
	eq(GameSession.steam_launch_alive(2147483000), false, "no such game running")


## Lint: nothing in app/scripts may call OS.execute( except exec_safe.gd.
func test_no_os_execute_outside_exec_safe() -> void:
	var bad: Array = []
	_scan("res://scripts", bad)
	eq(bad, [], "OS.execute( outside system/exec_safe.gd (use ExecSafe.run: OS.execute mangles quoted arguments)")


func _scan(dir: String, bad: Array) -> void:
	for sub in DirAccess.get_directories_at(dir):
		_scan(dir.path_join(sub), bad)
	for f in DirAccess.get_files_at(dir):
		if not f.ends_with(".gd"):
			continue
		var path := dir.path_join(f)
		if path == "res://scripts/system/exec_safe.gd":
			continue
		var n := 0
		for line in FileAccess.get_file_as_string(path).split("\n"):
			n += 1
			var code := line.strip_edges()
			if code.begins_with("#"):
				continue
			if "OS.execute(" in code:
				bad.append("%s:%d" % [path, n])
