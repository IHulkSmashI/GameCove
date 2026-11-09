extends RefCounted
## What the controller Controls talk to, read once per detect pass and shared
## by every control (each control's hook would otherwise ask InputPlumber again).
## Runs on the Controls worker only. Nothing polls: the snapshot is read on
## demand and kept for CACHE_MS, and every write drops it.
##
## Backends, picked per device at run time (docs/CONTROLS.md, Controller):
##   InputPlumber   Bazzite/SteamOS default. System bus, busctl through ctx.runner.
##                  Layout edits are device profiles (LoadProfileFromYaml, JSON),
##                  saved where the Controller service keeps the everyday layout
##                  (~/.config/inputplumber/profiles/gamecove/<device>/default.yaml)
##                  so its start-up reload (InputPlumber forgets profiles at reboot)
##                  brings ours back too. Rumble on/off: ForceFeedback.Enabled.
##   hhd            Handheld Daemon when it runs instead (hhd_client.gd). Settings
##                  come from its schema (/api/v1/settings) so every device's own
##                  options show up as hhd names them.
##   sysfs LEDs     RGB when hhd isn't driving it (leds.gd), written by the
##                  no-password root action.

const Busctl := preload("res://scripts/device/busctl.gd")
const Yaml := preload("res://scripts/input/yaml_lite.gd")
const Profile := preload("res://scripts/input/ip_profile.gd")
const PerDevice := preload("res://scripts/device/per_device.gd")
const Hhd := preload("res://scripts/controls/input/hhd_client.gd")
const Leds := preload("res://scripts/controls/input/leds.gd")
const IpEdit := preload("res://scripts/controls/input/ip_edit.gd")

const SERVICE := "org.shadowblip.InputPlumber"
const ROOT_PATH := "/org/shadowblip/InputPlumber"
const MANAGER_PATH := "/org/shadowblip/InputPlumber/Manager"
const MANAGER_IFACE := "org.shadowblip.InputManager"
const DEVICE_IFACE := "org.shadowblip.Input.CompositeDevice"
const FF_IFACE := "org.shadowblip.Output.ForceFeedback"
const OM_IFACE := "org.freedesktop.DBus.ObjectManager"
const TARGET_IFACE := "org.shadowblip.Input.Target"
const CACHE_MS := 1500

var ctx: Dictionary = {}
var row: Dictionary = {}
var bus: RefCounted
var hhd: Hhd
## Called on the main thread after a successful write (the Controller service's
## refresh, so its own page shows the change). Tests leave it empty.
var on_changed: Callable

var _snap: Dictionary = {}
var _snap_at := -1000000


func _init(context: Dictionary = {}) -> void:
	setup(context)


func setup(context: Dictionary) -> void:
	ctx = context
	row = device_row(context.get("device"))
	bus = Busctl.new(context.get("runner"), "--system")
	hhd = Hhd.new(context.get("runner"), str(context.get("sys_root", "")), str(context.get("home", "")))
	hhd.transport = context.get("hhd_transport")
	invalidate()


## The devices.json row from ctx.device: a Device node (its `profile`), a
## Dictionary row (tests, device matrix) or nothing.
static func device_row(device: Variant) -> Dictionary:
	if device is Dictionary:
		return device
	if device is Object and is_instance_valid(device):
		var p: Variant = device.get("profile")
		if p is Dictionary:
			return p
	return {}


func device_id() -> String:
	return str(row.get("id", "unknown"))


func sys_root() -> String:
	return str(ctx.get("sys_root", ""))


func invalidate() -> void:
	_snap = {}
	_snap_at = -1000000


## {"ip": {...} or {}, "hhd": {"state", "settings", "key"} or {}, "leds": [...]}.
func snapshot() -> Dictionary:
	var now := Time.get_ticks_msec()
	if not _snap.is_empty() and now - _snap_at < CACHE_MS:
		return _snap
	_snap = {"ip": _read_ip(), "hhd": _read_hhd(), "leds": Leds.scan(sys_root())}
	_snap_at = now
	return _snap


func ip() -> Dictionary:
	return snapshot()["ip"]


func hhd_info() -> Dictionary:
	return snapshot()["hhd"]


func leds() -> Array:
	return snapshot()["leds"]


