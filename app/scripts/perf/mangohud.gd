extends RefCounted
## mangoapp (MangoHud inside gamescope): the performance overlay levels and
## the game's frame timings.
##
## How the session does it (gamescope-session-plus `gamescope-session-plus`,
## OpenGamingCollective, MIT): the session exports MANGOHUD_CONFIGFILE
## (`mktemp /tmp/mangohud.XXXXXXXX`), writes "no_display" to it and runs
## `mangoapp` in a loop. Steam's performance-overlay slider and
## OpenGamepadUI's (core/systems/mangoapp/mangoapp.gd, GPL-3.0) just rewrite
## that file; mangoapp reloads it on inotify IN_MODIFY, and gamescope (when it
## launches mangoapp itself with --mangoapp) watches it for IN_CLOSE_WRITE to
## know whether the overlay is visible (src/mangoapp_config.h). No X atom is
## involved: mangoapp tags its own window GAMESCOPE_EXTERNAL_OVERLAY.
##
## Frame timings: gamescope sends every game frame's timing to mangoapp over a
## SysV message queue (ftok("mangoapp", 65), src/mangoapp.cpp). That queue has
## one reader, so we never read it ourselves. Instead we ask mangoapp to log:
## the config gets output_folder=<our tmpfs folder> and log_interval=1000, and
## `mangohudctl set log_session 1` (one process per game, not per sample)
## starts a log that mangoapp appends one CSV row a second to (fps, frametime,
## cpu_load, cpu_power, gpu_load, cpu_temp, gpu_temp, gpu_core_clock, ...).
## A hidden mangoapp still logs (MangoHud src/app/main.cpp only skips frames
## when hidden AND not logging). Every config reload makes a new logger and
## stops the old one (overlay_params.cpp), so after a rewrite the log is
## started again ("kick", at most every KICK_S). Without mangohudctl,
## autostart_log=1 starts a log only while the overlay is visible.
## gamescope's own stats pipe (-T, GAMESCOPE_STATS) only prints fps once per
## 300 composited frames and may already have a reader, so it isn't used.
##
## Thread-safe: the UI thread sets levels, PerfMonitor's sample task reads
## the log; a mutex guards both.

const ENV_CONFIG := "MANGOHUD_CONFIGFILE"
const HEADER := "# written by GameCove (performance overlay)"
const KICK_S := 3.0
const MAX_KICKS := 5
const NO_ROWS_S := 2.5
const FIRST_KICK_S := 1.0

## Overlay levels: 0 off, 1 frame rate only, 2 compact row, 3 full.
## Lines are MangoHud options (README "List of parameters"; the same choices
## as MangoHud's built-in presets 1-3 and OpenGamepadUI's slider).
const LEVELS := [
	["no_display"],
	["legacy_layout=0", "cpu_stats=0", "gpu_stats=0", "fps", "fps_only", "frametime=0"],
	["horizontal", "legacy_layout=0", "table_columns=20", "hud_no_margin", "fps", "frametime=0",
		"frame_timing=1", "cpu_stats", "gpu_stats", "cpu_power", "gpu_power", "ram", "battery", "battery_watt"],
	["legacy_layout=0", "fps", "frametime", "frame_timing=1", "cpu_stats", "cpu_temp", "cpu_power",
		"cpu_mhz", "gpu_stats", "gpu_temp", "gpu_power", "gpu_core_clock", "gpu_mem_clock", "ram",
		"vram", "battery", "battery_watt", "battery_time", "throttling_status"],
]
const LEVEL_NAMES := ["off", "fps", "compact", "full"]

var config_path := ""
var log_dir := ""
## Full path of mangohudctl, "" when not installed.
var ctl := ""
## Anything with run(program, args) -> {"code"|"exit": int, ...}.
var runner: RefCounted

var level := 0
var logging := false
## What PerfMonitor wants (set on the main thread); sync() makes it so. Jobs
## may run out of order on the thread pool, so each applies the newest want.
var want_logging := false

var _mutex := Mutex.new()
var _written := ""
var _log_file := ""
var _offset := 0
var _header: Dictionary = {}
var _partial := ""
var _last_row_s := -1.0
var _last_kick_s := -1000.0
var _kicks := 0
var _started_s := 0.0


## True when there is a mangoapp to drive: the session gave us its config file.
func supported() -> bool:
	return config_path != ""


## The config file text for an overlay level, with or without our log lines.
static func config_text(lvl: int, with_log: bool, folder: String, autostart := true) -> String:
	var lines: Array = [HEADER]
	lines.append_array(LEVELS[clampi(lvl, 0, LEVELS.size() - 1)])
	if with_log and folder != "":
		lines.append("output_folder=" + folder)
		lines.append("log_interval=1000")
		if autostart:
			lines.append("autostart_log=1")
	return "\n".join(PackedStringArray(lines)) + "\n"


