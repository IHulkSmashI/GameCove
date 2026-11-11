extends RefCounted
## What GameCove is being shown on: the handheld's own panel, a desk monitor or
## a TV, and how big it is. ui_scale.gd turns that into the interface size.
##
## Read from the kernel's connector list (/sys/class/drm/card*-<connector>):
## `status` "connected" and `enabled` "enabled" mark the output in use, the
## first 128 bytes of `edid` carry its physical size (bytes 21 and 22, cm).
## gamescope draws on one output: an external one (HDMI, DisplayPort, USB-C)
## wins over the built-in panel when it is plugged in, as in Game Mode.
## A few tiny sysfs reads; main.gd asks at start, when the window's size
## changes and when GameCove comes back to the front. Nothing is polled.
##
## A box with no panel of its own (Steam Machine, mini PC, HTPC) with a screen
## that doesn't say its size counts as a TV: that is where such a box lives,
## and too-big text on a desk monitor is the kinder mistake ("Interface size"
## in Settings changes it).

const DRM := "/sys/class/drm"
const INTERNAL: Array[String] = ["eDP", "DSI", "LVDS"]
const EXTERNAL: Array[String] = ["HDMI-A", "HDMI-B", "DP", "DVI-D", "DVI-I", "DVI-A", "VGA", "USB"]
## Diagonals, inches: below MONITOR_MIN an external screen is a portable one
## (read like a handheld), from TV_MIN up it is a TV.
const MONITOR_MIN := 18.5
const TV_MIN := 35.0


## Connectors in use under `root` ("" = the real system):
## [{name, type, internal: bool, diagonal_in: float (0 = not said)}].
static func connectors(root := "") -> Array:
	var out := []
	var dir := DirAccess.open(root + DRM)
	if dir == null:
		return out
	var names := Array(dir.get_directories())
	names.sort()
	for n in names:
		var type := connector_type(str(n))
		if type == "":
			continue
		var base := root + DRM + "/" + str(n) + "/"
		if _read(base + "status") != "connected":
			continue
		# `enabled` is missing on some drivers: a connected output counts then
		var en := _read(base + "enabled")
		if en != "" and en != "enabled":
			continue
		out.append({"name": str(n), "type": type, "internal": type in INTERNAL,
			"diagonal_in": edid_diagonal_in(_read_bytes(base + "edid", 128))})
	return out


## "card1-HDMI-A-1" -> "HDMI-A"; "" for anything that isn't a connector
## (card1, renderD128, Writeback and Virtual outputs).
static func connector_type(name: String) -> String:
	var dash := name.find("-")
	if not name.begins_with("card") or dash < 0:
		return ""
	var rest := name.substr(dash + 1)
	var last := rest.rfind("-")
	if last <= 0 or not rest.substr(last + 1).is_valid_int():
		return ""
	var type := rest.left(last)
	return type if type in INTERNAL or type in EXTERNAL else ""


## The screen's diagonal from an EDID block (bytes 21 / 22: width / height in
## cm); 0 when the block is short, isn't an EDID or leaves the size out
## (projectors, some AV receivers and capture boxes do).
static func edid_diagonal_in(edid: PackedByteArray) -> float:
	if edid.size() < 23 or edid[0] != 0x00 or edid[1] != 0xFF or edid[7] != 0x00:
		return 0.0
	var w := float(edid[21])
	var h := float(edid[22])
	if w <= 0.0 or h <= 0.0:
		return 0.0
	return Vector2(w, h).length() / 2.54


## The screen in use: {kind: "handheld" | "monitor" | "tv" | "", diagonal_in,
## external: bool, connector: String}. `panel` is the device row's panel
## ({size_in, resolution} or null), `boxed` whether this device has no screen
## of its own (Device.is_handheld() == false).
static func current(root: String, panel: Variant, boxed: bool) -> Dictionary:
	return pick(connectors(root), panel, boxed)


static func pick(found: Array, panel: Variant, boxed: bool) -> Dictionary:
	var panel_in := float(panel.get("size_in", 0.0)) if panel is Dictionary else 0.0
	var ext := {}
	var internal := {}
	for c in found:
		if bool(c["internal"]):
			if internal.is_empty():
				internal = c
		elif ext.is_empty() or float(c["diagonal_in"]) > float(ext["diagonal_in"]):
			ext = c
	if not ext.is_empty():
		var d := float(ext["diagonal_in"])
		var kind := "tv"
		if d > 0.0 and d < MONITOR_MIN:
			kind = "handheld"
		elif d >= MONITOR_MIN and d < TV_MIN:
			kind = "monitor"
		return {"kind": kind, "diagonal_in": d, "external": true, "connector": str(ext["name"])}
	if boxed:
		return {"kind": "tv", "diagonal_in": 0.0, "external": true, "connector": ""}
	# the built-in panel: the device table's size first (EDIDs of handheld
	# panels are often wrong), else what the panel says when that is believable
	var d2 := panel_in
	if d2 <= 0.0 and not internal.is_empty():
		var e := float(internal["diagonal_in"])
		if e >= 4.0 and e <= 18.0:
			d2 = e
	if d2 > 0.0:
		return {"kind": "handheld", "diagonal_in": d2, "external": false, "connector": str(internal.get("name", ""))}
	return {"kind": "", "diagonal_in": 0.0, "external": false, "connector": str(internal.get("name", ""))}


static func _read(path: String) -> String:
	return _read_bytes(path, 64).get_string_from_utf8().strip_edges()


## Up to `limit` bytes of a sysfs file (they report a size of 4096 or 0, so read
## until a short read, like Device.read_all).
static func _read_bytes(path: String, limit: int) -> PackedByteArray:
	if not FileAccess.file_exists(path):
		return PackedByteArray()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	return f.get_buffer(limit)
