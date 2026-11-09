extends RefCounted
## The firmware index (firmware.json.gz, built nightly by gamedb/gamedb/firmware/build.py and
## published on the rolling "firmware" release) and everything that compares it with what this
## handheld runs. Pure static functions: Updates calls them on its worker, tests feed fixtures.
##
## Hub items (one list for the Updates page, all kinds):
##   {"id", "section": "firmware" | "drivers", "kind": "bios" | "ec" | "controller" | "touch" |
##    "firmware" | "fwupd" | "kernel" | "mesa" | ..., "name", "current", "latest",
##    "status": "update" | "current" | "unknown" | "info", "severity": "important" | "recommended" | "info",
##    "how": "auto" | "guided" | "link", "flash": "<method>", "notes", "notes_url", "download_page",
##    "download_url", "sha256", "date", "source": "fwupd" | "index" | "local" | "os"}
## "how": auto = GameCove installs it (fwupd / OS update), guided = step-by-step instructions
## (and maybe a prepared USB drive), link = only the maker's page.

const URL := "https://github.com/IHulkSmashI/GameCove/releases/download/firmware/firmware.json.gz"
const MAX_UNPACKED := 8 * 1024 * 1024
const MAX_AGE_S := 7 * 24 * 3600
const DMI := "/sys/class/dmi/id/"

## Maker flash method -> how GameCove can help.
const HOW := {
	"ez-flash": "guided", "msi-usb": "guided", "steamos": "guided", "capsule": "guided",
	"windows": "link", "link": "link", "fwupd": "auto",
}


