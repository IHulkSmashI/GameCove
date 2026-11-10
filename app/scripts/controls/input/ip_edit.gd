extends RefCounted
## InputPlumber device-profile edits for the controller Controls (pure
## functions on Dictionaries; profiles go to InputPlumber as JSON through
## LoadProfileFromYaml, see scripts/input/ip_profile.gd for the base format).
##
## Checked against InputPlumber main (6aca920, 2026-11-07):
##  * Profile events use CapabilityConfig (src/config/capability_map.rs): gamepad
##    {button|axis|trigger}, keyboard, mouse {motion{speed_pps}|button}, touchpad
##    {name, touch{motion|button}}, and top-level gyroscope / accelerometer
##    {"name": "Left"|"Right"|"Center"}. The old {"gamepad": {"gyro": ...}} form
##    is ignored with a warning (src/input/capability.rs).
##  * Translation (src/input/event/value.rs): button -> button/key/mouse button,
##    axis -> mouse motion (speed_pps, 0.20 dead band), trigger -> button/mouse
##    button, touchpad motion -> another pad's motion. Gyroscope -> anything and
##    touchpad -> mouse are NotImplemented: such an event is dropped (with a log
##    line). So "gyro as mouse / as joystick" cannot be done in InputPlumber;
##    raw motion reaches a target that has a motion sensor (Steam Deck,
##    DualSense) and Steam Input turns it into mouse/joystick. A mapping with no
##    target events drops its source: that's how gyro / a pad / a button goes off.
##  * A profile's target_devices replaces the composite device's virtual devices
##    when the profile loads (load_device_profile).
##
## Every mapping we add is named "GameCove <what>" so we only ever replace our own.

const Profile := preload("res://scripts/input/ip_profile.gd")

const GYRO_SOURCES: Array[String] = ["Left", "Right", "Center"]
const PADS: Array[String] = ["LeftPad", "RightPad", "CenterPad"]
## Nintendo layout: the face buttons trade places (A<->B, X<->Y).
const NINTENDO_SWAP := {"South": "East", "East": "South", "North": "West", "West": "North"}
## Gamepad targets InputPlumber can emulate, best first for a handheld.
## (rootfs/usr/share/inputplumber/schema; src/input/target/mod.rs)
const GAMEPAD_TARGETS: Array[String] = ["deck", "ds5-edge", "ds5", "xbox-elite", "xbox-series", "xb360", "hori-steam", "gamepad", "deck-uhid"]
const DESKTOP_SPEED_DEFAULT := 1000


static func _mapping_list(p: Dictionary) -> Array:
	return p["mapping"] if p.get("mapping") is Array else []


static func _named(m: Variant, prefix: String) -> bool:
	return m is Dictionary and str(m.get("name", "")).begins_with(prefix)


## Mappings whose source is a gyroscope (modern or legacy form).
static func is_gyro_source(ev: Variant) -> bool:
	return ev is Dictionary and (ev.get("gyroscope") is Dictionary or Profile.is_gyro(ev))


static func gyro_source_name(ev: Variant) -> String:
	if ev is Dictionary and ev.get("gyroscope") is Dictionary:
		return str(ev["gyroscope"].get("name", ""))
	return ""


## Gyroscope sources the device has, from its Capabilities ("Gyroscope:Center").
static func gyro_sources(caps: Array) -> Array:
	var out: Array = []
	for c in caps:
		var s := str(c)
		if s.begins_with("Gyroscope:"):
			var n := s.trim_prefix("Gyroscope:")
			if n in GYRO_SOURCES and not n in out:
				out.append(n)
	out.sort_custom(func(a, b): return GYRO_SOURCES.find(a) < GYRO_SOURCES.find(b))
	return out


## Sources that pass through (not dropped by a mapping), out of `sources`.
static func gyro_enabled_sources(profile: Dictionary, sources: Array) -> Array:
	var dropped: Array = []
	for m in _mapping_list(profile):
		if m is Dictionary and is_gyro_source(m.get("source_event")):
			var t: Variant = m.get("target_events")
			if t is Array and (t as Array).is_empty():
				dropped.append(gyro_source_name(m["source_event"]))
	return sources.filter(func(s): return not s in dropped)


