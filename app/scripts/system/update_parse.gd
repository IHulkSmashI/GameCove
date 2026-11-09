extends RefCounted
## Parsers for update tool output. Pure functions; tests feed them fixtures.


## `rpm-ostree status --json`: the booted deployment, a staged one (an update
## that applies on the next boot) and rpm-ostree's cached update from the last
## check. {"booted": {...}|{}, "staged": {...}|{}, "cached": {...}|{}, "busy": bool}
## where each deployment is {"version", "checksum", "image", "timestamp"}.
static func rpm_ostree_status(text: String) -> Dictionary:
	var out := {"booted": {}, "staged": {}, "cached": {}, "busy": false}
	var d: Variant = _json(text)
	if not d is Dictionary:
		return out
	out["busy"] = d.get("transaction") != null
	var deps: Variant = d.get("deployments", [])
	if deps is Array:
		for dep in deps:
			if not dep is Dictionary:
				continue
			var item := _deployment(dep)
			if dep.get("booted", false):
				out["booted"] = item
			elif dep.get("staged", false):
				out["staged"] = item
	# A pending deployment rpm-ostree didn't mark staged (older versions put the
	# new one first, not booted): count it when it's first and not booted.
	if out["staged"].is_empty() and deps is Array and deps.size() > 1 and deps[0] is Dictionary \
			and not deps[0].get("booted", false) and not deps[0].get("pinned", false) \
			and int(deps[0].get("timestamp", 0)) > int(out["booted"].get("timestamp", 0)):
		out["staged"] = _deployment(deps[0])
	var cached: Variant = d.get("cached-update")
	if cached is Dictionary:
		out["cached"] = _deployment(cached)
	return out


static func _deployment(dep: Dictionary) -> Dictionary:
	return {
		"version": str(dep.get("version", "")) if dep.get("version") != null else "",
		"checksum": str(dep.get("checksum", "")),
		"image": str(dep.get("container-image-reference", dep.get("origin", ""))).trim_prefix("ostree-image-signed:docker://").trim_prefix("ostree-unverified-registry:"),
		"timestamp": int(dep.get("timestamp", 0)),
	}


## `rpm-ostree upgrade --check` (exit 0 = update, 77 = none).
## {"available": bool, "version": String, "digest": String, "error": String}
static func rpm_ostree_check(code: int, text: String) -> Dictionary:
	var out := {"available": false, "version": "", "digest": "", "error": ""}
	if code == 77:
		return out
	if code != 0:
		out["error"] = last_line(text)
		return out
	var in_update := false
	for raw in text.split("\n", false):
		var line := raw.strip_edges()
		if line.begins_with("AvailableUpdate"):
			in_update = true
			out["available"] = true
		elif line.begins_with("No updates available"):
			return out
		elif in_update and line.begins_with("Version:"):
			out["version"] = line.substr(8).strip_edges().split(" ", false)[0] if line.length() > 8 else ""
		elif in_update and (line.begins_with("Digest:") or line.begins_with("Commit:")):
			out["digest"] = line.substr(line.find(":") + 1).strip_edges()
	return out


## `steamos-update check` (exit 0 = update, 7 = none, anything else = error).
## OGC's wrapper prints "Update available: <version>"; Valve's client may print
## the version on its own line, so a bare version-looking line counts too.
static func steamos_check(code: int, text: String) -> Dictionary:
	var out := {"available": false, "version": "", "error": ""}
	if code == 7:
		return out
	if code != 0:
		out["error"] = last_line(text) if last_line(text) != "" else "steamos-update exited with %d" % code
		return out
	out["available"] = true
	var re := RegEx.new()
	re.compile("(?i)update available:?\\s*(\\S+)")
	var m := re.search(text)
	if m:
		out["version"] = m.get_string(1)
	return out


## Percent from a progress line ("42%", "Receiving objects: 45% (12/30)",
## "[3/10] Fetching"), or -1 when the line has none.
static func progress_percent(line: String) -> float:
	var re := RegEx.new()
	re.compile("(\\d{1,3}(?:\\.\\d+)?)\\s*%")
	var hits := re.search_all(line)
	if not hits.is_empty():
		return clampf(float(hits[hits.size() - 1].get_string(1)), 0.0, 100.0)
	re.compile("\\[(\\d+)/(\\d+)\\]")
	var m := re.search(line)
	if m and int(m.get_string(2)) > 0:
		return clampf(100.0 * int(m.get_string(1)) / int(m.get_string(2)), 0.0, 100.0)
	return -1.0


