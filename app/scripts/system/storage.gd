extends "res://scripts/system/service.gd"
## Storage: drives that can hold games (internal, SD card, external), their
## free space and filesystem, and how much each game library uses.
##
## Read-only and unprivileged: `findmnt` and `lsblk` (util-linux) plus Steam's
## and Heroic's own files. Nothing runs at start. refresh() reads once; while
## the Storage page is open, watch(true) compares /proc/self/mounts every few
## seconds (one small file read on the main thread, no process) and refreshes
## when a card or drive comes or goes. watch(false) when the page closes.
##
## Clean up: shader caches Steam leaves behind for games that are no longer
## installed (leftovers() measures, clean_leftovers() removes them through
## launch_files.gd's guarded remover), the same folders the Storage Cleaner
## Decky plugin clears. Proton prefixes (compatdata) are never touched: they can
## hold saves that aren't in the cloud.
##
## Formatting an SD card is not offered yet (docs/SYSTEM.md, future work).

signal changed(state: Dictionary)

const Parse := preload("res://scripts/system/storage_parse.gd")
const SteamStore := preload("res://scripts/library/stores/steam.gd")
const Common := preload("res://scripts/library/stores/common.gd")
const LaunchFiles := preload("res://scripts/controls/perf/launch_files.gd")

const WATCH_S := 4.0
const FINDMNT_ARGS := ["--json", "--list", "-b", "-o", "SOURCE,TARGET,FSTYPE,SIZE,USED,AVAIL,OPTIONS"]
const LSBLK_ARGS := ["--json", "-b", "-o", "NAME,PATH,PKNAME,TYPE,SIZE,RM,HOTPLUG,TRAN,MODEL,LABEL,FSTYPE"]

var home := OS.get_environment("HOME")
var proc_mounts := "/proc/self/mounts"

var _state := {"drives": [], "libraries": [], "watching": false, "ready": false, "error": "",
	"cleanup": {"ready": false, "dirs": [], "bytes": 0, "cleaning": false}}
var _timer: Timer
var _signature := ""


func setup(command_runner: RefCounted, home_dir: String, mounts_file := "") -> void:
	runner = command_runner
	home = home_dir
	proc_mounts = mounts_file


func state() -> Dictionary:
	return _state.duplicate(true)


## Reads drives and libraries on the worker; `changed` follows.
func refresh() -> void:
	_queue("refresh", _refresh)


## Start (page open) or stop (page closed) hot-plug watching.
func watch(on: bool) -> void:
	_state["watching"] = on
	if not on:
		if _timer:
			_timer.stop()
		return
	_signature = Parse.mounts_signature(read_text(proc_mounts)) if proc_mounts != "" else ""
	refresh()
	if not is_inside_tree():
		return
	if _timer == null:
		_timer = Timer.new()
		_timer.wait_time = WATCH_S
		_timer.timeout.connect(poll_mounts)
		add_child(_timer)
	_timer.start()


## One watch tick: refresh only when the set of mounted block devices changed.
## Returns true when it queued a refresh.
func poll_mounts() -> bool:
	if proc_mounts == "":
		return false
	var sig := Parse.mounts_signature(read_text(proc_mounts))
	if sig == _signature:
		return false
	_signature = sig
	refresh()
	return true


func _refresh() -> void:
	var r: Dictionary = runner.run("findmnt", PackedStringArray(FINDMNT_ARGS))
	var mounts: Array = Parse.findmnt(str(r.get("out", ""))) if int(r.get("code", -1)) == 0 else []
	var err := ""
	if mounts.is_empty() or int(mounts[0].get("size", -1)) < 0:
		# Old util-linux without size columns: df has them.
		var d: Dictionary = runner.run("df", PackedStringArray(["-B1", "--output=source,fstype,size,used,avail,target"]))
		var from_df: Array = Parse.df(str(d.get("out", ""))) if int(d.get("code", -1)) == 0 else []
		if not from_df.is_empty():
			var opts := {}
			for m in mounts:
				opts[m["target"]] = m["options"]
			for m in from_df:
				m["options"] = opts.get(m["target"], "")
			mounts = from_df
		elif mounts.is_empty():
			err = "could not read mounts"
	var b: Dictionary = runner.run("lsblk", PackedStringArray(LSBLK_ARGS))
	var blk: Dictionary = Parse.lsblk(str(b.get("out", ""))) if int(b.get("code", -1)) == 0 else {}
	var drives := Parse.drives(mounts, blk)
	var libs := libraries(mounts)
	_main(func():
		_state["drives"] = drives
		_state["libraries"] = libs
		_state["ready"] = true
		_state["error"] = err
		changed.emit(state()))


## Game library folders with their mount and size: every Steam library (sizes
## from libraryfolders.vdf), Heroic's install folder and ~/Games.
## [{"store": steam|heroic|games, "path", "device", "mount", "free", "bytes"
##  (-1 = not measured), "games" (-1 = unknown), "compression"}]
func libraries(mounts: Array) -> Array:
	var out: Array = []
	var seen := {}
	for root in SteamStore.STEAM_ROOTS:
		var steam_root := SteamStore.expand(root, home)
		var vdf := steam_root + "/steamapps/libraryfolders.vdf"
		if not FileAccess.file_exists(vdf):
			continue
		for lib in Parse.steam_libraries(FileAccess.get_file_as_string(vdf)):
			var p: String = lib["path"]
			if seen.has(p):
				continue
			seen[p] = true
			out.append(_lib("steam", p, lib["bytes"], lib["games"], mounts))
	for h in Common.heroic_roots(home):
		var cfg: String = h["root"] + "/config.json"
		if FileAccess.file_exists(cfg):
			var p := Parse.heroic_install_path(FileAccess.get_file_as_string(cfg), home)
			if p != "" and not seen.has(p) and DirAccess.dir_exists_absolute(p):
				seen[p] = true
				out.append(_lib("heroic", p, -1, -1, mounts))
	var games := home + "/Games"
	if DirAccess.dir_exists_absolute(games) and not seen.has(games):
		out.append(_lib("games", games, -1, -1, mounts))
	return out


