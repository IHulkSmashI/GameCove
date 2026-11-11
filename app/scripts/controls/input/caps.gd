extends RefCounted
## What a handheld's controller hardware has, from its devices.json row and its
## button profile (scripts/device/buttons.gd). Static: the controls still check
## the running backend before offering anything; this only rules things out
## ("This handheld has no trackpad") and labels them ("M1", "stick rings").

const Buttons := preload("res://scripts/device/buttons.gd")

## gyro state in devices.json -> reason when the control can't work at all.
const GYRO_REASONS := {
	"none": "This handheld has no gyro",
	"no": "Linux can't read this handheld's gyro yet",
}


## {"gyro": devices.json gyro state, "rgb": bool, "rgb_zones": "stick rings"...,
##  "rgb_via": "hhd" | "inputplumber" | ..., "paddles": {capability: label},
##  "extra_buttons": {capability: label} (special buttons GameCove leaves to the
##  game, remappable), "trackpads": int}
static func of(row: Dictionary) -> Dictionary:
	var rgb: Variant = row.get("rgb")
	var bp: Dictionary = Buttons.profile(row) if not row.is_empty() else {}
	var paddles: Dictionary = bp.get("paddles", {}) if bp.get("paddles") is Dictionary else {}
	var extra := {}
	var actions: Dictionary = bp.get("actions", {}) if bp.get("actions") is Dictionary else {}
	for s in bp.get("special", []):
		var cap := str(s.get("capability", ""))
		if cap == "" or cap in paddles or cap in extra:
			continue
		var action: String = actions.get(cap, Buttons.DEFAULT_ACTIONS.get(cap, ""))
		if action == "":
			extra[cap] = str(s.get("label", cap))
	return {
		"gyro": str(row.get("gyro", "unknown")),
		"rgb": rgb is Dictionary,
		"rgb_zones": str(rgb.get("zones", "")) if rgb is Dictionary else "",
		"rgb_via": str(rgb.get("via", "")) if rgb is Dictionary else "",
		"paddles": paddles,
		"extra_buttons": extra,
		"trackpads": int(bp.get("trackpads", 0)),
	}


## Reason the gyro can't be used whatever the backend, "" when it might.
## A row's own gyro_reason (devices.json, e.g. broken on one OS release) wins over the plain words.
static func gyro_block(row: Dictionary) -> String:
	var r: String = GYRO_REASONS.get(str(row.get("gyro", "unknown")), "")
	if r != "" and str(row.get("gyro_reason", "")) != "":
		return str(row["gyro_reason"])
	return r
