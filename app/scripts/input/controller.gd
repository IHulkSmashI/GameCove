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
##
## Two controller services exist on handhelds. InputPlumber (Bazzite's default)
## is used when it has a gamepad; otherwise Handheld Daemon (hhd.gd, its local
## HTTP API) when it answers. state()["backend"] says which, and
## state()["capabilities"] what works with it, so the UI only shows those:
##   InputPlumber: Guide/QAM intercept, paddle remapping, gyro modes, rumble,
##                 per-game profiles; no RGB (no LED setter in its API).
##   hhd:          gyro on/off, paddles as a whole (Steam Input / hhd shortcuts /
##                 off, no per-paddle remap), vibration on/off, RGB (solid color),
##                 per-game settings (a saved slice of hhd's state). Guide reaches
##                 GameCove as the virtual pad's Guide button while our UI has
##                 focus (main.gd), and hhd's Steam shortcuts arrive as Ctrl+1
##                 (Steam menu -> home) and Ctrl+2 (QAM -> quick menu), which hhd
##                 types on its own uinput keyboard into the focused window. Inside
##                 a game hhd keeps its buttons (no intercept API).
##
## Layouts are kept per device (one drive can boot several handhelds):
##   ~/.config/inputplumber/profiles/gamecove/<device id>/default.yaml, <game>.yaml
##   ~/.config/inputplumber/profiles/gamecove/<device id>/<game>.hhd.json (hhd)
## Files from before (straight in gamecove/) move to the device that starts first.
##
## Guide / Quick Access inside GameCove's own gamescope session: the InputPlumber
## intercept in intercept.gd (activation button, InterceptMode 2 while our UI
## has focus and 1 while a game has focus, InputEvent signals read from a
## `gdbus monitor` child). Results: `ui_action(action)` on the main thread, and
## navigation turned back into Godot joypad events. Only when GameCove is the
## session's main app; under Steam's own session InputPlumber is left alone.

signal changed(state: Dictionary)
## A setter finished: setting is "paddle", "gyro", "rumble", "profile", "game_profile".
signal applied(setting: String, ok: bool)
## A special button asked for a GameCove action: "home", "quick_menu", "osk" or
## "screenshot" (InputPlumber intercept, or a fallback chord). Main thread.
signal ui_action(action: String)
## Any button seen through the intercept went down or up (InputPlumber
## capability name: "South", "Guide", "LeftBumper"...). For the button test.
signal button_event(capability: String, pressed: bool)

const Busctl := preload("res://scripts/device/busctl.gd")
const Yaml := preload("res://scripts/input/yaml_lite.gd")
const Profile := preload("res://scripts/input/ip_profile.gd")
const Intercept := preload("res://scripts/input/intercept.gd")
const Hhd := preload("res://scripts/input/hhd.gd")
const PerDevice := preload("res://scripts/device/per_device.gd")
const SettingsFile := preload("res://scripts/system/settings_file.gd")
const ProfileLock := preload("res://scripts/input/profile_lock.gd")

const SERVICE := "org.shadowblip.InputPlumber"
const ROOT_PATH := "/org/shadowblip/InputPlumber"
const MANAGER_PATH := "/org/shadowblip/InputPlumber/Manager"
const MANAGER_IFACE := "org.shadowblip.InputManager"
const DEVICE_IFACE := "org.shadowblip.Input.CompositeDevice"
const FF_IFACE := "org.shadowblip.Output.ForceFeedback"
const OM_IFACE := "org.freedesktop.DBus.ObjectManager"

var bus: RefCounted
var home := OS.get_environment("HOME")
## gamecove/ under InputPlumber's user profile folder; profiles_dir is this device's folder in it.
var profiles_root := ""
var profiles_dir := ""
## Handheld Daemon client (tests swap its transport).
var hhd: RefCounted = Hhd.new()

var _state := {}                  # main thread: what state() returns
# Worker-side copies, set by _refresh() before it hands _state to the main thread.
var _active := ""
var _profiles_ok := false
var _rumble_ok := false
var _profile: Dictionary = {}     # loaded profile of the active device
var _profile_read_ok := false     # its last GetProfileYaml worked (review M13)
var _backend := "none"            # "inputplumber" | "hhd" | "none"
var _hhd_state: Variant = null    # last hhd state (worker)
var _game := ""
var _game_profile_loaded := false
var _baseline: Dictionary = {}    # profile before a per-game one was loaded

