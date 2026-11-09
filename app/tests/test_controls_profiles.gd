extends "res://tests/test_case.gd"

const ControlsScript := preload("res://scripts/controls/controls.gd")
const Ctl := preload("res://scripts/controls/control.gd")
const ProfilesScript := preload("res://scripts/controls/profiles.gd")


class FakePower extends RefCounted:
	signal changed(state: Dictionary)
	var plugged := false


class FakeSession extends Node:
	signal started(game: Dictionary)
	signal ended(game: Dictionary)


var _store: Dictionary
var _reg: Node
var _files: Array[String] = []


func _path() -> String:
	var p := OS.get_user_data_dir().path_join("test_profiles_%d_%d.json" % [Time.get_ticks_usec(), randi()])
	_files.append(p)
	return p


func _cleanup() -> void:
	for f in _files:
		DirAccess.remove_absolute(f)
	_files.clear()
	if _reg != null:
		_reg.free()
		_reg = null


func _ctl(id: String, spec := {}) -> RefCounted:
	var base := {"id": id, "title": id, "group": id.get_slice(".", 0), "kind": "slider",
		"min_value": 0.0, "max_value": 100.0, "step": 1.0}
	base.merge(spec, true)
	var store := _store
	return Ctl.make(base, func(_c): return "",
		func(_c): return store.get(id),
		func(_c, v): store[id] = v; return true)


## Registry with power.tdp (5..30 W), perf.fps (choice), display.brightness
## (not per game) and controller.gyro (unavailable).
func _setup(path := "") -> Node:
	_store = {"power.tdp": 15.0, "perf.fps": 60, "display.brightness": 50.0, "controller.gyro": false}
	_reg = ControlsScript.new()
	_reg.sync_mode = true
	_reg.setup({"sys_root": "/nonexistent", "runner": null, "home": "", "device": null})
	_reg.register(_ctl("power.tdp", {"min_value": 5.0, "max_value": 30.0, "apply_order": 10}))
	_reg.register(_ctl("perf.fps", {"kind": "choice", "options": [{"value": 30}, {"value": 40}, {"value": 60}]}))
	_reg.register(_ctl("display.brightness", {"group": "display", "per_game": false}))
	_reg.register(Ctl.make({"id": "controller.gyro", "group": "controller", "kind": "toggle"},
		func(_c): return "Needs InputPlumber", func(_c): return false, func(_c, _v): return true))
	var p = ProfilesScript.new()
	p.setup(_reg, "msi-claw-8-ex", path if path != "" else _path())
	return p


func test_precedence_and_explain() -> void:
	var p = _setup()
	p.set_layer("", "", {"power.tdp": 10})
	p.set_layer("", "ac", {"power.tdp": 20, "perf.fps": 40})
	p.set_layer("g:1", "", {"power.tdp": 25})
	p.set_layer("g:1", "ac", {"perf.fps": 30})
	eq(p.effective("", "battery"), {"power.tdp": 10}, "global only on battery")
	eq(p.effective("", "ac"), {"power.tdp": 20, "perf.fps": 40}, "source over global")
	eq(p.effective("g:1", "ac"), {"power.tdp": 25, "perf.fps": 30}, "game+source > game > source")
	eq(p.explain("g:1", "ac"), {"power.tdp": "game", "perf.fps": "game+ac"}, "explain")
	eq(p.explain("g:1", "battery"), {"power.tdp": "game"}, "explain battery")
	p.free()
	_cleanup()


func test_game_start_applies_and_end_restores_baseline() -> void:
	var p = _setup()
	_reg.detect_all()
	eq(p._first_detect_done, true, "first detection seen")
	p.set_layer("g:1", "", {"power.tdp": 25, "perf.fps": 40})
	eq(_store["power.tdp"], 15.0, "other game's profile not applied at home")
	p.game_started({"key": "g:1", "title": "Game One"})
	eq(_store["power.tdp"], 25.0, "game tdp applied")
	eq(_store["perf.fps"], 40, "game fps applied")
	p.game_ended({"key": "g:1"})
	eq(_store["power.tdp"], 15.0, "tdp back to what it was")
	eq(_store["perf.fps"], 60, "fps back to what it was")
	eq(p._baseline, {}, "baseline dropped")
	p.free()
	_cleanup()


func test_end_restores_global_over_baseline() -> void:
	var p = _setup()
	_reg.detect_all()
	p.set_layer("", "", {"power.tdp": 12})
	eq(_store["power.tdp"], 12.0, "global edit applies at home")
	p.set_layer("g:1", "", {"power.tdp": 28})
	p.game_started({"key": "g:1"})
	eq(_store["power.tdp"], 28.0, "game")
	p.game_ended()
	eq(_store["power.tdp"], 12.0, "global restored")
	p.free()
	_cleanup()


