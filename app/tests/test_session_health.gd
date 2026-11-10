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
