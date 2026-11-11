extends Node
## Knows which device we're on (a handheld, a Steam Machine, any PC by the TV)
## and reads live battery and power numbers.
## Read-only: nothing here writes to the system.
##
## Detection: the DMI ids in /sys/class/dmi/id pick the best row of
## data/devices.json (a "specific" row beats a "family" row). On hardware no row
## matches, a generic row is built from the CPU (/proc/cpuinfo) and GPU
## (/sys/class/drm) so TDP limits and the upscaler choice stay sane; with no
## battery in /sys/class/power_supply that row is a "desktop" (mini PC, HTPC,
## tower), which gets no handheld power limits at all.
## docs/DEVICES.md describes the table; docs/CONTRACTS.md the info() shape.

signal info_updated(info: Dictionary)

const Buttons := preload("res://scripts/device/buttons.gd")
const Traits := preload("res://scripts/device/traits.gd")
const ExecSafe := preload("res://scripts/system/exec_safe.gd")
const OsInfo := preload("res://scripts/system/os_info.gd")
const Sources := preload("res://scripts/perf/sources.gd")

const DEVICE_TABLE := "res://data/devices.json"
const DMI := "/sys/class/dmi/id/"
const POWER_SUPPLY := "/sys/class/power_supply/"
const ART_ROOT := "res://assets/devices/art/"
## Every device drawing uses the same scale: 1 mm of the real handheld = this many
## SVG units, so texture sizes compare truthfully (docs/DEVICES.md, Drawings).
const UNITS_PER_MM := 1.6
const DMI_KEYS: Array[String] = ["sys_vendor", "product_name", "board_name", "board_vendor", "product_family"]
const TIER_RANK := {"specific": 2, "family": 1, "generic": 0}
## A row's "form": a handheld (the default: own screen, battery, built-in
## controls), a console (a known box for the TV, e.g. the Steam Machine) or a
## desktop (an unknown PC with no battery).
const FORMS: Array[String] = ["handheld", "console", "desktop"]

var board_name := ""
var product_name := ""
var sys_vendor := ""
var board_vendor := ""
var product_family := ""
var cpu_model := ""
## {"vendor": "amd|intel|nvidia|", "driver": "amdgpu|xe|i915|", "pci_id": "1002:15BF", "card": "card1"}
var gpu: Dictionary = {}
## The matched row from devices.json, or the generic row built for unknown hardware.
var profile: Dictionary = {}
## Filesystem prefix ("" on the real system, a fixture folder in tests).
var root := ""
var home := OS.get_environment("HOME")

var _slow: Dictionary = {}
var _slow_thread: Thread
var _has_battery := true
## Tests and the screenshot tools pin this (true / false) so results don't
## depend on the machine they run on; null = look.
static var assume_battery: Variant = null


func _ready() -> void:
	detect()
	if "--selftest" in OS.get_cmdline_user_args():
		for line in selftest_lines():
			print(line)
		get_tree().quit.call_deferred()


## `gamecove.x86_64 --headless -- --selftest` (used by gamecove-selftest): what
## detection picked, one "selftest.<key>=<value>" per line. No serials or names.
func selftest_lines() -> Array[String]:
	var t: Dictionary = profile.get("tdp", {})
	var out: Array[String] = []
	var rows := {
		"device.id": id(), "device.name": str(profile.get("name", "")), "device.support": str(profile.get("support", "")),
		"device.verified": str(profile.get("verified", false)).to_lower(), "device.tier": str(profile.get("tier", "")),
		"device.chip": str(profile.get("chip", "")), "device.gpu_family": str(profile.get("gpu_family", "")),
		"device.tdp": "%s/%s/%s" % [t.get("min", "?"), t.get("battery_max", "?"), t.get("plugged_max", "?")],
		"device.buttons": str(profile.get("buttons", "")), "device.gyro": str(profile.get("gyro", "")),
		"device.fixes": ",".join(PackedStringArray(Traits.auto_fixes(profile) if profile.get("traits") is Dictionary else profile.get("fixes", []))),
		"device.platform": str((profile.get("traits", {}) as Dictionary).get("platform", "")) if profile.get("traits") is Dictionary else "",
		"gpu.driver": str(gpu.get("driver", "")), "gpu.pci_id": str(gpu.get("pci_id", "")),
		"cpu.model": cpu_model,
	}
	for k in rows:
		out.append("selftest.%s=%s" % [k, rows[k]])
	return out


func _exit_tree() -> void:
	if _slow_thread != null and _slow_thread.is_started():
		_slow_thread.wait_to_finish()


## Reads DMI, CPU and GPU under `root` and picks the row. Tests call this after
## setting `root`.
func detect() -> Dictionary:
	var dmi := read_dmi(root)
	sys_vendor = dmi["sys_vendor"]
	product_name = dmi["product_name"]
	board_name = dmi["board_name"]
	board_vendor = dmi["board_vendor"]
	product_family = dmi["product_family"]
	cpu_model = cpu_model_name(root)
	gpu = gpu_info(root)
	_has_battery = battery_path() != "" if assume_battery == null else bool(assume_battery)
	profile = for_os(resolve(load_doc(), dmi, cpu_model, gpu, _has_battery), OsInfo.detect(root))
	return profile


## The row as it holds on this OS: each `by_os` entry whose os (OsInfo family) and version range
## ("from" / "until", the VERSION_ID's major number, both inclusive) match replaces the keys in its
## "set" (the Legion Go's gyro is broken on Bazzite 44+, a Claw's lights are the kernel's there).
## The entry's "why" goes to the row's "os_notes". Rows without by_os come back unchanged.
static func for_os(row: Dictionary, os: Dictionary) -> Dictionary:
	var entries: Variant = row.get("by_os")
	if not entries is Array or (entries as Array).is_empty():
		return row
	var out := row.duplicate(true)
	var notes: Array = []
	var major := str(os.get("version", "")).get_slice(".", 0)
	for e in entries:
		if not e is Dictionary or str(e.get("os", "")) != str(os.get("family", "")):
			continue
		if not major.is_valid_int():
			continue
		var v := major.to_int()
		if e.has("from") and v < int(e["from"]):
			continue
		if e.has("until") and v > int(e["until"]):
			continue
		var set_: Dictionary = e.get("set", {}) if e.get("set") is Dictionary else {}
		for k in set_:
			out[k] = set_[k]
		notes.append(str(e.get("why", "")))
	if not notes.is_empty():
		out["os_notes"] = notes
	return out


