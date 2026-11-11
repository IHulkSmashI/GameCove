extends RefCounted
## Presses keyboard keys at the game through InputPlumber's virtual keyboard
## (org.shadowblip.Input.Keyboard.SendKey). GameCove writes no uinput device
## of its own.
##
##   /org/shadowblip/InputPlumber/devices/target/keyboardN
##       org.shadowblip.Input.Keyboard.SendKey(key s, pressed b)    "KEY_ESC", true
##   /org/shadowblip/InputPlumber/Manager  org.shadowblip.InputManager
##       CreateTargetDevice("keyboard") -> path, StopTargetDevice(path)
##
## polkit: SendKey and the two Manager calls are allowed to the `wheel` and
## `inputplumber` groups without a password by InputPlumber's own rule, the same
## rule the controller settings rely on.
##
## A keyboard InputPlumber already runs (the device's own config lists one, or
## mouse mode added it) is used as it is. When there is none, one is made for
## the press and stopped right after, so nothing of ours stays behind a game.
##
## Blocking (busctl calls and short waits): call from a worker thread only.
## Handheld Daemon has no call that presses a key, so there is no hhd path.

const Busctl := preload("res://scripts/device/busctl.gd")
const Registry := preload("res://scripts/actions/registry.gd")

const SERVICE := "org.shadowblip.InputPlumber"
const ROOT_PATH := "/org/shadowblip/InputPlumber"
const MANAGER_PATH := "/org/shadowblip/InputPlumber/Manager"
const MANAGER_IFACE := "org.shadowblip.InputManager"
const KEYBOARD_IFACE := "org.shadowblip.Input.Keyboard"
const OM_IFACE := "org.freedesktop.DBus.ObjectManager"
## A new virtual keyboard needs a moment before the compositor reads it.
const NEW_DEVICE_MS := 400
## How long the keys stay down, and the gap between one key and the next.
const HOLD_MS := 60
const STEP_MS := 20

var bus: RefCounted
## Tests: no real waiting.
var wait: Callable = func(ms: int) -> void: OS.delay_msec(ms)


func _init(command_runner: RefCounted) -> void:
	bus = Busctl.new(command_runner, "--system")


## Paths of the virtual keyboards InputPlumber runs now, sorted.
static func keyboards(objs: Variant) -> Array:
	var out: Array = []
	if objs is Dictionary:
		for path in objs:
			if objs[path] is Dictionary and (objs[path] as Dictionary).has(KEYBOARD_IFACE):
				out.append(str(path))
	out.sort()
	return out


## True when InputPlumber answers (keys can be pressed here).
func present() -> bool:
	return bus.get_prop(SERVICE, MANAGER_PATH, MANAGER_IFACE, "Version") != null


## Presses `keys` (profile names, "KeyLeftAlt") together: down in order, up in
## reverse. `before_ms`: a wait first, for the game to have the keyboard again
## after the quick menu closed. False when a call failed; keys already down are
## always let go.
func press(keys: Array, before_ms := 0) -> bool:
	if not Registry.valid_combo(keys):
		return false
	if before_ms > 0:
		wait.call(before_ms)
	var objs: Variant = bus.call_method(SERVICE, ROOT_PATH, OM_IFACE, "GetManagedObjects")
	var found := keyboards(objs[0] if objs is Array and not objs.is_empty() else {})
	var path: String = found[0] if not found.is_empty() else ""
	var made := false
	if path == "":
		var r: Variant = bus.call_method(SERVICE, MANAGER_PATH, MANAGER_IFACE, "CreateTargetDevice", PackedStringArray(["s", "keyboard"]))
		path = str(r[0]) if r is Array and not r.is_empty() else ""
		if not path.begins_with(ROOT_PATH + "/"):
			return false
		made = true
		wait.call(NEW_DEVICE_MS)
	var down: Array = []
	var ok := true
	for k in keys:
		if not _send(path, str(k), true):
			ok = false
			break
		down.append(k)
		wait.call(STEP_MS)
	if ok:
		wait.call(HOLD_MS)
	down.reverse()
	for k in down:
		ok = _send(path, str(k), false) and ok
		wait.call(STEP_MS)
	if made:
		_void(MANAGER_PATH, MANAGER_IFACE, "StopTargetDevice", ["s", path])
	return ok


func _send(path: String, key: String, pressed: bool) -> bool:
	return _void(path, KEYBOARD_IFACE, "SendKey", ["sb", Registry.dbus_key(key), "true" if pressed else "false"])


## A call with no answer: busctl prints nothing, so only its exit code says it worked.
func _void(path: String, iface: String, method: String, args: Array) -> bool:
	var argv := PackedStringArray(["--system", "--timeout=%d" % bus.timeout_s, "call", SERVICE, path, iface, method])
	argv.append_array(PackedStringArray(args))
	return int(bus.runner.run("busctl", argv).get("code", -1)) == 0
