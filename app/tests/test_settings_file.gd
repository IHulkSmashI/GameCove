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


func test_damaged_settings_turn_the_privacy_switches_off() -> void:
	# review problem 4: a settings.cfg that can't be read used to give every privacy switch its default (on)
	var Privacy := preload("res://scripts/system/privacy.gd")
	var d := _dir("privacy")
	var p := d.path_join("settings.cfg")
	ok(Privacy.background_allowed(p) and Privacy.metadata_allowed(p), "no file yet: the defaults (on)")
	_write(p, "[privacy\nbackground=fals")
	expect_error("ConfigFile parse error")
	ok(not Privacy.background_allowed(p), "damaged: Background lookups off")
	ok(not Privacy.metadata_allowed(p), "damaged: game details off")
	SettingsFile.reset_for_tests()   # the next start: the damaged copy sits at settings.cfg.bad
	ok(not Privacy.background_allowed(p), "still off on the next start")
	_write(p, "[device]\nreal_photo=true\n")   # another setting saved meanwhile
	ok(not Privacy.metadata_allowed(p), "a new file without the switch doesn't turn it back on")
	ok(Privacy.set_background_allowed(true, p) and Privacy.background_allowed(p), "the user turns it on again")
	ok(not Privacy.metadata_allowed(p), "the other switch stays off until it's set")


func test_damaged_discover_settings_turn_price_lookups_off() -> void:
	var dir := "user://test_settings_file_disc_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	_write(ProjectSettings.globalize_path(dir.path_join("settings.json")), "{\"price_lookups\": tr")
	var d: Node = Discover.new()
	d.data_dir = dir
	expect_error("couldn't be read")
	d.load_all()
	ok(not d.prices_allowed(), "damaged settings.json: no price lookups")
	d.free()
	_wipe(ProjectSettings.globalize_path(dir))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))


## Review H9 follow-up: steam_dev.cfg and the next-session question are written atomically too. A write through
## a symlink shows the difference: in place it changes the link's target, atomically it replaces the link.
func _linked(d: String, name: String, text: String) -> String:
	var target := d.path_join(name + ".target")
	_write(target, text)
	var p := d.path_join(name)
	DirAccess.open(d).create_link(target, p)
	return target


func test_steam_dev_cfg_and_session_question_written_atomically() -> void:
	var d := _dir("more_atomic")
	var target := _linked(d, "steam_dev.cfg", "keep me\n")
	ok(preload("res://scripts/controls/perf/launch_files.gd").set_shader_threads(d, 4), "written")
	eq(FileAccess.get_file_as_string(target), "keep me\n", "steam_dev.cfg replaced, not written in place")
	ok(FileAccess.get_file_as_string(d.path_join("steam_dev.cfg")).contains("unShaderBackgroundProcessingThreads 4"), "new value")
	var Guard := preload("res://scripts/ui/controls/session_guard.gd")
	var old_path: String = Guard.path
	var t2 := _linked(d, "controls_confirm.json", "{}")
	Guard.path = d.path_join("controls_confirm.json")
	Guard.remember("display.x", "X", 1, 2, "two")
	eq(FileAccess.get_file_as_string(t2), "{}", "the question file replaced, not written in place")
	eq(Guard.pending().get("id"), "display.x", "and readable")
	Guard.path = old_path


## Review 2, problem 2: on a full disk a small save returned OK and left a 0-byte
## file (seen on a 64 KiB tmpfs). A short write must keep the old file.
func test_short_write_keeps_the_old_file() -> void:
	var d := _dir("short")
	var p := d + "/power.cfg"
	_write(p, "[device]\ncharge_limit=80\n")
	SettingsFile.test_write_limit = 0
	var cfg := ConfigFile.new()
	cfg.set_value("device", "charge_limit", 60)
	ok(SettingsFile.save_cfg(cfg, p) != OK, "a short write is an error, not OK")
	SettingsFile.test_write_limit = 5
	ok(SettingsFile.save_cfg(cfg, p) != OK, "a partial write is an error too")
	SettingsFile.test_write_limit = -1
	eq(FileAccess.get_file_as_string(p), "[device]\ncharge_limit=80\n", "the old file is untouched")
	ok(not FileAccess.file_exists(p + ".tmp"), "no temp file left")
	eq(SettingsFile.save_cfg(cfg, p), OK, "saves again once there is room")


## The hand-rolled writers review 2 listed go through the same checked path.
func test_hand_rolled_writers_keep_the_old_file_on_a_short_write() -> void:
	var d := _dir("writers")
	var Health := preload("res://scripts/system/session_health.gd")
	var Overrides := preload("res://scripts/library/art/art_overrides.gd")
	var LaunchFiles := preload("res://scripts/controls/perf/launch_files.gd")
	var SessionEnv := preload("res://scripts/controls/display/session_env.gd")
	var StoreCommands := preload("res://scripts/library/manage/store_commands.gd")
	var VdfWriter := preload("res://scripts/steam/vdf_writer.gd")
	var hb := d + "/heartbeat"
	var h: Node = Health.new(hb)
	var ctx := {"home": d}
	var vdf := d + "/localconfig.vdf"
	var steps := {
		"heartbeat": [hb, func(): return h.beat()],
		"art overrides": [Overrides.index_path(d + "/art"), func(): return Overrides.write(d + "/art", {"x": {"cover": "y"}})],
		"perf env": [LaunchFiles.perf_env_path(d, "1"), func(): return LaunchFiles.write_env(d, "1", {"DXVK_HUD": "fps"})],
		"session env": [SessionEnv.path(ctx), func(): return SessionEnv.set_values(ctx, {"ORIENTATION": "left"})],
		"gog record": [d + StoreCommands.GOG_RECORD, func(): return StoreCommands.write_gog_record(d, [{"appName": "1"}]) == OK],
		"vdf": [vdf, func(): return VdfWriter.save(vdf, {"a": {"b": "c"}}) == OK],
	}
	for name in steps:
		var p: String = steps[name][0]
		var fn: Callable = steps[name][1]
		ok(fn.call(), "%s: writes normally" % name)
		var before := FileAccess.get_file_as_bytes(p)
		ok(before.size() > 0, "%s: wrote something" % name)
		SettingsFile.test_write_limit = 0
		ok(not fn.call(), "%s: a short write reports failure" % name)
		SettingsFile.test_write_limit = -1
		eq(FileAccess.get_file_as_bytes(p), before, "%s: the old file is kept" % name)
	h.free()