func test_ac_change_switches_layers_mid_game() -> void:
	var p = _setup()
	var pw := FakePower.new()
	p.attach_power(pw)
	_reg.detect_all()
	eq(p.source, "battery", "on battery")
	p.set_layer("g:1", "battery", {"power.tdp": 12})
	p.set_layer("g:1", "ac", {"power.tdp": 30, "perf.fps": 30})
	p.game_started({"key": "g:1"})
	eq(_store["power.tdp"], 12.0, "battery layer")
	pw.plugged = true
	pw.changed.emit({})
	eq(p.source, "ac", "source follows Power")
	eq(_store["power.tdp"], 30.0, "ac layer")
	eq(_store["perf.fps"], 30, "ac-only value")
	pw.plugged = false
	pw.changed.emit({})
	eq(_store["power.tdp"], 12.0, "battery again")
	eq(_store["perf.fps"], 60, "ac-only value restored to baseline")
	pw.changed.emit({})   # no change: nothing re-applied
	p.game_ended()
	eq(_store["power.tdp"], 15.0, "home")
	p.free()
	_cleanup()


func test_session_signals_drive_it() -> void:
	var p = _setup()
	_reg.detect_all()
	var s := FakeSession.new()
	p.attach_session(s)
	p.set_layer("g:2", "", {"power.tdp": 22})
	s.started.emit({"key": "g:2"})
	eq(_store["power.tdp"], 22.0, "started applies")
	eq(p.game_key, "g:2", "game key")
	s.ended.emit({"key": "g:2"})
	eq(_store["power.tdp"], 15.0, "ended restores")
	s.free()
	p.free()
	_cleanup()


func test_switching_games_restores_first() -> void:
	var p = _setup()
	_reg.detect_all()
	p.set_layer("a", "", {"perf.fps": 30})
	p.set_layer("b", "", {"power.tdp": 20})
	p.game_started({"key": "a"})
	p.game_started({"key": "b"})
	eq(_store["perf.fps"], 60, "first game's fps undone")
	eq(_store["power.tdp"], 20.0, "second game's tdp")
	p.free()
	_cleanup()


func test_unknown_unavailable_and_invalid_are_skipped_but_kept() -> void:
	var p = _setup()
	_reg.detect_all()
	var sent := []
	p.applied.connect(func(info): sent.append(info["values"]))
	p.set_layer("g:1", "", {"power.tdp": 99, "perf.fps": 45, "controller.gyro": true,
		"display.brightness": 10, "future.thing": 3})
	p.game_started({"key": "g:1"})
	eq(sent[-1], {"power.tdp": 30.0}, "only tdp sent, clamped; bad choice, unavailable, not-per-game, unknown skipped")
	eq(_store["power.tdp"], 30.0, "clamped to the control's max")
	eq(_store["display.brightness"], 50.0, "brightness never from a profile")
	ok(p.layer("g:1", "").has("future.thing"), "unknown id kept in storage")
	p.free()
	_cleanup()


func test_controls_that_appear_later_get_their_values() -> void:
	var p = _setup()
	_reg.detect_all()
	p.set_layer("", "", {"audio.volume": 40, "power.tdp": 18})
	eq(_store["power.tdp"], 18.0, "known applied")
	_store["power.tdp"] = 25.0   # user changes it by hand
	_reg.detect_all()
	eq(_store["power.tdp"], 25.0, "a re-detection doesn't undo the user's change")
	_reg.register(_ctl("audio.volume", {"group": "audio"}))
	_store["audio.volume"] = 80.0
	_reg.detect_all()
	eq(_store["audio.volume"], 40.0, "late control got its saved value")
	eq(_store["power.tdp"], 25.0, "others untouched")
	p.free()
	_cleanup()


func test_save_current_copy_reset() -> void:
	var p = _setup()
	_reg.detect_all()
	p.game_started({"key": "g:1", "title": "One"})
	_store["power.tdp"] = 21.0
	_store["perf.fps"] = 40
	_reg.detect_all()
	var saved: Dictionary = p.save_current()
	eq(saved, {"power.tdp": 21.0, "perf.fps": 40}, "snapshot of per-game, available controls")
	saved = {"power.tdp": 21, "perf.fps": 40}
	eq(p.layer("g:1", ""), saved, "stored on the running game (whole numbers as int)")
	ok(p.has_profile("g:1"), "has profile")
	eq(p.games()[0]["title"], "One", "running game's title stored with its new profile")
	p.copy("g:1", "", "g:2", "battery")
	eq(p.layer("g:2", "battery"), saved, "copied to another game's battery layer")
	p.copy("g:1", "*", "g:3", "*")
	eq(p.layer("g:3", ""), saved, "whole game copied")
	p.copy("g:3", "*", "g:3", "*")
	eq(p.layer("g:3", ""), saved, "copy onto itself keeps values")
	p.reset("g:1", "*")
	ok(not p.has_profile("g:1"), "reset forgets the game")
	eq(_store["power.tdp"], 15.0, "reset while running puts the baseline back")
	p.reset("g:2", "battery")
	ok(not p.has_profile("g:2"), "layer reset")
	p.set_value("", "", "power.tdp", 9)
	eq(p.layer(), {"power.tdp": 9}, "set_value")
	p.set_value("", "", "power.tdp", null)
	eq(p.layer(), {}, "set_value null removes")
	p.set_value("", "", "bad", [1])
	eq(p.layer(), {}, "non-plain values refused")
	p.free()
	_cleanup()


