extends "res://tests/test_case.gd"
## The heartbeat the session client watches for hangs (review H1) and the notice after the
## client fell back to Steam (review L31). Files in a temp folder only.

const SessionHealth := preload("res://scripts/system/session_health.gd")


func _dir() -> String:
	var d := OS.get_temp_dir().path_join("gc_health_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(d)
	return d


func test_beat_writes_a_changing_line_with_the_mode() -> void:
	var d := _dir()
	var h: Node = SessionHealth.new(d.path_join("gamecove-heartbeat"))
	ok(h.beat(), "beat written")
	eq(FileAccess.get_file_as_string(d.path_join("gamecove-heartbeat")), "1 ui\n", "sequence and mode")
	var playing := [true]
	h.game_running = func() -> bool: return playing[0]
	h.beat()
	eq(FileAccess.get_file_as_string(d.path_join("gamecove-heartbeat")), "2 game\n", "says game while one runs: the client never kills it then")
	ok(not FileAccess.file_exists(d.path_join("gamecove-heartbeat.tmp")), "replaced in one rename")
	h.free()


func test_no_heartbeat_outside_the_session() -> void:
	var h: Node = SessionHealth.new("")
	h.path = ""
	ok(not h.beat(), "nothing written without GAMECOVE_HEARTBEAT")
	h.free()


func test_fallback_notice_is_shown_once() -> void:
	var d := _dir()
	eq(SessionHealth.take_fallback_notice(d), "", "nothing to say")
	var f := FileAccess.open(d.path_join("crash-fallback"), FileAccess.WRITE)
	f.store_string("1700000000\ncrashes\n")
	f.close()
	var n := SessionHealth.take_fallback_notice(d)
	ok(n.contains("3 times") and n.contains("Steam started instead"), "says why Steam started: " + n)
	eq(SessionHealth.take_fallback_notice(d), "", "only once")
	ok(SessionHealth.notice_text("hung").contains("stopped responding"), "a hang")
	ok(SessionHealth.notice_text("missing").contains("Repair"), "missing files: points at Repair")
	ok(SessionHealth.notice_text("unsaved").contains("full"), "unsaved count")


class FakeSession extends RefCounted:
	signal started(game: Dictionary)
	signal ended(game: Dictionary)
	var active := false


## Review 2, low 13: the mode was sampled only every 5 s, so a stall right after a
## launch could read as a hung UI. A game start or end beats at once.
func test_game_start_and_end_beat_at_once() -> void:
	var d := _dir()
	var p := d.path_join("gamecove-heartbeat")
	var h: Node = SessionHealth.new(p)
	var s := FakeSession.new()
	h.game_running = func() -> bool: return s.active
	h.watch_session(s)
	s.active = true
	s.started.emit({})
	eq(FileAccess.get_file_as_string(p), "1 game\n", "beat with the game mode on start")
	s.active = false
	s.ended.emit({})
	eq(FileAccess.get_file_as_string(p), "2 ui\n", "and back to ui on end")
	h.free()


func test_nothing_is_written_while_a_game_runs() -> void:
	var d := _dir()
	var p := d.path_join("gamecove-heartbeat")
	var h: Node = SessionHealth.new(p)
	var playing := [false]
	h.game_running = func() -> bool: return playing[0]
	ok(h.tick(), "ui: every tick beats")
	ok(h.tick(), "ui: and the next")
	eq(FileAccess.get_file_as_string(p), "2 ui\n", "two beats")
	playing[0] = true
	ok(h.tick(), "the game start is written on the next tick")
	eq(FileAccess.get_file_as_string(p), "3 game\n", "says game")
	ok(not h.tick() and not h.tick(), "no writes while the file says game: the client never counts it stale")
	eq(FileAccess.get_file_as_string(p), "3 game\n", "unchanged")
	playing[0] = false
	ok(h.tick(), "the game end is written on the next tick")
	eq(FileAccess.get_file_as_string(p), "4 ui\n", "back to ui, beating again")
	h.free()


func test_the_client_never_needs_beats_in_game() -> void:
	# session/gamecove-session-client: stale only counts while the file says "ui"
	var client := FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://").path_join("../session/gamecove-session-client"))
	ok(client.contains("[ \"${now#* }\" = game ]"), "a \"game\" heartbeat resets the stale count")
