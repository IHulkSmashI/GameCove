extends RefCounted
## Parsers for storage: findmnt / lsblk / df output, Steam's libraryfolders.vdf,
## Heroic's install folder. Pure functions; tests feed them fixtures.

const Vdf := preload("res://scripts/launch/vdf.gd")

## Mount points that never hold games.
const SKIP_TARGET_PREFIXES := ["/boot", "/efi", "/sysroot", "/var/lib/containers", "/var/lib/docker",
	"/snap", "/var/lib/flatpak/runtime"]
## Preferred mount point per drive, best first (Bazzite's /var/home is where ~ lives).
const PREFERRED_TARGETS := ["/var/home", "/home", "/run/media/", "/media/", "/mnt/", "/var", "/"]


static func _int(v: Variant) -> int:
	if v == null:
		return -1
	if typeof(v) == TYPE_STRING:
		return int(v) if (v as String).is_valid_int() else -1
	return int(v)


static func _bool(v: Variant) -> bool:
	if typeof(v) == TYPE_STRING:
		return v == "1" or v == "true"
	return bool(v) if v != null else false


## "/dev/nvme0n1p3[/home]" -> "/dev/nvme0n1p3" (btrfs subvolumes show this way).
static func base_source(source: String) -> String:
	var i := source.find("[")
	return source.substr(0, i) if i > 0 else source


## `findmnt --json --list -b -o SOURCE,TARGET,FSTYPE,SIZE,USED,AVAIL,OPTIONS`.
## Only block devices. [{"source", "device", "target", "fstype", "size", "used", "free", "options"}]
static func findmnt(text: String) -> Array:
	var out: Array = []
	var d: Variant = _json(text)
	if not d is Dictionary:
		return out
	var stack: Array = (d.get("filesystems", []) as Array).duplicate()
	while not stack.is_empty():
		var fs: Variant = stack.pop_front()
		if not fs is Dictionary:
			continue
		if fs.get("children") is Array:
			stack.append_array(fs["children"])
		var src := str(fs.get("source", ""))
		if not src.begins_with("/dev/"):
			continue
		out.append({
			"source": src, "device": base_source(src), "target": str(fs.get("target", "")),
			"fstype": str(fs.get("fstype", "")),
			"size": _int(fs.get("size")), "used": _int(fs.get("used")), "free": _int(fs.get("avail")),
			"options": str(fs.get("options", "")),
		})
	return out


## `lsblk --json -b -o NAME,PATH,PKNAME,TYPE,SIZE,RM,HOTPLUG,TRAN,MODEL,LABEL,FSTYPE`.
## Flattened; partitions inherit transport/model/removable from their disk.
## {"/dev/x": {"name", "disk", "type", "size", "kind", "model", "label", "fstype", "tran"}}
static func lsblk(text: String) -> Dictionary:
	var out := {}
	var d: Variant = _json(text)
	if not d is Dictionary:
		return out
	for dev in d.get("blockdevices", []):
		_lsblk_walk(dev, {}, out)
	return out


static func _lsblk_walk(dev: Variant, parent: Dictionary, out: Dictionary) -> void:
	if not dev is Dictionary:
		return
	var name := str(dev.get("name", ""))
	var path := str(dev.get("path", "/dev/" + name))
	var disk: String = parent.get("disk", name) if not parent.is_empty() else name
	var tran := str(dev.get("tran", "")) if dev.get("tran") != null else ""
	if tran == "":
		tran = parent.get("tran", "")
	var model := str(dev.get("model", "")) if dev.get("model") != null else ""
	if model == "":
		model = parent.get("model", "")
	var removable: bool = _bool(dev.get("rm")) or _bool(dev.get("hotplug")) or parent.get("removable", false)
	var kind := "internal"
	if disk.begins_with("mmcblk") or tran == "mmc":
		kind = "sd"
	elif tran == "usb" or tran == "ieee1394" or removable:
		kind = "external"
	var item := {"name": name, "disk": disk, "type": str(dev.get("type", "")), "size": _int(dev.get("size")),
		"kind": kind, "model": model.strip_edges(), "label": str(dev.get("label", "")) if dev.get("label") != null else "",
		"fstype": str(dev.get("fstype", "")) if dev.get("fstype") != null else "", "tran": tran, "removable": removable}
	out[path] = item
	for child in dev.get("children", []):
		_lsblk_walk(child, {"disk": disk, "tran": tran, "model": model, "removable": removable}, out)


## `df -B1 --output=source,fstype,size,used,avail,target [paths]` (fallback
## when findmnt lacks size columns). Same shape as findmnt().
static func df(text: String) -> Array:
	var out: Array = []
	var lines := text.split("\n", false)
	for i in lines.size():
		var cols := lines[i].strip_edges().split(" ", false)
		if i == 0 and cols.size() > 0 and cols[0].to_lower().begins_with("filesystem"):
			continue
		if cols.size() < 6 or not cols[0].begins_with("/dev/"):
			continue
		out.append({"source": cols[0], "device": base_source(cols[0]), "fstype": cols[1],
			"size": _int(cols[2]), "used": _int(cols[3]), "free": _int(cols[4]),
			"target": " ".join(cols.slice(5)), "options": ""})
	return out


