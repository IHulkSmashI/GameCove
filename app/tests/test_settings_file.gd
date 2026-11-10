extends "res://tests/test_case.gd"
## Settings files (review H9): atomic writes, a damaged file is kept as <path>.bad and
## never replaced in the same run, and no store calls ConfigFile.save() by itself.

const SettingsFile := preload("res://scripts/system/settings_file.gd")
const PerfStore := preload("res://scripts/controls/perf/store.gd")
const PowerScript := preload("res://scripts/device/power.gd")
const ProfilesScript := preload("res://scripts/controls/profiles.gd")
const Discover := preload("res://scripts/discover/discover.gd")
const Runner := preload("res://tests/fixtures/power/fake_runner.gd")


func _dir(name: String) -> String:
	var d := OS.get_user_data_dir().path_join("test_settings_file").path_join(name)
	_wipe(d)
	DirAccess.make_dir_recursive_absolute(d)
	SettingsFile.reset_for_tests()
	return d


func _wipe(d: String) -> void:
	var da := DirAccess.open(d)
	if da == null:
		return
	for f in da.get_files():
		DirAccess.remove_absolute(d.path_join(f))
	for s in da.get_directories():
		_wipe(d.path_join(s))
		DirAccess.remove_absolute(d.path_join(s))


func _write(p: String, text: String) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func test_atomic_write_leaves_no_tmp_and_reads_back() -> void:
	var d := _dir("atomic")
	var cfg := ConfigFile.new()
	cfg.set_value("a", "b", 3)
	eq(SettingsFile.save_cfg(cfg, d + "/x.cfg"), OK, "saved")
	ok(not FileAccess.file_exists(d + "/x.cfg.tmp"), "no temp file left")
	eq(SettingsFile.load_cfg(d + "/x.cfg").get_value("a", "b", 0), 3, "reads back")
	eq(SettingsFile.update_cfg(d + "/x.cfg", func(c): c.set_value("a", "c", 4)), OK, "update")
	var back := SettingsFile.load_cfg(d + "/x.cfg")
	eq([back.get_value("a", "b", 0), back.get_value("a", "c", 0)], [3, 4], "update kept the rest")


## Proof 9.11 A: one damaged line wiped every other game's values on the next set_value.
func test_damaged_perf_store_is_kept_and_not_overwritten() -> void:
	var d := _dir("perf")
	var p := d + "/perf_controls.cfg"
	var damaged := "[perf/steam:1@unknown]\nfps=40\n\n[perf/steam:2@unknown]\nfps=30\n\n[perf/steam:3@unknown]\nfps=\"unterminated\n"
	_write(p, damaged)
	var st = PerfStore.new(p, "unknown")
	expect_error("ConfigFile parse error")
	st.get_value("steam:1", "fps", "MISSING")
	eq(st.set_value("steam:9", "fps", 60), false, "the save is refused")
	eq(FileAccess.get_file_as_string(p + ".bad"), damaged, "the damaged file is kept as .bad")
	ok(not FileAccess.file_exists(p) or FileAccess.get_file_as_string(p) == "", "nothing written over it")
	ok(SettingsFile.blocked(p), "blocked for this run")


## Proof 9.11 A2 for power.cfg: a damaged file must not become an empty one with the
## next remembered value (the charge limit and first-run flags were lost).
func test_damaged_power_cfg_is_not_replaced() -> void:
	var d := _dir("power")
	var p := d + "/power.cfg"
	var damaged := "[device@unknown]\ncharge_limit=80\nfan_mode=\"qu"
	_write(p, damaged)
	var power: Node = PowerScript.new()
	power.setup(Runner.new(), {}, d)
	power.config_path = p
	expect_error("ConfigFile parse error")
	power._remember("profile", "battery", "balanced")
	eq(FileAccess.get_file_as_string(p + ".bad"), damaged, "kept as .bad")
	ok(not FileAccess.file_exists(p), "not replaced by a file holding only the new value")
	power.free()


## Proof 9.11 B: a truncated wishlist.json loaded as empty and was saved over.
func test_truncated_wishlist_is_not_saved_over() -> void:
	var d := _dir("discover")
	var a = Discover.new()
	a.data_dir = d
	a.load_all()
	a.add_to_wishlist({"store": "steam", "id": "620", "title": "Portal 2"})
	a.add_to_wishlist({"store": "steam", "id": "400", "title": "Portal"})
	var wl := d + "/wishlist.json"
	var txt := FileAccess.get_file_as_string(wl)
	_write(wl, txt.substr(0, txt.length() / 2))
	var b = Discover.new()
	b.data_dir = d
	b.load_all()
	b.add_to_wishlist({"store": "steam", "id": "70", "title": "Half-Life"})
	eq(FileAccess.get_file_as_string(wl + ".bad"), txt.substr(0, txt.length() / 2), "damaged list kept")
	ok(not FileAccess.file_exists(wl), "not replaced by the one-item list")
	a.free()
	b.free()


## A profiles file from a newer build (unknown format) was replaced after a downgrade.
func test_profiles_of_unknown_format_are_kept() -> void:
	var d := _dir("profiles")
	var p := d + "/profiles.json"
	_write(p, "{\"format\": \"gamecove-profiles-v9\", \"devices\": {}}")
	var prof: Node = ProfilesScript.new()
	prof.setup(null, "unknown", p)
	prof.set_value("", "", "power.tdp", 10)
	ok(FileAccess.file_exists(p + ".bad"), "newer file kept as .bad")
	ok(not FileAccess.file_exists(p), "and not replaced")
	prof.free()


## No store writes a ConfigFile by itself: everything goes through SettingsFile.
func test_lint_no_raw_configfile_save() -> void:
	var bad: Array = []
	_scan("res://scripts", bad)
	eq(bad, [], "raw .save( calls outside settings_file.gd")


func _scan(dir: String, out: Array) -> void:
	for f in DirAccess.get_files_at(dir):
		if not f.ends_with(".gd") or f == "settings_file.gd":
			continue
		var lines := FileAccess.get_file_as_string(dir.path_join(f)).split("\n")
		for i in lines.size():
			var l := lines[i].strip_edges()
			if l.begins_with("#"):
				continue
			var re := RegEx.create_from_string("(?<![A-Za-z_])([A-Za-z_][A-Za-z_0-9]*)\\.save\\(")
			for m in re.search_all(l):
				if m.get_string(1) != "VdfWriter":
					out.append("%s:%d %s" % [dir.path_join(f), i + 1, l])
	for s in DirAccess.get_directories_at(dir):
		_scan(dir.path_join(s), out)