## New profile where only `enabled` gyro sources pass through; every other gyro
## mapping (ours or a legacy "gyro as mouse" that InputPlumber ignores) goes.
static func set_gyro_sources(profile: Dictionary, sources: Array, enabled: Array) -> Dictionary:
	var p := Profile.normalize(profile)
	var kept: Array = []
	for m in p["mapping"]:
		if not (m is Dictionary and is_gyro_source(m.get("source_event"))):
			kept.append(m)
	for s in sources:
		if not s in enabled:
			kept.append({"name": "GameCove Gyro Off " + str(s), "source_event": {"gyroscope": {"name": s}}, "target_events": []})
	p["mapping"] = kept
	return p


# ---- buttons ------------------------------------------------------------------

## What `button` sends now: "" (itself), "disabled", a button name, "Key…" or
## "mouse:Left"; several targets join with "+".
static func button_target(profile: Dictionary, button: String) -> String:
	for m in _mapping_list(profile):
		if not (m is Dictionary and Profile.button_of(m.get("source_event")) == button):
			continue
		if _named(m, "GameCove Nintendo"):
			continue
		var t: Array = m.get("target_events", []) if m.get("target_events") is Array else []
		if t.is_empty():
			return "disabled"
		var parts := PackedStringArray()
		for e in t:
			if e is Dictionary and e.get("mouse") is Dictionary and e["mouse"].get("button") is String:
				parts.append("mouse:" + str(e["mouse"]["button"]))
			else:
				parts.append(Profile.describe(e))
		return "+".join(parts)
	return ""


static func valid_button_target(target: String) -> bool:
	if target in ["", "disabled"]:
		return true
	if target.begins_with("mouse:"):
		return target.trim_prefix("mouse:") in ["Left", "Right", "Middle", "WheelUp", "WheelDown", "Extra1", "Extra2"]
	return Profile.valid_target(target)


static func _target_event(target: String) -> Dictionary:
	if target.begins_with("mouse:"):
		return {"mouse": {"button": target.trim_prefix("mouse:")}}
	if target.begins_with("Key"):
		return {"keyboard": target}
	return {"gamepad": {"button": target}}


## New profile with `button` sending `target` ("" = itself, "disabled" = nothing).
## `stock`: the device's stock profile (InputPlumber's default.yaml). Picking what the stock
## profile does for this button puts its own mapping(s) back instead of adding a GameCove
## one (the Ally's QuickAccess2 -> Screenshot is stock: a put-back must not leave a
## "GameCove QuickAccess2" override behind).
static func set_button(profile: Dictionary, button: String, target: String, stock: Dictionary = {}) -> Dictionary:
	var p := Profile.normalize(profile)
	var kept: Array = []
	for m in p["mapping"]:
		if not (m is Dictionary and Profile.button_of(m.get("source_event")) == button and not _named(m, "GameCove Nintendo")):
			kept.append(m)
	if not stock.is_empty() and button_target(stock, button) == target:
		for m in _mapping_list(stock):
			if m is Dictionary and Profile.button_of(m.get("source_event")) == button and not _named(m, "GameCove"):
				kept.append((m as Dictionary).duplicate(true))
		p["mapping"] = kept
		return p
	if target == "disabled":
		kept.append({"name": "GameCove " + button, "source_event": {"gamepad": {"button": button}}, "target_events": []})
	elif target != "" and target != button:
		kept.append({"name": "GameCove " + button, "source_event": {"gamepad": {"button": button}}, "target_events": [_target_event(target)]})
	p["mapping"] = kept
	return p


static func nintendo(profile: Dictionary) -> bool:
	return _mapping_list(profile).any(func(m): return _named(m, "GameCove Nintendo"))


