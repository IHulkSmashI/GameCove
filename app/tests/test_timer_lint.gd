extends "res://tests/test_case.gd"
## Every Timer in the app says what it does behind a game (docs/PERFORMANCE.md). Behind a game
## GameCove must sleep: BackgroundMode wakes the main loop for every running Timer, so a
## Timer that keeps running there costs wake-ups for the whole game. A new Timer.new() or
## create_timer() fails this test until it's listed here with how it behaves behind a game;
## tests/e2e/suite_perf.gd checks at run time that only the allowed ones run there.

const KNOWN := {
	# behind a game, on purpose
	"scripts/device/power.gd": [2, "15 s resume/charger check (review M19) and the thermal guard: must run"],
	"scripts/system/session_health.gd": [1, "heartbeat tick every 5 s; writes only when the mode changes"],
	"scripts/launch/game_session.gd": [1, "focus wait, then the exit check only while xprop -spy isn't watching"],
	"scripts/perf/perf_monitor.gd": [1, "1 s samples only while Auto TDP (or a `sample` listener) uses them"],
	# stopped or paused behind a game
	"scripts/main.gd": [2, "live refresh stops when unfocused without the menu; resume re-apply is one-shot after a sleep"],
	"scripts/discover/discover.gd": [1, "paused while a game runs (SessionWiring)"],
	"scripts/library/meta/resolver.gd": [1, "background fill paused while a game runs (Library.set_background_paused)"],
	"scripts/library/art/art_service.gd": [1, "auto fill paused while a game runs (Library.set_background_paused)"],
	"scripts/streaming/streaming.gd": [4, "checks stop while a game or stream runs; pairing / wake polls only in a flow the user started"],
	"scripts/system/storage.gd": [1, "mount watch only while the Storage page is open"],
	"scripts/steam/steam_handoff.gd": [1, "looks for Steam's controller settings window, only during a trip there the user started; stopped when it ends"],
	"scripts/steam/steam_backend.gd": [2, "polls only while an install / setting it started is watched"],
	# one-shot, started by something the user did (or a rare event)
	"scripts/library/library.gd": [1, "one-shot batch of library change signals"],
	"scripts/input/controller.gd": [2, "one-shot restart backoff when the intercept monitor died; one-shot hold time only while a shortcut button is held down"],
	"scripts/controls/providers/perf.gd": [1, "one-shot daily upscaler update check (privacy-gated)"],
	"scripts/ui/toast.gd": [1, "one-shot: a toast's stay time"],
	"scripts/system/updates.gd": [1, "one-shot 3 min after start: the opt-in automatic app update (refused while a game runs)"],
	"scripts/ui/slider_row.gd": [1, "one-shot settle after a slider change"],
	"scripts/ui/osk.gd": [1, "key repeat only while a D-pad direction, backspace or a caret button is held on the open keyboard"],
	"scripts/ui/controls/color_row.gd": [1, "one-shot settle after a colour change"],
	"scripts/ui/controls/keep_dialog.gd": [1, "countdown only while the Keep this? dialog is open"],
	"scripts/system/low_battery.gd": [1, "one-shot 5 s re-read, only when a battery reading lands at the sleep line out of nowhere (a glitch must not start the countdown)"],
	"scripts/ui/low_battery_dialog.gd": [1, "30 s countdown only while the Sleep at low battery warning is open (started by Power's 15 s check)"],
	"scripts/ui/device/controller_panel.gd": [1, "only while a button is held"],
	"scripts/ui/library_screen.gd": [1, "one-shot 0.12 s pause after a key typed in the search of a list over 2,000 games; only while the user types"],
	"scripts/ui/launch_overlay.gd": [1, "launch timeout; the overlay finishes when the game takes focus"],
	"scripts/ui/settings_screen.gd": [1, "one-shot: clears a status line"],
	"scripts/ui/quick_menu.gd": [2, "one-shots after a session switch was asked for: the overall limit and the wait for the logout; nothing while a game just runs"],
	"scripts/ui/games/game_closer.gd": [1, "one-shot grace before a hard kill (Exit game)"],
	# command-line modes, never in the running app
	"scripts/hwtest/controls_cli.gd": [1, "CLI timeout"],
	"scripts/installer/boot.gd": [1, "CLI prefetch timeout"],
	"scripts/controls/profiles.gd": [1, "CLI restore timeout"],
}


static func _scan(dir: String, out: Dictionary) -> void:
	for f in DirAccess.get_files_at(dir):
		if not f.ends_with(".gd"):
			continue
		var p := dir.path_join(f)
		var text := FileAccess.get_file_as_string(p)
		var n := text.count("Timer.new()") + text.count("create_timer(")
		if n > 0:
			out[p.trim_prefix("res://")] = n
	for d in DirAccess.get_directories_at(dir):
		_scan(dir.path_join(d), out)


func test_every_timer_says_what_it_does_behind_a_game() -> void:
	var found := {}
	_scan("res://scripts", found)
	for p in found:
		if not KNOWN.has(p):
			failures.append("%s: %s makes a Timer: list it in tests/test_timer_lint.gd KNOWN with how it stops (or why it must run) behind a game" % [_current, p])
		elif found[p] > int(KNOWN[p][0]):
			failures.append("%s: %s makes %d Timers, %d listed: add what the new one does behind a game" % [_current, p, found[p], KNOWN[p][0]])
	for p in KNOWN:
		ok(found.has(p), "%s listed but makes no Timer any more: remove it from KNOWN" % p)


func test_the_main_loop_is_paced_behind_a_game() -> void:
	ok(bool(ProjectSettings.get_setting("application/run/low_processor_mode", false)), "low-processor mode on (nothing redraws unless it changed)")
	var main := FileAccess.get_file_as_string("res://scripts/main.gd")
	ok(main.contains("background.set_front(false)") and main.contains("background.set_front(true)"), "main.gd tells BackgroundMode who is in front")
	ok(main.contains("background.set_menu(quick_menu.visible)"), "and whether the quick menu shows")
