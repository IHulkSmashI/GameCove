extends "res://scripts/system/service.gd"
## Controller settings through InputPlumber's D-Bus API (system bus,
## org.shadowblip.InputPlumber; names from InputPlumber src/dbus/interface/,
## commit 6aca920, recorded in docs/SYSTEM.md):
##
##   /org/shadowblip/InputPlumber                 org.freedesktop.DBus.ObjectManager GetManagedObjects
##   /org/shadowblip/InputPlumber/Manager         org.shadowblip.InputManager: Version s, GamepadOrder ao
##   /org/shadowblip/InputPlumber/CompositeDeviceN
##       org.shadowblip.Input.CompositeDevice: Name s, ProfileName s, ProfilePath s,
##           Capabilities as, OutputCapabilities as, TargetDevices as;
##           GetProfileYaml() -> s, LoadProfilePath(s), LoadProfileFromYaml(s)
##       org.shadowblip.Output.ForceFeedback (only when the device can rumble):
##           Enabled b (read/write), Rumble(d), Stop()
##
## Paddles and gyro are profile mappings: we read the loaded profile
## (GetProfileYaml), change its "mapping" list and send it back as JSON with
## LoadProfileFromYaml (JSON is YAML). polkit: reading is allowed to everyone;
## LoadProfile* is auth_admin by default, but InputPlumber's own rule allows the
## `wheel` and `inputplumber` groups without a password (the default user on
## Bazzite and SteamOS is in wheel). ForceFeedback.Enable is allowed to all.
## No RGB/LED setter exists in InputPlumber's API: LED is reported, not settable.
##
## Profiles we keep (JSON in .yaml files, readable by InputPlumber too):
##   ~/.config/inputplumber/profiles/gamecove/default.yaml   your everyday layout
##   ~/.config/inputplumber/profiles/gamecove/<game>.yaml     per game
## InputPlumber forgets a loaded profile when the device is recreated (reboot,
## reconnect), so we load default.yaml again at start and on start_game/end_game.
##
## Nothing polls. Everything runs on the worker; results come back on the main
## thread as `changed` and `applied`.

signal changed(state: Dictionary)
## A setter finished: setting is "paddle", "gyro", "rumble", "profile", "game_profile".
signal applied(setting: String, ok: bool)

const Busctl := preload("res://scripts/device/busctl.gd")
const Yaml := preload("res://scripts/input/yaml_lite.gd")
const Profile := preload("res://scripts/input/ip_profile.gd")

const SERVICE := "org.shadowblip.InputPlumber"
const ROOT_PATH := "/org/shadowblip/InputPlumber"
const MANAGER_PATH := "/org/shadowblip/InputPlumber/Manager"
const MANAGER_IFACE := "org.shadowblip.InputManager"
const DEVICE_IFACE := "org.shadowblip.Input.CompositeDevice"
const FF_IFACE := "org.shadowblip.Output.ForceFeedback"
const OM_IFACE := "org.freedesktop.DBus.ObjectManager"

var bus: RefCounted
var home := OS.get_environment("HOME")
var profiles_dir := ""

var _state := {}                  # main thread: what state() returns
# Worker-side copies, set by _refresh() before it hands _state to the main thread.
var _active := ""
var _profiles_ok := false
var _rumble_ok := false
var _profile: Dictionary = {}     # loaded profile of the active device
var _game := ""
var _game_profile_loaded := false
var _baseline: Dictionary = {}    # profile before a per-game one was loaded


func _init() -> void:
	bus = Busctl.new(runner, "--system")
	profiles_dir = home + "/.config/inputplumber/profiles/gamecove"
	_state = _blank()


func _ready() -> void:
	# Only when there is a saved everyday layout: put it back on (InputPlumber
	# forgot it at reboot). Otherwise nothing runs until the UI calls refresh().
	if not FileAccess.file_exists(default_profile_path()):
		return
	_queue("start", func():
		_refresh()
		if _active != "":
			_load_file(default_profile_path())
			_refresh())