## The intercept (see intercept.gd). `device_id` picks the button profile.
var intercept: RefCounted = Intercept.new()
var device_id := ""
var _intercepting := false        # wanted here and set up
var _monitor_alive := false
var _game_focused := false
var _button_test := false
var _restarts := 0
var _intercept_mode := -1         # last mode sent (main thread copy)


func _init() -> void:
	bus = Busctl.new(runner, "--system")
	profiles_root = home + "/.config/inputplumber/profiles/gamecove"
	set_device(device_id)
	_state = _blank()


## Which handheld the layouts belong to (Device.id()). Moves layouts saved
## before per-device folders into this device's folder once.
func set_device(id: String) -> void:
	device_id = id
	profiles_dir = PerDevice.migrate_dir(profiles_root, id if id != "" else "unknown")
	if DirAccess.open(profiles_root) != null:
		PerDevice.migrate_dir(profiles_root, id if id != "" else "unknown", ".json")


func _ready() -> void:
	set_process_input(false)
	var dev := get_node_or_null("/root/Device")
	if dev != null and dev.has_method("id"):
		set_device(dev.id())
	var gs := get_node_or_null("/root/Gamescope")
	if not preload("res://scripts/system/run_mode.gd").helper() and intercept_wanted(
			OS.get_environment("GAMECOVE_STEAM_MODE"), OS.get_environment("GAMECOVE_INTERCEPT"),
			gs != null and gs.has_method("is_running") and gs.is_running()):
		start_intercept()
	# Only when there is a saved everyday layout: put it back on (InputPlumber
	# forgot it at reboot). Otherwise nothing runs until the UI calls refresh().
	if not FileAccess.file_exists(default_profile_path()):
		return
	_queue("start", func():
		_refresh()
		if _active != "":
			_load_file(default_profile_path())
			_refresh())


func _exit_tree() -> void:
	var was := _intercepting
	_intercepting = false
	intercept.on_line = Callable()
	# the worker finishes its queue first (a queued mode change would otherwise land
	# after the safe mode below, review L18) ...
	super._exit_tree()
	if was:
		# ... then never leave a device in Always/Pass with nobody listening
		_set_devices_mode(MODE_NONE_SAFE, Intercept.activation_for(device_id))
		intercept.stop_monitor()


## Tests: fake runner and a fixture home.
func setup(command_runner: RefCounted, home_dir: String, hhd_transport: RefCounted = null) -> void:
	runner = command_runner
	bus = Busctl.new(runner, "--system")
	home = home_dir
	hhd = Hhd.new()
	hhd.home = home_dir
	hhd.root = home_dir + "/root"
	if hhd_transport != null:
		hhd.transport = hhd_transport
	else:
		hhd.transport = _NoHhd.new()
	profiles_root = home + "/.config/inputplumber/profiles/gamecove"
	set_device(device_id)
	_state = _blank()
	_backend = "none"
	_hhd_state = null
	_active = ""
	_profiles_ok = false
	_rumble_ok = false
	_profile = {}
	_game = ""
	_game_profile_loaded = false


## Tests without hhd: nothing answers.
class _NoHhd extends RefCounted:
	func request(_m: String, _p: String, _h: PackedStringArray, _b := "") -> Dictionary:
		return {"code": 0, "body": ""}


const NO_CAPS := {"guide_qam": false, "intercept": false, "paddles": "", "gyro": false, "rumble": false, "rgb": false, "per_game": false}


func _blank() -> Dictionary:
	return {
		"backend": "none", "capabilities": NO_CAPS.duplicate(), "gyro_modes": [], "paddle_modes": [], "paddle_mode": "",
		"rgb": null,
		"available": false, "version": "", "devices": [], "active": "",
		"profile": {"name": "", "path": "", "paddles": {}, "gyro": "off"},
		"rumble": null, "led": false, "game": "", "game_profile": false,
		"supported": {"profiles": false, "paddles": false, "gyro": false, "rumble": false, "led": false, "per_game": false},
	}


