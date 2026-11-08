extends RefCounted
## Runs an outside command and returns its exit code and output. The Gamescope
## service only talks to the system through this, so tests can swap in a fake
## runner with canned output and nothing real is touched.


## Returns {"exit": int, "output": String}. exit is -1 if the program is missing.
func run(program: String, args: PackedStringArray) -> Dictionary:
	var out: Array = []
	var code := OS.execute(program, args, out, true)
	return {"exit": code, "output": "".join(PackedStringArray(out))}