## Tests: fake runner and a fixture home.
func setup(command_runner: RefCounted, home_dir: String) -> void:
	runner = command_runner
	bus = Busctl.new(runner, "--system")
	home = home_dir
	profiles_dir = home + "/.config/inputplumber/profiles/gamecove"
	_state = _blank()
	_active = ""
	_profiles_ok = false
	_rumble_ok = false
	_profile = {}
	_game = ""
	_game_profile_loaded = false


func _blank() -> Dictionary:
	return {
		"available": false, "version": "", "devices": [], "active": "",
		"profile": {"name": "", "path": "", "paddles": {}, "gyro": "off"},
		"rumble": null, "led": false, "game": "", "game_profile": false,
		"supported": {"profiles": false, "paddles": false, "gyro": false, "rumble": false, "led": false, "per_game": false},
	}


## {"available": InputPlumber running, "version", "devices": [{"path", "name",
##   "profile_name", "profile_path", "capabilities", "output_capabilities",
##   "paddles": [...], "gyro": bool, "rumble": bool, "led": bool}],
##  "active": path of the device we edit, "profile": {"name", "path",
##   "paddles": {paddle: target}, "gyro": off|mouse|stick|custom},
##  "rumble": bool or null, "led": bool (device has LEDs; not settable),
##  "game": key or "", "game_profile": bool (that game has its own profile),
##  "supported": {"profiles", "paddles", "gyro", "rumble", "led", "per_game"}}
func state() -> Dictionary:
	return _state.duplicate(true)


func default_profile_path() -> String:
	return profiles_dir + "/default.yaml"


func game_profile_path(key: String) -> String:
	return profiles_dir + "/" + Profile.file_name_for(key)


func has_game_profile(key: String) -> bool:
	return FileAccess.file_exists(game_profile_path(key))


## Reads everything again (worker).
func refresh() -> void:
	_queue("refresh", func(): _refresh())


## Map a back paddle ("LeftPaddle1") to a gamepad button ("South") or a key
## ("KeyW"); "" restores it. Saved to the game's profile when one is active,
## else to the everyday profile.
func set_paddle(paddle: String, target: String) -> void:
	if not (paddle in Profile.PADDLES and Profile.valid_target(target)):
		applied.emit("paddle", false)
		return
	_queue("paddle:" + paddle, func(): _change("paddle", func(p): return Profile.set_paddle(p, paddle, target)))


## "off", "mouse" or "stick".
func set_gyro_mode(mode: String) -> void:
	if not mode in Profile.GYRO_MODES:
		applied.emit("gyro", false)
		return
	_queue("gyro", func(): _change("gyro", func(p): return Profile.set_gyro_mode(p, mode)))


func set_rumble(enabled: bool) -> void:
	_queue("rumble", func():
		var path := _active
		var ok: bool = path != "" and _rumble_ok \
			and bus.set_prop(SERVICE, path, FF_IFACE, "Enabled", "b", "true" if enabled else "false")
		if ok:
			var v: Variant = bus.get_prop(SERVICE, path, FF_IFACE, "Enabled")
			ok = v != null and bool(v) == enabled
		_main(func():
			if ok:
				_state["rumble"] = enabled
			applied.emit("rumble", ok)
			changed.emit(state())))


## A short buzz so the person feels the setting.
func test_rumble(strength := 0.6) -> void:
	_queue("rumble_test", func():
		var path := _active
		if path == "" or not _rumble_ok:
			return
		_call_void(path, FF_IFACE, "Rumble", ["d", str(clampf(strength, 0.0, 1.0))])
		OS.delay_msec(300)
		_call_void(path, FF_IFACE, "Stop", []))


## RGB is not in InputPlumber's D-Bus API (see header). Always false.
func set_led(_color: Color, _brightness: float) -> bool:
	return false


## Loads an InputPlumber profile file (YAML or JSON) onto the active device.
func load_profile_file(path: String) -> void:
	_queue("profile", func():
		var ok := _load_file(path)
		_refresh()
		_main(func(): applied.emit("profile", ok)))


## Saves the current layout as this game's profile (on = true) or deletes it.
func set_game_profile(key: String, on: bool) -> void:
	_queue("game_profile", func():
		var ok := true
		if on:
			ok = _write(game_profile_path(key), _profile)
		elif has_game_profile(key):
			ok = DirAccess.remove_absolute(game_profile_path(key)) == OK
		var has := has_game_profile(key)
		_main(func():
			if key == _game:
				_state["game_profile"] = has
				_game_profile_loaded = has
			applied.emit("game_profile", ok)
			changed.emit(state())))


