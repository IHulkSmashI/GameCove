extends "res://tests/test_case.gd"
## Review 2, low 23: caches were never pruned. Temp folder only.

const Prune := preload("res://scripts/system/cache_prune.gd")


func test_old_cache_files_go_and_others_stay() -> void:
	var d := OS.get_temp_dir().path_join("gc_prune_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(d.path_join("steam"))
	for p in ["a.json", "steam/1.json", "keep.txt"]:
		var f := FileAccess.open(d.path_join(p), FileAccess.WRITE)
		f.store_string("x")
		f.close()
	var now := int(Time.get_unix_time_from_system())
	eq(Prune.prune(d, 3600, now), 0, "fresh files stay")
	eq(Prune.prune(d, 3600, now + 7200), 2, "old cache files go, one folder down too")
	ok(not FileAccess.file_exists(d.path_join("steam/1.json")), "the old cache file is gone")
	ok(FileAccess.file_exists(d.path_join("keep.txt")), "other files stay")
	ok(DirAccess.dir_exists_absolute(d.path_join("steam")), "folders stay")
	DirAccess.remove_absolute(d.path_join("keep.txt"))
	DirAccess.remove_absolute(d.path_join("steam"))
	DirAccess.remove_absolute(d)
