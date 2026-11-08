extends RefCounted
## Steam app manifests (steamapps/appmanifest_<appid>.acf): install state and
## download progress straight from Steam's files, no Steam API needed. Steam
## rewrites the manifest when the state changes and every few seconds while it
## downloads, so polling it (only while a download is active) gives progress.
##
## StateFlags is Steam's EAppState bit field (SteamKit2 SteamLanguage
## EAppState; the same values the SteamClient JS API reports).

const VDF := preload("res://scripts/launch/vdf.gd")

const UNINSTALLED := 1
const UPDATE_REQUIRED := 2
const FULLY_INSTALLED := 4
const FILES_MISSING := 32
const APP_RUNNING := 64
const FILES_CORRUPT := 128
const UPDATE_RUNNING := 256
const UPDATE_PAUSED := 512
const UPDATE_STARTED := 1024
const UNINSTALLING := 2048
const BACKUP_RUNNING := 4096
const RECONFIGURING := 65536
const VALIDATING := 131072
const ADDING_FILES := 262144
const PREALLOCATING := 524288
const DOWNLOADING := 1048576
const STAGING := 2097152
const COMMITTING := 4194304
const UPDATE_STOPPING := 8388608

## Any of these means Steam is working on the app right now.
const BUSY := UPDATE_RUNNING | UPDATE_STARTED | VALIDATING | ADDING_FILES | PREALLOCATING \
	| DOWNLOADING | STAGING | COMMITTING | UNINSTALLING | RECONFIGURING


static func manifest_path(library_folder: String, appid: String) -> String:
	return library_folder.path_join("steamapps/appmanifest_%s.acf" % appid)


## {"appid", "name", "flags", "installdir", "bytes_downloaded", "bytes_to_download",
##  "bytes_staged", "bytes_to_stage", "size_on_disk", "build_id", "target_build_id"}
## from manifest text. {} when it isn't an app manifest.
static func parse(text: String) -> Dictionary:
	var root := VDF.parse(text)
	var st: Variant = VDF.get_ci(root, "AppState")
	if not (st is Dictionary):
		return {}
	var s: Dictionary = st
	var flags_raw := str(VDF.get_ci(s, "StateFlags", ""))
	return {
		"appid": str(VDF.get_ci(s, "appid", "")),
		"name": str(VDF.get_ci(s, "name", "")),
		# No StateFlags at all (very old or hand-made manifests): treat as installed.
		"flags": flags_raw.to_int() if flags_raw.is_valid_int() else FULLY_INSTALLED,
		"installdir": str(VDF.get_ci(s, "installdir", "")),
		"bytes_downloaded": _int(s, "BytesDownloaded"),
		"bytes_to_download": _int(s, "BytesToDownload"),
		"bytes_staged": _int(s, "BytesStaged"),
		"bytes_to_stage": _int(s, "BytesToStage"),
		"size_on_disk": _int(s, "SizeOnDisk"),
		"build_id": _int(s, "buildid"),
		"target_build_id": _int(s, "TargetBuildID"),
	}


static func parse_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	return parse(FileAccess.get_file_as_string(path))


static func _int(d: Dictionary, key: String) -> int:
	var v := str(VDF.get_ci(d, key, "0"))
	return v.to_int() if v.is_valid_int() else 0


static func is_installed(flags: int) -> bool:
	return flags & FULLY_INSTALLED != 0


static func is_busy(flags: int) -> bool:
	return flags & BUSY != 0


## One word for the app's state, for the UI and the download queue:
## installed | update_required | downloading | verifying | uninstalling | paused | not_installed
static func state_name(flags: int) -> String:
	if flags & UNINSTALLING:
		return "uninstalling"
	if flags & VALIDATING:
		return "verifying"
	if flags & UPDATE_PAUSED and not (flags & UPDATE_RUNNING):
		return "paused"
	if flags & BUSY:
		return "downloading"
	if flags & UPDATE_REQUIRED:
		return "update_required"
	if flags & FULLY_INSTALLED:
		return "installed"
	return "not_installed"


## {"bytes_done", "bytes_total"} for the phase Steam is in (download, then staging).
static func progress(m: Dictionary) -> Dictionary:
	var total: int = m.get("bytes_to_download", 0)
	var done: int = m.get("bytes_downloaded", 0)
	if total > 0 and done >= total and int(m.get("bytes_to_stage", 0)) > 0:
		return {"bytes_done": int(m.get("bytes_staged", 0)), "bytes_total": int(m["bytes_to_stage"])}
	return {"bytes_done": done, "bytes_total": total}