## The index from gzip bytes, or {} when they aren't a schema-1 index.
static func parse_gz(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 18 or bytes[0] != 0x1f or bytes[1] != 0x8b:
		return {}
	var raw := bytes.decompress_dynamic(MAX_UNPACKED, FileAccess.COMPRESSION_GZIP)
	if raw.is_empty():
		return {}
	var j := JSON.new()
	if j.parse(raw.get_string_from_utf8()) != OK or not j.data is Dictionary:
		return {}
	var d: Dictionary = j.data
	return d if int(d.get("schema", 0)) == 1 and d.get("devices") is Dictionary else {}


## The hex digest from a "<sha256>  firmware.json.gz" line ("" when there is none).
static func sha_from_text(text: String) -> String:
	var re := RegEx.create_from_string("\\b([0-9a-fA-F]{64})\\b")
	var m := re.search(text)
	return m.get_string(1).to_lower() if m else ""


static func is_stale(modified_unix: int, now_unix: int) -> bool:
	return modified_unix <= 0 or now_unix - modified_unix >= MAX_AGE_S


## Traits a devices.json row shares with its siblings. Uses the row's own "traits" when it has
## them (soc, wifi, controller, platform, ...; nulls dropped) and fills the rest from long-standing fields, so
## shared firmware ("every Steam Deck", "every RC73 board") matches before and after that field.
static func traits_of(row: Dictionary) -> Dictionary:
	var t := {}
	if row.get("traits") is Dictionary:
		t = (row["traits"] as Dictionary).duplicate(true)
	# a trait devices.json leaves null is unknown, not a value
	for k in t.keys():
		if t[k] == null or (t[k] is Array and (t[k] as Array).is_empty()):
			t.erase(k)
	# "platform" is a shared body / board group (traits.platform) and only comes from traits: the CPU
	# vendor is far broader ("every AMD handheld") and goes under its own key (traits review)
	var fill := {"maker": row.get("maker", ""), "family": row.get("family", ""), "cpu_vendor": row.get("cpu_vendor", ""),
		"soc": row.get("chip", ""), "controller": row.get("buttons", ""), "gpu": row.get("gpu_family", "")}
	for k in fill:
		if not t.has(k) and str(fill[k]) != "":
			t[k] = str(fill[k])
	return t


## True when every key of `want` is in `have` with the same value (either side may list values).
static func traits_match(want: Dictionary, have: Dictionary) -> bool:
	if want.is_empty():
		return false
	for k in want:
		if not have.has(k):
			return false
		var a: Array = want[k] if want[k] is Array else [want[k]]
		var b: Array = have[k] if have[k] is Array else [have[k]]
		if not a.any(func(x): return b.any(func(y): return str(x).to_lower() == str(y).to_lower())):
			return false
	return true


## The index entries for this row: its own, plus shared ones its traits match.
## {"entry": the device entry or {}, "items": Array}
static func entries_for(index: Dictionary, row: Dictionary) -> Dictionary:
	var devs: Dictionary = index.get("devices", {}) if index.get("devices") is Dictionary else {}
	var entry: Dictionary = devs.get(str(row.get("id", "")), {}) if devs.get(str(row.get("id", ""))) is Dictionary else {}
	var items: Array = (entry.get("items", []) as Array).duplicate(true) if entry.get("items") is Array else []
	var traits := traits_of(row)
	for s in index.get("shared", []) if index.get("shared") is Array else []:
		if s is Dictionary and s.get("traits") is Dictionary and traits_match(s["traits"], traits) and s.get("items") is Array:
			for it in s["items"]:
				if it is Dictionary and not items.any(func(x): return x.get("kind") == it.get("kind") and x.get("name") == it.get("name")):
					items.append(it.duplicate(true))
	return {"entry": entry, "items": items}


## What the firmware reports about itself: DMI BIOS version/date and the EC release.
static func read_installed(root := "") -> Dictionary:
	var out := {}
	for k in ["bios_version", "bios_date", "bios_release", "ec_firmware_release", "board_name", "board_vendor", "product_name"]:
		out[k] = _read(root + DMI + k)
	return out


static func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text().strip_edges() if f != null else ""


## The part of a raw version string that the maker's listing shows.
##   asus  "RC71L.343" -> "343"     msi "E1T91IMS.10E" stays (the board is part of it)
static func display_version(scheme: String, raw: String) -> String:
	raw = raw.strip_edges()
	if scheme == "asus" and raw.contains("."):
		return raw.get_slice(".", raw.get_slice_count(".") - 1)
	return raw


static func _digits(s: String) -> Array:
	var out: Array = []
	for m in RegEx.create_from_string("\\d+").search_all(s):
		out.append(int(m.get_string()))
	return out


static func _cmp_arrays(a: Array, b: Array) -> int:
	for i in max(a.size(), b.size()):
		var x: int = a[i] if i < a.size() else 0
		var y: int = b[i] if i < b.size() else 0
		if x != y:
			return -1 if x < y else 1
	return 0


## -1 when `current` is older than `latest`, 0 same, 1 newer, -2 can't tell (different board,
## unreadable). Each maker counts differently:
##   asus      "343" (from "RC71L.343"); asus-mcu "V321"
##   msi       "E1T91IMS.10E": board before the dot must match, revision is hex
##   lenovo    "N3CN40WW": the 4-letter family must match, then the number
##   valve     "F7A0131" / "F7G0014T20": prefix must match, then the 4 digits
##   hex-ts    8-digit hex build timestamps
##   natural   anything else: dotted numbers
static func compare(scheme: String, current: String, latest: String) -> int:
	current = display_version(scheme, current)
	latest = display_version(scheme, latest)
	if current == "" or latest == "":
		return -2
	if current.to_upper() == latest.to_upper():
		return 0
	match scheme:
		"msi":
			var cb := current.get_slice(".", 0).to_upper()
			var lb := latest.get_slice(".", 0).to_upper()
			var cr := current.get_slice(".", 1).to_upper()
			var lr := latest.get_slice(".", 1).to_upper()
			if cb != lb or not cr.is_valid_hex_number() or not lr.is_valid_hex_number():
				return -2
			return signi(cr.hex_to_int() - lr.hex_to_int())
		"lenovo":
			if current.length() < 6 or latest.length() < 6 or current.substr(0, 4).to_upper() != latest.substr(0, 4).to_upper():
				return -2
			return _cmp_arrays(_digits(current.substr(4)), _digits(latest.substr(4)))
		"valve":
			if current.substr(0, 3).to_upper() != latest.substr(0, 3).to_upper():
				return -2
			return _cmp_arrays(_digits(current.substr(3, 4)), _digits(latest.substr(3, 4)))
		"hex-ts":
			if not current.is_valid_hex_number() or not latest.is_valid_hex_number():
				return -2
			return signi(current.hex_to_int() - latest.hex_to_int())
	var a := _digits(current)
	var b := _digits(latest)
	if a.is_empty() or b.is_empty():
		return -2
	return _cmp_arrays(a, b)


## Steam Deck: the BIOS this OS image would install, read from its own jupiter-biosupdate
## (BIOS_VERSION_MAP[running]["default"]). "" when the script or the running BIOS isn't listed.
static func deck_bios_target(script: String, running: String) -> String:
	var re := RegEx.create_from_string("BIOS_VERSION_MAP='(\\{[\\s\\S]*?\\})'")
	var m := re.search(script)
	if m == null:
		return ""
	var j := JSON.new()
	if j.parse(m.get_string(1)) != OK or not j.data is Dictionary:
		return ""
	var e: Variant = (j.data as Dictionary).get(running.strip_edges())
	return str(e.get("default", "")) if e is Dictionary and e.get("default") != null else ""


## Hub items for this row from the index and what the hardware reports.
## fw_devices: fwupd devices from `fwupdmgr get-devices --json` (Parse.fwupd_devices), used to read
## the running controller/MCU version when fwupd sees that part.
static func firmware_items(index: Dictionary, row: Dictionary, installed: Dictionary, fw_devices: Array = []) -> Array:
	var got := entries_for(index, row)
	var entry: Dictionary = got["entry"]
	var out: Array = []
	for it in got["items"]:
		var kind := str(it.get("kind", "firmware"))
		var scheme := str(it.get("scheme", "natural"))
		var latest := str(it.get("version", ""))
		var cur := ""
		match kind:
			"bios":
				cur = str(installed.get("bios_version", ""))
			"ec":
				cur = str(installed.get("ec_firmware_release", ""))
			_:
				var want := str(it.get("match_name", ""))
				if want != "":
					for d in fw_devices:
						if str(d.get("name", "")).to_lower().contains(want.to_lower()):
							cur = str(d.get("current", ""))
		if it.has("board") and cur != "" and cur.get_slice(".", 0).to_upper() != str(it["board"]).to_upper():
			continue  # another board's BIOS in the same listing
		var c := compare(scheme, cur, latest)
		var flash := str(it.get("flash", "link"))
		out.append({
			"id": "index:%s:%s" % [kind, str(it.get("name", kind)).to_lower().replace(" ", "_")],
			"section": "firmware", "kind": kind, "name": str(it.get("name", kind)),
			"current": display_version(scheme, cur), "latest": latest,
			"status": "unknown" if latest == "" or c == -2 else ("update" if c < 0 else "current"),
			"severity": str(it.get("severity", "recommended")) if c < 0 else "info",
			"how": HOW.get(flash, "link"), "flash": flash,
			"notes": str(it.get("notes", "")), "notes_url": str(it.get("notes_url", entry.get("support_url", ""))),
			"download_page": str(it.get("download_page", entry.get("support_url", ""))),
			"download_url": str(it.get("download_url", "")), "sha256": str(it.get("sha256", "")),
			"date": str(it.get("date", "")), "source": "index", "stale": bool(entry.get("stale", false)),
		})
	return out


## A hub item for one fwupd device (from get-devices, merged with get-updates' release).
static func fwupd_item(dev: Dictionary) -> Dictionary:
	var latest := str(dev.get("version", ""))
	var has_update := latest != "" and latest != str(dev.get("current", ""))
	return {
		"id": "fwupd:" + str(dev.get("id", "")), "section": "firmware", "kind": "fwupd",
		"name": str(dev.get("name", "")), "current": str(dev.get("current", "")), "latest": latest if has_update else str(dev.get("current", "")),
		"status": "update" if has_update else "current", "severity": "recommended" if has_update else "info",
		"how": ("auto" if bool(dev.get("trusted", true)) else "guided") if has_update else "auto", "flash": "fwupd",
		"notes": str(dev.get("notes", dev.get("summary", ""))), "notes_url": str(dev.get("details_url", "")),
		"download_page": "", "download_url": "", "sha256": "", "date": "", "source": "fwupd",
		"needs_reboot": bool(dev.get("needs_reboot", false)), "fwupd_id": str(dev.get("id", "")),
	}
