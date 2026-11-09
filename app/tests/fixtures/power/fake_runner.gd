extends RefCounted
## Stands in for scripts/device/command_runner.gd in tests. Acts as a tiny fake
## D-Bus loaded from a fixture JSON of busctl output, and records every command.
##
## Fixture shape: {"props": {"<bus> get-property <service> <path> <iface> <prop>": {"type": "d", "data": 25.0}},
##                 "methods": {"<bus> call <service> <path> <iface> <method>": {"type": "ao", "data": [[...]]}}}

var props: Dictionary = {}
var methods: Dictionary = {}
## get-property keys whose set-property "succeeds" but changes nothing (read-back failure).
var frozen: Array[String] = []
var calls: Array[String] = []
## Optional func(argv: PackedStringArray) -> int, or -> {"code", "out"}, for non-busctl commands
## (pkexec, systemctl).
var exec_handler: Callable


static func from_fixture(path: String) -> RefCounted:
	var r = load("res://tests/fixtures/power/fake_runner.gd").new()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) == TYPE_DICTIONARY:
		r.props = parsed.get("props", {})
		r.methods = parsed.get("methods", {})
	return r


func run(program: String, args: PackedStringArray) -> Dictionary:
	var shown := Array(args).filter(func(x): return not x.begins_with("--timeout="))
	calls.append(program + " " + " ".join(PackedStringArray(shown)))
	if program != "busctl":
		var argv := PackedStringArray([program])
		argv.append_array(args)
		if exec_handler.is_valid():
			var r: Variant = exec_handler.call(argv)
			return r if r is Dictionary else {"code": int(r), "out": ""}
		return {"code": 0, "out": ""}
	var a := Array(args).filter(func(x): return x != "--json=short" and not x.begins_with("--timeout="))
	var bus: String = a[0]
	match a[1]:
		"get-property":
			var key := " ".join(PackedStringArray(a.slice(0, 6)))
			if props.has(key):
				return {"code": 0, "out": JSON.stringify(props[key])}
		"set-property":
			var key := " ".join(PackedStringArray([bus, "get-property"] + a.slice(2, 6)))
			if props.has(key):
				if not key in frozen:
					var sig: String = a[6]
					var raw: String = a[7]
					props[key]["data"] = float(raw) if sig == "d" else (int(raw) if sig in ["u", "i"] else (raw == "true" if sig == "b" else raw))
				return {"code": 0, "out": ""}
		"call":
			var key := " ".join(PackedStringArray(a.slice(0, 6)))
			if methods.has(key):
				return {"code": 0, "out": JSON.stringify(methods[key])}
	return {"code": 1, "out": ""}
