extends RefCounted
## Brings one of Steam's own windows (an install or uninstall dialog, the
## Downloads page) in front of GameCove under gamescope, then hands focus back.
##
## Gamescope publishes every focusable window as [window, app id, pid] triples
## in GAMESCOPE_FOCUSABLE_WINDOWS and lets a client force one window to the
## front with GAMESCOPECTRL_BASELAYER_WINDOW (gamescope src/steamcompmgr.cpp,
## focusControlWindow, commit 89b9e6e). Removing the property gives focus back
## to the base-layer app list, which the Gamescope service keeps on our home.
## We can't tell Steam's windows by app id (Steam's UI and our home can both be
## 769), so we pick by process: windows owned by `steam` or `steamwebhelper`.

const ATOM_FOCUSABLE_WINDOWS := "GAMESCOPE_FOCUSABLE_WINDOWS"
const ATOM_BASELAYER_WINDOW := "GAMESCOPECTRL_BASELAYER_WINDOW"
const STEAM_PROCESSES := ["steam", "steamwebhelper"]


## Steam window to show: the newest (last listed) window whose process is one of
## Steam's and isn't ours. `comm_of` maps pid -> process name. 0 if none.
static func pick_window(triples: Array, own_pid: int, comm_of: Dictionary) -> int:
	var best := 0
	var i := 0
	while i + 2 < triples.size():
		var wid := int(triples[i])
		var pid := int(triples[i + 2])
		if pid != own_pid and str(comm_of.get(pid, "")).strip_edges() in STEAM_PROCESSES:
			best = wid
		i += 3
	return best


## Process names for the pids in a triple list, read from /proc/<pid>/comm.
static func comms(triples: Array, proc_root := "/proc") -> Dictionary:
	var out := {}
	var i := 2
	while i < triples.size():
		var pid := int(triples[i])
		var p := proc_root.path_join(str(pid)).path_join("comm")
		if not out.has(pid) and FileAccess.file_exists(p):
			out[pid] = FileAccess.get_file_as_string(p).strip_edges()
		i += 3
	return out


## xprop arguments: read the focusable windows, force one window, release it.
static func read_args() -> PackedStringArray:
	return PackedStringArray(["-root", "-notype", ATOM_FOCUSABLE_WINDOWS])


static func focus_args(wid: int) -> PackedStringArray:
	return PackedStringArray(["-root", "-f", ATOM_BASELAYER_WINDOW, "32c", "-set", ATOM_BASELAYER_WINDOW, str(wid)])


static func release_args() -> PackedStringArray:
	return PackedStringArray(["-root", "-remove", ATOM_BASELAYER_WINDOW])