# ---- identity -------------------------------------------------------------------

func id() -> String:
	return str(profile.get("id", "unknown"))


func display_name() -> String:
	if profile.has("name") and str(profile.get("tier", "")) != "generic":
		return profile["name"]
	if product_name != "":
		return product_name
	return str(profile.get("name", "Unknown device"))


func maker() -> String:
	return str(profile.get("maker", sys_vendor))


## "handheld" | "console" | "desktop" (FORMS).
func form() -> String:
	return form_of(profile)


static func form_of(row: Dictionary) -> String:
	var f := str(row.get("form", "handheld"))
	return f if f in FORMS else "handheld"


## False on a Steam Machine, a mini PC or any other box with no screen and
## battery of its own: the UI then says "device", shows no battery and lays
## out for a TV.
func is_handheld() -> bool:
	return form() == "handheld"


## A system battery (BAT*) was there at detection. Controller batteries
## (power supplies with scope "Device") don't count.
func has_battery() -> bool:
	return _has_battery


## What to call this device in a sentence: "handheld", or "device" for anything else.
func noun() -> String:
	return "handheld" if is_handheld() else "device"


func chip() -> String:
	return str(profile.get("chip", "Unknown"))


func support_level() -> String:
	return profile.get("support", "generic")


func is_verified() -> bool:
	return bool(profile.get("verified", false))


## What GameCove can drive on this device. Flags, so the UI can hide controls.
func features() -> Dictionary:
	return features_of(profile)


static func features_of(row: Dictionary) -> Dictionary:
	var bp := Buttons.profile(row)
	var rgb: Variant = row.get("rgb")
	return {
		"tdp": row.has("tdp"),
		"fan": row.get("fan") != null,
		"fan_control": row.get("fan_via") != null,
		"charge_limit": bool(row.get("charge_limit", false)),
		"gyro": str(row.get("gyro", "unknown")),
		"gyro_reason": str(row.get("gyro_reason", "")),
		"rgb": rgb is Dictionary,
		"rgb_via": str(rgb.get("via", "")) if rgb is Dictionary else "",
		"vrr": row.get("vrr_range") is Array,
		"buttons": bool(bp.get("verified", false)) and Buttons.profile_id(row) != "generic",
		"paddles": Buttons.paddles(row).size(),
		"trackpads": int(bp.get("trackpads", 0)),
		"glyphs": Buttons.glyph_set(row),
	}


## This device's special buttons ({id, label, capability, press, glyph, action}).
func buttons() -> Array:
	return Buttons.special_buttons(profile)


func glyph_set() -> String:
	return Buttons.glyph_set(profile)


## Glyph path for an action or button on this device (see buttons.gd glyph_for).
func glyph_for(name: String) -> String:
	return Buttons.glyph_for(name, profile)


## Front-view picture of this device's layout.
func picture() -> String:
	return art_path(str(profile.get("art", "generic")))


## Picture for a device id from devices.json; the generic handheld for anything else.
static func picture_for(device_id: String) -> String:
	for d in load_table():
		if d.get("id", "") == device_id:
			return art_path(str(d.get("art", "generic")))
	return art_path("generic")


## The shell record ("bodies" in devices.json) behind this device's drawing:
## {w_mm, h_mm, d_mm, screen_in, aspect, source, ...}; {} for the generic drawing.
static func body_for(device_id: String) -> Dictionary:
	var bodies: Dictionary = load_doc().get("bodies", {})
	for d in load_table():
		if d.get("id", "") == device_id:
			return bodies.get(str(d.get("art", "")), {})
	return {}


static func art_path(art: String) -> String:
	var p := ART_ROOT + art + ".svg"
	if art == "" or not ResourceLoader.exists(p):
		return ART_ROOT + "generic.svg"
	return p


# ---- table ----------------------------------------------------------------------

static func read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return read_all(f).strip_edges()


## Reads an open file to its real end. sysfs files report a size of 4096 and
## /proc files a size of 0, so get_as_text() (which trusts the size) returns ""
## for both; reading in chunks until a short read works for every kind of file.
static func read_all(f: FileAccess) -> String:
	var buf := PackedByteArray()
	while true:
		var chunk := f.get_buffer(65536)
		if chunk.is_empty():
			break
		buf.append_array(chunk)
		if chunk.size() < 65536 or buf.size() > 64 * 1024 * 1024:
			break
	return buf.get_string_from_utf8()


static func load_doc() -> Dictionary:
	var raw := read_text(DEVICE_TABLE)
	if raw == "":
		return {}
	var parsed: Variant = JSON.parse_string(raw)
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


static func load_table() -> Array:
	return load_doc().get("devices", [])


static func read_dmi(prefix := "") -> Dictionary:
	var out := {}
	for k in DMI_KEYS:
		out[k] = read_text(prefix + DMI + k)
	return out


## How well `row` matches `dmi`; -1 = no match. Every key of a match object must
## match one of its glob patterns (case-insensitive). Keys missing from `dmi`
## are skipped, but at least one key must be compared. Higher = more specific:
## tier first, then the number of keys compared, then exact (wildcard-free) hits.
static func match_score(row: Dictionary, dmi: Dictionary) -> int:
	var m: Variant = row.get("match", {})
	var alternatives: Array = m if m is Array else [m]
	var best := -1
	for alt in alternatives:
		if not alt is Dictionary:
			continue
		var compared := 0
		var exact := 0
		var ok := true
		for key in alt:
			if not dmi.has(key):
				continue
			var value := str(dmi[key])
			var hit := ""
			for pat in alt[key]:
				if value != "" and value.matchn(str(pat)):
					hit = str(pat)
					break
			if hit == "":
				ok = false
				break
			compared += 1
			if not ("*" in hit or "?" in hit):
				exact += 1
		if ok and compared > 0:
			var rank: int = TIER_RANK.get(str(row.get("tier", "specific")), 2)
			best = maxi(best, rank * 1000 + compared * 10 + exact)
	return best


## All rows that match, best first.
static func matching_rows(devices: Array, dmi: Dictionary) -> Array:
	var scored := []
	for d in devices:
		if d is Dictionary:
			var s := match_score(d, dmi)
			if s >= 0:
				scored.append([s, d])
	scored.sort_custom(func(a, b): return a[0] > b[0])
	return scored.map(func(x): return x[1])