## btrfs compression from mount options ("compress=zstd:1" -> "zstd:1"), "" if none.
static func compression(options: String) -> String:
	for opt in options.split(",", false):
		for key in ["compress-force=", "compress="]:
			if opt.begins_with(key):
				var v := opt.substr(key.length())
				return "" if v == "no" or v == "none" else v
	return ""


static func _target_rank(target: String) -> int:
	for i in PREFERRED_TARGETS.size():
		var p: String = PREFERRED_TARGETS[i]
		if target == p or (p.ends_with("/") and target.begins_with(p)):
			return i
	return PREFERRED_TARGETS.size()


static func _skip(target: String) -> bool:
	for p in SKIP_TARGET_PREFIXES:
		if target == p or target.begins_with(p + "/"):
			return true
	return false


## One entry per drive (partition) that can hold games, best mount point first.
## [{"device", "kind": internal|sd|external, "label", "model", "fstype",
##   "mount", "mounts": [...], "size", "used", "free", "compression", "removable"}]
static func drives(mounts: Array, blk: Dictionary) -> Array:
	var by_dev := {}
	var order: Array = []
	for m in mounts:
		if m["fstype"] in ["swap", "squashfs", "erofs", "iso9660"] or _skip(m["target"]):
			continue
		var dev: String = m["device"]
		if not by_dev.has(dev):
			by_dev[dev] = []
			order.append(dev)
		by_dev[dev].append(m)
	var out: Array = []
	for dev in order:
		var ms: Array = by_dev[dev]
		ms.sort_custom(func(a, b): return _target_rank(a["target"]) < _target_rank(b["target"]) \
			or (_target_rank(a["target"]) == _target_rank(b["target"]) and a["target"].length() < b["target"].length()))
		var best: Dictionary = ms[0]
		var info: Dictionary = blk.get(dev, {})
		var kind: String = info.get("kind", "internal")
		if kind == "internal" and (best["target"].begins_with("/run/media/") or best["target"].begins_with("/media/")):
			kind = "external"
		out.append({
			"device": dev, "kind": kind,
			"label": info.get("label", best["target"].get_file()),
			"model": info.get("model", ""),
			"fstype": best["fstype"] if best["fstype"] != "" else info.get("fstype", ""),
			"mount": best["target"], "mounts": ms.map(func(m): return m["target"]),
			"size": best["size"], "used": best["used"], "free": best["free"],
			"compression": compression(best["options"]) if best["fstype"] == "btrfs" else "",
			"removable": info.get("removable", kind != "internal"),
		})
	return out


## The mount (from findmnt()/df()) holding `path`: longest matching target.
static func mount_for(path: String, mounts: Array) -> Dictionary:
	var best := {}
	for m in mounts:
		var t: String = m["target"]
		if path == t or path.begins_with(t.trim_suffix("/") + "/") or t == "/":
			if best.is_empty() or t.length() > best["target"].length():
				best = m
	return best


## Steam's libraryfolders.vdf: [{"path", "bytes", "games"}]. "bytes" is the sum
## of Steam's own per-app sizes ("apps" block), so no folder walk is needed.
static func steam_libraries(vdf_text: String) -> Array:
	var out: Array = []
	var root := Vdf.find_ci(Vdf.parse(vdf_text), "libraryfolders")
	for k in root:
		var f: Variant = root[k]
		if not f is Dictionary:
			continue
		var path := str(Vdf.get_ci(f, "path", ""))
		if path == "":
			continue
		var apps: Variant = Vdf.get_ci(f, "apps", {})
		var total := 0
		var count := 0
		if apps is Dictionary:
			for a in apps:
				count += 1
				total += maxi(0, _int(apps[a]))
		out.append({"path": path.replace("\\\\", "\\"), "bytes": total, "games": count})
	return out


## Heroic's default install folder from <heroic>/config.json, "" when unset.
static func heroic_install_path(config_text: String, home: String) -> String:
	var d: Variant = _json(config_text)
	if not d is Dictionary:
		return ""
	var s: Variant = d.get("defaultSettings", {})
	if not s is Dictionary:
		return ""
	var p := str(s.get("defaultInstallPath", ""))
	return home + p.substr(1) if p.begins_with("~") else p


## Block-device lines of /proc/self/mounts, sorted: changes when anything is
## plugged, mounted or removed. Cheap to compare.
static func mounts_signature(proc_mounts: String) -> String:
	var lines: Array = []
	for l in proc_mounts.split("\n", false):
		if l.begins_with("/dev/"):
			var cols := l.split(" ", false)
			if cols.size() >= 2:
				lines.append(cols[0] + " " + cols[1])
	lines.sort()
	return "\n".join(PackedStringArray(lines))


## JSON.parse_string without the engine's error line on bad input.
static func _json(text: String) -> Variant:
	var j := JSON.new()
	return j.data if j.parse(text) == OK else null
