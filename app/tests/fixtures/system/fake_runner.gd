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


## How many one-pkexec batches of root steps (installer_service.gd, Commands.batch_script) ran.
var batches := 0


## A batch of root steps: each step is answered like the same command run on its own would be, and the
## markers the real script prints are produced (so the service reads per-step results), but the real
## script is never run. Steps after a failed one that isn't optional don't run, as in the script.
func _batch(script: String, on_line: Callable) -> int:
	batches += 1
	var re := RegEx.create_from_string("'((?:[^']|'\\\\'')*)'")
	var starts := RegEx.create_from_string("echo '@@GC start (\\d+)'")
	var lines := script.split("\n")
	var k := 0
	while k < lines.size():
		var m := starts.search(lines[k])
		if m == null:
			k += 1
			continue
		var i := int(m.get_string(1))
		var run: String = lines[k + 1]
		k += 2
		on_line.call("@@GC start %d" % i)
		if run.begins_with("if [ -e"):
			var live := false
			for pm in RegEx.create_from_string("\\[ -e '([^']*)' \\]").search_all(run):
				live = live or FileAccess.file_exists(pm.get_string(1))
			if not live:
				on_line.call("@@GC pending %d" % i)
				continue
			run = run.substr(run.find("; then ") + 7)
		var main_part := run.split("; rc=$?")[0]
		var words := _words(re, main_part)
		var res := _answer_batch(words, on_line)
		if "echo '@@GC retry" in run and int(res["code"]) != 0:
			on_line.call("@@GC retry %d" % i)
			var fb := run.substr(run.find("echo '@@GC retry") + 1)
			fb = fb.substr(fb.find("; ") + 2).split("; rc=$?")[0]
			res = _answer_batch(_words(re, fb), on_line)
		on_line.call("@@GC end %d %d" % [i, int(res["code"])])
		if int(res["code"]) != 0 and run.ends_with("then exit 0; fi"):
			break
	return 0


func _words(re: RegEx, text: String) -> Array:
	var out: Array = []
	for w in re.search_all(text):
		out.append(w.get_string(1).replace("'\\''", "'"))
	return out


func _answer_batch(words: Array, on_line: Callable) -> Dictionary:
	var cmd := "pkexec " + " ".join(PackedStringArray(words))
	calls.append(cmd)
	var r := _answer(cmd)
	for line in str(r["out"]).split("\n", false):
		on_line.call(line)
	return r


func stream(program: String, args: PackedStringArray, on_line: Callable) -> int:
	if program == "pkexec" and args.size() == 3 and args[0] == "sh" and args[1] == "-c" and "@@GC start" in args[2]:
		# a dismissed password dialog: the whole batch answers like pkexec itself would
		var whole := _answer("pkexec batch")
		if int(whole["code"]) != 0:
			batches += 1
			return int(whole["code"])
		return _batch(args[2], on_line)
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