## {"backend": "inputplumber" | "hhd" | "none",
##  "capabilities": {"guide_qam", "intercept", "paddles": "remap" | "mode" | "",
##   "gyro", "rumble", "rgb", "per_game"} (what the UI may show for this backend),
##  "gyro_modes": modes set_gyro_mode takes here, "paddle_modes" / "paddle_mode"
##   (hhd: paddles as a whole), "rgb": {"hue", "saturation", "brightness"} or null,
##  "available": InputPlumber running, "version", "devices": [{"path", "name",
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
	var hhd_on: bool = _state.get("backend", "") == "hhd" or _backend == "hhd"
	var f := Profile.file_name_for(key)
	var old := Profile.legacy_file_name_for(key)
	if hhd_on:
		f = f.get_basename() + ".hhd.json"
		old = old.get_basename() + ".hhd.json"
	var p := profiles_dir + "/" + f
	# a layout saved under the older (colliding) name: move it to the unique one once
	if not FileAccess.file_exists(p) and old != f and FileAccess.file_exists(profiles_dir + "/" + old):
		DirAccess.rename_absolute(profiles_dir + "/" + old, p)
	return p


func has_game_profile(key: String) -> bool:
	return FileAccess.file_exists(game_profile_path(key))


## Reads everything again (worker).
func refresh() -> void:
	_queue("refresh", func(): _refresh())


## Map a back paddle ("LeftPaddle1") to a gamepad button ("South") or a key
## ("KeyW"); "" restores it. Saved to the game's profile when one is active,
## else to the everyday profile.
func set_paddle(paddle: String, target: String) -> void:
	if _state["backend"] == "hhd" or not (paddle in Profile.PADDLES and Profile.valid_target(target)):
		applied.emit("paddle", false)   # hhd has no per-paddle remap: set_paddle_mode()
		return
	_queue("paddle:" + paddle, func(): _change("paddle", func(p): return Profile.set_paddle(p, paddle, target)))


## Paddles as a whole on hhd: "steam_input", "noob" (hhd shortcuts), "touchpad",
## "both" or "disabled" (state()["paddle_modes"]). Reported as applied("paddle", ok).
func set_paddle_mode(mode: String) -> void:
	if _state["backend"] != "hhd" or not mode in Hhd.PADDLE_MODES:
		applied.emit("paddle", false)
		return
	_queue("paddle_mode", func():
		var key := Hhd.controller_key(_hhd_state)
		var info := Hhd.paddle_info(key, _hhd_section(key))
		var ok := false
		if not info.is_empty():
			ok = _hhd_set(Hhd.nest(info["path"], mode), info["path"], mode)
		_hhd_done("paddle", ok))


## InputPlumber: "off", "mouse" or "stick". hhd: "off" or "on" (Steam Input does
## the rest; "mouse"/"stick" count as on). state()["gyro_modes"] lists them.
func set_gyro_mode(mode: String) -> void:
	if _state["backend"] == "hhd":
		if not mode in ["off", "on", "mouse", "stick"]:
			applied.emit("gyro", false)
			return
		_queue("gyro", func():
			var key := Hhd.controller_key(_hhd_state)
			var gk := Hhd.gyro_key(_hhd_section(key))
			var ok := false
			if gk != "":
				var path := ["controllers", key, gk]
				ok = _hhd_set(Hhd.nest(path, mode != "off"), path, mode != "off")
			_hhd_done("gyro", ok))
		return
	if not mode in Profile.GYRO_MODES:
		applied.emit("gyro", false)
		return
	_queue("gyro", func(): _change("gyro", func(p): return Profile.set_gyro_mode(p, mode)))