## GameSession: a game starts. Loads its profile when it has one.
func start_game(key: String) -> void:
	_game = key
	_state["game"] = key
	_queue("game", func():
		var has := has_game_profile(key)
		var base: Dictionary = _profile.duplicate(true)
		var loaded := false
		if has and _active != "":
			loaded = _load_file(game_profile_path(key))
			_refresh()
		_main(func():
			_baseline = base
			_game_profile_loaded = loaded
			_state["game_profile"] = has
			changed.emit(state())))


## GameSession: the game ended. Puts the everyday layout back.
func end_game() -> void:
	var was_loaded := _game_profile_loaded
	var base := _baseline
	_game = ""
	_state["game"] = ""
	_state["game_profile"] = false
	_game_profile_loaded = false
	_baseline = {}
	_queue("game", func():
		if was_loaded and _active != "":
			if FileAccess.file_exists(default_profile_path()):
				_load_file(default_profile_path())
			elif not base.is_empty():
				_load_json(Profile.to_json(base))
		_refresh()
		_main(func(): changed.emit(state())))


# ---- worker side --------------------------------------------------------------

func _refresh() -> void:
	var st := _blank()
	var version: Variant = bus.get_prop(SERVICE, MANAGER_PATH, MANAGER_IFACE, "Version")
	var profile := {}
	if version != null:
		st["available"] = true
		st["version"] = str(version)
		var objs: Variant = bus.call_method(SERVICE, ROOT_PATH, OM_IFACE, "GetManagedObjects")
		st["devices"] = parse_devices(objs[0] if objs is Array and objs.size() > 0 else {})
		for d in st["devices"]:
			if d["name"] == "" or d["capabilities"].is_empty():
				_fill_device(d)
		var order: Variant = bus.get_prop(SERVICE, MANAGER_PATH, MANAGER_IFACE, "GamepadOrder")
		st["active"] = pick_active(st["devices"], order if order is Array else [])
	var dev := {}
	for d in st["devices"]:
		if d["path"] == st["active"]:
			dev = d
	if not dev.is_empty():
		var y: Variant = bus.call_method(SERVICE, dev["path"], DEVICE_IFACE, "GetProfileYaml")
		var parsed: Variant = Yaml.parse(str(y[0])) if y is Array and y.size() > 0 else null
		profile = parsed if parsed is Dictionary else {}
		st["profile"] = {"name": dev["profile_name"], "path": dev["profile_path"],
			"paddles": Profile.paddles(profile, dev["paddles"]), "gyro": Profile.gyro_mode(profile)}
		st["led"] = dev["led"]
		if dev["rumble"]:
			var en: Variant = bus.get_prop(SERVICE, dev["path"], FF_IFACE, "Enabled")
			st["rumble"] = bool(en) if en != null else null
		st["supported"] = {"profiles": true, "paddles": not dev["paddles"].is_empty(), "gyro": dev["gyro"],
			"rumble": dev["rumble"], "led": false, "per_game": true}
	_active = st["active"]
	_profiles_ok = st["supported"]["profiles"]
	_rumble_ok = st["supported"]["rumble"]
	_profile = profile
	_main(func():
		st["game"] = _game
		st["game_profile"] = has_game_profile(_game) if _game != "" else false
		_state = st
		changed.emit(state()))