## The best row for these DMI ids, or {}.
static func match_dmi(devices: Array, dmi: Dictionary) -> Dictionary:
	var rows := matching_rows(devices, dmi)
	return rows[0] if not rows.is_empty() else {}


## Older entry point: board name and product name only.
static func match_device(devices: Array, board: String, product: String) -> Dictionary:
	return match_dmi(devices, {"board_name": board, "product_name": product})


const SUPPORT_LEVELS := ["full", "partial", "beta", "generic"]
const GPU_FAMILIES := ["", "amd-vega", "amd-rdna2", "amd-rdna3", "intel-xe-lpg", "intel-xe2", "intel-xe3"]
const GPU_ARCHS := ["unknown", "Vega", "RDNA2", "RDNA3", "RDNA3.5", "Xe-LPG", "Xe2", "Xe3"]
const GYRO_STATES := ["yes", "fix", "no", "none", "unknown"]
## devices.json rgb.via: who drives the lights (texts_device.gd LED_BY names each).
const RGB_VIA := ["inputplumber", "hhd", "ayaneo-ec", "oxp-ec", "kernel", "steam"]
## by_os may only change what an OS changes about a handheld, never its identity or limits.
const BY_OS_KEYS := ["gyro", "gyro_reason", "rgb"]
const TDP_BACKENDS := ["steamos-manager", "powerstation"]
const TDP_KEYS := ["min", "battery_max", "plugged_max", "boost_max", "default", "source",
	"sppt_max", "fppt_max", "sppt_ratio", "fppt_ratio", "sppt_over", "fppt_over"]
const REQUIRED := ["id", "name", "maker", "tier", "match", "chip", "gpu", "gpu_family", "gpu_arch", "xmx",
	"panel_hz", "tdp", "fan", "charge_limit", "gyro", "buttons", "glyphs", "art", "fixes", "support", "verified", "unverified"]


## Problems with one devices.json row ([] = fine). Used by the tests and for
## rows people send in. Profile and art names are checked by the tests.
static func row_problems(row: Dictionary) -> Array:
	var p := []
	var id := str(row.get("id", "?"))
	for k in REQUIRED:
		if not row.has(k):
			p.append("%s: missing %s" % [id, k])
	if not p.is_empty():
		return p
	if not id.is_valid_identifier() and not id.replace("-", "_").is_valid_identifier():
		p.append("%s: id must be lower-case words joined by '-'" % id)
	if not str(row["tier"]) in TIER_RANK:
		p.append("%s: tier %s" % [id, row["tier"]])
	var m: Variant = row["match"]
	var alts: Array = m if m is Array else [m]
	if alts.is_empty() and str(row["tier"]) != "generic":
		p.append("%s: empty match" % id)
	for alt in alts:
		if not alt is Dictionary or alt.is_empty():
			p.append("%s: match entries must be non-empty objects" % id)
			continue
		for k in alt:
			if not k in DMI_KEYS:
				p.append("%s: unknown match key %s" % [id, k])
			elif not alt[k] is Array or alt[k].is_empty():
				p.append("%s: match.%s must be a non-empty list" % [id, k])
		if str(row["tier"]) == "specific":
			var has_exact := false
			for k in alt:
				for pat in alt[k]:
					if not ("*" in str(pat) or "?" in str(pat)):
						has_exact = true
			if not has_exact:
				p.append("%s: a specific row needs at least one exact (wildcard-free) DMI value" % id)
	if row.has("form") and not str(row["form"]) in FORMS:
		p.append("%s: form %s" % [id, row["form"]])
	if form_of(row) != "handheld" and (bool(row["charge_limit"]) or row.get("panel") != null or not (row.get("tdp_backends", [""]) as Array).is_empty()):
		p.append("%s: a %s has no panel, charge limit or handheld TDP backends" % [id, form_of(row)])
	if not str(row["support"]) in SUPPORT_LEVELS:
		p.append("%s: support %s" % [id, row["support"]])
	if row["support"] == "full" and not bool(row["verified"]):
		p.append("%s: full support needs verified values" % id)
	if bool(row["verified"]) != (row["unverified"] as Array).is_empty():
		p.append("%s: verified must be true exactly when unverified is empty" % id)
	if not str(row["gpu_family"]) in GPU_FAMILIES:
		p.append("%s: gpu_family %s" % [id, row["gpu_family"]])
	if not str(row["gpu_arch"]) in GPU_ARCHS:
		p.append("%s: gpu_arch %s" % [id, row["gpu_arch"]])
	if bool(row["xmx"]) and not str(row["gpu_family"]).begins_with("intel"):
		p.append("%s: xmx is Intel only" % id)
	if not str(row["gyro"]) in GYRO_STATES:
		p.append("%s: gyro %s" % [id, row["gyro"]])
	var t: Variant = row["tdp"]
	if not t is Dictionary or not (t.has("min") and t.has("battery_max") and t.has("plugged_max")):
		p.append("%s: tdp needs min, battery_max, plugged_max" % id)
	else:
		var lo := float(t["min"])
		var bmax := float(t["battery_max"])
		var pmax := float(t["plugged_max"])
		if not (lo >= 2.0 and lo < bmax and bmax <= pmax and pmax <= 150.0):
			p.append("%s: tdp must be 2 <= min < battery_max <= plugged_max <= 150" % id)
		if t.has("boost_max") and float(t["boost_max"]) < pmax:
			p.append("%s: boost_max below plugged_max" % id)
		# the maker's limits for this exact model, and where they come from (item 9: stay with the maker)
		if str(t.get("source", "")).strip_edges().length() < 12:
			p.append("%s: tdp needs a source (where the maker's limits for this model come from)" % id)
		if t.has("default") and (float(t["default"]) < lo or float(t["default"]) > pmax):
			p.append("%s: tdp default outside min..plugged_max" % id)
		for k in t:
			if not k in TDP_KEYS:
				p.append("%s: unknown tdp key %s" % [id, k])
		var prof: Dictionary = row.get("profiles", {})
		var last := 0.0
		for name in ["battery", "balanced", "performance"]:
			if prof.has(name):
				var w := float(prof[name])
				if w < lo or w > bmax:
					p.append("%s: profile %s outside min..battery_max" % [id, name])
				if w < last:
					p.append("%s: profiles must rise battery <= balanced <= performance" % id)
				last = w
	if str(row.get("cpu_vendor", "")) == "intel" and str(row["tier"]) == "specific" and float(row.get("pl2_offset_w", -1)) != 2.0:
		p.append("%s: Intel rows run PL2 = PL1 + 2 W (pl2_offset_w 2)" % id)
	if row.has("pl2_offset_w") and (float(row["pl2_offset_w"]) < 0.0 or float(row["pl2_offset_w"]) > 20.0):
		p.append("%s: pl2_offset_w out of range" % id)
	for b in row.get("tdp_backends", []):
		if not b in TDP_BACKENDS:
			p.append("%s: unknown tdp backend %s" % [id, b])
	var hz: Variant = row["panel_hz"]
	if hz is Array and hz.is_empty() and (str(row["tier"]) == "generic" or form_of(row) != "handheld"):
		hz = [30, 360]  # unknown panel on unknown hardware, or no panel at all: the TV decides
	if not hz is Array or hz.size() != 2 or float(hz[0]) < 30.0 or float(hz[0]) > float(hz[1]) or float(hz[1]) > 360.0:
		p.append("%s: panel_hz must be [min, max] Hz, 30..360" % id)
	var vrr: Variant = row.get("vrr_range")
	if vrr != null:
		if not vrr is Array or vrr.size() != 2 or float(vrr[0]) >= float(vrr[1]) or float(vrr[1]) > float(hz[1]) + 0.5:
			p.append("%s: vrr_range must be [lo, hi] inside the panel's range" % id)
	var panel: Variant = row.get("panel")
	if panel != null:
		if not panel is Dictionary or float(panel.get("size_in", 0)) < 3.0 or float(panel.get("size_in", 0)) > 18.0 \
				or not panel.get("resolution") is Array or panel["resolution"].size() != 2:
			p.append("%s: panel needs size_in (3..18) and resolution [w, h]" % id)
	p.append_array(_rgb_problems(id, row.get("rgb")))
	if row.has("gyro_reason") and str(row["gyro"]) == "yes":
		p.append("%s: gyro_reason only where the gyro doesn't simply work" % id)
	var by_os: Variant = row.get("by_os")
	if by_os != null:
		if not by_os is Array:
			p.append("%s: by_os must be a list" % id)
		else:
			for e in by_os:
				if not e is Dictionary or not str(e.get("os", "")) in ["bazzite", "steamos", "fedora-atomic"] \
						or not e.get("set") is Dictionary or str(e.get("why", "")) == "" or str(e.get("source", "")) == "":
					p.append("%s: by_os entries need os, set, why and source" % id)
					continue
				for k in e["set"]:
					if not k in BY_OS_KEYS:
						p.append("%s: by_os can't change %s" % [id, k])
				if e["set"].has("gyro") and not str(e["set"]["gyro"]) in GYRO_STATES:
					p.append("%s: by_os gyro %s" % [id, e["set"]["gyro"]])
				if e["set"].has("rgb"):
					p.append_array(_rgb_problems(id + " by_os", e["set"]["rgb"]))
	p.append_array(rumble_problems(id, row.get("rumble")))
	return p


