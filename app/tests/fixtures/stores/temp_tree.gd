extends RefCounted
## Copies fixture folders into the test user folder so tests can change them,
## and cleans up afterwards. Only ever touches paths under OS.get_user_data_dir().


static func temp_dir(name: String) -> String:
	var p := OS.get_user_data_dir().path_join("test_tmp").path_join(name)
	remove_tree(p)
	DirAccess.make_dir_recursive_absolute(p)
	return p


static func copy_tree(src: String, dst: String) -> void:
	DirAccess.make_dir_recursive_absolute(dst)
	var d := DirAccess.open(src)
	if d == null:
		return
	d.include_hidden = true
	for f in d.get_files():
		DirAccess.copy_absolute(src.path_join(f), dst.path_join(f))
	for sub in d.get_directories():
		copy_tree(src.path_join(sub), dst.path_join(sub))


static func remove_tree(path: String) -> void:
	if not path.begins_with(OS.get_user_data_dir()):
		return
	var d := DirAccess.open(path)
	if d == null:
		return
	d.include_hidden = true
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	for sub in d.get_directories():
		remove_tree(path.path_join(sub))
	DirAccess.remove_absolute(path)
