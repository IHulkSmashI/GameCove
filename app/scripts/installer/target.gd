extends RefCounted
## What the installer is working with: the OS and how GameCove installs on it,
## the downloaded release, whether GameCove is installed already (live or
## staged for the next boot), and Steam's state. Pure file reads over `paths`
## (and its root prefix), so tests use fixture folders.

const OsInfo := preload("res://scripts/system/os_info.gd")
const Login := preload("res://scripts/system/store_login.gd")

## family -> install method.
const METHODS := {"bazzite": "rpm-ostree", "fedora-atomic": "rpm-ostree", "steamos": "sysext"}


## {"os": OsInfo.detect(), "family", "method": rpm-ostree|sysext|none,
##  "supported": bool, "release": {"tag", "version", "os", "package"},
##  "package": path ("" when missing), "installed": bool (in /usr now),
##  "staged": bool (installed, waiting for a reboot), "state": install-state or {},
##  "maintenance": bool (installed or staged: offer change / repair / update / uninstall),
##  "update_available": bool, "pending": pending-choices dict, "steam": {"installed", "signed_in", "account"}}
static func detect(paths: RefCounted, path_env := "") -> Dictionary:
	var os_info := OsInfo.detect(paths.root)
	var family := str(os_info.get("family", "other"))
	var method: String = METHODS.get(family, "none")
	if method == "rpm-ostree" and not bool(os_info.get("atomic", false)):
		method = "none"
	var release := read_release(paths.release_file())
	var pkg := str(release.get("package", ""))
	if pkg != "" and not FileAccess.file_exists(pkg):
		pkg = ""
	var state := read_state(paths.state_file())
	var live := FileAccess.file_exists(paths.installed_binary())
	var staged := not live and str(state.get("stage", "")) == "staged"
	var installed_version := str(state.get("version", ""))
	var steam: Dictionary = Login.status(paths.home, path_env if path_env != "" else OS.get_environment("PATH")).get("steam", {})
	return {
		"os": os_info,
		"family": family,
		"method": method,
		"supported": method != "none",
		"release": release,
		"package": pkg,
		"installed": live,
		"staged": staged,
		"state": state,
		"maintenance": live or staged or not state.is_empty(),
		"update_available": installed_version != "" and str(release.get("version", "")) != "" \
			and newer(str(release["version"]), installed_version),
		"pending": read_pending(paths.pending_file()),
		"fix_choices": read_fix_choices(paths.data_dir().path_join("fixes.cfg")),
		"steam": {"installed": str(steam.get("tool", "")) != "" or str(steam.get("config", "")) != "",
			"signed_in": bool(steam.get("signed_in", false)), "account": str(steam.get("account", ""))},
	}


## What the user did on the Fixes page (device/fixes.gd), per device:
## {"<device key>": {"<fix>": "on" | "off"}}. Repair and change must not put back
## a fix the user undid there.
static func read_fix_choices(path: String) -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return {}
	var out := {}
	for sec in cfg.get_sections():
		if not sec.begins_with("fixes@"):
			continue
		var per := {}
		for k in cfg.get_section_keys(sec):
			per[k] = str(cfg.get_value(sec, k))
		out[sec.trim_prefix("fixes@")] = per
	return out


## release.env from get-gamecove.sh -> {"tag", "version", "os", "package", "app"}.
static func read_release(path: String) -> Dictionary:
	var kv := read_kv(path)
	return {"tag": kv.get("TAG", ""), "version": kv.get("VERSION", ""), "os": kv.get("OS", ""),
		"package": kv.get("PACKAGE", ""), "app": kv.get("APP", "")}


static func read_state(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var j := JSON.new()
	if j.parse(FileAccess.get_file_as_string(path)) != OK or not j.data is Dictionary:
		return {}
	return j.data


## KEY=value lines (no quotes, no shell): the format the shell helpers share.
static func read_kv(path: String) -> Dictionary:
	var out := {}
	if not FileAccess.file_exists(path):
		return out
	for raw in FileAccess.get_file_as_string(path).split("\n", false):
		var line := raw.strip_edges()
		var i := line.find("=")
		if line.begins_with("#") or i <= 0:
			continue
		out[line.substr(0, i)] = line.substr(i + 1)
	return out


static func read_pending(path: String) -> Dictionary:
	return read_kv(path)


## True when version a is newer than b ("0.10.0" > "0.9.1").
static func newer(a: String, b: String) -> bool:
	var pa := a.trim_prefix("v").split(".")
	var pb := b.trim_prefix("v").split(".")
	for i in maxi(pa.size(), pb.size()):
		var x := int(pa[i]) if i < pa.size() else 0
		var y := int(pb[i]) if i < pb.size() else 0
		if x != y:
			return x > y
	return false
