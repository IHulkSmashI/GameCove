extends SceneTree
## Prints every file inside an exported pck, one res:// path per line (packaging/tests/release.sh and the release
## workflow check the licence texts are in it). Run from any folder holding an empty project.godot:
##   godot --headless --path <empty project> -s packaging/tests/pck_files.gd -- <gamecove.pck>


func _walk(dir: String, out: PackedStringArray) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.include_hidden = true
	for sub in d.get_directories():
		_walk(dir.path_join(sub), out)
	for f in d.get_files():
		out.append(dir.path_join(f))


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1 or not ProjectSettings.load_resource_pack(args[0], false):
		printerr("usage: -s pck_files.gd -- <file.pck>")
		quit(2)
		return
	var out := PackedStringArray()
	_walk("res://", out)
	print("\n".join(out))
	quit(0)
