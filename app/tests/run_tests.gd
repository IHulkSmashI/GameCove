extends SceneTree
## godot --headless --path app -s res://tests/run_tests.gd
## Runs every res://tests/test_*.gd; exits 1 if anything fails.

func _initialize() -> void:
	var failed := 0
	var passed := 0
	var dir := DirAccess.open("res://tests")
	var files := Array(dir.get_files()).filter(func(f): return f.begins_with("test_") and f.ends_with(".gd") and f != "test_case.gd")
	files.sort()
	for f in files:
		var script: GDScript = load("res://tests/" + f)
		var t = script.new()
		for m in t.get_method_list():
			var name: String = m["name"]
			if not name.begins_with("test_"):
				continue
			var before: int = t.failures.size()
			t._current = "%s::%s" % [f, name]
			t.call(name)
			if t.failures.size() > before:
				failed += 1
				for msg in t.failures.slice(before):
					printerr("FAIL ", msg)
			else:
				passed += 1
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)
