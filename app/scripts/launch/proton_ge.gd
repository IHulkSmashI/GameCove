extends RefCounted
## GE-Proton: install the newest release, see which ones are installed and
## remove old ones, the way ProtonUp-Qt and the Wine Cellar Decky plugin do it,
## with no extra app: the latest release from GitHub's API, the tarball and its
## .sha512sum from the same release, the checksum checked before anything is
## unpacked, then `tar` into Steam's compatibilitytools.d (the folder Steam
## reads custom Protons from; Steam's own files are never touched). Steam
## lists a new one after it restarts; GameCove's own launches see it at once.
##
## Only when the user presses Check or Install: no background lookup. Every
## step blocks (curl, sha512sum, tar): call from a worker thread only.
##
## Nothing half-done ever sits where Steam looks: the tarball is unpacked inside
## .gamecove-download/ and renamed into compatibilitytools.d/<tag> (same drive,
## one atomic step) only once its compatibilitytool.vdf is there. A removal is
## renamed out of the way first, then deleted. Whatever an interruption leaves
## (power loss, app killed) stays inside .gamecove-download/ and goes at the next
## start or install (cleanup()). A GE-Proton folder without its
## compatibilitytool.vdf (left by an older GameCove or by hand) is listed by
## broken() so the card can offer to remove it. curl gives up on a stalled
## download (under 1 KB/s for 30 s) and only speaks HTTPS.

const Proton := preload("res://scripts/launch/proton.gd")
const VDF := preload("res://scripts/launch/vdf.gd")
const ExecSafe := preload("res://scripts/system/exec_safe.gd")

const API := "https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest"
## Downloads are only taken from this release page.
const DOWNLOAD_PREFIX := "https://github.com/GloriousEggroll/proton-ge-custom/releases/download/"
const TAG_RE := "^GE-Proton[0-9]+-[0-9]+$"
## Where a download waits for its checksum (inside compatibilitytools.d, so the
## unpack is on the same drive).
const DOWNLOAD_DIR := ".gamecove-download"
## curl: HTTPS only (redirects too), and give up when the transfer stalls.
const CURL_SAFE: Array[String] = ["--proto", "=https", "--proto-redir", "=https",
	"--speed-limit", "1024", "--speed-time", "30"]


## The release from GitHub's "latest release" JSON:
## {"tag", "tarball", "sha512", "bytes", "published"}; {} when it isn't a GE-Proton
## release with both files on GloriousEggroll's release page.
static func parse_release(json: String) -> Dictionary:
	var j := JSON.new()
	if j.parse(json) != OK or not j.data is Dictionary:
		return {}
	var d: Dictionary = j.data
	var tag := str(d.get("tag_name", ""))
	if RegEx.create_from_string(TAG_RE).search(tag) == null:
		return {}
	var out := {"tag": tag, "tarball": "", "sha512": "", "bytes": -1, "published": str(d.get("published_at", "")).left(10)}
	for a in d.get("assets", []) if d.get("assets") is Array else []:
		if not a is Dictionary:
			continue
		var url := str(a.get("browser_download_url", ""))
		if not url.begins_with(DOWNLOAD_PREFIX + tag + "/"):
			continue
		var n := str(a.get("name", ""))
		if n == tag + ".tar.gz":
			out["tarball"] = url
			out["bytes"] = int(a.get("size", -1))
		elif n == tag + ".sha512sum":
			out["sha512"] = url
	return out if out["tarball"] != "" and out["sha512"] != "" else {}


## The newest release, or {"error": "..."} when GitHub didn't answer.
static func latest(runner: RefCounted) -> Dictionary:
	var r: Dictionary = runner.run("curl", PackedStringArray(["-fsSL", "--max-time", "20"] + CURL_SAFE + [
		"-H", "Accept: application/vnd.github+json", "-H", "User-Agent: GameCove", API]))
	if int(r.get("code", -1)) != 0:
		return {"error": "offline"}
	var rel := parse_release(str(r.get("out", "")))
	return rel if not rel.is_empty() else {"error": "bad_release"}


## The user's compatibilitytools.d (created on install), "" without Steam.
static func compat_dir(home: String) -> String:
	var root := Proton.steam_root(home)
	return root.path_join("compatibilitytools.d") if root != "" else ""


