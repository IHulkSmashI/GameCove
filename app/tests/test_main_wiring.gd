extends "res://tests/test_case.gd"
## main.gd connects services' signals to its own methods; a method that takes
## fewer arguments than the signal sends is never called (Godot logs "Method
## expected 0 argument(s), but called with 1" and drops the call). The quick
## menu's Exit game and Settings' "Run setup again" did nothing because of
## that. Found by the end-to-end suite.

const Main := preload("res://scripts/main.gd")
const QuickMenu := preload("res://scripts/ui/quick_menu.gd")
const SettingsScreen := preload("res://scripts/ui/settings_screen.gd")


static func _method(script: Script, name: String) -> Dictionary:
	for m in script.get_script_method_list():
		if m["name"] == name:
			return m
	return {}


static func _signal_args(script: Script, name: String) -> int:
	for s in script.get_script_signal_list():
		if s["name"] == name:
			return s["args"].size()
	return -1


## [signal owner script, signal, main.gd method]
const WIRES := [
	[QuickMenu, "exit_game_requested", "exit_game"],
	[QuickMenu, "settings_requested", "_open_settings_category"],
	[QuickMenu, "closed", "_on_menu_closed"],
	[SettingsScreen, "setup_requested", "_on_setup_requested"],
	[SettingsScreen, "game_settings_requested", "_open_game_settings"],
]


func test_main_methods_take_what_the_signals_send() -> void:
	for w in WIRES:
		var m := _method(Main, w[2])
		ok(not m.is_empty(), "main.gd has %s" % w[2])
		var sent := _signal_args(w[0], w[1])
		var takes: int = m.get("args", []).size()
		var needs: int = takes - m.get("default_args", []).size()
		ok(sent >= needs and sent <= takes, "%s(%d args) can take %s's %d (needs %d..%d)" % [w[2], takes, w[1], sent, needs, takes])
