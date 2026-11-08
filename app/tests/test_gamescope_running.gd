extends "res://tests/test_case.gd"
## Gamescope.is_running(): environment first, then the root-window probe.

const GamescopeScript := preload("res://scripts/gamescope/gamescope.gd")


class CannedRunner:
	extends RefCounted
	var reply := {"exit": 0, "output": ""}
	var count := 0

	func run(_program: String, _args: PackedStringArray) -> Dictionary:
		count += 1
		return reply


func _make(env: Dictionary, reply: Dictionary) -> Array:
	var g = GamescopeScript.new()
	var r := CannedRunner.new()
	r.reply = reply
	g.runner = r
	g.env = env
	return [g, r]


func test_session_env_means_running_without_commands() -> void:
	var m := _make({"GAMESCOPE_WAYLAND_DISPLAY": "gamescope-0"}, {})
	ok(m[0].is_running(), "running")
	eq(m[1].count, 0, "no probe needed")
	m[0].free()


func test_root_atom_probe() -> void:
	var m := _make({"GAMESCOPE_WAYLAND_DISPLAY": "", "DISPLAY": ":0"},
		{"exit": 0, "output": "GAMESCOPE_FOCUSABLE_APPS = 769, 976730\n"})
	ok(m[0].is_running(), "detected from root atom")
	ok(m[0].is_running(), "second call")
	eq(m[1].count, 1, "probe result cached")
	m[0].free()


func test_plain_x_server_is_not_gamescope() -> void:
	var m := _make({"GAMESCOPE_WAYLAND_DISPLAY": "", "DISPLAY": ":0"},
		{"exit": 0, "output": "GAMESCOPE_FOCUSABLE_APPS:  no such atom on any window.\n"})
	ok(not m[0].is_running(), "plain X")
	m[0].free()


func test_no_display_no_probe() -> void:
	var m := _make({"GAMESCOPE_WAYLAND_DISPLAY": "", "DISPLAY": ""}, {})
	ok(not m[0].is_running(), "headless")
	eq(m[1].count, 0, "no probe without DISPLAY")
	m[0].free()


func test_missing_xprop_is_not_running() -> void:
	var m := _make({"GAMESCOPE_WAYLAND_DISPLAY": "", "DISPLAY": ":0"}, {"exit": -1, "output": ""})
	ok(not m[0].is_running(), "xprop missing")
	m[0].free()