## GE-Proton builds in `dir`, newest first: [{"name", "dir", "major", "minor"}].
static func installed(dir: String) -> Array:
	var out: Array = []
	if dir == "":
		return out
	var tools := Proton.tools([dir])
	for internal in tools:
		var path := str(tools[internal]["dir"])
		var c := Proton.classify(path.get_file())
		if c["flavour"] != "ge":
			c = Proton.classify(str(internal))
		if c["flavour"] != "ge" or path.get_file().begins_with(".") or not complete(path):
			continue   # a folder without its compatibilitytool.vdf is broken(), not installed
		out.append({"name": path.get_file(), "internal": str(internal), "dir": path, "major": c["major"], "minor": c["minor"]})
	out.sort_custom(func(a, b): return a["major"] > b["major"] or (a["major"] == b["major"] and a["minor"] > b["minor"]))
	return out


## Steam app ids whose Proton is set to `internal` in config/config.vdf.
static func games_using(steam_root: String, internal: String) -> Array:
	var out: Array = []
	if steam_root == "" or internal == "":
		return out
	var cfg := VDF.parse_file(steam_root.path_join("config/config.vdf"))
	var mapping := VDF.find_ci(cfg, "CompatToolMapping")
	for appid in mapping:
		var e: Variant = mapping[appid]
		if e is Dictionary and str(VDF.get_ci(e, "name", "")) == internal:
			out.append(str(appid))
	return out


## The hex digest from a .sha512sum file ("<128 hex>  GE-ProtonX-Y.tar.gz"), "" if malformed.
static func parse_sha(text: String) -> String:
	var h := text.strip_edges().get_slice(" ", 0).to_lower()
	return h if RegEx.create_from_string("^[0-9a-f]{128}$").search(h) != null else ""


## A folder in `dir` that looks like a GE-Proton build ("GE-Proton10-26") but has
## no readable compatibilitytool.vdf: Steam can't use it. Names, newest first.
static func broken(dir: String) -> Array:
	var out: Array = []
	if dir == "":
		return out
	var d := DirAccess.open(dir)
	if d == null:
		return out
	var tag_re := RegEx.create_from_string(TAG_RE)
	for sub in d.get_directories():
		if tag_re.search(sub) != null and not d.is_link(sub) and not complete(dir.path_join(sub)):
			out.append(sub)
	out.sort_custom(func(a, b):
		var ca := Proton.classify(a)
		var cb := Proton.classify(b)
		return ca["major"] > cb["major"] or (ca["major"] == cb["major"] and ca["minor"] > cb["minor"]))
	return out


## The build in `path` is whole enough for Steam (its compatibilitytool.vdf reads).
static func complete(path: String) -> bool:
	var f := path.path_join("compatibilitytool.vdf")
	return FileAccess.file_exists(f) and _read(f).contains("compat_tools")


## What an interrupted install or removal left in `dir` (the download folder).
static func has_leftovers(dir: String) -> bool:
	return dir != "" and DirAccess.dir_exists_absolute(dir.path_join(DOWNLOAD_DIR))


## Deletes those leftovers. `group`: stop when that exec_safe stop group stops
## (app exit); what's left goes next time.
static func cleanup(dir: String, group := "") -> bool:
	return remove_tree(dir.path_join(DOWNLOAD_DIR), group) if dir != "" else true


## Downloads, checks and unpacks `rel` into `dir`. {"ok": bool, "error": ""|reason}
## reasons: "exists", "download", "checksum", "unpack", "no_steam".
static func install(runner: RefCounted, rel: Dictionary, dir: String, group := "") -> Dictionary:
	if dir == "" or rel.is_empty():
		return {"ok": false, "error": "no_steam"}
	var tag := str(rel.get("tag", ""))
	if RegEx.create_from_string(TAG_RE).search(tag) == null:
		return {"ok": false, "error": "download"}
	var target := dir.path_join(tag)
	if DirAccess.dir_exists_absolute(target):
		if complete(target):
			return {"ok": false, "error": "exists"}
		# an unfinished copy of this very version (an older GameCove unpacked in place)
		if not _discard(dir, tag, group):
			return {"ok": false, "error": "unpack"}
	var part := dir.path_join(DOWNLOAD_DIR)
	remove_tree(part, group)
	DirAccess.make_dir_recursive_absolute(part.path_join("unpack"))
	var tarball := part.path_join(tag + ".tar.gz")
	var shafile := part.path_join(tag + ".sha512sum")
	var res := _fetch_check_unpack(runner, rel, part.path_join("unpack"), tarball, shafile)
	if res["ok"]:
		var unpacked := part.path_join("unpack").path_join(tag)
		if not complete(unpacked):
			res = {"ok": false, "error": "unpack"}
		elif DirAccess.rename_absolute(unpacked, target) != OK:
			res = {"ok": false, "error": "unpack"}
	remove_tree(part, group)
	return res


