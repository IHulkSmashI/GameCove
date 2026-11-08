extends RefCounted
## Small D-Bus client on top of `busctl --json=short` (part of systemd, so no
## extra dependency). Property reads return null when the service, object,
## interface or property is missing.
##
## Output shapes (systemd 255): get-property -> {"type":"d","data":17.0};
## call -> {"type":"ao","data":[[...first out arg...]]}.

var runner: RefCounted
## "--system" (PowerStation) or "--user" (steamos-manager's public API).
var bus: String
## Seconds before busctl gives up (its default is 25 s; a stuck service must not
## freeze the UI).
var timeout_s := 2


func _init(command_runner: RefCounted, which_bus: String) -> void:
	runner = command_runner
	bus = which_bus


func get_prop(service: String, path: String, iface: String, prop: String) -> Variant:
	var r: Dictionary = runner.run("busctl", PackedStringArray([bus, _timeout(), "--json=short", "get-property", service, path, iface, prop]))
	if int(r.get("code", -1)) != 0:
		return null
	var parsed: Variant = JSON.parse_string(str(r.get("out", "")))
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("data"):
		return null
	return parsed["data"]


func set_prop(service: String, path: String, iface: String, prop: String, signature: String, value: String) -> bool:
	var r: Dictionary = runner.run("busctl", PackedStringArray([bus, _timeout(), "set-property", service, path, iface, prop, signature, value]))
	return int(r.get("code", -1)) == 0


## The out arguments of a method call as an Array, or null on failure.
func call_method(service: String, path: String, iface: String, method: String, args: PackedStringArray = PackedStringArray()) -> Variant:
	var argv := PackedStringArray([bus, _timeout(), "--json=short", "call", service, path, iface, method])
	argv.append_array(args)
	var r: Dictionary = runner.run("busctl", argv)
	if int(r.get("code", -1)) != 0:
		return null
	var parsed: Variant = JSON.parse_string(str(r.get("out", "")))
	if typeof(parsed) != TYPE_DICTIONARY:
		return null
	var data: Variant = parsed.get("data", [])
	return data if typeof(data) == TYPE_ARRAY else [data]


func _timeout() -> String:
	return "--timeout=%d" % timeout_s
