extends RefCounted
## The conditions in a fix's lifecycle rules (fixes/<id>/fix.json "needed_when" / "obsolete_when",
## docs/FIXES.md) and the facts about this system they are checked against. Pure: files are only
## read, under `facts.root` (tests: a fixture folder), nothing runs here.
##
## A condition answers YES, NO or UNKNOWN. UNKNOWN (a version that can't be read, a rule this
## build doesn't know) never makes GameCove act: `all` is UNKNOWN unless every part is YES or one
## is NO, `any` is UNKNOWN unless one part is YES or all are NO.
##
##   {"all": [c, ...]}  {"any": [c, ...]}  {"not": c}
##   {"kernel": ">=6.19"}                           the running kernel
##   {"os": "bazzite", "version": ">=45"}           os-release ID / ID_LIKE (version optional)
##   {"bios": ">=E1T91IMS.110", "scheme": "msi"}    DMI bios_version (schemes: firmware_index.gd)
##   {"ec": ">=1.20"}                               DMI ec_firmware_release
##   {"tool": "inputplumber", "version": ">=0.70"}  an installed package (facts.tools)
##   {"file": "/usr/lib/..."}  {"sysfs": "/sys/..."}        the path exists
##   {"file_contains": {"path": ..., "text": ...}}
##   {"sysfs_value": {"path": ..., "equals": ...}}
##   {"module": "hid_msi"}  {"module_param": {"module": ..., "param": ..., "equals": ...}}
##   {"probe": "os_fixed" | "hw_absent"}            what the fix's own `status` reported (facts.probe)

const Index := preload("res://scripts/system/firmware_index.gd")
const DeviceScript := preload("res://scripts/device/device.gd")

const YES := 1
const NO := 0
const UNKNOWN := -1
## Paths a rule may read (the same pattern as tools/fixes/fix.schema.json): system folders only, no "..".
const PATH_RE := "^/(sys|proc|usr|etc|lib|boot|run|var/lib)/[A-Za-z0-9._:+@/-]+$"
const MAX_READ := 256 * 1024
## Package names per tool (rpm on Bazzite / Fedora, pacman on SteamOS / Arch).
const TOOL_PACKAGES := {
	"inputplumber": ["inputplumber"], "hhd": ["hhd"], "steamos-powerbuttond": ["steamos-powerbuttond", "powerbuttond"],
	"steamos-manager": ["steamos-manager"], "gamescope": ["gamescope"],
	"gamescope-session-plus": ["gamescope-session-plus", "gamescope-session"], "powerstation": ["powerstation"],
	"linux-firmware": ["linux-firmware"], "mesa": ["mesa-dri-drivers", "mesa"],
}


static func path_ok(path: String) -> bool:
	return not path.contains("..") and RegEx.create_from_string(PATH_RE).search(path) != null


static func _read(root: String, path: String) -> Variant:
	if not path_ok(path):
		return null
	var f := FileAccess.open(root + path, FileAccess.READ)
	if f == null:
		return null
	return DeviceScript.read_all(f).left(MAX_READ)


static func _exists(root: String, path: String) -> int:
	if not path_ok(path):
		return UNKNOWN
	return YES if FileAccess.file_exists(root + path) or DirAccess.dir_exists_absolute(root + path) else NO


## The leading dotted number of a version ("6.17.7-ba25.fc43" -> [6, 17, 7]); [] when there is none.
static func numbers(version: String) -> Array:
	var m := RegEx.create_from_string("^[^0-9]*([0-9]+(?:\\.[0-9]+)*)").search(version.strip_edges())
	var out: Array = []
	if m != null:
		for p in m.get_string(1).split("."):
			out.append(int(p))
	return out


static func cmp_versions(a: String, b: String) -> int:
	var x := numbers(a)
	var y := numbers(b)
	if x.is_empty() or y.is_empty():
		return -2
	for i in maxi(x.size(), y.size()):
		var p: int = x[i] if i < x.size() else 0
		var q: int = y[i] if i < y.size() else 0
		if p != q:
			return -1 if p < q else 1
	return 0