static func set_nintendo(profile: Dictionary, on: bool) -> Dictionary:
	var p := Profile.normalize(profile)
	var kept: Array = (p["mapping"] as Array).filter(func(m): return not _named(m, "GameCove Nintendo"))
	if on:
		for b in NINTENDO_SWAP:
			kept.append({"name": "GameCove Nintendo " + b, "source_event": {"gamepad": {"button": b}},
				"target_events": [{"gamepad": {"button": NINTENDO_SWAP[b]}}]})
	p["mapping"] = kept
	return p


# ---- desktop (mouse) mode -------------------------------------------------------

## Right stick moves the pointer, R2 left click, L2 right click; needs the
## "mouse" target. Returns 0 when off, else the pointer speed (pixels/s).
static func desktop_speed(profile: Dictionary) -> int:
	for m in _mapping_list(profile):
		if _named(m, "GameCove Desktop Pointer"):
			var t: Array = m.get("target_events", []) if m.get("target_events") is Array else []
			var sp: Variant = _dig(t[0] if not t.is_empty() else {}, ["mouse", "motion", "speed_pps"])
			return int(sp) if sp != null else DESKTOP_SPEED_DEFAULT
	return 0


## Mouse mode needs the mouse and keyboard virtual devices next to the gamepad. The list
## starts from the profile's own, else what InputPlumber runs now (`live`: a Steam Deck pad
## another tool set stays one, review M12), else `gamepad_target`. Off leaves the targets
## alone: the caller puts back exactly what was there (MouseModeState).
static func set_desktop(profile: Dictionary, on: bool, speed := DESKTOP_SPEED_DEFAULT, gamepad_target := "", live: Array = []) -> Dictionary:
	var p := Profile.normalize(profile)
	var kept: Array = (p["mapping"] as Array).filter(func(m): return not _named(m, "GameCove Desktop"))
	if on:
		kept.append({"name": "GameCove Desktop Pointer", "source_event": {"gamepad": {"axis": {"name": "RightStick"}}},
			"target_events": [{"mouse": {"motion": {"speed_pps": clampi(speed, 200, 4000)}}}]})
		kept.append({"name": "GameCove Desktop Left Click", "source_event": {"gamepad": {"trigger": {"name": "RightTrigger", "deadzone": 0.4}}},
			"target_events": [{"mouse": {"button": "Left"}}]})
		kept.append({"name": "GameCove Desktop Right Click", "source_event": {"gamepad": {"trigger": {"name": "LeftTrigger", "deadzone": 0.4}}},
			"target_events": [{"mouse": {"button": "Right"}}]})
		var targets: Array = (p["target_devices"] as Array).duplicate() if p.get("target_devices") is Array else []
		if targets.is_empty() and not live.is_empty():
			targets = live.duplicate()
		if targets.is_empty() and gamepad_target != "":
			targets = [gamepad_target]
		for t in ["mouse", "keyboard"]:
			if not t in targets:
				targets.append(t)
		p["target_devices"] = targets
	p["mapping"] = kept
	return p


# ---- touchpads ------------------------------------------------------------------

## Pads the device has, from Capabilities ("Touchpad:CenterPad:Touch:Motion").
static func pads(caps: Array) -> Array:
	var out: Array = []
	for c in caps:
		var s := str(c)
		if s.begins_with("Touchpad:"):
			var n := s.split(":")[1] if s.split(":").size() > 1 else ""
			if n in PADS and not n in out:
				out.append(n)
	out.sort_custom(func(a, b): return PADS.find(a) < PADS.find(b))
	return out


static func _pad_of(ev: Variant) -> String:
	if ev is Dictionary and ev.get("touchpad") is Dictionary:
		return str(ev["touchpad"].get("name", ""))
	return ""


## "default" (as the device sends it), "off", or the pad name it is moved to
## ("LeftPad" / "RightPad").
static func pad_mode(profile: Dictionary, pad: String) -> String:
	for m in _mapping_list(profile):
		if not (_named(m, "GameCove Pad") and _pad_of(m.get("source_event")) == pad):
			continue
		var t: Array = m.get("target_events", []) if m.get("target_events") is Array else []
		if t.is_empty():
			return "off"
		var to := _pad_of(t[0])
		return to if to != "" else "default"
	return "default"