static func _rgb_problems(id: String, rgb: Variant) -> Array:
	if rgb == null:
		return []
	if not rgb is Dictionary or not str(rgb.get("via", "")) in RGB_VIA:
		return ["%s: rgb must be null or {zones, via} with via one of %s" % [id, ", ".join(RGB_VIA)]]
	return []


const RUMBLE_STRENGTH := ["kernel", "hhd", "steam", "none"]
const RUMBLE_DRIVERS := ["hid-msi", "hid-lenovo-go"]
const RUMBLE_FIELDS := ["strength", "on_off", "test"]


## devices.json `rumble` (optional): {strength, driver, values, hhd, checked,
## unverified, source}; docs/DEVICES.md, Fields.
static func rumble_problems(id: String, r: Variant) -> Array:
	var p := []
	if r == null:
		return p
	if not r is Dictionary:
		return ["%s: rumble must be an object" % id]
	var how := str(r.get("strength", ""))
	if not how in RUMBLE_STRENGTH:
		p.append("%s: rumble.strength must be one of %s" % [id, ", ".join(RUMBLE_STRENGTH)])
	if (how == "kernel") != (r.get("driver") != null) or (how == "kernel" and not str(r.get("driver")) in RUMBLE_DRIVERS):
		p.append("%s: rumble.driver names the kernel driver (%s) exactly when strength is kernel" % [id, ", ".join(RUMBLE_DRIVERS)])
	if (how == "hhd") != (r.get("hhd") != null and str(r.get("hhd")) != ""):
		p.append("%s: rumble.hhd names the Handheld Daemon setting exactly when strength is hhd" % id)
	var vals: Variant = r.get("values")
	if how in ["kernel", "hhd"] and not (vals is Array and vals.size() >= 2):
		p.append("%s: rumble.values must be [lo, hi] or the driver's words" % id)
	for k in ["checked", "unverified"]:
		var l: Variant = r.get(k, [])
		if not l is Array or not (l as Array).all(func(x): return str(x) in RUMBLE_FIELDS):
			p.append("%s: rumble.%s lists %s" % [id, k, ", ".join(RUMBLE_FIELDS)])
	if str(r.get("source", "")) == "":
		p.append("%s: rumble.source says where it comes from" % id)
	if not (r.get("checked", []) as Array).is_empty() and str(r.get("checked_on", "")) == "":
		p.append("%s: rumble.checked_on names the system it was checked on" % id)
	return p


# ---- CPU / GPU fallback -------------------------------------------------------------

static func cpu_model_name(prefix := "") -> String:
	for line in read_text(prefix + "/proc/cpuinfo").split("\n"):
		if line.begins_with("model name"):
			return line.get_slice(":", 1).strip_edges()
	return ""


## {"cores": int, "threads": int} from /proc/cpuinfo.
static func cpu_counts(prefix := "") -> Dictionary:
	var threads := 0
	var cores := 0
	var core_ids := {}
	var phys := ""
	for line in read_text(prefix + "/proc/cpuinfo").split("\n"):
		if line.begins_with("processor"):
			threads += 1
		elif line.begins_with("physical id"):
			phys = line.get_slice(":", 1).strip_edges()
		elif line.begins_with("core id"):
			core_ids[phys + ":" + line.get_slice(":", 1).strip_edges()] = true
		elif line.begins_with("cpu cores") and cores == 0:
			cores = line.get_slice(":", 1).strip_edges().to_int()
	if cores == 0:
		cores = core_ids.size() if not core_ids.is_empty() else threads
	return {"cores": cores, "threads": threads}


