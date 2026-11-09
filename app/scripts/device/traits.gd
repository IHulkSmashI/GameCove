extends RefCounted
## Shared-component traits (devices.json "traits") and the selectors that fixes,
## quirks and device-matrix expectations use, so a fix or setting found on one
## handheld applies to every handheld with the same part. The same rules as
## tools/traits/traits.py (the tests check both resolve the catalogue alike).
##
## Selectors:
##   "*"                      every row
##   "<device id>"            one row
##   "<key>:<pat>|<pat>"      a trait value, shell globs, any case; list traits
##                            match when any element does. Keys: TRAIT_KEYS, id,
##                            family, maker, tier, panel (= panel.id),
##                            panel.<field>, driver (gpu_driver or ec), vendor
##   ["a", "b"]               any of them
##   {"any-of": [...]}, {"all-of": [...]}, {"not": sel}
## Pure functions over row Dictionaries: safe on any thread.

const TRAIT_KEYS := ["platform", "soc", "gpu_arch", "gpu_driver", "cpu_vendor", "ec", "controller", "imu",
	"wifi", "panel", "audio", "fingerprint", "firmware", "session_quirk"]
const ROW_KEYS := ["id", "family", "maker", "tier"]
const QUIRKS_PATH := "res://data/quirks.json"
const FIXES_PATH := "res://data/fixes.json"

static var _quirks: Array = []
static var _quirks_loaded := false


## A row's values for one selector key, as lower-case strings ([] = unknown).
static func values(row: Dictionary, key: String) -> Array:
	var t: Dictionary = row.get("traits", {}) if row.get("traits") is Dictionary else {}
	var v: Variant = null
	if key in ROW_KEYS:
		v = row.get(key)
	elif key == "vendor":
		v = t.get("cpu_vendor", row.get("cpu_vendor"))
	elif key == "driver":
		v = (t.get("gpu_driver", []) if t.get("gpu_driver") is Array else []) + (t.get("ec", []) if t.get("ec") is Array else [])
	elif key == "panel":
		v = (t.get("panel") as Dictionary).get("id") if t.get("panel") is Dictionary else null
	elif key.begins_with("panel."):
		if t.get("panel") is Dictionary:
			v = (t["panel"] as Dictionary).get(key.substr(6))
			if v is Array and v.size() == 2:
				v = "%s-%s" % [_num(v[0]), _num(v[1])]
			elif v is bool:
				v = "yes" if v else "no"
	else:
		v = t.get(key)
	if v == null:
		return []
	var out: Array = []
	for x in (v if v is Array else [v]):
		out.append(_num(x).to_lower())
	return out


static func _num(x: Variant) -> String:
	if x is float and x == floorf(x):
		return str(int(x))
	return str(x)


## True when `sel` picks this row.
static func matches(sel: Variant, row: Dictionary) -> bool:
	if sel is Array:
		for s in sel:
			if matches(s, row):
				return true
		return false
	if sel is Dictionary:
		if sel.size() != 1:
			return false
		var k: String = sel.keys()[0]
		var v: Variant = sel[k]
		match k:
			"any-of":
				return v is Array and matches(v, row)
			"all-of":
				if not v is Array or v.is_empty():
					return false
				for s in v:
					if not matches(s, row):
						return false
				return true
			"not":
				return not matches(v, row)
		return false
	if not (sel is String or sel is StringName):
		return false
	var s := str(sel)
	if s == "*":
		return true
	var i := s.find(":")
	if i < 0:
		return s == str(row.get("id", ""))
	var have := values(row, s.substr(0, i))
	for p in s.substr(i + 1).to_lower().split("|"):
		for h in have:
			if str(h).match(p):
				return true
	return false


## A short "because ..." for the parts of `sel` that hold on this row.
static func why(sel: Variant, row: Dictionary) -> String:
	if sel is Array:
		sel = {"any-of": sel}
	if sel is Dictionary and sel.size() == 1:
		var k: String = sel.keys()[0]
		if k == "not":
			return "not " + str(sel[k])
		var parts: Array = []
		for s in sel[k]:
			if matches(s, row):
				parts.append(why(s, row))
		if parts.is_empty():
			return ""
		return " and ".join(PackedStringArray(parts)) if k == "all-of" else str(parts[0])
	var s := str(sel)
	if s == "*":
		return "every handheld"
	if not ":" in s:
		return "this model"
	var key := s.get_slice(":", 0)
	return "%s %s" % [key, "/".join(PackedStringArray(values(row, key)))]