## "inputplumber" | "hhd" | "none": who handles the gamepad here.
func controller_backend() -> String:
	if not ip().is_empty() and ip().get("device", {}).get("gamepad", false):
		return "inputplumber"
	if str(hhd_info().get("key", "")) != "":
		return "hhd"
	return "none"


## "hhd" | "sysfs" | "none": who drives the RGB.
func rgb_backend() -> String:
	if Hhd.dig(hhd_info().get("state"), ["rgb", "handheld", "mode"]) is Dictionary:
		return "hhd"
	if not leds().is_empty() and controller_backend() != "hhd":
		return "sysfs"
	return "none"


# ---- InputPlumber -----------------------------------------------------------------

func _read_ip() -> Dictionary:
	if ctx.get("runner") == null:
		return {}
	var version: Variant = bus.get_prop(SERVICE, MANAGER_PATH, MANAGER_IFACE, "Version")
	if version == null:
		return {}
	var objs: Variant = bus.call_method(SERVICE, ROOT_PATH, OM_IFACE, "GetManagedObjects")
	var tree: Variant = objs[0] if objs is Array and objs.size() > 0 else {}
	var devices: Array = _parse_devices(tree)
	var order: Variant = bus.get_prop(SERVICE, MANAGER_PATH, MANAGER_IFACE, "GamepadOrder")
	var dev := _pick(devices, order if order is Array else [])
	if not dev.is_empty():
		dev["targets"] = live_targets(tree, dev["path"])
		if dev["targets"].is_empty():
			# older InputPlumber (0.78) may leave TargetDevices out of GetManagedObjects
			var paths: Variant = bus.get_prop(SERVICE, dev["path"], DEVICE_IFACE, "TargetDevices")
			for tp in (paths if paths is Array else []):
				var kind: Variant = bus.get_prop(SERVICE, str(tp), TARGET_IFACE, "DeviceType")
				if kind != null and str(kind) != "":
					dev["targets"].append(str(kind))
	var out := {"version": str(version), "device": dev, "profile": {}, "rumble": null}
	if dev.is_empty():
		return out
	var y: Variant = bus.call_method(SERVICE, dev["path"], DEVICE_IFACE, "GetProfileYaml")
	var parsed: Variant = Yaml.parse(str(y[0])) if y is Array and y.size() > 0 else null
	out["profile"] = parsed if parsed is Dictionary else {}
	if dev["rumble"]:
		var en: Variant = bus.get_prop(SERVICE, dev["path"], FF_IFACE, "Enabled")
		out["rumble"] = bool(en) if en != null else null
	return out


## The kinds of virtual devices InputPlumber runs for a composite device now, in its
## order: TargetDevices (paths) -> each target object's DeviceType ("deck-uhid", "mouse",
## ...). What another tool set with SetTargetDevices (OpenGamepadUI, Steam) shows here,
## not in the profile. [] when InputPlumber doesn't list them.
static func live_targets(objs: Variant, dev_path: String) -> Array:
	var out: Array = []
	if not objs is Dictionary or not objs.get(dev_path) is Dictionary:
		return out
	var props: Variant = objs[dev_path].get(DEVICE_IFACE)
	if not props is Dictionary:
		return out
	for p in _val(props, "TargetDevices", []):
		var t: Variant = objs.get(str(p))
		var tp: Variant = t.get(TARGET_IFACE) if t is Dictionary else null
		if tp is Dictionary:
			var kind := str(_val(tp, "DeviceType", ""))
			if kind != "":
				out.append(kind)
	return out


## Live target kinds of the picked device (see live_targets), [] when unknown.
func ip_live_targets() -> Array:
	return ip().get("device", {}).get("targets", [])


static func _val(props: Dictionary, key: String, fallback: Variant) -> Variant:
	var v: Variant = props.get(key)
	if v is Dictionary and v.has("data"):
		v = v["data"]
	if v == null or typeof(v) != typeof(fallback):
		return fallback
	return v