func set_rumble(enabled: bool) -> void:
	if _state["backend"] == "hhd":
		_queue("rumble", func():
			var key := Hhd.controller_key(_hhd_state)
			var ok := false
			if key != "" and Hhd.has_rumble(_hhd_section(key)):
				# hhd's manual limits start from its defaults; only vibration changes
				var v := 100 if enabled else 0
				var patch := {"controllers": {key: {"limits": {"mode": "manual", "manual": {"vibration": v}}}}}
				ok = _hhd_set(patch, ["controllers", key, "limits", "manual", "vibration"], v)
			_hhd_done("rumble", ok))
		return
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
		if _backend != "inputplumber" or path == "" or not _rumble_ok:
			return   # hhd has no "buzz now" call
		_call_void(path, FF_IFACE, "Rumble", ["d", str(clampf(strength, 0.0, 1.0))])
		OS.delay_msec(300)
		_call_void(path, FF_IFACE, "Stop", []))


## RGB: hhd only (InputPlumber's D-Bus API has no LED setter). Solid color;
## true when queued, then applied("led", ok) once hhd confirmed it.
func set_led(color: Color, brightness: float) -> bool:
	if _state["backend"] != "hhd" or not _state["capabilities"].get("rgb", false):
		return false
	_queue("led", func():
		var mode := Hhd.solid_rgb(color, brightness)
		var ok := _hhd_set({"rgb": {"handheld": {"mode": mode}}}, ["rgb", "handheld", "mode", "mode"], "solid")
		_hhd_done("led", ok))
	return true


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
		if on and _backend == "hhd":
			ok = _write_text(game_profile_path(key), JSON.stringify(Hhd.game_slice(_hhd_state), "  ") + "\n")
		elif on:
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


# ---- intercept ----------------------------------------------------------------

const MODE_NONE_SAFE := 0


## True when GameCove should take the Guide button from InputPlumber: inside a
## gamescope session that GameCove runs as its main app (our session file
## exports GAMECOVE_STEAM_MODE), unless GAMECOVE_INTERCEPT=0.
static func intercept_wanted(steam_mode_env: String, intercept_env: String, in_gamescope: bool) -> bool:
	return in_gamescope and steam_mode_env != "" and intercept_env != "0"


## Starts the intercept: the monitor first; devices get their activation and
## mode once it prints its first line. False when gdbus can't run (then the
## virtual pad keeps reaching Godot as usual and Guide arrives as a joypad button).
func start_intercept(program := Intercept.MONITOR_PROGRAM, args: Array = Intercept.MONITOR_ARGS) -> bool:
	_setup_intercept()
	_intercepting = true
	if not intercept.start_monitor(program, args):
		_intercepting = false
		return false
	return true


func _setup_intercept() -> void:
	intercept.device = device_id
	intercept.inject = _inject
	intercept.on_action = func(a: String): ui_action.emit(a)
	intercept.on_button = func(c: String, p: bool): button_event.emit(c, p)
	intercept.on_line = _on_monitor_line


## Tests: pretend the intercept runs (no monitor process); lines go through
## monitor_line().
func setup_intercept_for_tests() -> void:
	_setup_intercept()
	_intercepting = true


func monitor_line(parsed: Dictionary) -> void:
	_on_monitor_line(parsed)


## While a game has focus (true) everything but the activation button goes to
## the game; while GameCove's UI has focus (false) InputPlumber sends it all to
## us. main.gd calls it when home / the quick menu opens over a game and when
## the game gets the screen back. start_game / end_game set it too.
func set_game_focused(on: bool) -> void:
	_game_focused = on
	intercept.reset()
	_apply_intercept()


## Before leaving the session (quick menu "Switch to Steam"): stop
## intercepting and put InterceptMode 0 on every composite device, so Steam or
## the desktop never start with a device that sends its input nowhere. Runs on
## the worker; `done` is called on the main thread once it's written.
func release_intercept(done := Callable()) -> void:
	_intercepting = false
	_monitor_alive = false
	intercept.on_line = Callable()
	intercept.reset()
	intercept.stop_monitor()
	_intercept_mode = MODE_NONE_SAFE
	_queue("intercept", func():
		var objs: Variant = bus.call_method(SERVICE, ROOT_PATH, OM_IFACE, "GetManagedObjects")
		for d in parse_devices(objs[0] if objs is Array and objs.size() > 0 else {}):
			bus.set_prop(SERVICE, d["path"], DEVICE_IFACE, "InterceptMode", "u", str(MODE_NONE_SAFE))
		_main(func():
			if done.is_valid():
				done.call()))