## "<op><version>" -> [op, version], [] when it isn't one.
static func split_compare(expr: String) -> Array:
	for op in [">=", "<=", "==", ">", "<"]:
		if expr.begins_with(op) and expr.length() > op.length():
			return [op, expr.substr(op.length())]
	return []


## `have` against "<op><want>"; c = a ready comparison (-1, 0, 1, or -2 for "can't tell").
static func _holds(op: String, c: int) -> int:
	if c == -2:
		return UNKNOWN
	match op:
		">=": return YES if c >= 0 else NO
		"<=": return YES if c <= 0 else NO
		"==": return YES if c == 0 else NO
		">": return YES if c > 0 else NO
		"<": return YES if c < 0 else NO
	return UNKNOWN


static func compare(have: String, expr: String, scheme := "natural") -> int:
	var parts := split_compare(expr)
	if parts.is_empty() or have.strip_edges() == "":
		return UNKNOWN
	if scheme == "natural":
		return _holds(parts[0], cmp_versions(have, parts[1]))
	return _holds(parts[0], Index.compare(scheme, have, parts[1]))


static func _all(list: Variant, facts: Dictionary) -> int:
	if not list is Array or (list as Array).is_empty():
		return UNKNOWN
	var unknown := false
	for c in list:
		var r := evaluate(c, facts)
		if r == NO:
			return NO
		unknown = unknown or r == UNKNOWN
	return UNKNOWN if unknown else YES


static func _any(list: Variant, facts: Dictionary) -> int:
	if not list is Array or (list as Array).is_empty():
		return UNKNOWN
	var unknown := false
	for c in list:
		var r := evaluate(c, facts)
		if r == YES:
			return YES
		unknown = unknown or r == UNKNOWN
	return UNKNOWN if unknown else NO


static func evaluate(cond: Variant, facts: Dictionary) -> int:
	if not cond is Dictionary:
		return UNKNOWN
	var c: Dictionary = cond
	var root := str(facts.get("root", ""))
	if c.has("all"):
		return _all(c["all"], facts)
	if c.has("any"):
		return _any(c["any"], facts)
	if c.has("not"):
		var r := evaluate(c["not"], facts)
		return UNKNOWN if r == UNKNOWN else (NO if r == YES else YES)
	if c.has("kernel"):
		return compare(str(facts.get("kernel", "")), str(c["kernel"]))
	if c.has("os"):
		var ids: Array = [str(facts.get("os_id", ""))] + (facts.get("os_like", []) as Array)
		if str(facts.get("os_id", "")) == "":
			return UNKNOWN
		if not str(c["os"]) in ids:
			return NO
		return compare(str(facts.get("os_version", "")), str(c["version"])) if c.has("version") else YES
	if c.has("bios"):
		return compare(str(facts.get("bios", "")), str(c["bios"]), str(c.get("scheme", "natural")))
	if c.has("ec"):
		return compare(str(facts.get("ec", "")), str(c["ec"]))
	if c.has("tool"):
		var tools: Dictionary = facts.get("tools", {}) if facts.get("tools") is Dictionary else {}
		return compare(str(tools.get(str(c["tool"]), "")), str(c.get("version", "")))
	if c.has("file"):
		return _exists(root, str(c["file"]))
	if c.has("sysfs"):
		return _exists(root, str(c["sysfs"]))
	if c.has("file_contains") and c["file_contains"] is Dictionary:
		var fc: Dictionary = c["file_contains"]
		if not path_ok(str(fc.get("path", ""))) or str(fc.get("text", "")) == "":
			return UNKNOWN
		var text: Variant = _read(root, str(fc["path"]))
		return NO if text == null else (YES if str(text).contains(str(fc["text"])) else NO)
	if c.has("sysfs_value") and c["sysfs_value"] is Dictionary:
		var sv: Dictionary = c["sysfs_value"]
		if not path_ok(str(sv.get("path", ""))):
			return UNKNOWN
		var val: Variant = _read(root, str(sv["path"]))
		return NO if val == null else (YES if str(val).strip_edges() == str(sv.get("equals", "")) else NO)
	if c.has("module"):
		return _exists(root, "/sys/module/" + str(c["module"]))
	if c.has("module_param") and c["module_param"] is Dictionary:
		var mp: Dictionary = c["module_param"]
		var p := "/sys/module/%s/parameters/%s" % [str(mp.get("module", "")), str(mp.get("param", ""))]
		if not mp.has("equals"):
			return _exists(root, p)
		var v: Variant = _read(root, p)
		return NO if v == null else (YES if str(v).strip_edges() == str(mp["equals"]) else NO)
	if c.has("probe"):
		var probe: Dictionary = facts.get("probe", {}) if facts.get("probe") is Dictionary else {}
		return int(probe.get(str(c["probe"]), UNKNOWN))
	return UNKNOWN   # a rule from a newer GameCove: never acted on


