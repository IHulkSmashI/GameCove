extends RefCounted
## The services a settings or setup screen talks to, by short name. Screens get
## them passed in (fakes in tests); `from_tree()` is the fallback that looks up
## the autoloads when a host didn't pass any. It returns {} under the test
## runner, so tests never reach the real system.

## Short name -> autoload node name.
const AUTOLOADS := {
	"device": "Device", "power": "Power", "library": "Library", "launcher": "Launcher",
	"gamescope": "Gamescope", "discover": "Discover", "art": "Art", "perf": "PerfMonitor",
	"achievements": "Achievements", "updates": "Updates", "storage": "Storage",
	"setup": "Setup", "controller": "Controller",
	"controls": "Controls", "profiles": "Profiles",
}


static func under_tests(node: Node) -> bool:
	if node == null or not node.is_inside_tree():
		return true
	var s = node.get_tree().get_script()
	return s != null and str(s.resource_path).begins_with("res://tests/")


## {short name: autoload} for every autoload that exists; {} under tests.
static func from_tree(node: Node) -> Dictionary:
	var out := {}
	if under_tests(node):
		return out
	for k in AUTOLOADS:
		var n := node.get_node_or_null("/root/" + AUTOLOADS[k])
		if n != null:
			out[k] = n
	return out


## True when `svc` has every method in `methods`.
static func has_all(svc: Object, methods: Array) -> bool:
	if svc == null:
		return false
	for m in methods:
		if not svc.has_method(m):
			return false
	return true