static func _fetch_check_unpack(runner: RefCounted, rel: Dictionary, into: String, tarball: String, shafile: String) -> Dictionary:
	for job in [[str(rel["sha512"]), shafile], [str(rel["tarball"]), tarball]]:
		var url: String = job[0]
		if not url.begins_with(DOWNLOAD_PREFIX):
			return {"ok": false, "error": "download"}
		var r: Dictionary = runner.run("curl", PackedStringArray(["-fsSL", "--retry", "2", "--connect-timeout", "20"] + CURL_SAFE + [
			"-H", "User-Agent: GameCove", "-o", job[1], url]))
		if int(r.get("code", -1)) != 0:
			return {"ok": false, "error": "download"}
	var want := parse_sha(_read(shafile))
	var s: Dictionary = runner.run("sha512sum", PackedStringArray([tarball]))
	var got := parse_sha(str(s.get("out", ""))) if int(s.get("code", -1)) == 0 else ""
	if want == "" or got != want:
		return {"ok": false, "error": "checksum"}
	var t: Dictionary = runner.run("tar", PackedStringArray(["-xzf", tarball, "-C", into, "--no-same-owner"]))
	if int(t.get("code", -1)) != 0:
		return {"ok": false, "error": "unpack"}
	return {"ok": true, "error": ""}


static func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text() if f != null else ""


## Removes one GE-Proton folder from `dir` (a broken one too). Refused ("in_use")
## while a Steam game is set to it, and for anything that isn't a GE-Proton folder
## right inside `dir`. It's renamed out of Steam's sight first, then deleted.
static func remove(dir: String, name: String, steam_root: String, group := "") -> String:
	var target := dir.path_join(name)
	if dir == "" or name.contains("/") or name.begins_with(".") or Proton.classify(name)["flavour"] != "ge" \
			or not DirAccess.dir_exists_absolute(target):
		return "not_found"
	for t in installed(dir):
		if t["name"] == name and not games_using(steam_root, str(t["internal"])).is_empty():
			return "in_use"
	return "" if _discard(dir, name, group) else "failed"


## Moves dir/<name> into the download folder (one atomic rename), then deletes it.
## An interrupted delete leaves nothing where Steam looks; cleanup() finishes it.
static func _discard(dir: String, name: String, group := "") -> bool:
	var trash := dir.path_join(DOWNLOAD_DIR).path_join("removing")
	DirAccess.make_dir_recursive_absolute(trash)
	var moved := trash.path_join(name)
	remove_tree(moved, group)
	if DirAccess.rename_absolute(dir.path_join(name), moved) != OK:
		return false
	remove_tree(moved, group)
	return true


## Deletes a folder tree; a symlink inside is removed as a link, never followed.
## `group`: give up (false) once that exec_safe stop group is stopped (app exit).
static func remove_tree(path: String, group := "") -> bool:
	var d := DirAccess.open(path)
	if d == null:
		return not DirAccess.dir_exists_absolute(path)
	d.include_hidden = true
	for f in d.get_files():
		if group != "" and ExecSafe.stopped(group):
			return false
		DirAccess.remove_absolute(path.path_join(f))
	for sub in d.get_directories():
		if d.is_link(sub):
			DirAccess.remove_absolute(path.path_join(sub))
		elif not remove_tree(path.path_join(sub), group) and group != "" and ExecSafe.stopped(group):
			return false
	return DirAccess.remove_absolute(path) == OK