## Every tool a condition names (so only those versions are asked for).
static func tools_in(cond: Variant, out: Array = []) -> Array:
	if cond is Dictionary:
		for k in ["all", "any"]:
			if cond.get(k) is Array:
				for c in cond[k]:
					tools_in(c, out)
		if cond.has("not"):
			tools_in(cond["not"], out)
		if cond.has("tool") and TOOL_PACKAGES.has(str(cond["tool"])) and not str(cond["tool"]) in out:
			out.append(str(cond["tool"]))
	return out


static func uses_probe(cond: Variant) -> bool:
	if not cond is Dictionary:
		return false
	for k in ["all", "any"]:
		if cond.get(k) is Array:
			for c in cond[k]:
				if uses_probe(c):
					return true
	if cond.has("not"):
		return uses_probe(cond["not"])
	return cond.has("probe")


static func _os_release(root: String) -> Dictionary:
	var vals := {}
	var f := FileAccess.open(root + "/etc/os-release", FileAccess.READ)
	if f == null:
		f = FileAccess.open(root + "/usr/lib/os-release", FileAccess.READ)
	if f == null:
		return vals
	for line in DeviceScript.read_all(f).split("\n", false):
		var i := line.find("=")
		if i > 0:
			vals[line.substr(0, i)] = line.substr(i + 1).strip_edges().trim_prefix("\"").trim_suffix("\"").trim_prefix("'").trim_suffix("'")
	return vals


## What this system is, from files only: kernel, OS id and version, BIOS and EC versions.
## (Tool versions and probe answers are added by whoever ran those commands.)
static func gather(root := "") -> Dictionary:
	var facts := {"root": root, "tools": {}, "probe": {}}
	var k := FileAccess.open(root + "/proc/sys/kernel/osrelease", FileAccess.READ)
	facts["kernel"] = DeviceScript.read_all(k).strip_edges() if k != null else ""
	var os := _os_release(root)
	facts["os_id"] = str(os.get("ID", "")).to_lower()
	facts["os_like"] = Array(str(os.get("ID_LIKE", "")).to_lower().split(" ", false))
	# Bazzite's image version is OSTREE_VERSION / IMAGE_VERSION ("44.20261101.0"); SteamOS: VERSION_ID ("3.8.1")
	facts["os_version"] = str(os.get("OSTREE_VERSION", os.get("IMAGE_VERSION", os.get("VERSION_ID", os.get("BUILD_ID", "")))))
	var inst := Index.read_installed(root)
	facts["bios"] = str(inst.get("bios_version", ""))
	facts["ec"] = str(inst.get("ec_firmware_release", ""))
	return facts


## What changed between two gather() results that should make every fix be looked at again.
static func system_key(facts: Dictionary) -> String:
	return "%s|%s %s|%s|%s" % [facts.get("kernel", ""), facts.get("os_id", ""), facts.get("os_version", ""), facts.get("bios", ""), facts.get("ec", "")]


## The version out of `rpm -q --qf %{VERSION}` / `pacman -Q <pkg>` output ("" when not installed).
static func parse_package_version(output: String) -> String:
	var line := output.strip_edges().get_slice("\n", 0)
	if line == "" or line.contains("not installed") or line.contains("was not found") or line.begins_with("error"):
		return ""
	var parts := line.split(" ", false)
	var v := parts[parts.size() - 1]
	return v if not numbers(v).is_empty() else ""