func _lib(store: String, path: String, bytes: int, games: int, mounts: Array) -> Dictionary:
	var m := Parse.mount_for(path, mounts)
	return {"store": store, "path": path, "device": m.get("device", ""), "mount": m.get("target", ""),
		"free": m.get("free", -1), "bytes": bytes, "games": games,
		"compression": Parse.compression(m.get("options", "")) if m.get("fstype", "") == "btrfs" else ""}


## Measures one folder with `du` (can take seconds on a big library; runs on
## the worker). Updates that library's "bytes" and emits `changed`.
func measure(path: String) -> void:
	_queue("measure:" + path, func():
		var r: Dictionary = runner.run("du", PackedStringArray(["-sb", path]))
		var bytes := -1
		# du exits 1 when some subfolder is unreadable but still prints the total.
		if int(r.get("code", -1)) in [0, 1]:
			var lines := str(r.get("out", "")).strip_edges().split("\n", false)
			var first := lines[lines.size() - 1].split("\t", false) if lines.size() > 0 else PackedStringArray()
			if first.size() > 0 and first[0].is_valid_int():
				bytes = int(first[0])
		_main(func():
			for lib in _state["libraries"]:
				if lib["path"] == path:
					lib["bytes"] = bytes
			changed.emit(state())))


# ---- clean up ------------------------------------------------------------------------

## Non-Steam shortcuts get app ids from 2^31 up: they never have a manifest, so
## their caches are never "left over".
const SHORTCUT_IDS := 2147483648


## Every Steam library folder (libraryfolders.vdf of each Steam install).
func steam_library_paths() -> Array:
	var out: Array = []
	for root in SteamStore.STEAM_ROOTS:
		var vdf := SteamStore.expand(root, home) + "/steamapps/libraryfolders.vdf"
		if not FileAccess.file_exists(vdf):
			continue
		for lib in Parse.steam_libraries(FileAccess.get_file_as_string(vdf)):
			if not lib["path"] in out:
				out.append(lib["path"])
	return out


## steamapps/shadercache/<appid> folders whose game has no appmanifest in any of
## `libs` (uninstalled, or moved away and back without its cache).
static func leftover_dirs(libs: Array) -> Array:
	var installed := {}
	for lib in libs:
		for f in DirAccess.get_files_at(str(lib).path_join("steamapps")):
			if f.begins_with("appmanifest_") and f.ends_with(".acf"):
				installed[f.trim_prefix("appmanifest_").trim_suffix(".acf")] = true
	var out: Array = []
	for lib in libs:
		var base := str(lib).path_join("steamapps/shadercache")
		for id in DirAccess.get_directories_at(base):
			if not id.is_valid_int() or int(id) <= 0 or int(id) >= SHORTCUT_IDS or installed.has(id):
				continue
			out.append(base.path_join(id))
	out.sort()
	return out


## Finds and measures the leftovers on the worker; `changed` follows.
func leftovers() -> void:
	_queue("leftovers", func():
		var dirs := leftover_dirs(steam_library_paths())
		var bytes := _du_total(dirs)
		_main(func():
			_state["cleanup"] = {"ready": true, "dirs": dirs, "bytes": bytes, "cleaning": false}
			changed.emit(state())))


## Removes the leftovers found by the last leftovers(), then measures again.
## Returns false when there's nothing to remove or a clean-up is running.
func clean_leftovers() -> bool:
	var dirs: Array = _state["cleanup"].get("dirs", [])
	if dirs.is_empty() or bool(_state["cleanup"].get("cleaning", false)):
		return false
	_state["cleanup"]["cleaning"] = true
	changed.emit(state())
	_queue("clean_leftovers", func():
		var freed := 0
		var failed := 0
		for d in dirs:
			var b := _du_total([d])
			if LaunchFiles.remove_shader_cache(str(d)):
				freed += maxi(b, 0)
			else:
				failed += 1
		var left := leftover_dirs(steam_library_paths())
		var bytes := _du_total(left)
		_main(func():
			_state["cleanup"] = {"ready": true, "dirs": left, "bytes": bytes, "cleaning": false, "freed": freed, "failed": failed}
			changed.emit(state())))
	return true


## Total size of folders in bytes (du -sbc), 0 for none.
func _du_total(dirs: Array) -> int:
	if dirs.is_empty():
		return 0
	var args := PackedStringArray(["-sbc"])
	for d in dirs:
		args.append(str(d))
	var r: Dictionary = runner.run("du", args)
	if not int(r.get("code", -1)) in [0, 1]:
		return 0
	var lines := str(r.get("out", "")).strip_edges().split("\n", false)
	var last := lines[lines.size() - 1].split("\t", false) if lines.size() > 0 else PackedStringArray()
	return int(last[0]) if last.size() > 0 and last[0].is_valid_int() else 0