## Writes the config file in place (truncate + write: IN_MODIFY for
## mangoapp, IN_CLOSE_WRITE for gamescope), only when its text changes.
func _write_config() -> bool:
	if config_path == "":
		return false
	var text := config_text(level, logging, log_dir, ctl == "")
	if text == _written and FileAccess.file_exists(config_path):
		return true
	var f := FileAccess.open(config_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	_written = text
	return true


## Overlay level 0-3. Returns false when there's no mangoapp config to write.
func set_level(lvl: int) -> bool:
	_mutex.lock()
	level = clampi(lvl, 0, LEVELS.size() - 1)
	var ok := _write_config()
	if ok and logging:
		_kicks = 0
		_last_kick_s = -1000.0  # the reload stopped the log: start it again soon
	_mutex.unlock()
	return ok


## Starts or stops logging to match want_logging. Call off the main thread.
func sync(now_s: float) -> void:
	if want_logging and not logging:
		start_logging(now_s)
	elif not want_logging and logging:
		stop_logging()


## Starts frame logging for a game: writes the log lines into the config. The
## first read_rows() a second later asks mangoapp to start the log.
func start_logging(now_s: float) -> bool:
	_mutex.lock()
	if config_path == "" or log_dir == "":
		_mutex.unlock()
		return false
	DirAccess.make_dir_recursive_absolute(log_dir)
	_clear_logs()
	logging = true
	_started_s = now_s
	_kicks = 0
	_last_row_s = -1.0
	_last_kick_s = -1000.0
	var ok := _write_config()
	_mutex.unlock()
	return ok


## Stops logging: one config rewrite (which ends mangoapp's log) and the logs
## are deleted.
func stop_logging() -> void:
	_mutex.lock()
	if logging:
		logging = false
		_write_config()  # the reload ends mangoapp's log
		_clear_logs()
	_mutex.unlock()


## New log rows since the last call, each {column: float}. While logging and
## no row has come for a while, asks mangoapp to log again (one mangohudctl
## run, at most every KICK_S, MAX_KICKS times per start or config change).
func read_rows(now_s: float) -> Array:
	_mutex.lock()
	var rows := []
	if logging:
		rows = _read_new()
		if not rows.is_empty():
			_last_row_s = now_s
			_kicks = 0
		elif ctl != "" and runner != null and _kicks < MAX_KICKS and _kick_due(now_s):
			_last_kick_s = now_s
			_kicks += 1
			runner.run(ctl, PackedStringArray(["set", "log_session", "1"]))
	_mutex.unlock()
	return rows


## The first kick waits FIRST_KICK_S after start (mangoapp must reload the
## config first, or the reload ends the log at once); later ones wait for
## NO_ROWS_S without rows.
func _kick_due(now_s: float) -> bool:
	if now_s - _last_kick_s < KICK_S:
		return false
	if _last_row_s < 0.0:
		return now_s - _started_s >= (FIRST_KICK_S if _kicks == 0 else NO_ROWS_S)
	return now_s - _last_row_s >= NO_ROWS_S


## Seconds since the last row, -1 if none yet (for "fps unavailable" UI).
func row_age(now_s: float) -> float:
	return now_s - _last_row_s if _last_row_s >= 0.0 else -1.0


func _read_new() -> Array:
	if _log_file == "" or not FileAccess.file_exists(_log_file):
		_log_file = _newest_log()
		_offset = 0
		_header = {}
		_partial = ""
		if _log_file == "":
			return []
	var f := FileAccess.open(_log_file, FileAccess.READ)
	if f == null:
		return []
	var length := f.get_length()
	if length < _offset:  # replaced
		_offset = 0
		_header = {}
		_partial = ""
	if length == _offset:
		f.close()
		# a new log (after a reload) goes to a new file: switch when one appears
		var newest := _newest_log()
		if newest != "" and newest != _log_file:
			_log_file = newest
			_offset = 0
			_header = {}
			_partial = ""
		return []
	f.seek(_offset)
	var chunk := f.get_buffer(length - _offset).get_string_from_utf8()
	_offset = length
	f.close()
	return parse_chunk(chunk)


## Feeds log text (any split) and returns finished data rows. Keeps the
## header and an unfinished last line between calls.
func parse_chunk(chunk: String) -> Array:
	const Math := preload("res://scripts/perf/perf_math.gd")
	var text := _partial + chunk
	var lines := text.split("\n")
	_partial = lines[lines.size() - 1]
	var rows := []
	for i in lines.size() - 1:
		var line: String = lines[i].strip_edges()
		if line.begins_with("fps,"):
			_header = Math.csv_header(line)
			continue
		if _header.is_empty():
			continue  # system info lines before the frame header
		var r := Math.csv_row(line, _header)
		if not r.is_empty():
			rows.append(r)
	return rows


func _newest_log() -> String:
	var d := DirAccess.open(log_dir)
	if d == null:
		return ""
	var best := ""
	var best_t := -1
	for f in d.get_files():
		if not f.ends_with(".csv") or f.ends_with("_summary.csv"):
			continue
		var t := FileAccess.get_modified_time(log_dir + "/" + f)
		if t > best_t or (t == best_t and f > best.get_file()):
			best_t = t
			best = log_dir + "/" + f
	return best


func _clear_logs() -> void:
	_log_file = ""
	_offset = 0
	_header = {}
	_partial = ""
	var d := DirAccess.open(log_dir)
	if d == null:
		return
	for f in d.get_files():
		if f.ends_with(".csv"):
			DirAccess.remove_absolute(log_dir + "/" + f)