static func set_pad_mode(profile: Dictionary, pad: String, mode: String) -> Dictionary:
	var p := Profile.normalize(profile)
	var kept: Array = (p["mapping"] as Array).filter(func(m): return not (_named(m, "GameCove Pad") and _pad_of(m.get("source_event")) == pad))
	if mode == "off":
		for what in [{"motion": {}}, {"button": "Press"}, {"button": "Touch"}]:
			kept.append({"name": "GameCove Pad Off " + pad, "source_event": {"touchpad": {"name": pad, "touch": what}}, "target_events": []})
	elif mode in PADS and mode != pad:
		for what in [{"motion": {}}, {"button": "Press"}, {"button": "Touch"}]:
			kept.append({"name": "GameCove Pad " + pad + " As " + mode, "source_event": {"touchpad": {"name": pad, "touch": what}},
				"target_events": [{"touchpad": {"name": mode, "touch": what}}]})
	p["mapping"] = kept
	return p


# ---- target devices -------------------------------------------------------------

## The gamepad the profile emulates ("" = whatever the device config says).
static func gamepad_target(profile: Dictionary) -> String:
	var t: Variant = profile.get("target_devices")
	if t is Array:
		for x in t:
			if str(x) in GAMEPAD_TARGETS:
				return str(x)
	return ""


## New profile emulating `target` (a GAMEPAD_TARGETS entry), keeping the other
## virtual devices (mouse, keyboard, touchpad) of `base_targets`.
static func set_gamepad_target(profile: Dictionary, target: String, base_targets: Array) -> Dictionary:
	var p := Profile.normalize(profile)
	var cur: Array = p.get("target_devices", []) if p.get("target_devices") is Array else base_targets.duplicate()
	var out: Array = [target]
	for t in cur:
		if not str(t) in GAMEPAD_TARGETS and not t in out:
			out.append(t)
	p["target_devices"] = out
	return p


## Removes every GameCove mapping (and our target override): back to the
## device's own layout.
static func reset(profile: Dictionary) -> Dictionary:
	var p := Profile.normalize(profile)
	p["mapping"] = (p["mapping"] as Array).filter(func(m): return not _named(m, "GameCove"))
	p.erase("target_devices")
	return p


## Device config (InputPlumber's devices/*.yaml, /etc overrides first) whose
## `name:` is `device_name`: its target_devices list, [] when not found.
static func config_targets(sys_root: String, device_name: String) -> Array:
	for dir in [sys_root + "/etc/inputplumber/devices.d", sys_root + "/usr/share/inputplumber/devices"]:
		var d := DirAccess.open(dir)
		if d == null:
			continue
		var files := d.get_files()
		files.sort()
		for f in files:
			if not (f.ends_with(".yaml") or f.ends_with(".yml")):
				continue
			var parsed := parse_config_head(FileAccess.get_file_as_string(dir + "/" + f))
			if parsed["name"] == device_name and not parsed["targets"].is_empty():
				return parsed["targets"]
	return []


## The top-level `name:` and `target_devices:` list of a device config (simple
## line reading; the rest of the file isn't needed).
static func parse_config_head(text: String) -> Dictionary:
	var out := {"name": "", "targets": []}
	var in_targets := false
	for raw in text.split("\n"):
		var line := raw.split("#")[0].strip_edges(false, true)
		if line.strip_edges() == "":
			continue
		var top := not line.begins_with(" ") and not line.begins_with("-")
		if top:
			in_targets = line.begins_with("target_devices:")
			if line.begins_with("name:"):
				out["name"] = line.trim_prefix("name:").strip_edges().trim_prefix("\"").trim_suffix("\"")
			continue
		if in_targets and line.strip_edges().begins_with("- "):
			out["targets"].append(line.strip_edges().trim_prefix("- ").strip_edges().trim_prefix("\"").trim_suffix("\""))
	return out


static func _dig(d: Variant, path: Array) -> Variant:
	var cur: Variant = d
	for k in path:
		if not (cur is Dictionary) or not cur.has(k):
			return null
		cur = cur[k]
	return cur