## The integrated GPU: first DRM card with a PCI driver, preferring AMD/Intel.
static func gpu_info(prefix := "") -> Dictionary:
	var base := prefix + "/sys/class/drm/"
	var dir := DirAccess.open(base)
	var out := {"vendor": "", "driver": "", "pci_id": "", "card": ""}
	if dir == null:
		return out
	var names := Array(dir.get_directories()) + Array(dir.get_files())
	names.sort()
	for n in names:
		if not (n.begins_with("card") and n.substr(4).is_valid_int()):
			continue
		var driver := ""
		var pci := ""
		for line in read_text(base + n + "/device/uevent").split("\n"):
			if line.begins_with("DRIVER="):
				driver = line.substr(7)
			elif line.begins_with("PCI_ID="):
				pci = line.substr(7).to_upper()
		if driver == "":
			continue
		var vendor: String = {"1002": "amd", "8086": "intel", "10DE": "nvidia"}.get(pci.get_slice(":", 0), "")
		var cand := {"vendor": vendor, "driver": driver, "pci_id": pci, "card": n}
		if vendor in ["amd", "intel"]:
			return cand
		if out["card"] == "":
			out = cand
	return out


## The "cpus" entry whose pattern matches the CPU model name, or {}.
static func cpu_entry(cpus: Array, model: String) -> Dictionary:
	if model == "":
		return {}
	for c in cpus:
		for pat in c.get("match", []):
			if model.matchn(str(pat)):
				return c
	return {}


## "intel" / "amd" from the CPU's model name (/proc/cpuinfo), else the GPU's vendor, else "".
static func vendor_from(model: String, gpu_dev: Dictionary) -> String:
	var m := model.to_lower()
	if "intel" in m:
		return "intel"
	if "amd" in m:
		return "amd"
	var g := str(gpu_dev.get("vendor", ""))
	return g if g in ["intel", "amd"] else ""


## Limits for a handheld whose maker's limits we don't know (an unlisted model, or a family row
## filled from its CPU): never above SAFE_TDP for its CPU vendor, a chip with lower limits keeps
## its own. The source says so.
const SAFE_TDP := {"amd": {"min": 5, "battery_max": 20, "plugged_max": 25}, "intel": {"min": 8, "battery_max": 25, "plugged_max": 28}}

static func conservative_tdp(chip_tdp: Dictionary, vendor: String) -> Dictionary:
	var safe: Dictionary = SAFE_TDP["intel"] if vendor == "intel" else SAFE_TDP["amd"]
	var tdp: Dictionary = (chip_tdp if not chip_tdp.is_empty() else safe).duplicate()
	for k in ["battery_max", "plugged_max"]:
		tdp[k] = minf(float(tdp.get(k, safe[k])), float(safe[k]))
	tdp["min"] = minf(maxf(float(tdp.get("min", safe["min"])), float(safe["min"])), float(tdp["battery_max"]))
	if tdp.has("boost_max"):
		tdp["boost_max"] = minf(float(tdp["boost_max"]), float(tdp["plugged_max"]))
	tdp["source"] = "Not in the device table: conservative limits for an unknown %s handheld (GameCove's own, never above the chip's)" % ("Intel" if vendor == "intel" else "AMD")
	return tdp


## A row for hardware no specific row knows. Ranges are conservative.
## `battery` false = no system battery: a desktop (mini PC, HTPC, tower), not a
## handheld. No power service may set a TDP there (tdp_backends []): the
## handheld-sized limits below would choke a desktop chip.
static func fallback_row(dmi: Dictionary, model: String, gpu_dev: Dictionary, cpus: Array, battery := true) -> Dictionary:
	var c := cpu_entry(cpus, model)
	var vendor := str(c.get("cpu_vendor", ""))
	if vendor == "":
		vendor = vendor_from(model, gpu_dev)
	var family := str(c.get("gpu_family", ""))
	var arch := str(c.get("gpu_arch", "unknown"))
	if family == "" and str(gpu_dev.get("driver", "")) == "xe":
		family = "intel-xe2"  # the xe driver is the default from Lunar Lake on
		arch = "Xe2"
	# The chip table's range is what the chip can do in the biggest handheld that has it (a
	# Ryzen AI Max: 45/80 W); an unlisted handheld may be a small one, so never more than
	# these conservative limits (review L12). A chip with lower limits keeps its own.
	var tdp := conservative_tdp(c.get("tdp", {}) as Dictionary, vendor)
	var name := str(dmi.get("product_name", ""))
	var row := {
		"id": "unknown",
		"name": name if name != "" else "Unknown handheld",
		"maker": str(dmi.get("sys_vendor", "")),
		"family": "",
		"tier": "generic",
		"match": [],
		"chip": model if model != "" else "Unknown",
		"cpu_vendor": vendor,
		"gpu": str(c.get("chip", "")) if not c.is_empty() else "Unknown",
		"gpu_family": family,
		"gpu_arch": arch,
		"xmx": bool(c.get("xmx", false)),
		"panel": null, "panel_hz": [], "vrr_range": null,
		"tdp": tdp.duplicate(),
		"fan": null, "fan_via": null,
		"charge_limit": false, "charge_limit_via": null,
		"gyro": "unknown", "imu": null, "rgb": null,
		"buttons": "generic", "glyphs": "xbox", "art": "generic",
		"fixes": [], "quirks": ["Not in GameCove's device table yet. Power limits come from the chip."],
		"support": "generic", "verified": false, "unverified": ["all"], "sources": [],
	}
	if c.has("pl2_offset_w"):
		row["pl2_offset_w"] = c["pl2_offset_w"]
	if not battery:
		row["form"] = "desktop"
		row["name"] = name if name != "" else "Unknown PC"
		row["art"] = "generic-box"
		row["tdp_backends"] = []
		row["quirks"] = ["Not in GameCove's device table. No battery found, so we treat it as a PC by the TV: no battery settings and no power limits."]
	return row


