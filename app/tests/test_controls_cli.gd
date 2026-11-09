extends "res://tests/test_case.gd"
## controls_cli.gd: the hardware-test entry point the testbed checks use.

const Cli := preload("res://scripts/hwtest/controls_cli.gd")
const Ctl := preload("res://scripts/controls/control.gd")
const Boot := preload("res://scripts/installer/boot.gd")


func _ctl(spec: Dictionary) -> RefCounted:
	var base := {"id": "power.tdp", "title": "TDP", "group": "power", "kind": "slider",
		"min_value": 5.0, "max_value": 30.0, "step": 1.0, "unit": "W"}
	base.merge(spec, true)
	var c := Ctl.make(base, func(_c): return "", func(_c): return null, func(_c, _v): return true)
	c.available = true
	return c


func test_boot_routes_controls_flag() -> void:
	ok(Boot.wants_controls_cli(PackedStringArray(["--controls", "list"])))
	ok(not Boot.wants_controls_cli(PackedStringArray(["--installer"])))
	eq(Boot.scene_for(PackedStringArray(["--installer"])), Boot.INSTALLER, "installer unchanged")


func test_alt_value_per_kind() -> void:
	var s := _ctl({})
	eq(Cli.alt_value(s, 15.0), 16.0, "a step up")
	eq(Cli.alt_value(s, 30.0), 29.0, "at the top: a step down")
	eq(Cli.alt_value(s, null), null, "no value: nothing to try")
	var t := _ctl({"id": "display.vrr", "kind": "toggle"})
	eq(Cli.alt_value(t, true), false)
	var ch := _ctl({"id": "power.fan_mode", "kind": "choice",
		"options": [{"value": "auto"}, {"value": "quiet"}, {"value": "max"}]})
	eq(Cli.alt_value(ch, "auto"), "quiet")
	eq(Cli.alt_value(ch, "quiet"), "auto", "first different option")
	var num := _ctl({"id": "display.fps_limit", "kind": "choice", "options": [{"value": 0}, {"value": 30}]})
	eq(Cli.alt_value(num, 0.0), 30, "numbers compare across int/float")
	var col := _ctl({"id": "controller.led_color", "kind": "color"})
	eq(Cli.alt_value(col, "#00FF00"), "#ff0000")
	eq(Cli.alt_value(col, "ff8800"), "#00ff00")
	eq(Cli.alt_value(_ctl({"kind": "action"}), true), null, "actions are never probed")


func test_same_tolerates_slider_rounding() -> void:
	var s := _ctl({})
	ok(Cli.same(s, 15.0, 15.4), "within half a step")
	ok(not Cli.same(s, 15.0, 16.0), "a whole step apart")
	ok(Cli.same(_ctl({"kind": "choice"}), 30, 30.0), "int vs float")
	ok(Cli.same(_ctl({"kind": "color"}), "#FF0000", "ff0000"), "colour spelling")
	ok(not Cli.same(s, null, 15.0))
	ok(Cli.same(s, null, null))


func test_parse_value_and_lines() -> void:
	eq(Cli.parse_value("15"), 15.0)
	eq(Cli.parse_value("true"), true)
	eq(Cli.parse_value("\"quiet\""), "quiet")
	eq(Cli.parse_value("quiet"), "quiet", "bare words are strings")
	eq(Cli.line(["probe", "a\tb", "x\ny"]), "probe\ta b\tx y", "fields never break the format")


func test_describe_shapes() -> void:
	var d := Cli.describe(_ctl({}))
	eq(d[0], "control")
	eq(d[1], "power.tdp")
	ok("available=yes" in d)
	ok("shape=5.0..30.0 step 1.0 W" in d, str(d))
	var off := _ctl({"id": "display.hdr", "kind": "toggle"})
	off.available = false
	off.reason = "No HDR panel"
	ok("reason=No HDR panel" in Cli.describe(off))
	var ch := Cli.describe(_ctl({"kind": "choice", "options": [{"value": "auto"}, {"value": 30}]}))
	ok("shape=\"auto\"|30" in ch, str(ch))


class FakeRegistry extends Node:
	signal detected()


class FakeProfiles extends Node:
	var hits := 0
	func _on_detected() -> void:
		hits += 1
	func _on_power_changed(_s: Dictionary = {}) -> void:
		hits += 1


class FakePower extends Node:
	signal changed(state: Dictionary)


func test_profiles_detached() -> void:
	var r := FakeRegistry.new()
	var p := FakeProfiles.new()
	var pw := FakePower.new()
	r.detected.connect(p._on_detected)
	pw.changed.connect(p._on_power_changed)
	Cli.detach_profiles(r, p, pw)
	r.detected.emit()
	pw.changed.emit({})
	eq(p.hits, 0, "a test instance never applies stored profiles by itself")
	Cli.detach_profiles(r, p, pw)   # twice is fine
	Cli.detach_profiles(null, p, null)
	r.free()
	p.free()
	pw.free()


## A controls probe leaves no saved InputPlumber layout behind (the Claw kept
## ~/.config/inputplumber/profiles/gamecove/msi-claw-8-ex/default.yaml after one).
func test_probe_put_back_leaves_no_saved_layout() -> void:
	var home := ProjectSettings.globalize_path("user://test_cli_saved")
	var dir: String = Cli.saved_dir(home)
	DirAccess.make_dir_recursive_absolute(dir + "/other")
	var keep := FileAccess.open(dir + "/other/default.yaml", FileAccess.WRITE)
	keep.store_string("theirs\n")
	keep.close()
	var before: Dictionary = Cli.snapshot_files(dir)
	DirAccess.make_dir_recursive_absolute(dir + "/msi-claw-8-ex")
	var f := FileAccess.open(dir + "/msi-claw-8-ex/default.yaml", FileAccess.WRITE)
	f.store_string("written by the probe\n")
	f.close()
	var g := FileAccess.open(dir + "/other/default.yaml", FileAccess.WRITE)
	g.store_string("changed\n")
	g.close()
	Cli.restore_files(dir, before)
	ok(not FileAccess.file_exists(dir + "/msi-claw-8-ex/default.yaml"), "the probe's file is gone")
	ok(not DirAccess.dir_exists_absolute(dir + "/msi-claw-8-ex"), "and its folder")
	eq(FileAccess.get_file_as_string(dir + "/other/default.yaml"), "theirs\n", "an existing layout gets its bytes back")
	DirAccess.remove_absolute(dir + "/other/default.yaml")
	DirAccess.remove_absolute(dir + "/other")
	Cli.restore_files(dir, {})
	ok(not DirAccess.dir_exists_absolute(dir), "nothing saved before: no folder left")