static func _parse_devices(objs: Variant) -> Array:
	var out: Array = []
	if not objs is Dictionary:
		return out
	var paths: Array = (objs as Dictionary).keys().filter(func(p): return str(p).begins_with(ROOT_PATH + "/CompositeDevice"))
	paths.sort_custom(func(a, b): return int(str(a).trim_prefix(ROOT_PATH + "/CompositeDevice")) < int(str(b).trim_prefix(ROOT_PATH + "/CompositeDevice")))
	for path in paths:
		var ifaces: Variant = objs[path]
		if not ifaces is Dictionary:
			continue
		var props: Dictionary = ifaces.get(DEVICE_IFACE, {}) if ifaces.get(DEVICE_IFACE) is Dictionary else {}
		var caps: Array = _val(props, "Capabilities", [])
		var outs: Array = _val(props, "OutputCapabilities", [])
		out.append({"path": str(path), "name": str(_val(props, "Name", "")), "capabilities": caps,
			"output_capabilities": outs,
			"gamepad": caps.any(func(c): return str(c).begins_with("Gamepad:")),
			"rumble": ifaces.has(FF_IFACE) or "ForceFeedback" in outs})
	return out


static func _pick(devices: Array, order: Array) -> Dictionary:
	for p in order:
		for d in devices:
			if d["path"] == str(p):
				return d
	for d in devices:
		if d["gamepad"]:
			return d
	return {}


func ip_caps() -> Array:
	return ip().get("device", {}).get("capabilities", [])


func ip_profile() -> Dictionary:
	return ip().get("profile", {})


## InputPlumber's stock profile ("Default"): /etc override first, then the package's.
func ip_stock_profile() -> Dictionary:
	for f in [sys_root() + "/etc/inputplumber/profiles/default.yaml", sys_root() + "/usr/share/inputplumber/profiles/default.yaml"]:
		if FileAccess.file_exists(f):
			var parsed: Variant = Yaml.parse(FileAccess.get_file_as_string(f))
			if parsed is Dictionary:
				return parsed
	return {}


## The loaded profile exactly as InputPlumber hands it out ("" when none), for a
## byte-exact put-back (controls probe).
func ip_profile_yaml() -> String:
	var dev: Dictionary = ip().get("device", {})
	if dev.is_empty():
		return ""
	var y: Variant = bus.call_method(SERVICE, dev["path"], DEVICE_IFACE, "GetProfileYaml")
	return str(y[0]) if y is Array and y.size() > 0 else ""


## Loads a profile text as it was; true when InputPlumber took it.
func ip_load_yaml(text: String) -> bool:
	var dev: Dictionary = ip().get("device", {})
	if dev.is_empty() or text == "":
		return false
	var ok := _load(dev["path"], text)
	invalidate()
	return ok


func profile_path() -> String:
	var dir := str(ctx.get("home", "")) + "/.config/inputplumber/profiles/gamecove/" + PerDevice.key(device_id())
	return dir + "/default.yaml"


## The device config's own virtual devices (for "back to default" and for
## keeping mouse/keyboard when the gamepad type changes).
func ip_config_targets() -> Array:
	var name := str(ip().get("device", {}).get("name", ""))
	return IpEdit.config_targets(sys_root(), name) if name != "" else []


## Applies `edit` (profile -> profile) to the loaded profile, checks with
## `verify` (profile -> bool) on what InputPlumber hands back, saves it as the
## everyday layout. If InputPlumber took it but it doesn't read back right, the
## previous profile goes back on.
func ip_apply(edit: Callable, verify: Callable) -> bool:
	var dev: Dictionary = ip().get("device", {})
	if dev.is_empty():
		return false
	var before: Dictionary = ip_profile()
	var base: Dictionary = before if not before.is_empty() else Profile.empty()
	var next: Dictionary = edit.call(base)
	if not _load(dev["path"], Profile.to_json(next)):
		invalidate()
		return false
	invalidate()
	var after: Dictionary = ip_profile()
	if after.is_empty() or not verify.call(after):
		if not before.is_empty():
			_load(dev["path"], Profile.to_json(before))
		invalidate()
		return false
	_save(next)
	_changed()
	return true


func _load(path: String, json: String) -> bool:
	return call_void(path, DEVICE_IFACE, "LoadProfileFromYaml", ["s", json])


func _save(profile: Dictionary) -> void:
	var p := profile_path()
	DirAccess.make_dir_recursive_absolute(p.get_base_dir())
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(Profile.clean(Profile.normalize(profile)), "  ") + "\n")
		f.close()


