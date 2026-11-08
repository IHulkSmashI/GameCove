extends RefCounted
## InputPlumber device profiles as Dictionaries (schema:
## rootfs/usr/share/inputplumber/schema/device_profile_v1.json in InputPlumber):
##   {"version": 1, "kind": "DeviceProfile", "name": "...", "description": "...",
##    "target_devices": ["xbox-elite", ...] (optional),
##    "mapping": [{"name": "...", "source_event": <Event>, "target_events": [<Event>, ...]}]}
## <Event> is one of {"gamepad": {"button": "South"}}, {"gamepad": {"axis": {"name": "RightStick"}}},
## {"gamepad": {"gyro": {"name": "Gyro1", "axis": "yaw", ...}}}, {"keyboard": "KeyW"},
## {"mouse": {"motion": {"speed_pps": 800}}}, {"mouse": {"button": "Left"}}, ...
## Pure functions: read and change paddles and gyro, write JSON for
## LoadProfileFromYaml.

const PADDLES: Array[String] = ["LeftPaddle1", "RightPaddle1", "LeftPaddle2", "RightPaddle2", "LeftPaddle3", "RightPaddle3"]
const GYRO_MODES: Array[String] = ["off", "mouse", "stick"]
## Gamepad buttons a paddle may be mapped to (InputPlumber GamepadEvent.button).
const BUTTONS: Array[String] = ["South", "East", "North", "West", "Start", "Select", "Guide", "QuickAccess",
	"Keyboard", "Screenshot", "DPadUp", "DPadDown", "DPadLeft", "DPadRight", "LeftBumper", "RightBumper",
	"LeftTrigger", "RightTrigger", "LeftStick", "RightStick",
	"LeftPaddle1", "RightPaddle1", "LeftPaddle2", "RightPaddle2", "LeftPaddle3", "RightPaddle3"]


## A minimal valid profile.
static func empty(profile_name := "GameCove") -> Dictionary:
	return {"version": 1, "kind": "DeviceProfile", "name": profile_name, "mapping": []}


## Drops null values (serde_yaml writes every Option as null) so the JSON we
## send back is what InputPlumber's schema expects.
static func clean(v: Variant) -> Variant:
	if v is Dictionary:
		var out := {}
		for k in v:
			if v[k] != null:
				out[k] = clean(v[k])
		return out
	if v is Array:
		return (v as Array).map(func(x): return clean(x))
	return v


static func to_json(profile: Dictionary) -> String:
	return JSON.stringify(clean(normalize(profile)))


## Fills required fields and turns floats that are whole numbers back into ints.
static func normalize(profile: Dictionary) -> Dictionary:
	var p: Dictionary = profile.duplicate(true)
	p["version"] = int(p.get("version", 1)) if p.get("version") != null else 1
	if p.get("kind") == null:
		p["kind"] = "DeviceProfile"
	if p.get("name") == null:
		p["name"] = "GameCove"
	if not p.get("mapping") is Array:
		p["mapping"] = []
	return p


## Button name of a {"gamepad": {"button": X}} event, else "".
static func button_of(event: Variant) -> String:
	if event is Dictionary and event.get("gamepad") is Dictionary:
		return str(event["gamepad"].get("button", "")) if event["gamepad"].get("button") != null else ""
	return ""


static func is_gyro(event: Variant) -> bool:
	return event is Dictionary and event.get("gamepad") is Dictionary and event["gamepad"].get("gyro") is Dictionary


## Short text for a target event: a button name, "Key…" for keyboard keys,
## "mouse" / "stick" / "custom" otherwise.
static func describe(event: Variant) -> String:
	if not event is Dictionary:
		return "custom"
	var b := button_of(event)
	if b != "":
		return b
	if event.get("keyboard") is String:
		return event["keyboard"]
	if event.get("mouse") is Dictionary:
		return "mouse"
	if event.get("gamepad") is Dictionary and event["gamepad"].get("axis") is Dictionary:
		return "stick"
	return "custom"