## `fwupdmgr get-updates --json`. Exit 2 means "nothing to do" in fwupd.
## {"available": bool, "devices": [{"id", "name", "current", "version",
##  "summary", "needs_reboot", "trusted", "details_url"}], "error": String}
static func fwupd_updates(code: int, text: String) -> Dictionary:
	var out := {"available": false, "devices": [], "error": ""}
	var d: Variant = _json(text) if text.strip_edges().begins_with("{") else null
	if not d is Dictionary:
		if code != 0 and code != 2:
			out["error"] = last_line(text) if last_line(text) != "" else "fwupdmgr exited with %d" % code
		return out
	for dev in d.get("Devices", []):
		if not dev is Dictionary:
			continue
		var rels: Variant = dev.get("Releases", [])
		if not rels is Array or rels.is_empty() or not rels[0] is Dictionary:
			continue
		var rel: Dictionary = rels[0]
		var dflags: Array = dev.get("Flags", []) if dev.get("Flags") is Array else []
		var rflags: Array = rel.get("Flags", []) if rel.get("Flags") is Array else []
		out["devices"].append({
			"id": str(dev.get("DeviceId", "")),
			"name": str(dev.get("Name", "")),
			"current": str(dev.get("Version", "")),
			"version": str(rel.get("Version", "")),
			"summary": str(rel.get("Summary", rel.get("Name", ""))),
			"needs_reboot": "needs-reboot" in dflags or "needs-shutdown" in dflags,
			"trusted": "trusted-payload" in rflags or "trusted-metadata" in rflags,
			"details_url": str(rel.get("DetailsUrl", rel.get("Homepage", ""))),
			"notes": strip_markup(str(rel.get("Description", ""))),
		})
	out["available"] = not out["devices"].is_empty()
	return out


## `fwupdmgr get-devices --json`: every device fwupd can update, with its running version.
## [{"id", "name", "current", "vendor", "plugin", "needs_reboot"}]; [] on anything else.
static func fwupd_devices(text: String) -> Array:
	var out: Array = []
	var d: Variant = _json(text) if text.strip_edges().begins_with("{") else null
	if not d is Dictionary:
		return out
	for dev in d.get("Devices", []):
		if not dev is Dictionary:
			continue
		var flags: Array = dev.get("Flags", []) if dev.get("Flags") is Array else []
		if not "updatable" in flags:
			continue
		out.append({
			"id": str(dev.get("DeviceId", "")), "name": str(dev.get("Name", "")),
			"current": str(dev.get("Version", "")), "vendor": str(dev.get("Vendor", "")),
			"plugin": str(dev.get("Plugin", "")),
			"needs_reboot": "needs-reboot" in flags or "needs-shutdown" in flags,
		})
	return out


## fwupd's release descriptions are small XML/HTML ("<p>..</p><ul><li>..</li></ul>"): plain text.
static func strip_markup(text: String) -> String:
	var t := text.replace("</p>", "\n").replace("<li>", "• ").replace("</li>", "\n")
	t = RegEx.create_from_string("<[^>]+>").sub(t, "", true)
	t = t.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"")
	var lines := PackedStringArray()
	for l in t.split("\n", false):
		if l.strip_edges() != "":
			lines.append(l.strip_edges())
	return "\n".join(lines)


## `flatpak remote-ls --updates --<installation> --columns=application,name,version,branch,origin`.
## Tab-separated when not on a terminal; a header line, if any, is skipped.
static func flatpak_updates(text: String, installation: String) -> Array:
	var out: Array = []
	for raw in text.split("\n", false):
		var line := raw.strip_edges(false, true)
		if line.strip_edges() == "":
			continue
		var cols := line.split("\t")
		if cols.size() < 2:
			cols = line.strip_edges().split(" ", false)
		var app := cols[0].strip_edges()
		if app == "" or app == "Application ID" or app == "Application" or not "." in app:
			continue
		out.append({
			"id": app,
			"name": cols[1].strip_edges() if cols.size() > 1 else app,
			"version": cols[2].strip_edges() if cols.size() > 2 else "",
			"branch": cols[3].strip_edges() if cols.size() > 3 else "",
			"origin": cols[4].strip_edges() if cols.size() > 4 else "",
			"installation": installation,
		})
	return out


static func last_line(text: String) -> String:
	var lines := text.strip_edges().split("\n", false)
	return lines[lines.size() - 1].strip_edges() if lines.size() > 0 else ""


## JSON.parse_string without the engine's error line on bad input.
static func _json(text: String) -> Variant:
	var j := JSON.new()
	return j.data if j.parse(text) == OK else null