## The row for this hardware: best DMI match, its chip details filled in from
## the CPU where the row leaves them open, else the generic fallback.
static func resolve(doc: Dictionary, dmi: Dictionary, model: String, gpu_dev: Dictionary, battery := true) -> Dictionary:
	var cpus: Array = doc.get("cpus", [])
	var row := match_dmi(doc.get("devices", []), dmi)
	if row.is_empty():
		return fallback_row(dmi, model, gpu_dev, cpus, battery)
	var c := cpu_entry(cpus, model)
	var open_chip := str(row.get("chip", "")) == "Unknown" or bool(row.get("chip_from_cpu", false))
	if c.is_empty() and open_chip and str(row.get("cpu_vendor", "")) == "":
		# a family row (review S5-2: unlisted Claws are Intel and AMD) with a CPU we don't list: the
		# vendor from the CPU itself, so Intel-only behaviour (thermald hold, ...) follows the hardware
		row = row.duplicate(true)
		row["cpu_vendor"] = vendor_from(model, gpu_dev)
		return row
	if c.is_empty() or not open_chip:
		return row
	row = row.duplicate(true)
	row["chip"] = model
	for k in ["cpu_vendor", "gpu_family", "gpu_arch", "xmx"]:
		row[k] = c[k]
	if str(row.get("gpu", "")) == "Unknown":
		row["gpu"] = c["chip"]
	if c.has("pl2_offset_w") and not row.has("pl2_offset_w"):
		row["pl2_offset_w"] = c["pl2_offset_w"]
	if str(row.get("tier", "")) == "family":
		# the chip table's range is the biggest handheld's with that chip: an unlisted model of this
		# family may be a small one, so the same conservative limits as an unknown handheld
		row["tdp"] = conservative_tdp(c["tdp"], str(row["cpu_vendor"]))
		row.erase("profiles")
	return row


# ---- battery ----------------------------------------------------------------------

## First battery found, e.g. BAT0 or BAT1. Empty string when there's none.
func battery_path() -> String:
	return battery_path_at(root)


## The system battery under `prefix`: BAT* first, else any supply of type
## "Battery" that isn't a gadget's (controllers and mice show up here with
## scope "Device": a wired DualSense on a Steam Machine is not its battery).
static func battery_path_at(prefix: String) -> String:
	var dir := DirAccess.open(prefix + POWER_SUPPLY)
	if dir == null:
		return ""
	var names := Array(dir.get_directories()) + Array(dir.get_files())
	names.sort()
	for name in names:
		if name.begins_with("BAT"):
			return prefix + POWER_SUPPLY + name + "/"
	for name in names:
		var base: String = prefix + POWER_SUPPLY + name + "/"
		if read_text(base + "type") == "Battery" and read_text(base + "scope") != "Device":
			return base
	return ""


## {"percent": int, "status": String, "watts": float}; missing values are -1 / "".
func battery() -> Dictionary:
	var out := {"percent": -1, "status": "", "watts": -1.0}
	var bat := battery_path()
	if bat == "":
		return out
	var cap := read_text(bat + "capacity")
	if cap.is_valid_int():
		out["percent"] = cap.to_int()
	out["status"] = read_text(bat + "status")
	var power_uw := read_text(bat + "power_now")
	if power_uw.is_valid_int():
		out["watts"] = Sources.scale_fix(power_uw.to_int() / 1_000_000.0)
	else:
		var cur := read_text(bat + "current_now")
		var volt := read_text(bat + "voltage_now")
		if cur.is_valid_int() and volt.is_valid_int():
			# the Claw 8 EX EC reports current_now 100x too large (perf/sources.gd scale_fix)
			out["watts"] = Sources.scale_fix(cur.to_int() * volt.to_int() / 1e12)
	return out


## Read helpers for the power layer. `root` is a filesystem prefix ("" on the
## real system, a fixture folder in tests).

## The hwmon folder whose "name" file is `hwmon_name` (e.g. "msi_wmi_platform"), or "".
static func find_hwmon(hwmon_name: String, root := "") -> String:
	var base := root + "/sys/class/hwmon/"
	var dir := DirAccess.open(base)
	if dir == null:
		return ""
	var names := Array(dir.get_directories()) + Array(dir.get_files())
	names.sort()
	for n in names:
		if read_text(base + n + "/name") == hwmon_name:
			return base + n + "/"
	return ""


## True when a charger is connected (a Mains or USB supply reports online=1).
static func ac_online(root := "") -> bool:
	var base := root + POWER_SUPPLY
	var dir := DirAccess.open(base)
	if dir == null:
		return false
	for n in Array(dir.get_directories()) + Array(dir.get_files()):
		var kind := read_text(base + n + "/type")
		if (kind == "Mains" or kind == "USB") and read_text(base + n + "/online") == "1":
			return true
	return false


## The battery's charge_control_end_threshold file, or "" when the kernel has none.
static func charge_threshold_path(root := "") -> String:
	var base := root + POWER_SUPPLY
	var dir := DirAccess.open(base)
	if dir == null:
		return ""
	var names := Array(dir.get_directories()) + Array(dir.get_files())
	names.sort()
	for n in names:
		var p: String = base + n + "/charge_control_end_threshold"
		if read_text(base + n + "/type") == "Battery" and FileAccess.file_exists(p):
			return p
	return ""


# ---- About this device ----------------------------------------------------------------

