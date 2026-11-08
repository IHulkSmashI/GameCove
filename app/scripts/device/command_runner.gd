extends RefCounted
## Runs a program and returns what it printed. The one place power code touches
## OS.execute, so tests can swap in fake_runner.gd with canned output.


## {"code": exit code (-1 when it couldn't start), "out": stdout as text}.
func run(program: String, args: PackedStringArray) -> Dictionary:
	var output: Array = []
	var code := OS.execute(program, args, output, false)
	var text := ""
	if output.size() > 0:
		text = str(output[0])
	return {"code": code, "out": text}
