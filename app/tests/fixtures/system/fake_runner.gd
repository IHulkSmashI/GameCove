extends RefCounted
## Stands in for scripts/system/proc.gd in tests: canned output per command,
## every call recorded. Nothing real ever runs.
##
## Keys are "program arg1 arg2 ..." with busctl's --timeout=N and --json=short
## left out. A key ending in "*" matches any command starting with the rest.
## Values: {"code": int, "out": String} or {"code": int, "file": "<fixture path>"}.
## Unknown commands return code 127 (not found).

var responses := {}
var calls: Array[String] = []
## Optional func(cmd: String) -> Variant: a Dictionary answer, or null to fall through.
var handler: Callable


func _key(program: String, args: PackedStringArray) -> String:
	var shown := Array(args).filter(func(x): return not x.begins_with("--timeout=") and x != "--json=short")
	return program + (" " + " ".join(PackedStringArray(shown)) if shown.size() > 0 else "")


func _answer(cmd: String) -> Dictionary:
	if handler.is_valid():
		var h: Variant = handler.call(cmd)
		if h is Dictionary:
			return _resolve(h)
	if responses.has(cmd):
		return _resolve(responses[cmd])
	var best := ""
	for k in responses:
		var s: String = k
		if s.ends_with("*") and cmd.begins_with(s.trim_suffix("*")) and s.length() > best.length():
			best = s
	if best != "":
		return _resolve(responses[best])
	return {"code": 127, "out": ""}


func _resolve(r: Dictionary) -> Dictionary:
	if r.has("file"):
		return {"code": int(r.get("code", 0)), "out": FileAccess.get_file_as_string(r["file"])}
	return {"code": int(r.get("code", 0)), "out": str(r.get("out", ""))}


func run(program: String, args: PackedStringArray) -> Dictionary:
	var cmd := _key(program, args)
	calls.append(cmd)
	return _answer(cmd)


func stream(program: String, args: PackedStringArray, on_line: Callable) -> int:
	var cmd := _key(program, args)
	calls.append(cmd)
	var r := _answer(cmd)
	for line in str(r["out"]).split("\n", false):
		on_line.call(line)
	return int(r["code"])


func called(prefix: String) -> bool:
	for c in calls:
		if c.begins_with(prefix):
			return true
	return false
