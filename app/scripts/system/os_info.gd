extends RefCounted
## Which OS this is and how it updates. Pure functions over files under `root`
## ("" on the real system, a fixture folder in tests).
##
## Backends for the OS image (docs/SYSTEM.md has the research):
##   steamos-update  /usr/bin/steamos-polkit-helpers/steamos-update [check]
##                   The script Steam's own Gaming Mode runs. It re-runs itself
##                   under `pkexec --disable-internal-agent`; polkit allows the
##                   active session without a password (SteamOS; on Bazzite deck
##                   images the OGC gamescope-session-steam package ships it and
##                   it calls /usr/libexec/ogc/os-update, which runs uupd).
##                   check: exit 0 = update, 7 = none. apply: prints "NN%" lines.
##   rpm-ostree      `rpm-ostree upgrade --check` / `rpm-ostree upgrade`, through
##                   rpm-ostreed over D-Bus. Fedora Atomic 41+ allows actions
##                   repo-refresh and upgrade to any active local session without
##                   a password (/etc/polkit-1/rules.d/org.projectatomic.rpmostree1.rules).
##                   check: exit 0 = update, 77 = none.
## bootc is not used: `bootc upgrade --check` and `bootc status` need root.

const STEAM_HELPER := "/usr/bin/steamos-polkit-helpers/steamos-update"
const RPM_OSTREE := "/usr/bin/rpm-ostree"
## Bazzite's os-update restarts graphical.target (ends the session) the first
## time it runs and only creates this file then. Never call it before Steam's
## Gaming Mode has: without the file we use rpm-ostree instead.
const BAZZITE_FIRST_RUN := "/etc/bazzite/fixups/first_steam_gamemode_boostrap"
const BAZZITE_OS_UPDATE := "/usr/libexec/ogc/os-update"

const NOTES := {
	"bazzite": "https://github.com/ublue-os/bazzite/releases",
	"steamos": "https://store.steampowered.com/news/app/1675200",
	"fedora": "https://fedoraproject.org/atomic-desktops/",
}


## /etc/os-release (then /usr/lib/os-release) as a Dictionary, quotes removed.
static func parse_os_release(text: String) -> Dictionary:
	var out := {}
	for raw in text.split("\n", false):
		var line := raw.strip_edges()
		if line == "" or line.begins_with("#"):
			continue
		var i := line.find("=")
		if i <= 0:
			continue
		var v := line.substr(i + 1).strip_edges()
		if v.length() >= 2 and (v[0] == "\"" or v[0] == "'") and v[v.length() - 1] == v[0]:
			v = v.substr(1, v.length() - 2).replace("\\\"", "\"").replace("\\$", "$").replace("\\\\", "\\")
		out[line.substr(0, i)] = v
	return out


static func read_os_release(root := "") -> Dictionary:
	for p in ["/etc/os-release", "/usr/lib/os-release"]:
		if FileAccess.file_exists(root + p):
			return parse_os_release(FileAccess.get_file_as_string(root + p))
	return {}


## Universal Blue's /usr/share/ublue-os/image-info.json ({} when absent).
static func read_image_info(root := "") -> Dictionary:
	var p := root + "/usr/share/ublue-os/image-info.json"
	if not FileAccess.file_exists(p):
		return {}
	var d: Variant = _json(FileAccess.get_file_as_string(p))
	return d if d is Dictionary else {}


## {"id", "name", "version", "variant", "image", "atomic", "family", "backend",
##  "apply_via", "notes_url"}.
## family: steamos | bazzite | fedora-atomic | other.
## backend (how we check): steamos-update | rpm-ostree | none.
## apply_via (how we apply): steamos-update | rpm-ostree | none.
static func detect(root := "") -> Dictionary:
	var rel := read_os_release(root)
	var img := read_image_info(root)
	var id := str(rel.get("ID", ""))
	var like := str(rel.get("ID_LIKE", "")).split(" ", false)
	var out := {
		"id": id,
		"name": str(rel.get("PRETTY_NAME", rel.get("NAME", id))),
		"version": str(rel.get("VERSION_ID", rel.get("BUILD_ID", ""))),
		"variant": str(rel.get("VARIANT_ID", img.get("image-name", ""))),
		"image": str(img.get("image-ref", "")).trim_prefix("ostree-image-signed:docker://"),
		"atomic": FileAccess.file_exists(root + "/run/ostree-booted"),
		"family": "other",
		"backend": "none",
		"apply_via": "none",
		"notes_url": "",
	}
	if img.has("image-name"):
		out["variant"] = str(img["image-name"])
	var has_helper := FileAccess.file_exists(root + STEAM_HELPER)
	var has_rpm_ostree := FileAccess.file_exists(root + RPM_OSTREE)
	if id == "steamos":
		out["family"] = "steamos"
		out["notes_url"] = NOTES["steamos"]
		if has_helper:
			out["backend"] = "steamos-update"
			out["apply_via"] = "steamos-update"
		out["version"] = str(rel.get("VERSION_ID", "")) + ("" if str(rel.get("BUILD_ID", "")) == "" else " (" + str(rel["BUILD_ID"]) + ")")
		return out
	if id == "bazzite" or (img.get("image-vendor", "") == "ublue-os" and str(img.get("image-name", "")).begins_with("bazzite")):
		out["family"] = "bazzite"
		out["notes_url"] = NOTES["bazzite"]
		if str(rel.get("OSTREE_VERSION", "")) != "":
			out["version"] = str(rel["OSTREE_VERSION"])
	elif out["atomic"] and (id == "fedora" or "fedora" in like):
		out["family"] = "fedora-atomic"
		out["notes_url"] = NOTES["fedora"]
	else:
		return out
	if has_rpm_ostree and out["atomic"]:
		out["backend"] = "rpm-ostree"
		out["apply_via"] = "rpm-ostree"
	# Bazzite deck images: apply the way Gaming Mode does (progress, no password).
	if out["family"] == "bazzite" and has_helper and FileAccess.file_exists(root + BAZZITE_OS_UPDATE) \
			and FileAccess.file_exists(root + BAZZITE_FIRST_RUN):
		out["apply_via"] = "steamos-update"
		if out["backend"] == "none":
			out["backend"] = "steamos-update"
	return out


## JSON.parse_string without the engine's error line on bad input.
static func _json(text: String) -> Variant:
	var j := JSON.new()
	return j.data if j.parse(text) == OK else null