func test_persists_per_device_atomically() -> void:
	var path := _path()
	var p = _setup(path)
	p.set_layer("", "ac", {"power.tdp": 30})
	p.set_layer("g:1", "", {"perf.fps": 40})
	ok(FileAccess.file_exists(path), "saved")
	ok(not FileAccess.file_exists(path + ".tmp"), "no temp file left")
	p.free()
	var q = ProfilesScript.new()
	q.setup(_reg, "MSI Claw 8 EX", path)   # same key after PerDevice.key()
	eq(q.layer("", "ac"), {"power.tdp": 30}, "reloaded")
	eq(q.layer("g:1", ""), {"perf.fps": 40}, "game reloaded")
	q.free()
	var other = ProfilesScript.new()
	other.setup(_reg, "steam-deck-oled", path)
	eq(other.layer("", "ac"), {}, "another handheld sees none of it")
	other.set_layer("", "", {"power.tdp": 10})
	other.free()
	var again = ProfilesScript.new()
	again.setup(_reg, "msi-claw-8-ex", path)
	eq(again.layer("", "ac"), {"power.tdp": 30}, "claw kept after the deck saved")
	again.free()
	_cleanup()


func test_damaged_file_is_ignored() -> void:
	var path := _path()
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("{not json")
	f.close()
	var p = _setup(path)
	eq(p.effective(), {}, "empty after a damaged file")
	p.set_layer("", "", {"power.tdp": 10})
	eq(p.layer(), {"power.tdp": 10}, "works and overwrites")
	p.free()
	_cleanup()


func test_export_import_game_and_device() -> void:
	var p = _setup()
	p.set_layer("g:1", "", {"power.tdp": 25, "x.unknown": "keep"})
	p.set_layer("g:1", "ac", {"perf.fps": 30})
	var text: String = p.export_json("g:1")
	var d: Dictionary = JSON.parse_string(text)
	eq(d["format"], "gamecove-profiles", "format tag")
	eq(d["game"], "g:1", "game key")
	eq(d["device"], "msi-claw-8-ex", "device")
	var r: Dictionary = p.import_json(text, "g:9")
	ok(r["ok"], "imported")
	eq(r["values"], 3, "value count")
	eq(p.layer("g:9", ""), {"power.tdp": 25, "x.unknown": "keep"}, "imported into another game")
	eq(p.layer("g:9", "ac"), {"perf.fps": 30}, "ac layer")
	var whole: String = p.export_json()
	p.reset_all()
	eq(p.games(), [], "all gone")
	var r2: Dictionary = p.import_json(whole)
	ok(r2["ok"], "device import")
	eq(p.games().size(), 2, "both games back")
	ok(not p.import_json("{}")["ok"], "foreign json refused")
	ok(not p.import_json("[1,2]")["ok"], "non-object refused")
	ok(not p.import_json(JSON.stringify({"format": "gamecove-profiles", "version": 99, "game": "x"}))["ok"], "newer version refused")
	var mixed := JSON.stringify({"format": "gamecove-profiles", "version": 1, "game": "g:5",
		"all": {"power.tdp": 20, "bad": {"nested": 1}, "": 3}})
	var r3: Dictionary = p.import_json(mixed)
	ok(r3["ok"], "imported with bad entries dropped")
	eq(p.layer("g:5", ""), {"power.tdp": 20}, "only plain values")
	p.free()
	_cleanup()


func test_import_from_another_handheld_is_clamped_on_apply() -> void:
	var p = _setup()
	_reg.detect_all()
	var text := JSON.stringify({"format": "gamecove-profiles", "version": 1, "device": "gpd-win-5",
		"game": "g:1", "all": {"power.tdp": 85}})
	var r: Dictionary = p.import_json(text)
	eq(r["from_device"], "gpd-win-5", "source device reported")
	p.game_started({"key": "g:1"})
	eq(_store["power.tdp"], 30.0, "85 W from a Win 5 becomes this device's 30 W max")
	p.free()
	_cleanup()
