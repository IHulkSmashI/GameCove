extends RefCounted
## Services the Controls UI shares across screens that aren't autoloads: one
## Fixes service (scripts/device/fixes.gd) for the quick menu's Device tab
## and Settings > Device > Fixes. Made on first use, never under the test
## runner (tests pass fakes).

const Services := preload("res://scripts/ui/settings/services.gd")
const FIXES := "res://scripts/device/fixes.gd"

static var _fixes: Node


## The shared Fixes service, or null (tests, no Device).
static func fixes(node: Node) -> Node:
	if _fixes != null and is_instance_valid(_fixes):
		return _fixes
	if Services.under_tests(node) or not ResourceLoader.exists(FIXES):
		return null
	# main.gd owns one ("Fixes"): use it rather than making a second
	var owned := node.get_tree().root.find_child("Fixes", true, false)
	if owned != null and owned.has_method("rows") and owned.has_method("counts"):
		_fixes = owned
		return _fixes
	var dev := node.get_node_or_null("/root/Device")
	_fixes = load(FIXES).new()
	_fixes.name = "GameCoveFixes"
	_fixes.setup({"sys_root": "", "home": OS.get_environment("HOME"), "device": dev})
	node.get_tree().root.add_child.call_deferred(_fixes)
	(func():
		if not is_instance_valid(_fixes):
			return
		if _fixes.has_method("check_changes"):
			_fixes.check_changes()
		_fixes.refresh()).call_deferred()
	return _fixes


## An autoload by node name ("Controls", "Profiles") without needing a node in
## the tree; null under the test runner.
static func autoload(node_name: String) -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	var s = tree.get_script()
	if s != null and str(s.resource_path).begins_with("res://tests/"):
		return null
	return tree.root.get_node_or_null(node_name)
