extends RefCounted
## How this process was started, for the autoloads (they run before boot.gd decides).
##
## `--restore-baseline` (session-select runs it before a session switch, next to the
## live GameCove) only needs Device, Power, Controls, Launcher and Profiles. Everything
## else stays off: the store manager would restore the download queue and launch a
## saved install command beside the live one; GameDB, Discover and the photo
## prefetch would go online; PerfMonitor and the InputPlumber intercept would
## start watchers (review 2, problem 5).

const RESTORE_BASELINE := "--restore-baseline"

## Tests only: used instead of the command line when not null.
static var test_args: Variant = null


static func args() -> PackedStringArray:
	return PackedStringArray(test_args) if test_args != null else OS.get_cmdline_user_args()


## True in a headless helper run that must start no services.
static func helper() -> bool:
	return RESTORE_BASELINE in args()