## Ids of the rows `sel` picks, minus `exclude`.
static func resolve(sel: Variant, rows: Array, exclude: Variant = {}) -> Array:
	var out: Array = []
	if sel == null:
		return out
	for r in rows:
		if r is Dictionary and not _excluded(exclude, str(r.get("id", ""))) and matches(sel, r):
			out.append(r["id"])
	return out


static func _excluded(exclude: Variant, id: String) -> bool:
	return (exclude is Dictionary and exclude.has(id)) or (exclude is Array and id in exclude)


static func _empty_sel(sel: Variant) -> bool:
	return sel == null or (sel is Array and sel.is_empty()) or (sel is String and sel == "")


## Catalogue entry (fixes.json) -> is it auto-applied / offered on this row?
static func fix_auto(entry: Dictionary, row: Dictionary) -> bool:
	var id := str(row.get("id", "unknown"))
	if id == "unknown" or _empty_sel(entry.get("auto")) or _excluded(entry.get("exclude", {}), id):
		return false
	return matches(entry["auto"], row)


static func fix_optional(entry: Dictionary, row: Dictionary) -> bool:
	var id := str(row.get("id", "unknown"))
	if id == "unknown" or _empty_sel(entry.get("optional")) or _excluded(entry.get("exclude", {}), id):
		return false
	return matches(entry["optional"], row) and not fix_auto(entry, row)


## Folder fixes (kind root / file) the installer applies on this row, in catalogue order.
static func auto_fixes(row: Dictionary, catalogue: Array = []) -> Array:
	if catalogue.is_empty():
		catalogue = load_fixes()
	var out: Array = []
	for e in catalogue:
		if e is Dictionary and str(e.get("kind", "")) in ["root", "file"] and fix_auto(e, row):
			out.append(e["id"])
	return out


static func load_fixes() -> Array:
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXES_PATH))
	return d["fixes"] if d is Dictionary and d.get("fixes") is Array else []


## Quirks (app/data/quirks.json): known behaviour of a shared part that controls
## must respect. has_quirk("hdr-switch-blocked", row).
static func quirks() -> Array:
	if not _quirks_loaded:
		_quirks_loaded = true
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(QUIRKS_PATH))
		_quirks = d["quirks"] if d is Dictionary and d.get("quirks") is Array else []
	return _quirks


static func quirk(id: String) -> Dictionary:
	for q in quirks():
		if q is Dictionary and str(q.get("id", "")) == id:
			return q
	return {}


static func has_quirk(id: String, row: Dictionary) -> bool:
	var q := quirk(id)
	return not q.is_empty() and not row.is_empty() and matches(q.get("applies"), row)


## The quirks that hold on this row.
static func quirks_for(row: Dictionary) -> Array:
	return quirks().filter(func(q): return q is Dictionary and matches(q.get("applies"), row))


## Problems in one row's traits ([] = fine): the same checks as traits.py.
static func trait_problems(row: Dictionary) -> Array:
	var id := str(row.get("id", "?"))
	var t: Variant = row.get("traits")
	if not t is Dictionary:
		return ["%s: missing traits" % id]
	var p: Array = []
	for k in t:
		if not k in TRAIT_KEYS and not k in ["sources", "unverified"]:
			p.append("%s: unknown trait %s" % [id, k])
	for k in TRAIT_KEYS:
		if not t.has(k):
			p.append("%s: traits.%s missing" % [id, k])
			continue
		var v: Variant = t[k]
		if v == null:
			continue
		if k == "panel":
			if not v is Dictionary or str(v.get("id", "")) == "":
				p.append("%s: traits.panel needs an id" % id)
		elif k in ["soc", "gpu_arch", "gpu_driver", "ec", "wifi", "audio"]:
			if not v is Array or v.is_empty():
				p.append("%s: traits.%s must be a non-empty list or null" % [id, k])
			else:
				for x in v:
					if not x is String or x != x.to_lower() or " " in x or x == "":
						p.append("%s: traits.%s value %s must be a lower-case id" % [id, k, x])
		elif not v is String or v != v.to_lower() or " " in v or v == "":
			p.append("%s: traits.%s must be a lower-case id" % [id, k])
	if not t.get("sources") is Array or (t["sources"] as Array).is_empty():
		p.append("%s: traits.sources needs a source" % id)
	for u in t.get("unverified", []):
		if not u in TRAIT_KEYS:
			p.append("%s: traits.unverified names %s" % [id, u])
	return p