## {"LeftPaddle1": "South", ...} for each paddle in `available`: what it
## sends now. "" = not remapped (sends itself). Several targets join with "+".
static func paddles(profile: Dictionary, available: Array) -> Dictionary:
	var out := {}
	for p in available:
		out[p] = ""
	for m in profile.get("mapping", []):
		if not m is Dictionary:
			continue
		var src := button_of(m.get("source_event"))
		if src in out:
			var t: Array = m.get("target_events", []) if m.get("target_events") is Array else []
			out[src] = "+".join(PackedStringArray(t.map(func(e): return describe(e))))
	return out


## New profile with `paddle` sending `target` (a gamepad button, or "Key…"
## for a keyboard key). target "" or == paddle removes the remap.
static func set_paddle(profile: Dictionary, paddle: String, target: String) -> Dictionary:
	var p := normalize(profile)
	var kept: Array = []
	for m in p["mapping"]:
		if not (m is Dictionary and button_of(m.get("source_event")) == paddle):
			kept.append(m)
	if target != "" and target != paddle:
		var ev: Dictionary = {"keyboard": target} if target.begins_with("Key") else {"gamepad": {"button": target}}
		kept.append({"name": "GameCove " + paddle, "source_event": {"gamepad": {"button": paddle}}, "target_events": [ev]})
	p["mapping"] = kept
	return p


static func valid_target(target: String) -> bool:
	return target == "" or target in BUTTONS or (target.begins_with("Key") and target.length() > 3 and target.is_valid_identifier())


## "off" (no gyro mapping), "mouse" (gyro moves the pointer) or "stick"
## (gyro drives the right stick). Other gyro mappings read as "custom".
static func gyro_mode(profile: Dictionary) -> String:
	var mode := "off"
	for m in profile.get("mapping", []):
		if not (m is Dictionary and is_gyro(m.get("source_event"))):
			continue
		var t: Array = m.get("target_events", []) if m.get("target_events") is Array else []
		if t.size() == 1 and describe(t[0]) == "mouse":
			mode = "mouse"
		elif t.size() == 1 and describe(t[0]) == "stick":
			mode = "stick"
		else:
			return "custom"
	return mode


## New profile with every gyro mapping replaced by the one for `mode`.
## Note: "off" removes our gyro mappings; a target that has a motion sensor
## of its own (ds5, deck) still passes raw gyro to games that read it.
static func set_gyro_mode(profile: Dictionary, mode: String, gyro_name := "Gyro1") -> Dictionary:
	var p := normalize(profile)
	var kept: Array = []
	for m in p["mapping"]:
		if not (m is Dictionary and is_gyro(m.get("source_event"))):
			kept.append(m)
	var src := {"gamepad": {"gyro": {"name": gyro_name}}}
	if mode == "mouse":
		kept.append({"name": "GameCove Gyro Mouse", "source_event": src, "target_events": [{"mouse": {"motion": {}}}]})
	elif mode == "stick":
		kept.append({"name": "GameCove Gyro Stick", "source_event": src, "target_events": [{"gamepad": {"axis": {"name": "RightStick"}}}]})
	p["mapping"] = kept
	return p


## Paddles the device has, from its Capabilities ("Gamepad:Button:LeftPaddle1").
static func paddles_from_caps(caps: Array) -> Array:
	var out: Array = []
	for p in PADDLES:
		if ("Gamepad:Button:" + p) in caps:
			out.append(p)
	return out


static func has_gyro(caps: Array) -> bool:
	for c in caps:
		if str(c).begins_with("Gyroscope"):
			return true
	return false


## A per-game key ("steam:976730") as a safe file name.
static func file_name_for(key: String) -> String:
	var safe := ""
	for ch in key:
		safe += ch if (ch.is_valid_identifier() or ch.is_valid_int() or ch == "-") else "_"
	return safe + ".yaml"