## busctl call with no reply value.
func call_void(path: String, iface: String, method: String, args: Array) -> bool:
	var runner: RefCounted = ctx.get("runner")
	if runner == null:
		return false
	var argv := PackedStringArray(["--system", "--timeout=%d" % bus.timeout_s, "call", SERVICE, path, iface, method])
	for a in args:
		argv.append(str(a))
	return int(runner.run("busctl", argv).get("code", -1)) == 0


func ip_set_rumble(on: bool) -> bool:
	var dev: Dictionary = ip().get("device", {})
	if dev.is_empty() or not dev["rumble"]:
		return false
	var ok: bool = bus.set_prop(SERVICE, dev["path"], FF_IFACE, "Enabled", "b", "true" if on else "false")
	invalidate()
	ok = ok and ip().get("rumble") == on
	if ok:
		_changed()
	return ok


func ip_rumble_test(strength: float) -> bool:
	var dev: Dictionary = ip().get("device", {})
	if dev.is_empty() or not dev["rumble"]:
		return false
	var ok := call_void(dev["path"], FF_IFACE, "Rumble", ["d", str(clampf(strength, 0.0, 1.0))])
	OS.delay_msec(250)
	call_void(dev["path"], FF_IFACE, "Stop", [])
	return ok


# ---- hhd ----------------------------------------------------------------------------

func _read_hhd() -> Dictionary:
	if not hhd.present():
		return {}
	var st: Variant = hhd.get_state()
	if st == null:
		return {}
	var settings: Variant = hhd.get_settings()
	return {"state": st, "settings": settings if settings is Dictionary else {}, "key": Hhd.controller_key(st)}


func hhd_state() -> Dictionary:
	var s: Variant = hhd_info().get("state")
	return s if s is Dictionary else {}


func hhd_settings() -> Dictionary:
	var s: Variant = hhd_info().get("settings")
	return s if s is Dictionary else {}


func hhd_key() -> String:
	return str(hhd_info().get("key", ""))


## Value at a path under controllers.<key> (null when missing).
func hhd_ctl(path: Array) -> Variant:
	var key := hhd_key()
	return Hhd.dig(hhd_state(), ["controllers", key] + path) if key != "" else null


## Schema node under controllers.<key>.
func hhd_ctl_schema(path: Array) -> Variant:
	var key := hhd_key()
	return Hhd.schema_node(hhd_settings(), ["controllers", key] + path) if key != "" else null


## POSTs `patch`, then checks every [path, want] in `checks` on the state hhd
## answers with. On a mismatch the old values of those paths are sent back.
func hhd_set(patch: Dictionary, checks: Array) -> bool:
	var before := hhd_state()
	if before.is_empty():
		return false
	var after: Variant = hhd.set_state(patch)
	invalidate()
	if after == null:
		return false
	var ok := true
	for c in checks:
		if not same(Hhd.dig(after, c[0]), c[1]):
			ok = false
	if not ok:
		var undo := {}
		for c in checks:
			var old: Variant = Hhd.dig(before, c[0])
			if old != null:
				undo = Hhd.merge(undo, Hhd.nest(c[0], old))
		if not undo.is_empty():
			hhd.set_state(undo)
		return false
	_changed()
	return true


static func same(got: Variant, want: Variant) -> bool:
	if got == null:
		return false
	if (got is int or got is float) and (want is int or want is float):
		return absf(float(got) - float(want)) < 0.01
	return typeof(got) == typeof(want) and got == want or str(got) == str(want)


# ---- sysfs LEDs ----------------------------------------------------------------------

## Writes the nodes directly where they're world-writable (Leds.apply_direct), else
## runs the root action; re-reads the nodes and `verify` (leds -> bool) decides.
func led_apply(spec: String, verify: Callable) -> bool:
	var direct := Leds.apply_direct(leds(), spec)
	if direct == Leds.DIRECT_OK:
		invalidate()
		if verify.call(leds()):
			_changed()
			return true
	if not Leds.apply(ctx.get("runner"), spec):
		invalidate()
		return false
	invalidate()
	var ok: bool = verify.call(leds())
	if ok:
		_changed()
	return ok


func _changed() -> void:
	if on_changed.is_valid():
		on_changed.call_deferred()