## Button test: lets the virtual pad reach Godot directly (mode 0) so even back
## paddles show up, but only with no game running behind us.
func set_button_test(on: bool) -> void:
	_button_test = on
	intercept.reset()
	_apply_intercept()


## {"active": intercepting, "listening": monitor runs, "mode": last mode sent
## (-1 none), "game_focused", "activation": {"events", "target"}, "chords": {action: [modifier, button]}}
func intercept_state() -> Dictionary:
	return {"active": _intercepting, "listening": _monitor_alive, "mode": _intercept_mode,
		"game_focused": _game_focused, "activation": Intercept.activation_for(device_id),
		"chords": Intercept.chords_for(device_id)}


func _wanted_mode() -> int:
	if not _monitor_alive:
		return Intercept.MODE_NONE
	if _game_focused:
		return Intercept.MODE_PASS
	if _button_test and _game == "":
		return Intercept.MODE_NONE
	return Intercept.MODE_ALWAYS


func _apply_intercept() -> void:
	if not _intercepting:
		return
	_send_mode(_wanted_mode())


func _send_mode(mode: int) -> void:
	_intercept_mode = mode
	var act := Intercept.activation_for(device_id)
	_queue("intercept", func(): _set_devices_mode(mode, act))


## Worker: activation and mode on every gamepad composite device.
func _set_devices_mode(mode: int, act: Dictionary) -> void:
	var objs: Variant = bus.call_method(SERVICE, ROOT_PATH, OM_IFACE, "GetManagedObjects")
	var devs := parse_devices(objs[0] if objs is Array and objs.size() > 0 else {})
	for d in devs:
		if not d.get("gamepad", false) and not d["capabilities"].is_empty():
			continue
		var events: Array = act["events"]
		var args: Array = ["ass", str(events.size())]
		args.append_array(events)
		args.append(act["target"])
		_call_void(d["path"], DEVICE_IFACE, "SetInterceptActivation", args)
		bus.set_prop(SERVICE, d["path"], DEVICE_IFACE, "InterceptMode", "u", str(mode))


func _on_monitor_line(d: Dictionary) -> void:
	match str(d.get("kind", "")):
		"started":
			_monitor_alive = true
			_restarts = 0
			_apply_intercept()
		"owner":
			if str(d.get("owner", "")) != "":
				_apply_intercept()   # InputPlumber (re)started: its devices are new
				_reload_layout()
		"added":
			if str(d.get("path", "")).begins_with(ROOT_PATH + "/CompositeDevice"):
				_apply_intercept()
				_reload_layout()
		"event":
			intercept.handle(str(d["event"]), float(d["value"]))
		"exited":
			_monitor_alive = false
			intercept.reset()
			if _intercepting:
				_send_mode(Intercept.MODE_NONE)
				_restart_monitor_later()


## A new composite device (InputPlumber restarted: GameCove does it on the gyro accelerometer
## toggle; or the pad dropped and came back) starts with the stock profile: load ours again,
## the running game's own layout or the everyday one, and let Controls read what's live
## (review M10). One job: several "added" lines in a row load once.
func _reload_layout() -> void:
	_queue("reload_layout", func():
		_refresh()
		if _active != "":
			var own := _game != "" and _game_profile_loaded and has_game_profile(_game) and _backend != "hhd"
			if own:
				_load_file(game_profile_path(_game))
			elif FileAccess.file_exists(default_profile_path()):
				_load_file(default_profile_path())
			_refresh()
		_main(func():
			var controls := get_node_or_null("/root/Controls") if is_inside_tree() else null
			if controls != null and controls.has_method("detect_all"):
				controls.detect_all()))


func _restart_monitor_later() -> void:
	if _restarts >= 3 or not is_inside_tree():
		return
	_restarts += 1
	get_tree().create_timer(5.0 * _restarts).timeout.connect(func():
		if _intercepting and not intercept.running():
			intercept.stop_monitor()
			intercept.start_monitor())


func _inject(e: InputEvent) -> void:
	var pads := Input.get_connected_joypads()
	if not pads.is_empty() and (e is InputEventJoypadButton or e is InputEventJoypadMotion):
		e.device = pads[0]
	Input.parse_input_event(e)