## Everything for an "About this device" panel, grouped. Cheap: only reads
## files under /sys, /proc and /etc. Slow parts (Steam, Proton, storage space,
## vulkaninfo) come from request_slow_info() and are merged in once known.
## Shape: docs/CONTRACTS.md, "Device info".
func info() -> Dictionary:
	var counts := cpu_counts(root)
	var hz: Array = profile.get("panel_hz", [])
	var panel: Variant = profile.get("panel")
	var mesa := _mesa_from_renderer()
	var out := {
		"device": {
			"id": id(),
			"name": display_name(),
			"maker": maker(),
			"model": product_name,
			"board": board_name,
			"vendor": sys_vendor,
			"family": product_family,
			"bios_version": read_text(root + DMI + "bios_version"),
			"bios_date": read_text(root + DMI + "bios_date"),
			"serial": "hidden",
			"picture": picture(),
		},
		"chip": {
			"cpu": cpu_model if cpu_model != "" else chip(),
			"cores": counts["cores"],
			"threads": counts["threads"],
			"gpu": str(profile.get("gpu", "Unknown")),
			"gpu_arch": str(profile.get("gpu_arch", "unknown")),
			"gpu_driver": str(gpu.get("driver", "")),
			"gpu_pci_id": str(gpu.get("pci_id", "")),
			"mesa": mesa,
			"kernel": read_text(root + "/proc/sys/kernel/osrelease"),
		},
		"memory": memory_info(root, str(gpu.get("card", ""))),
		"storage": storage_info(root),
		"screen": {
			"size_in": float(panel.get("size_in", 0.0)) if panel is Dictionary else 0.0,
			"resolution": panel.get("resolution", []) if panel is Dictionary else [],
			"type": str(panel.get("type", "")) if panel is Dictionary else "",
			"refresh_hz": hz,
			"vrr": profile.get("vrr_range") is Array,
			"vrr_range": profile.get("vrr_range") if profile.get("vrr_range") is Array else [],
		},
		"battery": battery_info(),
		"software": {
			"os": "", "os_version": "", "os_id": "",
			"gamecove_version": gamecove_version(),
			"steam_version": "",
			"proton": [],
			"slow_done": not _slow.is_empty(),
		},
		"support": {
			"level": support_level(),
			"verified": is_verified(),
			"unverified": profile.get("unverified", []),
			"features": features(),
			"fixes": profile.get("fixes", []),
			"quirks": profile.get("quirks", []),
			"sources": profile.get("sources", []),
			"buttons": Buttons.profile_id(profile),
			"glyphs": glyph_set(),
		},
	}
	var osr := os_release(root)
	out["software"]["os"] = osr.get("PRETTY_NAME", osr.get("NAME", ""))
	out["software"]["os_version"] = osr.get("VERSION_ID", osr.get("BUILD_ID", ""))
	out["software"]["os_id"] = osr.get("ID", "")
	if not _slow.is_empty():
		out["software"]["steam_version"] = _slow.get("steam_version", "")
		out["software"]["proton"] = _slow.get("proton", [])
		for k in ["internal", "sd_card"]:
			var free: Dictionary = _slow.get("free_gb", {})
			if free.has(k) and out["storage"][k] is Dictionary and not out["storage"][k].is_empty():
				out["storage"][k]["free_gb"] = free[k]
		if out["chip"]["mesa"] == "":
			out["chip"]["mesa"] = _slow.get("mesa", "")
		if _slow.get("vulkan_driver", "") != "":
			out["chip"]["vulkan_driver"] = _slow["vulkan_driver"]
	return out


static func gamecove_version() -> String:
	return AppVersion.text()


func _mesa_from_renderer() -> String:
	if DisplayServer.get_name() == "headless":
		return ""
	return mesa_from_text(RenderingServer.get_video_adapter_api_version())


## "Mesa 25.1.3" out of a GL_VERSION / driverInfo string, or "".
static func mesa_from_text(s: String) -> String:
	var i := s.find("Mesa")
	if i < 0:
		return ""
	var tail := s.substr(i).split(" ")
	return "Mesa " + tail[1] if tail.size() > 1 else "Mesa"


static func os_release(prefix := "") -> Dictionary:
	var raw := read_text(prefix + "/etc/os-release")
	if raw == "":
		raw = read_text(prefix + "/usr/lib/os-release")
	var out := {}
	for line in raw.split("\n"):
		var eq := line.find("=")
		if eq <= 0 or line.begins_with("#"):
			continue
		out[line.left(eq).strip_edges()] = line.substr(eq + 1).strip_edges().trim_prefix("\"").trim_suffix("\"")
	return out


## {"total_mb", "vram_mb", "gtt_mb"}; -1 when unknown.
static func memory_info(prefix := "", card := "") -> Dictionary:
	var out := {"total_mb": -1, "vram_mb": -1, "gtt_mb": -1}
	for line in read_text(prefix + "/proc/meminfo").split("\n"):
		if line.begins_with("MemTotal:"):
			out["total_mb"] = int(line.get_slice(":", 1).strip_edges().get_slice(" ", 0).to_int() / 1024)
	if card != "":
		var dev := prefix + "/sys/class/drm/" + card + "/device/"
		var vram := read_text(dev + "mem_info_vram_total")
		var gtt := read_text(dev + "mem_info_gtt_total")
		if vram.is_valid_int():
			out["vram_mb"] = int(vram.to_int() / 1048576)
		if gtt.is_valid_int():
			out["gtt_mb"] = int(gtt.to_int() / 1048576)
	return out


## {"internal": {name, model, size_gb}, "sd_card": {...}}; {} for a missing drive.
static func storage_info(prefix := "") -> Dictionary:
	var out := {"internal": {}, "sd_card": {}}
	var base := prefix + "/sys/block/"
	var dir := DirAccess.open(base)
	if dir == null:
		return out
	var names := Array(dir.get_directories()) + Array(dir.get_files())
	names.sort()
	for n in names:
		if n.begins_with("loop") or n.begins_with("zram") or n.begins_with("dm-") or n.begins_with("ram"):
			continue
		var sectors := read_text(base + n + "/size")
		if not sectors.is_valid_int() or sectors.to_int() == 0:
			continue
		var size_gb := snappedf(sectors.to_int() * 512.0 / 1e9, 0.1)
		if n.begins_with("mmcblk"):
			var kind := read_text(base + n + "/device/type")
			var e := {"name": n, "model": read_text(base + n + "/device/name"), "size_gb": size_gb}
			if kind == "SD" and out["sd_card"].is_empty():
				out["sd_card"] = e
			elif kind != "SD" and out["internal"].is_empty():
				out["internal"] = e
		elif (n.begins_with("nvme") or n.begins_with("sd")) and out["internal"].is_empty() \
				and read_text(base + n + "/removable") != "1":
			out["internal"] = {"name": n, "model": read_text(base + n + "/device/model"), "size_gb": size_gb}
	return out


## Battery details: health from design vs full capacity, cycles, charging.
func battery_info() -> Dictionary:
	var out := {
		"present": false, "percent": -1, "status": "", "charging": false,
		"design_wh": -1.0, "full_wh": -1.0, "health_pct": -1, "cycles": -1,
		"charge_limit_supported": bool(profile.get("charge_limit", false)) or charge_threshold_path(root) != "",
		"model": "", "manufacturer": "", "technology": "",
	}
	var bat := battery_path()
	if bat == "":
		return out
	var b := battery()
	out["present"] = true
	out["percent"] = b["percent"]
	out["status"] = b["status"]
	out["charging"] = b["status"] == "Charging"
	var design := _wh(bat, "design")
	var full := _wh(bat, "")
	out["design_wh"] = design
	out["full_wh"] = full
	if design > 0.0 and full > 0.0:
		out["health_pct"] = mini(100, int(roundf(full / design * 100.0)))
	var cycles := read_text(bat + "cycle_count")
	if cycles.is_valid_int():
		out["cycles"] = cycles.to_int()
	out["model"] = read_text(bat + "model_name")
	out["manufacturer"] = read_text(bat + "manufacturer")
	out["technology"] = read_text(bat + "technology")
	return out


