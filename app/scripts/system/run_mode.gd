extends RefCounted
## How this process was started, for the autoloads (they run before boot.gd decides).
##
## `--restore-baseline` (session-select runs it before a session switch, next to the
## live GameCove) only needs Device, Power, Controls, Launcher and Profiles. Everything
## else stays off: the store manager would restore the download queue and launch a
## saved install command beside the live one; GameDB, Discover and the photo
## prefetch would go online; PerfMonitor and the InputPlumber intercept would
## start watchers (review 2, problem 5).
##
## A second home screen on the same settings (started from the desktop while one runs) is
## treated the same way and boot.gd ends it at once: two would write the same settings
## files in turns and both restart the saved download queue. The installer, the Controls
## command line, the photo prefetch and --restore-baseline run next to the home screen by
## design and never ask for the lock; neither does `godot -s <script>` (tests, tools).

const SettingsFile := preload("res://scripts/system/settings_file.gd")

const RESTORE_BASELINE := "--restore-baseline"
## Starts that aren't the home screen.
const NOT_HOME := ["--installer", "--controls", "--prefetch-photo", RESTORE_BASELINE]
const LOCK := "user://gamecove.pid"

## Tests only: used instead of the command line when not null.
static var test_args: Variant = null
## Tests only: the lock file, /proc and this process's id.
static var lock_path := LOCK
static var proc_root := "/proc"
static var pid := 0

static var _second: Variant = null


static func args() -> PackedStringArray:
	return PackedStringArray(test_args) if test_args != null else OS.get_cmdline_user_args()


## True in a headless helper run that must start no services, and in a second home screen.
static func helper() -> bool:
	return RESTORE_BASELINE in args() or second_instance()


## True when this start is a home screen and another one already runs on these settings.
## Asked once; the answer (and the lock, when it's ours) holds for the process's life.
static func second_instance() -> bool:
	if _second == null:
		_second = _ask()
	return _second


static func _ask() -> bool:
	for a in NOT_HOME:
		if a in args():
			return false
	if test_args == null:
		var cmd := OS.get_cmdline_args()
		if "-s" in cmd or "--script" in cmd or Engine.is_editor_hint():
			return false
	return SettingsFile.claim_instance(lock_path, pid if pid > 0 else OS.get_process_id(), proc_root) != 0


## Tests: forget the answer; with `defaults`, also the test lock, /proc and pid.
static func reset_for_tests(defaults := true) -> void:
	_second = null
	if defaults:
		lock_path = LOCK
		proc_root = "/proc"
		pid = 0