## GameSession: a game starts. Loads its profile when it has one.
func start_game(key: String) -> void:
	_game_focused = true
	_apply_intercept()
	_game = key
	_state["game"] = key
	_queue("game", func():
		var has := has_game_profile(key)
		var base: Dictionary = _profile.duplicate(true)
		var loaded := false
		if has and _backend == "hhd":
			base = Hhd.game_slice(_hhd_state)
			var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(game_profile_path(key)))
			loaded = saved is Dictionary and hhd.set_state(saved) != null
			_refresh()
		elif has and _active != "":
			loaded = _load_file(game_profile_path(key))
			_refresh()
		_main(func():
			_baseline = base
			_game_profile_loaded = loaded
			_state["game_profile"] = has
			changed.emit(state())))


## GameSession: the game ended. Puts the everyday layout back.
func end_game() -> void:
	_game_focused = false
	_game = ""
	_apply_intercept()
	var was_loaded := _game_profile_loaded
	var base := _baseline
	_game = ""
	_state["game"] = ""
	_state["game_profile"] = false
	_game_profile_loaded = false
	_baseline = {}
	_queue("game", func():
		if was_loaded and _backend == "hhd":
			if not base.is_empty():
				hhd.set_state(base)
		elif was_loaded and _active != "":
			if FileAccess.file_exists(default_profile_path()):
				_load_file(default_profile_path())
			elif not base.is_empty():
				_load_json(Profile.to_json(base))
		_refresh()
		_main(func(): changed.emit(state())))


# ---- worker side --------------------------------------------------------------

func _refresh() -> void:
	var st := _blank()
	var read_ok := false
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
		read_ok = parsed is Dictionary
		st["profile"] = {"name": dev["profile_name"], "path": dev["profile_path"],
			"paddles": Profile.paddles(profile, dev["paddles"]), "gyro": Profile.gyro_mode(profile)}
		st["led"] = dev["led"]
		if dev["rumble"]:
			var en: Variant = bus.get_prop(SERVICE, dev["path"], FF_IFACE, "Enabled")
			st["rumble"] = bool(en) if en != null else null
		st["supported"] = {"profiles": true, "paddles": not dev["paddles"].is_empty(), "gyro": dev["gyro"],
			"rumble": dev["rumble"], "led": false, "per_game": true}
	var backend := "inputplumber" if dev.get("gamepad", false) else "none"
	var hs: Variant = null
	if backend == "none":
		hs = hhd.get_state()
		if hs != null and Hhd.controller_key(hs) != "":
			backend = "hhd"
			_fill_hhd(st, hs)
	if backend == "inputplumber":
		st["capabilities"] = {"guide_qam": true, "intercept": true,
			"paddles": "remap" if st["supported"]["paddles"] else "", "gyro": st["supported"]["gyro"],
			"rumble": st["supported"]["rumble"], "rgb": false, "per_game": true}
		st["gyro_modes"] = Profile.GYRO_MODES.duplicate() if st["supported"]["gyro"] else []
	st["backend"] = backend
	_backend = backend
	_hhd_state = hs
	_active = st["active"]
	_profiles_ok = st["supported"]["profiles"]
	_rumble_ok = st["supported"]["rumble"]
	_profile = profile
	_profile_read_ok = read_ok
	_main(func():
		st["game"] = _game
		_state = st
		st["game_profile"] = has_game_profile(_game) if _game != "" else false
		if is_inside_tree():
			set_process_input(st["backend"] == "hhd")
		changed.emit(state()))


