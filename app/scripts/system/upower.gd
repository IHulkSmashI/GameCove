extends RefCounted
## Controller batteries from UPower (org.freedesktop.UPower on the system bus,
## through busctl): wired and 2.4 GHz pads whose kernel driver reports a
## battery (hid-playstation, hid-nintendo, xpad's wireless receivers, Steam
## Controller...), and Bluetooth pads, which BlueZ hands to UPower too. The top
## bar shows them as a small chip.
##
## Read when something changes, never on a timer: when GameCove comes to the
## front, when the quick menu opens, when Godot sees a controller connect or
## disconnect, and at most every READ_EVERY_S on the live refresh that already
## runs while GameCove is in front (main.gd). Behind a game nothing reads.
##
## Blocks (busctl): call from a worker thread.

const Busctl := preload("res://scripts/device/busctl.gd")

const SERVICE := "org.freedesktop.UPower"
const DEVICE := "org.freedesktop.UPower.Device"
## UPower's UpDeviceKind for game controllers (up-types.h UP_DEVICE_KIND_GAMING_INPUT).
const GAMING_INPUT := 12
## UpDeviceState: 1 charging, 4 fully charged.
const CHARGING_STATES := [1, 4]
## UpDeviceLevel for pads that only report a coarse level (hid-nintendo, some
## receivers): UpDeviceLevel 3 low, 4 critical, 5 normal, 6 high, 7 full, as a
## rough percentage. 1 (none) means the pad reports a real percentage.
const LEVELS := {3: 10, 4: 5, 5: 55, 6: 80, 7: 100}
const READ_EVERY_S := 120


static func _v(x: Variant) -> Variant:
	return x.get("data") if x is Dictionary and x.has("type") and x.has("data") else x


## Every game controller UPower knows: [{"path", "name", "percent" (-1 unknown),
## "charging"}], by name. [] without UPower.
static func pads(runner: RefCounted) -> Array:
	if runner == null:
		return []
	var bus: RefCounted = Busctl.new(runner, "--system")
	var paths: Variant = bus.call_method(SERVICE, "/org/freedesktop/UPower", SERVICE, "EnumerateDevices")
	var out: Array = []
	if not paths is Array or (paths as Array).is_empty() or not paths[0] is Array:
		return out
	for p in paths[0]:
		var props: Variant = bus.call_method(SERVICE, str(p), "org.freedesktop.DBus.Properties", "GetAll", PackedStringArray(["s", DEVICE]))
		if props is Array and not (props as Array).is_empty() and props[0] is Dictionary:
			var pad := pad_from(str(p), props[0])
			if not pad.is_empty():
				out.append(pad)
	out.sort_custom(func(a, b): return str(a["name"]).naturalnocasecmp_to(str(b["name"])) < 0)
	return out


## One device's properties -> a pad, or {} when it isn't a present game controller.
static func pad_from(path: String, props: Dictionary) -> Dictionary:
	if int(_v(props.get("Type", 0))) != GAMING_INPUT or _v(props.get("PowerSupply", false)) == true:
		return {}
	if props.has("IsPresent") and _v(props["IsPresent"]) == false:
		return {}
	var pct := -1
	var level := int(_v(props.get("BatteryLevel", 0)))
	if LEVELS.has(level):
		pct = int(LEVELS[level])
	elif props.has("Percentage"):
		pct = clampi(roundi(float(_v(props["Percentage"]))), 0, 100)
	var name := str(_v(props.get("Model", ""))).strip_edges()
	if name == "":
		name = "Controller"
	return {"path": path, "name": name, "percent": pct, "charging": int(_v(props.get("State", 0))) in CHARGING_STATES}


## What the chip says: the lowest battery first ("62%"), "" when none reports one.
static func chip_text(list: Array) -> String:
	var low := lowest(list)
	return "%d%%" % int(low["percent"]) if not low.is_empty() else ""


## The pad with the lowest known battery, {} when none reports one.
static func lowest(list: Array) -> Dictionary:
	var best := {}
	for p in list:
		if int(p.get("percent", -1)) >= 0 and (best.is_empty() or int(p["percent"]) < int(best["percent"])):
			best = p
	return best


## Tooltip / status line: "DualSense 62% · Xbox Controller 80% charging".
static func detail_text(list: Array) -> String:
	var parts := PackedStringArray()
	for p in list:
		if int(p.get("percent", -1)) < 0:
			continue
		parts.append("%s %d%%%s" % [p["name"], int(p["percent"]), " charging" if p.get("charging", false) else ""])
	return " · ".join(parts)
