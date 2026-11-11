extends RefCounted
## "What works here": one answer per feature for this exact handheld, shared by
## About this device, the quick menu's Device tab and anything else that lists
## what a handheld can do. Pure and static (safe on any thread).
##
## Sources, strongest first:
##   1. live Controls detection (the provider found the backend and the node):
##      available = works; unavailable with a reason = the hardware is there but
##      something is missing here (the reason says what), or, when devices.json
##      says the hardware isn't there, "not on this handheld";
##   2. devices.json through Device.features_of() (and the row's "unverified"
##      list): present = works (unconfirmed when listed as unverified),
##      absent = not on this handheld.
## A control that hasn't been detected yet ("Not checked yet") counts as no
## live answer.
##
##   Capabilities.states(features, unverified, controls) -> Array of
##     {key, state: "yes" | "maybe" | "absent", note}
##   "yes": works. "maybe": there but not confirmed / needs something (note says
##   what). "absent": this handheld doesn't have it (never shown as a failure).

const ORDER := ["tdp", "fan_control", "charge_limit", "vrr", "gyro", "paddles", "trackpads", "rgb"]
## Controls that prove a feature works (any one available is enough).
const CONTROL_IDS := {
	"tdp": ["power.tdp"],
	"fan_control": ["power.fan_mode", "power.fan_curve"],
	"charge_limit": ["power.charge_limit", "power.battery_long_life"],
	"vrr": ["display.vrr"],
	"gyro": ["controller.gyro"],
	"paddles": ["controller.paddles_as", "controller.paddle.LeftPaddle1", "controller.paddle.RightPaddle1"],
	"trackpads": ["controller.trackpad"],
	"rgb": ["controller.led_color", "controller.led_effect"],
}
## devices.json "unverified" names that cover a feature.
const UNVERIFIED_KEYS := {
	"tdp": ["tdp", "tdp.battery_max", "all"], "fan_control": ["fan", "all"], "charge_limit": ["charge_limit", "all"],
	"vrr": ["panel.vrr", "all"], "gyro": ["gyro", "all"], "paddles": ["buttons", "all"], "trackpads": ["buttons", "all"],
	"rgb": ["rgb", "all"],
}
const NOT_CHECKED := "Not checked yet"
const UNCONFIRMED := "Not confirmed on this model yet"
const GYRO_NOTES := {"fix": "Needs the gyro fix (Device, Fixes)", "unknown": "Not sure yet", "no": "Not working on Linux yet"}


## Does devices.json say this handheld has the hardware at all?
static func has_hardware(key: String, f: Dictionary) -> bool:
	match key:
		"tdp": return bool(f.get("tdp", false))
		"fan_control": return bool(f.get("fan", false)) or bool(f.get("fan_control", false))
		"charge_limit": return bool(f.get("charge_limit", false))
		"vrr": return bool(f.get("vrr", false))
		"gyro": return not str(f.get("gyro", "unknown")) in ["none"]
		"paddles": return int(f.get("paddles", 0)) > 0
		"trackpads": return int(f.get("trackpads", 0)) > 0
		"rgb": return bool(f.get("rgb", false))
	return false


## What devices.json alone says (no live detection).
static func row_state(key: String, f: Dictionary, unverified: Array) -> Dictionary:
	if not has_hardware(key, f):
		# Power limits always exist; "no tdp block" means we don't know them yet.
		if key == "tdp":
			return {"key": key, "state": "maybe", "note": UNCONFIRMED}
		return {"key": key, "state": "absent", "note": ""}
	if key == "gyro":
		var g := str(f.get("gyro", "unknown"))
		if g != "yes":
			var why := str(f.get("gyro_reason", ""))
			return {"key": key, "state": "maybe", "note": why if why != "" else GYRO_NOTES.get(g, GYRO_NOTES["unknown"])}
	if key == "fan_control" and not bool(f.get("fan_control", false)):
		return {"key": key, "state": "maybe", "note": "The fan runs on its own; presets aren't set up for this model yet"}
	for u in UNVERIFIED_KEYS.get(key, []):
		if u in unverified:
			return {"key": key, "state": "maybe", "note": UNCONFIRMED}
	return {"key": key, "state": "yes", "note": ""}


## Live answer from Controls: {} when there isn't one.
static func live_state(key: String, f: Dictionary, controls: Object) -> Dictionary:
	if controls == null or not controls.has_method("control"):
		return {}
	var reasons: Array = []
	for id in CONTROL_IDS.get(key, []):
		var c: Variant = controls.control(id)
		if c == null:
			continue
		if bool(c.get("available")):
			return {"key": key, "state": "yes", "note": ""}
		var r := str(c.get("reason"))
		if r != "" and r != NOT_CHECKED:
			reasons.append(r)
	if reasons.is_empty():
		return {}
	if not has_hardware(key, f):
		return {"key": key, "state": "absent", "note": ""}
	return {"key": key, "state": "maybe", "note": str(reasons[0])}


static func states(f: Dictionary, unverified: Array = [], controls: Object = null) -> Array:
	var out: Array = []
	for key in ORDER:
		var live := live_state(key, f, controls)
		out.append(live if not live.is_empty() else row_state(key, f, unverified))
	return out


## Short summary for tight spots: {"yes": n, "maybe": n, "absent": n}.
static func counts(list: Array) -> Dictionary:
	var c := {"yes": 0, "maybe": 0, "absent": 0}
	for s in list:
		c[s["state"]] = int(c.get(s["state"], 0)) + 1
	return c