## hhd's view into the state shape (worker).
func _fill_hhd(st: Dictionary, hs: Dictionary) -> void:
	var key := Hhd.controller_key(hs)
	var section := _section_of(hs, key)
	var caps := Hhd.capabilities(hs)
	st["capabilities"] = caps
	var gk := Hhd.gyro_key(section)
	st["gyro_modes"] = ["off", "on"] if gk != "" else []
	var pi := Hhd.paddle_info(key, section)
	st["paddle_modes"] = pi.get("modes", [])
	st["paddle_mode"] = pi.get("value", "")
	var rgb: Variant = Hhd.dig(hs, ["rgb", "handheld", "mode", "solid"])
	st["rgb"] = null
	if rgb is Dictionary:
		st["rgb"] = {"hue": int(rgb.get("hue", 0)), "saturation": int(rgb.get("saturation", 0)), "brightness": int(rgb.get("brightness", 0))}
	var rum: Variant = Hhd.rumble_on(section)
	st["rumble"] = true if rum == null and caps["rumble"] else rum
	st["profile"] = {"name": "hhd:" + key, "path": "", "paddles": {},
		"gyro": ("on" if section.get(gk, false) else "off") if gk != "" else "off"}
	st["supported"] = {"profiles": false, "paddles": caps["paddles"] != "", "gyro": caps["gyro"],
		"rumble": caps["rumble"], "led": caps["rgb"], "per_game": caps["per_game"]}
	st["led"] = caps["rgb"]


static func _section_of(hs: Variant, key: String) -> Dictionary:
	var v: Variant = Hhd.dig(hs, ["controllers", key]) if key != "" else null
	return v if v is Dictionary else {}


func _hhd_section(key: String) -> Dictionary:
	return _section_of(_hhd_state, key)


## POST a change to hhd and check `path` reads back as `want` (worker).
func _hhd_set(patch: Dictionary, path: Array, want: Variant) -> bool:
	if _backend != "hhd":
		return false
	var after: Variant = hhd.set_state(patch)
	if after == null:
		return false
	var got: Variant = Hhd.dig(after, path)
	_hhd_state = after
	if got == null:
		return false
	if (got is int or got is float) and (want is int or want is float):
		return absf(float(got) - float(want)) < 0.01   # JSON numbers come back as floats
	return str(got) == str(want)


## After an hhd setter: read everything again, then report (worker).
func _hhd_done(setting: String, ok: bool) -> void:
	_refresh()
	_main(func(): applied.emit(setting, ok))


## Ctrl+1 / Ctrl+2: hhd's Steam shortcuts (its QAM handler types them on a uinput
## keyboard), our home / quick menu. Only listened to while hhd is the backend.
static func hhd_key_action(e: InputEvent) -> String:
	if not (e is InputEventKey) or not e.pressed or e.echo or not e.ctrl_pressed:
		return ""
	match e.keycode:
		KEY_1: return "home"
		KEY_2: return "quick_menu"
	return ""


func _input(event: InputEvent) -> void:
	var a := hhd_key_action(event)
	if a != "":
		get_viewport().set_input_as_handled()
		ui_action.emit(a)


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
##
## Under ProfileLock, on the profile read again right now, and only when that read worked (review M13).
func _change(setting: String, edit: Callable) -> void:
	var ok := false
	ProfileLock.mutex.lock()
	_refresh()
	if _active != "" and _profiles_ok and _profile_read_ok:
		var base: Dictionary = _profile if not _profile.is_empty() else Profile.empty()
		var next: Dictionary = edit.call(base)
		ok = _load_json(Profile.to_json(next))
		if ok:
			var target := game_profile_path(_game) if _game != "" and _game_profile_loaded else default_profile_path()
			_write(target, next)
	ProfileLock.mutex.unlock()
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
	# never in the middle of the Controls worker's read-modify-write (ProfileLock is recursive)
	ProfileLock.mutex.lock()
	var ok := _call_void(path, DEVICE_IFACE, "LoadProfileFromYaml", ["s", text])
	ProfileLock.mutex.unlock()
	return ok


## busctl call for a method with no reply value (busctl.gd's call_method
## treats an empty reply as failure).
func _call_void(path: String, iface: String, method: String, args: Array) -> bool:
	var argv := PackedStringArray(["--system", "--timeout=%d" % bus.timeout_s, "call", SERVICE, path, iface, method])
	for a in args:
		argv.append(str(a))
	var r: Dictionary = runner.run("busctl", argv)
	return int(r.get("code", -1)) == 0


func _write_text(path: String, text: String) -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	return SettingsFile.save_text(path, text) == OK


func _write(path: String, profile: Dictionary) -> bool:
	return _write_text(path, JSON.stringify(Profile.clean(Profile.normalize(profile)), "  ") + "\n")
