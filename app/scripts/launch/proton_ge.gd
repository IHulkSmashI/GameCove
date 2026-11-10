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

const Proton := preload("res://scripts/launch/proton.gd")
const VDF := preload("res://scripts/launch/vdf.gd")

const API := "https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest"
## Downloads are only taken from this release page.
const DOWNLOAD_PREFIX := "https://github.com/GloriousEggroll/proton-ge-custom/releases/download/"
const TAG_RE := "^GE-Proton[0-9]+-[0-9]+$"
## Where a download waits for its checksum (inside compatibilitytools.d, so the
## unpack is on the same drive).
const DOWNLOAD_DIR := ".gamecove-download"


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
	var r: Dictionary = runner.run("curl", PackedStringArray(["-fsSL", "--max-time", "20",
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
		if c["flavour"] != "ge" or path.get_file().begins_with("."):
			continue
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


## Downloads, checks and unpacks `rel` into `dir`. {"ok": bool, "error": ""|reason}
## reasons: "exists", "download", "checksum", "unpack", "no_steam".
static func install(runner: RefCounted, rel: Dictionary, dir: String) -> Dictionary:
	if dir == "" or rel.is_empty():
		return {"ok": false, "error": "no_steam"}
	var tag := str(rel.get("tag", ""))
	if RegEx.create_from_string(TAG_RE).search(tag) == null:
		return {"ok": false, "error": "download"}
	if DirAccess.dir_exists_absolute(dir.path_join(tag)):
		return {"ok": false, "error": "exists"}
	var part := dir.path_join(DOWNLOAD_DIR)
	remove_tree(part)
	DirAccess.make_dir_recursive_absolute(part)
	var tarball := part.path_join(tag + ".tar.gz")
	var shafile := part.path_join(tag + ".sha512sum")
	var res := _fetch_check_unpack(runner, rel, dir, tarball, shafile)
	remove_tree(part)
	if res["ok"] and not FileAccess.file_exists(dir.path_join(tag).path_join("compatibilitytool.vdf")):
		remove_tree(dir.path_join(tag))
		return {"ok": false, "error": "unpack"}
	return res


static func _fetch_check_unpack(runner: RefCounted, rel: Dictionary, dir: String, tarball: String, shafile: String) -> Dictionary:
	for job in [[str(rel["sha512"]), shafile], [str(rel["tarball"]), tarball]]:
		var url: String = job[0]
		if not url.begins_with(DOWNLOAD_PREFIX):
			return {"ok": false, "error": "download"}
		var r: Dictionary = runner.run("curl", PackedStringArray(["-fsSL", "--retry", "2", "--connect-timeout", "20",
			"-H", "User-Agent: GameCove", "-o", job[1], url]))
		if int(r.get("code", -1)) != 0:
			return {"ok": false, "error": "download"}
	var want := parse_sha(_read(shafile))
	var s: Dictionary = runner.run("sha512sum", PackedStringArray([tarball]))
	var got := parse_sha(str(s.get("out", ""))) if int(s.get("code", -1)) == 0 else ""
	if want == "" or got != want:
		return {"ok": false, "error": "checksum"}
	var t: Dictionary = runner.run("tar", PackedStringArray(["-xzf", tarball, "-C", dir, "--no-same-owner"]))
	if int(t.get("code", -1)) != 0:
		remove_tree(dir.path_join(str(rel["tag"])))
		return {"ok": false, "error": "unpack"}
	return {"ok": true, "error": ""}


static func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text() if f != null else ""


## Removes one GE-Proton folder from `dir`. Refused ("in_use") while a Steam game
## is set to it, and for anything that isn't a GE-Proton folder right inside `dir`.
static func remove(dir: String, name: String, steam_root: String) -> String:
	var target := dir.path_join(name)
	if dir == "" or name.contains("/") or name.begins_with(".") or Proton.classify(name)["flavour"] != "ge" \
			or not DirAccess.dir_exists_absolute(target):
		return "not_found"
	for t in installed(dir):
		if t["name"] == name and not games_using(steam_root, str(t["internal"])).is_empty():
			return "in_use"
	return "" if remove_tree(target) else "failed"


## Deletes a folder tree; a symlink inside is removed as a link, never followed.
static func remove_tree(path: String) -> bool:
	var d := DirAccess.open(path)
	if d == null:
		return not DirAccess.dir_exists_absolute(path)
	d.include_hidden = true
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	for sub in d.get_directories():
		if d.is_link(sub):
			DirAccess.remove_absolute(path.path_join(sub))
		else:
			remove_tree(path.path_join(sub))
	return DirAccess.remove_absolute(path) == OK