## Devices from GetManagedObjects' first out argument (busctl JSON).
static func parse_devices(objs: Variant) -> Array:
	var out: Array = []
	if not objs is Dictionary:
		return out
	var re := RegEx.new()
	re.compile("^/org/shadowblip/InputPlumber/CompositeDevice\\d+$")
	var paths: Array = objs.keys()
	paths.sort_custom(func(a, b): return int(str(a).trim_prefix(ROOT_PATH + "/CompositeDevice")) < int(str(b).trim_prefix(ROOT_PATH + "/CompositeDevice")))
	for path in paths:
		if not re.search(str(path)):
			continue
		var ifaces: Variant = objs[path]
		if not ifaces is Dictionary:
			continue
		var props: Dictionary = ifaces.get(DEVICE_IFACE, {}) if ifaces.get(DEVICE_IFACE) is Dictionary else {}
		var caps: Array = _val(props, "Capabilities", [])
		var outs: Array = _val(props, "OutputCapabilities", [])
		out.append({
			"path": str(path), "name": str(_val(props, "Name", "")),
			"profile_name": str(_val(props, "ProfileName", "")), "profile_path": str(_val(props, "ProfilePath", "")),
			"capabilities": caps, "output_capabilities": outs,
			"paddles": Profile.paddles_from_caps(caps), "gyro": Profile.has_gyro(caps),
			"rumble": ifaces.has(FF_IFACE) or "ForceFeedback" in outs,
			"led": outs.any(func(c): return str(c).begins_with("LED")),
			"gamepad": caps.any(func(c): return str(c).begins_with("Gamepad:")),
		})
	return out


static func _val(props: Dictionary, key: String, fallback: Variant) -> Variant:
	var v: Variant = props.get(key)
	if v is Dictionary and v.has("data"):
		v = v["data"]
	if v == null or typeof(v) != typeof(fallback):
		return fallback
	return v


## The device we edit: first composite device in GamepadOrder, else the first
## that is a gamepad, else the first. "" when there is none.
static func pick_active(devices: Array, order: Array) -> String:
	var paths := devices.map(func(d): return d["path"])
	for p in order:
		if str(p) in paths:
			return str(p)
	for d in devices:
		if d.get("gamepad", false):
			return d["path"]
	return devices[0]["path"] if not devices.is_empty() else ""


func _fill_device(d: Dictionary) -> void:
	for key in ["Name", "ProfileName", "ProfilePath", "Capabilities", "OutputCapabilities"]:
		var v: Variant = bus.get_prop(SERVICE, d["path"], DEVICE_IFACE, key)
		if v == null:
			continue
		match key:
			"Name": d["name"] = str(v)
			"ProfileName": d["profile_name"] = str(v)
			"ProfilePath": d["profile_path"] = str(v)
			"Capabilities":
				if v is Array:
					d["capabilities"] = v
					d["paddles"] = Profile.paddles_from_caps(v)
					d["gyro"] = Profile.has_gyro(v)
					d["gamepad"] = v.any(func(c): return str(c).begins_with("Gamepad:"))
			"OutputCapabilities":
				if v is Array:
					d["output_capabilities"] = v
					d["led"] = v.any(func(c): return str(c).begins_with("LED"))
					d["rumble"] = d["rumble"] or "ForceFeedback" in v


## Applies `edit` (profile -> profile) to the loaded profile, sends it, reads it
## back, and saves it where it belongs.
func _change(setting: String, edit: Callable) -> void:
	var ok := false
	if _active != "" and _profiles_ok:
		var base: Dictionary = _profile if not _profile.is_empty() else Profile.empty()
		var next: Dictionary = edit.call(base)
		ok = _load_json(Profile.to_json(next))
		if ok:
			var target := game_profile_path(_game) if _game != "" and _game_profile_loaded else default_profile_path()
			_write(target, next)
	_refresh()
	_main(func(): applied.emit(setting, ok))


func _load_file(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	return _load_json(FileAccess.get_file_as_string(path))


func _load_json(text: String) -> bool:
	var path := _active
	if path == "":
		return false
	return _call_void(path, DEVICE_IFACE, "LoadProfileFromYaml", ["s", text])


## busctl call for a method with no reply value (busctl.gd's call_method
## treats an empty reply as failure).
func _call_void(path: String, iface: String, method: String, args: Array) -> bool:
	var argv := PackedStringArray(["--system", "--timeout=%d" % bus.timeout_s, "call", SERVICE, path, iface, method])
	for a in args:
		argv.append(str(a))
	var r: Dictionary = runner.run("busctl", argv)
	return int(r.get("code", -1)) == 0


func _write(path: String, profile: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(Profile.clean(Profile.normalize(profile)), "  ") + "\n")
	f.close()
	return true