## energy_full(_design) in Wh, or charge_full(_design) x voltage_min_design.
static func _wh(bat: String, which: String) -> float:
	var suffix := "_design" if which == "design" else ""
	var e := read_text(bat + "energy_full" + suffix)
	if e.is_valid_int():
		return snappedf(e.to_int() / 1e6, 0.1)
	var c := read_text(bat + "charge_full" + suffix)
	var v := read_text(bat + "voltage_min_design")
	if c.is_valid_int() and v.is_valid_int():
		return snappedf(c.to_int() * v.to_int() / 1e12, 0.1)
	return -1.0


# ---- slow info (off the main thread) -------------------------------------------------------

## Starts the slow lookups on a thread; info_updated(info()) fires when done.
## Does nothing if they're cached or already running.
func request_slow_info() -> void:
	if not _slow.is_empty() or (_slow_thread != null and _slow_thread.is_alive()):
		return
	if _slow_thread != null and _slow_thread.is_started():
		_slow_thread.wait_to_finish()
	_slow_thread = Thread.new()
	_slow_thread.start(_slow_worker)


## Two steps so the page isn't left waiting on vulkaninfo (a second or more on
## a cold start): Steam, Proton and free space first, then the Vulkan driver.
func _slow_worker() -> void:
	var s := slow_info(false)
	_finish_slow.call_deferred(s)
	if root == "" and FileAccess.file_exists("/usr/bin/vulkaninfo"):
		var v := vulkan_info()
		if not v.is_empty():
			_finish_vulkan.call_deferred(v)


func _finish_slow(s: Dictionary) -> void:
	_slow = s
	info_updated.emit(info())


func _finish_vulkan(v: Dictionary) -> void:
	if _slow.is_empty():
		return
	_slow["mesa"] = v.get("mesa", "")
	_slow["vulkan_driver"] = v.get("vulkan_driver", "")
	info_updated.emit(info())


## Mesa version and Vulkan driver name from `vulkaninfo --summary` (blocking).
static func vulkan_info() -> Dictionary:
	var r := ExecSafe.run("/usr/bin/vulkaninfo", PackedStringArray(["--summary"]), true)
	if r["code"] != 0 or str(r["out"]) == "":
		return {}
	var v := parse_vulkaninfo(str(r["out"]))
	return {"mesa": mesa_from_text(v.get("driver_info", "")), "vulkan_driver": v.get("driver_name", "")}


## Steam client version, Proton builds, free space, and (if `run_vulkaninfo` and
## the tool exists) the Vulkan driver. Synchronous; request_slow_info() runs it
## on a thread.
func slow_info(run_vulkaninfo := false) -> Dictionary:
	var out := {"steam_version": steam_version(home), "proton": proton_versions(home), "free_gb": {}, "mesa": "", "vulkan_driver": ""}
	var free := {}
	var internal_free := _free_gb(root + "/home" if DirAccess.dir_exists_absolute(root + "/home") else root + "/")
	if internal_free >= 0.0:
		free["internal"] = internal_free
	for mount in [root + "/run/media", root + "/media"]:
		var d := DirAccess.open(mount)
		if d == null:
			continue
		for sub in d.get_directories():
			var p: String = mount + "/" + sub
			var inner := DirAccess.open(p)
			if inner != null and inner.get_directories().size() > 0 and not free.has("sd_card"):
				var g := _free_gb(p + "/" + inner.get_directories()[0])
				if g >= 0.0:
					free["sd_card"] = g
	out["free_gb"] = free
	if run_vulkaninfo and root == "" and FileAccess.file_exists("/usr/bin/vulkaninfo"):
		var v := vulkan_info()
		out["mesa"] = v.get("mesa", "")
		out["vulkan_driver"] = v.get("vulkan_driver", "")
	return out


static func _free_gb(path: String) -> float:
	var d := DirAccess.open(path)
	if d == null:
		return -1.0
	return snappedf(d.get_space_left() / 1e9, 0.1)


## driverName / driverInfo of the first GPU in `vulkaninfo --summary` output.
static func parse_vulkaninfo(text: String) -> Dictionary:
	var out := {}
	for line in text.split("\n"):
		var t := line.strip_edges()
		for key in ["driverName", "driverInfo", "deviceName"]:
			if t.begins_with(key) and t.contains("=") and not out.has(key):
				out[key] = t.get_slice("=", 1).strip_edges()
	return {"driver_name": out.get("driverName", ""), "driver_info": out.get("driverInfo", ""), "device_name": out.get("deviceName", "")}


## Steam client build from its package manifest ("" when Steam isn't installed).
static func steam_version(home_dir: String) -> String:
	for rel in ["/.local/share/Steam/package/steam_client_ubuntu12.manifest", "/.steam/steam/package/steam_client_ubuntu12.manifest"]:
		var raw := read_text(home_dir + rel)
		for line in raw.split("\n"):
			var parts := line.strip_edges().split("\"", false)
			# "version"		"1761234567"
			if parts.size() >= 3 and parts[0] == "version":
				return parts[2].strip_edges() if parts[1].strip_edges() == "" else parts[1].strip_edges()
	return ""


## Proton builds Steam can use: Valve's (steamapps/common/Proton*) and custom
## ones (compatibilitytools.d), sorted.
static func proton_versions(home_dir: String) -> Array:
	var out := []
	for base in ["/.local/share/Steam", "/.steam/steam"]:
		var common := DirAccess.open(home_dir + base + "/steamapps/common")
		if common != null:
			for n in common.get_directories():
				if n.begins_with("Proton") and not n in out:
					out.append(n)
		var custom := DirAccess.open(home_dir + base + "/compatibilitytools.d")
		if custom != null:
			for n in custom.get_directories():
				if not n in out:
					out.append(n)
		if not out.is_empty():
			break
	out.sort()
	return out
